{-# OPTIONS_GHC -Wno-orphans #-}
-- Legacy SQLite adapters; the production algorithms do not import this module.
module Bridge.Legacy.ObservationPreparation () where
import Bridge.Ledger
import qualified Bridge.Ledger as Legacy
import Bridge.Budget (orderCostLimits)
import Bridge.Payment
import Bridge.Observer
import Bridge.Types
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Control.Monad (forM_)
import Database.SQLite.Simple

stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8

instance PreparationStore Ledger where
  preparationPause = pause
  preparationReadiness = readiness
  preparationOrderPolicy ledger oid = do
    rows <- ledgerAction ledger $ \db->query db "SELECT policy_json FROM orders WHERE id=?" (Only oid) :: IO [Only Text]
    case rows of [Only value]->stored value; _->reject "order_not_found"
  preparationCostLimits ledger oid = ledgerAction ledger $ \db->orderCostLimits db oid
  preparationAttempts = pendingAttempts
  preparationPending = pendingPreparations
  preparationBegin = beginPreparation
  preparationActive = activePreparationGeneration
  preparationStoreDraft = storeDraft
  preparationStoreAttempt = storeAttempt

instance ObserverLedger Ledger where
  observerReadCheckpoint = Legacy.readCheckpoint
  observerMaximumNativeDepth = Legacy.maximumNativeDepth
  observerCommitScan = Legacy.commitScan
  observerLookupInstruction = Legacy.lookupInstruction
  observerPendingVerification = Legacy.pendingVerification
  observerRecordScanFailure = Legacy.recordScanFailure
  observerScannerHealth = Legacy.scannerHealth
  observerPromoteObserved ledger = do
    candidates <- Legacy.ledgerAction ledger $ \db -> query_ db "SELECT d.id FROM deposits d JOIN orders o ON o.id=d.order_id WHERE d.eligible=1 AND d.allocated=0 AND o.status IN('Provisioning','AwaitingDeposit') ORDER BY d.first_seen,d.id LIMIT 1000" :: IO [Only Text]
    now <- epochSeconds
    forM_ candidates $ \(Only did)->Legacy.promoteDeposit ledger now did >> pure ()
