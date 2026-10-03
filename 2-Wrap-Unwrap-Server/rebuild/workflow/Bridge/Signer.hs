{-# LANGUAGE DataKinds, GADTs, RankNTypes, TypeOperators #-}
-- Dedicated signing evaluator: read-only ledger, private signing credentials,
-- no writer or broadcast operation. TLS/auth transport is installed by runtime.
module Bridge.Signer
  ( SigningAPI, signingAPI, signingServer, SignerSettings(..), withSigner, verifySigningKey, protectedSignerFile ) where
import Bridge.Operation.Internal
import Bridge.Credentials
import qualified Bridge.Config as C
import Bridge.Recovery
import Control.Exception (bracket)
import System.Directory (removeDirectoryRecursive)
import System.FilePath (takeDirectory)
import System.Timeout (timeout)
import Data.Aeson (encode)
import Bridge.Wire (Profile(..),SignedAttempt(..),NativeDraft,BackupReceipt(..))
import Bridge.Domain (Amount)
import Bridge.Error
import Bridge.Store (Reader,StoreRead(ReadState,ReadSigningDecision,ReadReplacementSigning,ReadReplacementDraftContext),LedgerState(..),RecordedAttempt(..),evalRead)
import Bridge.Payment
import qualified Bridge.Native as N
import Bridge.NativePayment (draftNativeReplacement,signNativeDraft,signNativeReplacement,NativeSigned(..),NativeTx(..))
import qualified Bridge.Solana as S
import qualified Bridge.SolanaHelper as H
import Bridge.SolanaPayment
import Data.Int (Int64)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Control.Concurrent.MVar (newMVar,withMVar)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)
import Servant

-- Keep the shared API pure; only the critical runtime will generate ClientM.
type SigningAPI = BasicAuth "signer" () :>
  (("sign-preparation" :> ReqBody '[JSON] (Text,Text,Int) :> Post '[JSON] SignedAttempt)
  :<|> ("sign-replacement" :> ReqBody '[JSON] (Text,Int64) :> Post '[JSON] SignedAttempt)
  :<|> ("draft-replacement" :> ReqBody '[JSON] (Text,Text,Amount) :> Post '[JSON] NativeDraft)
  :<|> ("checkpoint-custody" :> ReqBody '[JSON] (Text,Int64) :> Post '[JSON] BackupReceipt))
signingAPI :: Proxy SigningAPI
signingAPI=Proxy
signingServer :: ServerT SigningAPI (Request 'Signer 'Critical)
signingServer () = (\(identity,identifier,generation)->Request $ SignPrepared identity identifier generation)
  :<|> (\(identity,decision)->Request $ SignReplacement identity decision)
  :<|> (\(identity,parent,fee)->Request $ DraftReplacement identity parent fee)
  :<|> (\(identity,minimumSequence)->Request $ CheckpointCustody identity minimumSequence)

data SignerSettings = SignerSettings
  { signingNative :: N.NativeSettings, signingSolana :: S.SolanaSettings
  , signingPolicy :: H.SolanaPolicy, signingLibrary :: FilePath, signingKey :: FilePath
  , signingBackup :: Maybe (C.Config,FilePath,FilePath) }

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
  verifySigningKey (S.custodyOwner solana) (signingKey settings)
  gate<-newMVar ()
  let interpret :: forall a. Request 'Signer 'Critical a -> IO a
      interpret request=withMVar gate $ \_ -> case resolve request of
        SigningDSL (CheckpointCustody identity minimumSequence)->do
          require (identity==H.fingerprint config && minimumSequence>=0) "invalid_custody_checkpoint"
          (deployment,backup,parent)<-maybe (reject "custody_checkpoint_not_configured") pure (signingBackup settings)
          require (C.fingerprint deployment==identity && C.nativeSettings deployment==native
            && C.solanaSettings deployment==solana) "signer_profile_mismatch"
          result<-timeout 300000000 $ bracket
            (evalCustodyRecovery manager deployment $ ExportCheckpoint reader (signingKey settings) parent minimumSequence)
            (removeDirectoryRecursive . takeDirectory . fst) $ \(manifest,sequenceNo)->do
              receipt<-evalCustodyRecovery manager deployment (UploadCustody backup manifest sequenceNo)
              after<-evalRead reader ReadState
              require (ledgerSequence after==sequenceNo) "custody_backup_changed"
              pure receipt
          maybe (reject "custody_checkpoint_timeout") pure result
        SigningDSL (DraftReplacement identity parent fee)->do
          require (identity==H.fingerprint config) "signer_profile_mismatch"
          let readDecision=do
                now<-floor <$> getPOSIXTime
                evalRead reader (ReadReplacementDraftContext now parent fee)
          before<-readDecision
          draft<-draftNativeReplacement (N.nativeCall manager native) native (map snd before) fee
          after<-readDecision
          require (before==after) "signing_decision_changed"
          pure draft
        SigningDSL (SignReplacement identity decision)->do
          require (identity==H.fingerprint config) "signer_profile_mismatch"
          let readDecision=do
                now<-floor <$> getPOSIXTime
                evalRead reader (ReadReplacementSigning now decision)
          before@(family,draft)<-readDecision
          now<-floor <$> getPOSIXTime
          N.nativeWalletReadyWith (N.nativeCall manager native) native now
          signed<-signNativeReplacement (N.nativeCall manager native) native (map snd family) draft
          after<-readDecision
          require (before==after) "signing_decision_changed"
          parent<-case reverse family of (saved,_):_->pure saved; _->reject "native_replacement_family_bounds"
          pure $ SignedAttempt (nativeTxid $ signedNativeTransaction signed) (signedNativeBytes signed)
            (TE.decodeUtf8 $ BL.toStrict $ encode signed) (commonInput $ recordedSigned parent)
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
