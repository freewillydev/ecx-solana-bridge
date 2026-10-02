{-# LANGUAGE DataKinds, GADTs, RankNTypes, TypeOperators #-}
-- Authenticated loopback signer HTTP only; no control or broadcast routes.
module Bridge.Operator (SigningAPI, signingAPI, signerCredentials, signerCertificate, runSigningServer, signingApplication) where

import Bridge.Config (Config(signerPort,signerAuthFile))
import Bridge.Operation.Internal
import Bridge.Types (Amount, reject, require)
import Bridge.Web (asHandler, securityBoundary)
import Control.Concurrent.MVar (newMVar, withMVar)
import Data.Aeson (Value)
import Data.Bits ((.&.))
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Text (Text)
import Network.Wai.Handler.Warp (setHost,setPort,defaultSettings)
import Network.Wai.Handler.WarpTLS (runTLS,tlsSettings)
import Data.PEM (pemParseBS,pemContent)
import Data.X509 (SignedCertificate,decodeSignedCertificate)
import Servant
import System.FilePath (takeDirectory)
import System.IO (withBinaryFile,IOMode(ReadMode))
import System.Posix.Files (getSymbolicLinkStatus,getFileStatus,fileMode,fileOwner,isRegularFile)
import System.Posix.User (getEffectiveUserID)

type SigningAPI = BasicAuth "signer" () :> SigningOperations
type SigningOperations = "sign-preparation" :> ReqBody '[JSON] (Text, Text, Int) :> Post '[JSON] Value
  :<|> "draft-replacement" :> ReqBody '[JSON] (Text, Text, Amount) :> Post '[JSON] Value
  :<|> "sign-replacement" :> ReqBody '[JSON] (Text, Int64) :> Post '[JSON] Value

signingAPI :: Proxy SigningAPI
signingAPI = Proxy

-- The shared API contains no keys or executable client capability. Runtime
-- generates its ClientM functions privately inside the critical interpreter.
server :: ServerT SigningAPI (Request 'Critical)
server () = (\(identity, intent, generation) -> Request (SignPrepared identity intent generation))
  :<|> (\(identity, parent, fee) -> Request (DraftReplacement identity parent fee))
  :<|> (\(identity, sequenceNo) -> Request (SignReplacement identity sequenceNo))

-- Root or the service user owns a regular credential file, mode 0600 or 0640.
-- Group-read supports a dedicated worker/signer group; no group write or public
-- access. The containing directory must also reject group/world writes.
signerCredentials :: Config -> IO BasicAuthData
signerCredentials cfg = do
  let path=signerAuthFile cfg
  uid <- getEffectiveUserID
  status <- getSymbolicLinkStatus path
  parent <- getFileStatus (takeDirectory path)
  require (isRegularFile status && fileOwner status `elem` [0,uid]
    && fileMode status .&. 0o777 `elem` [0o600,0o640]
    && fileOwner parent `elem` [0,uid] && fileMode parent .&. 0o022==0) "unsafe_signer_auth_permissions"
  bytes <- withBinaryFile path ReadMode (\h->BS.hGet h 66)
  let token=BS.take 64 bytes
  require (BS.length token==64 && BS.all (\x->x>=48 && x<=57 || x>=97 && x<=102) token
    && (bytes==token || bytes==token<>"\n")) "invalid_signer_auth_token"
  pure (BasicAuthData "worker" token)

signingApplication :: BasicAuthData -> (forall a. SigningOperation a -> IO a) -> IO Application
signingApplication credentials evaluate = do
  gate <- newMVar ()
  let authenticate=BasicAuthCheck $ \supplied -> pure $
        if BA.constEq (basicAuthUsername supplied) (basicAuthUsername credentials)
          && BA.constEq (basicAuthPassword supplied) (basicAuthPassword credentials)
        then Authorized () else Unauthorized
      interpret :: forall a. Request 'Critical a -> Handler a
      interpret request = asHandler $ withMVar gate $ \_ -> case resolve request of
        SigningDSL operation -> evaluate operation
        _ -> reject "signer_command_required"
      context=authenticate :. EmptyContext
  securityBoundary (serveWithContext signingAPI context
    (hoistServerWithContext signingAPI (Proxy :: Proxy '[BasicAuthCheck ()]) interpret server))

-- Only the configured certificate is trusted by the worker; the host trust
-- store cannot authorize a different local listener. The file is public but its
-- owner and directory must protect it against unauthorized replacement.
signerCertificate :: Config -> IO SignedCertificate
signerCertificate cfg = do
  let path=signerAuthFile cfg<>".pem"
  uid <- getEffectiveUserID
  status <- getSymbolicLinkStatus path
  parent <- getFileStatus (takeDirectory path)
  require (isRegularFile status && fileOwner status `elem` [0,uid]
    && fileMode status .&. 0o022==0 && fileOwner parent `elem` [0,uid] && fileMode parent .&. 0o022==0) "unsafe_signer_certificate_permissions"
  bytes <- withBinaryFile path ReadMode (\h->BS.hGet h 8193)
  require (BS.length bytes<=8192) "signer_certificate_too_large"
  pems <- either (const $ reject "invalid_signer_certificate") pure (pemParseBS bytes)
  case pems of
    [pem]->either (const $ reject "invalid_signer_certificate") pure (decodeSignedCertificate $ pemContent pem)
    _->reject "invalid_signer_certificate"

runSigningServer :: Config -> (forall a. SigningOperation a -> IO a) -> IO ()
runSigningServer cfg evaluate = do
  credentials <- signerCredentials cfg
  _ <- signerCertificate cfg
  let key=signerAuthFile cfg<>".key"
  uid <- getEffectiveUserID
  status <- getSymbolicLinkStatus key
  require (isRegularFile status && fileOwner status `elem` [0,uid]
    && fileMode status .&. 0o777==0o600) "unsafe_signer_tls_key_permissions"
  application <- signingApplication credentials evaluate
  runTLS (tlsSettings (signerAuthFile cfg<>".pem") key)
    (setHost "127.0.0.1" $ setPort (signerPort cfg) defaultSettings) application
