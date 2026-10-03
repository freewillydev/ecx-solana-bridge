{-# LANGUAGE DataKinds, FunctionalDependencies, RoleAnnotations, TypeFamilies, PatternSynonyms, ViewPatterns, RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
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

-- All four callers have exactly one operation family. Severity is an index of
-- that family's GADT, so a caller can have safe and critical instructions without
-- inventing another class argument. Both dependencies reject new family instances.
class Operation (caller :: Caller) (severity :: Severity) (op :: Severity -> Type -> Type)
    | caller -> op, op -> caller where
  command :: op severity a -> DSL caller severity a
  interpretOperation :: Handlers severity f -> op severity a -> f a

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

-- These closed families are the only Operation instances. Their constructors
-- retain the precise severity and leaf result, including Result 'Critical op.
data CustomerCommand severity a where
  CustomerQuery :: CustomerRead a -> CustomerCommand 'Safe a
  CustomerChange :: CustomerWrite a -> CustomerCommand 'Critical a
data OperatorCommand severity a where
  OperatorQuery :: OperatorRead a -> OperatorCommand 'Safe a
  OperatorChange :: OperatorWrite a -> OperatorCommand 'Critical a
data WorkerCommand severity a where
  WorkerAction :: WorkerOperation a -> WorkerCommand 'Critical a
data SignerCommand severity a where
  SignerAction :: SigningOperation a -> SignerCommand 'Critical a

-- Each constructor stores the SAME filled-in class context as its Request.
-- Caller/severity cannot be weakened when command constructs the DSL.
data DSL (caller :: Caller) (severity :: Severity) a where
  ReadOperator :: Operation 'Operator 'Safe OperatorCommand => OperatorRead a -> DSL 'Operator 'Safe a
  OperatorDSL :: Operation 'Operator 'Critical OperatorCommand => OperatorWrite a -> DSL 'Operator 'Critical a
  WorkerDSL :: Operation 'Worker 'Critical WorkerCommand => WorkerOperation a -> DSL 'Worker 'Critical a
  SigningDSL :: Operation 'Signer 'Critical SignerCommand => SigningOperation a -> DSL 'Signer 'Critical a
  ReadCustomer :: Operation 'Customer 'Safe CustomerCommand => CustomerRead a -> DSL 'Customer 'Safe a
  WriteCustomer :: Operation 'Customer 'Critical CustomerCommand => CustomerWrite a -> DSL 'Customer 'Critical a

-- Runtime supplies this closed interpreter algebra. Operations select a handler;
-- they cannot manufacture effects (f has no Monad/IO constraint). Safe handlers
-- contain no critical capabilities. Neither requests nor DSL values carry these.
data Handlers (severity :: Severity) (f :: Type -> Type) where
  SafeHandlers :: (forall a. CustomerRead a -> f a)
    -> (forall a. OperatorRead a -> f a) -> Handlers 'Safe f
  CriticalHandlers :: (forall a. CustomerWrite a -> f a)
    -> (forall a. OperatorWrite a -> f a) -> (forall a. WorkerOperation a -> f a)
    -> (forall a. SigningOperation a -> f a) -> Handlers 'Critical f

-- Ground heads also prevent an OVERLAPPING specialization replacing a handler.
instance Operation 'Customer 'Safe CustomerCommand where
  command (CustomerQuery op) = ReadCustomer op
  interpretOperation (SafeHandlers run _) (CustomerQuery op) = run op
instance Operation 'Customer 'Critical CustomerCommand where
  command (CustomerChange op) = WriteCustomer op
  interpretOperation (CriticalHandlers run _ _ _) (CustomerChange op) = run op
instance Operation 'Operator 'Safe OperatorCommand where
  command (OperatorQuery op) = ReadOperator op
  interpretOperation (SafeHandlers _ run) (OperatorQuery op) = run op
instance Operation 'Operator 'Critical OperatorCommand where
  command (OperatorChange op) = OperatorDSL op
  interpretOperation (CriticalHandlers _ run _ _) (OperatorChange op) = run op
instance Operation 'Worker 'Critical WorkerCommand where
  command (WorkerAction op) = WorkerDSL op
  interpretOperation (CriticalHandlers _ _ run _) (WorkerAction op) = run op
instance Operation 'Signer 'Critical SignerCommand where
  command (SignerAction op) = SigningDSL op
  interpretOperation (CriticalHandlers _ _ _ run) (SignerAction op) = run op

-- The existential hides the caller's family (e.g. SignerCommand). Its result a
-- still retains the leaf's Result indices (e.g. Result 'Critical SignPrepared).
data Request (caller :: Caller) (severity :: Severity) a where
  Request :: Operation caller severity op => op severity a -> Request caller severity a

type role Request nominal nominal nominal
resolve :: Request caller severity a -> DSL caller severity a
resolve (Request op) = command op

-- A matching-only view recovers dictionaries from the CLOSED DSL constructors.
-- It cannot package an arbitrary Operation instance into an executable DSL.
-- Always resolve a Request first; interpreting its original dictionary directly
-- would bypass this closed vocabulary.
pattern Instruction :: forall caller severity a. ()
  => forall op. Operation caller severity op => op severity a -> DSL caller severity a
pattern Instruction op <- (instruction -> Request op)
{-# COMPLETE Instruction #-}

instruction :: DSL caller severity a -> Request caller severity a
instruction (ReadOperator op) = Request (OperatorQuery op)
instruction (OperatorDSL op) = Request (OperatorChange op)
instruction (WorkerDSL op) = Request (WorkerAction op)
instruction (ReadCustomer op) = Request (CustomerQuery op)
instruction (WriteCustomer op) = Request (CustomerChange op)
instruction (SigningDSL op) = Request (SignerAction op)

-- Retain caller identity through dispatch; a critical customer operation cannot
-- be substituted with a critical operator or signer operation as grammar grows.
data Plan (caller :: Caller) a where
  SafePlan :: Request caller 'Safe a -> Plan caller a
  CriticalPlan :: Request caller 'Critical a -> Plan caller a

type role Plan nominal nominal
safe :: CustomerRead a -> Plan 'Customer a
safe = SafePlan . Request . CustomerQuery
customer :: CustomerWrite a -> Plan 'Customer a
customer = CriticalPlan . Request . CustomerChange

operator :: OperatorWrite a -> Plan 'Operator a
operator=CriticalPlan . Request . OperatorChange
operatorRead :: OperatorRead a -> Plan 'Operator a
operatorRead=SafePlan . Request . OperatorQuery

workerRequest :: WorkerOperation a -> Request 'Worker 'Critical a
workerRequest = Request . WorkerAction
