-- Actual host locks/fsync and two disposable PostgreSQL databases. No chains.
module Main (main) where
import Bridge.Types
import Bridge.Postgres.Ledger
import qualified Bridge.Postgres.Fence as Fence
import Control.Exception (bracket,try)
import Control.Monad (when)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString as BS
import System.Environment (getArgs,getExecutablePath)
import System.FilePath ((</>))
import System.Directory (renameFile,removeFile)
import System.Posix.Files (setFileMode,createSymbolicLink)
import System.Posix.User (getEffectiveUserName)
import System.Process (readProcess)
import System.Timeout (timeout)
import qualified Database.PostgreSQL.Simple as PG

expect :: Text -> IO () -> IO ()
expect code action=do
  result <- try action :: IO(Either BridgeError ())
  require (case result of Left(BridgeError value)->value==code; _->False) ("fence_contract_expected:"<>code)

connection :: String -> IO PG.ConnectInfo
connection database=do
  user <- getEffectiveUserName
  pure PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}

main :: IO ()
main=getArgs >>= \case
  ["competing-worker",directory,identity,database]->do
    settings <- connection database
    expect "worker_fence_locked" $ Fence.withFence directory (T.pack identity) $ \guard->
      withGuardedLedger settings (T.pack identity) (Just guard) (const $ pure ())
    putStrLn "competing worker refused"
  [first,second,directory]->do
    let identity=T.replicate 64 "c"
        filename=directory </> "sequence.json"
    a <- connection first
    b <- connection second
    Fence.initializeFence directory identity 0
    original <- BS.readFile filename
    expect "worker_fence_already_initialized" $ Fence.initializeFence directory identity 0
    BS.readFile filename >>= \value->require (value==original) "fence_initialization_replaced_state"
    Fence.withFence directory identity $ \advance->do
      expect "worker_fence_locked" $ Fence.withFence directory identity (const $ pure ())
      executable <- getExecutablePath
      output <- timeout 10000000 $ readProcess executable ["competing-worker",directory,T.unpack identity,second] ""
      require (output==Just "competing worker refused\n") "cross_database_worker_lock_failed"
      let beforeCommit sequenceNo=do
            advance sequenceNo
            when (sequenceNo==1) $ bracket (PG.connect a) PG.close $ \c->do
              rows <- PG.query_ c "SELECT critical_sequence FROM deployment" :: IO [PG.Only Int64]
              require (rows==[PG.Only 0]) "fence_was_not_persisted_before_commit"
      withGuardedLedger a identity (Just beforeCommit) $ \ledger->do
        value <- ledgerAction ledger criticalSequence
        require (value==1) "fence_contract_sequence_not_committed"
    -- The same owner/keys could otherwise start against another cloned DB.
    expect "stale_ledger_below_worker_fence" $ Fence.withFence directory identity $ \guard->
      withGuardedLedger b identity (Just guard) (const $ pure ())
    bracket (PG.connect b) PG.close $ \c->do
      rows <- PG.query_ c "SELECT count(*) FROM audit" :: IO [PG.Only Int64]
      require (rows==[PG.Only 0]) "stale_startup_mutated_ledger"
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
