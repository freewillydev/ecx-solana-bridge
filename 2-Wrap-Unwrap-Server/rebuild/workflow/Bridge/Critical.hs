{-# LANGUAGE DataKinds, GADTs, RankNTypes #-}
-- The signer ClientM is constructed only inside this critical evaluator.
module Bridge.Critical (withPaymentWorker) where
import Bridge.Operation.Internal
import Bridge.Domain (Asset(..))
import Bridge.Error
import Bridge.Payment
import Bridge.Observer (ObserverSettings(..))
import Bridge.Reconciliation (reconcileCustody)
import Bridge.PaymentSource (verifyPaymentSource)
import qualified Bridge.Wire as W
import Control.Monad (forM_)
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
import Control.Concurrent.MVar (newMVar,withMVar)
import Control.Exception (bracket,onException)
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

-- Preparation and backup have already committed. No transaction spans signing.
-- Full runtime will share this gate with other critical worker operations.
withPaymentWorker :: Manager -> ObserverSettings -> H.SolanaPolicy -> SigningEndpoint -> Reader -> Writer
  -> ((forall a. Request 'Worker 'Critical a -> IO a) -> IO b) -> IO b
withPaymentWorker rpc settings config endpoint reader writer action = do
  let native=nativeSettings settings; solana=solanaSettings settings
  require (N.profile native==S.solanaProfile solana && S.mint solana==H.mint config
    && S.custodyOwner solana==H.custodyOwner config && S.custodyAta solana==H.custodyAta config) "payment_profile_mismatch"
  N.validateNativeSettings native
  S.validateSolanaSettings solana
  gate<-newMVar ()
  let interpret :: forall a. Request 'Worker 'Critical a -> IO a
      interpret request=withMVar gate $ \_ -> evalCritical (resolve request)
      evalCritical :: forall a. DSL 'Worker 'Critical a -> IO a
      evalCritical (WorkerDSL ReconcileCustody) = reconcileCustody rpc settings config reader writer
      evalCritical (WorkerDSL (QueuePayment txid)) = guarded $ do
        (recorded,_)<-loadActive txid
        refreshSource (recordedPayment recorded)
        now<-floor <$> getPOSIXTime
        evalWrite writer (MarkBroadcast now txid)
      evalCritical (WorkerDSL (BroadcastPayment txid)) = guarded $ do
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
      evalCritical (WorkerDSL (ReconcilePayment txid)) = guarded $ do
        recorded<-evalRead reader (ReadAttempt txid)
        if recordedState recorded `elem` ["settled","failed"] then pure () else do
          (current,reply)<-loadActive txid
          observe reply >>= recordOutcome current
      evalCritical (WorkerDSL (SignPreparedPayment identifier)) = signing `onException` evalWrite writer (Pause "signing_requires_review")
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
  action interpret
