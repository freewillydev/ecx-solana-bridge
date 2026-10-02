{-# LANGUAGE TemplateHaskell, FlexibleInstances, MultiParamTypeClasses #-}
-- Typed PostgreSQL row definitions. Keep aligned with migrations/postgresql.
-- Schema changes require a forward migration and database contract checks.
module Bridge.Postgres.Schema where

import Data.Int (Int64)
import qualified Bridge.Ledger.Model as Domain
import Data.Text (Text)
import Data.Profunctor.Product.TH (makeAdaptorAndInstance)
import qualified Opaleye as O

data OrdersF a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 = Orders
  { ordersId :: a0
  , ordersCapabilityHash :: a1
  , ordersIdempotencyKey :: a2
  , ordersRequestHash :: a3
  , ordersRequestJson :: a4
  , ordersQuoteJson :: a5
  , ordersPolicyJson :: a6
  , ordersStatus :: a7
  , ordersDeadline :: a8
  , ordersGraceDeadline :: a9
  , ordersInstruction :: a10
  , ordersInstructionSequence :: a11
  , ordersPayoutTx :: a12
  , ordersInstructionIssued :: a13
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pOrders" ''OrdersF)

type Orders = OrdersF Text Text Text Text Text Text Text Text Int64 Int64 (Maybe Text) (Maybe Int64) (Maybe Text) Int64
type OrdersRead = OrdersF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
type OrdersWrite = OrdersF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
ordersTable :: O.Table OrdersWrite OrdersRead
ordersTable = O.table "orders" $ pOrders Orders
  { ordersId = O.requiredTableField "id"
  , ordersCapabilityHash = O.requiredTableField "capability_hash"
  , ordersIdempotencyKey = O.requiredTableField "idempotency_key"
  , ordersRequestHash = O.requiredTableField "request_hash"
  , ordersRequestJson = O.requiredTableField "request_json"
  , ordersQuoteJson = O.requiredTableField "quote_json"
  , ordersPolicyJson = O.requiredTableField "policy_json"
  , ordersStatus = O.requiredTableField "status"
  , ordersDeadline = O.requiredTableField "deadline"
  , ordersGraceDeadline = O.requiredTableField "grace_deadline"
  , ordersInstruction = O.requiredTableField "instruction"
  , ordersInstructionSequence = O.requiredTableField "instruction_sequence"
  , ordersPayoutTx = O.requiredTableField "payout_tx"
  , ordersInstructionIssued = O.requiredTableField "instruction_issued"
  }

data EventsF a0 a1 = Events
  { eventsId :: a0
  , eventsDescription :: a1
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pEvents" ''EventsF)

type Events = EventsF Text Text
type EventsRead = EventsF (O.Field O.SqlText) (O.Field O.SqlText)
type EventsWrite = EventsF (O.Field O.SqlText) (O.Field O.SqlText)
eventsTable :: O.Table EventsWrite EventsRead
eventsTable = O.table "events" $ pEvents Events
  { eventsId = O.requiredTableField "id"
  , eventsDescription = O.requiredTableField "description"
  }

data PostingsF a0 a1 a2 a3 a4 = Postings
  { postingsId :: a0
  , postingsEventId :: a1
  , postingsAsset :: a2
  , postingsAccount :: a3
  , postingsDelta :: a4
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pPostings" ''PostingsF)

type Postings = PostingsF Int64 Text Text Text Int64
type PostingsRead = PostingsF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type PostingsWrite = PostingsF (Maybe (O.Field O.SqlInt8)) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
postingsTable :: O.Table PostingsWrite PostingsRead
postingsTable = O.table "postings" $ pPostings Postings
  { postingsId = O.optionalTableField "id"
  , postingsEventId = O.requiredTableField "event_id"
  , postingsAsset = O.requiredTableField "asset"
  , postingsAccount = O.requiredTableField "account"
  , postingsDelta = O.requiredTableField "delta"
  }

data ReservationsF a0 a1 a2 a3 = Reservations
  { reservationsOrderId :: a0
  , reservationsAsset :: a1
  , reservationsAmount :: a2
  , reservationsPhase :: a3
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pReservations" ''ReservationsF)

type Reservations = ReservationsF Text Text Int64 Text
type ReservationsRead = ReservationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText)
type ReservationsWrite = ReservationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText)
reservationsTable :: O.Table ReservationsWrite ReservationsRead
reservationsTable = O.table "reservations" $ pReservations Reservations
  { reservationsOrderId = O.requiredTableField "order_id"
  , reservationsAsset = O.requiredTableField "asset"
  , reservationsAmount = O.requiredTableField "amount"
  , reservationsPhase = O.requiredTableField "phase"
  }

data DepositsF a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 = Deposits
  { depositsId :: a0
  , depositsOrderId :: a1
  , depositsAsset :: a2
  , depositsAmount :: a3
  , depositsAnchor :: a4
  , depositsFirstSeen :: a5
  , depositsConfirmations :: a6
  , depositsEligible :: a7
  , depositsAllocated :: a8
  , depositsState :: a9
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pDeposits" ''DepositsF)

type Deposits = DepositsF Text (Maybe Text) Text Int64 Text Int64 Int64 Int64 Int64 Text
type DepositsRead = DepositsF (O.Field O.SqlText) (O.FieldNullable O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText)
type DepositsWrite = DepositsF (O.Field O.SqlText) (O.FieldNullable O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText)
depositsTable :: O.Table DepositsWrite DepositsRead
depositsTable = O.table "deposits" $ pDeposits Deposits
  { depositsId = O.requiredTableField "id"
  , depositsOrderId = O.requiredTableField "order_id"
  , depositsAsset = O.requiredTableField "asset"
  , depositsAmount = O.requiredTableField "amount"
  , depositsAnchor = O.requiredTableField "anchor"
  , depositsFirstSeen = O.requiredTableField "first_seen"
  , depositsConfirmations = O.requiredTableField "confirmations"
  , depositsEligible = O.requiredTableField "eligible"
  , depositsAllocated = O.requiredTableField "allocated"
  , depositsState = O.requiredTableField "state"
  }

data ObligationsF a0 a1 a2 a3 a4 a5 a6 a7 = Obligations
  { obligationsId :: a0
  , obligationsOrderId :: a1
  , obligationsDepositId :: a2
  , obligationsKind :: a3
  , obligationsAsset :: a4
  , obligationsAmount :: a5
  , obligationsRecipient :: a6
  , obligationsStatus :: a7
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pObligations" ''ObligationsF)

type Obligations = ObligationsF Text Text Text Text Text Int64 Text Text
type ObligationsRead = ObligationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText)
type ObligationsWrite = ObligationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText)
obligationsTable :: O.Table ObligationsWrite ObligationsRead
obligationsTable = O.table "obligations" $ pObligations Obligations
  { obligationsId = O.requiredTableField "id"
  , obligationsOrderId = O.requiredTableField "order_id"
  , obligationsDepositId = O.requiredTableField "deposit_id"
  , obligationsKind = O.requiredTableField "kind"
  , obligationsAsset = O.requiredTableField "asset"
  , obligationsAmount = O.requiredTableField "amount"
  , obligationsRecipient = O.requiredTableField "recipient"
  , obligationsStatus = O.requiredTableField "status"
  }

data IntentsF a0 a1 a2 a3 a4 = Intents
  { intentsId :: a0
  , intentsObligationId :: a1
  , intentsChain :: a2
  , intentsCommonInput :: a3
  , intentsResolved :: a4
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pIntents" ''IntentsF)

type Intents = IntentsF Text Text Text (Maybe Text) Int64
type IntentsRead = IntentsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
type IntentsWrite = IntentsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
intentsTable :: O.Table IntentsWrite IntentsRead
intentsTable = O.table "intents" $ pIntents Intents
  { intentsId = O.requiredTableField "id"
  , intentsObligationId = O.requiredTableField "obligation_id"
  , intentsChain = O.requiredTableField "chain"
  , intentsCommonInput = O.requiredTableField "common_input"
  , intentsResolved = O.requiredTableField "resolved"
  }

data AttemptsF a0 a1 a2 a3 a4 a5 a6 a7 a8 = Attempts
  { attemptsTxid :: a0
  , attemptsIntentId :: a1
  , attemptsSignedBytes :: a2
  , attemptsPolicyJson :: a3
  , attemptsFeeLimit :: a4
  , attemptsState :: a5
  , attemptsCriticalSequence :: a6
  , attemptsObservationJson :: a7
  , attemptsPreparationGeneration :: a8
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pAttempts" ''AttemptsF)

type Attempts = AttemptsF Text Text Text Text Int64 Text (Maybe Int64) (Maybe Text) Int64
type AttemptsRead = AttemptsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
type AttemptsWrite = AttemptsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
attemptsTable :: O.Table AttemptsWrite AttemptsRead
attemptsTable = O.table "attempts" $ pAttempts Attempts
  { attemptsTxid = O.requiredTableField "txid"
  , attemptsIntentId = O.requiredTableField "intent_id"
  , attemptsSignedBytes = O.requiredTableField "signed_bytes"
  , attemptsPolicyJson = O.requiredTableField "policy_json"
  , attemptsFeeLimit = O.requiredTableField "fee_limit"
  , attemptsState = O.requiredTableField "state"
  , attemptsCriticalSequence = O.requiredTableField "critical_sequence"
  , attemptsObservationJson = O.requiredTableField "observation_json"
  , attemptsPreparationGeneration = O.requiredTableField "preparation_generation"
  }

data CheckpointsF a0 a1 = Checkpoints
  { checkpointsChain :: a0
  , checkpointsAnchor :: a1
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pCheckpoints" ''CheckpointsF)

type Checkpoints = CheckpointsF Text Text
type CheckpointsRead = CheckpointsF (O.Field O.SqlText) (O.Field O.SqlText)
type CheckpointsWrite = CheckpointsF (O.Field O.SqlText) (O.Field O.SqlText)
checkpointsTable :: O.Table CheckpointsWrite CheckpointsRead
checkpointsTable = O.table "checkpoints" $ pCheckpoints Checkpoints
  { checkpointsChain = O.requiredTableField "chain"
  , checkpointsAnchor = O.requiredTableField "anchor"
  }

data AuditF a0 a1 a2 = Audit
  { auditId :: a0
  , auditAction :: a1
  , auditDetail :: a2
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pAudit" ''AuditF)

type Audit = AuditF Int64 Text Text
type AuditRead = AuditF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText)
type AuditWrite = AuditF (Maybe (O.Field O.SqlInt8)) (O.Field O.SqlText) (O.Field O.SqlText)
auditTable :: O.Table AuditWrite AuditRead
auditTable = O.table "audit" $ pAudit Audit
  { auditId = O.optionalTableField "id"
  , auditAction = O.requiredTableField "action"
  , auditDetail = O.requiredTableField "detail"
  }

data FeeReservationsF a0 a1 a2 a3 = FeeReservations
  { feereservationsIntentId :: a0
  , feereservationsAsset :: a1
  , feereservationsAmount :: a2
  , feereservationsReleased :: a3
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pFeeReservations" ''FeeReservationsF)

type FeeReservations = FeeReservationsF Text Text Int64 Int64
type FeeReservationsRead = FeeReservationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
type FeeReservationsWrite = FeeReservationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
feereservationsTable :: O.Table FeeReservationsWrite FeeReservationsRead
feereservationsTable = O.table "fee_reservations" $ pFeeReservations FeeReservations
  { feereservationsIntentId = O.requiredTableField "intent_id"
  , feereservationsAsset = O.requiredTableField "asset"
  , feereservationsAmount = O.requiredTableField "amount"
  , feereservationsReleased = O.requiredTableField "released"
  }

data DeploymentF a0 a1 a2 a3 a4 a5 a6 = Deployment
  { deploymentSingleton :: a0
  , deploymentSchemaVersion :: a1
  , deploymentFingerprint :: a2
  , deploymentCriticalSequence :: a3
  , deploymentBackupSequence :: a4
  , deploymentPaused :: a5
  , deploymentPauseReason :: a6
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pDeployment" ''DeploymentF)

type Deployment = DeploymentF Int64 Int64 Text Int64 Int64 Int64 Text
type DeploymentRead = DeploymentF (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText)
type DeploymentWrite = DeploymentF (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText)
deploymentTable :: O.Table DeploymentWrite DeploymentRead
deploymentTable = O.table "deployment" $ pDeployment Deployment
  { deploymentSingleton = O.requiredTableField "singleton"
  , deploymentSchemaVersion = O.requiredTableField "schema_version"
  , deploymentFingerprint = O.requiredTableField "fingerprint"
  , deploymentCriticalSequence = O.requiredTableField "critical_sequence"
  , deploymentBackupSequence = O.requiredTableField "backup_sequence"
  , deploymentPaused = O.requiredTableField "paused"
  , deploymentPauseReason = O.requiredTableField "pause_reason"
  }

data ObservationEvidenceF a0 a1 a2 a3 = ObservationEvidence
  { observationevidenceHash :: a0
  , observationevidenceChain :: a1
  , observationevidenceEventId :: a2
  , observationevidenceEvidenceJson :: a3
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pObservationEvidence" ''ObservationEvidenceF)

type ObservationEvidence = ObservationEvidenceF Text Text Text Text
type ObservationEvidenceRead = ObservationEvidenceF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText)
type ObservationEvidenceWrite = ObservationEvidenceF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText)
observationevidenceTable :: O.Table ObservationEvidenceWrite ObservationEvidenceRead
observationevidenceTable = O.table "observation_evidence" $ pObservationEvidence ObservationEvidence
  { observationevidenceHash = O.requiredTableField "hash"
  , observationevidenceChain = O.requiredTableField "chain"
  , observationevidenceEventId = O.requiredTableField "event_id"
  , observationevidenceEvidenceJson = O.requiredTableField "evidence_json"
  }

data ScanOriginsF a0 a1 = ScanOrigins
  { scanoriginsChain :: a0
  , scanoriginsAnchor :: a1
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pScanOrigins" ''ScanOriginsF)

type ScanOrigins = ScanOriginsF Text Text
type ScanOriginsRead = ScanOriginsF (O.Field O.SqlText) (O.Field O.SqlText)
type ScanOriginsWrite = ScanOriginsF (O.Field O.SqlText) (O.Field O.SqlText)
scanoriginsTable :: O.Table ScanOriginsWrite ScanOriginsRead
scanoriginsTable = O.table "scan_origins" $ pScanOrigins ScanOrigins
  { scanoriginsChain = O.requiredTableField "chain"
  , scanoriginsAnchor = O.requiredTableField "anchor"
  }

data ScanHealthF a0 a1 a2 a3 = ScanHealth
  { scanhealthChain :: a0
  , scanhealthLastSuccess :: a1
  , scanhealthLastError :: a2
  , scanhealthCheckedAt :: a3
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pScanHealth" ''ScanHealthF)

type ScanHealth = ScanHealthF Text (Maybe Int64) (Maybe Text) Int64
type ScanHealthRead = ScanHealthF (O.Field O.SqlText) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
type ScanHealthWrite = ScanHealthF (O.Field O.SqlText) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
scanhealthTable :: O.Table ScanHealthWrite ScanHealthRead
scanhealthTable = O.table "scan_health" $ pScanHealth ScanHealth
  { scanhealthChain = O.requiredTableField "chain"
  , scanhealthLastSuccess = O.requiredTableField "last_success"
  , scanhealthLastError = O.requiredTableField "last_error"
  , scanhealthCheckedAt = O.requiredTableField "checked_at"
  }

data ChainEventsF a0 a1 a2 a3 a4 a5 a6 a7 = ChainEvents
  { chaineventsChain :: a0
  , chaineventsEventId :: a1
  , chaineventsKind :: a2
  , chaineventsAnchor :: a3
  , chaineventsEvidenceHash :: a4
  , chaineventsFirstSeen :: a5
  , chaineventsLastSeen :: a6
  , chaineventsNeedsReview :: a7
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pChainEvents" ''ChainEventsF)

type ChainEvents = ChainEventsF Text Text Text Text Text Int64 Int64 Int64
type ChainEventsRead = ChainEventsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
type ChainEventsWrite = ChainEventsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
chaineventsTable :: O.Table ChainEventsWrite ChainEventsRead
chaineventsTable = O.table "chain_events" $ pChainEvents ChainEvents
  { chaineventsChain = O.requiredTableField "chain"
  , chaineventsEventId = O.requiredTableField "event_id"
  , chaineventsKind = O.requiredTableField "kind"
  , chaineventsAnchor = O.requiredTableField "anchor"
  , chaineventsEvidenceHash = O.requiredTableField "evidence_hash"
  , chaineventsFirstSeen = O.requiredTableField "first_seen"
  , chaineventsLastSeen = O.requiredTableField "last_seen"
  , chaineventsNeedsReview = O.requiredTableField "needs_review"
  }

data TreasuryAllocationsF a0 a1 a2 a3 = TreasuryAllocations
  { treasuryallocationsDepositId :: a0
  , treasuryallocationsAllocationJson :: a1
  , treasuryallocationsProofJson :: a2
  , treasuryallocationsCriticalSequence :: a3
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pTreasuryAllocations" ''TreasuryAllocationsF)

type TreasuryAllocations = TreasuryAllocationsF Text Text Text Int64
type TreasuryAllocationsRead = TreasuryAllocationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type TreasuryAllocationsWrite = TreasuryAllocationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
treasuryallocationsTable :: O.Table TreasuryAllocationsWrite TreasuryAllocationsRead
treasuryallocationsTable = O.table "treasury_allocations" $ pTreasuryAllocations TreasuryAllocations
  { treasuryallocationsDepositId = O.requiredTableField "deposit_id"
  , treasuryallocationsAllocationJson = O.requiredTableField "allocation_json"
  , treasuryallocationsProofJson = O.requiredTableField "proof_json"
  , treasuryallocationsCriticalSequence = O.requiredTableField "critical_sequence"
  }

data TreasurySpendsF a0 a1 a2 a3 a4 a5 = TreasurySpends
  { treasuryspendsChain :: a0
  , treasuryspendsEventId :: a1
  , treasuryspendsAnchor :: a2
  , treasuryspendsEconomicJson :: a3
  , treasuryspendsProofJson :: a4
  , treasuryspendsCriticalSequence :: a5
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pTreasurySpends" ''TreasurySpendsF)

type TreasurySpends = TreasurySpendsF Text Text Text Text Text Int64
type TreasurySpendsRead = TreasurySpendsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type TreasurySpendsWrite = TreasurySpendsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
treasuryspendsTable :: O.Table TreasurySpendsWrite TreasurySpendsRead
treasuryspendsTable = O.table "treasury_spends" $ pTreasurySpends TreasurySpends
  { treasuryspendsChain = O.requiredTableField "chain"
  , treasuryspendsEventId = O.requiredTableField "event_id"
  , treasuryspendsAnchor = O.requiredTableField "anchor"
  , treasuryspendsEconomicJson = O.requiredTableField "economic_json"
  , treasuryspendsProofJson = O.requiredTableField "proof_json"
  , treasuryspendsCriticalSequence = O.requiredTableField "critical_sequence"
  }

data SolanaExpiriesF a0 a1 a2 = SolanaExpiries
  { solanaexpiriesTxid :: a0
  , solanaexpiriesProofJson :: a1
  , solanaexpiriesCriticalSequence :: a2
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pSolanaExpiries" ''SolanaExpiriesF)

type SolanaExpiries = SolanaExpiriesF Text Text Int64
type SolanaExpiriesRead = SolanaExpiriesF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type SolanaExpiriesWrite = SolanaExpiriesF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
solanaexpiriesTable :: O.Table SolanaExpiriesWrite SolanaExpiriesRead
solanaexpiriesTable = O.table "solana_expiries" $ pSolanaExpiries SolanaExpiries
  { solanaexpiriesTxid = O.requiredTableField "txid"
  , solanaexpiriesProofJson = O.requiredTableField "proof_json"
  , solanaexpiriesCriticalSequence = O.requiredTableField "critical_sequence"
  }

data PreparationsF a0 a1 a2 a3 a4 a5 = Preparations
  { preparationsIntentId :: a0
  , preparationsGeneration :: a1
  , preparationsPolicyJson :: a2
  , preparationsDraftJson :: a3
  , preparationsRetiredTxid :: a4
  , preparationsCancelled :: a5
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pPreparations" ''PreparationsF)

type Preparations = PreparationsF Text Int64 Text (Maybe Text) (Maybe Text) Int64
type PreparationsRead = PreparationsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
type PreparationsWrite = PreparationsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlText) (O.Field O.SqlInt8)
preparationsTable :: O.Table PreparationsWrite PreparationsRead
preparationsTable = O.table "preparations" $ pPreparations Preparations
  { preparationsIntentId = O.requiredTableField "intent_id"
  , preparationsGeneration = O.requiredTableField "generation"
  , preparationsPolicyJson = O.requiredTableField "policy_json"
  , preparationsDraftJson = O.requiredTableField "draft_json"
  , preparationsRetiredTxid = O.requiredTableField "retired_txid"
  , preparationsCancelled = O.requiredTableField "cancelled"
  }

data SolanaRetryApprovalsF a0 a1 a2 a3 = SolanaRetryApprovals
  { solanaretryapprovalsExpiredTxid :: a0
  , solanaretryapprovalsReason :: a1
  , solanaretryapprovalsProofJson :: a2
  , solanaretryapprovalsCriticalSequence :: a3
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pSolanaRetryApprovals" ''SolanaRetryApprovalsF)

type SolanaRetryApprovals = SolanaRetryApprovalsF Text Text Text Int64
type SolanaRetryApprovalsRead = SolanaRetryApprovalsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type SolanaRetryApprovalsWrite = SolanaRetryApprovalsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
solanaretryapprovalsTable :: O.Table SolanaRetryApprovalsWrite SolanaRetryApprovalsRead
solanaretryapprovalsTable = O.table "solana_retry_approvals" $ pSolanaRetryApprovals SolanaRetryApprovals
  { solanaretryapprovalsExpiredTxid = O.requiredTableField "expired_txid"
  , solanaretryapprovalsReason = O.requiredTableField "reason"
  , solanaretryapprovalsProofJson = O.requiredTableField "proof_json"
  , solanaretryapprovalsCriticalSequence = O.requiredTableField "critical_sequence"
  }

data OperatingClockF a0 a1 = OperatingClock
  { operatingclockSingleton :: a0
  , operatingclockLastTime :: a1
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pOperatingClock" ''OperatingClockF)

type OperatingClock = OperatingClockF Int64 Int64
type OperatingClockRead = OperatingClockF (O.Field O.SqlInt8) (O.Field O.SqlInt8)
type OperatingClockWrite = OperatingClockF (O.Field O.SqlInt8) (O.Field O.SqlInt8)
operatingclockTable :: O.Table OperatingClockWrite OperatingClockRead
operatingclockTable = O.table "operating_clock" $ pOperatingClock OperatingClock
  { operatingclockSingleton = O.requiredTableField "singleton"
  , operatingclockLastTime = O.requiredTableField "last_time"
  }

data OperatingCostsF a0 a1 = OperatingCosts
  { operatingcostsPostingId :: a0
  , operatingcostsRecordedAt :: a1
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pOperatingCosts" ''OperatingCostsF)

type OperatingCosts = OperatingCostsF Int64 Int64
type OperatingCostsRead = OperatingCostsF (O.Field O.SqlInt8) (O.Field O.SqlInt8)
type OperatingCostsWrite = OperatingCostsF (O.Field O.SqlInt8) (O.Field O.SqlInt8)
operatingcostsTable :: O.Table OperatingCostsWrite OperatingCostsRead
operatingcostsTable = O.table "operating_costs" $ pOperatingCosts OperatingCosts
  { operatingcostsPostingId = O.requiredTableField "posting_id"
  , operatingcostsRecordedAt = O.requiredTableField "recorded_at"
  }

data OrderCostLimitsF a0 a1 a2 a3 = OrderCostLimits
  { ordercostlimitsOrderId :: a0
  , ordercostlimitsNativeFee :: a1
  , ordercostlimitsSolanaFee :: a2
  , ordercostlimitsSolanaRent :: a3
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pOrderCostLimits" ''OrderCostLimitsF)

type OrderCostLimits = OrderCostLimitsF Text Int64 Int64 Int64
type OrderCostLimitsRead = OrderCostLimitsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
type OrderCostLimitsWrite = OrderCostLimitsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
ordercostlimitsTable :: O.Table OrderCostLimitsWrite OrderCostLimitsRead
ordercostlimitsTable = O.table "order_cost_limits" $ pOrderCostLimits OrderCostLimits
  { ordercostlimitsOrderId = O.requiredTableField "order_id"
  , ordercostlimitsNativeFee = O.requiredTableField "native_fee"
  , ordercostlimitsSolanaFee = O.requiredTableField "solana_fee"
  , ordercostlimitsSolanaRent = O.requiredTableField "solana_rent"
  }

data OperatingReservationsF a0 a1 a2 a3 a4 = OperatingReservations
  { operatingreservationsOrderId :: a0
  , operatingreservationsKind :: a1
  , operatingreservationsAsset :: a2
  , operatingreservationsAmount :: a3
  , operatingreservationsPhase :: a4
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pOperatingReservations" ''OperatingReservationsF)

type OperatingReservations = OperatingReservationsF Text Text Text Int64 Text
type OperatingReservationsRead = OperatingReservationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText)
type OperatingReservationsWrite = OperatingReservationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText)
operatingreservationsTable :: O.Table OperatingReservationsWrite OperatingReservationsRead
operatingreservationsTable = O.table "operating_reservations" $ pOperatingReservations OperatingReservations
  { operatingreservationsOrderId = O.requiredTableField "order_id"
  , operatingreservationsKind = O.requiredTableField "kind"
  , operatingreservationsAsset = O.requiredTableField "asset"
  , operatingreservationsAmount = O.requiredTableField "amount"
  , operatingreservationsPhase = O.requiredTableField "phase"
  }

data NativeAllocationsF a0 a1 a2 = NativeAllocations
  { nativeallocationsOrderId :: a0
  , nativeallocationsLabel :: a1
  , nativeallocationsCriticalSequence :: a2
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pNativeAllocations" ''NativeAllocationsF)

type NativeAllocations = NativeAllocationsF Text Text Int64
type NativeAllocationsRead = NativeAllocationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type NativeAllocationsWrite = NativeAllocationsF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
nativeallocationsTable :: O.Table NativeAllocationsWrite NativeAllocationsRead
nativeallocationsTable = O.table "native_allocations" $ pNativeAllocations NativeAllocations
  { nativeallocationsOrderId = O.requiredTableField "order_id"
  , nativeallocationsLabel = O.requiredTableField "label"
  , nativeallocationsCriticalSequence = O.requiredTableField "critical_sequence"
  }

data CustodyCheckF a0 a1 a2 a3 a4 a5 = CustodyCheck
  { custodycheckSingleton :: a0
  , custodycheckRevision :: a1
  , custodycheckCheckedRevision :: a2
  , custodycheckCheckedAt :: a3
  , custodycheckLastError :: a4
  , custodycheckReportJson :: a5
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pCustodyCheck" ''CustodyCheckF)

type CustodyCheck = CustodyCheckF Int64 Int64 (Maybe Int64) (Maybe Int64) (Maybe Text) (Maybe Text)
type CustodyCheckRead = CustodyCheckF (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlText)
type CustodyCheckWrite = CustodyCheckF (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlText)
custodycheckTable :: O.Table CustodyCheckWrite CustodyCheckRead
custodycheckTable = O.table "custody_check" $ pCustodyCheck CustodyCheck
  { custodycheckSingleton = O.requiredTableField "singleton"
  , custodycheckRevision = O.requiredTableField "revision"
  , custodycheckCheckedRevision = O.requiredTableField "checked_revision"
  , custodycheckCheckedAt = O.requiredTableField "checked_at"
  , custodycheckLastError = O.requiredTableField "last_error"
  , custodycheckReportJson = O.requiredTableField "report_json"
  }

data PreparationCancellationsF a0 a1 a2 a3 a4 a5 = PreparationCancellations
  { preparationcancellationsIntentId :: a0
  , preparationcancellationsGeneration :: a1
  , preparationcancellationsReason :: a2
  , preparationcancellationsCleanupJson :: a3
  , preparationcancellationsCriticalSequence :: a4
  , preparationcancellationsCompleted :: a5
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pPreparationCancellations" ''PreparationCancellationsF)

type PreparationCancellations = PreparationCancellationsF Text Int64 Text Text Int64 Int64
type PreparationCancellationsRead = PreparationCancellationsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
type PreparationCancellationsWrite = PreparationCancellationsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8)
preparationcancellationsTable :: O.Table PreparationCancellationsWrite PreparationCancellationsRead
preparationcancellationsTable = O.table "preparation_cancellations" $ pPreparationCancellations PreparationCancellations
  { preparationcancellationsIntentId = O.requiredTableField "intent_id"
  , preparationcancellationsGeneration = O.requiredTableField "generation"
  , preparationcancellationsReason = O.requiredTableField "reason"
  , preparationcancellationsCleanupJson = O.requiredTableField "cleanup_json"
  , preparationcancellationsCriticalSequence = O.requiredTableField "critical_sequence"
  , preparationcancellationsCompleted = O.requiredTableField "completed"
  }

data NativePaymentRecoveriesF a0 a1 a2 a3 a4 a5 = NativePaymentRecoveries
  { nativepaymentrecoveriesId :: a0
  , nativepaymentrecoveriesTxid :: a1
  , nativepaymentrecoveriesPreviousObservation :: a2
  , nativepaymentrecoveriesState :: a3
  , nativepaymentrecoveriesObservationJson :: a4
  , nativepaymentrecoveriesCriticalSequence :: a5
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pNativePaymentRecoveries" ''NativePaymentRecoveriesF)

type NativePaymentRecoveries = NativePaymentRecoveriesF Int64 Text Text Text Text Int64
type NativePaymentRecoveriesRead = NativePaymentRecoveriesF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type NativePaymentRecoveriesWrite = NativePaymentRecoveriesF (Maybe (O.Field O.SqlInt8)) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
nativepaymentrecoveriesTable :: O.Table NativePaymentRecoveriesWrite NativePaymentRecoveriesRead
nativepaymentrecoveriesTable = O.table "native_payment_recoveries" $ pNativePaymentRecoveries NativePaymentRecoveries
  { nativepaymentrecoveriesId = O.optionalTableField "id"
  , nativepaymentrecoveriesTxid = O.requiredTableField "txid"
  , nativepaymentrecoveriesPreviousObservation = O.requiredTableField "previous_observation"
  , nativepaymentrecoveriesState = O.requiredTableField "state"
  , nativepaymentrecoveriesObservationJson = O.requiredTableField "observation_json"
  , nativepaymentrecoveriesCriticalSequence = O.requiredTableField "critical_sequence"
  }

data SourceRecoveriesF a0 a1 a2 a3 a4 a5 = SourceRecoveries
  { sourcerecoveriesId :: a0
  , sourcerecoveriesDepositId :: a1
  , sourcerecoveriesState :: a2
  , sourcerecoveriesShortfall :: a3
  , sourcerecoveriesEvidenceJson :: a4
  , sourcerecoveriesCriticalSequence :: a5
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pSourceRecoveries" ''SourceRecoveriesF)

type SourceRecoveries = SourceRecoveriesF Int64 Text Text Int64 Text Int64
type SourceRecoveriesRead = SourceRecoveriesF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8)
type SourceRecoveriesWrite = SourceRecoveriesF (Maybe (O.Field O.SqlInt8)) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8)
sourcerecoveriesTable :: O.Table SourceRecoveriesWrite SourceRecoveriesRead
sourcerecoveriesTable = O.table "source_recoveries" $ pSourceRecoveries SourceRecoveries
  { sourcerecoveriesId = O.optionalTableField "id"
  , sourcerecoveriesDepositId = O.requiredTableField "deposit_id"
  , sourcerecoveriesState = O.requiredTableField "state"
  , sourcerecoveriesShortfall = O.requiredTableField "shortfall"
  , sourcerecoveriesEvidenceJson = O.requiredTableField "evidence_json"
  , sourcerecoveriesCriticalSequence = O.requiredTableField "critical_sequence"
  }

data SourceRecoveryApprovalsF a0 a1 a2 a3 a4 a5 a6 a7 = SourceRecoveryApprovals
  { sourcerecoveryapprovalsObligationId :: a0
  , sourcerecoveryapprovalsRestorationSequence :: a1
  , sourcerecoveryapprovalsLossSequence :: a2
  , sourcerecoveryapprovalsPriorStatus :: a3
  , sourcerecoveryapprovalsWorkHash :: a4
  , sourcerecoveryapprovalsReason :: a5
  , sourcerecoveryapprovalsProofJson :: a6
  , sourcerecoveryapprovalsCriticalSequence :: a7
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pSourceRecoveryApprovals" ''SourceRecoveryApprovalsF)

type SourceRecoveryApprovals = SourceRecoveryApprovalsF Text Int64 Int64 Text Text Text Text Int64
type SourceRecoveryApprovalsRead = SourceRecoveryApprovalsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type SourceRecoveryApprovalsWrite = SourceRecoveryApprovalsF (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
sourcerecoveryapprovalsTable :: O.Table SourceRecoveryApprovalsWrite SourceRecoveryApprovalsRead
sourcerecoveryapprovalsTable = O.table "source_recovery_approvals" $ pSourceRecoveryApprovals SourceRecoveryApprovals
  { sourcerecoveryapprovalsObligationId = O.requiredTableField "obligation_id"
  , sourcerecoveryapprovalsRestorationSequence = O.requiredTableField "restoration_sequence"
  , sourcerecoveryapprovalsLossSequence = O.requiredTableField "loss_sequence"
  , sourcerecoveryapprovalsPriorStatus = O.requiredTableField "prior_status"
  , sourcerecoveryapprovalsWorkHash = O.requiredTableField "work_hash"
  , sourcerecoveryapprovalsReason = O.requiredTableField "reason"
  , sourcerecoveryapprovalsProofJson = O.requiredTableField "proof_json"
  , sourcerecoveryapprovalsCriticalSequence = O.requiredTableField "critical_sequence"
  }

data SourceLossCoversF a0 a1 a2 a3 a4 a5 a6 a7 = SourceLossCovers
  { sourcelosscoversCriticalSequence :: a0
  , sourcelosscoversDepositId :: a1
  , sourcelosscoversRecoverySequence :: a2
  , sourcelosscoversAmount :: a3
  , sourcelosscoversFloatAmount :: a4
  , sourcelosscoversEarnedAmount :: a5
  , sourcelosscoversReason :: a6
  , sourcelosscoversProofJson :: a7
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pSourceLossCovers" ''SourceLossCoversF)

type SourceLossCovers = SourceLossCoversF Int64 Text Int64 Int64 Int64 Int64 Text Text
type SourceLossCoversRead = SourceLossCoversF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText)
type SourceLossCoversWrite = SourceLossCoversF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText)
sourcelosscoversTable :: O.Table SourceLossCoversWrite SourceLossCoversRead
sourcelosscoversTable = O.table "source_loss_covers" $ pSourceLossCovers SourceLossCovers
  { sourcelosscoversCriticalSequence = O.requiredTableField "critical_sequence"
  , sourcelosscoversDepositId = O.requiredTableField "deposit_id"
  , sourcelosscoversRecoverySequence = O.requiredTableField "recovery_sequence"
  , sourcelosscoversAmount = O.requiredTableField "amount"
  , sourcelosscoversFloatAmount = O.requiredTableField "float_amount"
  , sourcelosscoversEarnedAmount = O.requiredTableField "earned_amount"
  , sourcelosscoversReason = O.requiredTableField "reason"
  , sourcelosscoversProofJson = O.requiredTableField "proof_json"
  }

data SourceLossReturnsF a0 a1 = SourceLossReturns
  { sourcelossreturnsCoverSequence :: a0
  , sourcelossreturnsRecoverySequence :: a1
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pSourceLossReturns" ''SourceLossReturnsF)

type SourceLossReturns = SourceLossReturnsF Int64 Int64
type SourceLossReturnsRead = SourceLossReturnsF (O.Field O.SqlInt8) (O.Field O.SqlInt8)
type SourceLossReturnsWrite = SourceLossReturnsF (O.Field O.SqlInt8) (O.Field O.SqlInt8)
sourcelossreturnsTable :: O.Table SourceLossReturnsWrite SourceLossReturnsRead
sourcelossreturnsTable = O.table "source_loss_returns" $ pSourceLossReturns SourceLossReturns
  { sourcelossreturnsCoverSequence = O.requiredTableField "cover_sequence"
  , sourcelossreturnsRecoverySequence = O.requiredTableField "recovery_sequence"
  }

data NativeReplacementDraftsF a0 a1 a2 a3 a4 a5 a6 = NativeReplacementDrafts
  { nativereplacementdraftsCriticalSequence :: a0
  , nativereplacementdraftsParentTxid :: a1
  , nativereplacementdraftsFee :: a2
  , nativereplacementdraftsDraftJson :: a3
  , nativereplacementdraftsWorkHash :: a4
  , nativereplacementdraftsReason :: a5
  , nativereplacementdraftsProofJson :: a6
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pNativeReplacementDrafts" ''NativeReplacementDraftsF)

type NativeReplacementDrafts = NativeReplacementDraftsF Int64 Text Int64 Text Text Text Text
type NativeReplacementDraftsRead = NativeReplacementDraftsF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText)
type NativeReplacementDraftsWrite = NativeReplacementDraftsF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText)
nativereplacementdraftsTable :: O.Table NativeReplacementDraftsWrite NativeReplacementDraftsRead
nativereplacementdraftsTable = O.table "native_replacement_drafts" $ pNativeReplacementDrafts NativeReplacementDrafts
  { nativereplacementdraftsCriticalSequence = O.requiredTableField "critical_sequence"
  , nativereplacementdraftsParentTxid = O.requiredTableField "parent_txid"
  , nativereplacementdraftsFee = O.requiredTableField "fee"
  , nativereplacementdraftsDraftJson = O.requiredTableField "draft_json"
  , nativereplacementdraftsWorkHash = O.requiredTableField "work_hash"
  , nativereplacementdraftsReason = O.requiredTableField "reason"
  , nativereplacementdraftsProofJson = O.requiredTableField "proof_json"
  }

data NativeReplacementCancellationsF a0 a1 a2 = NativeReplacementCancellations
  { nativereplacementcancellationsDraftSequence :: a0
  , nativereplacementcancellationsReason :: a1
  , nativereplacementcancellationsCriticalSequence :: a2
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pNativeReplacementCancellations" ''NativeReplacementCancellationsF)

type NativeReplacementCancellations = NativeReplacementCancellationsF Int64 Text Int64
type NativeReplacementCancellationsRead = NativeReplacementCancellationsF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8)
type NativeReplacementCancellationsWrite = NativeReplacementCancellationsF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8)
nativereplacementcancellationsTable :: O.Table NativeReplacementCancellationsWrite NativeReplacementCancellationsRead
nativereplacementcancellationsTable = O.table "native_replacement_cancellations" $ pNativeReplacementCancellations NativeReplacementCancellations
  { nativereplacementcancellationsDraftSequence = O.requiredTableField "draft_sequence"
  , nativereplacementcancellationsReason = O.requiredTableField "reason"
  , nativereplacementcancellationsCriticalSequence = O.requiredTableField "critical_sequence"
  }

data NativeReplacementMembersF a0 a1 a2 = NativeReplacementMembers
  { nativereplacementmembersDraftSequence :: a0
  , nativereplacementmembersTxid :: a1
  , nativereplacementmembersCriticalSequence :: a2
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pNativeReplacementMembers" ''NativeReplacementMembersF)

type NativeReplacementMembers = NativeReplacementMembersF Int64 Text Int64
type NativeReplacementMembersRead = NativeReplacementMembersF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8)
type NativeReplacementMembersWrite = NativeReplacementMembersF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlInt8)
nativereplacementmembersTable :: O.Table NativeReplacementMembersWrite NativeReplacementMembersRead
nativereplacementmembersTable = O.table "native_replacement_members" $ pNativeReplacementMembers NativeReplacementMembers
  { nativereplacementmembersDraftSequence = O.requiredTableField "draft_sequence"
  , nativereplacementmembersTxid = O.requiredTableField "txid"
  , nativereplacementmembersCriticalSequence = O.requiredTableField "critical_sequence"
  }

data NativeWinnerChangesF a0 a1 a2 a3 a4 a5 a6 = NativeWinnerChanges
  { nativewinnerchangesCriticalSequence :: a0
  , nativewinnerchangesPreviousTxid :: a1
  , nativewinnerchangesWinnerTxid :: a2
  , nativewinnerchangesPreviousObservation :: a3
  , nativewinnerchangesObservationJson :: a4
  , nativewinnerchangesEvidenceHash :: a5
  , nativewinnerchangesFeeDelta :: a6
  } deriving (Eq,Show)
$(makeAdaptorAndInstance "pNativeWinnerChanges" ''NativeWinnerChangesF)

type NativeWinnerChanges = NativeWinnerChangesF Int64 Text Text Text Text Text Int64
type NativeWinnerChangesRead = NativeWinnerChangesF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
type NativeWinnerChangesWrite = NativeWinnerChangesF (O.Field O.SqlInt8) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
nativewinnerchangesTable :: O.Table NativeWinnerChangesWrite NativeWinnerChangesRead
nativewinnerchangesTable = O.table "native_winner_changes" $ pNativeWinnerChanges NativeWinnerChanges
  { nativewinnerchangesCriticalSequence = O.requiredTableField "critical_sequence"
  , nativewinnerchangesPreviousTxid = O.requiredTableField "previous_txid"
  , nativewinnerchangesWinnerTxid = O.requiredTableField "winner_txid"
  , nativewinnerchangesPreviousObservation = O.requiredTableField "previous_observation"
  , nativewinnerchangesObservationJson = O.requiredTableField "observation_json"
  , nativewinnerchangesEvidenceHash = O.requiredTableField "evidence_hash"
  , nativewinnerchangesFeeDelta = O.requiredTableField "fee_delta"
  }

-- Exact projections from persisted rows into the shared economic records.
-- These grant no database or payment capability.
asObligation :: Obligations -> Domain.Obligation
asObligation row = Domain.Obligation (obligationsId row) (obligationsOrderId row)
  (obligationsDepositId row) (obligationsKind row) (obligationsAsset row)
  (obligationsAmount row) (obligationsRecipient row)

asAttempt :: Attempts -> Text -> Domain.Attempt
asAttempt row chain = Domain.Attempt (attemptsTxid row) (attemptsIntentId row) chain
  (attemptsSignedBytes row) (attemptsPolicyJson row) (attemptsFeeLimit row)
  (attemptsState row) (attemptsCriticalSequence row)
