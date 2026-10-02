{-# LANGUAGE GADTs #-}
-- Actual host locks/fsync and two disposable PostgreSQL databases. No chains.
module FenceCheck (run) where
import Bridge.Config (Config(..),loadConfig,publicTestProfile)
import Data.Aeson (encode,eitherDecode,object,(.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import System.Exit (ExitCode(..))
import Bridge.Types
import Bridge.Postgres.Schema
import qualified Opaleye as O
import Bridge.Postgres.Ledger
import qualified Bridge.Postgres.Fence as Fence
import Control.Exception (bracket,try)
import Control.Monad (when,void)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString as BS
import System.Environment (getArgs,getExecutablePath,getEnvironment)
import System.FilePath ((</>))
import System.Directory (renameFile,removeFile,createDirectory,doesPathExist)
import System.Posix.Files (setFileMode,createSymbolicLink)
import System.Posix.User (getEffectiveUserName)
import System.Process (readProcess,readCreateProcessWithExitCode,proc,CreateProcess(..))
import System.Timeout (timeout)
import qualified Database.PostgreSQL.Simple as PG

expect :: Text -> IO () -> IO ()
expect code action=do
  result <- try action :: IO(Either BridgeError ())
  require (case result of Left(BridgeError value)->value==code; _->False) ("fence_contract_expected:"<>code)

settingsFor :: String -> IO PG.ConnectInfo
settingsFor database=do
  require ("ecx_fence_contract_" `T.isPrefixOf` T.pack database) "disposable_fence_database_required"
  user <- getEffectiveUserName
  pure PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}

run :: IO ()
run=getArgs >>= \case
  ["runtime",binary,config,database,directory]->runtimeContract binary config database directory
  ["competing-worker",directory,identity,database]->do
    settings <- settingsFor database
    expect "worker_fence_locked" $ Fence.withFence directory (T.pack identity) $ \guard->
      withGuardedLedger settings (T.pack identity) (Just guard) (const $ pure ())
    putStrLn "competing worker refused"
  [first,second,directory]->do
    let identity=T.replicate 64 "c"
        filename=directory </> "sequence.json"
    require (first/=second) "distinct_fence_databases_required"
    a <- settingsFor first
    b <- settingsFor second
    mapM_ (\settings->bracket (PG.connect settings) PG.close $ \c->
      PG.withTransaction c (fixture c $ Initialize identity)) [a,b]
    Fence.initializeFence directory identity 0
    original <- BS.readFile filename
    expect "worker_fence_already_initialized" $ Fence.initializeFence directory identity 0
    BS.readFile filename >>= \value->require (value==original) "fence_initialization_replaced_state"
    Fence.withFence directory identity $ \advance->do
      expect "worker_fence_locked" $ Fence.withFence directory identity (const $ pure ())
      executable <- getExecutablePath
      output <- timeout 10000000 $ readProcess executable ["fence","competing-worker",directory,T.unpack identity,second] ""
      require (output==Just "competing worker refused\n") "cross_database_worker_lock_failed"
      let beforeCommit sequenceNo=do
            advance sequenceNo
            when (sequenceNo==1) $ bracket (PG.connect a) PG.close $ \c->do
              rows <- fixture c ReadSequence
              require (rows==[0]) "fence_was_not_persisted_before_commit"
      withGuardedLedger a identity (Just beforeCommit) $ \ledger->do
        value <- ledgerAction ledger criticalSequence
        require (value==1) "fence_contract_sequence_not_committed"
    -- The same owner/keys could otherwise start against another cloned DB.
    expect "stale_ledger_below_worker_fence" $ Fence.withFence directory identity $ \guard->
      withGuardedLedger b identity (Just guard) (const $ pure ())
    bracket (PG.connect b) PG.close $ \c->do
      rows <- fixture c ReadAudit
      require (null rows) "stale_startup_mutated_ledger"
    expect "worker_fence_identity_mismatch" $ Fence.withFence directory (T.replicate 64 "d") (const $ pure ())
    setFileMode filename 0o604
    expect "unsafe_worker_fence_permissions" $ Fence.withFence directory identity (const $ pure ())
    setFileMode filename 0o600
    renameFile filename (directory </> "saved.json")
    createSymbolicLink (directory </> "saved.json") filename
    expect "unsafe_worker_fence_permissions" $ Fence.withFence directory identity (const $ pure ())
    removeFile filename
    renameFile (directory </> "saved.json") filename
    -- An uncertain failure AFTER the durable watermark cannot silently permit
    -- the rolled-back database. This is injected at the real commit boundary.
    Fence.withFence directory identity $ \advance->do
      let uncertain sequenceNo=do
            advance sequenceNo
            when (sequenceNo==2) $ reject "contract_uncertain_commit"
      withGuardedLedger a identity (Just uncertain) $ \ledger->
        expect "contract_uncertain_commit" $ ledgerAction ledger criticalSequence >> pure ()
    expect "stale_ledger_below_worker_fence" $ Fence.withFence directory identity $ \guard->
      withGuardedLedger a identity (Just guard) (const $ pure ())
    latest <- BS.readFile filename
    Fence.withFence directory identity $ \advance->do
      expect "stale_ledger_below_worker_fence" $ advance 1
      advance 2
    BS.readFile filename >>= \value->require (value==latest) "equal_fence_sequence_rewritten"
    Fence.retireFence directory identity 2
    retired <- BS.readFile filename
    expect "worker_fence_retired" $ Fence.withFence directory identity (const $ pure ())
    Fence.retireFence directory identity 2
    expect "worker_fence_already_initialized" $ Fence.initializeFence directory identity 0
    BS.readFile filename >>= \value->require (value==retired) "retired_fence_reactivated_or_rewritten"
    putStrLn "Host fence: same-process/cross-process/cross-database ownership, precommit durability, stale/identity/permission/symlink refusal, retained uncertain-commit watermark, retirement and idempotence passed; no chain or signer"
  _->reject "fence_contract_arguments_required"

-- Fixed fixture operations only; no row SQL or query callback from the runner.
data Fixture a where
  RequireEmpty :: Fixture ()
  Initialize :: Text -> Fixture ()
  SetSequence :: Int64 -> Fixture ()
  ReadSequence :: Fixture [Int64]
  ReadAudit :: Fixture [Audit]

fixture :: PG.Connection -> Fixture a -> IO a
fixture connection = \case
  RequireEmpty -> do
    rows <- O.runSelect connection (O.selectTable deploymentTable) :: IO [Deployment]
    require (null rows) "fresh_fence_database_required"
  Initialize identity -> do
    fixture connection RequireEmpty
    void $ O.runInsert connection O.Insert
      {O.iTable=deploymentTable,O.iRows=[Deployment (O.sqlInt8 1) (O.sqlInt8 18) (O.sqlStrictText identity)
        (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "fence contract")]
      ,O.iReturning=O.rCount,O.iOnConflict=Nothing}
  SetSequence n -> void $ O.runUpdate connection O.Update
    {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentCriticalSequence=O.sqlInt8 n}
    ,O.uWhere= \row->deploymentSingleton row O..== O.sqlInt8 1,O.uReturning=O.rCount}
  ReadSequence -> O.runSelect connection (fmap deploymentCriticalSequence $ O.selectTable deploymentTable)
  ReadAudit -> O.runSelect connection (O.selectTable auditTable)

-- Exercise the installed command boundary as well as the fence implementation.
-- Caller supplies a fresh migrated DB, SELECT-only PGREADUSER and unused directory.
runtimeContract :: FilePath -> FilePath -> String -> FilePath -> IO ()
runtimeContract binary config database directory = do
  settings <- settingsFor database
  exists <- doesPathExist directory
  require (not exists) "fresh_fence_directory_required"
  createDirectory directory
  setFileMode directory 0o700
  original <- loadConfig config
  require (publicTestProfile original) "public_test_profile_required"
  let cfg=original {deploymentId="ecx-fence-runtime-contract",customerSocket=directory </> "customer.sock",adminSocket=directory </> "admin.sock"}
      configPath=directory </> "config.json"
      watermark=directory </> "fence/sequence.json"
      save value=LBS.writeFile configPath (encode value) >> setFileMode configPath 0o600
  save cfg
  environment <- getEnvironment
  let overrides=[("PGHOST",PG.connectHost settings),("PGPORT",show $ PG.connectPort settings)
        ,("PGDATABASE",database),("PGUSER",PG.connectUser settings),("ECX_WORKER_FENCE_DIR",directory </> "fence")]
      childEnvironment=overrides<>filter (\(key,_)->key `notElem` map fst overrides && key `notElem` ["PGPASSWORD","ECX_INTERFACE_CONFIG","ECX_PORT"]) environment
      command name expected = do
        result <- timeout 10000000 $ readCreateProcessWithExitCode
          (proc binary [name,configPath]) {env=Just childEnvironment} ""
        case (result,expected) of
          (Just(ExitSuccess,_,_),Nothing)->pure ()
          (Just(ExitFailure _,output,_),Just code)->require
            (eitherDecode (LBS.pack output)==Right(object["error" .= code])) ("fence_cli_expected:"<>code)
          _->reject ("fence_cli_failed:"<>T.pack name)
      mutate n=bracket (PG.connect settings) PG.close $ \c->PG.withTransaction c (fixture c $ SetSequence n)
      audit=bracket (PG.connect settings) PG.close (\c->fixture c ReadAudit)
  bracket (PG.connect settings) PG.close (\c->fixture c RequireEmpty)
  command "postgres-init" Nothing
  command "postgres-test-worker" (Just "worker_fence_not_initialized")
  mutate 1
  command "postgres-init-worker-fence" Nothing
  saved <- BS.readFile watermark
  command "postgres-init-worker-fence" (Just "worker_fence_already_initialized")
  mutate 0
  before <- audit
  command "postgres-test-worker" (Just "stale_ledger_below_worker_fence")
  command "test-worker" (Just "stale_ledger_below_worker_fence")
  command "scan" (Just "local_operator_command_required")
  after <- audit
  require (before==after) "stale_cli_mutated_ledger"
  BS.readFile watermark >>= \bytes->require (bytes==saved) "stale_cli_changed_watermark"
  save cfg {deploymentId="different-fence-identity"}
  command "postgres-test-worker" (Just "worker_fence_identity_mismatch")
  save cfg
  mutate 1
  command "postgres-retire-worker" Nothing
  retired <- BS.readFile watermark
  command "postgres-test-worker" (Just "worker_fence_retired")
  command "postgres-init-worker-fence" (Just "worker_fence_already_initialized")
  BS.readFile watermark >>= \bytes->require (bytes==retired) "retired_cli_changed_watermark"
  mapM_ (\path->doesPathExist path >>= \opened->require (not opened) "fenced_cli_opened_api") [customerSocket cfg,adminSocket cfg]
  putStrLn "Worker CLI: missing/stale/identity/retired fences, aliases, unchanged journal/watermark and unopened API passed; no chain or signer"
