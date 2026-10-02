-- Shared economic records and evidence decoding; no database capability.
module Bridge.Ledger.Model
  ( CostLimits(..), Deposit(..), ChainEvent(..), ScanBatch(..), SourceCheck(..)
  , LossCapital(..), Obligation(..), Attempt(..), Preparation(..), PaymentCosts(..)
  , NativeSettlementCheck(..), economicOutflow
  ) where

import Bridge.Types
import Data.Aeson
import Data.Aeson.Types (parseEither,Parser)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Text.Read (readMaybe)

data CostLimits = CostLimits
  { savedNativeFee :: !Amount, savedSolanaFee :: !Amount, savedSolanaRent :: !Amount }
  deriving (Eq,Show)

data Deposit = Deposit { depositId :: !Text, depositOrder :: !(Maybe Text), depositAsset :: !Asset, depositAmount :: !Amount, depositAnchor :: !Text, depositConfirmations :: !Int, depositEligible :: !Bool, depositSeenAt :: !Int64 } deriving (Eq,Show)

data ChainEvent = ChainEvent
  { chainEventId :: !Text, chainEventKind :: !Text, chainEventAnchor :: !Text
  , chainEventEvidence :: !Value
  } deriving (Eq,Show)

data ScanBatch = ScanBatch
  { scanChain :: !Text, scanOrigin :: !Text, scanPrevious :: !(Maybe Text)
  , scanNext :: !Text, scanTime :: !Int64, scanDeposits :: ![Deposit]
  , scanEvents :: ![ChainEvent]
  } deriving (Eq,Show)

data SourceCheck = SourcePending Value | SourceMissing Value | SourceRestored Value | SourceUnavailable Value
  deriving (Eq,Show)

data LossCapital = LossCapital { lossFloat :: !Amount, lossEarned :: !Amount }
  deriving (Eq,Show,Generic,ToJSON,FromJSON)

data Obligation = Obligation { obligationId :: !Text, obligationOrder :: !Text, obligationDeposit :: !Text, obligationKind :: !Text, obligationAsset :: !Text, obligationAmount :: !Int64, obligationRecipient :: !Text } deriving (Eq,Show)

data Attempt = Attempt { attemptId :: !Text, attemptIntent :: !Text, attemptChain :: !Text, attemptBytes :: !Text, attemptPolicy :: !Text, attemptFeeLimit :: !Int64, attemptState :: !Text, attemptSequence :: !(Maybe Int64) } deriving (Eq,Show)

data Preparation = Preparation
  { preparationObligation :: !Obligation, preparationChain :: !Text
  , preparationFeeLimit :: !Int64, preparationPolicy :: !Text
  , preparationDraft :: !(Maybe Text), preparationGeneration :: !Int
  } deriving (Eq,Show)

data PaymentCosts = PaymentCosts { networkFee :: !Amount, accountRent :: !Amount }
  deriving (Eq,Show,Generic,ToJSON,FromJSON)

data NativeSettlementCheck
  = NativeSettlementConfirming
  | NativeSettlementUnavailable Text
  | NativeSettlementReconfirmed PaymentCosts Text
  | NativeSettlementReplaced [Attempt] Text PaymentCosts Text
  deriving (Eq,Show)

economicOutflow :: Text -> Value -> Either Text (Asset,Amount,Amount)
economicOutflow stream = either (const $ Left "invalid_treasury_outflow") Right . parseEither parseFlow
 where
  property key = withObject "economic evidence" (.: key)
  signed value = do
    text <- parseJSON value :: Parser Text
    case readMaybe (T.unpack text) of
      Just n | T.length text<=21 && T.pack(show (n::Integer))==text -> pure n
      _ -> fail "invalid signed units"
  quantity = either (fail . T.unpack) pure . amount
  parseFlow value = do
    (asset,delta,fee) <- case stream of
      "Native" -> do
        net <- property "walletNetUnits" value >>= signed
        fee <- property "feeUnits" value :: Parser Amount
        pure (Native,net-toInteger (units fee),fee)
      "Solana" -> do
        delta <- property "delta" value >>= signed
        zero <- quantity 0
        pure (Wrapped,delta,zero)
      "SolanaOperating" -> (,,) Sol <$> (property "delta" value >>= signed) <*> property "feeUnits" value
      _ -> fail "invalid observation stream"
    requireP (delta<0 && negate delta>=toInteger (units fee))
    outflow <- quantity (negate delta)
    pure (asset,outflow,fee)
  requireP ok=if ok then pure () else fail "invalid outgoing value"
