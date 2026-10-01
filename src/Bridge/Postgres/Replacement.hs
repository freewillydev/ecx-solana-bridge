module Bridge.Postgres.Replacement
  ( parent,decision,recordDraft,member,signingContext,recordMember,cancel ) where
import Bridge.Types
import Bridge.Config (Config(..),fingerprint)
import Bridge.Ledger (Attempt(..))
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema hiding (deploymentFingerprint)
import qualified Bridge.Postgres.NativeFamily as Family
import qualified Bridge.Postgres.Preparation as P
import Bridge.Postgres.Source (paymentWorkHashC)
import Bridge.Postgres.Cancellation (freshC)
import Data.Aeson (FromJSON,ToJSON,eitherDecodeStrict',encode,object,(.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

parent :: Ledger -> Config -> Text -> IO Attempt
parent ledger cfg txid=ledgerAction ledger $ \c->fst <$> contextC c cfg txid

contextC :: PG.Connection -> Config -> Text -> IO (Attempt,[NativeSigned])
contextC c cfg txid=do
  rows <- O.runSelect c $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    ob <- O.selectTable obligationsTable
    deposit <- O.selectTable depositsTable
    fee <- O.selectTable feereservationsTable
    order <- O.selectTable ordersTable
    O.where_ (attemptsTxid a O..== text txid O..&& attemptsState a O..== text "broadcast_intent" O..&&
      attemptsIntentId a O..== intentsId i O..&& intentsChain i O..== text "Native" O..&& intentsResolved i O..== num 0 O..&&
      intentsObligationId i O..== obligationsId ob O..&& obligationsStatus ob O..== text "paying" O..&&
      obligationsDepositId ob O..== depositsId deposit O..&& depositsEligible deposit O..== num 1 O..&&
      feereservationsIntentId fee O..== intentsId i O..&& feereservationsAsset fee O..== text "Native" O..&&
      feereservationsReleased fee O..== num 0 O..&& feereservationsAmount fee O..>= attemptsFeeLimit a O..&& obligationsOrderId ob O..== ordersId order)
    pure(a,i,ob,order)
    :: IO [(Attempts,Intents,Obligations,Orders)]
  (a,i,ob,order) <- case rows of [row]->pure row; _->reject "native_replacement_not_expected"
  let current=asAttempt a (intentsChain i)
  require (maybe False (>0) $ attemptSequence current) "broadcast_intent_required"
  family <- Family.familyC c (attemptIntent current)
  require (not(null family) && last family==current) "native_replacement_not_current"
  _ <- P.activeC c (attemptIntent current)
  policy <- stored(ordersPolicyJson order)
  signed <- stored(attemptPolicy current)
  let plan=signedNativePlan signed
  require (obligationsAsset ob=="Native" && units(planAmount plan)==obligationsAmount ob && planRecipient plan==obligationsRecipient ob &&
    planProfile plan==profile cfg && planDepth plan==nativeDepth policy && deploymentFingerprint policy==fingerprint cfg &&
    units(planFeeLimit plan)==attemptFeeLimit current && nativeTxid(signedNativeTransaction signed)==txid && signedNativeBytes signed==attemptBytes current) "saved_native_policy_mismatch"
  members <- mapM (stored . attemptPolicy) family
  either reject pure(validateNativeFamily members)
  pure(current,members)

pausedC :: PG.Connection -> IO ()
pausedC c=do
  rows <- O.runSelect c $ fmap deploymentPaused $ O.selectTable deploymentTable :: IO [Int64]
  require (rows==[1]) "pause_before_operator_action"

draftsC :: PG.Connection -> Int64 -> IO [NativeReplacementDrafts]
draftsC c sequenceNo=O.runSelect c $ do
  row <- O.selectTable nativereplacementdraftsTable
  O.where_ (nativereplacementdraftsCriticalSequence row O..== num sequenceNo)
  pure row
cancelRowsC :: PG.Connection -> Int64 -> IO [NativeReplacementCancellations]
cancelRowsC c sequenceNo=O.runSelect c $ do
  row <- O.selectTable nativereplacementcancellationsTable
  O.where_ (nativereplacementcancellationsDraftSequence row O..== num sequenceNo)
  pure row

decision :: Ledger -> Text -> Amount -> Text -> IO (Maybe(Int64,Bool))
decision ledger txid fee reason=ledgerAction ledger $ \c->do
  rows <- decisionC c txid fee reason
  case rows of
    []->pure Nothing
    [r]->do
      cancellations <- cancelRowsC c (nativereplacementdraftsCriticalSequence r)
      pure(Just(nativereplacementdraftsCriticalSequence r,not(null cancellations)))
    _->reject "duplicate_native_replacement_decision"
decisionC :: PG.Connection -> Text -> Amount -> Text -> IO [NativeReplacementDrafts]
decisionC c txid fee reason=O.runSelect c $ do
  r <- O.selectTable nativereplacementdraftsTable
  O.where_(nativereplacementdraftsParentTxid r O..== text txid O..&& nativereplacementdraftsFee r O..== num(units fee) O..&& nativereplacementdraftsReason r O..== text reason)
  pure r

recordDraft :: Ledger -> Config -> Attempt -> NativeDraft -> Text -> Int64 -> IO Int64
recordDraft ledger cfg expected draft reason now=ledgerAction ledger $ \c->do
  require (not(T.null $ T.strip reason) && T.length reason<=512 && T.length(json draft)<=200000) "invalid_native_replacement_draft"
  pausedC c
  old <- decisionC c (attemptId expected) (draftFee draft) reason
  case old of
    [r]->require (nativereplacementdraftsDraftJson r==json draft) "native_replacement_draft_conflict" >> pure(nativereplacementdraftsCriticalSequence r)
    []->do
      (current,family) <- contextC c cfg (attemptId expected)
      require (current==expected) "native_replacement_parent_changed"
      either reject pure(validateNativeReplacementDraft family (draftFee draft) draft)
      drafts <- O.runSelect c $ do
        row <- O.selectTable nativereplacementdraftsTable
        a <- O.selectTable attemptsTable
        O.where_(nativereplacementdraftsParentTxid row O..== attemptsTxid a O..&& attemptsIntentId a O..== text(attemptIntent current))
        pure row
        :: IO [NativeReplacementDrafts]
      require (length drafts<7) "native_replacement_draft_limit"
      mapM_ (\r->do
        cancelled <- cancelRowsC c (nativereplacementdraftsCriticalSequence r)
        signed <- memberC c (nativereplacementdraftsCriticalSequence r)
        require (not(null cancelled) || signed/=Nothing) "native_replacement_draft_pending") drafts
      freshC c now
      workHash <- paymentWorkHashC c (attemptIntent current)
      checks <- O.runSelect c (O.selectTable custodycheckTable) :: IO [CustodyCheck]
      let custody=[(custodycheckRevision r,custodycheckCheckedAt r,custodycheckReportJson r) | r<-checks]
          proof=json $ object["custody" .= custody,"parentBroadcastSequence" .= attemptSequence current]
      require (T.length proof<=32768) "native_replacement_evidence_too_large"
      sequenceNo <- criticalSequence c
      inserted <- O.runInsert c O.Insert {O.iTable=nativereplacementdraftsTable,O.iRows=[NativeReplacementDrafts (num sequenceNo) (text $ attemptId current) (num $ units $ draftFee draft) (text $ json draft) (text workHash) (text reason) (text proof)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (inserted==1) "native_replacement_draft_insert_failed"
      auditC c "native_replacement_drafted" (attemptId current)
      pure sequenceNo
    _->reject "duplicate_native_replacement_decision"

signingContext :: Ledger -> Config -> Int64 -> IO ([Attempt],NativeDraft)
signingContext ledger cfg sequenceNo=ledgerAction ledger $ \c->signingContextC c cfg sequenceNo
signingContextC :: PG.Connection -> Config -> Int64 -> IO ([Attempt],NativeDraft)
signingContextC c cfg sequenceNo=do
  pausedC c
  cancelled <- cancelRowsC c sequenceNo
  signed <- memberC c sequenceNo
  rows <- draftsC c sequenceNo
  row <- case rows of [r] | null cancelled && signed==Nothing->pure r; _->reject "native_replacement_not_unsigned"
  (a,members) <- contextC c cfg (nativereplacementdraftsParentTxid row)
  workHash <- paymentWorkHashC c (attemptIntent a)
  require (workHash==nativereplacementdraftsWorkHash row) "native_replacement_work_changed"
  draft <- stored(nativereplacementdraftsDraftJson row)
  require (units(draftFee draft)==nativereplacementdraftsFee row) "native_replacement_draft_changed"
  either reject pure(validateNativeReplacementDraft members (draftFee draft) draft)
  family <- Family.familyC c (attemptIntent a)
  common <- O.runSelect c $ do
    i <- O.selectTable intentsTable
    O.where_(intentsId i O..== text(attemptIntent a))
    pure(intentsCommonInput i)
    :: IO [Maybe Text]
  point <- case nativeInputs(draftTransaction draft) of input:_->pure(nativeOutpoint input); _->reject "native_input_mismatch"
  require (common==[Just(outpointTxid point<>":"<>T.pack(show $ outpointVout point))]) "native_replacement_common_input_changed"
  pure(family,draft)

member :: Ledger -> Int64 -> IO (Maybe Attempt)
member ledger sequenceNo=ledgerAction ledger $ \c->memberC c sequenceNo
memberC :: PG.Connection -> Int64 -> IO (Maybe Attempt)
memberC c sequenceNo=do
  rows <- O.runSelect c $ do
    m <- O.selectTable nativereplacementmembersTable
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_(nativereplacementmembersDraftSequence m O..== num sequenceNo O..&& nativereplacementmembersTxid m O..== attemptsTxid a O..&& attemptsIntentId a O..== intentsId i)
    pure(a,intentsChain i)
    :: IO [(Attempts,Text)]
  case rows of []->pure Nothing; [(a,chain)]->pure(Just $ asAttempt a chain); _->reject "duplicate_native_replacement_member"

recordMember :: Ledger -> Config -> Int64 -> [Attempt] -> NativeSigned -> Int64 -> IO Attempt
recordMember ledger cfg sequenceNo expected signed now=ledgerAction ledger $ \c->do
  let txid=nativeTxid(signedNativeTransaction signed)
      bytes=signedNativeBytes signed
      policy=json signed
  require (T.length bytes<=200000 && T.length policy<=32768) "invalid_native_signed_bytes"
  previous <- memberC c sequenceNo
  case previous of
    Just a->require (attemptId a==txid && attemptBytes a==bytes && attemptPolicy a==policy) "native_replacement_signature_conflict" >> pure a
    Nothing->do
      (family,draft) <- signingContextC c cfg sequenceNo
      require (family==expected) "native_replacement_family_changed"
      members <- mapM (stored . attemptPolicy) family
      either reject pure(validateNativeFamily $ members<>[signed])
      require (sameNativeTemplate (draftTransaction draft) (signedNativeTransaction signed) && draftFee draft==signedNativeFee signed && sameNativePrevouts (draftPrevouts draft) (signedNativePrevouts signed)) "native_replacement_signed_template_changed"
      freshC c now
      latest <- case reverse family of a:_->pure a; _->reject "native_replacement_family_bounds"
      generation <- P.activeC c (attemptIntent latest)
      memberSequence <- criticalSequence c
      count <- O.runInsert c O.Insert {O.iTable=attemptsTable,O.iRows=[Attempts (text txid) (text $ attemptIntent latest) (text bytes) (text policy) (num $ attemptFeeLimit latest) (text "signed") O.null O.null (num generation)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "native_replacement_member_insert_failed"
      _ <- O.runInsert c O.Insert {O.iTable=nativereplacementmembersTable,O.iRows=[NativeReplacementMembers (num sequenceNo) (text txid) (num memberSequence)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      auditC c "native_replacement_signed" txid
      pure $ Attempt txid (attemptIntent latest) "Native" bytes policy (attemptFeeLimit latest) "signed" Nothing

cancel :: Ledger -> Int64 -> Text -> IO ()
cancel ledger sequenceNo reason=ledgerAction ledger $ \c->do
  require (sequenceNo>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_native_replacement_cancellation"
  pausedC c
  old <- cancelRowsC c sequenceNo
  case old of
    [r]->require (nativereplacementcancellationsReason r==reason) "native_replacement_cancellation_conflict"
    []->do
      signed <- memberC c sequenceNo
      require (signed==Nothing) "native_replacement_already_signed"
      drafts <- draftsC c sequenceNo
      txid <- case drafts of [r]->pure(nativereplacementdraftsParentTxid r); _->reject "native_replacement_draft_missing"
      critical <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=nativereplacementcancellationsTable,O.iRows=[NativeReplacementCancellations (num sequenceNo) (text reason) (num critical)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      auditC c "native_replacement_cancelled" txid
    _->reject "duplicate_native_replacement_cancellation"

auditC :: PG.Connection -> Text -> Text -> IO ()
auditC c action detail=do
  count <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text action) (text detail)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  require (count==1) "audit_insert_failed"
asAttempt :: Attempts -> Text -> Attempt
asAttempt a chain=Attempt (attemptsTxid a) (attemptsIntentId a) chain (attemptsSignedBytes a) (attemptsPolicyJson a) (attemptsFeeLimit a) (attemptsState a) (attemptsCriticalSequence a)
stored :: FromJSON a => Text -> IO a
stored=either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8
json :: ToJSON a => a -> Text
json=TE.decodeUtf8 . LBS.toStrict . encode
text :: Text -> O.Field O.SqlText
text=O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num=O.sqlInt8
