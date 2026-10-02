module Bridge.Postgres.CoveredSource (approveWith) where

import Bridge.Config (Config)
import Bridge.Types
import Bridge.Ledger.Model (Obligation(..),Deposit(..),SourceCheck(..))
import Bridge.Postgres.Ledger (Ledger,readiness)
import Bridge.Postgres.PaymentStore (Store(..))
import qualified Bridge.Postgres.Source as Source
import qualified Bridge.Postgres.Reconciliation as Custody
import Bridge.Reorg (NativeSourceStore(..),inspectNativeSourceWith)
import Bridge.Settlement (PaymentTransport(..),reconcilePaymentsWith)
import Bridge.RPC (fieldValue)
import Data.Aeson (Value,object,(.=))
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T

-- Explicit operator approval revives the original suspended obligation only.
-- It never resumes intake, signs, broadcasts, marks a deposit eligible or books
-- another capital allocation. Every effect still traverses the existing engine.
approveWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> Text -> Int64 -> Text -> IO Value
approveWith clock transport cfg ledger intent loss reason = do
  require (loss>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
  readiness ledger >>= \health->require (not $ available health) "pause_before_operator_action"
  old <- Source.coveredApproval ledger intent loss
  case old of
    Just saved->require (saved==reason) "source_approval_conflict"
    Nothing->do
      ob <- Source.coveredObligation ledger intent loss
      let store=Store ledger
      paymentIdentity transport
      payments <- reconcilePaymentsWith transport cfg store
      attempts <- fieldValue "attempts" payments :: IO [Value]
      failures <- mapM (fieldValue "error") attempts :: IO [Maybe Text]
      require (all (==Nothing) failures) "source_approval_payment_requires_review"
      _ <- Custody.reconcileCustodyWith clock transport cfg ledger
      candidates <- sourceCandidates store
      require (length candidates<=1000) "source_recovery_backlog"
      source <- case filter ((==obligationDeposit ob).depositId) candidates of
        [row]->pure row
        _->reject "source_loss_not_proven"
      proof <- inspectNativeSourceWith transport cfg store source >>= \case
        SourceMissing evidence->pure evidence
        _->reject "source_loss_not_proven"
      now <- clock
      Source.coveredRecord ledger intent loss now reason proof
  pure $ object["approvedCoveredSource" .= intent,"lossRecoverySequence" .= loss
    ,"paused" .= True,"signedOrSent" .= False]
