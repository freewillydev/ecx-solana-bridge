module Bridge.Worker (runWorker, runTestWorker, runWorkerWith, scanOnce, reconcileOnce, recoverOnce, allocateTestOperating, approveRetry, cancelUnsigned, approveRestoredSource, coverLoss, draftReplacement, cancelReplacement, doctor) where

import Bridge.API
import Control.Monad.IO.Class (liftIO)
import Bridge.Config
import Bridge.Deposit (prepareSolanaDeposit)
import Bridge.Ledger
import Bridge.Native
import Bridge.Observer
import Bridge.Order (createCustomerOrder)
import Bridge.RPC
import Bridge.Reconciliation
import Bridge.Recovery
import Bridge.Solana
import Bridge.Settlement
import Bridge.Types
import Bridge.Web
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent (threadDelay)
import Control.Exception (try,bracket,catch,IOException)
import Control.Monad (forever,when)
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (open,close)
import Network.HTTP.Client (Manager)
import Servant

-- Canonical intake remains unavailable. The explicit test-worker command below
-- runs the same application against public Signet/Devnet with configured limits.
implementationReady :: Bool
implementationReady = False
bearer :: Text -> IO Text
bearer header = case T.stripPrefix "Bearer " header of
  Just token -> either reject (const $ pure token) (capabilityHash token)
  Nothing -> reject "authorization_required"
runWorker :: Config -> IO ()
runWorker c = do
  manager <- newRpcManager
  runWorkerWith c $ \ledger -> forever $ do
    _ <- recoverDeployment manager c ledger
    when implementationReady $ do
      result <- try (paymentPass manager c ledger (const $ reject "critical_backup_not_configured")
        `catch` ioFailure) :: IO (Either BridgeError ())
      case result of
        Right () -> pure ()
        Left (BridgeError code) -> pause ledger code
    threadDelay 15000000
 where
  ioFailure :: IOException -> IO ()
  ioFailure _=reject "payment_io_requires_reconciliation"

runTestWorker :: Config -> IO ()
runTestWorker c=do
  require (profile c==L2LSignetDevnet && not (backupRequired c)) "public_test_profile_required"
  manager <- newRpcManager
  runWorkerWithMode True c $ \ledger->do
    checked ledger $ do
      _ <- recoverDeployment manager c ledger
      epochSeconds >>= checkCustodyFresh ledger
      resumeAfterChecks ledger
    forever $ do
      checked ledger $ do
        _ <- recoverDeployment manager c ledger
        health <- readiness ledger
        fresh <- try (epochSeconds >>= checkCustodyFresh ledger) :: IO (Either BridgeError ())
        case fresh of
          Right ()->when (available health) $ paymentPass manager c ledger (const $ reject "unexpected_test_backup")
          Left (BridgeError "custody_not_reconciled")->pure ()
          Left (BridgeError reason)->reject reason
      threadDelay 15000000
 where
  checked ledger action=do
    result <- try (action `catch` (\(_::IOException)->reject "test_worker_io_unavailable")) :: IO (Either BridgeError ())
    case result of
      Right ()->pure ()
      Left (BridgeError reason)->pause ledger reason

-- The socket tests supply an idle observer; the runtime always uses the real
-- adapters above. This seam does not expose a selectable substitute chain.
runWorkerWith :: Config -> (Ledger -> IO ()) -> IO ()
runWorkerWith = runWorkerWithMode False

runWorkerWithMode :: Bool -> Config -> (Ledger -> IO ()) -> IO ()
runWorkerWithMode testMode c observer = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  pause ledger "implementation_acceptance_pending"
  manager <- newRpcManager
  customer <- securityBoundary (serve customerAPI (customerServer testMode manager c ledger))
  admin <- securityBoundary (serve adminAPI (adminServer c ledger))
  concurrently_ (concurrently_ (runUnix (customerSocket c) 0o660 customer) (runUnix (adminSocket c) 0o600 admin)) (observer ledger)

scanOnce :: Config -> IO Value
scanOnce c = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  observeOnce manager c ledger
reconcileOnce :: Config -> IO Value
reconcileOnce c = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  _ <- observeOnce manager c ledger
  reconcileCustody manager c ledger
recoverOnce :: Config -> IO Value
recoverOnce c = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  recoverDeployment manager c ledger
allocateTestOperating :: Config -> Text -> Amount -> IO Value
allocateTestOperating c signature quantity=do
  require (profile c==L2LSignetDevnet && not (backupRequired c)) "public_test_profile_required"
  withLedger (dbPath c) (fingerprint c) $ \ledger->do
    manager <- newRpcManager
    _ <- recoverDeployment manager c ledger
    epochSeconds >>= checkCustodyFresh ledger
    allocateSolOperatingReceipt ledger signature quantity
    custody <- reconcileCustody manager c ledger
    pure $ object ["allocatedSignature" .= signature,"lamports" .= quantity,"custody" .= custody,"paused" .= True,"signedOrSent" .= False]
