{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Web (runUnix, runPublic, publicApplication, securityBoundary, asHandler) where

import Control.Monad.IO.Class (liftIO)
import Bridge.Types
import Control.Concurrent.STM
import Control.Exception (bracket,catch)
import Control.Monad (when)
import Data.Aeson (encode,object,(.=))
import qualified Data.ByteString as BS
import Data.IORef
import Data.Text (Text)
import Network.HTTP.Types
import qualified Network.Socket as NS
import Network.Wai
import Network.Wai.Handler.Warp
import Servant hiding (respond)
import System.Directory (createDirectoryIfMissing,removeFile,doesPathExist)
import System.FilePath ((</>),takeDirectory)
import System.Posix.Files (setFileMode)

asHandler :: IO a -> Handler a
asHandler action = do
  outcome <- liftIO $ (Right <$> action) `catch` (\(BridgeError code) -> pure (Left code))
  case outcome of
    Right result -> pure result
    Left code -> throwError err409 {errBody=encode (object ["error" .= code]),errHeaders=[("Content-Type","application/json")]}
runUnix :: FilePath -> Integer -> Application -> IO ()
runUnix path mode app = do
  createDirectoryIfMissing True (takeDirectory path)
  setFileMode (takeDirectory path) 0o750
  -- Caller holds the worker lock. Only its stale socket may be removed.
  existing <- doesPathExist path
  when existing (removeFile path)
  bracket (NS.socket NS.AF_UNIX NS.Stream NS.defaultProtocol) NS.close $ \sock -> do
    NS.bind sock (NS.SockAddrUnix path)
    setFileMode path (fromInteger mode)
    NS.listen sock 64
    runSettingsSocket (setTimeout 20 defaultSettings) sock app
securityBoundary :: Application -> IO Application
securityBoundary app = do
  active <- newTVarIO (0::Int)
  let acquire = atomically $ do
        n <- readTVar active
        if n>=64 then pure False else writeTVar active (n+1) >> pure True
      release admitted = when admitted $ atomically (modifyTVar' active (subtract 1))
  pure $ \request respond -> bracket acquire release $ \admitted -> do
    let headers=[("Cache-Control","no-store"),("Referrer-Policy","no-referrer"),("X-Content-Type-Options","nosniff"),("Content-Security-Policy","default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")]
        answer = respond . mapResponseHeaders (headers<>)
        bad statusCode code = answer $ responseLBS statusCode [("Content-Type","application/json")] (encode $ object ["error" .= (code::Text)])
    if not admitted then bad status503 "server_busy" else if lookup "Sec-Fetch-Site" (requestHeaders request)==Just "cross-site" && requestMethod request/="GET"
      then bad status403 "cross_origin_request"
      else do
        result <- (Right <$> consume request 0 []) `catch` (\(BridgeError c) -> pure (Left c))
        case result of
          Left code -> bad status413 code
          Right bytes -> do
            ref <- newIORef bytes
            app (setRequestBodyChunks (atomicModifyIORef' ref (\b -> (BS.empty,b))) request) answer
 where
  consume req total chunks = do
    b <- getRequestBodyChunk req
    let n=total+BS.length b
    require (n<=16384) "request_too_large"
    if BS.null b then pure (BS.concat $ reverse chunks) else consume req n (b:chunks)
-- The API supplied here is the DSL-backed server, not a generated client.
runPublic :: Int -> FilePath -> Application -> IO ()
runPublic port assets api = do
  application <- publicApplication assets api
  runSettings (setHost "127.0.0.1" $ setPort port $ setTimeout 20 defaultSettings) application

publicApplication :: FilePath -> Application -> IO Application
publicApplication assets api = do
  let application req respond = case (requestMethod req,pathInfo req) of
        ("GET",[]) -> file "index.html" "text/html; charset=utf-8" respond
        ("GET",["style.css"]) -> file "style.css" "text/css; charset=utf-8" respond
        ("GET",["wallet.js"]) -> file "dist/wallet.js" "text/javascript; charset=utf-8" respond
        _ -> api req respond
      file name mime respond = respond $ responseFile status200 [("Content-Type",mime)] (assets </> name) Nothing
  securityBoundary application
