module Bridge.Worker (runWorker, runWorkerWith, scanOnce, doctor) where

import Bridge.API
import Control.Monad.IO.Class (liftIO)
import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.Observer
import Bridge.RPC
import Bridge.Solana
import Bridge.Settlement
import Bridge.Types
import Bridge.Web
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent (threadDelay)
import Control.Exception (try,bracket,catch,IOException)
import Control.Monad (forever,when)
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (open,close)
import Servant

-- A release without completed settlement/restore acceptance must not accept funds.
-- This gate is deliberately not a configuration switch or a public/admin endpoint.
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
    _ <- observeOnce manager c ledger
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

-- The socket tests supply an idle observer; the runtime always uses the real
-- adapters above. This seam does not expose a selectable substitute chain.
runWorkerWith :: Config -> (Ledger -> IO ()) -> IO ()
runWorkerWith c observer = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  pause ledger "implementation_acceptance_pending"
  customer <- securityBoundary (serve customerAPI (customerServer c ledger))
  admin <- securityBoundary (serve adminAPI (adminServer ledger))
  concurrently_ (concurrently_ (runUnix (customerSocket c) 0o660 customer) (runUnix (adminSocket c) 0o600 admin)) (observer ledger)

scanOnce :: Config -> IO Value
scanOnce c = withLedger (dbPath c) (fingerprint c) $ \ledger -> do
  manager <- newRpcManager
  observeOnce manager c ledger
customerServer :: Config -> Ledger -> Server CustomerAPI
customerServer c ledger =
  configView :<|> create :<|> get :<|> transaction :<|> hint :<|> health :<|> ready
 where
  configView = do
    a <- liftIO (readiness ledger)
    pure $ object ["profile" .= profile c,"deployment" .= deploymentId c,"mint" .= mint c,"decimals" .= (8::Int),"minInput" .= minInput c,"maxInput" .= maxInput c,"feesBps" .= object ["NativeToWrapped" .= (20::Int),"WrappedToNative" .= (100::Int)],"availability" .= a,"implementationReady" .= implementationReady,"walletsTested" .= ([]::[Text])]
  create header _ = asHandler $ bearer header >> reject "implementation_acceptance_pending"
  get oid header = asHandler $ bearer header >>= \token -> exposeOrder ledger (backupRequired c) token oid
  transaction oid header = asHandler $ do
    token <- bearer header
    _ <- exposeOrder ledger (backupRequired c) token oid
    reject "implementation_acceptance_pending"
  hint oid header h = asHandler $ do
    token <- bearer header
    addHint ledger token oid (signature h)
    pure $ object ["accepted" .= True,"authorization" .= ("independent_chain_evidence_required"::Text)]
  health = pure (Availability True "process_running")
  ready = do
    a <- liftIO (readiness ledger)
    if available a then pure a else throwError err503 {errBody=encode a}
adminServer :: Ledger -> Server AdminAPI
adminServer l = asHandler (readiness l)
  :<|> (\p -> asHandler (pause l (T.take 120 (pauseReason p)) >> readiness l))
  :<|> asHandler (auditExport l)
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
