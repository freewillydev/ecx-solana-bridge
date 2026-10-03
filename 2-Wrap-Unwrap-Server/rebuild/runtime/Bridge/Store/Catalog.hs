-- Fixed catalog expressions extracted from the baseline; no caller SQL.
module Bridge.Store.Catalog (verifyReadRole, claimWorker) where
import Data.Profunctor.Product (p2,p3,p6)
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import Opaleye.Internal.Column (Field_(Column),unColumn)
import qualified Opaleye.Internal.HaskellDB.PrimQuery as Expr

-- PostgreSQL OIDs are used only inside the query, never decoded or fabricated.
data SqlOid
type Relation = (O.Field SqlOid,O.Field SqlOid,O.Field O.SqlText)
type Namespace = (O.Field SqlOid,O.Field O.SqlText)

verifyReadRole :: PG.Connection -> IO Bool
verifyReadRole connection = do
  roles <- O.runSelect connection $ do
    (name,super,createDB,createRole,replication,bypassRLS) <- O.selectTable $
      O.tableWithSchema "pg_catalog" "pg_roles" $ p6
        (O.requiredTableField "rolname",O.requiredTableField "rolsuper",
         O.requiredTableField "rolcreatedb",O.requiredTableField "rolcreaterole",
         O.requiredTableField "rolreplication",O.requiredTableField "rolbypassrls")
    O.where_ (name O..== currentUser)
    pure (O.not (super O..|| createDB O..|| createRole O..|| replication O..|| bypassRLS O..|| schemaCreate))
  writable <- O.runSelect connection $ O.limit 1 $ do
    (oid,namespace,kind) <- O.selectTable relations
    (namespaceOid,name) <- O.selectTable namespaces
    O.where_ (namespace O..== namespaceOid O..&& name O..== O.sqlStrictText "public")
    O.where_ (O.in_ (map O.sqlStrictText ["r","p","v","m","f","S"]) kind)
    O.where_ (O.ifThenElse (kind O..== O.sqlStrictText "S") (sequenceWrite oid) (tableWrite oid))
    pure (O.sqlBool True)
  pure (roles==[True] && null (writable :: [Bool]))
 where
  relations :: O.Table Relation Relation
  relations = O.tableWithSchema "pg_catalog" "pg_class" $ p3
    (O.requiredTableField "oid",O.requiredTableField "relnamespace",O.requiredTableField "relkind")
  namespaces :: O.Table Namespace Namespace
  namespaces = O.tableWithSchema "pg_catalog" "pg_namespace" $
    p2 (O.requiredTableField "oid",O.requiredTableField "nspname")

-- Fixed PostgreSQL built-ins absent from Opaleye's public API. These bindings
-- have no caller-supplied SQL or function name. Privilege checks implicitly use
-- current_user, including inherited permissions, as PostgreSQL specifies.
currentUser :: O.Field O.SqlText
currentUser = Column (Expr.ConstExpr (Expr.OtherLit "CURRENT_USER"))

schemaCreate :: O.Field O.SqlBool
schemaCreate = Column (Expr.FunExpr "pg_catalog.has_schema_privilege"
  [unColumn (O.sqlStrictText "public"),unColumn (O.sqlStrictText "CREATE")])

sequenceWrite :: O.Field SqlOid -> O.Field O.SqlBool
sequenceWrite oid = Column (Expr.FunExpr "pg_catalog.has_sequence_privilege"
  [unColumn oid,unColumn (O.sqlStrictText "USAGE,UPDATE")])

tableWrite :: O.Field SqlOid -> O.Field O.SqlBool
tableWrite oid = Column (Expr.FunExpr "pg_catalog.has_table_privilege"
  [unColumn oid,unColumn (O.sqlStrictText "INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER")])
  O..|| Column (Expr.FunExpr "pg_catalog.has_any_column_privilege"
    [unColumn oid,unColumn (O.sqlStrictText "INSERT,UPDATE,REFERENCES")])


claimWorker :: PG.Connection -> IO Bool
claimWorker connection = do
  claimed <- O.runSelect connection $ pure (Column (Expr.FunExpr "pg_catalog.pg_try_advisory_lock"
    [unColumn (O.sqlInt4 1162041393),unColumn (O.sqlInt4 18)]) :: O.Field O.SqlBool)
  pure (claimed==[True])