approveRetry :: Config -> Text -> Text -> IO Value
approveRetry c txid reason = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  approveSolanaRetry manager c ledger txid reason
  pure $ object ["approvedRetryOf" .= txid,"paused" .= True,"signedOrSent" .= False]
cancelUnsigned :: Config -> Text -> Int -> Text -> IO Value
cancelUnsigned c intent generation reason = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  cancelPreparation manager c ledger intent generation reason
approveRestoredSource :: Config -> Text -> Int64 -> Text -> IO Value
approveRestoredSource c intent restoration reason = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  approveSourceRecovery manager c ledger intent restoration reason
coverLoss :: Config -> Text -> Int64 -> Amount -> Amount -> Text -> IO Value
coverLoss c did recovery fromFloat fromEarned reason = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  coverSourceLoss manager c ledger did recovery (LossCapital fromFloat fromEarned) reason
draftReplacement :: Config -> Text -> Amount -> Text -> IO Value
draftReplacement c parent fee reason=withLedger (dbPath c) (fingerprint c) $ \ledger->do
  manager <- newRpcManager
  prepareNativeReplacement manager c ledger parent fee reason
cancelReplacement :: Config -> Int64 -> Text -> IO Value
cancelReplacement c sequenceNo reason=withLedger (dbPath c) (fingerprint c) $ \ledger->do
  recordNativeReplacementCancellation ledger sequenceNo reason
  pure $ object ["cancelledDraftSequence" .= sequenceNo,"paused" .= True,"signedOrSent" .= False]
customerServer :: Bool -> Manager -> Config -> Ledger -> Server CustomerAPI
customerServer testMode manager c ledger =
  configView :<|> create :<|> get :<|> transaction :<|> hint :<|> health :<|> ready
 where
  configView = do
    a <- liftIO publicAvailability
    pure $ object ["profile" .= profile c,"deployment" .= deploymentId c,"mint" .= mint c,"decimals" .= (8::Int),"minInput" .= minInput c,"maxInput" .= maxInput c,"feesBps" .= object ["NativeToWrapped" .= (20::Int),"WrappedToNative" .= (100::Int)],"availability" .= a,"intakeEnabled" .= testMode,"implementationReady" .= implementationReady,"walletsTested" .= ([]::[Text])]
  create header request = asHandler $ do
    token <- bearer header
    require testMode "implementation_acceptance_pending"
    createCustomerOrder manager c ledger (const $ reject "unexpected_test_backup") token request
  get oid header = asHandler $ bearer header >>= \token -> exposeOrder ledger (backupRequired c) token oid
  transaction oid header = asHandler $ do
    token <- bearer header
    _ <- exposeOrder ledger (backupRequired c) token oid
    require testMode "implementation_acceptance_pending"
    prepareSolanaDeposit manager c ledger token oid
  hint oid header h = asHandler $ do
    token <- bearer header
    addHint ledger token oid (signature h)
    pure $ object ["accepted" .= True,"authorization" .= ("independent_chain_evidence_required"::Text)]
  health = pure (Availability True "process_running")
  ready = do
    a <- liftIO publicAvailability
    if available a then pure a else throwError err503 {errBody=encode a}
  publicAvailability = do
    a <- readiness ledger
    if not testMode || not (available a) then pure a else do
      result <- try (epochSeconds >>= checkIntakeReady ledger) :: IO (Either BridgeError ())
      pure $ case result of Right ()->a; Left (BridgeError reason)->Availability False reason
adminServer :: Config -> Ledger -> Server AdminAPI
adminServer c l = asHandler (readiness l)
  :<|> (\p -> asHandler (pause l (T.take 120 (pauseReason p)) >> readiness l))
  :<|> asHandler (auditExportWithBudget l c)
  :<|> asHandler (scannerHealth l)
doctor :: Config -> IO Value
doctor c = do
  manager <- newRpcManager
  native <- try (nativeIdentity manager c) :: IO (Either BridgeError Value)
  solana <- try (solanaIdentity manager c) :: IO (Either BridgeError Value)
  database <- try (bracket (open ":memory:") close sqliteIdentity) :: IO (Either BridgeError Value)
  let report (Right evidence) = object ["ok" .= True,"evidence" .= evidence]
      report (Left (BridgeError code)) = object ["ok" .= False,"error" .= code]
  pure $ object ["profile" .= profile c,"fingerprint" .= fingerprint c,"native" .= report native,"solana" .= report solana,"database" .= report database,"implementationReady" .= implementationReady]
