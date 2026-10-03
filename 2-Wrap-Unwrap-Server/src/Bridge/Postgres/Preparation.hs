module Bridge.Postgres.Preparation
  ( orderPolicy, costLimits, begin, active, activeC, storeDraft, storeAttempt, pending, pendingC, signingDecisionC, nativeLockAudit
  , readCancellation, beginCancellation, finishCancellation ) where

import Bridge.Config
import Bridge.Types
import Bridge.Ledger.Model (encodeRecord, decodePaymentRecord, CostLimits(..), Obligation(..), Preparation(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema hiding (deploymentFingerprint)
import qualified Bridge.Postgres.Source as Source
import Bridge.Postgres.Custody (freshC)
import Data.Aeson (Value(..))
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

orderPolicy :: Ledger -> Text -> IO PolicySnapshot
orderPolicy ledger oid = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ fmap ordersPolicyJson $ whereRows (\row->ordersId row O..== text oid) (O.selectTable ordersTable) :: IO [Text]
  case rows of [value]->decodePaymentRecord value; _->reject "order_not_found"

costLimits :: Ledger -> Text -> IO CostLimits
costLimits ledger oid = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ whereRows (\row->ordercostlimitsOrderId row O..== text oid) (O.selectTable ordercostlimitsTable) :: IO [OrderCostLimits]
  case rows of
    [row]->CostLimits <$> quantity (ordercostlimitsNativeFee row) <*> quantity (ordercostlimitsSolanaFee row) <*> quantity (ordercostlimitsSolanaRent row)
    _->reject "order_cost_policy_missing"
 where quantity=either reject pure . amount . toInteger

context :: PG.Connection -> Obligation -> Text -> IO Obligations
context c expected chain = do
  rows <- O.runSelect c $ whereRows (\row->obligationsId row O..== text (obligationId expected)) (O.selectTable obligationsTable) :: IO [Obligations]
  row <- case rows of [row] | asObligation row==expected->pure row; _->reject "obligation_mismatch"
  require (chain==if obligationAsset expected=="Native" then "Native" else "Solana") "wrong_destination_chain"
  pure row

activeC :: PG.Connection -> Text -> IO Int64
activeC c intent = do
  rows <- O.runSelect c $ do
    p <- O.selectTable preparationsTable
    i <- O.selectTable intentsTable
    O.where_ (preparationsIntentId p O..== intentsId i O..&& intentsId i O..== text intent O..&& intentsResolved i O..== num 0 O..&& O.isNull(preparationsRetiredTxid p) O..&& preparationsCancelled p O..== num 0)
    pure (preparationsGeneration p)
    :: IO [Int64]
  generation <- case rows of [g]->pure g; _->reject "preparation_not_found"
  cancellations <- cancellationRowsC c intent generation
  require (null cancellations) "preparation_cancellation_pending"
  pure generation

active :: Ledger -> Text -> IO Int
active ledger intent = ledgerAction ledger $ \c->activeC c intent >>= generationInt

begin :: Ledger -> Config -> Obligation -> Text -> Int64 -> Text -> IO ()
begin ledger cfg expected chain limit policy = ledgerAction ledger $ \c->do
  ob <- context c expected chain
  require (limit>=0 && not(T.null policy) && T.length policy<=16384) "invalid_preparation"
  let intent=obligationId expected; feeAsset=if chain=="Native" then "Native" else "Sol"
  existing <- O.runSelect c $ do
    i <- O.selectTable intentsTable
    p <- O.selectTable preparationsTable
    f <- O.selectTable feereservationsTable
    O.where_ (intentsId i O..== text intent O..&& preparationsIntentId p O..== intentsId i O..&& feereservationsIntentId f O..== intentsId i O..&& intentsResolved i O..== num 0 O..&& O.isNull(preparationsRetiredTxid p) O..&& preparationsCancelled p O..== num 0)
    pure (intentsChain i,feereservationsAmount f,preparationsPolicyJson p)
    :: IO [(Text,Int64,Text)]
  case existing of
    [previous]->require (previous==(chain,limit,policy)) "preparation_conflict" >> activeC c intent >> pure ()
    []->do
      deployment <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
      require (map deploymentPaused deployment==[0]) "payouts_paused"
      sourceAllowed <- Source.authorizedC c intent
      require sourceAllowed "source_not_eligible"
      require (obligationsStatus ob=="ready") "obligation_not_ready"
      busy <- O.runSelect c $ whereRows (\row->intentsChain row O..== text chain O..&& intentsResolved row O..== num 0) (O.selectTable intentsTable) :: IO [Intents]
      require (null busy) "destination_payment_unresolved"
      old <- O.runSelect c $ whereRows (\row->intentsId row O..== text intent) (O.selectTable intentsTable) :: IO [Intents]
      generation <- case old of
        []->pure 0
        [previous] | intentsChain previous==chain && intentsResolved previous==1->do
          history <- O.runSelect c $ whereRows (\row->preparationsIntentId row O..== text intent) (O.selectTable preparationsTable) :: IO [Preparations]
          attempts <- O.runSelect c $ whereRows (\row->attemptsIntentId row O..== text intent) (O.selectTable attemptsTable) :: IO [Attempts]
          expiries <- O.runSelect c (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
          let prior=sortOn preparationsGeneration history
          require (not(null prior) && length prior<8 && map preparationsGeneration prior==[0..fromIntegral(length prior)-1] &&
            all (\row->preparationsRetiredTxid row/=Nothing || preparationsCancelled row==1) prior &&
            all (\row->any ((==attemptsTxid row).solanaexpiriesTxid) expiries) attempts) "preparation_retry_not_authorized"
          fees <- O.runSelect c $ whereRows (\row->feereservationsIntentId row O..== text intent) (O.selectTable feereservationsTable) :: IO [FeeReservations]
          case last prior of
            row | preparationsRetiredTxid row==Nothing && preparationsCancelled row==1->do
              completed <- cancellationRowsC c intent (preparationsGeneration row)
              require (map preparationcancellationsCompleted completed==[1] && map feereservationsReleased fees==[0]) "preparation_cancellation_not_complete"
            row | Just txid<-preparationsRetiredTxid row,preparationsCancelled row==0->do
              approved <- O.runSelect c $ whereRows (\r->solanaretryapprovalsExpiredTxid r O..== text txid) (O.selectTable solanaretryapprovalsTable) :: IO [SolanaRetryApprovals]
              require (chain=="Solana" && map solanaretryapprovalsExpiredTxid approved==[txid]) "solana_retry_not_authorized"
              require (map feereservationsReleased fees==[1]) "solana_retry_fee_hold_conflict"
            _->reject "preparation_retry_not_authorized"
          _ <- O.runUpdate c O.Update {O.uTable=feereservationsTable,O.uUpdateWith= \r->r {feereservationsReleased=num 1},O.uWhere= \r->feereservationsIntentId r O..== text intent,O.uReturning=O.rCount}
          pure(fromIntegral $ length prior)
        _->reject "previous_intent_not_resolved"
      transferOrderCosts c cfg (obligationOrder expected) (obligationKind expected) feeAsset limit
      if null old then do
        _ <- O.runInsert c O.Insert {O.iTable=intentsTable,O.iRows=[Intents (text intent) (text intent) (text chain) O.null (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        _ <- O.runInsert c O.Insert {O.iTable=feereservationsTable,O.iRows=[FeeReservations (text intent) (text feeAsset) (num limit) (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        pure ()
      else do
        _ <- O.runUpdate c O.Update {O.uTable=intentsTable,O.uUpdateWith= \r->r {intentsResolved=num 0},O.uWhere= \r->intentsId r O..== text intent,O.uReturning=O.rCount}
        _ <- O.runUpdate c O.Update {O.uTable=feereservationsTable,O.uUpdateWith= \r->r {feereservationsAmount=num limit,feereservationsReleased=num 0},O.uWhere= \r->feereservationsIntentId r O..== text intent,O.uReturning=O.rCount}
        pure ()
      _ <- O.runInsert c O.Insert {O.iTable=preparationsTable,O.iRows=[Preparations (text intent) (num generation) (text policy) O.null O.null (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=text "paying"},O.uWhere= \r->obligationsId r O..== text intent,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=reservationsTable,O.uUpdateWith= \r->r {reservationsPhase=text "payment"},O.uWhere= \r->reservationsOrderId r O..== text(obligationOrder expected) O..&& reservationsPhase r O..== text "obligation",O.uReturning=O.rCount}
      orderStatus c (obligationOrder expected) "Preparing"
    _->reject "duplicate_preparation"

storeDraft :: Ledger -> Text -> Text -> Int -> IO ()
storeDraft ledger intent draft generation = ledgerAction ledger $ \c->do
  require (not(T.null draft) && T.length draft<=200000) "invalid_preparation_draft"
  actual <- activeC c intent
  require (actual==fromIntegral generation) "preparation_generation_changed"
  rows <- O.runSelect c $ whereRows (\r->preparationsIntentId r O..== text intent O..&& preparationsGeneration r O..== num actual) (O.selectTable preparationsTable) :: IO [Preparations]
  case rows of
    [row] | preparationsDraftJson row==Nothing->do
      _ <- criticalSequence c
      _ <- O.runUpdate c O.Update {O.uTable=preparationsTable,O.uUpdateWith= \r->r {preparationsDraftJson=O.toNullable(text draft)},O.uWhere= \r->preparationsIntentId r O..== text intent O..&& preparationsGeneration r O..== num actual,O.uReturning=O.rCount}
      pure ()
    [row]->require (preparationsDraftJson row==Just draft) "preparation_draft_conflict"
    _->reject "preparation_not_found"

storeAttempt :: Ledger -> Obligation -> Text -> Text -> Text -> Text -> Int64 -> Maybe Text -> Int -> IO ()
storeAttempt ledger expected chain txid bytes policy limit common generation = ledgerAction ledger $ \c->do
  ob <- context c expected chain
  require (not(T.null bytes) && T.length bytes<=200000 && not(T.null policy) && T.length policy<=32768 && limit>=0) "invalid_attempt"
  actual <- activeC c (obligationId expected)
  require (actual==fromIntegral generation) "preparation_generation_changed"
  fees <- O.runSelect c $ whereRows (\r->feereservationsIntentId r O..== text(obligationId expected)) (O.selectTable feereservationsTable) :: IO [FeeReservations]
  require ([(feereservationsAmount r,feereservationsReleased r) | r<-fees]==[(limit,0)]) "payment_not_prepared"
  sourceAllowed <- Source.authorizedC c (obligationId expected)
  require sourceAllowed "source_not_eligible"
  require (obligationsStatus ob=="paying") "obligation_not_preparing"
  prior <- O.runSelect c $ whereRows (\r->attemptsIntentId r O..== text(obligationId expected) O..&& attemptsPreparationGeneration r O..== num actual) (O.selectTable attemptsTable) :: IO [Attempts]
  require (null prior) "attempt_already_recorded"
  _ <- O.runUpdate c O.Update {O.uTable=intentsTable,O.uUpdateWith= \r->r {intentsCommonInput=maybe O.null (O.toNullable . text) common},O.uWhere= \r->intentsId r O..== text(obligationId expected),O.uReturning=O.rCount}
  _ <- O.runInsert c O.Insert {O.iTable=attemptsTable,O.iRows=[Attempts (text txid) (text(obligationId expected)) (text bytes) (text policy) (num limit) (text "signed") O.null O.null (num actual)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  orderStatus c (obligationOrder expected) "Paying"

pending :: Ledger -> IO [Preparation]
pending ledger = ledgerAction ledger pendingC

pendingC :: PG.Connection -> IO [Preparation]
pendingC c = do
  rows <- O.runSelect c $ do
    p <- O.selectTable preparationsTable
    i <- O.selectTable intentsTable
    ob <- O.selectTable obligationsTable
    f <- O.selectTable feereservationsTable
    O.where_ (preparationsIntentId p O..== intentsId i O..&& intentsObligationId i O..== obligationsId ob O..&& feereservationsIntentId f O..== intentsId i O..&& intentsResolved i O..== num 0 O..&& O.isNull(preparationsRetiredTxid p) O..&& preparationsCancelled p O..== num 0)
    pure(p,i,ob,f)
    :: IO [(Preparations,Intents,Obligations,FeeReservations)]
  attempts <- O.runSelect c $ do
    attempt <- O.selectTable attemptsTable
    intent <- O.selectTable intentsTable
    O.where_ (attemptsIntentId attempt O..== intentsId intent O..&& intentsResolved intent O..== num 0)
    pure (attemptsIntentId attempt,attemptsPreparationGeneration attempt)
    :: IO [(Text,Int64)]
  mapM (\(p,i,ob,f)->Preparation (asObligation ob) (intentsChain i) (feereservationsAmount f) (preparationsPolicyJson p) (preparationsDraftJson p) <$> generationInt(preparationsGeneration p))
    [row | row@(p,i,_,_)<-rows,(intentsId i,preparationsGeneration p) `notElem` attempts]

orderStatus :: PG.Connection -> Text -> Text -> IO ()
orderStatus c oid status = do
  _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text status},O.uWhere= \r->ordersId r O..== text oid O..&& ordersStatus r O../= text "Paid",O.uReturning=O.rCount}
  pure ()
generationInt :: Int64 -> IO Int
generationInt g = require (g>=0 && g<=7) "preparation_generation_overflow" >> pure(fromIntegral g)
whereRows :: (a -> O.Field O.SqlBool) -> O.Select a -> O.Select a
whereRows predicate query = do row<-query; O.where_(predicate row); pure row
text :: Text -> O.Field O.SqlText
text = O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num = O.sqlInt8

-- Specific read-only signer operation. It accepts durable identity, never a
-- caller-supplied plan or transaction. No connection escapes the signer.
signingDecisionC :: PG.Connection -> Config -> Text -> Int -> IO (Preparation,PolicySnapshot)
signingDecisionC c cfg intent generation = do
  actual <- activeC c intent
  require (actual==fromIntegral generation) "preparation_generation_changed"
  rows <- pendingC c
  prepared <- case filter ((==intent).obligationId.preparationObligation) rows of
    [row]->pure row
    _->reject "preparation_not_unsigned"
  let ob=preparationObligation prepared
  sourceAllowed <- Source.authorizedC c intent
  require sourceAllowed "source_not_eligible"
  statuses <- O.runSelect c $ fmap obligationsStatus $ whereRows (\r->obligationsId r O..== text intent) (O.selectTable obligationsTable) :: IO [Text]
  require (statuses==["paying"] && preparationGeneration prepared==generation
    && preparationDraft prepared/=Nothing) "payment_not_prepared"
  fees <- O.runSelect c $ whereRows (\r->feereservationsIntentId r O..== text intent) (O.selectTable feereservationsTable) :: IO [FeeReservations]
  require ([(feereservationsAmount r,feereservationsReleased r) | r<-fees]==[(preparationFeeLimit prepared,0)]) "payment_not_prepared"
  policies <- O.runSelect c $ fmap ordersPolicyJson $ whereRows (\r->ordersId r O..== text(obligationOrder ob)) (O.selectTable ordersTable) :: IO [Text]
  policy <- case policies of [value]->decodePaymentRecord value; _->reject "order_not_found"
  require (deploymentFingerprint policy==fingerprint cfg) "payment_profile_mismatch"
  pure (prepared,policy)

nativeLockAudit :: Ledger -> Text -> IO ()
nativeLockAudit ledger subject = ledgerAction ledger $ \connection->do
  _ <- O.runInsert connection O.Insert
    {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "native_locks_restored") (O.sqlStrictText subject)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  pure ()

-- Unsigned cancellation shares the preparation generation and fee hold.
cancellationRowsC :: PG.Connection -> Text -> Int64 -> IO [PreparationCancellations]
cancellationRowsC c intent generation = O.runSelect c $ do
  r <- O.selectTable preparationcancellationsTable
  O.where_(preparationcancellationsIntentId r O..== text intent O..&& preparationcancellationsGeneration r O..== num generation)
  pure r
readCancellation :: Ledger -> Text -> Int -> IO (Maybe(Text,Text,Bool))
readCancellation ledger intent generation = ledgerAction ledger $ \c->do
  saved <- cancellationRowsC c intent (fromIntegral generation)
  case saved of
    []->pure Nothing
    [r]->pure(Just(preparationcancellationsReason r,preparationcancellationsCleanupJson r,preparationcancellationsCompleted r==1))
    _->reject "duplicate_preparation_cancellation"

paused :: PG.Connection -> IO ()
paused c = do
  state <- O.runSelect c(fmap deploymentPaused $ O.selectTable deploymentTable) :: IO [Int64]
  require(state==[1]) "pause_before_operator_action"

beginCancellation :: Ledger -> Preparation -> Int64 -> Text -> Value -> IO ()
beginCancellation ledger preparation now reason cleanup = ledgerAction ledger $ \c->do
  let intent=obligationId(preparationObligation preparation); generation=preparationGeneration preparation
      encoded=encodeRecord cleanup
  require(not(T.null $ T.strip reason) && T.length reason<=512 && cleanup/=Null && T.length encoded<=32768) "invalid_preparation_cancellation"
  paused c
  old <- cancellationRowsC c intent (fromIntegral generation)
  case old of
    [r]->require ((preparationcancellationsReason r,preparationcancellationsCleanupJson r)==(reason,encoded)) "preparation_cancellation_conflict"
    []->do
      freshC c now
      current <- pendingC c
      require(preparation `elem` current) "preparation_cancellation_not_expected"
      seqNo <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=preparationcancellationsTable,O.iRows=[PreparationCancellations (text intent) (num $ fromIntegral generation) (text reason) (text encoded) (num seqNo) (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      cancellationAudit c "preparation_cancellation_requested" intent generation
    _->reject "duplicate_preparation_cancellation"

finishCancellation :: Ledger -> Preparation -> IO ()
finishCancellation ledger preparation = ledgerAction ledger $ \c->do
  let ob=preparationObligation preparation;intent=obligationId ob;generation=preparationGeneration preparation
  paused c
  saved <- cancellationRowsC c intent (fromIntegral generation)
  case map preparationcancellationsCompleted saved of
    [1]->pure ()
    [0]->do
      current <- pendingC c
      require(preparation `elem` current) "preparation_cancellation_not_expected"
      fees <- O.runSelect c $ do
        r <- O.selectTable feereservationsTable
        O.where_(feereservationsIntentId r O..== text intent)
        pure(feereservationsAmount r,feereservationsReleased r)
        :: IO [(Int64,Int64)]
      require(fees==[(preparationFeeLimit preparation,0)]) "preparation_fee_hold_missing"
      source <- O.runSelect c $ do
        r <- O.selectTable depositsTable
        O.where_(depositsId r O..== text(obligationDeposit ob))
        pure(depositsEligible r)
        :: IO [Int64]
      eligible <- case source of [r] | r `elem` [0,1]->pure(r==1);_->reject "deposit_not_found"
      _ <- criticalSequence c
      _ <- O.runUpdate c O.Update {O.uTable=preparationcancellationsTable,O.uUpdateWith= \r->r {preparationcancellationsCompleted=num 1},O.uWhere= \r->preparationcancellationsIntentId r O..== text intent O..&& preparationcancellationsGeneration r O..== num(fromIntegral generation),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=preparationsTable,O.uUpdateWith= \r->r {preparationsCancelled=num 1},O.uWhere= \r->preparationsIntentId r O..== text intent O..&& preparationsGeneration r O..== num(fromIntegral generation),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=intentsTable,O.uUpdateWith= \r->r {intentsResolved=num 1},O.uWhere= \r->intentsId r O..== text intent,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=text(if eligible then "ready" else "review")},O.uWhere= \r->obligationsId r O..== text intent,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text(if eligible then "Ready" else "NeedsReview")},O.uWhere= \r->ordersId r O..== text(obligationOrder ob) O..&& ordersStatus r O../= text "Paid",O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=reservationsTable,O.uUpdateWith= \r->r {reservationsPhase=text "obligation"},O.uWhere= \r->reservationsOrderId r O..== text(obligationOrder ob) O..&& reservationsPhase r O..== text "payment",O.uReturning=O.rCount}
      cancellationAudit c "preparation_cancellation_completed" intent generation
    _->reject "preparation_cancellation_not_expected"
cancellationAudit :: PG.Connection -> Text -> Text -> Int -> IO ()
cancellationAudit c action intent generation = do
  _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text action) (text $ intent<>":"<>T.pack(show generation))],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  pure ()
