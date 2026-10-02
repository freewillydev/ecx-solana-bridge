module Bridge.Postgres.Settlement (recordSettlement,recordFailedSolana,markBroadcastIntent,authorizeRecordedSend,recordSolanaExpiry,checkExpiryOrigins, pendingAttempts, readObligation, sourceContext, winner, ready, busy
  , retryReasons, retryCandidates, approveRetry, createRefund) where

import Bridge.Config
import Bridge.RPC (fieldValue)
import Bridge.SolanaMessage (publicKey)
import Bridge.Types
import Bridge.Ledger.Model (encodeRecord, decodeRecord, decodePaymentRecord, Attempt(..),Obligation(..),Deposit(..),PaymentCosts(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import qualified Bridge.Postgres.Source as Source
import Control.Monad (forM,forM_,when)
import Data.List (sortOn,nub)
import qualified Bridge.Postgres.Replacement as Replacement
import Data.Aeson (object,(.=))
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

paymentContext :: PG.Connection -> Text -> IO (Attempts,Intents,Obligations,Deposits,Orders)
paymentContext c txid = do
  rows <- O.runSelect c $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    ob <- O.selectTable obligationsTable
    d <- O.selectTable depositsTable
    q <- O.selectTable ordersTable
    O.where_ (attemptsTxid a O..== text txid O..&& attemptsIntentId a O..== intentsId i O..&& intentsObligationId i O..== obligationsId ob O..&& obligationsDepositId ob O..== depositsId d O..&& obligationsOrderId ob O..== ordersId q)
    pure(a,i,ob,d,q)
    :: IO [(Attempts,Intents,Obligations,Deposits,Orders)]
  case rows of [row]->pure row; _->reject "settlement_not_expected"

recordSettlement :: Ledger -> Text -> PaymentCosts -> Text -> IO ()
recordSettlement ledger txid costs proof = ledgerAction ledger $ \c->do
  require (not(T.null proof) && T.length proof<=32768) "settlement_fee_or_evidence_invalid"
  let saved=encodeRecord(object["costs" .= costs,"proof" .= proof]); actual=toInteger(units $ networkFee costs)+toInteger(units $ accountRent costs)
  (a,i,ob,d,q) <- paymentContext c txid
  case attemptsState a of
    "settled"->require (attemptsObservationJson a==Just saved) "settlement_evidence_conflict"
    "broadcast_intent"->do
      require (units(networkFee costs)>0 && actual<=toInteger(attemptsFeeLimit a) && (obligationsAsset ob/="Native" || units(accountRent costs)==0)) "settlement_fee_or_evidence_invalid"
      fees <- O.runSelect c $ whereRows (\r->feereservationsIntentId r O..== text(intentsId i) O..&& feereservationsReleased r O..== num 0) (O.selectTable feereservationsTable) :: IO [FeeReservations]
      winners <- O.runSelect c $ whereRows (\r->attemptsIntentId r O..== text(intentsId i) O..&& attemptsState r O..== text "settled") (O.selectTable attemptsTable) :: IO [Attempts]
      let feeAsset=if obligationsAsset ob=="Native" then Native else Sol
      require (intentsResolved i==0 && null winners && obligationsStatus ob `elem` ["paying","review"] &&
        case fees of [f]->feereservationsAsset f==T.pack(show feeAsset) && feereservationsAmount f>=attemptsFeeLimit a; _->False) "payment_intent_not_settleable"
      quote <- decodePaymentRecord(ordersQuoteJson q)
      source <- parseAsset(depositsAsset d); destination <- parseAsset(obligationsAsset ob)
      let principal=toInteger(depositsAmount d); payout=toInteger(obligationsAmount ob)
          flow=if obligationsKind ob=="refund" then [(source,"principal",negate principal),(source,"external",principal)]
            else [(source,"principal",negate principal),(source,"float",toInteger(units $ net quote)),(source,"earned",toInteger(units $ fee quote)),(destination,"float",negate payout),(destination,"external",payout)]
      posting c ("settlement:"<>txid) "successful finalized payout" flow
      forM_ [("network-fee",networkFee costs),("account-rent",accountRent costs)] $ \(label,cost)->when (units cost>0) $
        posting c (label<>":"<>txid) label [(feeAsset,"operating",negate $ toInteger $ units cost),(feeAsset,"external",toInteger $ units cost)]
      resolve c a i ob "settled" saved "paid"
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text(if obligationsKind ob=="refund" then "Refunded" else "Paid"),ordersPayoutTx=O.toNullable(text txid)},O.uWhere= \r->ordersId r O..== text(ordersId q) O..&& (O.sqlBool(obligationsKind ob/="refund") O..|| ordersStatus r O../= text "Paid"),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=reservationsTable,O.uUpdateWith= \r->r {reservationsPhase=text "released"},O.uWhere= \r->reservationsOrderId r O..== text(ordersId q),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=operatingreservationsTable,O.uUpdateWith= \r->r {operatingreservationsPhase=text "released"},O.uWhere= \r->operatingreservationsOrderId r O..== text(ordersId q) O..&& (operatingreservationsPhase r O..== text "quote" O..|| operatingreservationsPhase r O..== text "obligation"),O.uReturning=O.rCount}
      pure ()
    _->reject "settlement_not_expected"

