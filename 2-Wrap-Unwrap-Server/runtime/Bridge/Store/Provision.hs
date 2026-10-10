-- Closed offline installer operation. Never adopts, resumes or replaces a ledger.
module Bridge.Store.Provision (provisionDatabase,provisionRestoredDatabase) where
import Bridge.Error
import qualified Bridge.Store.Schema as S
import Bridge.Store.Catalog (claimWorker,verifyReadRole)
import Data.Int (Int64)
import Bridge.Identity (digest)
import Control.Exception (bracket)
import Control.Monad (forM,forM_,void)
import qualified Data.ByteString.Char8 as B
import Data.Profunctor.Product (p2,p3,p8)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types (Identifier(..),Query(..))
import qualified Opaleye as O
import Opaleye.Internal.Column (Field_(Column),unColumn)
import qualified Opaleye.Internal.HaskellDB.PrimQuery as E
import Paths_ecx_bridge (getDataFileName)

-- The unique NOLOGIN owner binds CREATE DATABASE atomically to the root journal.
-- A COMMENT written after database creation would leave an ambiguous crash gap.
-- All catalog/data reads and receipt writes use Opaleye; only DDL uses execute.
provisionDatabase :: PG.ConnectInfo -> Text -> IO ()
provisionDatabase settings token=do
  require (T.length token==32 && T.all (`elem` ("0123456789abcdef"::String)) token) "invalid_installation_token"
  require (PG.connectDatabase settings=="postgres" && PG.connectUser settings=="postgres") "provision_requires_postgres_admin"
  scripts<-forM [1..8::Int] $ \n->do
    bytes<-getDataFileName ("migrations/00"<>show n<>".sql") >>= B.readFile
    let lines'=B.lines bytes
    require (length(filter(=="BEGIN;") lines')==1 && length(filter(=="COMMIT;") lines')==1
      && last(filter(not.B.null) lines')=="COMMIT;") "unexpected_installation_migration_structure"
    pure (bytes,B.unlines $ filter(\line->line/="BEGIN;" && line/="COMMIT;") lines')
  let checksum=digest(B.concat $ map fst scripts)
      owner="ecx_setup_"<>token
      names=["ecxbridgew","ecxbridger","ecxbridges",owner]
      label="ecx-install:"<>token
  bracket (PG.connect settings) PG.close $ \admin->do
    locked<-O.runSelect admin $ pure (Column(E.FunExpr "pg_catalog.pg_try_advisory_lock"
      [unColumn(O.sqlInt4 1162041393),unColumn(O.sqlInt4 19)]) :: O.Field O.SqlBool)
    require (locked==[True]) "database_provisioning_busy"
    PG.withTransaction admin $ do
      roles<-O.runSelect admin $ do
        (name,super,db,role,replication,bypass,login,oid)<-O.selectTable rolesTable
        O.where_ (O.in_ (map O.sqlStrictText names) name)
        let comment=Column(E.FunExpr "pg_catalog.shobj_description" [unColumn oid,unColumn(O.sqlStrictText "pg_authid")]) :: O.FieldNullable O.SqlText
        pure (name,super O..|| db O..|| role O..|| replication O..|| bypass,login,comment)
        :: IO [(Text,Bool,Bool,Maybe Text)]
      if null roles then do
        -- An existing database is never adopted merely because roles are absent.
        databases<-databaseOwners admin
        require (null databases) "foreign_installation_database"
        forM_ names $ \name->do
          void $ PG.execute admin (if name==owner
            then "CREATE ROLE ? NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
            else "CREATE ROLE ? LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS") (PG.Only $ Identifier name)
          void $ PG.execute admin "COMMENT ON ROLE ? IS ?" (Identifier name,label)
      else require (length roles==4 && all (\(name,privileged,login,comment)->
        not privileged && login==(name/=owner) && comment==Just label) roles) "foreign_installation_roles"
    databases<-databaseOwners admin
    case databases of
      []->void $ PG.execute admin "CREATE DATABASE ecx_bridge OWNER ? TEMPLATE template0 ALLOW_CONNECTIONS false" (PG.Only $ Identifier owner)
      [saved] | saved==owner->pure ()
      _->reject "foreign_installation_database"
    PG.withTransaction admin $ do
      void $ PG.execute_ admin "REVOKE ALL ON DATABASE ecx_bridge FROM PUBLIC"
      void $ PG.execute_ admin "ALTER DATABASE ecx_bridge ALLOW_CONNECTIONS true"
    bracket (PG.connect settings {PG.connectDatabase="ecx_bridge"}) PG.close $ \target->PG.withTransaction target $ do
      schemas<-O.runSelect target $ do
        (_,name)<-O.selectTable namespaces
        O.where_ (name O..== O.sqlStrictText "ecx_install")
        pure name
        :: IO [Text]
      if null schemas then do
        existing<-O.runSelect target $ O.limit 1 $ do
          (_,namespace,_)<-O.selectTable relations
          (oid,name)<-O.selectTable namespaces
          O.where_ (namespace O..== oid O..&& name O..== O.sqlStrictText "public")
          pure name
          :: IO [Text]
        require (null existing) "unrecognized_installation_schema"
        void $ PG.execute_ target "CREATE SCHEMA ecx_install AUTHORIZATION postgres; REVOKE ALL ON SCHEMA ecx_install FROM PUBLIC; CREATE TABLE ecx_install.receipt(token text PRIMARY KEY, migration_hash text NOT NULL); REVOKE ALL ON ecx_install.receipt FROM PUBLIC"
        forM_ scripts $ \(_,sql)->void $ PG.execute_ target (Query sql)
        count<-O.runInsert target O.Insert {O.iTable=receipt,O.iRows=[(O.sqlStrictText token,O.sqlStrictText checksum)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        require (count==1) "installation_receipt_failed"
      else do
        saved<-O.runSelect target (O.selectTable receipt) :: IO [(Text,Text)]
        require (saved==[(token,checksum)]) "installation_receipt_mismatch"
      void $ PG.execute_ target "REVOKE ALL ON SCHEMA public FROM PUBLIC; REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC; REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC; GRANT CONNECT ON DATABASE ecx_bridge TO ecxbridgew,ecxbridger,ecxbridges; GRANT USAGE ON SCHEMA public TO ecxbridgew,ecxbridger,ecxbridges; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO ecxbridgew; GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO ecxbridgew; GRANT SELECT ON ALL TABLES IN SCHEMA public TO ecxbridger,ecxbridges; GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ecxbridger,ecxbridges"

-- Closed recovery setup: grant service roles on an already restored paused ledger.
-- No initialization, database rename or financial-row mutation is permitted.
provisionRestoredDatabase :: PG.ConnectInfo -> Text -> Int64 -> IO ()
provisionRestoredDatabase settings identity sequenceNo=do
  let name=T.pack $ PG.connectDatabase settings
  require (PG.connectUser settings=="postgres" && sequenceNo>=0 && T.length name==44
    && "ecx_restore_" `T.isPrefixOf` name
    && T.all (`elem` ("0123456789abcdef"::String)) (T.drop 12 name)) "invalid_restored_database_target"
  bracket (PG.connect settings) PG.close $ \db->PG.withTransaction db $ do
    claimWorker db >>= flip require "worker_already_running"
    rows<-O.runSelect db (O.selectTable S.deployment) :: IO [S.Deployment]
    require (case rows of
      [r]->S.singleton r==1 && S.schemaVersion r==22 && S.fingerprint r==identity
        && S.criticalSequence r==sequenceNo && S.paused r==1
        && S.pauseReason r=="restored_requires_reconciliation"
      _->False) "restored_database_identity_or_state_mismatch"
    forM_ ["ecxbridgew","ecxbridger","ecxbridges"] $ \role->do
      present<-O.runSelect db $ do
        (n,super,createDB,createRole,replication,bypass,login,_)<-O.selectTable rolesTable
        O.where_ (n O..== O.sqlStrictText role)
        pure (super O..|| createDB O..|| createRole O..|| replication O..|| bypass,login)
        :: IO [(Bool,Bool)]
      case present of
        []->void $ PG.execute db "CREATE ROLE ? LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS" (PG.Only $ Identifier role)
        [(False,True)]->pure ()
        _->reject "unsafe_restored_service_role"
      memberships<-O.runSelect db $ do
        (n,_,_,_,_,_,_,oid)<-O.selectTable rolesTable
        member<-O.selectTable $ O.tableWithSchema "pg_catalog" "pg_auth_members" (O.requiredTableField "member")
        O.where_ (n O..== O.sqlStrictText role O..&& member O..== oid)
        pure n
        :: IO [Text]
      require (null memberships) "inherited_restored_service_role"
    void $ PG.execute db "REVOKE ALL ON DATABASE ? FROM PUBLIC" (PG.Only $ Identifier name)
    void $ PG.execute db "GRANT CONNECT ON DATABASE ? TO ecxbridgew,ecxbridger,ecxbridges" (PG.Only $ Identifier name)
    void $ PG.execute_ db "REVOKE ALL ON SCHEMA public FROM PUBLIC; REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC; REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC; GRANT USAGE ON SCHEMA public TO ecxbridgew,ecxbridger,ecxbridges; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO ecxbridgew; GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO ecxbridgew; GRANT SELECT ON ALL TABLES IN SCHEMA public TO ecxbridger,ecxbridges; GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ecxbridger,ecxbridges"
    forM_ ["ecxbridger","ecxbridges"] $ \role->do
      void $ PG.execute db "SET LOCAL ROLE ?" (PG.Only $ Identifier role)
      verifyReadRole db >>= flip require "unsafe_restored_reader_role"
      void $ PG.execute_ db "RESET ROLE"

data SqlOid
type Oid=O.Field SqlOid
type Txt=O.Field O.SqlText
type Flag=O.Field O.SqlBool
rolesTable :: O.Table (Txt,Flag,Flag,Flag,Flag,Flag,Flag,Oid) (Txt,Flag,Flag,Flag,Flag,Flag,Flag,Oid)
rolesTable=O.tableWithSchema "pg_catalog" "pg_roles" $ p8
  (O.requiredTableField "rolname",O.requiredTableField "rolsuper",O.requiredTableField "rolcreatedb",O.requiredTableField "rolcreaterole"
  ,O.requiredTableField "rolreplication",O.requiredTableField "rolbypassrls",O.requiredTableField "rolcanlogin",O.requiredTableField "oid")
namespaces :: O.Table (Oid,Txt) (Oid,Txt)
namespaces=O.tableWithSchema "pg_catalog" "pg_namespace" $ p2 (O.requiredTableField "oid",O.requiredTableField "nspname")
relations :: O.Table (Oid,Oid,Txt) (Oid,Oid,Txt)
relations=O.tableWithSchema "pg_catalog" "pg_class" $ p3 (O.requiredTableField "oid",O.requiredTableField "relnamespace",O.requiredTableField "relname")
receipt :: O.Table (Txt,Txt) (Txt,Txt)
receipt=O.tableWithSchema "ecx_install" "receipt" $ p2 (O.requiredTableField "token",O.requiredTableField "migration_hash")
databaseOwners :: PG.Connection -> IO [Text]
databaseOwners c=O.runSelect c $ do
  (name,owner)<-O.selectTable $ O.tableWithSchema "pg_catalog" "pg_database" $ p2 (O.requiredTableField "datname",O.requiredTableField "datdba")
  (role,_,_,_,_,_,_,oid)<-O.selectTable rolesTable
  O.where_ (name O..== O.sqlStrictText "ecx_bridge" O..&& owner O..== oid)
  pure role
