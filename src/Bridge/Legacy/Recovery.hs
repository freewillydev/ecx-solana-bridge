{-# OPTIONS_GHC -Wno-orphans #-}
module Bridge.Legacy.Recovery
  ( recoverDeployment, approveSourceRecovery, prepareNativeReplacement
  , coverSourceLoss, reconcileNativeLocks, cancelPreparation ) where
import Bridge.Legacy.PaymentLifecycle ()
import Bridge.Recovery
import Bridge.Legacy.Reconciliation
import Bridge.Reorg
import Bridge.Settlement
import Bridge.Observer (epochSeconds,observeOnce)
import Bridge.Native (nativeIdentity)
import Bridge.Ledger
import Bridge.Config
import Bridge.Types
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import Network.HTTP.Client (Manager)
import Database.SQLite.Simple

recoverDeployment :: Manager -> Config -> Ledger -> IO Value
recoverDeployment manager c ledger=do
  scans <- observeOnce manager c ledger
  epochSeconds >>= expireQuotes ledger
  sources <- reconcileNativeSources manager c ledger
  nativeSettlements <- reconcileNativeSettlements manager c ledger
  payments <- reconcilePayments manager c ledger
  locks <- reconcileNativeLocks manager c ledger
  custody <- reconcileCustody manager c ledger
  health <- readiness ledger
  pure $ object ["scanners" .= scans,"sources" .= sources,"nativeSettlements" .= nativeSettlements,"payments" .= payments,"nativeLocks" .= locks,"custody" .= custody
    ,"availability" .= health,"signedOrSent" .= False]

-- Explicitly restore only the work suspended by a recovered source. This is
-- neither a replacement approval nor permission to resume or send anything.

approveSourceRecovery :: Manager -> Config -> Ledger -> Text -> Int64 -> Text -> IO Value
approveSourceRecovery manager c ledger intent restoration reason=do
  _ <- recoverDeployment manager c ledger
  approveSourceRecoveryWith epochSeconds
    (realPaymentTransport manager c (const $ reject "unexpected_source_approval_backup")) c ledger intent restoration reason

prepareNativeReplacement :: Manager -> Config -> Ledger -> Text -> Amount -> Text -> IO Value
prepareNativeReplacement manager c ledger parent fee reason=do
  _ <- recoverDeployment manager c ledger
  prepareNativeReplacementWith epochSeconds
    (realPaymentTransport manager c (const $ reject "unexpected_replacement_backup")) c ledger parent fee reason

-- Storage capability for the complete explicit operator workflow. Chain
-- inspection and signing remain shared; callers cannot substitute arbitrary IO.

coverSourceLoss :: Manager -> Config -> Ledger -> Text -> Int64 -> LossCapital -> Text -> IO Value
coverSourceLoss manager c ledger did recovery capital reason=do
  _ <- recoverDeployment manager c ledger
  coverSourceLossWith epochSeconds
    (realPaymentTransport manager c (const $ reject "unexpected_loss_cover_backup")) c ledger did recovery capital reason

reconcileNativeLocks :: Manager -> Config -> Ledger -> IO Value
reconcileNativeLocks manager c=reconcileNativeLocksWith
  (realPaymentTransport manager c (const $ reject "unexpected_lock_recovery_backup"))
    {paymentIdentity=nativeIdentity manager c >> pure ()} c

cancelPreparation :: Manager -> Config -> Ledger -> Text -> Int -> Text -> IO Value
cancelPreparation manager c ledger intent generation reason=do
  _ <- observeOnce manager c ledger
  cancelPreparationWith epochSeconds
    (realPaymentTransport manager c (const $ reject "unexpected_cancellation_backup")) c ledger intent generation reason

instance SourceRecoveryStore Ledger where
  recoveryApproval = sourceRecoveryApproval
  recoveryObligation = sourceRecoveryObligation
  recoveryRecord = recordSourceRecoveryApproval
  recoveryReconcile = reconcileCustodyWith

instance NativeReplacementStore Ledger where
  replacementDecision = nativeReplacementDecision
  replacementParent = nativeReplacementParent
  replacementRecordDraft = recordNativeReplacementDraft
  replacementMember = nativeReplacementMember
  replacementSigningContext = nativeReplacementSigningContext
  replacementRecordMember = recordNativeReplacementMember
  replacementCustody = reconcileCustodyWith
  replacementFresh = checkCustodyFresh
  replacementCancel = recordNativeReplacementCancellation

-- Persist the reviewed unsigned template; this command cannot invoke a signer
-- or create another economic intent. Cancellation keeps the original payment.

instance LossCoverStore Ledger where
  lossReadiness = readiness
  lossDecision = sourceLossCover
  lossRecord = recordSourceLossCover

instance NativeLockStore Ledger where
  nativeLockAudit ledger subject = ledgerAction ledger $ \db->execute db "INSERT INTO audit(action,detail) VALUES('native_locks_restored',?)" (Only subject)

instance CancellationStore Ledger where
  cancellationReconcile = reconcileCustodyWith
  cancellationRead = preparationCancellation
  cancellationCheckFresh = checkCustodyFresh
  cancellationBegin = beginPreparationCancellation
  cancellationFinish = finishPreparationCancellation
