{-# LANGUAGE ScopedTypeVariables #-}
-- Owns an unfunded temporary PostgreSQL cluster; never uses the caller's PG* DB.
module ProvisionCheck (contract,child) where
import Bridge.Store
import qualified Bridge.Store.Backup as Backup
import qualified Bridge.Store.Schema as S
import Bridge.Store.Catalog (verifyReadRole)
import Control.Exception
import Control.Concurrent (threadDelay)
import Control.Monad (forM_,void,unless)
import qualified Data.ByteString.Char8 as B
import Data.Profunctor.Product (p2,p3)
import Data.List (sort,isInfixOf)
import Data.Int (Int64)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import Paths_ecx_bridge (getDataFileName)
import System.Directory
import System.Environment (lookupEnv,setEnv,unsetEnv,getExecutablePath,getEnvironment)
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (signalProcess,sigKILL)
import System.Exit (ExitCode(..))
import System.Timeout (timeout)
import System.Process (readProcess,callProcess,withCreateProcess,proc,env,getPid,waitForProcess)
import Test.QuickCheck (quickCheckWithResult,stdArgs,maxSuccess,ioProperty,isSuccess)

child :: FilePath -> IO ()
child root=evalSetup PG.defaultConnectInfo {PG.connectHost=root,PG.connectPort=29479,PG.connectUser="postgres",PG.connectDatabase="postgres"}
  (ProvisionDatabase "0123456789abcdef0123456789abcdef")

contract :: IO ()
contract=bracket directory removeDirectoryRecursive $ \root->do
  callProcess "initdb" ["-D",root</>"data","-U","postgres","--auth=trust","--no-locale"]
  let control args=callProcess "pg_ctl" (["-D",root</>"data"]<>args)
  bracket_ (control ["-l",root</>"postgres.log","-o","-k "<>root<>" -h '' -p 29479 -c shared_buffers=16MB -c max_connections=12","-w","start"])
    (control ["-m","immediate","-w","stop"]) $ do
      let admin=PG.defaultConnectInfo {PG.connectHost=root,PG.connectPort=29479,PG.connectUser="postgres",PG.connectDatabase="postgres"}
      result<-quickCheckWithResult stdArgs {maxSuccess=1} (ioProperty $ checks root admin >> pure True)
      unless(isSuccess result)(fail "database provisioning contract failed")
 where
  directory=do
    (path,h)<-openTempFile "/tmp" "ecx-provision-"
    hClose h; removeFile path; createDirectory path; setFileMode path 0o700; pure path

checks :: FilePath -> PG.ConnectInfo -> IO ()
checks root admin=bracket(PG.connect admin) PG.close $ \c->do
  let token="0123456789abcdef0123456789abcdef"
      run=evalSetup admin(ProvisionDatabase token)
      ddl sql=void(PG.execute_ c sql)
      refused expected action=(action >> fail "expected refusal") `catch` \(BridgeError actual)->check(actual==expected)
      target=admin {PG.connectDatabase="ecx_bridge"}
  ddl "CREATE ROLE ecxbridgew NOLOGIN"
  refused "foreign_installation_roles" run
  ddl "DROP ROLE ecxbridgew"
  ddl "CREATE DATABASE ecx_bridge"
  refused "foreign_installation_database" run
  ddl "DROP DATABASE ecx_bridge"
  createDirectory(root</>"bad"); createDirectory(root</>"bad/migrations")
  forM_ [1..8::Int] $ \n->do
    let name="migrations/00"<>show n<>".sql"
    bytes<-getDataFileName name >>= B.readFile
    B.writeFile(root</>"bad"</>name) $ if n==8 then B.unlines(concatMap(\line->if line=="COMMIT;" then ["CREATE TABLE deliberately_invalid(;",line] else [line])(B.lines bytes)) else bytes
  prior<-lookupEnv "ecx_bridge_datadir"
  bracket_ (setEnv "ecx_bridge_datadir" (root</>"bad"))
    (maybe(unsetEnv "ecx_bridge_datadir")(setEnv "ecx_bridge_datadir") prior) $
      (run >> fail "invalid migration accepted") `catch` \(_::PG.SqlError)->pure ()
  -- Roles and DB survive; the entire schema+receipt transaction rolls back.
  bracket(PG.connect target) PG.close $ \db->do
    rows<-O.runSelect db $ do
      (schema,name)<-O.selectTable tables
      O.where_ (O.in_ [O.sqlStrictText "public",O.sqlStrictText "ecx_install"] schema)
      pure name
      :: IO [T.Text]
    check(null rows)
  refused "foreign_installation_roles" (evalSetup admin $ ProvisionDatabase "fedcba9876543210fedcba9876543210")
  -- Hold a DDL name collision until the child reaches the final migration, then
  -- kill the actual OS process (no Haskell exception cleanup can run there).
  original<-getDataFileName "migrations/008.sql" >>= B.readFile
  B.writeFile(root</>"bad/migrations/008.sql") $ B.unlines $ concatMap
    (\line->if line=="COMMIT;" then ["CREATE TABLE public.provision_kill_barrier(id integer);",line] else [line]) (B.lines original)
  bracket(PG.connect target) PG.close $ \blocker->do
    PG.begin blocker
    void $ PG.execute_ blocker "CREATE TABLE public.provision_kill_barrier(id integer)"
    bracket_ (setEnv "ecx_bridge_datadir" (root</>"bad"))
      (maybe(unsetEnv "ecx_bridge_datadir")(setEnv "ecx_bridge_datadir") prior) $
      do
        executable<-getExecutablePath
        environment<-getEnvironment
        withCreateProcess (proc executable []) {env=Just(("ECX_PROVISION_CHILD",root):filter((/="ECX_PROVISION_CHILD").fst) environment)} $ \_ _ _ process->do
          let blocked=do
                rows<-O.runSelect c $ do
                  (db,event,query)<-O.selectTable activity
                  O.where_ (db O..== O.sqlStrictText "ecx_bridge" O..&& O.fromNullable (O.sqlStrictText "") event O..== O.sqlStrictText "Lock"
                    O..&& O.like query (O.sqlStrictText "%replacement_schema_mismatch%"))
                  pure query
                  :: IO [T.Text]
                if null rows then threadDelay 20000 >> blocked else pure ()
          reached<-timeout 10000000 blocked
          pid<-getPid process >>= maybe(fail "child exited before interruption") pure
          signalProcess sigKILL pid
          status<-waitForProcess process
          unless(reached==Just ())(fail "child never reached migration008 lock")
          unless(status/=ExitSuccess)(fail "child unexpectedly succeeded before SIGKILL")
    PG.rollback blocker
  -- Wait for the disconnected backend to finish rollback and release its lock.
  let retry=run `catch` \(BridgeError code)->if code=="database_provisioning_busy"
        then threadDelay 20000 >> retry else throwIO(BridgeError code)
  recovered<-timeout 10000000 retry
  unless(recovered==Just ())(fail "killed provisioner retained ownership lock")
  run; run
  evalSetup target(InitializeLedger $ T.replicate 64 "a")
  before<-bracket(PG.connect target) PG.close $ \db->do
    void $ O.runInsert db O.Insert {O.iTable=S.scanHealth,O.iRows=[(O.sqlStrictText "Native",O.toNullable $ O.sqlInt8 42,O.null,O.sqlInt8 42)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    (,) <$> (O.runSelect db $ O.selectTable S.deployment) <*> (O.runSelect db $ O.selectTable S.scanHealth)
      :: IO ([S.Deployment],[(T.Text,Maybe Int64,Maybe T.Text,Int64)])
  run
  after<-bracket(PG.connect target) PG.close $ \db->
    (,) <$> (O.runSelect db $ O.selectTable S.deployment) <*> (O.runSelect db $ O.selectTable S.scanHealth)
  check(before==after)
  bracket_ (setEnv "ecx_bridge_datadir" (root</>"bad"))
    (maybe(unsetEnv "ecx_bridge_datadir")(setEnv "ecx_bridge_datadir") prior) $
      refused "installation_receipt_mismatch" run
  forM_ ["ecxbridger","ecxbridges"] $ \role->
    bracket(PG.connect target {PG.connectUser=role}) PG.close $ \db->verifyReadRole db >>= check
  -- Real provisioning creates ecx_install.receipt, deliberately inaccessible to
  -- the runtime reader. Back up that exact layout, not a migration-only fixture.
  let identity=T.replicate 64 "a"
      readerSettings=target {PG.connectUser="ecxbridger"}
      receiptNames :: PG.Connection -> IO [T.Text]
      receiptNames db=O.runSelect db $ do
        (schema,name)<-O.selectTable tables
        O.where_ (schema O..== O.sqlStrictText "ecx_install")
        pure name
      inventory :: PG.Connection -> IO [[T.Text]]
      inventory db=mapM (\(schema,table,namespace,column)->sort <$> O.runSelect db (do
        (space,name)<-O.selectTable $ O.tableWithSchema schema table $
          p2(O.requiredTableField namespace,O.requiredTableField column)
        O.where_ (space O..== O.sqlStrictText "public")
        pure (name :: O.Field O.SqlText)))
        [("information_schema","tables","table_schema","table_name")
        ,("pg_catalog","pg_sequences","schemaname","sequencename")
        ,("information_schema","routines","routine_schema","routine_name")
        ,("information_schema","table_constraints","constraint_schema","constraint_name")
        ,("information_schema","triggers","trigger_schema","trigger_name")
        ,("pg_catalog","pg_indexes","schemaname","indexname")] :: IO [[T.Text]]
  objects<-bracket(PG.connect target) PG.close $ \db->do
    receiptNames db >>= check . ((==["receipt"]) :: [T.Text]->Bool)
    inventory db
  check(all (not . null) objects)
  archive<-withReader readerSettings identity False $ \reader->evalBackup reader(ExportLedger root)
  listing<-readProcess "pg_restore" ["--list",archivePath archive] ""
  check(not $ "ecx_install" `isInfixOf` listing)
  bracket (evalRestore admin $ RestoreLedger (manifestPath archive) identity 0)
    (\(database,_)->Backup.discardRestore admin {PG.connectDatabase=T.unpack database}) $ \(database,n)->do
      check(n==0 && database/="ecx_bridge")
      let restoredSettings=admin {PG.connectDatabase=T.unpack database}
      refused "restored_database_identity_or_state_mismatch" (evalSetup restoredSettings $ ProvisionRestoredDatabase "wrong" n)
      refused "restored_database_identity_or_state_mismatch" (evalSetup restoredSettings $ ProvisionRestoredDatabase identity (n+1))
      evalSetup restoredSettings (ProvisionRestoredDatabase identity n)
      evalSetup restoredSettings (ProvisionRestoredDatabase identity n)
      forM_ ["ecxbridger","ecxbridges"] $ \role->
        bracket(PG.connect restoredSettings {PG.connectUser=role}) PG.close $ \db->verifyReadRole db >>= check

      bracket(PG.connect admin {PG.connectDatabase=T.unpack database}) PG.close $ \db->do
        inventory db >>= check . (==objects)
        receiptNames db >>= check . null
        restored<-(,) <$> (O.runSelect db $ O.selectTable S.deployment) <*> (O.runSelect db $ O.selectTable S.scanHealth)
        let (rows,observations)=before
        check(restored==([row {S.paused=1,S.pauseReason="restored_requires_reconciliation"} | row<-rows],observations))
  bracket(PG.connect readerSettings) PG.close $ \db->verifyReadRole db >>= check
  putStrLn "PASS: provisioned restricted-reader backup, installer receipt excluded, all public tables/sequences/functions/constraints/triggers/indexes restored, ledger and observation data preserved, paused isolated restore, reader remains restricted"
  putStrLn "PASS: foreign role/database refusal, migration rollback, SIGKILL during migration008 and successful retry, changed-migration refusal, read-only roles and initialized ledger/observation preservation"
 where
  check True=pure ()
  check False=fail "provisioning invariant failed"
  tables :: O.Table (O.Field O.SqlText,O.Field O.SqlText) (O.Field O.SqlText,O.Field O.SqlText)
  tables=O.tableWithSchema "information_schema" "tables" $ p2(O.requiredTableField "table_schema",O.requiredTableField "table_name")
  activity :: O.Table (O.Field O.SqlText,O.FieldNullable O.SqlText,O.Field O.SqlText) (O.Field O.SqlText,O.FieldNullable O.SqlText,O.Field O.SqlText)
  activity=O.tableWithSchema "pg_catalog" "pg_stat_activity" $ p3(O.requiredTableField "datname",O.requiredTableField "wait_event_type",O.requiredTableField "query")
