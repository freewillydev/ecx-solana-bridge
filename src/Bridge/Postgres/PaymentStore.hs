module Bridge.Postgres.PaymentStore (Store(..), pendingAttempts) where

import Bridge.Types
import Bridge.Ledger (Attempt(..),Obligation(..),Deposit(..))
import Bridge.Settlement (PaymentStore(..),SettlementStore(..))
import Control.Exception (IOException,catch,try)
import Data.Aeson (Value,object,(.=))
import qualified Bridge.Postgres.Settlement as S
import qualified Bridge.Postgres.Retry as Retry
import qualified Bridge.Postgres.Source as Source
import Bridge.Reorg (NativeSourceStore(..),NativeSettlementStore(..))
import qualified Bridge.Postgres.NativeRecovery as NativeRecovery
import Bridge.Recovery (CancellationStore(..),NativeLockStore(..),SourceRecoveryStore(..))
import qualified Bridge.Postgres.Cancellation as Cancellation
import Bridge.Payment (PreparationStore(..))
import Bridge.Deposit (DepositStore(..))
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Postgres.Preparation as P
import Bridge.Reconciliation (CustodyStore(..),View(..),inspectCustodyWith)
import qualified Bridge.Postgres.Custody as C
import qualified Bridge.Postgres.Observation as Observation
import Data.Int (Int64)
import qualified Bridge.Postgres.NativeFamily as NativeFamily
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Data.Aeson (FromJSON,eitherDecodeStrict')
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Opaleye as O

newtype Store = Store Ledger

instance PaymentStore Store where
  paymentObligation (Store ledger) oid = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable obligationsTable
      O.where_ (obligationsId row O..== O.sqlStrictText oid)
      pure row
      :: IO [Obligations]
    case rows of [row]->pure (obligation row); _->reject "obligation_not_found"
  paymentSourceContext (Store ledger) expected = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      ob <- O.selectTable obligationsTable
      order <- O.selectTable ordersTable
      deposit <- O.selectTable depositsTable
      O.where_ (obligationsId ob O..== O.sqlStrictText (obligationId expected) O..&&
        obligationsOrderId ob O..== ordersId order O..&& obligationsDepositId ob O..== depositsId deposit)
      pure (ob,order,deposit)
      :: IO [(Obligations,Orders,Deposits)]
    (ob,order,deposit) <- case rows of [row]->pure row; _->reject "source_deposit_missing"
    require (obligation ob==expected) "obligation_mismatch"
    request <- stored (ordersRequestJson order)
    policy <- stored (ordersPolicyJson order)
    instruction <- maybe (reject "source_instruction_missing") pure (ordersInstruction order)
    let asset=sourceAsset (direction request)
    require (depositsOrderId deposit==Just (obligationOrder expected) && depositsAsset deposit==T.pack(show asset)) "source_binding_mismatch"
    quantity <- either reject pure (amount $ toInteger $ depositsAmount deposit)
    require (depositsConfirmations deposit>=0 && toInteger (depositsConfirmations deposit)<=toInteger(maxBound::Int)) "source_depth_overflow"
    pure (Deposit (depositsId deposit) (depositsOrderId deposit) asset quantity (depositsAnchor deposit)
      (fromIntegral $ depositsConfirmations deposit) (depositsEligible deposit==1) (depositsFirstSeen deposit),request,policy,instruction)
  paymentNativeFamily (Store ledger) intent = ledgerAction ledger $ \connection->NativeFamily.familyC connection intent

pendingAttempts :: Store -> IO [Attempt]
pendingAttempts (Store ledger) = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_ (attemptsIntentId a O..== intentsId i O..&& intentsResolved i O..== O.sqlInt8 0)
    pure (a,intentsChain i)
    :: IO [(Attempts,Text)]
  expired <- O.runSelect connection (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
  pure [attempt a chain | (a,chain)<-sortOn (\(a,_)->(attemptsPreparationGeneration a,attemptsCriticalSequence a,attemptsTxid a)) rows,not(any ((==attemptsTxid a).solanaexpiriesTxid) expired)]

obligation :: Obligations -> Obligation
obligation row = Obligation (obligationsId row) (obligationsOrderId row) (obligationsDepositId row) (obligationsKind row) (obligationsAsset row) (obligationsAmount row) (obligationsRecipient row)
attempt :: Attempts -> Text -> Attempt
attempt row chain = Attempt (attemptsTxid row) (attemptsIntentId row) chain (attemptsSignedBytes row) (attemptsPolicyJson row) (attemptsFeeLimit row) (attemptsState row) (attemptsCriticalSequence row)
stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8

instance CustodyStore Store where
  custodyView cfg (Store ledger) now losses = do
    snapshot <- C.readSnapshot cfg ledger now losses
    pure (View (C.revision snapshot) (C.totals snapshot) (C.heads snapshot) (C.slot snapshot))
  custodyPending = pendingAttempts
  custodyProof (Store ledger) = C.eventProof ledger
  custodyDepth (Store ledger) = Observation.maximumNativeDepth ledger
  custodyRevision (Store ledger) = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection (fmap custodycheckRevision $ O.selectTable custodycheckTable) :: IO [Int64]
    case rows of [revision]->pure revision; _->reject "custody_check_missing"
  custodyHasEvent (Store ledger) txid chain = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable chaineventsTable
      O.where_ (chaineventsEventId row O..== O.sqlStrictText txid O..&&
        (chaineventsChain row O..== O.sqlStrictText chain O..|| chaineventsChain row O..== O.sqlStrictText (if chain=="Solana" then "SolanaOperating" else "Native")))
      pure (chaineventsEventId row)
      :: IO [Text]
    pure (not $ null rows)


instance PreparationStore Store where
  preparationPause (Store ledger) = pause ledger
  preparationReadiness (Store ledger) = readiness ledger
  preparationOrderPolicy (Store ledger) = P.orderPolicy ledger
  preparationCostLimits (Store ledger) = P.costLimits ledger
  preparationAttempts = pendingAttempts
  preparationPending (Store ledger) = P.pending ledger
  preparationBegin (Store ledger) = P.begin ledger
  preparationActive (Store ledger) = P.active ledger
  preparationStoreDraft (Store ledger) = P.storeDraft ledger
  preparationStoreAttempt (Store ledger) = P.storeAttempt ledger

instance SettlementStore Store where
  settlementRetryReasons (Store ledger) = Retry.reasons ledger
  settlementRetryAttempts (Store ledger) = Retry.candidates ledger
  settlementRecordRetry (Store ledger) = Retry.recordApproval ledger
  settlementWinner (Store ledger) intent = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable attemptsTable
      O.where_(attemptsIntentId row O..== O.sqlStrictText intent O..&& attemptsState row O..== O.sqlStrictText "settled")
      pure(attemptsTxid row)
      :: IO [Text]
    case rows of [winner]->pure winner; _->reject "settled_payment_missing"
  settlementReady (Store ledger) = ledgerAction ledger $ \c->do
    rows <- O.runSelect c $ O.limit 100 $ do
      row <- O.selectTable obligationsTable
      O.where_ (obligationsStatus row O..== O.sqlStrictText "ready")
      pure row
      :: IO [Obligations]
    pure(map obligation rows)
  settlementBusy (Store ledger) chain = ledgerAction ledger $ \c->do
    rows <- O.runSelect c $ do
      row <- O.selectTable intentsTable
      O.where_ (intentsChain row O..== O.sqlStrictText chain O..&& intentsResolved row O..== O.sqlInt8 0)
      pure(intentsId row)
      :: IO [Text]
    pure(not $ null rows)
  settlementRefresh (Store ledger) = Observation.refreshDeposit ledger
  settlementRecord (Store ledger) = S.recordSettlement ledger
  settlementFailed (Store ledger) = S.recordFailedSolana ledger
  settlementExpiry (Store ledger) = S.recordSolanaExpiry ledger
  settlementExpiryOrigins (Store ledger) = S.checkExpiryOrigins ledger
  settlementBroadcast (Store ledger) = S.markBroadcastIntent ledger
  settlementAuthorize (Store ledger) = S.authorizeRecordedSend ledger

instance DepositStore Store where
  depositRead (Store ledger) capability oid = do
    cap <- either reject pure(capabilityHash capability)
    ledgerAction ledger (\connection->Order.readOrderC connection cap oid)
  depositExpose (Store ledger) = Order.exposeOrder ledger
  depositPause (Store ledger) = pause ledger
  depositReadiness (Store ledger) = readiness ledger

instance CancellationStore Store where
  cancellationReconcile clock transport cfg store@(Store ledger) = do
    expected <- custodyRevision store
    result <- try (inspectCustodyWith clock transport cfg store False `catch` (\(_::IOException)->reject "custody_rpc_unavailable")) :: IO (Either BridgeError (Int64,Int64,Bool,Value))
    case result of
      Right (revision,at,matches,report)->do
        C.recordCheck ledger revision at (if matches then Nothing else Just "custody_balance_mismatch") (Just report)
        pure(object["matches" .= matches])
      Left(BridgeError code)->do
        at <- clock
        C.recordCheck ledger expected at (Just code) Nothing
        pure(object["matches" .= False,"error" .= code])
  cancellationRead (Store ledger) = Cancellation.readCancellation ledger
  cancellationCheckFresh (Store ledger) = Cancellation.checkFresh ledger
  cancellationBegin (Store ledger) = Cancellation.begin ledger
  cancellationFinish (Store ledger) = Cancellation.finish ledger

instance NativeLockStore Store where
  nativeLockAudit (Store ledger) subject = ledgerAction ledger $ \connection->do
    _ <- O.runInsert connection O.Insert
      {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "native_locks_restored") (O.sqlStrictText subject)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()

instance SourceRecoveryStore Store where
  recoveryApproval (Store ledger) = Source.recoveryApproval ledger
  recoveryObligation (Store ledger) = Source.recoveryObligation ledger
  recoveryRecord (Store ledger) = Source.recoveryRecord ledger
  recoveryReconcile = cancellationReconcile

instance NativeSourceStore Store where
  sourceCandidates (Store ledger) = Source.candidates ledger
  sourcePause (Store ledger) = pause ledger
  sourceRecordCheck (Store ledger) = Source.recordCheck ledger
  sourceOrderBinding (Store ledger) = Source.orderBinding ledger
  sourceEventEvidence (Store ledger) = Source.eventEvidence ledger

instance NativeSettlementStore Store where
  recoveryCandidates (Store ledger) = NativeRecovery.candidates ledger
  recoveryPause (Store ledger) = pause ledger
  recoveryObservation (Store ledger) = NativeRecovery.observation ledger
  recoveryCheck (Store ledger) = NativeRecovery.recordCheck ledger
