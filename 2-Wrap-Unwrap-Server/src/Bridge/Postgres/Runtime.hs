{-# LANGUAGE DataKinds,GADTs #-}
module Bridge.Postgres.Runtime (runAPI,runTestWorker,runBackedTestWorker,doctor,checkDatabase) where

import qualified Bridge.Postgres.Replacement as PgReplacement
import qualified Bridge.Postgres.Source as PgSource
import Bridge.API (customerAPI)
import Bridge.BrowserBuild (browserAssetsDirectory)
import qualified Bridge.API as API
import Bridge.Control (runControl)
import Bridge.Operator (signingAPI,signerCredentials,signerCertificate)
import qualified Servant.Client as SC
import qualified Network.Connection as NC
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher (ciphersuite_default)
import Network.HTTP.Client.TLS (mkManagerSettings)
import Data.X509.CertificateStore (makeCertificateStore)
import Data.IORef (newIORef,atomicModifyIORef')
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Bridge.Config
import Bridge.Types
import Bridge.Operation.Internal
import Bridge.Postgres.Ledger (Ledger,withGuardedLedger,ledgerAction,pause,readiness)
import qualified Bridge.Postgres.Treasury as Treasury
import qualified Bridge.Postgres.Fence as Fence
import Bridge.Postgres.Schema hiding (Audit)
import Bridge.Postgres.Catalog (verifyReadRole,inspectDatabase)
import qualified Bridge.Postgres.Backup as Backup
import qualified Bridge.Postgres.NativeRecovery as NativeRecovery
import qualified Bridge.Postgres.Source as Source
import Bridge.NativeReplacement (NativeFamilyView(..))
import qualified Data.Text.Encoding as TE
import Data.Int (Int64)
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Observer as Observer
import qualified Bridge.Postgres.Server as Server
import qualified Bridge.Postgres.Refund as Refund
import qualified Bridge.Ledger.Model as Domain
import Bridge.Postgres.PaymentStore (paymentNativeFamily)
import qualified Bridge.Reconciliation as CustodyWorkflow
import Bridge.Settlement (realPaymentTransport,settleAttemptWith,paymentPass,reconcilePaymentsWith,PaymentTransport(..),approveSolanaRetryWith,readSavedPayment,readSavedNativeFamily,recheckSourceWith)
import qualified Bridge.Postgres.Startup as Startup
import Bridge.Recovery (cancelPreparationWith,reconcileNativeLocksWith,approveSourceRecoveryWith,prepareNativeReplacementUsing,signNativeReplacementUsing,coverSourceLossWith)
import Bridge.Native (nativeIdentity)
import Bridge.Payment (prepareNativeWithSigner,prepareSolanaWithSigner)
import Bridge.Solana (solanaIdentity)
import Bridge.Reorg (reconcileNativeSourcesWith,reconcileNativeSettlementsWith,inspectNativeSourceWith)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar,newMVar,withMVar)
import Control.Monad (forever,when,forM_)
import Control.Exception (IOException,catch,onException)
import qualified Bridge.SolanaPay as Pay
import Bridge.RPC (fieldValue,parseValue)
import qualified Bridge.Order as OrderWorkflow
import Bridge.Observer (epochSeconds)
import Bridge.RPC (newRpcManager,boundedBody)
import Bridge.Web (asHandler,runUnix,runPublic,securityBoundary)
import Control.Concurrent.Async (concurrently_)
import Control.Exception (bracket,try)
import Data.Aeson (FromJSON,Value(..),object,(.=),toJSON,parseJSON,eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as M
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)
import Text.Read (readMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager,closeManager,newManager,managerSetProxy,noProxy,
  managerRetryableException,managerIdleConnectionCount,managerResponseTimeout,managerModifyRequest,managerModifyResponse,
  redirectCount,responseBody,responseTimeoutMicro)
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import qualified Opaleye as O
import Servant

-- No signer, mutating chain transport, writable ledger or private Config.
data SafeContext = SafeContext PG.ConnectInfo (Maybe API.PublicConfiguration) Bool Bool
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
    VerifyReadRole->verifyReadRole connection
    DatabaseIdentity expected->inspectDatabase connection expected
    PublicConfig->do
      state <- publicAvailability connection
      configuration <- maybe (reject "public_configuration_unavailable") pure public
      pure configuration {API.pubAvailability=state}
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
      configuration <- maybe (reject "public_configuration_unavailable") pure public
      let owner=API.pubCustodyOwner configuration
          mintId=API.pubMint configuration
      uri <- either reject pure(Pay.payURIFor owner mintId instruction (gross $ quote order))
      pure(API.PaymentInstruction uri (T.drop 11 instruction) mintId (gross $ quote order) "verified_source_owner")
    Readiness->publicAvailability connection
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
-- Observer mode can pause and reconcile recorded effects.
-- It has no order-creation, resume, new signature or broadcast authority.
observationOperation :: DSL 'Critical a -> Bool
observationOperation = \case
  OperatorDSL (Pause _)->True
  WorkerDSL ScanAndReconcile->True
  _->False

evalCritical (CriticalContext manager cfg ledger _ backup) plan = case plan of
  SigningDSL _->reject "dedicated_signer_required"
  CustomerDSL operation->case operation of
    CreateOrder header request->bearer header >>= \token->OrderWorkflow.createCustomerOrder manager cfg ledger backup token request
  OperatorDSL operation->case operation of
    Pause reason->pause ledger reason >> readiness ledger
    CancelPreparation intent generation reason->cancelPreparationWith epochSeconds transport cfg ledger intent generation reason
    Resume->do
      verifyNativeBoundary
      Startup.resumeAfterReview epochSeconds transport cfg ledger
      readiness ledger
    ApproveSolanaRetry txid reason->do
      approveSolanaRetryWith transport cfg ledger txid reason
      pure(object["approvedRetryOf" .= txid,"signedOrSent" .= False])
    ApproveSourceRecovery intent restoration reason->approveSourceRecoveryWith epochSeconds transport cfg ledger intent restoration reason
    ApproveCoveredSource intent loss reason->approveCoveredSource intent loss reason
    RebroadcastNative txid recovery reason->rebroadcastNative txid recovery reason
    PrepareNativeReplacement parent fee reason->
      prepareNativeReplacementUsing epochSeconds transport
        (\parent' _ fee'->signerRequest (DraftReplacement (fingerprint cfg) parent' fee')) cfg ledger parent fee reason
    SignNativeReplacement sequenceNo->do
      a <- signNativeReplacementUsing epochSeconds transport
        (\sequenceNo' _ _->signerRequest (SignReplacement (fingerprint cfg) sequenceNo')) cfg ledger sequenceNo
      pure(object["transaction" .= Domain.attemptId a,"draftSequence" .= sequenceNo,"signed" .= True,"sent" .= False])
    CancelNativeReplacement sequenceNo reason->do
      PgReplacement.cancel ledger sequenceNo reason
      pure(object["draftSequence" .= sequenceNo,"cancelled" .= True,"signedOrSent" .= False])
    SendNativeReplacement sequenceNo->do
      saved <- PgReplacement.member ledger sequenceNo
      a <- maybe (reject "native_replacement_member_missing") pure saved
      outcome <- settleAttemptWith transport cfg ledger a
      pure(object["transaction" .= Domain.attemptId a,"outcome" .= outcome])
    CoverSourceLoss did recovery capital reason->
      coverSourceLossWith epochSeconds transport cfg ledger did recovery capital reason
    AllocateTreasury did split reason->do
      _<-CustodyWorkflow.reconcileCustodyWith epochSeconds transport cfg ledger
      now<-epochSeconds
      Treasury.allocate ledger now did split reason
    ClassifyTreasurySpend stream txid reason->Treasury.classifySpend ledger stream txid reason
    RefundDeposit did->do
      obligation <- Refund.createRefund ledger did
      pure(object["obligation" .= Domain.obligationId obligation,"recipient" .= Domain.obligationRecipient obligation,"amount" .= T.pack(show $ Domain.obligationAmount obligation)])
  WorkerDSL ScanAndReconcile->do
    -- Advisory native locks must be restored independently of Solana RPC health.
    _ <- reconcileNativeLocksWith
      transport
        {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg ledger
    _ <- Observer.observeOnce manager cfg ledger
    _ <- reconcileNativeSourcesWith
      transport
        {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg ledger
    _ <- reconcileNativeSettlementsWith
      transport
        {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg ledger
    now <- epochSeconds
    Order.expireQuotes ledger now
    _ <- reconcilePaymentsWith transport cfg ledger
    CustodyWorkflow.reconcileCustodyWith epochSeconds transport cfg ledger
  WorkerDSL StartPayments->do
    verifyNativeBoundary
    lockResult <- reconcileNativeLocksWith transport {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg ledger
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
        Right ()->paymentPass transport cfg ledger prepare
        Left (BridgeError "custody_not_reconciled")->pure ()
        Left (BridgeError reason)->reject reason
 where
  transport=realPaymentTransport manager cfg backup

  verifyNativeBoundary :: IO ()
  verifyNativeBoundary = do
      forM_ ["walletprocesspsbt","signrawtransactionwithwallet","signmessage","dumpprivkey"
        ,"dumpwallet","gethdkeys","listdescriptors","walletpassphrase","walletpassphrasechange"
        ,"encryptwallet","importprivkey","importwallet","backupwallet"] $ \methodName->do
          denied <- try (paymentNative transport True methodName []) :: IO (Either BridgeError Value)
          require (case denied of Left(BridgeError "rpc_method_forbidden")->True; _->False)
            "native_signing_authority_not_separated"

  prepare ob = if Domain.obligationAsset ob=="Native"
    then prepareNativeWithSigner (paymentNative transport)
      (\intent generation _ _->signerRequest (SignPrepared (fingerprint cfg) intent generation)) cfg ledger ob
    else prepareSolanaWithSigner (paymentSolana transport)
      (\intent generation _->signerRequest (SignPrepared (fingerprint cfg) intent generation)) cfg ledger ob

  -- The only ClientM capability lives inside this critical evaluator. Calls
  -- use the server's shared contract, never a caller-supplied URL or command.
  signerRequest :: FromJSON reply => SigningOperation Value -> IO reply
  signerRequest operation = do
    credentials <- signerCredentials cfg
    certificate <- signerCertificate cfg
    when (backupRequired cfg) $ do
      sequenceNo <- ledgerAction ledger $ \c->do
        rows <- O.runSelect c $ fmap deploymentCriticalSequence (O.selectTable deploymentTable) :: IO [Int64]
        case rows of [n]->pure n; _->reject "corrupt_sequence"
      backup sequenceNo
    let base=TLS.defaultParamsClient "127.0.0.1" BS.empty
        tls=base{TLS.clientShared=(TLS.clientShared base){TLS.sharedCAStore=makeCertificateStore [certificate]}
          ,TLS.clientSupported=(TLS.clientSupported base){TLS.supportedCiphers=ciphersuite_default}}
        settings=managerSetProxy noProxy (mkManagerSettings (NC.TLSSettings tls) Nothing)
          {managerRetryableException=const False,managerIdleConnectionCount=0
          ,managerResponseTimeout=responseTimeoutMicro 60000000
          ,managerModifyRequest= \request->pure request{redirectCount=0}
          ,managerModifyResponse= \response->do
            bytes <- boundedBody 524288 (responseBody response)
            body <- newIORef bytes
            pure response{responseBody=atomicModifyIORef' body (\chunk->(BS.empty,chunk))}}
    bracket (newManager settings) closeManager $ \local->do
      let prepareCall :<|> draftCall :<|> replacementCall=SC.client signingAPI credentials
          action=case operation of
            SignPrepared identity intent generation->prepareCall (identity,intent,generation)
            DraftReplacement identity parent fee->draftCall (identity,parent,fee)
            SignReplacement identity sequenceNo->replacementCall (identity,sequenceNo)
          environment=SC.mkClientEnv local (SC.BaseUrl SC.Https "127.0.0.1" (signerPort cfg) "")
      result <- SC.runClientM action environment
      value <- case result of
        Right value->pure value
        Left (SC.FailureResponse _ response)->do
          failure <- either (const $ reject "signer_outcome_unknown") pure
            (eitherDecodeStrict' $ LBS.toStrict $ SC.responseBody response)
          case failure of
            Object fields | Just code<-KM.lookup "error" fields->parseValue parseJSON code >>= reject
            _->reject "signer_request_rejected"
        Left _->reject "signer_outcome_unknown"
      parseValue parseJSON value

  -- Explicit operator approval revives the original suspended obligation only.
  -- It never resumes intake, signs, broadcasts, marks a deposit eligible or books
  -- another capital allocation. Every effect still traverses the existing engine.
  approveCoveredSource :: Text -> Int64 -> Text -> IO Value
  approveCoveredSource intent loss reason = do
    require (loss>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
    readiness ledger >>= \health->require (not $ available health) "pause_before_operator_action"
    old <- Source.coveredApproval ledger intent loss
    case old of
      Just saved->require (saved==reason) "source_approval_conflict"
      Nothing->do
        ob <- Source.coveredObligation ledger intent loss
        paymentIdentity transport
        payments <- reconcilePaymentsWith transport cfg ledger
        attempts <- fieldValue "attempts" payments :: IO [Value]
        failures <- mapM (fieldValue "error") attempts :: IO [Maybe Text]
        require (all (==Nothing) failures) "source_approval_payment_requires_review"
        _ <- CustodyWorkflow.reconcileCustodyWith epochSeconds transport cfg ledger
        candidates <- PgSource.candidates ledger
        require (length candidates<=1000) "source_recovery_backlog"
        source <- case filter ((==Domain.obligationDeposit ob).Domain.depositId) candidates of
          [row]->pure row
          _->reject "source_loss_not_proven"
        proof <- inspectNativeSourceWith transport cfg ledger source >>= \case
          Domain.SourceMissing evidence->pure evidence
          _->reject "source_loss_not_proven"
        now <- epochSeconds
        Source.coveredRecord ledger intent loss now reason proof
    pure $ object["approvedCoveredSource" .= intent,"lossRecoverySequence" .= loss
      ,"paused" .= True,"signedOrSent" .= False]

  -- Explicit repair of the original native payment, including after a lost send
  -- reply. Never create a signature, release principal or resume payment intake.
  -- All family members share the original inputs; the chain adapter validates
  -- current wallet/tip, saved outputs/fees, and every actual previous output.
  rebroadcastNative :: Text -> Int64 -> Text -> IO Value
  rebroadcastNative txid anchor reason = work `onException` pause ledger "native_rebroadcast_requires_review"
   where
    work=do
      require (anchor>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_native_rebroadcast_approval"
      state <- readiness ledger
      require (not $ available state) "pause_before_operator_action"
      previous <- NativeRecovery.rebroadcastDecision ledger txid anchor reason
      candidates <- NativeRecovery.candidates ledger
      require (length candidates<=1000) "native_settlement_recovery_backlog"
      attempt <- case filter ((==txid).Domain.attemptId) candidates of
        [saved]->pure saved
        _->reject "native_rebroadcast_payment_not_in_review"
      paymentIdentity transport
      (ob,_) <- readSavedPayment transport cfg ledger attempt
      family <- paymentNativeFamily ledger (Domain.attemptIntent attempt)
      view <- missing family
      recheckSourceWith transport cfg ledger ob
      block <- paymentNative transport False "getblockchaininfo" [] >>= fieldValue "bestblockhash" :: IO Text
      let proof=object["transaction" .= txid,"bytesHash" .= digest(TE.encodeUtf8 $ Domain.attemptBytes attempt),
            "nodeBlock" .= block,"family" .= map Domain.attemptId family,
            "noActiveFamilyPayment" .= (familyActive view==Nothing)]
      approved <- case previous of
        Just sequenceNo->pure sequenceNo
        Nothing->NativeRecovery.recordRebroadcast ledger attempt family anchor reason proof
      when (backupRequired cfg) $ paymentBackup transport approved
      -- Upload can take time. Repeat actual identity, source and input/tip proofs
      -- immediately before the short ledger authorization and exact-byte send.
      paymentIdentity transport
      recheckSourceWith transport cfg ledger ob
      _ <- missing family
      NativeRecovery.authorizeRebroadcast ledger (backupRequired cfg) attempt family approved
      actual <- paymentNative transport True "sendrawtransaction" [toJSON $ Domain.attemptBytes attempt] >>= parseValue parseJSON
      require (actual==txid) "native_broadcast_identity_mismatch"
      pure(object["transaction" .= txid,"approvalSequence" .= approved,
        "outcome" .= ("rebroadcast"::Text),"paused" .= True,"newSignature" .= False,
        "newPrincipalPosting" .= False])
    missing family=do
      (_,view) <- readSavedNativeFamily transport cfg ledger family
      require (familyActive view==Nothing) "native_rebroadcast_payment_not_missing"
      pure view

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
interpret runtime plan = asHandler (evaluate runtime plan)

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
  portText <- fromMaybe "8080" <$> lookupEnv "ECX_PORT"
  port <- maybe (reject "invalid_http_port") pure (readMaybe portText :: Maybe Int)
  require (port>=1024 && port<=65535) "invalid_http_port"
  assets <- fromMaybe browserAssetsDirectory <$> lookupEnv "ECX_ASSETS"
  links <- lookupEnv "ECX_INTERFACE_CONFIG" >>= loadInterface cfg
  readUser <- lookupEnv "PGREADUSER" >>= maybe (reject "read_database_user_required") pure
  require (not(T.null $ T.strip $ T.pack readUser) && readUser/=PG.connectUser settings) "distinct_read_database_user_required"
  readPassword <- fromMaybe "" <$> lookupEnv "PGREADPASSWORD"
  let readSettings=settings {PG.connectUser=readUser,PG.connectPassword=readPassword}
  let public=API.PublicConfiguration (profile cfg)
        (if profile cfg==CanonicalBeta then "mainnet-beta" else "devnet") links
        (deploymentId cfg) (mint cfg) (custodyOwner cfg) 8 (minInput cfg) (maxInput cfg)
        (M.fromList [("NativeToWrapped",100),("WrappedToNative",100)]) paying False
        (Availability False "starting")
      safeContext=SafeContext readSettings (Just public) (backupRequired cfg) paying
  -- Validate the separately authenticated reader through a closed safe operation.
  evalSafe safeContext (resolve (Request VerifyReadRole))
    `catch` (\(_::PG.SqlError)->reject "read_database_identity_unavailable")
    `catch` (\(_::IOException)->reject "read_database_identity_unavailable")
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
        runtime=Runtime safeContext (CriticalContext manager cfg ledger paying backup) gate
    let checked action = do
          outcome <- try (action `catch` (\(_::IOException)->reject "postgres_worker_io_unavailable")) :: IO (Either BridgeError ())
          case outcome of
            Right ()->pure ()
            Left(BridgeError reason)->evaluate runtime (operator(Pause reason)) >> pure ()
    let bootstrap=checked $ do
          _ <- evaluate runtime (worker ScanAndReconcile)
          when paying (evaluate runtime (worker StartPayments))
    let customerAPIApp=serve customerAPI (hoistServer customerAPI (interpret runtime) Server.customerServer)
    customerApp <- securityBoundary customerAPIApp
    -- Local clients retain their existing socket; public HTTP invokes the same
    -- typed server directly. Operator routes remain private to their own socket.
    let api=concurrently_ (runPublic port assets customerAPIApp)
          (concurrently_ (runUnix (customerSocket cfg) 0o660 customerApp) (runControl cfg (evaluate runtime)))
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


-- CLI diagnostics use the same closed safe interpreter as HTTP reads. They do
-- not initialize a ledger, acquire worker ownership or construct a signer.
checkDatabase :: PG.ConnectInfo -> Text -> IO Value
checkDatabase settings identity =
  evalSafe (SafeContext settings Nothing False False) (resolve $ Request $ DatabaseIdentity identity)
    `catch` (\(_::PG.SqlError)->reject "postgres_diagnostic_unavailable")
    `catch` (\(_::IOException)->reject "postgres_diagnostic_unavailable")

doctor :: PG.ConnectInfo -> Config -> IO Value
doctor settings cfg = do
  manager <- newRpcManager
  native <- inspect (nativeIdentity manager cfg)
  solana <- inspect (solanaIdentity manager cfg)
  database <- inspect (checkDatabase settings $ fingerprint cfg)
  pure $ object ["profile" .= profile cfg,"fingerprint" .= fingerprint cfg,
    "native" .= native,"solana" .= solana,"database" .= database,"implementationReady" .= False]
 where
  inspect action = do
    result <- try (action `catch` (\(_::IOException)->reject "diagnostic_io_unavailable")) :: IO (Either BridgeError Value)
    pure $ case result of
      Right evidence->object ["ok" .= True,"evidence" .= evidence]
      Left (BridgeError code)->object ["ok" .= False,"error" .= code]
