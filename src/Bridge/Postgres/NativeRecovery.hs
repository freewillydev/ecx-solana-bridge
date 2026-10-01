module Bridge.Postgres.NativeRecovery (candidates,observation,recordCheck) where
import Bridge.Types
import Bridge.Ledger (Attempt(..),PaymentCosts(..),NativeSettlementCheck(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Bridge.RPC (fieldValue)
import Control.Monad (when)
import Data.Aeson (FromJSON,ToJSON,Value,object,(.=),encode,eitherDecodeStrict')
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import qualified Data.Text as T
import Data.Int (Int64)
import Data.Profunctor.Product (p2)
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import qualified Opaleye.Exists as E

jsonField :: O.Field O.SqlText -> O.Field O.SqlJsonb
jsonField = O.unsafeCast "jsonb"
proofField :: O.Field O.SqlText -> O.FieldNullable O.SqlJsonb
proofField value = O.toNullable $ jsonField (O.fromNullable (text "{}") (O.toNullable(jsonField value) O..->> text "proof"))
jsonInt :: O.FieldNullable O.SqlText -> Int64 -> O.Field O.SqlInt8
jsonInt value fallback = O.unsafeCast "bigint" (O.fromNullable (text $ T.pack $ show fallback) value)
recoveryStateTable :: O.Table (O.Field O.SqlText,O.Field O.SqlText) (O.Field O.SqlText,O.Field O.SqlText)
recoveryStateTable = O.table "native_payment_recovery_state" (p2 (O.requiredTableField "txid",O.requiredTableField "state"))

candidates :: Ledger -> IO [Attempt]
candidates ledger = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc (attemptsTxid . fst)) $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_(attemptsIntentId a O..== intentsId i O..&& intentsChain i O..== text "Native" O..&& attemptsState a O..== text "settled")
    let proof=proofField(O.fromNullable (text "{}") $ attemptsObservationJson a)
        anchor=O.fromNullable (text "") (proof O..->> text "blockhash")
        depth=jsonInt (proof O..->> text "requiredDepth") 0
    healthy <- E.exists $ do
      event <- O.selectTable chaineventsTable
      evidence <- O.selectTable observationevidenceTable
      let eventProof=O.toNullable(jsonField(observationevidenceEvidenceJson evidence)) O..-> text "proof"
          confirmations=jsonInt (eventProof O..->> text "confirmations") (-1)
      O.where_ (chaineventsChain event O..== text "Native" O..&& chaineventsEventId event O..== attemptsTxid a O..&&
        chaineventsKind event O..== text "outgoing" O..&& chaineventsNeedsReview event O..== num 0 O..&&
        chaineventsAnchor event O..== anchor O..&& chaineventsEvidenceHash event O..== observationevidenceHash evidence O..&& depth O..> num 0 O..&& confirmations O..>= depth)
      pure ()
    review <- E.exists $ do
      (txid,state) <- O.selectTable recoveryStateTable
      O.where_ (txid O..== attemptsTxid a O..&& state O../= text "reconfirmed")
      pure ()
    O.where_(O.not healthy O..|| review)
    pure(a,intentsChain i)
    :: IO [(Attempts,Text)]
  pure [asAttempt a chain | (a,chain)<-rows]

observation :: Ledger -> Text -> IO Text
observation ledger txid = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    a <- O.selectTable attemptsTable
    O.where_(attemptsTxid a O..== text txid)
    pure(attemptsObservationJson a)
    :: IO [Maybe Text]
  case rows of [Just value]->pure value; _->reject "native_settlement_missing"

recordCheck :: Ledger -> Attempt -> Text -> NativeSettlementCheck -> IO ()
recordCheck ledger expected previous check = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_(attemptsTxid a O..== text(attemptId expected) O..&& attemptsIntentId a O..== intentsId i O..&& intentsResolved i O..== num 1)
    pure(a,intentsChain i)
    :: IO [(Attempts,Text)]
  require (map (uncurry asAttempt) rows==[expected] && attemptState expected=="settled" && attemptChain expected=="Native" &&
    map (attemptsObservationJson . fst) rows==[Just previous]) "native_settlement_changed"
  (state,saved) <- case check of
    NativeSettlementConfirming->pure("confirming",json $ object["reason" .= ("native_confirmation_policy_pending"::Text)])
    NativeSettlementUnavailable reason->do
      require (not(T.null reason) && T.length reason<=160) "invalid_native_recovery_reason"
      pure("unavailable",json $ object["reason" .= reason])
    NativeSettlementReconfirmed costs proof->do
      old <- stored previous :: IO Value
      oldCosts <- fieldValue "costs" old
      require (costs==oldCosts && units(networkFee costs)>0 && units(accountRent costs)==0) "native_recovery_cost_changed"
      oldProofText <- fieldValue "proof" old
      oldProof <- stored oldProofText :: IO Value
      oldDepth <- fieldValue "requiredDepth" oldProof :: IO Int64
      value <- stored proof :: IO Value
      txid <- fieldValue "txid" value :: IO Text
      anchor <- fieldValue "blockhash" value :: IO Text
      depth <- fieldValue "requiredDepth" value :: IO Int64
      require (txid==attemptId expected && depth>0) "invalid_native_settlement"
      require (depth==oldDepth) "native_recovery_policy_changed"
      history <- eventRows c txid
      case history of
        [(event,evidence)]->do
          observed <- stored(observationevidenceEvidenceJson evidence) :: IO Value
          confirmations <- fieldValue "proof" observed >>= fieldValue "confirmations" :: IO Int64
          require (chaineventsAnchor event==anchor && confirmations>=depth) "native_recovery_scan_not_current"
        _->reject "native_recovery_scan_not_current"
      pure("reconfirmed",json $ object["costs" .= costs,"proof" .= proof])
    -- Family fee adjustment is a separate required port. Until it exists, an
    -- observed winner change stays paused for review and cannot book new money.
    NativeSettlementReplaced{}->reject "native_winner_change_requires_accounting"
  require (T.length saved<=32768) "native_recovery_evidence_too_large"
  oldReview <- O.runSelect c $ O.limit 1 $ O.orderBy (O.desc nativepaymentrecoveriesId) $ do
    row <- O.selectTable nativepaymentrecoveriesTable
    O.where_(nativepaymentrecoveriesTxid row O..== text(attemptId expected))
    pure row
    :: IO [NativePaymentRecoveries]
  let unchanged=map (\r->(nativepaymentrecoveriesState r,nativepaymentrecoveriesObservationJson r)) oldReview==[(state,saved)] || null oldReview && state=="reconfirmed" && previous==saved
  when (not unchanged) $ do
    sequenceNo <- criticalSequence c
    _ <- O.runInsert c O.Insert {O.iTable=nativepaymentrecoveriesTable,O.iRows=[NativePaymentRecoveries Nothing (text $ attemptId expected) (text previous) (text state) (text saved) (num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    when (state=="reconfirmed") $ do
      _ <- O.runUpdate c O.Update {O.uTable=attemptsTable,O.uUpdateWith= \a->a {attemptsObservationJson=O.toNullable(text saved)},O.uWhere= \a->attemptsTxid a O..== text(attemptId expected),O.uReturning=O.rCount}
      pure ()
    _ <- O.runUpdate c O.Update {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=num 1,deploymentPauseReason=text "native_settlement_recovery"},O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
    _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "native_settlement_recovery") (text $ attemptId expected<>":"<>state)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()

eventRows :: PG.Connection -> Text -> IO [(ChainEvents,ObservationEvidence)]
eventRows c txid = O.runSelect c $ do
  event <- O.selectTable chaineventsTable
  evidence <- O.selectTable observationevidenceTable
  O.where_(chaineventsChain event O..== text "Native" O..&& chaineventsEventId event O..== text txid O..&& chaineventsKind event O..== text "outgoing" O..&& chaineventsNeedsReview event O..== num 0 O..&& chaineventsEvidenceHash event O..== observationevidenceHash evidence)
  pure(event,evidence)
asAttempt :: Attempts -> Text -> Attempt
asAttempt a chain = Attempt (attemptsTxid a) (attemptsIntentId a) chain (attemptsSignedBytes a) (attemptsPolicyJson a) (attemptsFeeLimit a) (attemptsState a) (attemptsCriticalSequence a)
stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_native_settlement") pure . eitherDecodeStrict' . TE.encodeUtf8
json :: ToJSON a => a -> Text
json = TE.decodeUtf8 . LBS.toStrict . encode
text :: Text -> O.Field O.SqlText
text = O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num = O.sqlInt8
