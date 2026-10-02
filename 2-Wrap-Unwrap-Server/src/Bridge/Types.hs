{-# LANGUAGE DerivingStrategies #-}
module Bridge.Types
  ( Amount, amount, units, parseUnits, parseCoins, renderCoins, feeFor
  , Direction(..), Asset(..), sourceAsset, destinationAsset, feeBps
  , OrderRequest(..), Quote(..), makeQuote, PolicySnapshot(..), OrderView(..), Availability(..)
  , BridgeError(..), reject, require, digest, randomId, capabilityHash, validIdentifier
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.ByteArray.Encoding as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Hex
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import Text.Read (readMaybe)

newtype Amount = Amount { units :: Int64 } deriving stock (Eq, Ord, Show)
instance ToJSON Amount where toJSON = String . T.pack . show . units
instance FromJSON Amount where parseJSON = withText "integer base-unit string" (either (fail . T.unpack) pure . parseUnits)
amount :: Integer -> Either Text Amount
amount n | n >= 0 && n <= toInteger (maxBound :: Int64) = Right (Amount (fromInteger n))
         | otherwise = Left "amount_out_of_range"
parseUnits :: Text -> Either Text Amount
parseUnits t
  | T.null t || T.length t > 19 || not (T.all asciiDigit t) || (T.length t > 1 && T.head t == '0') = Left "invalid_base_units"
  | otherwise = maybe (Left "invalid_base_units") amount (readMaybe (T.unpack t))
asciiDigit :: Char -> Bool
asciiDigit c = c >= '0' && c <= '9'
parseCoins :: Text -> Either Text Amount
parseCoins t = case T.splitOn "." t of
  [whole] -> go whole ""
  [whole, fractional] | not (T.null fractional) -> go whole fractional
  _ -> Left "invalid_decimal"
 where
  go w f
    | T.null w || T.length w > 11 || (T.length w > 1 && T.head w == '0') || T.length f > 8 || not (T.all asciiDigit (w<>f)) = Left "invalid_decimal"
    | otherwise = maybe (Left "invalid_decimal") amount (readMaybe (T.unpack (w <> T.justifyLeft 8 '0' f)))
renderCoins :: Amount -> Text
renderCoins a = let (w,f) = units a `divMod` 100000000 in T.pack (show w) <> "." <> T.justifyRight 8 '0' (T.pack (show f))
feeFor :: Integer -> Amount -> Either Text Amount
feeFor b a | b < 0 || b > 10000 = Left "invalid_fee"
           | otherwise = amount ((toInteger (units a)*b+9999) `div` 10000)
data Direction = NativeToWrapped | WrappedToNative deriving stock (Eq, Show, Read, Generic) deriving anyclass (ToJSON, FromJSON)
data Asset = Native | Wrapped | Sol deriving stock (Eq, Ord, Show, Read, Generic) deriving anyclass (ToJSON, FromJSON)
sourceAsset, destinationAsset :: Direction -> Asset
sourceAsset NativeToWrapped = Native
sourceAsset WrappedToNative = Wrapped
destinationAsset NativeToWrapped = Wrapped
destinationAsset WrappedToNative = Native
feeBps :: Direction -> Integer
feeBps NativeToWrapped = 20
feeBps WrappedToNative = 100

data OrderRequest = OrderRequest
  { direction :: !Direction, input :: !Amount, recipient :: !Text
  , refund :: !Text, sourceOwner :: !(Maybe Text), idempotencyKey :: !Text
  } deriving stock (Eq, Show, Generic) deriving anyclass (ToJSON)
instance FromJSON OrderRequest where parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }
data Quote = Quote { gross :: !Amount, fee :: !Amount, net :: !Amount }
  deriving stock (Eq, Show, Generic) deriving anyclass (ToJSON, FromJSON)
makeQuote :: Direction -> Amount -> Either Text Quote
makeQuote d a = do
  f <- feeFor (feeBps d) a
  n <- amount (toInteger (units a) - toInteger (units f))
  if units n <= 0 then Left "nonpositive_net" else Right (Quote a f n)
data PolicySnapshot = PolicySnapshot { nativeDepth :: !Int, solanaCommitment :: !Text, deploymentFingerprint :: !Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (ToJSON, FromJSON)
data OrderView = OrderView
  { orderId :: !Text, request :: !OrderRequest, quote :: !Quote, status :: !Text
  , deadline :: !Int64, depositInstruction :: !(Maybe Text), payoutTx :: !(Maybe Text), policy :: !PolicySnapshot
  } deriving stock (Eq, Show, Generic) deriving anyclass (ToJSON, FromJSON)
data Availability = Availability { available :: !Bool, reason :: !Text }
  deriving stock (Eq, Show, Generic) deriving anyclass (ToJSON, FromJSON)
data BridgeError = BridgeError !Text deriving stock (Eq, Show)
instance Exception BridgeError
reject :: Text -> IO a
reject = throwIO . BridgeError
require :: Bool -> Text -> IO ()
require b msg = unless b (reject msg)
digest :: BS.ByteString -> Text
digest b = TE.decodeUtf8 (BA.convertToBase BA.Base16 (hash b :: Digest SHA256))
randomId :: IO Text
randomId = TE.decodeUtf8 . Hex.encode <$> (getRandomBytes 32 :: IO BS.ByteString)
capabilityHash :: Text -> Either Text Text
capabilityHash t
  | T.length t == 64 && T.all (\c -> asciiDigit c || c >= 'a' && c <= 'f') t = Right (digest (TE.encodeUtf8 ("ecx-capability-v1:" <> t)))
  | otherwise = Left "invalid_capability"
validIdentifier :: Text -> Bool
validIdentifier t = not (T.null t) && T.length t <= 64 && T.all (\c -> asciiDigit c || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '-' || c == '_') t