recordFailedSolana :: Ledger -> Text -> Int64 -> Text -> IO ()
recordFailedSolana ledger txid actualFee proof = ledgerAction ledger $ \c->do
  (a,i,ob,_,q) <- paymentContext c txid
  require (intentsChain i=="Solana") "failure_not_proven"
  case attemptsState a of
    "failed"->do
      charged <- O.runSelect c $ fmap postingsDelta $ whereRows (\r->postingsEventId r O..== text("failed-fee:"<>txid) O..&& postingsAccount r O..== text "external") (O.selectTable postingsTable) :: IO [Int64]
      require (attemptsObservationJson a==Just proof && charged==[actualFee]) "failure_evidence_conflict"
    "broadcast_intent"->do
      require (actualFee>0 && actualFee<=attemptsFeeLimit a && not(T.null proof) && T.length proof<=32768) "invalid_failure_evidence"
      posting c ("failed-fee:"<>txid) "finalized Solana failure network fee" [(Sol,"operating",negate $ toInteger actualFee),(Sol,"external",toInteger actualFee)]
      resolve c a i ob "failed" proof "review"
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text "NeedsReview"},O.uWhere= \r->ordersId r O..== text(ordersId q),O.uReturning=O.rCount}
      pure ()
    _->reject "failure_not_proven"

resolve :: PG.Connection -> Attempts -> Intents -> Obligations -> Text -> Text -> Text -> IO ()
resolve c a i ob state proof status = do
  _ <- O.runUpdate c O.Update {O.uTable=attemptsTable,O.uUpdateWith= \r->r {attemptsState=text state,attemptsObservationJson=O.toNullable(text proof)},O.uWhere= \r->attemptsTxid r O..== text(attemptsTxid a),O.uReturning=O.rCount}
  _ <- O.runUpdate c O.Update {O.uTable=feereservationsTable,O.uUpdateWith= \r->r {feereservationsReleased=num 1},O.uWhere= \r->feereservationsIntentId r O..== text(intentsId i),O.uReturning=O.rCount}
  _ <- O.runUpdate c O.Update {O.uTable=intentsTable,O.uUpdateWith= \r->r {intentsResolved=num 1},O.uWhere= \r->intentsId r O..== text(intentsId i),O.uReturning=O.rCount}
  _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=text status},O.uWhere= \r->obligationsId r O..== text(obligationsId ob),O.uReturning=O.rCount}
  pure ()

sourceCoverage :: PG.Connection -> Text -> Int64 -> IO Int64
sourceCoverage c intent original = do
  rows <- O.runSelect c $ fmap sourcerecoveryapprovalsCriticalSequence $ whereRows (\r->sourcerecoveryapprovalsObligationId r O..== text intent) (O.selectTable sourcerecoveryapprovalsTable) :: IO [Int64]
  pure(maximum(original:rows))

