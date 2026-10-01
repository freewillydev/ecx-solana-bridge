{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.RPC (newRpcManager, rpc, parseValue, fieldValue, boundedBody, unixManager) where

import Bridge.Types
import Control.Exception (bracketOnError, catch)
import Control.Monad (when)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import Data.Text (Text)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import qualified Network.Socket as NS

newRpcManager :: IO Manager
newRpcManager = newManager $ managerSetProxy noProxy tlsManagerSettings
  { managerRetryableException = const False, managerConnCount = 4
  , managerResponseTimeout = responseTimeoutMicro 15000000 }
unixManager :: FilePath -> IO Manager
unixManager path = newManager $ managerSetProxy noProxy defaultManagerSettings
  { managerRetryableException = const False, managerConnCount = 8
  , managerResponseTimeout = responseTimeoutMicro 15000000
  , managerRawConnection = pure $ \_ _ _ -> bracketOnError (NS.socket NS.AF_UNIX NS.Stream NS.defaultProtocol) NS.close $ \sock -> do
      NS.connect sock (NS.SockAddrUnix path)
      socketConnection sock 8192 }
boundedBody :: Int -> BodyReader -> IO BS.ByteString
boundedBody maximumBytes reader = go 0 []
 where
  go total chunks = do
    chunk <- brRead reader
    let next = total+BS.length chunk
    when (next>maximumBytes) (reject "rpc_response_too_large")
    if BS.null chunk then pure (BS.concat (reverse chunks)) else go next (chunk:chunks)
parseValue :: (Value -> Parser a) -> Value -> IO a
parseValue p v = either (const $ reject "unexpected_rpc_schema") pure (parseEither p v)
fieldValue :: FromJSON a => Key -> Value -> IO a
fieldValue k = parseValue (withObject "object" (.: k))
rpc :: Manager -> String -> Maybe (BS.ByteString,BS.ByteString) -> Text -> [Value] -> IO Value
rpc manager url auth methodName params = run `catch` (\(_ :: HttpException) -> reject "rpc_transport_unknown_outcome")
 where
  run = do
    base <- parseRequest url
    let req0 = base { method="POST", redirectCount=0, checkResponse = \_ _ -> pure ()
                    , requestHeaders=[("Content-Type","application/json")]
                    , requestBody=RequestBodyLBS (encode $ object ["jsonrpc" .= ("2.0"::Text),"id" .= (1::Int),"method" .= methodName,"params" .= params]) }
        req = maybe req0 (\(u,p) -> applyBasicAuth u p req0) auth
    withResponse req manager $ \response -> do
      bytes <- boundedBody (4*1024*1024) (responseBody response)
      value <- either (const $ reject "rpc_invalid_json") pure (eitherDecodeStrict' bytes)
      identity <- fieldValue "id" value :: IO Int
      require (identity==1) "rpc_id_mismatch"
      err <- parseValue (withObject "RPC" (.:? "error")) value :: IO (Maybe Value)
      when (err/=Nothing && err/=Just Null) $ do
        -- Error text is untrusted and may contain credentials or supplied bytes.
        reject "rpc_returned_error"
      require (statusCode (responseStatus response)==200) "rpc_http_status"
      fieldValue "result" value
