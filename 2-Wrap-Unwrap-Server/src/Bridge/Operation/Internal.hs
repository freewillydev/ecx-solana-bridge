{-# LANGUAGE FlexibleInstances, DataKinds, FunctionalDependencies, RoleAnnotations, TypeFamilies, TypeFamilyDependencies, ConstraintKinds, UndecidableSuperClasses, TypeApplications, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Closed grammar and evaluation contract. Operations carry data, never IO callbacks.
module Bridge.Operation.Internal where

import Data.Aeson (ToJSON,FromJSON(..),genericParseJSON,defaultOptions,Options(..))
import GHC.Generics (Generic)
import Bridge.Domain (Asset,Amount)
import Bridge.Wire
import Data.Kind (Type)
import Data.Typeable (Typeable,eqT)
import Data.Type.Equality ((:~:)(Refl))
import Control.Operation
import Data.Text (Text)
import Data.Int (Int64)

data Severity = Safe | Critical
data Caller = Customer | Signer | Worker | Operator

-- All four callers have exactly one operation family. Severity is an index of
-- that family's GADT, so a caller can have safe and critical instructions without
-- inventing another class argument. Both dependencies reject new family instances.
-- Concrete instances live beside the evaluators; constructors stay private there.
data family Evaluation (severity :: Severity)

-- Closed effect capability; the general operation/pipeline machinery is supplied
-- by operation-capabilities. No evaluation environment enters a pure pipeline.
class (Typeable caller,Typeable severity,Typeable op)
    => Execution (caller :: Caller) (severity :: Severity) (op :: Severity -> Type -> Type)
    | caller -> op, op -> caller where
  command :: Typeable a => op severity a -> Program caller severity a
  authorizeOperation :: Evaluation severity -> op severity a -> IO ()
  evaluateOperation :: Evaluation severity -> op severity a -> IO a

data CustomerRead a where
  PublicConfig :: CustomerRead PublicConfiguration
  OrderStatus :: Text -> Text -> CustomerRead OrderView
  PaymentInstructions :: Text -> Text -> CustomerRead PaymentInstruction

data CustomerWrite a where
  CreateOrder :: Text -> OrderRequest -> CustomerWrite OrderView

data OperatorRead a where
  NativeReviews :: OperatorRead [(Text,Text,Int64)]
  ServiceState :: OperatorRead ServiceStatus
  TreasuryReceipts :: OperatorRead [(Text,Asset,Amount)]

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

-- Closed signer instruction set, populated by the Execution.command instances.
data SigningOperation a where
  PreparedSigning :: SignPrepared a -> SigningOperation a
  ReplacementSigning :: SignReplacement a -> SigningOperation a
  DraftSigning :: DraftReplacement a -> SigningOperation a
  CheckpointSigning :: CheckpointCustody a -> SigningOperation a

data WorkerOperation a where
  CheckpointBackup :: Int64 -> WorkerOperation ()
  CheckpointForUpgrade :: WorkerOperation BackupReceipt
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

-- One closed payload GADT carries caller, severity and the exact result type.
-- Family aliases retain the evaluator's caller -> family functional dependency.
data Command (caller :: Caller) (severity :: Severity) a where
  CustomerQuery :: CustomerRead a -> Command 'Customer 'Safe a
  CustomerChange :: CustomerWrite a -> Command 'Customer 'Critical a
  OperatorQuery :: OperatorRead a -> Command 'Operator 'Safe a
  OperatorChange :: OperatorWrite a -> Command 'Operator 'Critical a
  WorkerAction :: WorkerOperation a -> Command 'Worker 'Critical a
  SignerAction :: SigningOperation a -> Command 'Signer 'Critical a

type CustomerCommand = Command 'Customer
type OperatorCommand = Command 'Operator
type WorkerCommand = Command 'Worker
type SignerCommand = Command 'Signer

-- Each constructor stores the same closed execution capability as its operation.
-- Caller/severity cannot be weakened when command constructs the DSL.
data Program (caller :: Caller) (severity :: Severity) a where
  ReadOperator :: (Typeable a, Execution 'Operator 'Safe OperatorCommand) => OperatorRead a -> Program 'Operator 'Safe a
  OperatorDSL :: (Typeable a, Execution 'Operator 'Critical OperatorCommand) => OperatorWrite a -> Program 'Operator 'Critical a
  WorkerDSL :: (Typeable a, Execution 'Worker 'Critical WorkerCommand) => WorkerOperation a -> Program 'Worker 'Critical a
  SigningDSL :: (Typeable a, Execution 'Signer 'Critical SignerCommand) => SigningOperation a -> Program 'Signer 'Critical a
  ReadCustomer :: (Typeable a, Execution 'Customer 'Safe CustomerCommand) => CustomerRead a -> Program 'Customer 'Safe a
  WriteCustomer :: (Typeable a, Execution 'Customer 'Critical CustomerCommand) => CustomerWrite a -> Program 'Customer 'Critical a

-- The library existential hides the command family. Its nominal capability
-- indices retain caller, severity and result without a second request wrapper.
class (Typeable caller, Typeable severity, Typeable a,
       Outcome value ~ Program caller severity a)
    => CompileOperation (caller :: Caller) (severity :: Severity) a value
    | value -> caller severity a where
  compileOperation :: value -> Program caller severity a
  operationDSL :: value -> DSL value

type PreparationCaps caller severity a = '[CompileOperation caller severity a]
-- Servant needs a partially applied Type -> Type constructor, hence this
-- zero-cost newtype rather than an unsaturated type synonym. The existential
-- and its capability evidence belong entirely to the library.
newtype Pending caller severity a = Pending (SomeOperationWith
  (PreparationCaps caller severity a) (PreparationCaps caller severity a))
type role Pending nominal nominal nominal

pending :: (Operation value (PreparationCaps caller severity a),
            CompileOperation caller severity a value)
        => value -> Pending caller severity a
pending = Pending . prepare

-- The generic compilation boundary sees only CompileOperation. It receives no
-- evaluation environment and cannot call Execution methods. Interpretation is
-- explicit and total: a mismatched existential is rejected, never cast or forced.
checkedOperation :: Pending caller severity a -> Either Text (Program caller severity a)
checkedOperation (Pending operations) = withCapabilities (\value ->
  maybe (Left "operation_dictionary_mismatch") Right
    (interpret (SomeOperation value) (operationDSL value))) operations

instance (Typeable a, Execution caller severity (Command caller))
    => CompileOperation caller severity a (Command caller severity a) where
  compileOperation = command
  operationDSL _ = Compile

instance (Typeable a, Execution caller severity (Command caller))
    => Operation (Command caller severity a) (PreparationCaps caller severity a) where
  type Context (Command caller severity a) = CompileOperation caller severity a (Command caller severity a)
  type Outcome (Command caller severity a) = Program caller severity a
  data DSL (Command caller severity a) where
    Compile :: CompileOperation caller severity a (Command caller severity a)
      => DSL (Command caller severity a)
  interpret (SomeOperation (value :: actual)) Compile =
    case eqT @actual @(Command caller severity a) of
      Just Refl -> Just (compileOperation value)
      Nothing -> Nothing

-- Retain caller identity through dispatch; a critical customer operation cannot
-- be substituted with a critical operator or signer operation as grammar grows.
data Plan (caller :: Caller) a where
  SafePlan :: Pending caller 'Safe a -> Plan caller a
  CriticalPlan :: Pending caller 'Critical a -> Plan caller a

type role Plan nominal nominal
safe :: (Typeable a, Execution 'Customer 'Safe CustomerCommand) => CustomerRead a -> Plan 'Customer a
safe = SafePlan . pending . CustomerQuery
customer :: (Typeable a, Execution 'Customer 'Critical CustomerCommand) => CustomerWrite a -> Plan 'Customer a
customer = CriticalPlan . pending . CustomerChange

operator :: (Typeable a, Execution 'Operator 'Critical OperatorCommand) => OperatorWrite a -> Plan 'Operator a
operator=CriticalPlan . pending . OperatorChange
operatorRead :: (Typeable a, Execution 'Operator 'Safe OperatorCommand) => OperatorRead a -> Plan 'Operator a
operatorRead=SafePlan . pending . OperatorQuery

workerRequest :: (Typeable a, Execution 'Worker 'Critical WorkerCommand) => WorkerOperation a -> Pending 'Worker 'Critical a
workerRequest = pending . WorkerAction

-- Pure HTTP/control assembly carries these closed instance requirements.
type CustomerOperations = (Execution 'Customer 'Safe CustomerCommand, Execution 'Customer 'Critical CustomerCommand)
type OperatorOperations = (Execution 'Operator 'Safe OperatorCommand, Execution 'Operator 'Critical OperatorCommand)
