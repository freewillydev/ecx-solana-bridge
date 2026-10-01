{-# LANGUAGE DataKinds,GADTs #-}
module Bridge.Postgres.Runtime (runAPI,runTestWorker) where

import Bridge.API
import Bridge.Config
import Bridge.Types
import Bridge.Operation.Internal
import Bridge.Postgres.Ledger (Ledger,withLedger,ledgerAction,pause,readiness)
import Bridge.Postgres.Schema hiding (Audit)
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Postgres.Observer as Observer
import qualified Bridge.Postgres.Reconciliation as Reconciliation
import qualified Bridge.Postgres.Server as Server
import qualified Bridge.Postgres.Refund as Refund
import qualified Bridge.Ledger as Domain
import Bridge.Postgres.PaymentStore (Store(..))
import Bridge.Settlement (realPaymentTransport,paymentPass,reconcilePaymentsWith,PaymentTransport(..),approveSolanaRetryWith)
import qualified Bridge.Postgres.Startup as Startup
import Bridge.Recovery (cancelPreparationWith)
import Bridge.NativePayment (ownedNativeLocks)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar,newMVar,withMVar)
import Control.Monad (forever,when)
import Control.Exception (IOException,catch)
import qualified Bridge.SolanaPay as Pay
import Bridge.RPC (fieldValue)
import qualified Bridge.Postgres.Provisioning as Provisioning
import Bridge.Observer (epochSeconds)
import Bridge.RPC (newRpcManager)
import Bridge.Web (asHandler,runUnix,securityBoundary)
import Control.Concurrent.Async (concurrently_)
import Control.Exception (bracket,try)
import Data.Aeson (Value(..),object,(.=),toJSON,encode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as M
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager)
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import qualified Opaleye as O
import Servant

-- No signer, mutating chain transport, writable ledger or private Config.
data SafeContext = SafeContext PG.ConnectInfo Value Bool
data CriticalContext = CriticalContext Manager Config Ledger

data Runtime = Runtime SafeContext CriticalContext (MVar ())

bearer :: Text -> IO Text
bearer header = do
  token <- maybe (reject "authorization_required") pure(T.stripPrefix "Bearer " header)
  _ <- either reject pure(capabilityHash token)
  pure token

readOnly :: SafeContext -> (PG.Connection -> IO a) -> IO a
readOnly (SafeContext settings _ _) action = bracket (PG.connect settings) PG.close $ \connection->
  Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly) connection (action connection)

availability :: PG.Connection -> IO Availability
availability connection = do
  rows <- O.runSelect connection (O.selectTable deploymentTable) :: IO [Deployment]
  case rows of [row]->pure(Availability (deploymentPaused row==0) (deploymentPauseReason row)); _->reject "corrupt_deployment"

publicAvailability :: PG.Connection -> IO Availability
publicAvailability connection = do
  state <- availability connection
  if not(available state) then pure state else do
    now <- epochSeconds
    outcome <- try(Order.checkIntakeReadyC connection now) :: IO(Either BridgeError ())
    pure $ case outcome of Right ()->state; Left(BridgeError reason)->Availability False reason

evalSafe :: SafeContext -> DSL 'Safe a -> IO a
evalSafe context@(SafeContext _ public remote) (SafeDSL operation) = case operation of
  PublicConfig->readOnly context $ \connection->do
    state <- publicAvailability connection
    case public of
      Object fields->pure(Object(KM.insert "availability" (toJSON state) fields))
      _->reject "invalid_public_configuration"
  OrderStatus header oid->do
    token <- bearer header
    cap <- either reject pure(capabilityHash token)
    readOnly context (\connection->Order.exposeOrderC connection remote cap oid)
  PaymentInstructions header oid->do
    token <- bearer header
    cap <- either reject pure(capabilityHash token)
    readOnly context $ \connection->do
      order <- Order.exposeOrderC connection remote cap oid
      now <- epochSeconds
      state <- publicAvailability connection
      require (available state && status order=="AwaitingDeposit" && now<=deadline order && direction(request order)==WrappedToNative) "deposit_window_closed"
      instruction <- maybe (reject "instruction_not_recorded") pure(depositInstruction order)
      owner <- fieldValue "custodyOwner" public
      mintId <- fieldValue "mint" public
      uri <- either reject pure(Pay.payURIFor owner mintId instruction (gross $ quote order))
      pure(object["uri" .= uri,"reference" .= T.drop 11 instruction,"mint" .= mintId,"amount" .= gross(quote order),"refundPolicy" .= ("verified_source_owner"::Text)])
  Health->pure(Availability True "process_running")
  Readiness->readOnly context publicAvailability
  ReadyEndpoint->readOnly context publicAvailability
  Scanners->readOnly context $ \connection->do
    rows <- O.runSelect connection (O.selectTable scanhealthTable) :: IO [ScanHealth]
    pure(object["scanners" .= [object["chain" .= scanhealthChain row,"lastSuccess" .= scanhealthLastSuccess row,"lastError" .= scanhealthLastError row] | row<-rows]])
  Audit->readOnly context $ \connection->do
    rows <- O.runSelect connection (O.selectTable postingsTable) :: IO [Postings]
    obligations <- O.runSelect connection (O.selectTable obligationsTable) :: IO [Obligations]
    let totals=M.fromListWith (+) [((postingsAsset row,postingsAccount row),toInteger(postingsDelta row)) | row<-rows]
    pure(object["balances" .= [object["asset" .= asset,"allocation" .= account,"units" .= T.pack(show n)] | ((asset,account),n)<-M.toList totals],"unresolved" .= [object["id" .= obligationsId row,"status" .= obligationsStatus row] | row<-obligations,obligationsStatus row/="paid"]])

