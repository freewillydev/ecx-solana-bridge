{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables, TypeFamilies, TypeApplications, ConstraintKinds, PatternSynonyms, ViewPatterns #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- The signer ClientM is constructed only inside this critical evaluator.
module Bridge.Critical (Process(..),WorkerLifetime(..),runProcess,CustomerSettings(..),SignerSettings(..),runWorkerLoop) where
import Bridge.Operation.Internal hiding (customer)
import Bridge.Domain (Asset(..),gross,paymentAsset,paymentId,units)
import Bridge.Identity (payURIFor,digest)
import Bridge.Admission (checkSolanaPayoutWith)
import Bridge.Order (createCustomerOrder)
import Bridge.Credentials (readNativeUnlock,withNativeUnlock)
import qualified Bridge.Config as C
import Bridge.Recovery
import Bridge.Control (runControl)
import Bridge.Web (publicApplication,runPublicServer)
import Data.Int (Int64)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Database.PostgreSQL.Simple as PG
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Bridge.Error
import Bridge.Payment
import Bridge.Observer (ObserverSettings(..),observeOnce)
import Bridge.Reconciliation (reconcileCustody,inspectLossCustody)
import Bridge.PaymentSource (verifyPaymentSource,inspectNativeSource)
import qualified Bridge.Wire as W
import Control.Monad (forM,forM_,when,forever)
import qualified Bridge.NativePayment as NP
import Bridge.NativePayment (NativeSigned,previewNativePayment,checkNativeAcceptance,releaseNativeInputLocks)
import Bridge.SolanaPayment (SolanaSigned,signedSolanaPlan,solPlanRecent,solPlanFeeLimit,solPlanRentLimit,checkBlockhashWindow,prepareSolanaSigned)
import Data.Text (Text)
import Bridge.PaymentObservation
import qualified Bridge.Solana as S
import Data.Aeson (Value,eitherDecodeStrict',FromJSON,toJSON,object,(.=),parseJSON,encode)
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import Data.Typeable (eqT)
import Data.Type.Equality ((:~:)(Refl))
import Bridge.Signer (signingAPI,SigningEndpoint(..),signerCredentials,signerCertificate,verifySigningKey,signingApplication,runSigningServer)
import Bridge.Store
import qualified Bridge.Native as N
import qualified Bridge.SolanaHelper as H
import Bridge.RPC (boundedBody,parseValue)
import qualified Bridge.RPC as RPC
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import System.IO (hPutStrLn,stderr)
import Control.Concurrent.MVar (MVar,newMVar,withMVar,modifyMVar)
import Control.Exception (bracket,onException,try,catch,throwIO,IOException)
import Data.IORef (newIORef,atomicModifyIORef')
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (removeDirectoryRecursive)
import System.FilePath (takeDirectory)
import System.Timeout (timeout)
import Network.HTTP.Client hiding (Request)
import Network.HTTP.Client.TLS (mkManagerSettings)
import qualified Network.Connection as NC
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher (ciphersuite_default)
import Data.X509.CertificateStore (makeCertificateStore)
import Servant.API ((:<|>)(..))
import qualified Servant.Client as SC

-- Here each filled OperationContext reduces to its ground Operation instance.
-- Recover the dictionary from the closed DSL, never an unchecked request.
pattern Instruction :: forall caller severity a. ()
  => forall op. Operation caller severity op => op severity a -> DSL caller severity a
pattern Instruction op <- (instruction -> Request op)
{-# COMPLETE Instruction #-}

instruction :: DSL caller severity a -> Request caller severity a
instruction (ReadOperator op) = Request (OperatorQuery op)
instruction (OperatorDSL op) = Request (OperatorChange op)
instruction (WorkerDSL op) = Request (WorkerAction op)
instruction (ReadCustomer op) = Request (CustomerQuery op)
instruction (WriteCustomer op) = Request (CustomerChange op)
instruction (SigningDSL op) = Request (SignerAction op)

-- Safe interpretation has no writer, signer transport, keys or RPC manager.
data instance Evaluation 'Safe = SafeEnvironment Reader (Maybe W.PublicConfiguration)
  (MVar (Maybe (Word64,Maybe W.PublicReport)))

-- Coalesce public refreshes, including failures. This cache carries no authority;
-- intake checks stay live and the report retains its actual observation times.
cachedPublicReport :: Reader -> MVar (Maybe (Word64,Maybe W.PublicReport)) -> Int64 -> IO (Maybe W.PublicReport)
cachedPublicReport reader cache now=modifyMVar cache $ \saved->do
  tick<-getMonotonicTimeNSec
  (stamp,report)<-case saved of
    Just entry@(stamp,_) | tick-stamp<30000000000->pure entry
    _->do
      result<-(timeout 5000000 (Just <$> evalRead reader (ReadPublicReport now)))
        `catch` (\(_::BridgeError)->pure Nothing)
        `catch` (\(_::PG.SqlError)->pure Nothing)
        `catch` (\(_::IOException)->pure Nothing)
      pure(tick,maybe Nothing id result)
  let aged value=value {W.reportCustodyFresh=W.reportCustodyFresh value
        && maybe False (\at->at<=now && now-at<=60) (W.reportCustodyAt value)}
  pure(Just(stamp,report),aged <$> report)

evalSafe :: Evaluation 'Safe -> Request caller 'Safe a -> IO a
evalSafe environment request=do
  program<-either reject pure (checkedRequest request)
  case program of
    Instruction op->authorizeOperation environment op >> evaluateOperation environment op

-- Ground instances own grammar checks and concrete effects in one place. eqT
-- proves context-type alignment; it does not compare dictionary values.
instance Operation 'Customer 'Safe CustomerCommand where
  type OperationContext 'Customer 'Safe CustomerCommand = Operation 'Customer 'Safe CustomerCommand
  command (CustomerQuery op)=ReadCustomer op
  interpretOperation dsl@(Instruction (_ :: actual 'Safe a))=
    case eqT @(OperationContext 'Customer 'Safe CustomerCommand) @(OperationContext 'Customer 'Safe actual) of
      Just Refl->Right dsl
      Nothing->Left "operation_dictionary_mismatch"
  authorizeOperation _ _=pure ()
  evaluateOperation (SafeEnvironment reader public cache) (CustomerQuery operation)=run operation
   where
    run :: CustomerRead a -> IO a
    run PublicConfig=do
      configuration<-configured
      now<-floor <$> getPOSIXTime
      report<-cachedPublicReport reader cache now
      let reported=configuration {W.pubReport=report}
      if not(W.pubIntakeEnabled configuration) then pure reported {W.pubAvailability=W.Availability False "observation_only"} else do
        result<-try (evalRead reader $ CheckIntake now) :: IO (Either BridgeError ())
        let state=case result of Right ()->W.Availability True ""; Left (BridgeError code)->W.Availability False code
        pure reported {W.pubAvailability=state}
    run (OrderStatus header identifier)=evalRead reader (ReadOrder header identifier)
    run (PaymentInstructions header identifier)=do
      configuration<-configured
      require (W.pubIntakeEnabled configuration) "deposit_window_closed"
      now<-floor <$> getPOSIXTime
      view<-evalRead reader (ReadPayableOrder now header identifier)
      instruction<-maybe (reject "instruction_not_recorded") pure (W.depositInstruction view)
      let mint=W.pubMint configuration
      uri<-either reject pure (payURIFor (W.pubCustodyOwner configuration) mint instruction (gross $ W.quote view))
      pure $ W.PaymentInstruction uri (T.drop 11 instruction) mint (gross $ W.quote view) "verified_source_owner"
    configured=maybe (reject "customer_configuration_unavailable") pure public

instance Operation 'Operator 'Safe OperatorCommand where
  type OperationContext 'Operator 'Safe OperatorCommand = Operation 'Operator 'Safe OperatorCommand
  command (OperatorQuery op)=ReadOperator op
  interpretOperation dsl@(Instruction (_ :: actual 'Safe a))=
    case eqT @(OperationContext 'Operator 'Safe OperatorCommand) @(OperationContext 'Operator 'Safe actual) of
      Just Refl->Right dsl
      Nothing->Left "operation_dictionary_mismatch"
  authorizeOperation _ _=pure ()
  evaluateOperation (SafeEnvironment reader _ _) (OperatorQuery operation)=run operation
   where
    run :: OperatorRead a -> IO a
    run NativeReviews=evalRead reader ReadNativeReviews
    run TreasuryReceipts=evalRead reader ReadTreasuryReceipts
    run ServiceState=do
      state<-evalRead reader ReadState
      pure $ W.ServiceStatus (ledgerPaused state) (ledgerReason state) (ledgerSequence state) (ledgerBackup state)

data CustomerSettings = CustomerSettings
  { publicConfiguration :: W.PublicConfiguration, customerPolicy :: StorePolicy
  , unsignedSdk :: FilePath }

data SignerSettings = SignerSettings
  { signingNative :: N.NativeSettings, signingSolana :: S.SolanaSettings
  , signingPolicy :: H.SolanaPolicy, signingLibrary :: FilePath, signingKey :: FilePath
  , signingNativeUnlock :: Maybe FilePath
  , signingBackup :: Maybe (C.Config,FilePath,FilePath) }

-- Concrete service lifetimes, never caller-supplied evaluator continuations.
-- Checkpointing holds the same writer/fence without starting any background work.
-- Signer startup cannot receive a writer or customer configuration.
data WorkerLifetime = Serving Int FilePath FilePath | Checkpointing
data Process
  = WorkerProcess ObserverSettings H.SolanaPolicy (Maybe CustomerSettings) SigningEndpoint Writer WorkerLifetime
  | SignerProcess SignerSettings SigningEndpoint

runProcess :: Manager -> Reader -> Process -> IO ()
runProcess rpc reader process=do
  environment<-case process of
    SignerProcess settings _->do
      let native=signingNative settings; solana=signingSolana settings; config=signingPolicy settings
      require (S.solanaProfile solana==N.profile native
        && S.mint solana==H.mint config && S.custodyOwner solana==H.custodyOwner config
        && S.custodyAta solana==H.custodyAta config) "signer_profile_mismatch"
      N.validateNativeSettings native
      S.validateSolanaSettings solana
      verifySigningKey (S.custodyOwner solana) (signingKey settings)
      forM_ (signingNativeUnlock settings) $ \path->readNativeUnlock path >> pure ()
      pure $ SignerEvaluation rpc reader settings
    WorkerProcess settings config customerSettings endpoint writer _->do
      let native=nativeSettings settings; solana=solanaSettings settings
      require (N.profile native==S.solanaProfile solana && S.mint solana==H.mint config
        && S.custodyOwner solana==H.custodyOwner config && S.custodyAta solana==H.custodyAta config) "payment_profile_mismatch"
      N.validateNativeSettings native
      S.validateSolanaSettings solana
      forM_ customerSettings $ \configured->do
        let public=publicConfiguration configured; store=customerPolicy configured
            policy=W.paymentPolicy(executionTerms store); costs=W.paymentLimits(executionTerms store)
        require (W.pubProfile public==N.profile native && W.pubMint public==H.mint config
          && W.pubCustodyOwner public==H.custodyOwner config && W.pubDeployment public==H.deploymentId config
          && W.pubDecimals public==8
          && W.pubFeesBps public==M.fromList [("NativeToWrapped",100),("WrappedToNative",100)]
          && W.pubSolanaCluster public==(if N.profile native==W.CanonicalBeta then "mainnet-beta" else "devnet")
          && W.deploymentFingerprint policy==H.fingerprint config && W.nativeDepth policy==defaultNativeDepth settings
          && W.savedSolanaFee costs==H.maxSolFee config && W.savedSolanaRent costs==H.maxSolAccountRent config) "customer_configuration_mismatch"
      pure $ WorkerEvaluation (CriticalEnvironment rpc settings config customerSettings endpoint reader writer)
  -- The only critical dispatch call site. It cannot escape this service lifetime.
  -- Each OS process owns its own gate; the two processes share no mutable state.
  gate<-newMVar ()
  let dispatch :: forall caller a. Request caller 'Critical a -> IO a
      dispatch request=either reject (evalCritical gate environment) (checkedRequest request)
  case process of
    SignerProcess _ endpoint->do
      credentials<-signerCredentials endpoint
      signingApplication credentials dispatch >>= runSigningServer endpoint
    WorkerProcess _ _ _ _ _ Checkpointing->
      dispatch (workerRequest CheckpointForUpgrade) >>= BL.putStr . (<> "\n") . encode
    WorkerProcess _ _ customerSettings _ _ (Serving port assets directory)->do
      reportCache<-newMVar Nothing
      let safeEnvironment=SafeEnvironment reader (publicConfiguration <$> customerSettings) reportCache
          evaluate :: forall caller a. Plan caller a -> IO a
          evaluate (SafePlan request)=evalSafe safeEnvironment request
          evaluate (CriticalPlan request)=dispatch request
      app<-publicApplication assets evaluate
      concurrently_
        (runPublicServer port app)
        (concurrently_ (runWorkerLoop dispatch) (runControl directory evaluate))

evalCritical :: MVar () -> Evaluation 'Critical -> DSL caller 'Critical a -> IO a
evalCritical gate environment operation=withMVar gate $ \_->case operation of
  Instruction op->do
    authorizeOperation environment op
    case (environment,operation) of
      -- Local key work is reachable only here, while the critical gate is held.
      (SignerEvaluation manager reader settings,SigningDSL signing)->do
        let native=signingNative settings
            solana=signingSolana settings
            config=signingPolicy settings
            -- The signer gate is already held; each closed read gets a fresh timestamp.
            withStableDecision :: Eq decision => (Int64 -> StoreRead decision) -> (decision -> IO a) -> IO a
            withStableDecision query work=do
              let readDecision=do
                    now<-floor <$> getPOSIXTime
                    evalRead reader (query now)
              before<-readDecision
              result<-work before
              after<-readDecision
              require (before==after) "signing_decision_changed"
              pure result
        case signing of
          CheckpointSigning (CheckpointCustody identity minimumSequence)->do
            require (identity==H.fingerprint config && minimumSequence>=0) "invalid_custody_checkpoint"
            (deployment,backup,parent)<-maybe (reject "custody_checkpoint_not_configured") pure (signingBackup settings)
            require (C.fingerprint deployment==identity && C.nativeSettings deployment==native
              && C.solanaSettings deployment==solana && C.nativeUnlockFile deployment==signingNativeUnlock settings) "signer_profile_mismatch"
            result<-timeout 300000000 $ bracket
              (evalCustodyRecovery manager deployment $ ExportCheckpoint reader (signingKey settings) parent minimumSequence)
              (removeDirectoryRecursive . takeDirectory . fst) $ \(manifest,sequenceNo)->do
                receipt<-evalCustodyRecovery manager deployment (UploadCustody backup manifest sequenceNo)
                after<-evalRead reader ReadState
                require (ledgerSequence after==sequenceNo) "custody_backup_changed"
                pure receipt
            CheckpointResult <$> maybe (reject "custody_checkpoint_timeout") pure result
          DraftSigning (DraftReplacement identity parent fee)->do
            require (identity==H.fingerprint config) "signer_profile_mismatch"
            DraftResult <$> withStableDecision (\now->ReadReplacementDraftContext now parent fee)
              (\family->NP.draftNativeReplacement (N.nativeCall manager native) native (map snd family) fee)
          ReplacementSigning (SignReplacement identity decision)->do
            require (identity==H.fingerprint config) "signer_profile_mismatch"
            (family,signed)<-withStableDecision (\now->ReadReplacementSigning now decision) $ \(family,draft)->do
              signed<-withNativeUnlock (N.nativeCall manager native) native (signingNativeUnlock settings) $
                NP.signNativeReplacement (N.nativeCall manager native) native (map snd family) draft
              pure (family,signed)
            parent<-case reverse family of (saved,_):_->pure saved; _->reject "native_replacement_family_bounds"
            pure $ ReplacementResult $ SignedAttempt (NP.nativeTxid $ NP.signedNativeTransaction signed) (NP.signedNativeBytes signed)
              (TE.decodeUtf8 $ BL.toStrict $ encode signed) (commonInput $ recordedSigned parent)
          PreparedSigning (SignPrepared identity identifier generation)->do
            require (identity==H.fingerprint config) "signer_profile_mismatch"
            PreparedResult <$> withStableDecision (\now->ReadSigningDecision now identifier generation) (\before->do
              plan<-resolveSigningPlan (N.profile native) config before
              reply<-case plan of
                NativeAuthorization saved draft->do
                  _<-N.nativeIdentity manager native
                  withNativeUnlock (N.nativeCall manager native) native (signingNativeUnlock settings) $
                    NativeReply <$> NP.signNativeDraft (N.nativeCall manager native) saved draft
                SolanaAuthorization saved expected->do
                  _<-S.solanaIdentity manager solana
                  let limits=config {H.maxSolFee=solPlanFeeLimit saved,H.maxSolAccountRent=solPlanRentLimit saved}
                      sign actual=do
                        require (actual==expected) "saved_solana_request_mismatch"
                        H.signSolanaSdk (signingLibrary settings) limits (signingKey settings) actual
                  SolanaReply <$> prepareSolanaSigned (S.solanaCall manager solana) sign limits saved
              verifySigningReply (N.nativeCall manager native) (N.profile native) config before reply)
      _->evaluateOperation environment op

-- Private resources, never callbacks or operations supplied by a caller.
data CriticalEnvironment = CriticalEnvironment
  Manager ObserverSettings H.SolanaPolicy (Maybe CustomerSettings) SigningEndpoint Reader Writer

data instance Evaluation 'Critical
  = WorkerEvaluation CriticalEnvironment
  | SignerEvaluation Manager Reader SignerSettings

paying :: CriticalEnvironment -> Bool
paying (CriticalEnvironment _ _ _ configured _ _ _)=maybe True (W.pubIntakeEnabled . publicConfiguration) configured

customer :: CriticalEnvironment -> IO CustomerSettings
customer (CriticalEnvironment _ _ _ configured _ _ _)=maybe (reject "customer_configuration_unavailable") pure configured

-- Internal instructions are already authorized under the caller's held gate.
-- They pass through the checked grammar without reacquiring that gate.
evalWorker :: CriticalEnvironment -> WorkerOperation a -> IO a
evalWorker environment operation=do
  program<-either reject pure (checkedRequest $ workerRequest operation)
  case program of Instruction op->evaluateOperation (WorkerEvaluation environment) op

evaluateSigning :: CriticalEnvironment -> SigningOperation a -> IO a
evaluateSigning environment operation=do
  program<-either reject pure (checkedRequest $ Request $ SignerAction operation)
  case program of Instruction op->evaluateOperation (WorkerEvaluation environment) op

instance Operation 'Signer 'Critical SignerCommand where
  type OperationContext 'Signer 'Critical SignerCommand = Operation 'Signer 'Critical SignerCommand
  command (SignerAction op)=SigningDSL op
  interpretOperation dsl@(Instruction (_ :: actual 'Critical a))=
    case eqT @(OperationContext 'Signer 'Critical SignerCommand) @(OperationContext 'Signer 'Critical actual) of
      Just Refl->Right dsl
      Nothing->Left "operation_dictionary_mismatch"
  authorizeOperation WorkerEvaluation{} _=reject "signer_operation_forbidden"
  authorizeOperation SignerEvaluation{} _=pure ()
  evaluateOperation (WorkerEvaluation environment@(CriticalEnvironment _ _ _ _ endpoint _ _)) (SignerAction operation)=do
    require (paying environment) "observation_only"
    credentials<-signerCredentials endpoint
    certificate<-signerCertificate endpoint
    let base=TLS.defaultParamsClient "127.0.0.1" BS.empty
        tls=base {TLS.clientShared=(TLS.clientShared base) {TLS.sharedCAStore=makeCertificateStore [certificate]}
          ,TLS.clientSupported=(TLS.clientSupported base) {TLS.supportedCiphers=ciphersuite_default}}
        settings=managerSetProxy noProxy (mkManagerSettings (NC.TLSSettings tls) Nothing)
          {managerRetryableException=const False,managerIdleConnectionCount=0
          ,managerResponseTimeout=responseTimeoutMicro (case operation of CheckpointSigning{}->315000000; _->60000000)
          ,managerModifyRequest= \request->pure request {redirectCount=0}
          ,managerModifyResponse= \response->do
            bytes<-boundedBody 524288 (responseBody response)
            body<-newIORef bytes
            pure response {responseBody=atomicModifyIORef' body $ \chunk->(BS.empty,chunk)}}
    bracket (newManager settings) closeManager $ \local->do
      let prepared :<|> replacement :<|> draft :<|> checkpoint=SC.client signingAPI credentials
          clientEnvironment=SC.mkClientEnv local (SC.BaseUrl SC.Https "127.0.0.1" (signerPort endpoint) "")
          call=case operation of
            CheckpointSigning (CheckpointCustody identity minimumSequence)->checkpoint (identity,minimumSequence)
            PreparedSigning (SignPrepared identity identifier generation)->prepared (identity,identifier,generation)
            ReplacementSigning (SignReplacement identity decision)->replacement (identity,decision)
            DraftSigning (DraftReplacement identity parent fee)->draft (identity,parent,fee)
      result<-SC.runClientM call clientEnvironment
      -- Even an HTTP failure may follow signing. Retain the preparation;
      -- never automatically retry or pretend the outcome is known.
      either (const $ reject "signer_outcome_unknown") pure result
  evaluateOperation SignerEvaluation{} _=reject "signer_evaluator_required"

instance Operation 'Customer 'Critical CustomerCommand where
  type OperationContext 'Customer 'Critical CustomerCommand = Operation 'Customer 'Critical CustomerCommand
  command (CustomerChange op)=WriteCustomer op
  interpretOperation dsl@(Instruction (_ :: actual 'Critical a))=
    case eqT @(OperationContext 'Customer 'Critical CustomerCommand) @(OperationContext 'Customer 'Critical actual) of
      Just Refl->Right dsl
      Nothing->Left "operation_dictionary_mismatch"
  authorizeOperation (WorkerEvaluation environment) _=require (paying environment) "observation_only"
  authorizeOperation SignerEvaluation{} _=reject "signer_context_forbidden"
  evaluateOperation SignerEvaluation{} _=reject "signer_context_forbidden"
  evaluateOperation (WorkerEvaluation environment@(CriticalEnvironment rpc settings config _ _ reader writer))
      (CustomerChange (Bridge.Operation.Internal.CreateOrder header request))=do
    c<-customer environment
    createCustomerOrder rpc settings config (customerPolicy c) (unsignedSdk c) (\n->evalWorker environment (CheckpointBackup n) >> freshIntake environment) reader writer header request

instance Operation 'Operator 'Critical OperatorCommand where
  type OperationContext 'Operator 'Critical OperatorCommand = Operation 'Operator 'Critical OperatorCommand
  command (OperatorChange op)=OperatorDSL op
  interpretOperation dsl@(Instruction (_ :: actual 'Critical a))=
    case eqT @(OperationContext 'Operator 'Critical OperatorCommand) @(OperationContext 'Operator 'Critical actual) of
      Just Refl->Right dsl
      Nothing->Left "operation_dictionary_mismatch"
  authorizeOperation SignerEvaluation{} _=reject "signer_context_forbidden"
  authorizeOperation (WorkerEvaluation environment) (OperatorChange operation)=case operation of
    PauseService{}->pure ()
    _->require (paying environment) "observation_only"
  evaluateOperation SignerEvaluation{} _=reject "signer_context_forbidden"
  evaluateOperation (WorkerEvaluation environment@(CriticalEnvironment rpc settings config _ _ reader writer)) (OperatorChange operation)=run operation
   where
    native=nativeSettings settings
    solana=solanaSettings settings
    run :: forall a. OperatorWrite a -> IO a
    run (RebroadcastNative txid anchor reason)=guarded environment $ do
      require (NP.transactionId txid && anchor>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_native_rebroadcast_approval"
      (saved,family,current)<-evalRead reader (ReadNativeRebroadcastContext txid)
      previous<-evalRead reader (ReadNativeRebroadcastDecision txid anchor reason)
      require (current==maybe anchor id previous) "native_rebroadcast_review_changed"
      let missing=do
            (actual,view)<-readSavedNativeFamily (N.nativeCall rpc native) native config reader (recordedPayment saved)
            require (actual==family) "native_replacement_family_changed"
            require (NP.familyActive view==Nothing) "native_rebroadcast_payment_not_missing"
            pure view
      before<-missing
      refreshSource environment (recordedPayment saved)
      block<-RPC.fieldValue "hash" (NP.familyPosition before) :: IO Text
      let proof=object ["transaction" .= txid,"bytesHash" .= digest(TE.encodeUtf8 $ signedBytes $ recordedSigned saved)
            ,"nodeBlock" .= block,"family" .= map (signedId.recordedSigned.fst) family,"noActiveFamilyPayment" .= True]
      approved<-maybe (evalWrite writer $ RecordNativeRebroadcast saved (map fst family) anchor reason proof) pure previous
      backupDecisions environment
      -- Backup may be slow. Recheck source and exact family immediately before
      -- authorizing the saved bytes. An uncertain send never triggers a retry.
      refreshSource environment (recordedPayment saved)
      _<-missing
      authorized<-evalWrite writer (AuthorizeNativeRebroadcast saved (map fst family) approved)
      actual<-N.nativeCall rpc native True "sendrawtransaction" [toJSON $ signedBytes $ recordedSigned authorized] >>= parseValue parseJSON
      require (actual==txid) "native_broadcast_identity_mismatch"
      pure txid
    run (CoverLostSource receipt recovery capital earned reason)=guarded environment $ do
      require (recovery>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_loss_cover"
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      previous<-evalRead reader (ReadLossCover receipt recovery)
      case previous of
        Just old->require (old==(capital,earned,reason)) "source_loss_cover_conflict"
        Nothing->do
          source<-evalRead reader (ReadSource receipt)
          proof<-proveMissing environment source
          custody<-inspectLossCustody rpc settings config reader
          now<-floor <$> getPOSIXTime
          evalWrite writer (CoverSourceLoss source recovery now capital earned reason proof custody)
    run (ApproveCovered key recovery reason)=guarded environment $ do
      require (recovery>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      previous<-evalRead reader (ReadCoveredApproval key recovery)
      case previous of
        Just old->require (old==reason) "source_approval_conflict"
        Nothing->do
          evalRead reader (CheckCoveredSource key recovery)
          binding<-evalRead reader (ReadPaymentSource key) >>= maybe (reject "source_approval_not_expected") pure
          proof<-proveMissing environment (W.sourceDeposit binding)
          reconcilePending environment >>= mapM_ (either throwIO pure)
          evalWorker environment ReconcileCustody
          now<-floor <$> getPOSIXTime
          evalWrite writer (ApproveCoveredSource now key recovery reason proof)
    run (RestoreSource key restoration reason)=guarded environment $ do
      require (restoration>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      previous<-evalRead reader (ReadSourceApproval key restoration)
      case previous of
        Just old->require (old==reason) "source_approval_conflict"
        Nothing->do
          evalRead reader (CheckSourceRestoration key restoration)
          refreshSource environment key
          reconcilePending environment >>= mapM_ (either throwIO pure)
          evalWorker environment ReconcileCustody
          now<-floor <$> getPOSIXTime
          evalWrite writer (ApproveSourceRestoration now key restoration reason)
    run (ClassifySpend chain key reason)=evalWrite writer (ClassifyTreasurySpend chain key reason)
    run (AllocateReceipt receipt split reason)=do
      now<-floor <$> getPOSIXTime
      evalWrite writer (AllocateTreasury now receipt split reason)
    run (WithdrawFees key asset quantity recipient reason)=guarded environment $ do
      c<-customer environment
      require (T.length key==64 && T.all (`elem` ("0123456789abcdef"::String)) key
        && not(T.null $ T.strip reason) && T.length reason<=512
        && units quantity>0 && quantity<=maximumWithdrawal(admissionLimits $ customerPolicy c)
        && asset `elem` [Native,Wrapped]) "invalid_fee_withdrawal"
      previous<-evalRead reader (ReadWithdrawal key)
      case previous of
        Just _->pure () -- Store checks exact immutable replay before returning it.
        Nothing->do
          state<-evalRead reader ReadState
          require (ledgerPaused state) "pause_before_operator_action"
          case asset of
            Native->do
              _<-N.nativeIdentity rpc native
              previewNativePayment (N.nativeCall rpc native) (N.profile native) (defaultNativeDepth settings)
                (W.savedNativeFee $ W.paymentLimits $ executionTerms $ customerPolicy c) recipient quantity
            Wrapped->do
              _<-S.solanaIdentity rpc solana
              checkSolanaPayoutWith (S.solanaCall rpc solana) (H.invokeUnsignedHelper (unsignedSdk c) config) config recipient quantity
            Sol->reject "invalid_payout_asset"
          evalWorker environment ReconcileCustody
      now<-floor <$> getPOSIXTime
      paymentId . withdrawalPayment <$> evalWrite writer (ReserveFees now key asset quantity recipient reason)
    run (CancelFeeWithdrawal key reason)=do
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      paymentId . withdrawalPayment <$> evalWrite writer (CancelFees key reason)
    run (DraftNativeReplacement parent fee reason)=guarded environment $ do
      require (NP.transactionId parent && units fee>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_native_replacement_decision"
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      previous<-evalRead reader (ReadReplacementDecision parent fee reason)
      case previous of
        Just (decision,cancelled)->require (not cancelled) "native_replacement_cancelled" >> pure decision
        Nothing->do
          saved<-evalRead reader (ReadAttempt parent)
          require (recordedChain saved=="Native") "native_replacement_not_expected"
          refreshSource environment (recordedPayment saved)
          evalWorker environment ReconcileCustody
          now<-floor <$> getPOSIXTime
          family<-evalRead reader (ReadReplacementDraftContext now parent fee)
          draft<-draftOutput <$> evaluateSigning environment (DraftSigning $ DraftReplacement (H.fingerprint config) parent fee)
          either reject pure (NP.validateNativeReplacementDraft (map snd family) fee draft)
          later<-floor <$> getPOSIXTime
          evalWrite writer (SaveReplacementDraft later saved draft reason)
    run (SignNativeReplacement decision)=guarded environment $ do
      require (decision>0) "invalid_native_replacement_decision"
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      previous<-evalRead reader (ReadReplacementMember decision)
      case previous of
        Just saved->pure (signedId $ recordedSigned saved)
        Nothing->do
          identifier<-evalRead reader (ReadReplacementPayment decision)
          refreshSource environment identifier
          backupDecisions environment
          evalWorker environment ObserveChains
          evalWorker environment ReconcileCustody
          now<-floor <$> getPOSIXTime
          (family,draft)<-evalRead reader (ReadReplacementSigning now decision)
          wire<-replacementOutput <$> evaluateSigning environment (ReplacementSigning $ SignReplacement (H.fingerprint config) decision)
          signed<-decode (signedPolicy wire)
          require (signedId wire==NP.nativeTxid(NP.signedNativeTransaction signed)
            && signedBytes wire==NP.signedNativeBytes signed
            && commonInput wire==commonInput(recordedSigned $ fst $ last family)) "native_replacement_signature_conflict"
          either reject pure (NP.validateNativeFamily $ map snd family<>[signed])
          require (NP.sameNativeTemplate (NP.draftTransaction draft) (NP.signedNativeTransaction signed)
            && NP.draftFee draft==NP.signedNativeFee signed
            && NP.sameNativePrevouts (NP.draftPrevouts draft) (NP.signedNativePrevouts signed)) "native_replacement_signed_template_changed"
          actual<-N.nativeCall rpc native False "decoderawtransaction" [toJSON $ signedBytes wire] >>= either reject pure . NP.decodeNativeTx
          require (actual==NP.signedNativeTransaction signed) "native_signed_bytes_mismatch"
          later<-floor <$> getPOSIXTime
          saved<-evalWrite writer (RecordReplacement later decision family signed)
          pure (signedId $ recordedSigned saved)
    run (CancelNativeReplacement decision reason)=
      evalWrite writer (CancelReplacementDraft decision reason)
    run (RetrySolanaPayment txid reason)=guarded environment $ do
      require (not(T.null $ T.strip reason) && T.length reason<=512) "invalid_retry_approval"
      previous<-evalRead reader (ReadRetryApproval txid)
      case previous of
        Just old->require (old==reason) "retry_approval_conflict"
        Nothing->do
          state<-evalRead reader ReadState
          require (ledgerPaused state) "pause_before_operator_action"
          saved<-evalRead reader (ReadAttempt txid)
          expired<-evalRead reader (ReadSolanaExpiry txid)
          require (recordedChain saved=="Solana" && recordedState saved=="review" && expired/=Nothing) "solana_retry_not_expected"
          prepared<-evalRead reader (ReadRecordedPreparation txid)
          verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared (recordedSigned saved)
          signed<-decode (signedPolicy $ recordedSigned saved)
          refreshSource environment (recordedPayment saved)
          proof<-expiry environment signed >>= maybe (reject "solana_expiry_not_proven") pure
          evalWorker environment ReconcileCustody
          now<-floor <$> getPOSIXTime
          evalWrite writer (ApproveSolanaRetry now saved reason proof)
    run (CancelPreparation identifier generation reason)=guarded environment $ do
      require (generation>=0 && generation<8 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_preparation_cancellation"
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      previous<-evalRead reader (ReadCancellation identifier generation)
      forM_ previous $ \(old,_,_)->require (old==reason) "preparation_cancellation_conflict"
      case previous of
        Just (_,_,True)->pure ()
        _->do
          unsigned<-evalRead reader (ReadUnsignedPreparation identifier)
          require (preparedGeneration unsigned==generation) "preparation_generation_changed"
          case paymentAsset(savedPayment $ preparedView unsigned) of
            Native->N.nativeIdentity rpc native >> pure ()
            Wrapped->S.solanaIdentity rpc solana >> pure ()
            Sol->reject "invalid_payout_asset"
          refreshSource environment identifier
          evalWorker environment ReconcileCustody
          prepared<-evalRead reader (ReadUnsignedPreparation identifier)
          require (preparedGeneration prepared==generation) "preparation_generation_changed"
          (points,cleanup)<-cancellationPlan (N.nativeCall rpc native) (N.profile native) config prepared
          forM_ previous $ \(_,plan,_)->require (plan==cleanup) "preparation_cancellation_conflict"
          now<-floor <$> getPOSIXTime
          evalWrite writer (BeginCancellation prepared now reason cleanup)
          when (paymentAsset(savedPayment $ preparedView prepared)==Native) $
            releaseNativeInputLocks (N.nativeCall rpc native) points
          evalWrite writer (FinishCancellation prepared reason cleanup)
    run (RefundDeposit receipt)=do
      now<-floor <$> getPOSIXTime
      evalWrite writer (AuthorizeRefund now receipt)
    run (RepairCompletedOrder order)=do
      now<-floor <$> getPOSIXTime
      evalWrite writer (RepairCompletedOrderView now order)
    run (PauseService reason)=evalWrite writer (Pause reason)
    run ResumeService=guarded environment $ do
      state<-evalRead reader ReadState
      require (ledgerPaused state) "pause_before_operator_action"
      N.verifyNativeBoundaryWith (N.nativeCall rpc native)
      recoverPending environment
      ids<-evalRead reader PendingAttempts
      reviewed<-mapM (evalRead reader . ReadAttempt) ids
      forM_ reviewed (refreshSource environment . recordedPayment)
      backupDecisions environment
      evalWorker environment ObserveChains
      evalWorker environment ReconcileCustody
      -- Revalidate unknown native signing outcomes without signing or changing
      -- the saved generation. Resume commits only if this exact work remains.
      nativeWork<-evalRead reader ReadNativeLockWork
      unsigned<-case nativeWork of
        Just work | null(lockAttempts work) && not(lockCancelling work)
          && preparedDraft(lockPreparation work)/=Nothing->do
            _<-restoreNativeWork (N.nativeCall rpc native) native config nativeWork
            pure nativeWork
        _->pure Nothing
      now<-floor <$> getPOSIXTime
      evalWrite writer (ResumeLedger now [("Native",N.nativeCheckpointHash native),("Solana",tokenOrigin settings),("SolanaOperating",operatingOrigin settings)] reviewed unsigned)

instance Operation 'Worker 'Critical WorkerCommand where
  type OperationContext 'Worker 'Critical WorkerCommand = Operation 'Worker 'Critical WorkerCommand
  command (WorkerAction op)=WorkerDSL op
  interpretOperation dsl@(Instruction (_ :: actual 'Critical a))=
    case eqT @(OperationContext 'Worker 'Critical WorkerCommand) @(OperationContext 'Worker 'Critical actual) of
      Just Refl->Right dsl
      Nothing->Left "operation_dictionary_mismatch"
  authorizeOperation SignerEvaluation{} _=reject "signer_context_forbidden"
  authorizeOperation (WorkerEvaluation environment) (WorkerAction operation)=case operation of
    RecoverNativeSources->pure ()
    RecoverNativeSettlements->pure ()
    RecoverNativeLocks->pure ()
    RunWorkerCycle->pure ()
    ObserveChains->pure ()
    ReconcileCustody->pure ()
    ReconcilePayment{}->pure ()
    _->require (paying environment) "observation_only"
  evaluateOperation SignerEvaluation{} _=reject "signer_context_forbidden"
  evaluateOperation (WorkerEvaluation environment@(CriticalEnvironment rpc settings config _ _ reader writer)) (WorkerAction operation)=run operation
   where
    native=nativeSettings settings
    solana=solanaSettings settings
    checkpoint :: Int64 -> LedgerState -> IO W.BackupReceipt
    checkpoint minimumSequence before=do
      receipt<-checkpointOutput <$> evaluateSigning environment
        (CheckpointSigning $ CheckpointCustody (H.fingerprint config) minimumSequence)
      let hash value=T.length value==64 && T.all (`elem` ("0123456789abcdef"::String)) value
      require (W.receiptIdentity receipt==H.fingerprint config && W.receiptSequence receipt==ledgerSequence before
        && hash (W.receiptSnapshot receipt) && hash (W.receiptArchiveHash receipt)) "invalid_custody_checkpoint_receipt"
      after<-evalRead reader ReadState
      require (ledgerSequence after==ledgerSequence before) "custody_backup_changed"
      evalWrite writer (AcknowledgeBackup (W.receiptIdentity receipt) (W.receiptSequence receipt) (W.receiptSnapshot receipt))
      pure receipt
    run :: forall a. WorkerOperation a -> IO a
    run CheckpointForUpgrade = guarded environment $ do
      before<-evalRead reader ReadState
      require (ledgerPaused before) "pause_before_upgrade_checkpoint"
      checkpoint (ledgerSequence before) before
    run (CheckpointBackup minimumSequence) = guarded environment $ do
      before<-evalRead reader ReadState
      require (minimumSequence>=0 && minimumSequence<=ledgerSequence before) "invalid_custody_checkpoint"
      when (ledgerBackup before<minimumSequence) $ checkpoint minimumSequence before >> pure ()
    run RecoverNativeSettlements = guarded environment $ do
      candidates<-evalRead reader NativeSettlementCandidates
      outcomes<-forM candidates $ \saved->tryBridge $ do
        inspected<-tryBridge $ do
          (family,view)<-readSavedNativeFamily (N.nativeCall rpc native) native config reader (recordedPayment saved)
          require (saved `elem` map fst family) "native_settlement_changed"
          active<-activeNativeMember family view
          case active of
            Nothing->pure $ NativeUnavailable "native_settled_payment_unseen"
            Just (winner,signed,depth,proof)->do
              outcome<-nativeConfirmation (N.nativeCall rpc native) signed depth proof
              case outcome of
                PaymentWaiting->pure NativeConfirming
                PaymentConfirmed costs evidence->pure $
                  if winner==saved then NativeReconfirmed costs evidence
                  else NativeWinnerChanged (map fst family) (signedId $ recordedSigned winner) costs evidence
                _->reject "unexpected_native_payment_failure"
        let result=either (\(BridgeError code)->NativeUnavailable code) id inspected
        committed<-tryBridge (evalWrite writer $ RecordNativeSettlement saved result)
        case committed of
          Right ()->pure ()
          Left (BridgeError code)->evalWrite writer (RecordNativeSettlement saved $ NativeUnavailable code)
      mapM_ (either throwIO pure) outcomes
    run RecoverNativeSources = do
      sources<-evalRead reader NativeSourceCandidates
      outcomes<-forM sources $ \source->tryBridge $ do
        result<-tryBridge $ do
          _<-N.nativeIdentity rpc native
          (binding,evidence)<-evalRead reader (ReadNativeSourceInspection $ W.depositId source)
          inspectNativeSource (N.nativeCall rpc native) native (defaultNativeDepth settings) (H.fingerprint config) source binding evidence
        let unavailable code=W.SourceUnavailable $ object ["reason" .= code]
            checked=either (\(BridgeError code)->unavailable code) id result
        recorded<-tryBridge (evalWrite writer $ RecordSourceCheck source checked)
        case recorded of
          Right ()->pure ()
          Left (BridgeError code)->evalWrite writer (RecordSourceCheck source $ unavailable code)
      mapM_ (either throwIO pure) outcomes
    run RecoverNativeLocks = guarded environment $ do
      _<-N.nativeIdentity rpc native
      _<-N.nativeWalletInfoWith (N.nativeCall rpc native) native
      saved<-evalRead reader ReadNativeLockWork
      restored<-restoreNativeWork (N.nativeCall rpc native) native config saved
      when (restored>0) $ forM_ saved $ \work->evalWrite writer (RecordNativeLockRestore work restored)
    run ObserveChains = observeOnce rpc settings reader writer
    run (PrepareOutgoing identifier) = guarded environment $ do
      now<-floor <$> getPOSIXTime
      evalRead reader (CheckIntake now)
      _<-evalRead reader (ReadPayment identifier)
      _<-N.nativeIdentity rpc native
      _<-S.solanaIdentity rpc solana
      refreshSource environment identifier
      freshIntake environment
      -- Plan RPC and source updates may age or invalidate custody before commit.
      _<-prepareUnsigned (freshIntake environment >> floor <$> getPOSIXTime) (N.nativeCall rpc native) (S.solanaCall rpc solana)
        (N.profile native) config reader writer identifier
      pure ()
    run ReconcileCustody = reconcileCustody rpc settings config reader writer
    run (QueuePayment txid) = guarded environment $ do
      (recorded,_)<-loadActive environment txid
      refreshSource environment (recordedPayment recorded)
      freshIntake environment
      now<-floor <$> getPOSIXTime
      evalWrite writer (MarkBroadcast now txid)
    run (BroadcastPayment txid) = guarded environment $ do
      (recorded,reply)<-loadActive environment txid
      require (recordedState recorded=="broadcast_intent") "broadcast_intent_required"
      (observedAttempt,observed)<-observeAttempt environment recorded reply
      case observed of
        PaymentUnseen->do
          refreshSource environment (recordedPayment recorded)
          freshIntake environment
          case reply of
            NativeReply signed->checkNativeAcceptance (N.nativeCall rpc native) signed
            SolanaReply signed->checkBlockhashForSend (S.solanaCall rpc solana) (solPlanRecent $ signedSolanaPlan signed)
          now<-floor <$> getPOSIXTime
          authorized<-evalWrite writer (AuthorizeSend now txid)
          require (authorized==recorded) "saved_payment_changed"
          actual<-case reply of
            NativeReply _->N.nativeCall rpc native True "sendrawtransaction" [toJSON $ signedBytes $ recordedSigned authorized] >>= parseValue parseJSON
            SolanaReply _->S.solanaCall rpc solana "sendTransaction" [toJSON $ signedBytes $ recordedSigned authorized,object
              ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("confirmed"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
          require (actual==txid) "broadcast_identifier_mismatch"
        _->recordOutcome environment observedAttempt observed
    run (ReconcilePayment txid) = guarded environment $ do
      recorded<-evalRead reader (ReadAttempt txid)
      retired<-evalRead reader (ReadSolanaExpiry txid)
      payment<-evalRead reader (ReadPayment $ recordedPayment recorded)
      if savedStatus payment==PaymentPaid || recordedState recorded `elem` ["settled","failed"] || retired/=Nothing then pure () else do
        (current,reply)<-loadActive environment txid
        (winner,outcome)<-observeAttempt environment current reply
        recordOutcome environment winner outcome
    run (SignPreparedPayment identifier) = signing `onException` evalWrite writer (Pause "signing_requires_review")
     where
      signing = do
        (_,saved,attempts)<-evalRead reader (ReadPaymentWork identifier)
        prepared<-maybe (reject "payment_not_prepared") pure saved
        case attempts of
          []->issue prepared
          [txid]->do
            recorded<-evalRead reader (ReadAttempt txid)
            require (recordedPayment recorded==identifier && recordedGeneration recorded==preparedGeneration prepared) "payment_requires_recovery"
            verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared (recordedSigned recorded)
            pure txid
          _->reject "payment_requires_recovery"
      issue prepared = do
        _<-resolveSigningPlan (N.profile native) config prepared
        refreshSource environment identifier
        freshIntake environment
        now<-floor <$> getPOSIXTime
        decision<-evalRead reader (ReadSigningDecision now identifier $ preparedGeneration prepared)
        require (decision==prepared) "preparation_changed"
        signed<-preparedOutput <$> evaluateSigning environment (PreparedSigning $ SignPrepared (H.fingerprint config) identifier $ preparedGeneration prepared)
        verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared signed
        recorded<-evalWrite writer (RecordAttempt prepared signed)
        pure (signedId $ recordedSigned recorded)
    run RunWorkerCycle = cycleWork `catch` (\(BridgeError code)->
      if code=="custody_not_reconciled" then do
        paused<-ledgerPaused <$> evalRead reader ReadState
        when paused (reject code)
      else evalWrite writer (Pause code) >> reject code)
     where
      cycleWork = do
        recoverPending environment
        state<-evalRead reader ReadState
        when (paying environment && not(ledgerPaused state)) $ do
          candidates<-evalRead reader PaymentCandidates
          forM_ candidates $ \identifier->do
            freshIntake environment
            (_,_,attempts)<-evalRead reader (ReadPaymentWork identifier)
            txid<-case attempts of
              []->do
                evalWorker environment (PrepareOutgoing identifier)
                backupDecisions environment
                evalWorker environment (SignPreparedPayment identifier)
              [saved]->pure saved
              _->do
                family<-evalRead reader (ReadNativeFamily identifier)
                pure (signedId $ recordedSigned $ fst $ last family)
            _<-evalWorker environment (QueuePayment txid)
            backupDecisions environment
            evalWorker environment (BroadcastPayment txid)

-- Shared workflows take only the private resource context.
-- Refresh stale evidence after slow checkpoints; never extend quote/backup terms.
freshIntake :: CriticalEnvironment -> IO ()
freshIntake environment@(CriticalEnvironment _ _ _ _ _ reader _)=refresh 2
 where
  -- Custody RPC can age previously fresh scans; permit one further refresh.
  refresh :: Int -> IO ()
  refresh remaining=do
    now<-floor <$> getPOSIXTime
    result<-tryBridge (evalRead reader $ CheckIntake now)
    case result of
      Left (BridgeError code) | remaining>0 && code `elem` ["scanners_not_fresh","custody_not_reconciled"]->do
        when (code=="scanners_not_fresh") (evalWorker environment ObserveChains)
        evalWorker environment ReconcileCustody
        refresh (remaining-1)
      _->either throwIO pure result

backupDecisions :: CriticalEnvironment -> IO ()
backupDecisions environment@(CriticalEnvironment _ _ _ _ _ reader _)=do
  c<-customer environment
  when (requireBackup $ customerPolicy c) $ do
    before<-evalRead reader ReadState
    when (ledgerBackup before<ledgerSequence before) $ do
      evalWorker environment (CheckpointBackup $ ledgerSequence before)
      after<-evalRead reader ReadState
      require (ledgerBackup after>=ledgerSequence before) "backup_pending"

-- Explicit resume retains every recovery error; only the worker may defer custody.
recoverPending :: CriticalEnvironment -> IO ()
recoverPending environment@(CriticalEnvironment _ _ _ _ _ _ writer)=do
  locks<-tryBridge (evalWorker environment RecoverNativeLocks)
  scanned<-tryBridge (evalWorker environment ObserveChains)
  sources<-tryBridge (evalWorker environment RecoverNativeSources)
  now<-floor <$> getPOSIXTime
  evalWrite writer (ExpireQuotes now)
  outcomes<-reconcilePending environment
  settled<-tryBridge (evalWorker environment RecoverNativeSettlements)
  evalWorker environment ReconcileCustody
  mapM_ (either throwIO pure) (locks:scanned:sources:settled:outcomes)

-- Inspect each economic payment once, including its native replacement family.
reconcilePending :: CriticalEnvironment -> IO [Either BridgeError ()]
reconcilePending environment@(CriticalEnvironment _ _ _ _ _ reader _)=do
  pending<-evalRead reader PendingAttempts >>= mapM (evalRead reader . ReadAttempt)
  let families=M.elems $ M.fromList [(recordedPayment saved,saved)|saved<-pending]
  mapM (tryBridge . evalWorker environment . ReconcilePayment . signedId . recordedSigned) families

tryBridge :: forall result. IO result -> IO (Either BridgeError result)
tryBridge work=try (work `catch` (\(_::IOException)->reject "worker_io_unavailable"))

guarded :: CriticalEnvironment -> IO a -> IO a
guarded (CriticalEnvironment _ _ _ _ _ _ writer) operation=operation `onException` evalWrite writer (Pause "payment_requires_reconciliation")

decode :: forall result. FromJSON result => Text -> IO result
decode proof=either (const $ reject "invalid_saved_payment") pure (eitherDecodeStrict' $ TE.encodeUtf8 proof)

loadActive :: CriticalEnvironment -> Text -> IO (RecordedAttempt,SigningReply)
loadActive (CriticalEnvironment rpc settings config _ _ reader _) txid = do
  recorded<-evalRead reader (ReadAttempt txid)
  require (recordedState recorded `elem` ["signed","broadcast_intent"]) "payment_requires_recovery"
  prepared<-evalRead reader (ReadPreparation $ recordedPayment recorded)
  require (preparedGeneration prepared==recordedGeneration recorded) "payment_requires_recovery"
  let saved=recordedSigned recorded
  case recordedChain recorded of
    "Native"->do
      family<-evalRead reader (ReadNativeFamily $ recordedPayment recorded)
      require (recorded `elem` map fst family) "native_replacement_family_changed"
      case family of
        [(first,_)]->verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared (recordedSigned first)
        _->nativePreparationPlan (N.profile native) config prepared >> pure ()
    _->verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared saved
  reply<-case recordedChain recorded of
    "Native"->NativeReply <$> (decode (signedPolicy saved) :: IO NativeSigned)
    "Solana"->SolanaReply <$> (decode (signedPolicy saved) :: IO SolanaSigned)
    _->reject "invalid_payout_asset"
  pure (recorded,reply)
 where
  native=nativeSettings settings

observeAttempt :: CriticalEnvironment -> RecordedAttempt -> SigningReply -> IO (RecordedAttempt,PaymentObservation)
observeAttempt (CriticalEnvironment rpc settings config _ _ reader _) recorded reply=case reply of
  NativeReply _->do
    (members,view)<-readSavedNativeFamily (N.nativeCall rpc native) native config reader (recordedPayment recorded)
    require (recorded `elem` map fst members) "native_replacement_family_changed"
    active<-activeNativeMember members view
    case active of
      Just (winner,payment,depth,value) | depth>0 || winner==recorded->do
        result<-nativeConfirmation (N.nativeCall rpc native) payment depth value
        pure (winner,result)
      _->pure (recorded,if recorded==fst(last members) then PaymentUnseen else PaymentWaiting)
  SolanaReply signed->do
    _<-S.solanaIdentity rpc solana
    result<-observeSolanaPayment (S.solanaCall rpc solana) config signed
    pure (recorded,result)
 where
  native=nativeSettings settings; solana=solanaSettings settings

recordOutcome :: CriticalEnvironment -> RecordedAttempt -> PaymentObservation -> IO ()
recordOutcome environment@(CriticalEnvironment _ _ _ _ _ _ writer) recorded observed=case observed of
  PaymentUnseen->when (recordedChain recorded=="Solana") $ do
    signed<-decode (signedPolicy $ recordedSigned recorded)
    proof<-expiry environment signed
    forM_ proof (evalWrite writer . RecordSolanaExpiry recorded)
  PaymentWaiting->require (recordedState recorded=="broadcast_intent") "unrecorded_broadcast_observed"
  PaymentConfirmed costs proof->evalWrite writer (SettlePayment recorded costs proof)
  PaymentFailed fee proof->evalWrite writer (FailSolana recorded fee proof)

expiry :: CriticalEnvironment -> SolanaSigned -> IO (Maybe Text)
expiry (CriticalEnvironment rpc settings config _ _ reader _) signed=do
  let origins=(tokenOrigin settings,operatingOrigin settings)
  evalRead reader (CheckExpiryOrigins origins)
  solanaExpiryEvidence (S.solanaCall rpc solana)
    (fmap (\url->RPC.rpc rpc url Nothing) $ S.solanaVerifierRpc solana) (N.profile native) config origins signed
 where
  native=nativeSettings settings; solana=solanaSettings settings

proveMissing :: CriticalEnvironment -> W.Deposit -> IO Value
proveMissing (CriticalEnvironment rpc settings config _ _ reader _) source = do
  _<-N.nativeIdentity rpc native
  (binding,evidence)<-evalRead reader (ReadNativeSourceInspection $ W.depositId source)
  result<-inspectNativeSource (N.nativeCall rpc native) native (defaultNativeDepth settings) (H.fingerprint config) source binding evidence
  case result of W.SourceMissing proof->pure proof; _->reject "source_loss_not_proven"
 where
  native=nativeSettings settings

refreshSource :: CriticalEnvironment -> Text -> IO ()
refreshSource environment@(CriticalEnvironment rpc settings config _ _ reader writer) identifier = do
  source<-evalRead reader (ReadPaymentSource identifier)
  forM_ source $ \binding->do
    let saved=W.sourceDeposit binding
    if W.depositAsset saved==Native && not(W.depositEligible saved) then do
      evalRead reader (CheckPaymentSource identifier)
      proof<-proveMissing environment saved
      evalWrite writer (RecordSourceCheck saved $ W.SourceMissing proof)
     else do
      case W.depositAsset saved of
        Native->N.nativeIdentity rpc native >> pure ()
        Wrapped->S.solanaIdentity rpc solana >> pure ()
        Sol->reject "unsupported_source_asset"
      observed<-verifyPaymentSource (N.nativeCall rpc native) (S.solanaCall rpc solana)
        (fmap (\url->RPC.rpc rpc url Nothing) $ S.solanaVerifierRpc solana) (N.profile native) config binding
      evalWrite writer (RefreshPaymentSource saved observed)
    evalRead reader (CheckPaymentSource identifier)
 where
  native=nativeSettings settings; solana=solanaSettings settings

-- The caller owns this lifetime (run it alongside HTTP with structured concurrency).
-- Async cancellation and database failures escape; they are never retried as work.
runWorkerLoop :: (forall a. Request 'Worker 'Critical a -> IO a) -> IO ()
runWorkerLoop evaluate=forever $ do
  evaluate (workerRequest RunWorkerCycle) `catch` (\(BridgeError code)->hPutStrLn stderr ("worker: "<>T.unpack code))
  threadDelay 15000000
