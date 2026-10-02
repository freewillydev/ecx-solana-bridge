{-# LANGUAGE DataKinds,GADTs #-}
module Bridge.Postgres.Runtime (runAPI,runTestWorker,runBackedTestWorker) where

import Bridge.API
import Bridge.Config
import Bridge.Types
import Bridge.Operation.Internal
import Bridge.Postgres.Ledger (Ledger,withGuardedLedger,ledgerAction,pause,readiness)
import qualified Bridge.Postgres.Treasury as Treasury
import qualified Bridge.Postgres.Fence as Fence
import Bridge.Postgres.Schema hiding (Audit)
import qualified Bridge.Postgres.Backup as Backup
import qualified Bridge.Postgres.CoveredSource as CoveredSource
import qualified Bridge.Postgres.NativeRebroadcast as NativeRebroadcast
import qualified Bridge.Postgres.NativeRecovery as NativeRecovery
import Data.Int (Int64)
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Postgres.Observer as Observer
import qualified Bridge.Postgres.Reconciliation as Reconciliation
import qualified Bridge.Postgres.Server as Server
import qualified Bridge.Postgres.Refund as Refund
import qualified Bridge.Ledger.Model as Domain
import Bridge.Postgres.PaymentStore (Store(..))
import Bridge.Settlement (realPaymentTransport,settleAttemptWith,paymentPass,reconcilePaymentsWith,PaymentTransport(..),approveSolanaRetryWith)
import qualified Bridge.Postgres.Startup as Startup
import Bridge.Recovery (cancelPreparationWith,reconcileNativeLocksWith,approveSourceRecoveryWith,prepareNativeReplacementWith,signNativeReplacementWith,NativeReplacementStore(..),coverSourceLossWith)
import Bridge.Native (nativeIdentity)
import Bridge.Reorg (reconcileNativeSourcesWith,reconcileNativeSettlementsWith)
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
data SafeContext = SafeContext PG.ConnectInfo Value Bool Bool
data CriticalContext = CriticalContext Manager Config Ledger Bool (Int64 -> IO ())

data Runtime = Runtime SafeContext CriticalContext (MVar ())

bearer :: Text -> IO Text
bearer header = do
  token <- maybe (reject "authorization_required") pure(T.stripPrefix "Bearer " header)
  _ <- either reject pure(capabilityHash token)
  pure token

-- The only input to read evaluation is a closed safe DSL command. No caller
-- can supply a query, callback or receive a database connection.
evalSafe :: SafeContext -> DSL 'Safe a -> IO a
evalSafe _ (SafeDSL Health) = pure(Availability True "process_running")
evalSafe (SafeContext settings public remote paying) (SafeDSL operation) =
  bracket (PG.connect settings) PG.close $ \connection->
    Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly)
      connection (readOperation connection operation)
 where
  publicAvailability :: PG.Connection -> IO Availability
  publicAvailability connection
    | not paying = pure(Availability False "observation_only")
    | otherwise = do
        rows <- O.runSelect connection (O.selectTable deploymentTable) :: IO [Deployment]
        state <- case rows of
          [row]->pure(Availability (deploymentPaused row==0) (deploymentPauseReason row))
          _->reject "corrupt_deployment"
        if not(available state) then pure state else do
          now <- epochSeconds
          outcome <- try(Order.checkIntakeReadyC connection now) :: IO(Either BridgeError ())
          pure $ case outcome of
            Right ()->state
            Left(BridgeError reason)->Availability False reason

  readOperation :: PG.Connection -> SafeOperation result -> IO result
  readOperation connection = \case
    PublicConfig->do
      state <- publicAvailability connection
      case public of
        Object fields->pure(Object(KM.insert "availability" (toJSON state) fields))
        _->reject "invalid_public_configuration"
    OrderStatus header oid->do
      token <- bearer header
      cap <- either reject pure(capabilityHash token)
      Order.exposeOrderC connection remote cap oid
    PaymentInstructions header oid->do
      token <- bearer header
      cap <- either reject pure(capabilityHash token)
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
    Readiness->publicAvailability connection
    ReadyEndpoint->publicAvailability connection
    Scanners->do
      rows <- O.runSelect connection (O.selectTable scanhealthTable) :: IO [ScanHealth]
      pure(object["scanners" .= [object["chain" .= scanhealthChain row,"lastSuccess" .= scanhealthLastSuccess row,"lastError" .= scanhealthLastError row] | row<-rows]])
    Audit->do
      rows <- O.runSelect connection (O.selectTable postingsTable) :: IO [Postings]
      obligations <- O.runSelect connection (O.selectTable obligationsTable) :: IO [Obligations]
      treasuryReceipts <- O.runSelect connection $ O.limit 1001 $ do
        row<-O.selectTable depositsTable
        O.where_(O.isNull(depositsOrderId row) O..&& depositsEligible row O..== O.sqlInt8 1 O..&& depositsAllocated row O..== O.sqlInt8 0)
        pure row
        :: IO [Deposits]
      nativeReviews <- NativeRecovery.reviewSequences connection
      let totals=M.fromListWith (+) [((postingsAsset row,postingsAccount row),toInteger(postingsDelta row)) | row<-rows]
      pure(object["treasuryReceipts" .= [object["receipt" .= depositsId row,"asset" .= depositsAsset row,"units" .= T.pack(show $ depositsAmount row),"ownershipRequiresAttestation" .= True] | row<-take 1000 treasuryReceipts],"treasuryBacklog" .= (length treasuryReceipts>1000),"balances" .= [object["asset" .= asset,"allocation" .= account,"units" .= T.pack(show n)] | ((asset,account),n)<-M.toList totals],"unresolved" .= [object["id" .= obligationsId row,"status" .= obligationsStatus row] | row<-obligations,obligationsStatus row/="paid"],"nativeRecoveryReviews" .= [object["transaction" .= txid,"state" .= state,"recoverySequence" .= sequenceNo] | (txid,state,sequenceNo)<-take 1000 nativeReviews],"nativeRecoveryBacklog" .= (length nativeReviews>1000)])