evalCritical :: CriticalContext -> DSL 'Critical a -> IO a
evalCritical (CriticalContext manager cfg ledger) plan = case plan of
  CustomerDSL operation->case operation of
    CreateOrder header request->bearer header >>= \token->Provisioning.createCustomerOrder manager cfg ledger (const $ reject "unexpected_test_backup") token request
    DepositHint header oid signature->do
      token <- bearer header
      cap <- either reject pure(capabilityHash token)
      require (T.length signature>=64 && T.length signature<=88) "invalid_signature_hint"
      ledgerAction ledger $ \connection->do
        _ <- Order.readSavedOrder connection cap oid
        previous <- O.runSelect connection $ do
          row <- O.selectTable hintsTable
          O.where_(hintsOrderId row O..== O.sqlStrictText oid)
          pure(hintsSignature row)
          :: IO [Text]
        require (length previous<8) "hint_limit"
        if signature `elem` previous then pure () else do
          _ <- O.runInsert connection O.Insert {O.iTable=hintsTable,O.iRows=[Hints (O.sqlStrictText oid) (O.sqlStrictText signature)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
          pure ()
      pure(object["accepted" .= True,"authorization" .= ("independent_chain_evidence_required"::Text)])
  OperatorDSL operation->case operation of
    Pause reason->pause ledger reason >> readiness ledger
    CancelPreparation intent generation reason->cancelPreparationWith epochSeconds (realPaymentTransport manager cfg (const $ reject "unexpected_test_backup")) cfg (Store ledger) intent generation reason
    Resume->do
      now <- epochSeconds
      Startup.resumeAfterChecks cfg ledger now
      readiness ledger
    ApproveSolanaRetry txid reason->do
      approveSolanaRetryWith (realPaymentTransport manager cfg (const $ reject "unexpected_test_backup")) cfg (Store ledger) txid reason
      pure(object["approvedRetryOf" .= txid,"signedOrSent" .= False])
    RefundDeposit did->do
      obligation <- Refund.createRefund ledger did
      pure(object["obligation" .= Domain.obligationId obligation,"recipient" .= Domain.obligationRecipient obligation,"amount" .= T.pack(show $ Domain.obligationAmount obligation)])
  WorkerDSL ScanAndReconcile->do
    _ <- Observer.observeOnce manager cfg ledger
    now <- epochSeconds
    Order.expireQuotes ledger now
    _ <- reconcilePaymentsWith (realPaymentTransport manager cfg (const $ reject "unexpected_test_backup")) cfg (Store ledger)
    Reconciliation.reconcileCustodyWith epochSeconds (realPaymentTransport manager cfg (const $ reject "unexpected_test_backup")) cfg ledger
  WorkerDSL StartPayments->do
    let transport=realPaymentTransport manager cfg (const $ reject "unexpected_test_backup")
    _ <- ownedNativeLocks (paymentNative transport) []
    now <- epochSeconds
    Startup.resumeAfterChecks cfg ledger now
  WorkerDSL AdvancePayments->do
    state <- readiness ledger
    when (available state) $ do
      now <- epochSeconds
      fresh <- try (Order.checkIntakeReady ledger now) :: IO (Either BridgeError ())
      case fresh of
        Right ()->paymentPass manager cfg (Store ledger) (const $ reject "unexpected_test_backup")
        Left (BridgeError "custody_not_reconciled")->pure ()
        Left (BridgeError reason)->reject reason

-- The sole production invocation of critical evaluation. Routes have already
-- resolved their existential operation to a typed DSL, without performing IO.
evaluate :: Runtime -> Plan a -> IO a
evaluate (Runtime safeContext criticalContext gate) plan = case plan of
  SafePlan dsl->evalSafe safeContext dsl
  CustomerPlan dsl->critical dsl
  OperatorPlan dsl->critical dsl
  WorkerPlan dsl->critical dsl
 -- A critical workflow can include RPC calls between ledger transactions.
 -- Keep scanning, admission and payment workflows from interleaving; otherwise
 -- a request's sampled time can precede a newer custody certificate after it
 -- waits for the ledger. Safe reads retain their independent connections.
 where critical dsl = withMVar gate (\_->evalCritical criticalContext dsl)

interpret :: Runtime -> Plan a -> Handler a
interpret runtime plan = do
  result <- asHandler(evaluate runtime plan)
  case plan of
    SafePlan (SafeDSL ReadyEndpoint) | not(available result)->throwError err503 {errBody=encode result}
    _->pure result

-- This command exposes the actual API against a paused test deployment. It
-- continuously scans/reconciles; it never resumes or advances payments.
-- The paying test worker shares the same runtime and guarded dispatcher.
runAPI :: PG.ConnectInfo -> Config -> IO ()
runAPI = runRuntime False

runTestWorker :: PG.ConnectInfo -> Config -> IO ()
runTestWorker = runRuntime True

runRuntime :: Bool -> PG.ConnectInfo -> Config -> IO ()
runRuntime paying settings cfg = do
  require (profile cfg==L2LSignetDevnet && not(backupRequired cfg)) "public_test_profile_required"
  links <- lookupEnv "ECX_INTERFACE_CONFIG" >>= loadInterface cfg
  withLedger settings (fingerprint cfg) $ \ledger->do
    manager <- newRpcManager
    gate <- newMVar ()
    readUser <- fromMaybe (PG.connectUser settings) <$> lookupEnv "PGREADUSER"
    let readSettings=settings {PG.connectUser=readUser}
        public=object["profile" .= profile cfg,"solanaCluster" .= (if profile cfg==CanonicalBeta then "mainnet-beta" else "devnet"::Text),"links" .= links,"deployment" .= deploymentId cfg,"mint" .= mint cfg,"custodyOwner" .= custodyOwner cfg,"decimals" .= (8::Int),"minInput" .= minInput cfg,"maxInput" .= maxInput cfg,"feesBps" .= object["NativeToWrapped" .= (100::Int),"WrappedToNative" .= (100::Int)],"intakeEnabled" .= paying,"implementationReady" .= False]
        runtime=Runtime (SafeContext readSettings public (backupRequired cfg)) (CriticalContext manager cfg ledger) gate
    let checked action = do
          outcome <- try (action `catch` (\(_::IOException)->reject "postgres_worker_io_unavailable")) :: IO (Either BridgeError ())
          case outcome of
            Right ()->pure ()
            Left(BridgeError reason)->evaluate runtime (operator(Pause reason)) >> pure ()
    let bootstrap=checked $ do
          _ <- evaluate runtime (worker ScanAndReconcile)
          when paying (evaluate runtime (worker StartPayments))
    customerApp <- securityBoundary (serve customerAPI (hoistServer customerAPI (interpret runtime) Server.customerServer))
    adminApp <- securityBoundary (serve Server.operatorAPI (hoistServer Server.operatorAPI (interpret runtime) Server.adminServer))
    let api=concurrently_ (runUnix (customerSocket cfg) 0o660 customerApp) (runUnix (adminSocket cfg) 0o600 adminApp)
        loop=forever $ do
          result <- try ((do
            _ <- evaluate runtime (worker ScanAndReconcile)
            when paying(evaluate runtime (worker AdvancePayments))) `catch` (\(_::IOException)->reject "postgres_worker_io_unavailable")) :: IO(Either BridgeError ())
          case result of
            Right ()->pure ()
            Left(BridgeError reason)->evaluate runtime (operator(Pause reason)) >> pure ()
          threadDelay 15000000
    -- Liveness must not wait for initial chain synchronization. withLedger has
    -- already paused intake; bootstrap can only resume it after reconciliation.
    concurrently_ api (bootstrap >> loop)
