{-# LANGUAGE TemplateHaskell #-}
-- Existing schema, projected only as needed. No row operation lives here.
module Bridge.Store.Schema where
import Data.Int (Int64)
import Data.Text (Text)
import Data.Profunctor.Product (p2,p3,p4,p5,p6)
import Data.Profunctor.Product.TH (makeAdaptorAndInstance)
import qualified Opaleye as O

type TextField = O.Field O.SqlText
type IntField = O.Field O.SqlInt8

data DeploymentF n t = Deployment
  { singleton :: n, schemaVersion :: n, fingerprint :: t, criticalSequence :: n
  , backupSequence :: n, paused :: n, pauseReason :: t } deriving (Eq,Show)
$(makeAdaptorAndInstance "pDeployment" ''DeploymentF)
type Deployment = DeploymentF Int64 Text
deployment :: O.Table (DeploymentF IntField TextField) (DeploymentF IntField TextField)
deployment = O.table "deployment" $ pDeployment Deployment
  { singleton=O.requiredTableField "singleton", schemaVersion=O.requiredTableField "schema_version"
  , fingerprint=O.requiredTableField "fingerprint", criticalSequence=O.requiredTableField "critical_sequence"
  , backupSequence=O.requiredTableField "backup_sequence", paused=O.requiredTableField "paused"
  , pauseReason=O.requiredTableField "pause_reason" }

data WithdrawalF t n = Withdrawal
  { withdrawalId :: t, asset :: t, quantity :: n, recipient :: t
  , terms :: t, reason :: t, sequenceNo :: n } deriving (Eq,Show)
$(makeAdaptorAndInstance "pWithdrawal" ''WithdrawalF)
type Withdrawal = WithdrawalF Text Int64
withdrawals :: O.Table (WithdrawalF TextField IntField) (WithdrawalF TextField IntField)
withdrawals = O.table "fee_withdrawals" $ pWithdrawal Withdrawal
  { withdrawalId=O.requiredTableField "id", asset=O.requiredTableField "asset"
  , quantity=O.requiredTableField "amount", recipient=O.requiredTableField "recipient"
  , terms=O.requiredTableField "policy_json", reason=O.requiredTableField "reason"
  , sequenceNo=O.requiredTableField "critical_sequence" }

cancellations :: O.Table (TextField,TextField,IntField) (TextField,TextField,IntField)
cancellations = O.table "fee_withdrawal_cancellations" $ p3
  (O.requiredTableField "withdrawal_id",O.requiredTableField "reason",O.requiredTableField "critical_sequence")
events :: O.Table (TextField,TextField) (TextField,TextField)
events = O.table "events" $ p2 (O.requiredTableField "id",O.requiredTableField "description")
postings :: O.Table (Maybe IntField,TextField,TextField,TextField,IntField) (IntField,TextField,TextField,TextField,IntField)
postings = O.table "postings" $ p5
  (O.optionalTableField "id",O.requiredTableField "event_id",O.requiredTableField "asset",O.requiredTableField "account",O.requiredTableField "delta")
audit :: O.Table (Maybe IntField,TextField,TextField) (IntField,TextField,TextField)
audit = O.table "audit" $ p3 (O.optionalTableField "id",O.requiredTableField "action",O.requiredTableField "detail")
custody :: O.Table (IntField,IntField,O.FieldNullable O.SqlInt8,O.FieldNullable O.SqlInt8,O.FieldNullable O.SqlText)
                   (IntField,IntField,O.FieldNullable O.SqlInt8,O.FieldNullable O.SqlInt8,O.FieldNullable O.SqlText)
custody = O.table "custody_check" $ p5
  (O.requiredTableField "singleton",O.requiredTableField "revision",O.requiredTableField "checked_revision",O.requiredTableField "checked_at",O.requiredTableField "last_error")
intentIds :: O.Table TextField TextField
intentIds = O.table "intents" (O.requiredTableField "id")

data OrderF t n nt nn = Order
  { orderId :: t, capabilityHash :: t, idempotencyKey :: t, requestHash :: t
  , requestJson :: t, quoteJson :: t, policyJson :: t, status :: t
  , deadline :: n, graceDeadline :: n, instruction :: nt, instructionSequence :: nn
  , payoutTx :: nt, instructionIssued :: n } deriving (Eq,Show)
$(makeAdaptorAndInstance "pOrder" ''OrderF)
type Order = OrderF Text Int64 (Maybe Text) (Maybe Int64)
type OrderFields = OrderF TextField IntField (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlInt8)
orders :: O.Table OrderFields OrderFields
orders = O.table "orders" $ pOrder Order
  { orderId=O.requiredTableField "id", capabilityHash=O.requiredTableField "capability_hash"
  , idempotencyKey=O.requiredTableField "idempotency_key", requestHash=O.requiredTableField "request_hash"
  , requestJson=O.requiredTableField "request_json", quoteJson=O.requiredTableField "quote_json"
  , policyJson=O.requiredTableField "policy_json", status=O.requiredTableField "status"
  , deadline=O.requiredTableField "deadline", graceDeadline=O.requiredTableField "grace_deadline"
  , instruction=O.requiredTableField "instruction", instructionSequence=O.requiredTableField "instruction_sequence"
  , payoutTx=O.requiredTableField "payout_tx", instructionIssued=O.requiredTableField "instruction_issued" }

data DepositF t n nt = Deposit
  { depositId :: t, depositOrder :: nt, depositAsset :: t, depositAmount :: n
  , depositAnchor :: t, depositSeen :: n, depositDepth :: n, depositEligible :: n
  , depositAllocated :: n, depositState :: t } deriving (Eq,Show)
$(makeAdaptorAndInstance "pDeposit" ''DepositF)
type Deposit = DepositF Text Int64 (Maybe Text)
type DepositFields = DepositF TextField IntField (O.FieldNullable O.SqlText)
deposits :: O.Table DepositFields DepositFields
deposits = O.table "deposits" $ pDeposit Deposit
  { depositId=O.requiredTableField "id", depositOrder=O.requiredTableField "order_id"
  , depositAsset=O.requiredTableField "asset", depositAmount=O.requiredTableField "amount"
  , depositAnchor=O.requiredTableField "anchor", depositSeen=O.requiredTableField "first_seen"
  , depositDepth=O.requiredTableField "confirmations", depositEligible=O.requiredTableField "eligible"
  , depositAllocated=O.requiredTableField "allocated", depositState=O.requiredTableField "state" }

data ObligationF t n = Obligation
  { obligationId :: t, obligationOrder :: t, obligationDeposit :: t, obligationKind :: t
  , obligationAsset :: t, obligationAmount :: n, obligationRecipient :: t, obligationStatus :: t } deriving (Eq,Show)
$(makeAdaptorAndInstance "pObligation" ''ObligationF)
type Obligation = ObligationF Text Int64
type ObligationFields = ObligationF TextField IntField
obligations :: O.Table ObligationFields ObligationFields
obligations = O.table "obligations" $ pObligation Obligation
  { obligationId=O.requiredTableField "id", obligationOrder=O.requiredTableField "order_id"
  , obligationDeposit=O.requiredTableField "deposit_id", obligationKind=O.requiredTableField "kind"
  , obligationAsset=O.requiredTableField "asset", obligationAmount=O.requiredTableField "amount"
  , obligationRecipient=O.requiredTableField "recipient", obligationStatus=O.requiredTableField "status" }

-- Read projections for recovery overlays. They grant no update capability.
nativeRecovery, sourceRecovery :: O.Select (TextField,TextField)
nativeRecovery = O.selectTable $ O.table "native_payment_recovery_state" $ p2
  (O.requiredTableField "txid",O.requiredTableField "state")
sourceRecovery = O.selectTable $ O.table "source_recovery_state" $ p2
  (O.requiredTableField "deposit_id",O.requiredTableField "state")
accountedLosses :: O.Select TextField
accountedLosses = O.selectTable $ O.table "accounted_source_losses" (O.requiredTableField "deposit_id")
orderDeposits :: O.Select (TextField,O.FieldNullable O.SqlText)
orderDeposits = fmap (\row->(depositId row,depositOrder row)) (O.selectTable deposits)
orderObligations :: O.Select (TextField,TextField,TextField,TextField)
orderObligations = fmap (\row->(obligationId row,obligationOrder row,obligationDeposit row,obligationStatus row)) (O.selectTable obligations)
intentObligations, attemptIntents :: O.Select (TextField,TextField)
intentObligations = O.selectTable $ O.table "intents" $ p2
  (O.requiredTableField "id",O.requiredTableField "obligation_id")
attemptIntents = O.selectTable $ O.table "attempts" $ p2
  (O.requiredTableField "txid",O.requiredTableField "intent_id")

reservations :: O.Table (TextField,TextField,IntField,TextField) (TextField,TextField,IntField,TextField)
reservations = O.table "reservations" $ p4
  (O.requiredTableField "order_id",O.requiredTableField "asset",O.requiredTableField "amount",O.requiredTableField "phase")
orderCosts :: O.Table (TextField,IntField,IntField,IntField) (TextField,IntField,IntField,IntField)
orderCosts = O.table "order_cost_limits" $ p4
  (O.requiredTableField "order_id",O.requiredTableField "native_fee",O.requiredTableField "solana_fee",O.requiredTableField "solana_rent")
operatingReservations :: O.Table (TextField,TextField,TextField,IntField,TextField) (TextField,TextField,TextField,IntField,TextField)
operatingReservations = O.table "operating_reservations" $ p5
  (O.requiredTableField "order_id",O.requiredTableField "kind",O.requiredTableField "asset",O.requiredTableField "amount",O.requiredTableField "phase")
feeReservations :: O.Select (TextField,IntField,IntField)
feeReservations = O.selectTable $ O.table "fee_reservations" $ p3
  (O.requiredTableField "asset",O.requiredTableField "amount",O.requiredTableField "released")
operatingClock, operatingCosts :: O.Table (IntField,IntField) (IntField,IntField)
operatingClock = O.table "operating_clock" $ p2 (O.requiredTableField "singleton",O.requiredTableField "last_time")
operatingCosts = O.table "operating_costs" $ p2 (O.requiredTableField "posting_id",O.requiredTableField "recorded_at")
scanHealth :: O.Table (TextField,O.FieldNullable O.SqlInt8,O.FieldNullable O.SqlText,IntField)
                     (TextField,O.FieldNullable O.SqlInt8,O.FieldNullable O.SqlText,IntField)
scanHealth = O.table "scan_health" $ p4
  (O.requiredTableField "chain",O.requiredTableField "last_success",O.requiredTableField "last_error",O.requiredTableField "checked_at")
checkpoints :: O.Table (TextField,TextField) (TextField,TextField)
checkpoints = O.table "checkpoints" $ p2 (O.requiredTableField "chain",O.requiredTableField "anchor")
nativeAllocations :: O.Table (TextField,TextField,IntField) (TextField,TextField,IntField)
nativeAllocations = O.table "native_allocations" $ p3
  (O.requiredTableField "order_id",O.requiredTableField "label",O.requiredTableField "critical_sequence")

sourceChecks :: O.Table (Maybe IntField,TextField,TextField,IntField,TextField,IntField)
                       (IntField,TextField,TextField,IntField,TextField,IntField)
sourceChecks = O.table "source_recoveries" $ p6
  (O.optionalTableField "id",O.requiredTableField "deposit_id",O.requiredTableField "state",
   O.requiredTableField "shortfall",O.requiredTableField "evidence_json",O.requiredTableField "critical_sequence")
sourceReturns :: O.Table (IntField,IntField) (IntField,IntField)
sourceReturns = O.table "source_loss_returns" $ p2 (O.requiredTableField "cover_sequence",O.requiredTableField "recovery_sequence")
activeSourceCovers :: O.Select (IntField,TextField,IntField,IntField,IntField)
activeSourceCovers = O.selectTable $ O.table "active_source_loss_covers" $ p5
  (O.requiredTableField "critical_sequence",O.requiredTableField "deposit_id",O.requiredTableField "amount",
   O.requiredTableField "float_amount",O.requiredTableField "earned_amount")
eventHeads :: O.Select (TextField,TextField,TextField,TextField,IntField)
eventHeads = O.selectTable $ O.table "chain_events" $ p5
  (O.requiredTableField "chain",O.requiredTableField "event_id",O.requiredTableField "kind",O.requiredTableField "evidence_hash",O.requiredTableField "needs_review")
observationEvidence :: O.Table (TextField,TextField,TextField,TextField) (TextField,TextField,TextField,TextField)
observationEvidence = O.table "observation_evidence" $ p4
  (O.requiredTableField "hash",O.requiredTableField "chain",O.requiredTableField "event_id",O.requiredTableField "evidence_json")

-- Fixed recovery projections. Only closed operations execute these queries.
workIntents :: O.Select (TextField,TextField,IntField,O.FieldNullable O.SqlText)
workIntents = O.selectTable $ O.table "intents" $ p4
  (O.requiredTableField "id",O.requiredTableField "chain",O.requiredTableField "resolved",O.requiredTableField "common_input")
workPreparations :: O.Select (TextField,IntField,TextField,O.FieldNullable O.SqlText,O.FieldNullable O.SqlText,IntField)
workPreparations = O.selectTable $ O.table "preparations" $ p6
  (O.requiredTableField "intent_id",O.requiredTableField "generation",O.requiredTableField "policy_json",O.requiredTableField "draft_json",O.requiredTableField "retired_txid",O.requiredTableField "cancelled")
workAttempts :: O.Select (TextField,TextField,TextField,IntField,O.FieldNullable O.SqlInt8,O.FieldNullable O.SqlText)
workAttempts = O.selectTable $ O.table "attempts" $ p6
  (O.requiredTableField "txid",O.requiredTableField "intent_id",O.requiredTableField "state",O.requiredTableField "preparation_generation",O.requiredTableField "critical_sequence",O.requiredTableField "observation_json")
workCancellations :: O.Select (TextField,IntField,TextField,TextField,IntField)
workCancellations = O.selectTable $ O.table "preparation_cancellations" $ p5
  (O.requiredTableField "intent_id",O.requiredTableField "generation",O.requiredTableField "reason",O.requiredTableField "cleanup_json",O.requiredTableField "completed")
workFees :: O.Select (TextField,TextField,IntField,IntField)
workFees = O.selectTable $ O.table "fee_reservations" $ p4
  (O.requiredTableField "intent_id",O.requiredTableField "asset",O.requiredTableField "amount",O.requiredTableField "released")
replacementDrafts :: O.Select (IntField,TextField,IntField,TextField,TextField,TextField)
replacementDrafts = O.selectTable $ O.table "native_replacement_drafts" $ p6
  (O.requiredTableField "critical_sequence",O.requiredTableField "parent_txid",O.requiredTableField "fee",O.requiredTableField "draft_json",O.requiredTableField "work_hash",O.requiredTableField "reason")
replacementCancellations :: O.Select (IntField,TextField,IntField)
replacementCancellations = O.selectTable $ O.table "native_replacement_cancellations" $ p3
  (O.requiredTableField "draft_sequence",O.requiredTableField "reason",O.requiredTableField "critical_sequence")
winnerHistory :: O.Select (TextField,TextField)
winnerHistory = O.selectTable $ O.table "native_winner_changes" $ p2
  (O.requiredTableField "previous_txid",O.requiredTableField "previous_observation")
treasurySpendEffects :: O.Select (TextField,TextField,TextField,TextField)
treasurySpendEffects = O.selectTable $ O.table "treasury_spends" $ p4
  (O.requiredTableField "chain",O.requiredTableField "event_id",O.requiredTableField "anchor",O.requiredTableField "economic_json")
scanOrigins :: O.Table (TextField,TextField) (TextField,TextField)
scanOrigins = O.table "scan_origins" $ p2 (O.requiredTableField "chain",O.requiredTableField "anchor")

data ChainEventF t n = ChainEvent
  { eventChain :: t, eventId :: t, eventKind :: t, eventAnchor :: t, eventHash :: t
  , eventFirstSeen :: n, eventLastSeen :: n, eventReview :: n } deriving (Eq,Show)
$(makeAdaptorAndInstance "pChainEvent" ''ChainEventF)
type ChainEvent = ChainEventF Text Int64
chainEvents :: O.Table (ChainEventF TextField IntField) (ChainEventF TextField IntField)
chainEvents = O.table "chain_events" $ pChainEvent ChainEvent
  { eventChain=O.requiredTableField "chain",eventId=O.requiredTableField "event_id"
  , eventKind=O.requiredTableField "kind",eventAnchor=O.requiredTableField "anchor",eventHash=O.requiredTableField "evidence_hash"
  , eventFirstSeen=O.requiredTableField "first_seen",eventLastSeen=O.requiredTableField "last_seen",eventReview=O.requiredTableField "needs_review" }
