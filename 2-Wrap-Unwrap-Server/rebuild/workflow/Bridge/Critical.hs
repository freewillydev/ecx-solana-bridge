{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables #-}
-- The signer ClientM is constructed only inside this critical evaluator.
module Bridge.Critical (CustomerSettings(..),withRuntime,runWorkerLoop) where
import Bridge.Operation.Internal
import Bridge.Domain (Asset(..),gross,paymentAsset,paymentId,units)
import Bridge.Identity (payURIFor)
import Bridge.Admission (checkSolanaPayoutWith)
import Bridge.Order (createCustomerOrder)
import Data.Int (Int64)
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
import Bridge.SolanaPayment (SolanaSigned,signedSolanaPlan,solPlanRecent,checkBlockhashWindow)
import Data.Text (Text)
import Bridge.PaymentObservation
import qualified Bridge.Solana as S
import Data.Aeson (eitherDecodeStrict',FromJSON,toJSON,object,(.=),parseJSON)
import qualified Data.Text.Encoding as TE
import Bridge.Signer (signingAPI)
import Bridge.SigningTransport
import Bridge.Store
import qualified Bridge.Native as N
import qualified Bridge.SolanaHelper as H
import Bridge.RPC (boundedBody,parseValue)
import qualified Bridge.RPC as RPC
import Control.Concurrent (threadDelay)
import System.IO (hPutStrLn,stderr)
import Control.Concurrent.MVar (newMVar,withMVar)
import Control.Exception (bracket,onException,try,catch,throwIO,IOException)
import Data.IORef (newIORef,atomicModifyIORef')
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client hiding (Request)
import Network.HTTP.Client.TLS (mkManagerSettings)
import qualified Network.Connection as NC
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher (ciphersuite_default)
import Data.X509.CertificateStore (makeCertificateStore)
import Servant.API ((:<|>)(..))
import qualified Servant.Client as SC

-- The safe evaluator receives only read credentials and public configuration.
-- It cannot access the writer, signer transport, backup callback or RPC manager.
evalSafe :: Reader -> Maybe W.PublicConfiguration -> DSL caller 'Safe a -> IO a
evalSafe reader public operation = case operation of
  ReadOperator ServiceState->do
    state<-evalRead reader ReadState
    pure $ W.ServiceStatus (ledgerPaused state) (ledgerReason state) (ledgerSequence state) (ledgerBackup state)
  ReadCustomer PublicConfig->do
    configuration<-configured
    if not(W.pubIntakeEnabled configuration) then pure configuration {W.pubAvailability=W.Availability False "observation_only"} else do
      now<-floor <$> getPOSIXTime
      result<-try (evalRead reader $ CheckIntake now) :: IO (Either BridgeError ())
      let state=case result of Right ()->W.Availability True ""; Left (BridgeError code)->W.Availability False code
      pure configuration {W.pubAvailability=state}
  ReadCustomer (OrderStatus header identifier)->evalRead reader (ReadOrder header identifier)
  ReadCustomer (PaymentInstructions header identifier)->do
    configuration<-configured
    require (W.pubIntakeEnabled configuration) "deposit_window_closed"
    now<-floor <$> getPOSIXTime
    view<-evalRead reader (ReadPayableOrder now header identifier)
    instruction<-maybe (reject "instruction_not_recorded") pure (W.depositInstruction view)
    let mint=W.pubMint configuration
    uri<-either reject pure (payURIFor (W.pubCustodyOwner configuration) mint instruction (gross $ W.quote view))
    pure $ W.PaymentInstruction uri (T.drop 11 instruction) mint (gross $ W.quote view) "verified_source_owner"
 where configured=maybe (reject "customer_configuration_unavailable") pure public

data CustomerSettings = CustomerSettings
  { publicConfiguration :: W.PublicConfiguration, customerPolicy :: StorePolicy
  , unsignedSdk :: FilePath, coverBackup :: Int64 -> IO () }

-- Startup supplies capabilities. Customer and worker requests share one dispatch
-- and one gate; safe reads have no writer, signer or network capability.
withRuntime :: Manager -> ObserverSettings -> H.SolanaPolicy -> Maybe CustomerSettings -> SigningEndpoint -> Reader -> Writer
  -> ((forall a. Request 'Worker 'Critical a -> IO a) -> (forall a. Plan 'Customer a -> IO a) -> (forall a. Plan 'Operator a -> IO a) -> IO b) -> IO b
withRuntime rpc settings config customerSettings endpoint reader writer action = do
  let native=nativeSettings settings; solana=solanaSettings settings
  require (N.profile native==S.solanaProfile solana && S.mint solana==H.mint config
    && S.custodyOwner solana==H.custodyOwner config && S.custodyAta solana==H.custodyAta config) "payment_profile_mismatch"
  N.validateNativeSettings native
  S.validateSolanaSettings solana
  forM_ customerSettings $ \customer->do
    let public=publicConfiguration customer; store=customerPolicy customer
        policy=W.paymentPolicy(executionTerms store); costs=W.paymentLimits(executionTerms store)
        limits=admissionLimits store
    require (W.pubProfile public==N.profile native && W.pubMint public==H.mint config
      && W.pubCustodyOwner public==H.custodyOwner config && W.pubDeployment public==H.deploymentId config
      && W.pubDecimals public==8 && W.pubMinInput public==orderMinimum limits && W.pubMaxInput public==orderMaximum limits
      && W.pubFeesBps public==M.fromList [("NativeToWrapped",100),("WrappedToNative",100)]
      && W.pubSolanaCluster public==(if N.profile native==W.CanonicalBeta then "mainnet-beta" else "devnet")
      && W.deploymentFingerprint policy==H.fingerprint config && W.nativeDepth policy==defaultNativeDepth settings
      && W.savedSolanaFee costs==H.maxSolFee config && W.savedSolanaRent costs==H.maxSolAccountRent config) "customer_configuration_mismatch"
  gate<-newMVar ()
  let paying=maybe True (W.pubIntakeEnabled . publicConfiguration) customerSettings
      customer=maybe (reject "customer_configuration_unavailable") pure customerSettings
      interpret :: forall caller a. Request caller 'Critical a -> IO a
      interpret request=do
        let command=resolve request
        case command of
          OperatorDSL PauseService{}->pure ()
          SigningDSL _->reject "signer_operation_forbidden"
          WorkerDSL RecoverNativeSources->pure ()
          WorkerDSL RecoverNativeSettlements->pure ()
          WorkerDSL RecoverNativeLocks->pure ()
          WorkerDSL RunWorkerCycle->pure ()
          WorkerDSL ObserveChains->pure ()
          WorkerDSL ReconcileCustody->pure ()
          WorkerDSL ReconcilePayment{}->pure ()
          _->require paying "observation_only"
        withMVar gate $ \_ -> evalCritical command
      customerRequest :: forall caller a. Plan caller a -> IO a
      customerRequest (SafePlan request)=evalSafe reader (publicConfiguration <$> customerSettings) (resolve request)
      customerRequest (CriticalPlan request)=interpret request
      evalCritical :: forall caller a. DSL caller 'Critical a -> IO a
      evalCritical (SigningDSL _)=reject "signer_operation_forbidden"
      evalCritical (WriteCustomer (Bridge.Operation.Internal.CreateOrder header request))=do
        c<-customer
        createCustomerOrder rpc settings config (customerPolicy c) (unsignedSdk c) (coverBackup c) reader writer header request
      evalCritical (OperatorDSL (CoverLostSource receipt recovery capital earned reason))=guarded $ do
        require (recovery>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_loss_cover"
        state<-evalRead reader ReadState
        require (ledgerPaused state) "pause_before_operator_action"
        previous<-evalRead reader (ReadLossCover receipt recovery)
        case previous of
          Just old->require (old==(capital,earned,reason)) "source_loss_cover_conflict"
          Nothing->do
            source<-evalRead reader (ReadSource receipt)
            proof<-proveMissing source
            custody<-inspectLossCustody rpc settings config reader
            now<-floor <$> getPOSIXTime
            evalWrite writer (CoverSourceLoss source recovery now capital earned reason proof custody)
      evalCritical (OperatorDSL (ApproveCovered key recovery reason))=guarded $ do
        require (recovery>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
        state<-evalRead reader ReadState
        require (ledgerPaused state) "pause_before_operator_action"
        previous<-evalRead reader (ReadCoveredApproval key recovery)
        case previous of
          Just old->require (old==reason) "source_approval_conflict"
          Nothing->do
            evalRead reader (CheckCoveredSource key recovery)
            binding<-evalRead reader (ReadPaymentSource key) >>= maybe (reject "source_approval_not_expected") pure
            proof<-proveMissing (W.sourceDeposit binding)
            reconcilePending >>= mapM_ (either throwIO pure)
            evalWorker ReconcileCustody
            now<-floor <$> getPOSIXTime
            evalWrite writer (ApproveCoveredSource now key recovery reason proof)
      evalCritical (OperatorDSL (RestoreSource key restoration reason))=guarded $ do
        require (restoration>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
        state<-evalRead reader ReadState
        require (ledgerPaused state) "pause_before_operator_action"
        previous<-evalRead reader (ReadSourceApproval key restoration)
        case previous of
          Just old->require (old==reason) "source_approval_conflict"
          Nothing->do
            evalRead reader (CheckSourceRestoration key restoration)
            refreshSource key
            reconcilePending >>= mapM_ (either throwIO pure)
            evalWorker ReconcileCustody
            now<-floor <$> getPOSIXTime
            evalWrite writer (ApproveSourceRestoration now key restoration reason)
      evalCritical (OperatorDSL (ClassifySpend chain key reason))=evalWrite writer (ClassifyTreasurySpend chain key reason)
      evalCritical (OperatorDSL (AllocateReceipt receipt split reason))=do
        now<-floor <$> getPOSIXTime
        evalWrite writer (AllocateTreasury now receipt split reason)
      evalCritical (OperatorDSL (WithdrawFees key asset quantity recipient reason))=guarded $ do
        c<-customer
        require (T.length key==64 && T.all (`elem` ("0123456789abcdef"::String)) key
          && not(T.null $ T.strip reason) && T.length reason<=512
          && units quantity>0 && quantity<=orderMaximum(admissionLimits $ customerPolicy c)
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
            evalWorker ReconcileCustody
        now<-floor <$> getPOSIXTime
        paymentId . withdrawalPayment <$> evalWrite writer (ReserveFees now key asset quantity recipient reason)
      evalCritical (OperatorDSL (CancelFeeWithdrawal key reason))=do
        state<-evalRead reader ReadState
        require (ledgerPaused state) "pause_before_operator_action"
        paymentId . withdrawalPayment <$> evalWrite writer (CancelFees key reason)
      evalCritical (OperatorDSL (DraftNativeReplacement parent fee reason))=guarded $ do
        require (NP.transactionId parent && units fee>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_native_replacement_decision"
        state<-evalRead reader ReadState
        require (ledgerPaused state) "pause_before_operator_action"
        previous<-evalRead reader (ReadReplacementDecision parent fee reason)
        case previous of
          Just (decision,cancelled)->require (not cancelled) "native_replacement_cancelled" >> pure decision
          Nothing->do
            saved<-evalRead reader (ReadAttempt parent)
            require (recordedChain saved=="Native") "native_replacement_not_expected"
            refreshSource (recordedPayment saved)
            evalWorker ReconcileCustody
            now<-floor <$> getPOSIXTime
            family<-evalRead reader (ReadReplacementDraftContext now parent fee)
            draft<-callSigner (DraftReplacement (H.fingerprint config) parent fee)
            either reject pure (NP.validateNativeReplacementDraft (map snd family) fee draft)
            later<-floor <$> getPOSIXTime
            evalWrite writer (SaveReplacementDraft later saved draft reason)
      evalCritical (OperatorDSL (SignNativeReplacement decision))=guarded $ do
        require (decision>0) "invalid_native_replacement_decision"
        state<-evalRead reader ReadState
        require (ledgerPaused state) "pause_before_operator_action"
        previous<-evalRead reader (ReadReplacementMember decision)
        case previous of
          Just saved->pure (signedId $ recordedSigned saved)
          Nothing->do
            identifier<-evalRead reader (ReadReplacementPayment decision)
            refreshSource identifier
            backupDecisions
            evalWorker ReconcileCustody
            now<-floor <$> getPOSIXTime
            (family,draft)<-evalRead reader (ReadReplacementSigning now decision)
            wire<-callSigner (SignReplacement (H.fingerprint config) decision)
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
      evalCritical (OperatorDSL (CancelNativeReplacement decision reason))=
        evalWrite writer (CancelReplacementDraft decision reason)
      evalCritical (OperatorDSL (RetrySolanaPayment txid reason))=guarded $ do
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
            refreshSource (recordedPayment saved)
            proof<-expiry signed >>= maybe (reject "solana_expiry_not_proven") pure
            evalWorker ReconcileCustody
            now<-floor <$> getPOSIXTime
            evalWrite writer (ApproveSolanaRetry now saved reason proof)
      evalCritical (OperatorDSL (CancelPreparation identifier generation reason))=guarded $ do
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
            refreshSource identifier
            evalWorker ReconcileCustody
            prepared<-evalRead reader (ReadUnsignedPreparation identifier)
            require (preparedGeneration prepared==generation) "preparation_generation_changed"
            (points,cleanup)<-cancellationPlan (N.nativeCall rpc native) (N.profile native) config prepared
            forM_ previous $ \(_,plan,_)->require (plan==cleanup) "preparation_cancellation_conflict"
            now<-floor <$> getPOSIXTime
            evalWrite writer (BeginCancellation prepared now reason cleanup)
            when (paymentAsset(savedPayment $ preparedView prepared)==Native) $
              releaseNativeInputLocks (N.nativeCall rpc native) points
            evalWrite writer (FinishCancellation prepared reason cleanup)
      evalCritical (OperatorDSL (RefundDeposit receipt))=do
        now<-floor <$> getPOSIXTime
        evalWrite writer (AuthorizeRefund now receipt)
      evalCritical (OperatorDSL (PauseService reason))=evalWrite writer (Pause reason)
      evalCritical (OperatorDSL ResumeService)=guarded $ do
        state<-evalRead reader ReadState
        require (ledgerPaused state) "pause_before_operator_action"
        N.verifyNativeBoundaryWith (N.nativeCall rpc native)
        recoverPending
        ids<-evalRead reader PendingAttempts
        reviewed<-mapM (evalRead reader . ReadAttempt) ids
        forM_ reviewed (refreshSource . recordedPayment)
        evalWorker ReconcileCustody
        now<-floor <$> getPOSIXTime
        evalWrite writer (ResumeLedger now [("Native",N.nativeCheckpointHash native),("Solana",tokenOrigin settings),("SolanaOperating",operatingOrigin settings)] reviewed)
      evalCritical (WorkerDSL operation)=evalWorker operation
      evalWorker :: forall a. WorkerOperation a -> IO a
      evalWorker RecoverNativeSettlements = guarded $ do
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
      evalWorker RecoverNativeSources = do
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
      evalWorker RecoverNativeLocks = guarded $ do
        _<-N.nativeIdentity rpc native
        _<-N.nativeWalletInfoWith (N.nativeCall rpc native) native
        saved<-evalRead reader ReadNativeLockWork
        restored<-restoreNativeWork (N.nativeCall rpc native) native config saved
        when (restored>0) $ forM_ saved $ \work->evalWrite writer (RecordNativeLockRestore work restored)
      evalWorker ObserveChains = observeOnce rpc settings reader writer
      evalWorker (PrepareOutgoing identifier) = guarded $ do
        now<-floor <$> getPOSIXTime
        evalRead reader (CheckIntake now)
        _<-evalRead reader (ReadPayment identifier)
        _<-N.nativeIdentity rpc native
        _<-S.solanaIdentity rpc solana
        refreshSource identifier
        _<-prepareUnsigned (floor <$> getPOSIXTime) (N.nativeCall rpc native) (S.solanaCall rpc solana)
          (N.profile native) config reader writer identifier
        pure ()
      evalWorker ReconcileCustody = reconcileCustody rpc settings config reader writer
      evalWorker (QueuePayment txid) = guarded $ do
        (recorded,_)<-loadActive txid
        refreshSource (recordedPayment recorded)
        now<-floor <$> getPOSIXTime
        evalWrite writer (MarkBroadcast now txid)
      evalWorker (BroadcastPayment txid) = guarded $ do
        (recorded,reply)<-loadActive txid
        require (recordedState recorded=="broadcast_intent") "broadcast_intent_required"
        (observedAttempt,observed)<-observeAttempt recorded reply
        case observed of
          PaymentUnseen->do
            refreshSource (recordedPayment recorded)
            case reply of
              NativeReply signed->checkNativeAcceptance (N.nativeCall rpc native) signed
              SolanaReply signed->checkBlockhashWindow (S.solanaCall rpc solana) (solPlanRecent $ signedSolanaPlan signed)
            now<-floor <$> getPOSIXTime
            authorized<-evalWrite writer (AuthorizeSend now txid)
            require (authorized==recorded) "saved_payment_changed"
            actual<-case reply of
              NativeReply _->N.nativeCall rpc native True "sendrawtransaction" [toJSON $ signedBytes $ recordedSigned authorized] >>= parseValue parseJSON
              SolanaReply _->S.solanaCall rpc solana "sendTransaction" [toJSON $ signedBytes $ recordedSigned authorized,object
                ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("confirmed"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
            require (actual==txid) "broadcast_identifier_mismatch"
          _->recordOutcome observedAttempt observed
      evalWorker (ReconcilePayment txid) = guarded $ do
        recorded<-evalRead reader (ReadAttempt txid)
        retired<-evalRead reader (ReadSolanaExpiry txid)
        payment<-evalRead reader (ReadPayment $ recordedPayment recorded)
        if savedStatus payment==PaymentPaid || recordedState recorded `elem` ["settled","failed"] || retired/=Nothing then pure () else do
          (current,reply)<-loadActive txid
          (winner,outcome)<-observeAttempt current reply
          recordOutcome winner outcome
      evalWorker (SignPreparedPayment identifier) = signing `onException` evalWrite writer (Pause "signing_requires_review")
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
          refreshSource identifier
          now<-floor <$> getPOSIXTime
          decision<-evalRead reader (ReadSigningDecision now identifier $ preparedGeneration prepared)
          require (decision==prepared) "preparation_changed"
          signed<-callSigner (SignPrepared (H.fingerprint config) identifier $ preparedGeneration prepared)
          verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared signed
          recorded<-evalWrite writer (RecordAttempt prepared signed)
          pure (signedId $ recordedSigned recorded)
      evalWorker RunWorkerCycle = cycleWork `catch` (\(BridgeError code)->
        if code=="custody_not_reconciled" then pure () else evalWrite writer (Pause code) >> reject code)
       where
        cycleWork = do
          recoverPending
          state<-evalRead reader ReadState
          when (paying && not(ledgerPaused state)) $ do
            candidates<-evalRead reader PaymentCandidates
            forM_ candidates $ \identifier->do
              freshIntake
              (_,_,attempts)<-evalRead reader (ReadPaymentWork identifier)
              txid<-case attempts of
                []->do
                  evalWorker (PrepareOutgoing identifier)
                  freshIntake
                  backupDecisions
                  evalWorker (SignPreparedPayment identifier)
                [saved]->pure saved
                _->do
                  family<-evalRead reader (ReadNativeFamily identifier)
                  pure (signedId $ recordedSigned $ fst $ last family)
              freshIntake
              _<-evalWorker (QueuePayment txid)
              backupDecisions
              freshIntake
              evalWorker (BroadcastPayment txid)
        freshIntake=do
          now<-floor <$> getPOSIXTime
          result<-tryBridge (evalRead reader $ CheckIntake now)
          case result of
            Left (BridgeError "custody_not_reconciled")->do
              evalWorker ReconcileCustody
              later<-floor <$> getPOSIXTime
              evalRead reader (CheckIntake later)
            _->either throwIO pure result
      backupDecisions=do
        c<-customer
        when (requireBackup $ customerPolicy c) $ do
          before<-evalRead reader ReadState
          when (ledgerBackup before<ledgerSequence before) $ do
            coverBackup c (ledgerSequence before)
            after<-evalRead reader ReadState
            require (ledgerBackup after>=ledgerSequence before) "backup_pending"
      callSigner :: SigningOperation a -> IO a
      callSigner operation=do
        credentials<-signerCredentials endpoint
        certificate<-signerCertificate endpoint
        let base=TLS.defaultParamsClient "127.0.0.1" BS.empty
            tls=base {TLS.clientShared=(TLS.clientShared base) {TLS.sharedCAStore=makeCertificateStore [certificate]}
              ,TLS.clientSupported=(TLS.clientSupported base) {TLS.supportedCiphers=ciphersuite_default}}
            settings=managerSetProxy noProxy (mkManagerSettings (NC.TLSSettings tls) Nothing)
              {managerRetryableException=const False,managerIdleConnectionCount=0
              ,managerResponseTimeout=responseTimeoutMicro 60000000
              ,managerModifyRequest= \request->pure request {redirectCount=0}
              ,managerModifyResponse= \response->do
                bytes<-boundedBody 524288 (responseBody response)
                body<-newIORef bytes
                pure response {responseBody=atomicModifyIORef' body $ \chunk->(BS.empty,chunk)}}
        bracket (newManager settings) closeManager $ \local->do
          let prepared :<|> replacement :<|> draft=SC.client signingAPI credentials
              environment=SC.mkClientEnv local (SC.BaseUrl SC.Https "127.0.0.1" (signerPort endpoint) "")
              call=case operation of
                SignPrepared identity identifier generation->prepared (identity,identifier,generation)
                SignReplacement identity decision->replacement (identity,decision)
                DraftReplacement identity parent fee->draft (identity,parent,fee)
          result<-SC.runClientM call environment
          -- Even an HTTP failure may follow signing. Retain the preparation;
          -- never automatically retry or pretend the outcome is known.
          either (const $ reject "signer_outcome_unknown") pure result
      -- Explicit resume must retain every recovery error; the scheduler alone
      -- may defer a custody check while waiting for the next observation cycle.
      recoverPending :: IO ()
      recoverPending=do
        locks<-tryBridge (evalWorker RecoverNativeLocks)
        scanned<-tryBridge (evalWorker ObserveChains)
        sources<-tryBridge (evalWorker RecoverNativeSources)
        now<-floor <$> getPOSIXTime
        evalWrite writer (ExpireQuotes now)
        outcomes<-reconcilePending
        settled<-tryBridge (evalWorker RecoverNativeSettlements)
        evalWorker ReconcileCustody
        mapM_ (either throwIO pure) (locks:scanned:sources:settled:outcomes)
      -- Inspect each economic payment once, including all replacement members.
      -- A policy error on one family must not hide another finalized effect.
      reconcilePending=do
        pending<-evalRead reader PendingAttempts >>= mapM (evalRead reader . ReadAttempt)
        let families=M.elems $ M.fromList [(recordedPayment saved,saved)|saved<-pending]
        mapM (tryBridge . evalWorker . ReconcilePayment . signedId . recordedSigned) families
      tryBridge :: IO a -> IO (Either BridgeError a)
      tryBridge work=try (work `catch` (\(_::IOException)->reject "worker_io_unavailable"))
      guarded :: IO a -> IO a
      guarded operation=operation `onException` evalWrite writer (Pause "payment_requires_reconciliation")
      decode :: FromJSON a => Text -> IO a
      decode proof=either (const $ reject "invalid_saved_payment") pure (eitherDecodeStrict' $ TE.encodeUtf8 proof)
      loadActive txid = do
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
      observeAttempt recorded reply=case reply of
        NativeReply signed->do
          family<-evalRead reader (ReadNativeFamily $ recordedPayment recorded)
          if length family==1 then do
            _<-N.nativeIdentity rpc native
            result<-observeNativePayment (N.nativeCall rpc native) signed
            pure (recorded,result)
          else do
            (members,view)<-readSavedNativeFamily (N.nativeCall rpc native) native config reader (recordedPayment recorded)
            require (recorded `elem` map fst members) "native_replacement_family_changed"
            active<-activeNativeMember members view
            case active of
              Just (winner,payment,depth,value)->do
                if depth>0 || winner==recorded then do
                  result<-nativeConfirmation (N.nativeCall rpc native) payment depth value
                  pure (winner,result)
                else pure (recorded,if recorded==fst(last members) then PaymentUnseen else PaymentWaiting)
              Nothing->pure (recorded,if recorded==fst(last members) then PaymentUnseen else PaymentWaiting)
        SolanaReply signed->do
          _<-S.solanaIdentity rpc solana
          result<-observeSolanaPayment (S.solanaCall rpc solana) config signed
          pure (recorded,result)
      recordOutcome recorded observed=case observed of
        PaymentUnseen->when (recordedChain recorded=="Solana") $ do
          signed<-decode (signedPolicy $ recordedSigned recorded)
          proof<-expiry signed
          forM_ proof (evalWrite writer . RecordSolanaExpiry recorded)
        PaymentWaiting->require (recordedState recorded=="broadcast_intent") "unrecorded_broadcast_observed"
        PaymentConfirmed costs proof->evalWrite writer (SettlePayment recorded costs proof)
        PaymentFailed fee proof->evalWrite writer (FailSolana recorded fee proof)
      expiry signed=do
        let origins=(tokenOrigin settings,operatingOrigin settings)
        evalRead reader (CheckExpiryOrigins origins)
        solanaExpiryEvidence (S.solanaCall rpc solana)
          (fmap (\url->RPC.rpc rpc url Nothing) $ S.solanaVerifierRpc solana) (N.profile native) config origins signed
      proveMissing source = do
        _<-N.nativeIdentity rpc native
        (binding,evidence)<-evalRead reader (ReadNativeSourceInspection $ W.depositId source)
        result<-inspectNativeSource (N.nativeCall rpc native) native (defaultNativeDepth settings) (H.fingerprint config) source binding evidence
        case result of W.SourceMissing proof->pure proof; _->reject "source_loss_not_proven"
      refreshSource identifier = do
        source<-evalRead reader (ReadPaymentSource identifier)
        forM_ source $ \binding->do
          let saved=W.sourceDeposit binding
          if W.depositAsset saved==Native && not(W.depositEligible saved) then do
            evalRead reader (CheckPaymentSource identifier)
            proof<-proveMissing saved
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
  action interpret customerRequest customerRequest

-- The caller owns this lifetime (run it alongside HTTP with structured concurrency).
-- Async cancellation and database failures escape; they are never retried as work.
runWorkerLoop :: (forall a. Request 'Worker 'Critical a -> IO a) -> IO ()
runWorkerLoop evaluate=forever $ do
  evaluate (Request RunWorkerCycle) `catch` (\(BridgeError code)->hPutStrLn stderr ("worker: "<>T.unpack code))
  threadDelay 15000000
