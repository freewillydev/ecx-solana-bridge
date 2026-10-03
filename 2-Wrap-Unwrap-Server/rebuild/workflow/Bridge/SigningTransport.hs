{-# LANGUAGE DataKinds, RankNTypes, ScopedTypeVariables #-}
-- Shared authenticated HTTP contract, never a signer client or signing authority.
module Bridge.SigningTransport
  ( SigningEndpoint(..), signerCredentials, signerCertificate, signingApplication, runSigningServer ) where
import Bridge.Web (boundedApplication)
import Bridge.Error
import Bridge.Operation.Internal
import Bridge.Signer (signingAPI,signingServer)
import Control.Exception (catch)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (encode,object,(.=))
import Data.Bits ((.&.))
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.PEM (pemParseBS,pemContent)
import Data.X509 (SignedCertificate,decodeSignedCertificate)
import Network.Wai hiding (Request)
import Network.Wai.Handler.Warp (setHost,setPort,setTimeout,defaultSettings)
import Network.Wai.Handler.WarpTLS (runTLS,tlsSettings)
import Servant hiding (respond)
import System.FilePath (isAbsolute,takeDirectory)
import System.IO (withBinaryFile,IOMode(ReadMode))
import System.Posix.Files
import System.Posix.User (getEffectiveUserID)

data SigningEndpoint = SigningEndpoint { signerPort :: Int, signerAuthFile :: FilePath } deriving (Eq,Show)

-- Secret files permit group read only for the shared auth token. Certificates
-- may be public, but neither they nor their parent may be replaced by that group.
protected :: FilePath -> Bool -> Bool -> IO ()
protected path secret shared = do
  require (isAbsolute path) "absolute_credential_path_required"
  uid<-getEffectiveUserID
  file<-getSymbolicLinkStatus path
  parent<-getFileStatus (takeDirectory path)
  let mode=fileMode file .&. 0o777
  require (isRegularFile file && fileOwner file `elem` [0,uid]
    && fileOwner parent `elem` [0,uid] && fileMode parent .&. 0o022==0
    && if secret then mode==0o600 || shared && mode==0o640 else mode .&. 0o022==0) "unsafe_signer_file_permissions"

signerCredentials :: SigningEndpoint -> IO BasicAuthData
signerCredentials endpoint = do
  require (signerPort endpoint>0 && signerPort endpoint<=65535) "invalid_signer_port"
  let path=signerAuthFile endpoint
  protected path True True
  bytes<-withBinaryFile path ReadMode (`BS.hGet` 66)
  let token=BS.take 64 bytes
  require (BS.length token==64 && BS.all (\x->x>=48 && x<=57 || x>=97 && x<=102) token
    && (bytes==token || bytes==token<>"\n")) "invalid_signer_auth_token"
  pure (BasicAuthData "worker" token)

signerCertificate :: SigningEndpoint -> IO SignedCertificate
signerCertificate endpoint = do
  let path=signerAuthFile endpoint<>".pem"
  protected path False False
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

runSigningServer :: SigningEndpoint -> (forall a. Request 'Signer 'Critical a -> IO a) -> IO ()
runSigningServer endpoint evaluate = do
  credentials<-signerCredentials endpoint
  _<-signerCertificate endpoint
  let key=signerAuthFile endpoint<>".key"
  protected key True False
  app<-signingApplication credentials evaluate
  runTLS (tlsSettings (signerAuthFile endpoint<>".pem") key)
    (setHost "127.0.0.1" $ setPort (signerPort endpoint) $ setTimeout 65 defaultSettings) app