nativeSendChoice :: PG.Connection -> Attempts -> Intents -> IO ()
nativeSendChoice c a i = when (intentsChain i=="Native") $ do
  family <- O.runSelect c $ whereRows (\r->attemptsIntentId r O..== text(intentsId i)) (O.selectTable attemptsTable) :: IO [Attempts]
  -- Family fee limits are fixed; replacement member sequences supply chronology.
  members <- O.runSelect c (O.selectTable nativereplacementmembersTable) :: IO [NativeReplacementMembers]
  let descendants=[m | m<-members,any ((==nativereplacementmembersTxid m).attemptsTxid) family]
      latest=case descendants of
        []->case family of
          [first]->Just(attemptsTxid first)
          _->Nothing
        _->Just(nativereplacementmembersTxid $ foldr1 (\x y->if nativereplacementmembersCriticalSequence x>nativereplacementmembersCriticalSequence y then x else y) descendants)
  require (latest==Just(attemptsTxid a)) "native_replacement_not_current"
  drafts <- O.runSelect c (O.selectTable nativereplacementdraftsTable) :: IO [NativeReplacementDrafts]
  cancellations <- O.runSelect c (O.selectTable nativereplacementcancellationsTable) :: IO [NativeReplacementCancellations]
  require (all (\d->not(any ((==nativereplacementdraftsParentTxid d).attemptsTxid) family) ||
    any ((==nativereplacementdraftsCriticalSequence d).nativereplacementcancellationsDraftSequence) cancellations ||
    any ((==nativereplacementdraftsCriticalSequence d).nativereplacementmembersDraftSequence) members) drafts) "native_replacement_draft_pending"

markBroadcastIntent :: Ledger -> Text -> IO Int64
markBroadcastIntent ledger txid = ledgerAction ledger $ \c->do
  (a,i,_,_,_) <- paymentContext c txid
  nativeSendChoice c a i
  case (attemptsState a,attemptsCriticalSequence a) of
    ("broadcast_intent",Just sequenceNo)->sourceCoverage c (intentsId i) sequenceNo
    ("signed",_)->do
      sourceAllowed <- Source.authorizedC c (intentsId i)
      require sourceAllowed "source_not_eligible"
      deployment <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
      require (map deploymentPaused deployment==[0]) "payouts_paused"
      sequenceNo <- criticalSequence c
      _ <- O.runUpdate c O.Update {O.uTable=attemptsTable,O.uUpdateWith= \r->r {attemptsState=text "broadcast_intent",attemptsCriticalSequence=O.toNullable(num sequenceNo)},O.uWhere= \r->attemptsTxid r O..== text txid,O.uReturning=O.rCount}
      pure sequenceNo
    _->reject "attempt_not_sendable"

authorizeRecordedSend :: Ledger -> Bool -> Text -> IO Attempt
authorizeRecordedSend ledger remote txid = ledgerAction ledger $ \c->do
  (a,i,ob,_,_) <- paymentContext c txid
  require (intentsResolved i==0 && attemptsState a=="broadcast_intent") "broadcast_intent_required"
  sequenceNo <- maybe (reject "broadcast_intent_required") pure(attemptsCriticalSequence a)
  needed <- sourceCoverage c (intentsId i) sequenceNo
  deployment <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
  require (not remote || case deployment of [r]->deploymentBackupSequence r>=needed; _->False) "backup_pending"
  sourceAllowed <- Source.authorizedC c (intentsId i)
  require (sourceAllowed && obligationsStatus ob=="paying") "source_not_eligible"
  require (map deploymentPaused deployment==[0]) "payouts_paused"
  nativeSendChoice c a i
  pure(asAttempt a (intentsChain i))

parseAsset :: Text -> IO Asset
parseAsset "Native"=pure Native
parseAsset "Wrapped"=pure Wrapped
parseAsset _=reject "invalid_payout_asset"
whereRows :: (a -> O.Field O.SqlBool) -> O.Select a -> O.Select a
whereRows predicate query = do row<-query; O.where_(predicate row); pure row
text :: Text -> O.Field O.SqlText
text=O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num=O.sqlInt8

checkExpiryOrigins :: Ledger -> Config -> IO ()
checkExpiryOrigins ledger cfg = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ whereRows (\r->scanoriginsChain r O..== text "Solana" O..|| scanoriginsChain r O..== text "SolanaOperating") (O.selectTable scanoriginsTable) :: IO [ScanOrigins]
  require (length rows==2 && all (\r->Just(scanoriginsAnchor r)==if scanoriginsChain r=="Solana" then solanaHistoryStart cfg else solanaOperatingHistoryStart cfg) rows) "expiry_scan_origin_mismatch"

