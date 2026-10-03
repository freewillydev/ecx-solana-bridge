{-# LANGUAGE DataKinds, GADTs, RankNTypes, TypeOperators #-}
-- Dedicated signing evaluator: read-only ledger, private signing credentials,
-- no writer or broadcast operation. TLS/auth transport is installed by runtime.
module Bridge.Signer
  ( SigningAPI, signingAPI, signingServer, SignerSettings(..), withSigner ) where
import Bridge.Operation.Internal
import Bridge.Wire (Profile(..),SignedAttempt)
import Bridge.Error
import Bridge.Store (Reader,StoreRead(ReadSigningDecision),evalRead)
import Bridge.Payment
import qualified Bridge.Native as N
import Bridge.NativePayment (signNativeDraft)
import qualified Bridge.Solana as S
import qualified Bridge.SolanaHelper as H
import Bridge.SolanaPayment
import Control.Concurrent.MVar (newMVar,withMVar)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)
import Servant

-- Keep the shared API pure; only the critical runtime will generate ClientM.
type SigningAPI = BasicAuth "signer" () :> "sign-preparation"
  :> ReqBody '[JSON] (Text,Text,Int) :> Post '[JSON] SignedAttempt
signingAPI :: Proxy SigningAPI
signingAPI=Proxy
signingServer :: ServerT SigningAPI (Request 'Signer 'Critical)
signingServer () (identity,identifier,generation)=Request (SignPrepared identity identifier generation)

data SignerSettings = SignerSettings
  { signingNative :: N.NativeSettings, signingSolana :: S.SolanaSettings
  , signingPolicy :: H.SolanaPolicy, signingLibrary :: FilePath, signingKey :: FilePath }

-- The gate serializes complete decisions, including RPC/FFI and the second read.
-- Database read transactions finish before any external work starts.
withSigner :: Manager -> Reader -> SignerSettings
  -> ((forall a. Request 'Signer 'Critical a -> IO a) -> IO b) -> IO b
withSigner manager reader settings action = do
  let native=signingNative settings; solana=signingSolana settings; config=signingPolicy settings
  require (N.profile native `elem` [L2LSignetDevnet,ECXBetanetDevnet]
    && S.solanaProfile solana==N.profile native
    && S.mint solana==H.mint config && S.custodyOwner solana==H.custodyOwner config
    && S.custodyAta solana==H.custodyAta config) "signer_profile_mismatch"
  N.validateNativeSettings native
  S.validateSolanaSettings solana
  gate<-newMVar ()
  let interpret :: forall a. Request 'Signer 'Critical a -> IO a
      interpret request=withMVar gate $ \_ -> case resolve request of
        SigningDSL (SignPrepared identity identifier generation)->do
          require (identity==H.fingerprint config) "signer_profile_mismatch"
          let readDecision=do
                now<-floor <$> getPOSIXTime
                evalRead reader (ReadSigningDecision now identifier generation)
          before<-readDecision
          plan<-resolveSigningPlan (N.profile native) config before
          reply<-case plan of
            NativeAuthorization saved draft->do
              _<-N.nativeIdentity manager native
              now<-floor <$> getPOSIXTime
              N.nativeWalletReadyWith (N.nativeCall manager native) native now
              NativeReply <$> signNativeDraft (N.nativeCall manager native) saved draft
            SolanaAuthorization saved expected->do
              _<-S.solanaIdentity manager solana
              let limits=config {H.maxSolFee=solPlanFeeLimit saved,H.maxSolAccountRent=solPlanRentLimit saved}
                  sign actual=do
                    require (actual==expected) "saved_solana_request_mismatch"
                    H.signSolanaSdk (signingLibrary settings) limits (signingKey settings) actual
              SolanaReply <$> prepareSolanaSigned (S.solanaCall manager solana) sign limits saved
          verified<-verifySigningReply (N.nativeCall manager native) (N.profile native) config before reply
          after<-readDecision
          require (before==after) "signing_decision_changed"
          pure verified
  action interpret
