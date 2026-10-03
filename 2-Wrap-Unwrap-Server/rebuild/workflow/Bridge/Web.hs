{-# LANGUAGE DataKinds, RankNTypes #-}
module Bridge.Web (customerApplication,boundedApplication) where
import Bridge.API
import Bridge.Operation (Plan,Caller(Customer))
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

customerApplication :: (forall a. Plan 'Customer a -> IO a) -> IO Application
customerApplication evaluate = boundedApplication 32 "server_busy" $
  serve customerAPI (hoistServer customerAPI interpret customerServer)
 where
  interpret :: forall a. Plan 'Customer a -> Handler a
  interpret plan = do
    result<-liftIO $ (Right <$> evaluate plan) `catch` (\(BridgeError code)->pure $ Left code)
    either (\code->throwError err409 {errBody=encode $ object ["error" .= code],errHeaders=[("Content-Type","application/json")]}) pure result

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
    let answer=respond . mapResponseHeaders (("Cache-Control","no-store"):)
        bad status code=answer $ responseLBS status [("Content-Type","application/json")] (encode $ object ["error" .= (code::Text)])
    if not admitted then bad HTTP.status503 busy
    else if lookup "Sec-Fetch-Site" (requestHeaders request)==Just "cross-site" then bad HTTP.status403 "cross_origin_request"
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
