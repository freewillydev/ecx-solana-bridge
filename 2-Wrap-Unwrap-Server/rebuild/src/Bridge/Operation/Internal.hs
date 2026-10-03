{-# LANGUAGE DataKinds, FunctionalDependencies, RoleAnnotations, TypeFamilies #-}
-- Grammar only. Neither requests nor DSL values contain executable IO.
module Bridge.Operation.Internal where

import Data.Aeson (ToJSON,FromJSON(..),genericParseJSON,defaultOptions,Options(..))
import GHC.Generics (Generic)
import Bridge.Domain (Asset,Amount)
import Bridge.Wire
import Data.Kind (Type)
import Data.Text (Text)
import Data.Int (Int64)

data Severity = Safe | Critical
data Caller = Customer | Signer | Worker | Operator

-- Caller and severity belong to the operation, not to the caller's choice.
class Operation (caller :: Caller) (severity :: Severity) (op :: Type -> Type)
    | op -> caller severity where
  command :: op a -> DSL caller severity a

data CustomerRead a where
  PublicConfig :: CustomerRead PublicConfiguration
  OrderStatus :: Text -> Text -> CustomerRead OrderView
  PaymentInstructions :: Text -> Text -> CustomerRead PaymentInstruction

data CustomerWrite a where
  CreateOrder :: Text -> OrderRequest -> CustomerWrite OrderView

data OperatorRead a where
  NativeReviews :: OperatorRead [(Text,Text,Int64)]
  ServiceState :: OperatorRead ServiceStatus

data OperatorWrite a where
  RepairCompletedOrder :: Text -> OperatorWrite ()
  RebroadcastNative :: Text -> Int64 -> Text -> OperatorWrite Text
  DraftNativeReplacement :: Text -> Amount -> Text -> OperatorWrite Int64
  SignNativeReplacement :: Int64 -> OperatorWrite Text
  CancelNativeReplacement :: Int64 -> Text -> OperatorWrite ()
  CoverLostSource :: Text -> Int64 -> Amount -> Amount -> Text -> OperatorWrite ()
  ApproveCovered :: Text -> Int64 -> Text -> OperatorWrite ()
  RestoreSource :: Text -> Int64 -> Text -> OperatorWrite ()
  ClassifySpend :: Text -> Text -> Text -> OperatorWrite Int64
  AllocateReceipt :: Text -> [(Text,Amount)] -> Text -> OperatorWrite Int64
  WithdrawFees :: Text -> Asset -> Amount -> Text -> Text -> OperatorWrite Text
  CancelFeeWithdrawal :: Text -> Text -> OperatorWrite Text
  RetrySolanaPayment :: Text -> Text -> OperatorWrite ()
  CancelPreparation :: Text -> Int -> Text -> OperatorWrite ()
  RefundDeposit :: Text -> OperatorWrite RefundAuthorization
  PauseService :: Text -> OperatorWrite ()
  ResumeService :: OperatorWrite ()

-- Data families are generative and injective in BOTH indices. No type-family
-- injectivity annotation is needed. Each instance has its own output constructor.
data family Result (severity :: Severity) (op :: Type -> Type)
type PreparedResult = Result 'Critical SignPrepared
data instance Result 'Critical SignPrepared = PreparedResult { preparedOutput :: !SignedAttempt } deriving (Eq,Show,Generic)
instance ToJSON PreparedResult
instance FromJSON PreparedResult where
  parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }
type ReplacementResult = Result 'Critical SignReplacement
data instance Result 'Critical SignReplacement = ReplacementResult { replacementOutput :: !SignedAttempt } deriving (Eq,Show,Generic)
instance ToJSON ReplacementResult
instance FromJSON ReplacementResult where
  parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }
type DraftResult = Result 'Critical DraftReplacement
data instance Result 'Critical DraftReplacement = DraftResult { draftOutput :: !NativeDraft } deriving (Eq,Show,Generic)
instance ToJSON DraftResult
instance FromJSON DraftResult where
  parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }
type CheckpointResult = Result 'Critical CheckpointCustody
data instance Result 'Critical CheckpointCustody = CheckpointResult { checkpointOutput :: !BackupReceipt } deriving (Eq,Show,Generic)
instance ToJSON CheckpointResult
instance FromJSON CheckpointResult where
  parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }

