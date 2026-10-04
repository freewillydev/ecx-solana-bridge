{-# LANGUAGE DataKinds, FlexibleContexts, RankNTypes, TypeOperators #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Authenticated signer transport. Concrete signing runs in Bridge.Critical.
module Bridge.Signer
  ( SigningAPI, signingAPI, signingServer, verifySigningKey, protectedSignerFile
  , SigningEndpoint(..), signerCredentials, signerCertificate, signingApplication, runSigningServer ) where
import Bridge.Operation.Internal
import Bridge.Credentials (verifySigningKey,protectedSignerFile)
import Control.Exception (catch)
import Data.Aeson (encode,object,(.=))
import Bridge.Domain (Amount)
import Bridge.Error
import Data.Int (Int64)
import Data.Text (Text)
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
signingServer :: Operation 'Signer 'Critical SignerCommand => ServerT SigningAPI (Request 'Signer 'Critical)
signingServer () = (\(identity,identifier,generation)->Request $ SignerAction $ PreparedSigning $ SignPrepared identity identifier generation)
  :<|> (\(identity,decision)->Request $ SignerAction $ ReplacementSigning $ SignReplacement identity decision)
  :<|> (\(identity,parent,fee)->Request $ SignerAction $ DraftSigning $ DraftReplacement identity parent fee)
  :<|> (\(identity,minimumSequence)->Request $ SignerAction $ CheckpointSigning $ CheckpointCustody identity minimumSequence)

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

signingApplication :: Operation 'Signer 'Critical SignerCommand => BasicAuthData -> (forall a. Request 'Signer 'Critical a -> IO a) -> IO Application
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
