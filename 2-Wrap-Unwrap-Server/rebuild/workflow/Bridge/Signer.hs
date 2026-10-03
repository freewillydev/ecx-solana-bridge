{-# LANGUAGE DataKinds, GADTs, RankNTypes, TypeOperators #-}
-- Dedicated signing evaluator: read-only ledger, private signing credentials,
-- no writer or broadcast operation. TLS/auth transport is installed by runtime.
module Bridge.Signer
  ( SigningAPI, signingAPI, signingServer, SignerSettings(..), withSigner, verifySigningKey, protectedSignerFile ) where
import Bridge.Operation.Internal
import Bridge.Wire (Profile(..),SignedAttempt(..),NativeDraft)
import Bridge.Domain (Amount)
import Bridge.Identity (publicKey)
import Bridge.Error
import Bridge.Store (Reader,StoreRead(ReadSigningDecision,ReadReplacementSigning,ReadReplacementDraftContext),RecordedAttempt(..),evalRead)
import Bridge.Payment
import qualified Bridge.Native as N
import Bridge.NativePayment (draftNativeReplacement,signNativeDraft,signNativeReplacement,NativeSigned(..),NativeTx(..))
import qualified Bridge.Solana as S
import qualified Bridge.SolanaHelper as H
import Bridge.SolanaPayment
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.Aeson (eitherDecodeStrict',encode)
import Data.Int (Int64)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.Bits ((.&.))
import Data.Word (Word8)
import System.FilePath (isAbsolute,takeDirectory)
import System.IO (withBinaryFile,IOMode(ReadMode))
import System.Posix.Files
import System.Posix.User (getEffectiveUserID)
import Control.Concurrent.MVar (newMVar,withMVar)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)
import Servant

-- Keep the shared API pure; only the critical runtime will generate ClientM.
type SigningAPI = BasicAuth "signer" () :>
  (("sign-preparation" :> ReqBody '[JSON] (Text,Text,Int) :> Post '[JSON] SignedAttempt)
  :<|> ("sign-replacement" :> ReqBody '[JSON] (Text,Int64) :> Post '[JSON] SignedAttempt)
  :<|> ("draft-replacement" :> ReqBody '[JSON] (Text,Text,Amount) :> Post '[JSON] NativeDraft))
signingAPI :: Proxy SigningAPI
signingAPI=Proxy
signingServer :: ServerT SigningAPI (Request 'Signer 'Critical)
signingServer () = (\(identity,identifier,generation)->Request $ SignPrepared identity identifier generation)
  :<|> (\(identity,decision)->Request $ SignReplacement identity decision)
  :<|> (\(identity,parent,fee)->Request $ DraftReplacement identity parent fee)

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
  verifySigningKey (S.custodyOwner solana) (signingKey settings)
  gate<-newMVar ()
  let interpret :: forall a. Request 'Signer 'Critical a -> IO a
      interpret request=withMVar gate $ \_ -> case resolve request of
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

-- Secret files permit group read only for the shared auth token. Certificates
-- may be public, but neither they nor their parent may be replaced by that group.
protectedSignerFile :: FilePath -> Bool -> Bool -> IO ()
protectedSignerFile path secret shared = do
  require (isAbsolute path) "absolute_credential_path_required"
  uid<-getEffectiveUserID
  file<-getSymbolicLinkStatus path
  parent<-getFileStatus (takeDirectory path)
  let mode=fileMode file .&. 0o777
  require (isRegularFile file && fileOwner file `elem` [0,uid]
    && fileOwner parent `elem` [0,uid] && fileMode parent .&. 0o022==0
    && if secret then mode==0o600 || shared && mode==0o640 else mode .&. 0o022==0) "unsafe_signer_file_permissions"

-- Standard Solana CLI keypair: seed plus derived public key, never printed.
-- Validate before accepting requests; the SDK checks again when it signs.
verifySigningKey :: Text -> FilePath -> IO ()
verifySigningKey owner filename = do
  protectedSignerFile filename True False
  bytes<-withBinaryFile filename ReadMode (`BS.hGet` 4097)
  require (BS.length bytes<=4096) "signer_file_too_large"
  values<-either (const $ reject "invalid_signer_json") pure
    (eitherDecodeStrict' bytes :: Either String [Word8])
  require (length values==64) "invalid_signer_length"
  expected<-either reject pure (publicKey owner)
  let key=BS.pack values
  case Ed.secretKey (BS.take 32 key) of
    CryptoPassed secret->do
      let actual=BA.convert(Ed.toPublic secret) :: BS.ByteString
      require (actual==BS.drop 32 key && actual==expected) "signer_mismatch"
    CryptoFailed _->reject "invalid_signer"
