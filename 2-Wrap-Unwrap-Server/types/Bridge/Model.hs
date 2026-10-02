{-# LANGUAGE DerivingStrategies, DeriveGeneric, DeriveAnyClass, OverloadedStrings #-}
-- Shared server/browser contract. Pure values only: no RPC, keys or database IO.
module Bridge.Model where

import Data.Aeson
import Data.Char (toLower)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
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
feeBps _ = 100

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
data Profile = L2LSignetDevnet | ECXBetanetDevnet | CanonicalBeta deriving (Eq, Show, Generic, ToJSON, FromJSON)

data InterfaceConfig = InterfaceConfig
  { supportUrl :: !(Maybe Text), jupiterUrl :: !(Maybe Text)
  , orcaUrl :: !(Maybe Text), nativeExplorerBase :: !(Maybe Text)
  , publicOrigin :: !(Maybe Text)
  } deriving (Eq,Show,Generic,ToJSON)
instance FromJSON InterfaceConfig where
  parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }


-- Result records are wire data. They never contain a DSL or execution authority.
data PublicConfiguration = PublicConfiguration
  { pubProfile :: !Profile, pubSolanaCluster :: !Text, pubLinks :: !InterfaceConfig
  , pubDeployment :: !Text, pubMint :: !Text, pubCustodyOwner :: !Text
  , pubDecimals :: !Int, pubMinInput :: !Amount, pubMaxInput :: !Amount
  , pubFeesBps :: !(Map Text Int), pubIntakeEnabled :: !Bool
  , pubImplementationReady :: !Bool, pubAvailability :: !Availability
  } deriving (Eq, Show, Generic)

publicJSON :: Options
publicJSON = defaultOptions { fieldLabelModifier = \field -> case drop 3 field of
  first:rest -> toLower first:rest
  [] -> [] }
instance ToJSON PublicConfiguration where toJSON = genericToJSON publicJSON
instance FromJSON PublicConfiguration where parseJSON = genericParseJSON publicJSON

data PaymentInstruction = PaymentInstruction
  { instructionUri :: !Text, instructionReference :: !Text, instructionMint :: !Text
  , instructionAmount :: !Amount, instructionRefundPolicy :: !Text
  } deriving (Eq, Show, Generic)
instance ToJSON PaymentInstruction where toJSON = genericToJSON instructionJSON
instance FromJSON PaymentInstruction where parseJSON = genericParseJSON instructionJSON
instructionJSON :: Options
instructionJSON = defaultOptions {fieldLabelModifier = \field -> case drop 11 field of
  first:rest -> toLower first:rest
  [] -> []}