evalCritical :: CriticalContext -> DSL 'Critical a -> IO a
-- Observer mode can retain payment hints, pause and reconcile recorded effects.
-- It has no order-creation, resume, new signature or broadcast authority.
observationOperation :: DSL 'Critical a -> Bool
observationOperation = \case
  CustomerDSL (DepositHint _ _ _)->True
  OperatorDSL (Pause _)->True
  WorkerDSL ScanAndReconcile->True
  _->False

evalCritical (CriticalContext manager cfg ledger _ backup) plan = case plan of
  CustomerDSL operation->case operation of
    CreateOrder header request->bearer header >>= \token->Provisioning.createCustomerOrder manager cfg ledger backup token request
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
    CancelPreparation intent generation reason->cancelPreparationWith epochSeconds (realPaymentTransport manager cfg backup) cfg (Store ledger) intent generation reason
    Resume->do
      Startup.resumeAfterReview epochSeconds (realPaymentTransport manager cfg backup) cfg ledger
      readiness ledger
    ApproveSolanaRetry txid reason->do
      approveSolanaRetryWith (realPaymentTransport manager cfg backup) cfg (Store ledger) txid reason
      pure(object["approvedRetryOf" .= txid,"signedOrSent" .= False])
    ApproveSourceRecovery intent restoration reason->approveSourceRecoveryWith epochSeconds (realPaymentTransport manager cfg backup) cfg (Store ledger) intent restoration reason
    ApproveCoveredSource intent loss reason->CoveredSource.approveWith epochSeconds (realPaymentTransport manager cfg backup) cfg ledger intent loss reason
    RebroadcastNative txid recovery reason->NativeRebroadcast.rebroadcastWith (realPaymentTransport manager cfg backup) cfg ledger txid recovery reason
    PrepareNativeReplacement parent fee reason->
      prepareNativeReplacementWith epochSeconds (realPaymentTransport manager cfg backup) cfg (Store ledger) parent fee reason
    SignNativeReplacement sequenceNo->do
      a <- signNativeReplacementWith epochSeconds (realPaymentTransport manager cfg backup) cfg (Store ledger) sequenceNo
      pure(object["transaction" .= Domain.attemptId a,"draftSequence" .= sequenceNo,"signed" .= True,"sent" .= False])
    CancelNativeReplacement sequenceNo reason->do
      replacementCancel (Store ledger) sequenceNo reason
      pure(object["draftSequence" .= sequenceNo,"cancelled" .= True,"signedOrSent" .= False])
    SendNativeReplacement sequenceNo->do
      saved <- replacementMember (Store ledger) sequenceNo
      a <- maybe (reject "native_replacement_member_missing") pure saved
      outcome <- settleAttemptWith (realPaymentTransport manager cfg backup) cfg (Store ledger) a
      pure(object["transaction" .= Domain.attemptId a,"outcome" .= outcome])
    CoverSourceLoss did recovery capital reason->
      coverSourceLossWith epochSeconds (realPaymentTransport manager cfg backup) cfg (Store ledger) did recovery capital reason
    AllocateTreasury did split reason->do
      _<-Reconciliation.reconcileCustodyWith epochSeconds (realPaymentTransport manager cfg backup) cfg ledger
      now<-epochSeconds
      Treasury.allocate ledger now did split reason
    RefundDeposit did->do
      obligation <- Refund.createRefund ledger did
      pure(object["obligation" .= Domain.obligationId obligation,"recipient" .= Domain.obligationRecipient obligation,"amount" .= T.pack(show $ Domain.obligationAmount obligation)])
  WorkerDSL ScanAndReconcile->do
    -- Advisory native locks must be restored independently of Solana RPC health.
    _ <- reconcileNativeLocksWith
      (realPaymentTransport manager cfg backup)
        {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg (Store ledger)
    _ <- Observer.observeOnce manager cfg ledger
    _ <- reconcileNativeSourcesWith
      (realPaymentTransport manager cfg backup)
        {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg (Store ledger)
    _ <- reconcileNativeSettlementsWith
      (realPaymentTransport manager cfg backup)
        {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg (Store ledger)
    now <- epochSeconds
    Order.expireQuotes ledger now
    _ <- reconcilePaymentsWith (realPaymentTransport manager cfg backup) cfg (Store ledger)
    Reconciliation.reconcileCustodyWith epochSeconds (realPaymentTransport manager cfg backup) cfg ledger
  WorkerDSL StartPayments->do
    let transport=realPaymentTransport manager cfg backup
    lockResult <- reconcileNativeLocksWith transport {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg (Store ledger)
    lockError <- fieldValue "error" lockResult :: IO (Maybe Text)
    maybe (pure ()) reject lockError
    now <- epochSeconds
    Startup.resumeAfterChecks cfg ledger now
  WorkerDSL AdvancePayments->do
    state <- readiness ledger
    when (available state) $ do
      now <- epochSeconds
      fresh <- try (Order.checkIntakeReady ledger now) :: IO (Either BridgeError ())
      case fresh of
        Right ()->paymentPass manager cfg (Store ledger) backup
        Left (BridgeError "custody_not_reconciled")->pure ()
        Left (BridgeError reason)->reject reason

-- Routes return existential operations, without performing IO. Unpack their
-- class dictionaries here and elaborate to the DSL before either evaluator.
-- This remains the sole production invocation of critical evaluation.
evaluate :: Runtime -> Plan a -> IO a
evaluate (Runtime safeContext criticalContext gate) plan = case plan of
  SafePlan request->evalSafe safeContext (resolve request)
  CustomerPlan request->critical (resolve request)
  OperatorPlan request->critical (resolve request)
  WorkerPlan request->critical (resolve request)
 -- A critical workflow can include RPC calls between ledger transactions.
 -- Keep scanning, admission and payment workflows from interleaving; otherwise
 -- a request's sampled time can precede a newer custody certificate after it
 -- waits for the ledger. Safe reads retain their independent connections.
 where critical dsl = case criticalContext of
         CriticalContext _ _ _ paying _->do
           -- Immutable mode authorization must not wait behind a chain scan.
           require (paying || observationOperation dsl) "payment_worker_required"
           withMVar gate (\_->evalCritical criticalContext dsl)

interpret :: Runtime -> Plan a -> Handler a
interpret runtime plan = do
  result <- asHandler(evaluate runtime plan)
  case plan of
    SafePlan request -> case resolve request of
      SafeDSL ReadyEndpoint | not(available result)->throwError err503 {errBody=encode result}
      _->pure result
    _->pure result

-- This command exposes the actual API against a paused test deployment. It
-- continuously scans/reconciles; it never resumes or advances payments.
-- The paying test worker shares the same runtime and guarded dispatcher.
runAPI :: PG.ConnectInfo -> Config -> IO ()
runAPI = runRuntime False Nothing

runTestWorker :: PG.ConnectInfo -> Config -> IO ()
runTestWorker = runRuntime True Nothing

-- Backed acceptance remains limited to the same real Devnet profiles. This
-- command does not activate canonical/mainnet custody or waive release gates.
runBackedTestWorker :: PG.ConnectInfo -> Config -> Backup.RemoteBackup -> IO ()
runBackedTestWorker settings cfg remote = runRuntime True (Just remote) settings cfg

runRuntime :: Bool -> Maybe Backup.RemoteBackup -> PG.ConnectInfo -> Config -> IO ()
runRuntime paying remote settings cfg = do
  case remote of
    Nothing->require (publicTestProfile cfg) "public_test_profile_required"
    Just _->require (paying && profile cfg `elem` [L2LSignetDevnet,ECXBetanetDevnet] && backupRequired cfg) "backed_test_profile_required"
  links <- lookupEnv "ECX_INTERFACE_CONFIG" >>= loadInterface cfg
  readUser <- lookupEnv "PGREADUSER" >>= maybe (reject "read_database_user_required") pure
  require (not(T.null $ T.strip $ T.pack readUser) && readUser/=PG.connectUser settings) "distinct_read_database_user_required"
  readPassword <- fromMaybe "" <$> lookupEnv "PGREADPASSWORD"
  let readSettings=settings {PG.connectUser=readUser,PG.connectPassword=readPassword}
  -- Safe evaluation gets a separately authenticated role, never worker credentials.
  let validateReader = bracket (PG.connect readSettings) PG.close $ \connection->do
        roles <- PG.query_ connection "SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls AND NOT has_schema_privilege(current_user,'public','CREATE') FROM pg_roles WHERE rolname=current_user" :: IO [PG.Only Bool]
        require (roles==[PG.Only True]) "unsafe_read_database_role"
        writable <- PG.query_ connection "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','f','S') AND CASE WHEN c.relkind='S' THEN has_sequence_privilege(current_user,c.oid,'USAGE,UPDATE') ELSE has_table_privilege(current_user,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') END" :: IO [PG.Only Int64]
        require (writable==[PG.Only 0]) "unsafe_read_database_role"
  validateReader `catch` (\(_::PG.SqlError)->reject "read_database_identity_unavailable") `catch` (\(_::IOException)->reject "read_database_identity_unavailable")
  let ownership action=if paying then do
        directory <- Fence.fenceDirectory
        Fence.withFence directory (fingerprint cfg) $ \guard->withGuardedLedger settings (fingerprint cfg) (Just guard) action
       else withGuardedLedger settings (fingerprint cfg) Nothing action
  ownership $ \ledger->do
    manager <- newRpcManager
    gate <- newMVar ()
    let backup=case remote of
          Nothing->const $ reject "unexpected_test_backup"
          Just policy->Backup.backupCallback readSettings ledger cfg policy
        public=object["profile" .= profile cfg,"solanaCluster" .= (if profile cfg==CanonicalBeta then "mainnet-beta" else "devnet"::Text),"links" .= links,"deployment" .= deploymentId cfg,"mint" .= mint cfg,"custodyOwner" .= custodyOwner cfg,"decimals" .= (8::Int),"minInput" .= minInput cfg,"maxInput" .= maxInput cfg,"feesBps" .= object["NativeToWrapped" .= (100::Int),"WrappedToNative" .= (100::Int)],"intakeEnabled" .= paying,"implementationReady" .= False]
        runtime=Runtime (SafeContext readSettings public (backupRequired cfg) paying) (CriticalContext manager cfg ledger paying backup) gate
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
