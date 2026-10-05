{-# LANGUAGE ConstraintKinds, DataKinds, RankNTypes #-}
module Bridge.Web (customerApplication,publicApplication,boundedApplication,runPublicServer,rateLimitedApplication) where
import Bridge.API
import Bridge.Operation (Plan,Caller(Customer),CustomerOperations)
import Bridge.Credentials (protectedSignerFile)
import Bridge.Error
import Control.Concurrent.STM
import Control.Exception (bracket,catch)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (encode,object,(.=))
import qualified Data.ByteString as BS
import Data.IORef (newIORef,atomicModifyIORef')
import Data.Text (Text)
import qualified Network.HTTP.Types as HTTP
import Network.Wai
import Servant
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Environment (lookupEnv)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Wai.Handler.Warp (runSettings,setHost,setPort,setTimeout,defaultSettings)
import Network.Wai.Handler.WarpTLS (runTLS,tlsSettings)

customerApplication :: CustomerOperations => (forall a. Plan 'Customer a -> IO a) -> IO Application
customerApplication evaluate = boundedApplication 32 "server_busy" (customerRoutes evaluate)

customerRoutes :: CustomerOperations => (forall a. Plan 'Customer a -> IO a) -> Application
customerRoutes evaluate = serve customerAPI (hoistServer customerAPI interpret customerServer)
 where
  interpret :: forall a. Plan 'Customer a -> Handler a
  interpret plan = do
    result<-liftIO $ (Right <$> evaluate plan) `catch` (\(BridgeError code)->pure $ Left code)
    either (\code->throwError err409 {errBody=encode $ object ["error" .= code],errHeaders=[("Content-Type","application/json")]}) pure result

-- Exactly three static resources, built from Haskell/HTML/CSS by root Cabal.
-- A requested path is never joined to a filesystem path.
publicApplication :: CustomerOperations => FilePath -> (forall a. Plan 'Customer a -> IO a) -> IO Application
publicApplication assets evaluate = do
  let files=[([],"index.html","text/html; charset=utf-8"),(["style.css"],"style.css","text/css; charset=utf-8"),
             (["wallet.js"],"dist/wallet.js","text/javascript; charset=utf-8")]
  mapM_ (\(_,file,_)->doesFileExist (assets</>file) >>= flip require "browser_assets_missing") files
  boundedApplication 32 "server_busy" $ \request respond->
    case [(file,mime)|(path,file,mime)<-files,pathInfo request==path,requestMethod request=="GET"] of
      [(file,mime)]->respond $ responseFile HTTP.status200 [("Content-Type",mime)] (assets</>file) Nothing
      _->customerRoutes evaluate request respond

-- Both HTTP surfaces share the same bounded body and concurrency behavior.
-- This middleware carries no operation or evaluation authority.
boundedApplication :: Int -> Text -> Application -> IO Application
boundedApplication capacity busy app = do
  active<-newTVarIO (0::Int)
  let acquire=atomically $ do
        n<-readTVar active
        if n>=capacity then pure False else writeTVar active (n+1) >> pure True
      release admitted=when admitted $ atomically (modifyTVar' active (subtract 1))
  pure $ \request respond->bracket acquire release $ \admitted->do
    let headers=[("Cache-Control","no-store"),("Referrer-Policy","no-referrer"),("X-Content-Type-Options","nosniff"),
          ("Content-Security-Policy","default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")]
        answer=respond . mapResponseHeaders (headers<>)
        bad status code=answer $ responseLBS status [("Content-Type","application/json")] (encode $ object ["error" .= (code::Text)])
    if not admitted then bad HTTP.status503 busy
    else if lookup "Sec-Fetch-Site" (requestHeaders request)==Just "cross-site" && requestMethod request/="GET" then bad HTTP.status403 "cross_origin_request"
    else do
      result<-(Right <$> consume request 0 []) `catch` (\(BridgeError code)->pure $ Left code)
      case result of
        Left code->bad HTTP.status413 code
        Right bytes->do
          body<-newIORef bytes
          app (setRequestBodyChunks (atomicModifyIORef' body $ \b->(BS.empty,b)) request) answer
 where
  consume request total chunks = do
    bytes<-getRequestBodyChunk request
    let size=total+BS.length bytes
    require (size<=4096) "request_too_large"
    if BS.null bytes then pure (BS.concat $ reverse chunks) else consume request size (bytes:chunks)

-- TLS terminates at the existing Servant application, without a forwarding hop.
-- Absent TLS stays loopback-only; partial TLS configuration must never downgrade.
runPublicServer :: Int -> Application -> IO ()
runPublicServer port app = do
  certificate<-lookupEnv "ECX_PUBLIC_TLS_CERT"
  key<-lookupEnv "ECX_PUBLIC_TLS_KEY"
  let settings=setPort port $ setTimeout 65 defaultSettings
  case (certificate,key) of
    (Nothing,Nothing)->runSettings (setHost "127.0.0.1" settings) app
    (Just cert,Just secret)->do
      require (cert/=secret) "public_tls_files_must_differ"
      protectedSignerFile cert False False
      protectedSignerFile secret True False
      limited<-rateLimitedApplication (toInteger <$> getMonotonicTimeNSec) app
      runTLS (tlsSettings cert secret) (setHost "*4" settings) limited
    _->reject "public_tls_requires_certificate_and_key"

-- Two constant-space, atomic admission budgets; no attacker-controlled IP map.
-- These are global limits, not provider quotas or network-level DDoS protection.
rateLimitedApplication :: IO Integer -> Application -> IO Application
rateLimitedApplication clock app = do
  arrivals<-newTVarIO (0,0)
  pure $ \request respond->do
    now<-clock
    accepted<-atomically $ do
      (allAt,orderAt)<-readTVar arrivals
      let creating=requestMethod request=="POST" && filter (/="") (pathInfo request)==["api","v1","orders"]
          nextAll=max now allAt+33333334
          nextOrder=if creating then max now orderAt+2000000000 else orderAt
          allowed=nextAll<=now+60*33333334 && (not creating || nextOrder<=now+4000000000)
      if allowed then writeTVar arrivals (nextAll,nextOrder) >> pure True else pure False
    if accepted then app request respond else respond $
      responseLBS HTTP.status429 [("Content-Type","application/json"),("Cache-Control","no-store"),("Retry-After","2")]
        "{\"error\":\"request_rate_limited\"}"