recordSolanaExpiry :: Ledger -> Attempt -> Text -> IO ()
recordSolanaExpiry ledger expected proof = ledgerAction ledger $ \c->do
  require (attemptChain expected=="Solana" && attemptState expected `elem` ["signed","broadcast_intent"] && not(T.null proof) && T.length proof<=200000) "invalid_solana_expiry"
  previous <- O.runSelect c $ whereRows (\r->solanaexpiriesTxid r O..== text(attemptId expected)) (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
  case previous of
    [row]->require (solanaexpiriesProofJson row==proof) "expiry_evidence_conflict"
    []->do
      (a,i,ob,_,q) <- paymentContext c (attemptId expected)
      require (intentsResolved i==0 && asAttempt a (intentsChain i)==expected) "expiry_attempt_changed"
      family <- O.runSelect c $ whereRows (\r->attemptsIntentId r O..== text(intentsId i)) (O.selectTable attemptsTable) :: IO [Attempts]
      expiries <- O.runSelect c (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
      require ([attemptsTxid r | r<-family,not(any ((==attemptsTxid r).solanaexpiriesTxid) expiries)]==[attemptId expected]) "expiry_attempt_changed"
      preparation <- O.runSelect c $ whereRows (\r->preparationsIntentId r O..== text(intentsId i) O..&& preparationsGeneration r O..== num(attemptsPreparationGeneration a) O..&& O.isNull(preparationsRetiredTxid r) O..&& preparationsCancelled r O..== num 0) (O.selectTable preparationsTable) :: IO [Preparations]
      require (length preparation==1) "expiry_preparation_missing"
      sequenceNo <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=solanaexpiriesTable,O.iRows=[SolanaExpiries (text $ attemptId expected) (text proof) (num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runUpdate c O.Update {O.uTable=preparationsTable,O.uUpdateWith= \r->r {preparationsRetiredTxid=O.toNullable(text $ attemptId expected)},O.uWhere= \r->preparationsIntentId r O..== text(intentsId i) O..&& O.isNull(preparationsRetiredTxid r) O..&& preparationsCancelled r O..== num 0,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=attemptsTable,O.uUpdateWith= \r->r {attemptsState=text "review",attemptsObservationJson=O.toNullable(text proof)},O.uWhere= \r->attemptsTxid r O..== text(attemptId expected),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=feereservationsTable,O.uUpdateWith= \r->r {feereservationsReleased=num 1},O.uWhere= \r->feereservationsIntentId r O..== text(intentsId i),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=intentsTable,O.uUpdateWith= \r->r {intentsResolved=num 1},O.uWhere= \r->intentsId r O..== text(intentsId i),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=text "review"},O.uWhere= \r->obligationsId r O..== text(obligationsId ob) O..&& obligationsStatus r O..== text "paying",O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text "NeedsReview"},O.uWhere= \r->ordersId r O..== text(ordersId q) O..&& ordersStatus r O../= text "Paid",O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "solana_expiry_verified") (text $ attemptId expected)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    _->reject "duplicate_expiry"

readObligation :: Ledger -> Text -> IO Obligation
readObligation ledger oid = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable obligationsTable
    O.where_ (obligationsId row O..== O.sqlStrictText oid)
    pure row
    :: IO [Obligations]
  case rows of [row]->pure (asObligation row); _->reject "obligation_not_found"
sourceContext :: Ledger -> Obligation -> IO (Deposit,OrderRequest,PolicySnapshot,Text)
sourceContext ledger expected = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    ob <- O.selectTable obligationsTable
    order <- O.selectTable ordersTable
    deposit <- O.selectTable depositsTable
    O.where_ (obligationsId ob O..== O.sqlStrictText (obligationId expected) O..&&
      obligationsOrderId ob O..== ordersId order O..&& obligationsDepositId ob O..== depositsId deposit)
    pure (ob,order,deposit)
    :: IO [(Obligations,Orders,Deposits)]
  (ob,order,deposit) <- case rows of [row]->pure row; _->reject "source_deposit_missing"
  require (asObligation ob==expected) "obligation_mismatch"
  request <- decodePaymentRecord (ordersRequestJson order)
  policy <- decodePaymentRecord (ordersPolicyJson order)
  instruction <- maybe (reject "source_instruction_missing") pure (ordersInstruction order)
  let asset=sourceAsset (direction request)
  require (depositsOrderId deposit==Just (obligationOrder expected) && depositsAsset deposit==T.pack(show asset)) "source_binding_mismatch"
  quantity <- either reject pure (amount $ toInteger $ depositsAmount deposit)
  require (depositsConfirmations deposit>=0 && toInteger (depositsConfirmations deposit)<=toInteger(maxBound::Int)) "source_depth_overflow"
  pure (Deposit (depositsId deposit) (depositsOrderId deposit) asset quantity (depositsAnchor deposit)
    (fromIntegral $ depositsConfirmations deposit) (depositsEligible deposit==1) (depositsFirstSeen deposit),request,policy,instruction)

pendingAttempts :: Ledger -> IO [Attempt]
pendingAttempts ledger = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_ (attemptsIntentId a O..== intentsId i O..&& intentsResolved i O..== O.sqlInt8 0)
    pure (a,intentsChain i)
    :: IO [(Attempts,Text)]
  expired <- O.runSelect connection (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
  native <- fmap concat $ forM (nub [attemptsIntentId a | (a,chain)<-rows,chain=="Native"]) (Replacement.familyC connection)
  -- A newly signed replacement has no broadcast sequence yet. Sorting on that
  -- nullable field puts it before its parent; lineage readers require fee order.
  -- Use the same verified family order as signing, settlement and recovery.
  pure $ native <> [asAttempt a chain | (a,chain)<-sortOn (\(a,_)->(attemptsPreparationGeneration a,attemptsCriticalSequence a,attemptsTxid a)) rows,chain/="Native",not(any ((==attemptsTxid a).solanaexpiriesTxid) expired)]

winner :: Ledger -> Text -> IO Text
winner ledger intent = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable attemptsTable
    O.where_(attemptsIntentId row O..== O.sqlStrictText intent O..&& attemptsState row O..== O.sqlStrictText "settled")
    pure(attemptsTxid row)
    :: IO [Text]
  case rows of [txid]->pure txid; _->reject "settled_payment_missing"
ready :: Ledger -> IO [Obligation]
ready ledger = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ O.limit 100 $ do
    row <- O.selectTable obligationsTable
    O.where_ (obligationsStatus row O..== O.sqlStrictText "ready")
    pure row
    :: IO [Obligations]
  pure(map asObligation rows)
busy :: Ledger -> Text -> IO Bool
busy ledger chain = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    row <- O.selectTable intentsTable
    O.where_ (intentsChain row O..== O.sqlStrictText chain O..&& intentsResolved row O..== O.sqlInt8 0)
    pure(intentsId row)
    :: IO [Text]
  pure(not $ null rows)

-- Expired Solana attempts require an explicit retry decision.
retryReasons :: Ledger -> Text -> IO [Text]
retryReasons ledger txid = ledgerAction ledger $ \c->O.runSelect c $ do
  r <- O.selectTable solanaretryapprovalsTable
  O.where_(solanaretryapprovalsExpiredTxid r O..== O.sqlStrictText txid)
  pure(solanaretryapprovalsReason r)

retryContext :: PG.Connection -> Text -> IO (Attempts,Intents,Obligations,Deposits)
retryContext c txid = do
  rows <- O.runSelect c $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    ob <- O.selectTable obligationsTable
    d <- O.selectTable depositsTable
    e <- O.selectTable solanaexpiriesTable
    O.where_(attemptsTxid a O..== O.sqlStrictText txid O..&& attemptsTxid a O..== solanaexpiriesTxid e O..&& attemptsIntentId a O..== intentsId i O..&& intentsObligationId i O..== obligationsId ob O..&& obligationsDepositId ob O..== depositsId d)
    pure(a,i,ob,d)
    :: IO [(Attempts,Intents,Obligations,Deposits)]
  case rows of
    [(a,i,ob,d)]->do
      p <- O.runSelect c $ do
        r <- O.selectTable preparationsTable
        O.where_(preparationsIntentId r O..== O.sqlStrictText(intentsId i))
        pure(preparationsGeneration r)
        :: IO [Int64]
      latest <- O.runSelect c $ do
        r <- O.selectTable attemptsTable
        O.where_(attemptsIntentId r O..== O.sqlStrictText(intentsId i) O..&& attemptsPreparationGeneration r O..== O.sqlInt8(maximum(-1:p)))
        pure(attemptsTxid r)
        :: IO [Text]
      require (intentsChain i=="Solana" && intentsResolved i==1 && obligationsStatus ob=="review" && attemptsState a=="review" && latest==[txid]) "solana_retry_not_expected"
      pure(a,i,ob,d)
    _->reject "solana_retry_not_expected"

retryCandidates :: Ledger -> Text -> IO [Attempt]
retryCandidates ledger txid = ledgerAction ledger $ \c->do
  (a,i,_,_) <- retryContext c txid
  pure[asAttempt a (intentsChain i)]

approveRetry :: Ledger -> Text -> Text -> Text -> IO ()
approveRetry ledger txid reason proof = ledgerAction ledger $ \c->do
  require (not(T.null $ T.strip reason) && T.length reason<=512 && not(T.null proof) && T.length proof<=200000) "invalid_retry_approval"
  old <- O.runSelect c $ do
    r <- O.selectTable solanaretryapprovalsTable
    O.where_(solanaretryapprovalsExpiredTxid r O..== O.sqlStrictText txid)
    pure(solanaretryapprovalsReason r)
    :: IO [Text]
  case old of
    [previous]->require(previous==reason) "retry_approval_conflict"
    []->do
      health <- O.runSelect c(fmap deploymentPaused $ O.selectTable deploymentTable) :: IO [Int64]
      require(health==[1]) "pause_before_operator_action"
      (_,i,ob,d) <- retryContext c txid
      require(depositsEligible d==1) "solana_retry_not_expected"
      sequenceNo <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=solanaretryapprovalsTable,O.iRows=[SolanaRetryApprovals (O.sqlStrictText txid) (O.sqlStrictText reason) (O.sqlStrictText proof) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=O.sqlStrictText "ready"},O.uWhere= \r->obligationsId r O..== O.sqlStrictText(obligationsId ob),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=O.sqlStrictText "Ready"},O.uWhere= \r->ordersId r O..== O.sqlStrictText(obligationsOrderId ob),O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "solana_retry_approved") (O.sqlStrictText txid)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require(intentsId i==obligationsId ob) "intent_binding_mismatch"
    _->reject "duplicate_retry_approval"

-- Explicit operator/customer-resolution workflow, never an automatic change of
-- destination supplied by a caller. Solana refunds use immutable verified receipt
-- evidence, not a wallet address guessed before the payment exists.
createRefund :: Ledger -> Text -> IO Obligation
createRefund ledger did = ledgerAction ledger $ \c->do
  existing <- O.runSelect c $ do
    row <- O.selectTable obligationsTable
    O.where_(obligationsDepositId row O..== text did O..&& obligationsKind row O..== text "refund")
    pure row
    :: IO [Obligations]
  case existing of
    [row]->pure(asObligation row)
    []->do
      rows <- O.runSelect c $ do
        d <- O.selectTable depositsTable
        q <- O.selectTable ordersTable
        O.where_(depositsId d O..== text did O..&& O.matchNullable (O.sqlBool False) (\oid->oid O..== ordersId q) (depositsOrderId d))
        pure(d,q)
        :: IO [(Deposits,Orders)]
      (d,q) <- case rows of [row@(d,_)] | depositsEligible d==1->pure row; _->reject "refundable_deposit_not_found"
      request <- decodeRecord "corrupt_ledger_json" (ordersRequestJson q)
      let oid=ordersId q
      require (depositsAsset d==T.pack(show $ sourceAsset $ direction request)) "unsupported_refund_asset"
      unresolved <- O.runSelect c $ do
        i <- O.selectTable intentsTable
        o <- O.selectTable obligationsTable
        O.where_(intentsObligationId i O..== obligationsId o O..&& obligationsOrderId o O..== text oid O..&& intentsResolved i O..== O.sqlInt8 0)
        pure(intentsId i)
        :: IO [Text]
      require (null unresolved) "refund_would_race_payment"
      obligations <- O.runSelect c $ do
        row <- O.selectTable obligationsTable
        O.where_(obligationsOrderId row O..== text oid O..&& obligationsStatus row O../= text "cancelled")
        pure row
        :: IO [Obligations]
      require (all (\row->obligationsDepositId row==did || obligationsStatus row=="paid") obligations) "other_obligation_must_resolve_before_refund"
      let active=[row | row<-obligations,obligationsDepositId row==did]
      require (length active<=1 && all ((`elem` ["ready","review"]).obligationsStatus) active) "principal_already_resolved"
      destination <- if direction request==NativeToWrapped then pure(refund request) else case sourceOwner request of
        Just owner->pure owner
        Nothing->do
          signature <- maybe (reject "invalid_solana_deposit_id") pure(T.stripPrefix "solana:" did)
          evidence <- O.runSelect c $ do
            event <- O.selectTable chaineventsTable
            saved <- O.selectTable observationevidenceTable
            O.where_(chaineventsChain event O..== text "Solana" O..&& chaineventsEventId event O..== text signature O..&& chaineventsKind event O..== text "incoming" O..&& chaineventsNeedsReview event O..== O.sqlInt8 0 O..&& chaineventsEvidenceHash event O..== observationevidenceHash saved)
            pure(observationevidenceEvidenceJson saved)
            :: IO [Text]
          encoded <- case evidence of [value]->pure value; _->reject "verified_refund_owner_missing"
          proof <- decodeRecord "corrupt_ledger_json" encoded >>= fieldValue "proof"
          instruction <- fieldValue "instruction" proof
          require (ordersInstruction q==Just instruction) "refund_reference_mismatch"
          owner <- fieldValue "verifiedOwner" proof
          _ <- either reject pure(publicKey owner)
          pure owner
      forM_ active $ \old->do
        _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=text "cancelled"},O.uWhere= \r->obligationsId r O..== text(obligationsId old),O.uReturning=O.rCount}
        cancellation <- O.runSelect c $ do
          row <- O.selectTable preparationcancellationsTable
          i <- O.selectTable intentsTable
          O.where_(preparationcancellationsIntentId row O..== text(obligationsId old) O..&& intentsId i O..== preparationcancellationsIntentId row O..&& intentsResolved i O..== O.sqlInt8 1 O..&& preparationcancellationsCompleted row O..== O.sqlInt8 1)
          pure(preparationcancellationsGeneration row)
          :: IO [Int64]
        if null cancellation then pure () else do
          _ <- O.runUpdate c O.Update {O.uTable=feereservationsTable,O.uUpdateWith= \r->r {feereservationsReleased=O.sqlInt8 1},O.uWhere= \r->feereservationsIntentId r O..== text(obligationsId old),O.uReturning=O.rCount}
          pure ()
      let ob=Obligation ("refund:"<>did) oid did "refund" (depositsAsset d) (depositsAmount d) destination
      _ <- O.runInsert c O.Insert {O.iTable=obligationsTable,O.iRows=[Obligations (text $ obligationId ob) (text oid) (text did) (text "refund") (text $ depositsAsset d) (O.sqlInt8 $ depositsAmount d) (text destination) (text "ready")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runUpdate c O.Update {O.uTable=depositsTable,O.uUpdateWith= \r->r {depositsAllocated=O.sqlInt8 1},O.uWhere= \r->depositsId r O..== text did,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=reservationsTable,O.uUpdateWith= \r->r {reservationsPhase=text "released"},O.uWhere= \r->reservationsOrderId r O..== text oid,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=operatingreservationsTable,O.uUpdateWith= \r->r {operatingreservationsPhase=O.ifThenElse (operatingreservationsKind r O..== text "conversion") (text "released") (text "obligation")},O.uWhere= \r->operatingreservationsOrderId r O..== text oid O..&& (operatingreservationsPhase r O..== text "quote" O..|| (operatingreservationsKind r O..== text "conversion" O..&& operatingreservationsPhase r O..== text "obligation")),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text "Refunding"},O.uWhere= \r->ordersId r O..== text oid O..&& ordersStatus r O../= text "Paid",O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "refund_authorized") (text did)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ob
    _->reject "duplicate_refund"
