{-# LANGUAGE ScopedTypeVariables #-}
-- Owns an unfunded temporary PostgreSQL cluster; never uses the caller's PG* DB.
module ProvisionCheck (contract) where
import Bridge.Store
import qualified Bridge.Store.Schema as S
import Bridge.Store.Catalog (verifyReadRole)
import Control.Exception
import Control.Monad (forM_,void,unless)
import qualified Data.ByteString.Char8 as B
import Data.Profunctor.Product (p2)
import Data.Int (Int64)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import Paths_ecx_bridge (getDataFileName)
import System.Directory
import System.Environment (lookupEnv,setEnv,unsetEnv)
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode)
import System.Process (callProcess)
import Test.QuickCheck (quickCheckWithResult,stdArgs,maxSuccess,ioProperty,isSuccess)

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
  putStrLn "PASS: foreign role/database refusal, migration rollback, same-token retry, changed-migration refusal, read-only roles and initialized ledger/observation preservation"
 where
  check True=pure ()
  check False=fail "provisioning invariant failed"
  tables :: O.Table (O.Field O.SqlText,O.Field O.SqlText) (O.Field O.SqlText,O.Field O.SqlText)
  tables=O.tableWithSchema "information_schema" "tables" $ p2(O.requiredTableField "table_schema",O.requiredTableField "table_name")
