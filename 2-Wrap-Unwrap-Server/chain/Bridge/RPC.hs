{-# LANGUAGE ScopedTypeVariables, LambdaCase #-}
module Bridge.RPC (newRpcManager, rpcManagerSettings, rpcHost, withSolanaRpc, independentHttps, rpc, retryRpcRead, parseValue, fieldValue, boundedBody) where

import Bridge.Error
import Control.Exception (bracket, catch, try, throwIO)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Monad (when)
import Data.Char (toLower)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

newRpcManager :: IO Manager
newRpcManager = do
  configured<-lookupEnv "ECX_RPC_REQUESTS_PER_SECOND"
  rate<-maybe (pure 2) (maybe (reject "invalid_rpc_rate") pure . readMaybe) configured
  rpcManagerSettings rate (toInteger <$> getMonotonicTimeNSec) threadDelay >>= newManager

rpcHost :: Request -> BS.ByteString
rpcHost = BSC.dropWhileEnd (=='.') . BSC.map toLower . host

-- Only session mechanics are shared. Each closed caller supplies its expected
-- network and refusal categories; no authority or mutable chain fact is cached.
withSolanaRpc :: String -> Text -> (Text,Text) -> ((Text -> [Value] -> IO Value) -> IO a) -> IO a
withSolanaRpc endpoint genesis (transportError,identityError) action = do
  request<-parseRequest endpoint
  require (secure request) transportError
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
    actual<-call "getGenesisHash" [] >>= parseValue parseJSON
    require (actual==genesis) identityError
    action call

independentHttps :: String -> String -> IO ()
independentHttps primary verifier = do
  first<-parseRequest primary; second<-parseRequest verifier
  require (secure first && secure second && rpcHost first/=rpcHost second) "independent_https_providers_required"

-- Per-manager HTTPS admission pacing, not a provider-wide or wire-arrival quota.
-- Worker, signer and administration processes need budgets whose sum fits the
-- provider plan. Host keys exclude credentials, paths and query strings.
rpcManagerSettings :: Int -> IO Integer -> (Int -> IO ()) -> IO ManagerSettings
rpcManagerSettings rate clock wait = do
  require (rate>=1 && rate<=1000) "invalid_rpc_rate"
  hosts<-newMVar M.empty
  let interval=(1000000000+toInteger rate-1) `div` toInteger rate
      untilTime next=do
        now<-clock
        when (now<next) $ wait (fromInteger $ min 1000000 ((next-now+999) `div` 1000)) >> untilTime next
      pace request=when (secure request) $ do
        let key=rpcHost request
        gate<-modifyMVar hosts $ \known->case M.lookup key known of
          Just existing->pure (known,existing)
          Nothing->do fresh<-newMVar 0; pure (M.insert key fresh known,fresh)
        -- Hold only this host's gate while waiting. A delayed/cancelled caller
        -- cannot leave reserved future slots that later dispatch in a burst.
        modifyMVar_ gate $ \next->untilTime next >> ((+interval) <$> clock)
      base=managerSetProxy noProxy tlsManagerSettings
        { managerRetryableException = const False, managerConnCount = 4
        , managerResponseTimeout = responseTimeoutMicro 15000000 }
  -- http-client calls managerModifyRequest twice. This wrapper is called once
  -- per responseOpen, including each explicit read retry; RPC redirects are off.
  pure base {managerWrapException= \request action->managerWrapException base request (pace request >> action)}
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
rpc manager url auth methodName params = retryRpcRead threadDelay methodName run
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
      -- sooner. Mutating calls are never retried.
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
-- mutation. Closed reads, rate limits and unavailable Solana history storage
-- share at most two retries;
-- timeouts and other transport failures remain unknown. HTTPS retries are paced
-- by the manager, and callers still recheck time and blockhash.
retryRpcRead :: (Int -> IO ()) -> Text -> IO (Either (Maybe Int) a) -> IO a
retryRpcRead wait methodName action = go (0::Int)
 where
  readsOnly=methodName `elem`
    ["getGenesisHash","getAccountInfo","getMultipleAccounts","getLatestBlockhash","getBlock"
    ,"getBlockHeight","getSlot","isBlockhashValid","getFeeForMessage","getMinimumBalanceForRentExemption"
    ,"getSignatureStatuses","getTransaction","getSignaturesForAddress"
    ,"getblockchaininfo","getblockhash","getblockheader","getwalletinfo","getbalances"
    ,"getaddressinfo","getaddressesbylabel","gettransaction","listsinceblock","gettxout","listlockunspent","listunspent","decodescript"
    ,"decoderawtransaction","decodepsbt","estimatesmartfee","getmempoolinfo","getmempoolentry"]
  closed NoResponseDataReceived=True
  closed ConnectionClosed=True
  closed _=False
  go tries=try (try action) >>= \case
    Left e@(HttpExceptionRequest _ failure)
      | readsOnly && tries<2 && closed failure -> wait 250000 >> go (tries+1)
      | otherwise -> throwIO e
    Left e -> throwIO e
    Right (Left e@(BridgeError code))
      | code=="rpc_error_-32019" && tries<2
        && methodName `elem` ["getTransaction","getSignatureStatuses","getSignaturesForAddress"] ->
          wait 250000 >> go (tries+1)
      | otherwise -> throwIO e
    Right (Right (Right result)) -> pure result
    Right (Right (Left requested)) -> do
      let seconds=maybe (4*(tries+1)) id requested
      require (readsOnly && tries<2 && seconds>=0 && seconds<=15) "rpc_rate_limited"
      wait (max 1 seconds*1000000)
      go (tries+1)
