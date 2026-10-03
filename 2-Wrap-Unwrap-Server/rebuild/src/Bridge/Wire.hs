{-# LANGUAGE DeriveAnyClass, DerivingStrategies #-}
-- Existing customer wire contract; validated money comes only from Domain.
module Bridge.Wire where
import Bridge.Domain (Amount, Asset, Direction, Quote)
import Data.Aeson
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
