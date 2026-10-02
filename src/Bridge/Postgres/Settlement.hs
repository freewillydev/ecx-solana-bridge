module Bridge.Postgres.Settlement (recordSettlement,recordFailedSolana,markBroadcastIntent,authorizeRecordedSend,recordSolanaExpiry,checkExpiryOrigins) where

import Bridge.Config
import Bridge.Types
import Bridge.Ledger (Attempt(..),PaymentCosts(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import qualified Bridge.Postgres.Source as Source
import Control.Monad (forM_,when)
import Data.Aeson (FromJSON,ToJSON,object,(.=),encode,eitherDecodeStrict')
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
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
  let saved=json(object["costs" .= costs,"proof" .= proof]); actual=toInteger(units $ networkFee costs)+toInteger(units $ accountRent costs)
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
      quote <- stored(ordersQuoteJson q)
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
  pure(Attempt (attemptsTxid a) (attemptsIntentId a) (intentsChain i) (attemptsSignedBytes a) (attemptsPolicyJson a) (attemptsFeeLimit a) (attemptsState a) (attemptsCriticalSequence a))

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
stored :: FromJSON a => Text -> IO a
stored=either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8
json :: ToJSON a => a -> Text
json=TE.decodeUtf8 . LBS.toStrict . encode

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
      require (intentsResolved i==0 && Attempt (attemptsTxid a) (attemptsIntentId a) (intentsChain i) (attemptsSignedBytes a) (attemptsPolicyJson a) (attemptsFeeLimit a) (attemptsState a) (attemptsCriticalSequence a)==expected) "expiry_attempt_changed"
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
