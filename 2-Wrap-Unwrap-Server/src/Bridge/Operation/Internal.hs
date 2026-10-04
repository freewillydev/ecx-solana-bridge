{-# LANGUAGE DataKinds, FunctionalDependencies, RoleAnnotations, TypeFamilies, TypeFamilyDependencies, ConstraintKinds, UndecidableSuperClasses, TypeApplications, ScopedTypeVariables, PatternSynonyms, ViewPatterns, RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Grammar only. Neither requests nor DSL values contain executable IO.
module Bridge.Operation.Internal where

import Data.Aeson (ToJSON,FromJSON(..),genericParseJSON,defaultOptions,Options(..))
import GHC.Generics (Generic)
import Bridge.Domain (Asset,Amount)
import Bridge.Wire
import Data.Kind (Constraint,Type)
import Data.Typeable (Typeable,eqT)
import Data.Type.Equality ((:~:)(Refl))
import Data.Text (Text)
import Data.Int (Int64)

data Severity = Safe | Critical
data Caller = Customer | Signer | Worker | Operator

-- All four callers have exactly one operation family. Severity is an index of
-- that family's GADT, so a caller can have safe and critical instructions without
-- inventing another class argument. Both dependencies reject new family instances.
data Dictionary (constraint :: Constraint) where
  Dictionary :: constraint => Dictionary constraint

class Typeable (OperationContext caller severity op)
    => Operation (caller :: Caller) (severity :: Severity) (op :: Severity -> Type -> Type)
    | caller -> op, op -> caller where
  type OperationContext caller severity op = (context :: Constraint) | context -> caller severity op
  operationDictionary :: Dictionary (OperationContext caller severity op)
  command :: op severity a -> DSL caller severity a
  interpretOperation :: Dictionary (OperationContext caller severity op)
    -> DSL caller severity a -> Either Text (DSL caller severity a)

-- Concrete workflow instances own private resource contexts. Requests cannot
-- supply executable callbacks or obtain an interpreter's environment.
class Interpreter environment (program :: Type -> Type) where
  execute :: environment -> program a -> IO a

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
  ReadOperator :: OperationContext 'Operator 'Safe OperatorCommand => OperatorRead a -> DSL 'Operator 'Safe a
  OperatorDSL :: OperationContext 'Operator 'Critical OperatorCommand => OperatorWrite a -> DSL 'Operator 'Critical a
  WorkerDSL :: OperationContext 'Worker 'Critical WorkerCommand => WorkerOperation a -> DSL 'Worker 'Critical a
  SigningDSL :: OperationContext 'Signer 'Critical SignerCommand => SigningOperation a -> DSL 'Signer 'Critical a
  ReadCustomer :: OperationContext 'Customer 'Safe CustomerCommand => CustomerRead a -> DSL 'Customer 'Safe a
  WriteCustomer :: OperationContext 'Customer 'Critical CustomerCommand => CustomerWrite a -> DSL 'Customer 'Critical a

-- Ground heads also prevent an OVERLAPPING specialization replacing a handler.
instance Operation 'Customer 'Safe CustomerCommand where
  type OperationContext 'Customer 'Safe CustomerCommand = Operation 'Customer 'Safe CustomerCommand
  operationDictionary = Dictionary
  command (CustomerQuery op) = ReadCustomer op
  interpretOperation Dictionary dsl@(Instruction (_ :: actual 'Safe a)) =
    case eqT @(OperationContext 'Customer 'Safe CustomerCommand) @(OperationContext 'Customer 'Safe actual) of
      Just Refl -> Right dsl
      Nothing -> Left "operation_dictionary_mismatch"
instance Operation 'Customer 'Critical CustomerCommand where
  type OperationContext 'Customer 'Critical CustomerCommand = Operation 'Customer 'Critical CustomerCommand
  operationDictionary = Dictionary
  command (CustomerChange op) = WriteCustomer op
  interpretOperation Dictionary dsl@(Instruction (_ :: actual 'Critical a)) =
    case eqT @(OperationContext 'Customer 'Critical CustomerCommand) @(OperationContext 'Customer 'Critical actual) of
      Just Refl -> Right dsl
      Nothing -> Left "operation_dictionary_mismatch"
instance Operation 'Operator 'Safe OperatorCommand where
  type OperationContext 'Operator 'Safe OperatorCommand = Operation 'Operator 'Safe OperatorCommand
  operationDictionary = Dictionary
  command (OperatorQuery op) = ReadOperator op
  interpretOperation Dictionary dsl@(Instruction (_ :: actual 'Safe a)) =
    case eqT @(OperationContext 'Operator 'Safe OperatorCommand) @(OperationContext 'Operator 'Safe actual) of
      Just Refl -> Right dsl
      Nothing -> Left "operation_dictionary_mismatch"
instance Operation 'Operator 'Critical OperatorCommand where
  type OperationContext 'Operator 'Critical OperatorCommand = Operation 'Operator 'Critical OperatorCommand
  operationDictionary = Dictionary
  command (OperatorChange op) = OperatorDSL op
  interpretOperation Dictionary dsl@(Instruction (_ :: actual 'Critical a)) =
    case eqT @(OperationContext 'Operator 'Critical OperatorCommand) @(OperationContext 'Operator 'Critical actual) of
      Just Refl -> Right dsl
      Nothing -> Left "operation_dictionary_mismatch"
instance Operation 'Worker 'Critical WorkerCommand where
  type OperationContext 'Worker 'Critical WorkerCommand = Operation 'Worker 'Critical WorkerCommand
  operationDictionary = Dictionary
  command (WorkerAction op) = WorkerDSL op
  interpretOperation Dictionary dsl@(Instruction (_ :: actual 'Critical a)) =
    case eqT @(OperationContext 'Worker 'Critical WorkerCommand) @(OperationContext 'Worker 'Critical actual) of
      Just Refl -> Right dsl
      Nothing -> Left "operation_dictionary_mismatch"
instance Operation 'Signer 'Critical SignerCommand where
  type OperationContext 'Signer 'Critical SignerCommand = Operation 'Signer 'Critical SignerCommand
  operationDictionary = Dictionary
  command (SignerAction op) = SigningDSL op
  interpretOperation Dictionary dsl@(Instruction (_ :: actual 'Critical a)) =
    case eqT @(OperationContext 'Signer 'Critical SignerCommand) @(OperationContext 'Signer 'Critical actual) of
      Just Refl -> Right dsl
      Nothing -> Left "operation_dictionary_mismatch"

-- The existential hides the caller's family (e.g. SignerCommand). Its result a
-- still retains the leaf's Result indices (e.g. Result 'Critical SignPrepared).
data Request (caller :: Caller) (severity :: Severity) a where
  Request :: Operation caller severity op => op severity a -> Request caller severity a

type role Request nominal nominal nominal
resolve :: Request caller severity a -> DSL caller severity a
resolve (Request op) = command op

-- Keep the request's dictionary witness until the DSL recovers its own. This
-- proves instance-type alignment, not equality of dictionary values or payloads;
-- coherent ground instances and deriving the DSL here remain essential.
checkedRequest :: forall caller severity a. Request caller severity a -> Either Text (DSL caller severity a)
checkedRequest (Request (op :: requested severity a)) =
  interpretOperation (operationDictionary @caller @severity @requested) (command op)

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
