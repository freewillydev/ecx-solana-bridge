{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables #-}
-- The signer ClientM is constructed only inside this critical evaluator.
module Bridge.Critical (CustomerSettings(..),withRuntime,runWorkerLoop) where
import Bridge.Operation.Internal
import Bridge.Domain (Asset(..),gross)
import Bridge.Identity (payURIFor)
import Bridge.Order (createCustomerOrder)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Bridge.Error
import Bridge.Payment
import Bridge.Observer (ObserverSettings(..),observeOnce)
import Bridge.Reconciliation (reconcileCustody)
import Bridge.PaymentSource (verifyPaymentSource)
import qualified Bridge.Wire as W
import Control.Monad (forM_,when,forever)
import Bridge.NativePayment (NativeSigned,checkNativeAcceptance)
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
import qualified Servant.Client as SC

-- The safe evaluator receives only read credentials and public configuration.
-- It cannot access the writer, signer transport, backup callback or RPC manager.
evalSafe :: Reader -> Maybe W.PublicConfiguration -> DSL 'Customer 'Safe a -> IO a
evalSafe reader public operation = case operation of
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
  -> ((forall a. Request 'Worker 'Critical a -> IO a) -> (forall a. Plan 'Customer a -> IO a) -> IO b) -> IO b
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
          SigningDSL _->reject "signer_operation_forbidden"
          WorkerDSL RecoverNativeLocks->pure ()
          WorkerDSL RunWorkerCycle->pure ()
          WorkerDSL ObserveChains->pure ()
          WorkerDSL ReconcileCustody->pure ()
          WorkerDSL ReconcilePayment{}->pure ()
          _->require paying "observation_only"
        withMVar gate $ \_ -> evalCritical command
      customerRequest :: forall a. Plan 'Customer a -> IO a
      customerRequest (SafePlan request)=evalSafe reader (publicConfiguration <$> customerSettings) (resolve request)
      customerRequest (CriticalPlan request)=interpret request
      evalCritical :: forall caller a. DSL caller 'Critical a -> IO a
      evalCritical (SigningDSL _)=reject "signer_operation_forbidden"
      evalCritical (WriteCustomer (Bridge.Operation.Internal.CreateOrder header request))=do
        c<-customer
        createCustomerOrder rpc settings config (customerPolicy c) (unsignedSdk c) (coverBackup c) reader writer header request
      evalCritical (WorkerDSL operation)=evalWorker operation
      evalWorker :: forall a. WorkerOperation a -> IO a
      evalWorker RecoverNativeLocks = guarded $ do
        _<-N.nativeIdentity rpc native
        _<-N.nativeWalletInfoWith (N.nativeCall rpc native) native
        saved<-evalRead reader ReadNativeLockWork
        restored<-restoreNativeWork (N.nativeCall rpc native) (N.profile native) config saved
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
        observed<-observe reply
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
          _->recordOutcome recorded observed
      evalWorker (ReconcilePayment txid) = guarded $ do
        recorded<-evalRead reader (ReadAttempt txid)
        if recordedState recorded `elem` ["settled","failed"] then pure () else do
          (current,reply)<-loadActive txid
          observe reply >>= recordOutcome current
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
          signed<-bracket (newManager settings) closeManager $ \local->do
            let call=SC.client signingAPI credentials
                environment=SC.mkClientEnv local (SC.BaseUrl SC.Https "127.0.0.1" (signerPort endpoint) "")
            result<-SC.runClientM (call (H.fingerprint config,identifier,preparedGeneration prepared)) environment
            -- Even an HTTP failure may follow signing. Retain the preparation;
            -- never automatically retry or pretend the outcome is known.
            either (const $ reject "signer_outcome_unknown") pure result
          verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared signed
          recorded<-evalWrite writer (RecordAttempt prepared signed)
          pure (signedId $ recordedSigned recorded)
      evalWorker RunWorkerCycle = cycleWork `catch` (\(BridgeError code)->
        if code=="custody_not_reconciled" then pure () else evalWrite writer (Pause code) >> reject code)
       where
        cycleWork = do
          locks<-tryBridge (evalWorker RecoverNativeLocks)
          scanned<-tryBridge (evalWorker ObserveChains)
          now<-floor <$> getPOSIXTime
          evalWrite writer (ExpireQuotes now)
          pending<-evalRead reader PendingAttempts
          -- A policy error on one attempt must not hide another finalized effect.
          outcomes<-mapM (tryBridge . evalWorker . ReconcilePayment) pending
          evalWorker ReconcileCustody
          mapM_ (either throwIO pure) (locks:scanned:outcomes)
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
                _->reject "payment_requires_recovery"
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
        verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared saved
        reply<-case recordedChain recorded of
          "Native"->NativeReply <$> (decode (signedPolicy saved) :: IO NativeSigned)
          "Solana"->SolanaReply <$> (decode (signedPolicy saved) :: IO SolanaSigned)
          _->reject "invalid_payout_asset"
        pure (recorded,reply)
      observe reply=case reply of
        NativeReply signed->N.nativeIdentity rpc native >> observeNativePayment (N.nativeCall rpc native) signed
        SolanaReply signed->S.solanaIdentity rpc solana >> observeSolanaPayment (S.solanaCall rpc solana) config signed
      recordOutcome recorded observed=case observed of
        PaymentUnseen->pure ()
        PaymentWaiting->require (recordedState recorded=="broadcast_intent") "unrecorded_broadcast_observed"
        PaymentConfirmed costs proof->evalWrite writer (SettlePayment recorded costs proof)
        PaymentFailed fee proof->evalWrite writer (FailSolana recorded fee proof)
      refreshSource identifier = do
        source<-evalRead reader (ReadPaymentSource identifier)
        forM_ source $ \binding->do
          case W.depositAsset (W.sourceDeposit binding) of
            Native->N.nativeIdentity rpc native >> pure ()
            Wrapped->S.solanaIdentity rpc solana >> pure ()
            Sol->reject "unsupported_source_asset"
          observed<-verifyPaymentSource (N.nativeCall rpc native) (S.solanaCall rpc solana)
            (fmap (\url->RPC.rpc rpc url Nothing) $ S.solanaVerifierRpc solana) (N.profile native) config binding
          evalWrite writer (RefreshPaymentSource (W.sourceDeposit binding) observed)
          require (W.depositEligible observed) "source_not_eligible"
  action interpret customerRequest

-- The caller owns this lifetime (run it alongside HTTP with structured concurrency).
-- Async cancellation and database failures escape; they are never retried as work.
runWorkerLoop :: (forall a. Request 'Worker 'Critical a -> IO a) -> IO ()
runWorkerLoop evaluate=forever $ do
  evaluate (Request RunWorkerCycle) `catch` (\(BridgeError code)->hPutStrLn stderr ("worker: "<>T.unpack code))
  threadDelay 15000000