-- Initial signing is tied to a durable decision, never caller-supplied bytes.
data CheckpointCustody a where
  CheckpointCustody :: Text -> Int64 -> CheckpointCustody CheckpointResult
data DraftReplacement a where
  DraftReplacement :: Text -> Text -> Amount -> DraftReplacement DraftResult
data SignReplacement a where
  SignReplacement :: Text -> Int64 -> SignReplacement ReplacementResult
data SignPrepared a where
  SignPrepared :: Text -> Text -> Int -> SignPrepared PreparedResult

-- Closed signer instruction set, populated by the Operation.command instances.
data SigningOperation a where
  PreparedSigning :: SignPrepared a -> SigningOperation a
  ReplacementSigning :: SignReplacement a -> SigningOperation a
  DraftSigning :: DraftReplacement a -> SigningOperation a
  CheckpointSigning :: CheckpointCustody a -> SigningOperation a

data WorkerOperation a where
  CheckpointBackup :: Int64 -> WorkerOperation ()
  RecoverNativeSettlements :: WorkerOperation ()
  RecoverNativeSources :: WorkerOperation ()
  RecoverNativeLocks :: WorkerOperation ()
  RunWorkerCycle :: WorkerOperation ()
  ObserveChains :: WorkerOperation ()
  PrepareOutgoing :: Text -> WorkerOperation ()
  ReconcileCustody :: WorkerOperation ()
  SignPreparedPayment :: Text -> WorkerOperation Text
  ReconcilePayment :: Text -> WorkerOperation ()
  QueuePayment :: Text -> WorkerOperation Int64
  BroadcastPayment :: Text -> WorkerOperation ()

data DSL (caller :: Caller) (severity :: Severity) a where
  ReadOperator :: OperatorRead a -> DSL 'Operator 'Safe a
  OperatorDSL :: OperatorWrite a -> DSL 'Operator 'Critical a
  WorkerDSL :: WorkerOperation a -> DSL 'Worker 'Critical a
  SigningDSL :: SigningOperation a -> DSL 'Signer 'Critical a
  ReadCustomer :: CustomerRead a -> DSL 'Customer 'Safe a
  WriteCustomer :: CustomerWrite a -> DSL 'Customer 'Critical a

instance Operation 'Operator 'Safe OperatorRead where command = ReadOperator
instance Operation 'Operator 'Critical OperatorWrite where command = OperatorDSL
instance Operation 'Worker 'Critical WorkerOperation where command = WorkerDSL
instance Operation 'Signer 'Critical SignPrepared where command = SigningDSL . PreparedSigning
instance Operation 'Signer 'Critical SignReplacement where command = SigningDSL . ReplacementSigning
instance Operation 'Signer 'Critical DraftReplacement where command = SigningDSL . DraftSigning
instance Operation 'Signer 'Critical CheckpointCustody where command = SigningDSL . CheckpointSigning
instance Operation 'Customer 'Safe CustomerRead where command = ReadCustomer
instance Operation 'Customer 'Critical CustomerWrite where command = WriteCustomer

-- A signer input fixes a to Result severity op before op is existentially hidden.
-- Packaging preserves that result identity; no IO or runtime cast enters Request.
data Request (caller :: Caller) (severity :: Severity) a where
  Request :: Operation caller severity op => op a -> Request caller severity a

type role Request nominal nominal nominal
resolve :: Request caller severity a -> DSL caller severity a
resolve (Request op) = command op

-- Retain caller identity through dispatch; a critical customer operation cannot
-- be substituted with a critical operator or signer operation as grammar grows.
data Plan (caller :: Caller) a where
  SafePlan :: Request caller 'Safe a -> Plan caller a
  CriticalPlan :: Request caller 'Critical a -> Plan caller a

type role Plan nominal nominal
safe :: CustomerRead a -> Plan 'Customer a
safe = SafePlan . Request
customer :: CustomerWrite a -> Plan 'Customer a
customer = CriticalPlan . Request

operator :: OperatorWrite a -> Plan 'Operator a
operator=CriticalPlan . Request
operatorRead :: OperatorRead a -> Plan 'Operator a
operatorRead=SafePlan . Request
