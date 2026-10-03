{-# LANGUAGE DeriveAnyClass, DerivingStrategies #-}
-- Existing customer wire contract; validated money comes only from Domain.
module Bridge.Wire where
import Bridge.Domain (Amount, Asset(..), Direction, Quote, amount, units)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import qualified Data.Text as T
import Text.Read (readMaybe)
import Data.Char (toLower)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)

data OrderRequest = OrderRequest
  { direction :: !Direction, input :: !Amount, recipient :: !Text
  , refund :: !Text, sourceOwner :: !(Maybe Text), idempotencyKey :: !Text
  } deriving stock (Eq, Show, Generic) deriving anyclass (ToJSON)
instance FromJSON OrderRequest where parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }
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

data CostLimits = CostLimits
  { savedNativeFee :: !Amount, savedSolanaFee :: !Amount, savedSolanaRent :: !Amount }
  deriving (Eq,Show)

-- Immutable execution terms shared by customer payouts and earned-fee funding.
-- The fee-funding JSON layout is retained exactly for existing reservations.
data PaymentTerms = PaymentTerms
  { paymentPolicy :: !PolicySnapshot, paymentLimits :: !CostLimits }
  deriving (Eq,Show)
instance ToJSON PaymentTerms where
  toJSON (PaymentTerms policy limits) = object
    ["fingerprint" .= deploymentFingerprint policy,"policy" .= policy,
     "nativeFee" .= savedNativeFee limits,"solanaFee" .= savedSolanaFee limits,
     "solanaRent" .= savedSolanaRent limits]
instance FromJSON PaymentTerms where
  parseJSON = withObject "payment terms" $ \o->do
    identity <- o .: "fingerprint"
    policy <- o .: "policy"
    if identity/=deploymentFingerprint policy then fail "payment_profile_mismatch" else
      PaymentTerms policy <$> (CostLimits <$> o .: "nativeFee" <*> o .: "solanaFee" <*> o .: "solanaRent")

-- Observation evidence is data, not permission to execute a chain or ledger action.
data Deposit = Deposit
  { depositId :: !Text, depositOrder :: !(Maybe Text), depositAsset :: !Asset
  , depositAmount :: !Amount, depositAnchor :: !Text, depositConfirmations :: !Int
  , depositEligible :: !Bool, depositSeenAt :: !Int64 } deriving (Eq,Show)
data SourceCheck = SourcePending Value | SourceMissing Value | SourceRestored Value | SourceUnavailable Value
  deriving (Eq,Show)

data ChainEvent = ChainEvent
  { chainEventId :: !Text, chainEventKind :: !Text, chainEventAnchor :: !Text
  , chainEventEvidence :: !Value } deriving (Eq,Show)
data ScanBatch = ScanBatch
  { scanChain :: !Text, scanOrigin :: !Text, scanPrevious :: !(Maybe Text)
  , scanNext :: !Text, scanTime :: !Int64, scanDeposits :: ![Deposit]
  , scanEvents :: ![ChainEvent] } deriving (Eq,Show)

-- Canonical economic approval identity, independent of provider metadata noise.
economicOutflow :: Text -> Value -> Either Text (Asset,Amount,Amount)
economicOutflow stream = either (const $ Left "invalid_treasury_outflow") Right . parseEither parseFlow
 where
  property key = withObject "economic evidence" (.: key)
  signed value = do
    text <- parseJSON value :: Parser Text
    if T.length text>21 then fail "invalid signed units" else
      case readMaybe (T.unpack text) of
        Just n | T.pack(show (n::Integer))==text -> pure n
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
    if delta<0 && negate delta>=toInteger (units fee) then do
      outflow <- quantity (negate delta)
      pure (asset,outflow,fee)
    else fail "invalid outgoing value"

-- Signatures are evidence, not authority to broadcast. The worker independently
-- validates this reply against its durable preparation before storing it.
data SignedAttempt = SignedAttempt
  { signedId :: Text, signedBytes :: Text, signedPolicy :: Text, commonInput :: Maybe Text }
  deriving stock (Eq,Show,Generic) deriving anyclass (ToJSON)
instance FromJSON SignedAttempt where
  parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }

data PaymentCosts = PaymentCosts { networkFee :: Amount, accountRent :: Amount }
  deriving stock (Eq,Show,Generic) deriving anyclass (ToJSON,FromJSON)

-- Immutable customer binding plus the latest saved receipt snapshot.
data PaymentSource = PaymentSource
  { sourceDeposit :: Deposit, sourceRequest :: OrderRequest
  , sourcePolicy :: PolicySnapshot, sourceInstruction :: Text } deriving (Eq,Show)
