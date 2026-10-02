{-# OPTIONS_GHC -Wno-orphans #-}
-- Test-only SQLite instances retained until their unique contracts are ported.
module Bridge.Legacy.Recovery () where
import Bridge.Legacy.PaymentLifecycle ()
import Bridge.Recovery
import Bridge.Legacy.Reconciliation
import Bridge.Ledger
import Database.SQLite.Simple

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
