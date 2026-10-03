{-# LANGUAGE DataKinds, GADTs, RankNTypes, TypeOperators #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Dedicated signing evaluator: read-only ledger, private signing credentials,
-- no writer or broadcast operation. The real evaluator never escapes its API.
module Bridge.Signer
  ( SigningAPI, signingAPI, signingServer, SignerSettings(..), signerApplication, runSigner, verifySigningKey, protectedSignerFile
  , SigningEndpoint(..), signerCredentials, signerCertificate, signingApplication, runSigningServer ) where
import Bridge.Operation.Internal
import Bridge.Credentials
import qualified Bridge.Config as C
import Bridge.Recovery
import Control.Exception (bracket,catch)
import Control.Monad (forM_)
import System.Directory (removeDirectoryRecursive)
import System.FilePath (takeDirectory)
import System.Timeout (timeout)
import Data.Aeson (encode,object,(.=))
import Bridge.Wire (Profile(..),SignedAttempt(..))
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
import Servant hiding (respond)
import Bridge.Web (boundedApplication)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.PEM (pemParseBS,pemContent)
import Data.X509 (SignedCertificate,decodeSignedCertificate)
import Network.Wai hiding (Request)
import Network.Wai.Handler.Warp (setHost,setPort,setTimeout,defaultSettings)
import Network.Wai.Handler.WarpTLS (runTLS,tlsSettings)
import System.IO (withBinaryFile,IOMode(ReadMode))

-- Keep the shared API pure; only the critical runtime will generate ClientM.
type SigningAPI = BasicAuth "signer" () :>
  (("sign-preparation" :> ReqBody '[JSON] (Text,Text,Int) :> Post '[JSON] PreparedResult)
  :<|> ("sign-replacement" :> ReqBody '[JSON] (Text,Int64) :> Post '[JSON] ReplacementResult)
  :<|> ("draft-replacement" :> ReqBody '[JSON] (Text,Text,Amount) :> Post '[JSON] DraftResult)
  :<|> ("checkpoint-custody" :> ReqBody '[JSON] (Text,Int64) :> Post '[JSON] CheckpointResult))
signingAPI :: Proxy SigningAPI
signingAPI=Proxy
signingServer :: ServerT SigningAPI (Request 'Signer 'Critical)
signingServer () = (\(identity,identifier,generation)->Request $ SignerAction $ PreparedSigning $ SignPrepared identity identifier generation)
  :<|> (\(identity,decision)->Request $ SignerAction $ ReplacementSigning $ SignReplacement identity decision)
  :<|> (\(identity,parent,fee)->Request $ SignerAction $ DraftSigning $ DraftReplacement identity parent fee)
  :<|> (\(identity,minimumSequence)->Request $ SignerAction $ CheckpointSigning $ CheckpointCustody identity minimumSequence)

data SignerSettings = SignerSettings
  { signingNative :: N.NativeSettings, signingSolana :: S.SolanaSettings
  , signingPolicy :: H.SolanaPolicy, signingLibrary :: FilePath, signingKey :: FilePath
  , signingNativeUnlock :: Maybe FilePath
  , signingBackup :: Maybe (C.Config,FilePath,FilePath) }

-- The gate serializes complete decisions, including RPC/FFI and the second read.
-- Database read transactions finish before any external work starts.
signerApplication :: Manager -> Reader -> SignerSettings -> BasicAuthData -> IO Application
signerApplication manager reader settings credentials = do
  let native=signingNative settings; solana=signingSolana settings; config=signingPolicy settings
  require (N.profile native `elem` [L2LSignetDevnet,ECXBetanetDevnet]
    && S.solanaProfile solana==N.profile native
    && S.mint solana==H.mint config && S.custodyOwner solana==H.custodyOwner config
    && S.custodyAta solana==H.custodyAta config) "signer_profile_mismatch"
  N.validateNativeSettings native
  S.validateSolanaSettings solana
  verifySigningKey (S.custodyOwner solana) (signingKey settings)
  forM_ (signingNativeUnlock settings) $ \path->readNativeUnlock path >> pure ()
  gate<-newMVar ()
  let evalSigningCritical :: forall a. Request 'Signer 'Critical a -> IO a
      evalSigningCritical request=withMVar gate $ \_ -> case resolve request of
        SigningDSL (CheckpointSigning (CheckpointCustody identity minimumSequence))->do
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
        SigningDSL (DraftSigning (DraftReplacement identity parent fee))->do
          require (identity==H.fingerprint config) "signer_profile_mismatch"
          let readDecision=do
                now<-floor <$> getPOSIXTime
                evalRead reader (ReadReplacementDraftContext now parent fee)
          before<-readDecision
          draft<-draftNativeReplacement (N.nativeCall manager native) native (map snd before) fee
          after<-readDecision
          require (before==after) "signing_decision_changed"
          pure $ DraftResult draft
        SigningDSL (ReplacementSigning (SignReplacement identity decision))->do
          require (identity==H.fingerprint config) "signer_profile_mismatch"
          let readDecision=do
                now<-floor <$> getPOSIXTime
                evalRead reader (ReadReplacementSigning now decision)
          before@(family,draft)<-readDecision
          signed<-withNativeUnlock (N.nativeCall manager native) native (signingNativeUnlock settings) $
            signNativeReplacement (N.nativeCall manager native) native (map snd family) draft
          after<-readDecision
          require (before==after) "signing_decision_changed"
          parent<-case reverse family of (saved,_):_->pure saved; _->reject "native_replacement_family_bounds"
          pure $ ReplacementResult $ SignedAttempt (nativeTxid $ signedNativeTransaction signed) (signedNativeBytes signed)
            (TE.decodeUtf8 $ BL.toStrict $ encode signed) (commonInput $ recordedSigned parent)
        SigningDSL (PreparedSigning (SignPrepared identity identifier generation))->do
          require (identity==H.fingerprint config) "signer_profile_mismatch"
          let readDecision=do
                now<-floor <$> getPOSIXTime
                evalRead reader (ReadSigningDecision now identifier generation)
          before<-readDecision
          plan<-resolveSigningPlan (N.profile native) config before
          reply<-case plan of
            NativeAuthorization saved draft->do
              _<-N.nativeIdentity manager native
              withNativeUnlock (N.nativeCall manager native) native (signingNativeUnlock settings) $
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
          pure $ PreparedResult verified
  signingApplication credentials evalSigningCritical

-- Startup exposes an authenticated application/server, never its evaluator.
runSigner :: Manager -> Reader -> SignerSettings -> SigningEndpoint -> IO ()
runSigner manager reader settings endpoint=do
  credentials<-signerCredentials endpoint
  app<-signerApplication manager reader settings credentials
  runSigningServer endpoint app

data SigningEndpoint = SigningEndpoint { signerPort :: Int, signerAuthFile :: FilePath } deriving (Eq,Show)

signerCredentials :: SigningEndpoint -> IO BasicAuthData
signerCredentials endpoint = do
  require (signerPort endpoint>0 && signerPort endpoint<=65535) "invalid_signer_port"
  let path=signerAuthFile endpoint
  protectedSignerFile path True True
  bytes<-withBinaryFile path ReadMode (`BS.hGet` 66)
  let token=BS.take 64 bytes
  require (BS.length token==64 && BS.all (\x->x>=48 && x<=57 || x>=97 && x<=102) token
    && (bytes==token || bytes==token<>"\n")) "invalid_signer_auth_token"
  pure (BasicAuthData "worker" token)

signerCertificate :: SigningEndpoint -> IO SignedCertificate
signerCertificate endpoint = do
  let path=signerAuthFile endpoint<>".pem"
  protectedSignerFile path False False
  bytes<-withBinaryFile path ReadMode (`BS.hGet` 8193)
  require (BS.length bytes<=8192) "signer_certificate_too_large"
  pems<-either (const $ reject "invalid_signer_certificate") pure (pemParseBS bytes)
  case pems of
    [pem]->either (const $ reject "invalid_signer_certificate") pure (decodeSignedCertificate $ pemContent pem)
    _->reject "invalid_signer_certificate"

signingApplication :: BasicAuthData -> (forall a. Request 'Signer 'Critical a -> IO a) -> IO Application
signingApplication credentials evaluate = do
  let authenticate=BasicAuthCheck $ \supplied->pure $
        if BA.constEq (basicAuthUsername supplied) (basicAuthUsername credentials)
          && BA.constEq (basicAuthPassword supplied) (basicAuthPassword credentials)
        then Authorized () else Unauthorized
      interpret :: forall a. Request 'Signer 'Critical a -> Handler a
      interpret request = do
        result<-liftIO $ (Right <$> evaluate request) `catch` (\(BridgeError code)->pure $ Left code)
        either (\code->throwError err409 {errBody=encode $ object ["error" .= code],errHeaders=[("Content-Type","application/json")]}) pure result
      context=authenticate :. EmptyContext
      app=serveWithContext signingAPI context
        (hoistServerWithContext signingAPI (Proxy :: Proxy '[BasicAuthCheck ()]) interpret signingServer)
  boundedApplication 16 "signer_busy" app

runSigningServer :: SigningEndpoint -> Application -> IO ()
runSigningServer endpoint app = do
  _<-signerCertificate endpoint
  let key=signerAuthFile endpoint<>".key"
  protectedSignerFile key True False
  runTLS (tlsSettings (signerAuthFile endpoint<>".pem") key)
    (setHost "127.0.0.1" $ setPort (signerPort endpoint) $ setTimeout 315 defaultSettings) app
