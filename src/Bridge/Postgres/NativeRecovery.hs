module Bridge.Postgres.NativeRecovery (candidates,observation,recordCheck,reviewSequences,rebroadcastDecision,recordRebroadcast,authorizeRebroadcast) where
import Bridge.Types
import Bridge.NativePayment
import qualified Bridge.Postgres.NativeFamily as Family
import Bridge.Ledger (Attempt(..),PaymentCosts(..),NativeSettlementCheck(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Bridge.RPC (fieldValue)
import Control.Monad (when)
import Data.Aeson (FromJSON,ToJSON,Value(..),object,(.=),toJSON,encode,eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import qualified Data.Text as T
import Data.Int (Int64)
import Data.Profunctor.Product (p2,p3)
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

-- SELECT-only diagnostics expose the exact anchor an operator must approve.
reviewSequences :: PG.Connection -> IO [(Text,Text,Int64)]
reviewSequences c = O.runSelect c $ O.limit 1001 $ O.orderBy(O.desc $ \(_,_,sequenceNo)->sequenceNo) $ do
  row@(_,state,_) <- O.selectTable table
  O.where_(state O../= text "reconfirmed")
  pure row
 where table :: O.Table (O.Field O.SqlText,O.Field O.SqlText,O.Field O.SqlInt8) (O.Field O.SqlText,O.Field O.SqlText,O.Field O.SqlInt8)
       table=O.table "native_payment_recovery_state" (p3 (O.requiredTableField "txid",O.requiredTableField "state",O.requiredTableField "critical_sequence"))

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
  case check of
    NativeSettlementReplaced family txid costs proof->winnerChangeC c expected previous family txid costs proof
    _->finalityC c expected previous check

finalityC :: PG.Connection -> Attempt -> Text -> NativeSettlementCheck -> IO ()
finalityC c expected previous check = do
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
    -- Winner changes must use the family/accounting path selected above.
    NativeSettlementReplaced{}->reject "native_winner_change_requires_accounting"
  require (T.length saved<=32768) "native_recovery_evidence_too_large"
  oldReview <- O.runSelect c $ O.limit 1 $ O.orderBy (O.desc nativepaymentrecoveriesId) $ do
    row <- O.selectTable nativepaymentrecoveriesTable
    O.where_(nativepaymentrecoveriesTxid row O..== text(attemptId expected))
    pure row
    :: IO [NativePaymentRecoveries]
  unchangedReview <- case oldReview of
    [row] | nativepaymentrecoveriesState row==state->do
      old <- stored(nativepaymentrecoveriesObservationJson row) :: IO Value
      new <- stored saved :: IO Value
      -- The decision authorizes only the same saved bytes. A repeat scan of
      -- the identical unresolved state must not erase its journal binding.
      pure $ old==new || case old of
        Object fields | KM.member "rebroadcastRecovery" fields->
          Object (foldr KM.delete fields ["rebroadcastRecovery","operatorReason","rebroadcastProof"])==new
        _->False
    _->pure False
  let unchanged=unchangedReview || null oldReview && state=="reconfirmed" && previous==saved
  when (not unchanged) $ do
    sequenceNo <- criticalSequence c
    _ <- O.runInsert c O.Insert {O.iTable=nativepaymentrecoveriesTable,O.iRows=[NativePaymentRecoveries Nothing (text $ attemptId expected) (text previous) (text state) (text saved) (num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    when (state=="reconfirmed") $ do
      _ <- O.runUpdate c O.Update {O.uTable=attemptsTable,O.uUpdateWith= \a->a {attemptsObservationJson=O.toNullable(text saved)},O.uWhere= \a->attemptsTxid a O..== text(attemptId expected),O.uReturning=O.rCount}
      pure ()
    _ <- O.runUpdate c O.Update {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=num 1,deploymentPauseReason=text "native_settlement_recovery"},O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
    _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "native_settlement_recovery") (text $ attemptId expected<>":"<>state)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()

-- Decisions share the immutable recovery journal, without changing settlement
-- or creating another economic intent. Only the exact original bytes qualify.
rebroadcastDecision :: Ledger -> Text -> Int64 -> Text -> IO (Maybe Int64)
rebroadcastDecision ledger txid anchor reason = ledgerAction ledger $ \c->do
  rows <- decisionRowsC c txid anchor
  case rows of
    []->pure Nothing
    [row]->do
      value <- stored(nativepaymentrecoveriesObservationJson row) :: IO Value
      saved <- fieldValue "operatorReason" value
      require (saved==reason) "native_rebroadcast_conflict"
      pure(Just $ nativepaymentrecoveriesCriticalSequence row)
    _->reject "duplicate_native_rebroadcast_decision"

decisionRowsC :: PG.Connection -> Text -> Int64 -> IO [NativePaymentRecoveries]
decisionRowsC c txid anchor = O.runSelect c $ O.limit 2 $ do
  row <- O.selectTable nativepaymentrecoveriesTable
  let value=jsonField(nativepaymentrecoveriesObservationJson row)
  O.where_(nativepaymentrecoveriesTxid row O..== text txid O..&&
    O.fromNullable (text "") (O.toNullable value O..->> text "rebroadcastRecovery") O..== text(T.pack $ show anchor))
  pure row

rebroadcastContextC :: PG.Connection -> Attempt -> [Attempt] -> IO NativePaymentRecoveries
rebroadcastContextC c expected family = do
  state <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
  require (map deploymentPaused state==[1]) "pause_before_operator_action"
  actual <- Family.familyC c (attemptIntent expected)
  require (actual==family && expected `elem` actual && attemptChain expected=="Native" && attemptState expected=="settled" && maybe False (>0) (attemptSequence expected)) "native_rebroadcast_payment_changed"
  contexts <- O.runSelect c $ do
    intent <- O.selectTable intentsTable
    ob <- O.selectTable obligationsTable
    O.where_(intentsId intent O..== text(attemptIntent expected) O..&& intentsObligationId intent O..== obligationsId ob)
    pure(intentsResolved intent,obligationsStatus ob)
    :: IO [(Int64,Text)]
  require (contexts==[(1,"paid")]) "native_rebroadcast_payment_changed"
  reviews <- O.runSelect c $ O.limit 1 $ O.orderBy(O.desc nativepaymentrecoveriesId) $ do
    row <- O.selectTable nativepaymentrecoveriesTable
    O.where_(nativepaymentrecoveriesTxid row O..== text(attemptId expected))
    pure row
    :: IO [NativePaymentRecoveries]
  review <- case reviews of [row]->pure row; _->reject "native_rebroadcast_review_missing"
  value <- stored(nativepaymentrecoveriesObservationJson review) :: IO Value
  why <- fieldValue "reason" value :: IO Text
  require ((nativepaymentrecoveriesState review=="confirming" && why=="native_confirmation_policy_pending") ||
    (nativepaymentrecoveriesState review=="unavailable" && why=="native_settled_payment_unseen")) "native_rebroadcast_not_missing"
  pure review

recordRebroadcast :: Ledger -> Attempt -> [Attempt] -> Int64 -> Text -> Value -> IO Int64
recordRebroadcast ledger expected family anchor reason proof = ledgerAction ledger $ \c->do
  require (anchor>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_native_rebroadcast_approval"
  rows <- decisionRowsC c (attemptId expected) anchor
  case rows of
    [row]->do
      value <- stored(nativepaymentrecoveriesObservationJson row) :: IO Value
      saved <- fieldValue "operatorReason" value
      require (saved==reason) "native_rebroadcast_conflict"
      pure(nativepaymentrecoveriesCriticalSequence row)
    []->do
      review <- rebroadcastContextC c expected family
      require (nativepaymentrecoveriesCriticalSequence review==anchor) "native_rebroadcast_review_changed"
      txid <- fieldValue "transaction" proof
      bytesHash <- fieldValue "bytesHash" proof
      require (txid==attemptId expected && bytesHash==digest(TE.encodeUtf8 $ attemptBytes expected)) "native_rebroadcast_proof_mismatch"
      old <- stored(nativepaymentrecoveriesObservationJson review) :: IO Value
      fields <- case old of Object values->pure values; _->reject "invalid_native_recovery_evidence"
      let saved=json $ Object $ KM.insert "rebroadcastRecovery" (toJSON anchor) $
            KM.insert "operatorReason" (toJSON reason) $ KM.insert "rebroadcastProof" proof fields
      require (T.length saved<=32768) "native_recovery_evidence_too_large"
      sequenceNo <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=nativepaymentrecoveriesTable,O.iRows=[NativePaymentRecoveries Nothing (text $ attemptId expected) (text $ nativepaymentrecoveriesPreviousObservation review) (text $ nativepaymentrecoveriesState review) (text saved) (num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "native_rebroadcast_approved") (text $ attemptId expected<>":"<>T.pack(show sequenceNo))],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure sequenceNo
    _->reject "duplicate_native_rebroadcast_decision"

authorizeRebroadcast :: Ledger -> Bool -> Attempt -> [Attempt] -> Int64 -> IO ()
authorizeRebroadcast ledger backed expected family approved = ledgerAction ledger $ \c->do
  review <- rebroadcastContextC c expected family
  require (nativepaymentrecoveriesCriticalSequence review==approved) "native_rebroadcast_review_changed"
  value <- stored(nativepaymentrecoveriesObservationJson review) :: IO Value
  _ <- fieldValue "rebroadcastRecovery" value :: IO Int64
  proof <- fieldValue "rebroadcastProof" value :: IO Value
  bytesHash <- fieldValue "bytesHash" proof
  require (bytesHash==digest(TE.encodeUtf8 $ attemptBytes expected)) "native_rebroadcast_payment_changed"
  state <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
  require (not backed || case state of [row]->deploymentBackupSequence row>=approved; _->False) "backup_pending"

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

-- Atomic canonical-winner move. Principal, reservations and intent resolution
-- remain settled; only the proved fee difference is appended to the ledger.
winnerChangeC :: PG.Connection -> Attempt -> Text -> [Attempt] -> Text -> PaymentCosts -> Text -> IO ()
winnerChangeC c previousWinner previous expected txid costs proof = do
  family <- Family.familyC c (attemptIntent previousWinner)
  require (family==expected && previousWinner `elem` family && txid/=attemptId previousWinner) "native_replacement_family_changed"
  winner <- case filter ((==txid).attemptId) family of [a]->pure a; _->reject "native_family_winner_missing"
  require (attemptState winner `elem` ["broadcast_intent","review"] && all (maybe False (>0).attemptSequence) [previousWinner,winner]) "unrecorded_broadcast_observed"
  contexts <- O.runSelect c $ do
    i <- O.selectTable intentsTable
    ob <- O.selectTable obligationsTable
    order <- O.selectTable ordersTable
    reservation <- O.selectTable feereservationsTable
    O.where_ (intentsId i O..== text(attemptIntent winner) O..&& intentsResolved i O..== num 1 O..&&
      intentsObligationId i O..== obligationsId ob O..&& obligationsOrderId ob O..== ordersId order O..&&
      obligationsStatus ob O..== text "paid" O..&& feereservationsIntentId reservation O..== intentsId i O..&& feereservationsReleased reservation O..== num 1)
    pure(ob,order)
    :: IO [(Obligations,Orders)]
  (ob,order) <- case contexts of [row]->pure row; _->reject "native_winner_context_changed"
  policy <- stored(ordersPolicyJson order)
  signed <- stored(attemptPolicy winner)
  oldSigned <- stored(attemptPolicy previousWinner)
  let plan=signedNativePlan signed
      quantity=obligationsAmount ob
  require (obligationsAsset ob=="Native" && units(planAmount plan)==quantity && planRecipient plan==obligationsRecipient ob && planDepth plan==nativeDepth policy) "saved_native_policy_mismatch"
  old <- stored previous :: IO Value
  oldCosts <- fieldValue "costs" old
  oldProofText <- fieldValue "proof" old
  oldProof <- stored oldProofText :: IO Value
  oldTxid <- fieldValue "txid" oldProof
  oldDepth <- fieldValue "requiredDepth" oldProof
  zero <- either reject pure(amount 0)
  require (oldTxid==attemptId previousWinner && oldDepth==planDepth plan && oldCosts==PaymentCosts (signedNativeFee oldSigned) zero) "native_recovery_cost_changed"
  require (costs==PaymentCosts (signedNativeFee signed) zero) "native_recovery_cost_changed"
  value <- stored proof :: IO Value
  provedTxid <- fieldValue "txid" value
  anchor <- fieldValue "blockhash" value
  depth <- fieldValue "requiredDepth" value
  require (provedTxid==txid && depth==planDepth plan) "native_recovery_policy_changed"
  history <- eventRows c txid
  (event,evidence) <- case history of [row]->pure row; _->reject "native_recovery_scan_not_current"
  observed <- stored(observationevidenceEvidenceJson evidence) :: IO Value
  eventProof <- fieldValue "proof" observed :: IO Value
  confirmations <- fieldValue "confirmations" eventProof
  net <- fieldValue "walletNetUnits" eventProof
  fee <- fieldValue "feeUnits" eventProof
  require (chaineventsAnchor event==anchor && confirmations>=depth && net==T.pack(show $ negate $ toInteger quantity) && fee==signedNativeFee signed) "native_recovery_scan_not_current"
  let saved=json $ object["costs" .= costs,"proof" .= proof]
      delta=toInteger(units $ networkFee costs)-toInteger(units $ networkFee oldCosts)
  require (T.length saved<=32768 && delta/=0 && abs delta<=toInteger(maxBound::Int64)) "invalid_native_settlement"
  sequenceNo <- criticalSequence c
  inserted <- O.runInsert c O.Insert {O.iTable=nativewinnerchangesTable,O.iRows=[NativeWinnerChanges (num sequenceNo) (text $ attemptId previousWinner) (text txid) (text previous) (text saved) (text $ chaineventsEvidenceHash event) (num $ fromInteger delta)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  require (inserted==1) "native_winner_record_failed"
  posting c ("native-winner-fee:"<>T.pack(show sequenceNo)) "canonical native winner fee adjustment" [(Native,"operating",negate delta),(Native,"external",delta)]
  oldChanged <- O.runUpdate c O.Update {O.uTable=attemptsTable,O.uUpdateWith= \a->a {attemptsState=text "review"},O.uWhere= \a->attemptsTxid a O..== text(attemptId previousWinner),O.uReturning=O.rCount}
  newChanged <- O.runUpdate c O.Update {O.uTable=attemptsTable,O.uUpdateWith= \a->a {attemptsState=text "settled",attemptsObservationJson=O.toNullable(text saved)},O.uWhere= \a->attemptsTxid a O..== text txid,O.uReturning=O.rCount}
  require (oldChanged==1 && newChanged==1) "native_winner_context_changed"
  -- A later refund must not replace the conversion's primary payout link.
  _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \o->o {ordersPayoutTx=O.toNullable(text txid)},O.uWhere= \o->ordersId o O..== text(ordersId order) O..&& O.fromNullable (text "") (ordersPayoutTx o) O..== text(attemptId previousWinner),O.uReturning=O.rCount}
  _ <- O.runUpdate c O.Update {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=num 1,deploymentPauseReason=text "native_winner_changed"},O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
  _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "native_winner_changed") (text $ attemptId previousWinner<>":"<>txid)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  pure ()
