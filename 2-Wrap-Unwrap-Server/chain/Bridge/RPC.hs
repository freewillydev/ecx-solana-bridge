{-# LANGUAGE ScopedTypeVariables, LambdaCase #-}
module Bridge.RPC (newRpcManager, rpc, retryRateLimitedRead, parseValue, fieldValue, boundedBody) where

import Bridge.Error
import Control.Exception (catch)
import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Text.Read (readMaybe)

newRpcManager :: IO Manager
newRpcManager = newManager $ managerSetProxy noProxy tlsManagerSettings
  { managerRetryableException = const False, managerConnCount = 4
  , managerResponseTimeout = responseTimeoutMicro 15000000 }
boundedBody :: Int -> BodyReader -> IO BS.ByteString
boundedBody maximumBytes reader = require (maximumBytes>=0) "invalid_response_bound" >> go 0 []
 where
  go total chunks = do
    chunk <- brRead reader
    when (BS.length chunk>maximumBytes-total) (reject "rpc_response_too_large")
    if BS.null chunk then pure (BS.concat (reverse chunks)) else go (total+BS.length chunk) (chunk:chunks)
parseValue :: (Value -> Parser a) -> Value -> IO a
parseValue p v = either (const $ reject "unexpected_rpc_schema") pure (parseEither p v)
fieldValue :: FromJSON a => Key -> Value -> IO a
fieldValue k = parseValue (withObject "object" (.: k))
rpc :: Manager -> String -> Maybe (BS.ByteString,BS.ByteString) -> Text -> [Value] -> IO Value
rpc manager url auth methodName params = retryRateLimitedRead threadDelay methodName run
  `catch` (\(_ :: HttpException) -> reject "rpc_transport_unknown_outcome")
 where
  run = do
    base <- parseRequest url
    let req0 = base { method="POST", redirectCount=0, checkResponse = \_ _ -> pure ()
                    , requestHeaders=[("Content-Type","application/json")]
                    , requestBody=RequestBodyLBS (encode $ object ["jsonrpc" .= ("2.0"::Text),"id" .= (1::Int),"method" .= methodName,"params" .= params]) }
        req = maybe req0 (\(u,p) -> applyBasicAuth u p req0) auth
    withResponse req manager $ \response -> do
      bytes <- boundedBody (4*1024*1024) (responseBody response)
      -- An unsupported Retry-After form is a stop, never permission to retry
      -- sooner. Neither transport errors nor mutating calls are retried here.
      require (statusCode (responseStatus response)/=403) "rpc_method_forbidden"
      let delay=case lookup "Retry-After" (responseHeaders response) of
            Nothing -> Nothing
            Just h -> Just $ maybe (maxBound::Int) id (readMaybe $ BSC.unpack h)
      if statusCode (responseStatus response)==429 then pure (Left delay) else do
        value <- either (const $ reject "rpc_invalid_json") pure (eitherDecodeStrict' bytes)
        identity <- fieldValue "id" value :: IO Int
        require (identity==1) "rpc_id_mismatch"
        err <- parseValue (withObject "RPC" (.:? "error")) value :: IO (Maybe Value)
        code <- case err of Nothing->pure Nothing; Just Null->pure Nothing; Just e->Just <$> fieldValue "code" e
        case code of
          Just (429::Int) -> pure (Left delay)
          Just n -> reject ("rpc_error_"<>T.pack (show n))
          Nothing -> do
            require (statusCode (responseStatus response)==200) "rpc_http_status"
            Right <$> fieldValue "result" value

-- Explicit allowlist: a typo/new method cannot accidentally retry a wallet
-- mutation. At most two bounded waits; callers still recheck time and blockhash.
retryRateLimitedRead :: (Int -> IO ()) -> Text -> IO (Either (Maybe Int) a) -> IO a
retryRateLimitedRead wait methodName action = go (0::Int)
 where
  readsOnly=methodName `elem`
    ["getGenesisHash","getAccountInfo","getMultipleAccounts","getLatestBlockhash","getBlock"
    ,"getBlockHeight","getSlot","isBlockhashValid","getFeeForMessage","getMinimumBalanceForRentExemption"
    ,"getSignatureStatuses","getTransaction","getSignaturesForAddress"
    ,"getblockchaininfo","getblockhash","getblockheader","getwalletinfo","getbalances"
    ,"getaddressinfo","getaddressesbylabel","gettransaction","listsinceblock","gettxout","listlockunspent","listunspent","decodescript"
    ,"decoderawtransaction","decodepsbt","estimatesmartfee","getmempoolinfo","getmempoolentry"]
  go tries=action >>= \case
    Right result -> pure result
    Left requested -> do
      let seconds=maybe (4*(tries+1)) id requested
      require (readsOnly && tries<2 && seconds>=0 && seconds<=15) "rpc_rate_limited"
      wait (max 1 seconds*1000000)
      go (tries+1)
