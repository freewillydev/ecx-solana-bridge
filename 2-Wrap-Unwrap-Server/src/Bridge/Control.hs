{-# LANGUAGE GADTs, RankNTypes, ScopedTypeVariables #-}
-- Local control protocol. No operator HTTP routes and no serialized DSL.
module Bridge.Control (runControl, callControl) where

import Bridge.Config (Config(adminSocket))
import Bridge.Ledger.Model (LossCapital)
import Bridge.Operation.Internal (Plan, SafeOperation(Readiness,Audit,Scanners), OperatorOperation(..), safe, operator)
import Bridge.Types
import Control.Exception (bracket, catch, IOException)
import Control.Monad (forever)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Binary.Get (runGet, getWord32be)
import Data.Binary.Put (runPut, putWord32be)
import Data.Text (Text)
import Data.Int (Int64)
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as S
import System.Timeout (timeout)
import Bridge.Web (withUnixListener)

data ControlPlan where
  ControlPlan :: ToJSON a => Plan a -> ControlPlan

-- Named operations only; arguments decode into their concrete domain types.
controlPlan :: Value -> Parser ControlPlan
controlPlan = withObject "operator command" $ \o -> do
  command <- o .: "operation" :: Parser Text
  args <- o .:? "arguments" .!= Null
  case command of
    "health" -> pure (ControlPlan $ safe Readiness)
    "audit" -> pure (ControlPlan $ safe Audit)
    "scanners" -> pure (ControlPlan $ safe Scanners)
    "pause" -> unary args Pause
    "resume" -> pure (ControlPlan $ operator Resume)
    "refund" -> unary args RefundDeposit
    "retry-solana" -> binary args ApproveSolanaRetry
    "cancel-preparation" -> ternary args CancelPreparation
    "approve-source-recovery" -> ternary args ApproveSourceRecovery
    "approve-covered-source" -> ternary args ApproveCoveredSource
    "rebroadcast-native" -> ternary args RebroadcastNative
    "prepare-native-replacement" -> ternary args PrepareNativeReplacement
    "sign-native-replacement" -> unary args SignNativeReplacement
    "cancel-native-replacement" -> binary args CancelNativeReplacement
    "send-native-replacement" -> unary args SendNativeReplacement
    "cover-source-loss" -> do
      (receipt, sequenceNo, capital, reason) <- parseJSON args :: Parser (Text,Int64,LossCapital,Text)
      pure (ControlPlan $ operator $ CoverSourceLoss receipt sequenceNo capital reason)
    "allocate-treasury" -> ternary args AllocateTreasury
    "classify-treasury-spend" -> ternary args ClassifyTreasurySpend
    _ -> fail "unknown operator operation"
 where
  unary :: (FromJSON x, ToJSON a) => Value -> (x -> OperatorOperation a) -> Parser ControlPlan
  unary args operation = ControlPlan . operator . operation <$> parseJSON args
  binary :: (FromJSON x, FromJSON y, ToJSON a) => Value -> (x -> y -> OperatorOperation a) -> Parser ControlPlan
  binary args operation = do
    (x,y) <- parseJSON args
    pure (ControlPlan $ operator $ operation x y)
  ternary :: (FromJSON x, FromJSON y, FromJSON z, ToJSON a) => Value -> (x -> y -> z -> OperatorOperation a) -> Parser ControlPlan
  ternary args operation = do
    (x,y,z) <- parseJSON args
    pure (ControlPlan $ operator $ operation x y z)

runControl :: Config -> (forall a. Plan a -> IO a) -> IO ()
runControl cfg evaluate = withUnixListener (adminSocket cfg) 0o600 $ \listener -> forever $
  bracket (fst <$> S.accept listener) S.close $ \socket -> do
    -- One bounded request per connection. The owning local user is the authority.
    _ <- timeout 20000000 $ do
      reply <- (do
        bytes <- receive 16384 socket
        value <- either (const $ reject "invalid_operator_request") pure (eitherDecodeStrict' bytes)
        ControlPlan plan <- either (const $ reject "invalid_operator_operation") pure (parseEither controlPlan value)
        toJSON <$> evaluate plan) `catch` (\(BridgeError code) -> pure $ object ["error" .= code])
      send 524288 socket (L.toStrict $ encode reply)
    pure ()
  `catch` (\(_ :: IOException) -> pure ())

callControl :: Config -> Value -> IO Value
callControl cfg command = bracket (S.socket S.AF_UNIX S.Stream S.defaultProtocol) S.close $ \socket -> do
  result <- timeout 20000000 $ do
    S.connect socket (S.SockAddrUnix $ adminSocket cfg)
    send 16384 socket (L.toStrict $ encode command)
    reply <- receive 524288 socket
    either (const $ reject "invalid_operator_reply") pure (eitherDecodeStrict' reply)
  maybe (reject "operator_outcome_unknown") pure result

send :: Int -> S.Socket -> B.ByteString -> IO ()
send limit socket bytes = do
  require (B.length bytes <= limit) "operator_message_too_large"
  S.sendAll socket (L.toStrict (runPut $ putWord32be $ fromIntegral $ B.length bytes) <> bytes)

receive :: Int -> S.Socket -> IO B.ByteString
receive limit socket = do
  header <- exactly 4 []
  let size = toInteger $ runGet getWord32be $ L.fromStrict header
  require (size > 0 && size <= toInteger limit) "operator_message_too_large"
  exactly (fromInteger size) []
 where
  exactly 0 chunks = pure (B.concat $ reverse chunks)
  exactly n chunks = do
    bytes <- S.recv socket n
    require (not $ B.null bytes) "operator_connection_closed"
    exactly (n - B.length bytes) (bytes:chunks)
