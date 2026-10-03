{-# LANGUAGE DataKinds, GADTs, RankNTypes #-}
-- The signer ClientM is constructed only inside this critical evaluator.
module Bridge.Critical (withPaymentWorker) where
import Bridge.Operation.Internal
import Bridge.Error
import Bridge.Payment
import Bridge.PaymentObservation
import qualified Bridge.Solana as S
import Data.Aeson (eitherDecodeStrict')
import qualified Data.Text.Encoding as TE
import Bridge.Signer (signingAPI)
import Bridge.SigningTransport
import Bridge.Store
import qualified Bridge.Native as N
import qualified Bridge.SolanaHelper as H
import Bridge.RPC (boundedBody)
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
withPaymentWorker :: Manager -> N.NativeSettings -> S.SolanaSettings -> H.SolanaPolicy -> SigningEndpoint -> Reader -> Writer
  -> ((forall a. Request 'Worker 'Critical a -> IO a) -> IO b) -> IO b
withPaymentWorker rpc native solana config endpoint reader writer action = do
  require (N.profile native==S.solanaProfile solana && S.mint solana==H.mint config
    && S.custodyOwner solana==H.custodyOwner config && S.custodyAta solana==H.custodyAta config) "payment_profile_mismatch"
  N.validateNativeSettings native
  S.validateSolanaSettings solana
  gate<-newMVar ()
  let interpret :: forall a. Request 'Worker 'Critical a -> IO a
      interpret request=withMVar gate $ \_ -> evalCritical (resolve request)
      evalCritical :: forall a. DSL 'Worker 'Critical a -> IO a
      evalCritical (WorkerDSL (ReconcilePayment txid)) = reconcile `onException` evalWrite writer (Pause "payment_observation_requires_review")
       where
        reconcile = do
          recorded<-evalRead reader (ReadAttempt txid)
          case recordedState recorded of
            "settled"->pure ()
            "failed"->pure ()
            _->do
              require (recordedState recorded `elem` ["signed","broadcast_intent"]) "payment_requires_recovery"
              prepared<-evalRead reader (ReadPreparation $ recordedPayment recorded)
              require (preparedGeneration prepared==recordedGeneration recorded) "payment_requires_recovery"
              let saved=recordedSigned recorded
                  decode proof=either (const $ reject "invalid_saved_payment") pure (eitherDecodeStrict' $ TE.encodeUtf8 proof)
              verifySignedAttempt (N.nativeCall rpc native) (N.profile native) config prepared saved
              observed<-case recordedChain recorded of
                "Native"->do
                  _<-N.nativeIdentity rpc native
                  decode (signedPolicy saved) >>= observeNativePayment (N.nativeCall rpc native)
                "Solana"->do
                  _<-S.solanaIdentity rpc solana
                  decode (signedPolicy saved) >>= observeSolanaPayment (S.solanaCall rpc solana) config
                _->reject "invalid_payout_asset"
              case observed of
                PaymentUnseen->pure ()
                PaymentWaiting->pure ()
                PaymentConfirmed costs proof->evalWrite writer (SettlePayment recorded costs proof)
                PaymentFailed fee proof->evalWrite writer (FailSolana recorded fee proof)
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
  action interpret
