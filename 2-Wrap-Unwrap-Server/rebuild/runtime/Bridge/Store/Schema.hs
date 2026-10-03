{-# LANGUAGE TemplateHaskell #-}
-- Existing schema, projected only as needed. No row operation lives here.
module Bridge.Store.Schema where
import Data.Int (Int64)
import Data.Text (Text)
import Data.Profunctor.Product (p2,p3,p5)
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
