module Bridge.Postgres.Source (lossCoverDecision, recordLossCover, recordSourceCheckC, paymentWorkHashC, sourceWorkHashC, recoveryApproval, recoveryObligation, recoveryRecord, coveredApproval, coveredObligation, coveredRecord, authorizedC, coveredAuthorized, candidates, recordCheck, orderBinding, eventEvidence) where

import Bridge.Types
import Bridge.Ledger.Model (encodeRecord,decodeRecord,SourceCheck(..),Obligation(..),Deposit(..),LossCapital(..))
import Bridge.Postgres.Ledger (Ledger,ledgerAction,balances)
import Bridge.Postgres.Custody (freshC)
import qualified Bridge.Postgres.Order as Order
import Bridge.RPC (fieldValue)
import Data.Int (Int64)
import Data.Aeson (object,(.=),eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (catMaybes)
import qualified Data.Map.Strict as M
import Bridge.Postgres.Schema
import Bridge.Postgres.Ledger (criticalSequence, posting)
import Control.Monad (when, forM_)
import Data.Aeson (Value(..), ToJSON, encode)
import qualified Data.Aeson
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as LBS
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import Data.Profunctor.Product (p2)

recordSourceCheckC :: PG.Connection -> Text -> SourceCheck -> IO ()
recordSourceCheckC connection did check = do
  sources <- O.runSelect connection $ do
    row <- O.selectTable depositsTable
    O.where_ (depositsId row O..== O.sqlStrictText did)
    pure row
    :: IO [Deposits]
  source <- case sources of [row]->pure row; _->reject "source_deposit_missing"
  asset <- case depositsAsset source of "Native"->pure Native; "Wrapped"->pure Wrapped; "Sol"->pure Sol; _->reject "invalid_source_asset"
  history <- O.runSelect connection $ do
    row <- O.selectTable sourcerecoveriesTable
    O.where_ (sourcerecoveriesDepositId row O..== O.sqlStrictText did)
    pure row
    :: IO [SourceRecoveries]
  let old=case reverse (sortOn sourcerecoveriesId history) of row:_->Just row; []->Nothing
      previousLoss=maybe 0 sourcerecoveriesShortfall old
      eligible=depositsEligible source==1
  (state,loss,proof) <- case check of
    SourcePending proof->require (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure ("pending",0,proof)
    SourceMissing proof->require (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure ("missing",depositsAmount source,proof)
    SourceRestored proof->require eligible "source_recovery_scan_not_current" >> pure ("restored",0,proof)
    SourceUnavailable proof->pure ("unavailable",previousLoss,proof)
  let evidence=encodeRecord proof
      ordinary=old==Nothing && depositsAllocated source==0 && state=="pending"
      unchanged=case old of Just row->sourcerecoveriesState row==state && sourcerecoveriesShortfall row==loss && (state/="unavailable" || sourcerecoveriesEvidenceJson row==evidence); _->False
  require (proof/=Null && T.length evidence<=16384) "invalid_source_recovery_evidence"
  when (not ordinary && not unchanged) $ do
    sequenceNo <- criticalSequence connection
    _ <- O.runInsert connection O.Insert
      {O.iTable=sourcerecoveriesTable,O.iRows=[SourceRecoveries Nothing (O.sqlStrictText did) (O.sqlStrictText state) (O.sqlInt8 loss) (O.sqlStrictText evidence) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    let delta=toInteger loss-toInteger previousLoss
    when (delta/=0) $ posting connection ("source-recovery:"<>T.pack (show sequenceNo)) "change in verified missing source value"
      [(asset,"source_deficit",negate delta),(asset,"external",delta)]
    when (delta<0) $ do
      covers <- unreturnedCoversC connection did
      forM_ covers $ \row->do
        require (toInteger (sourcelosscoversAmount row)==negate delta) "source_loss_return_mismatch"
        let covered=sourcelosscoversCriticalSequence row
        _ <- O.runInsert connection O.Insert
          {O.iTable=sourcelossreturnsTable,O.iRows=[SourceLossReturns (O.sqlInt8 covered) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        posting connection ("source-loss-return:"<>T.pack (show covered)) "restored source returns its operator loss allocation"
          [(asset,"float",toInteger (sourcelosscoversFloatAmount row)),(asset,"earned",toInteger (sourcelosscoversEarnedAmount row)),(asset,"source_deficit",negate (toInteger (sourcelosscoversAmount row)))]
    _ <- O.runUpdate connection O.Update
      {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 1,deploymentPauseReason=O.sqlStrictText "source_recovery_review"},O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount}
    _ <- O.runInsert connection O.Insert
      {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "source_recovery") (O.sqlStrictText (did<>":"<>state))],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()

paymentWorkHashC :: PG.Connection -> Text -> IO Text
paymentWorkHashC connection intent = do
  obligations <- O.runSelect connection $ matching (\row->obligationsId row O..== O.sqlStrictText intent) (O.selectTable obligationsTable) :: IO [Obligations]
  work <- O.runSelect connection $ matching (\row->intentsId row O..== O.sqlStrictText intent) (O.selectTable intentsTable) :: IO [Intents]
  preparations <- O.runSelect connection $ matching (\row->preparationsIntentId row O..== O.sqlStrictText intent) (O.selectTable preparationsTable) :: IO [Preparations]
  attempts <- O.runSelect connection $ matching (\row->attemptsIntentId row O..== O.sqlStrictText intent) (O.selectTable attemptsTable) :: IO [Attempts]
  cancellations <- O.runSelect connection $ matching (\row->preparationcancellationsIntentId row O..== O.sqlStrictText intent) (O.selectTable preparationcancellationsTable) :: IO [PreparationCancellations]
  fees <- O.runSelect connection $ matching (\row->feereservationsIntentId row O..== O.sqlStrictText intent) (O.selectTable feereservationsTable) :: IO [FeeReservations]
  let obligationRows=[(obligationsId r,obligationsOrderId r,obligationsDepositId r,obligationsKind r,obligationsAsset r,obligationsAmount r,obligationsRecipient r) | r<-obligations]
      workRows=[(intentsChain r,intentsResolved r==1,intentsCommonInput r) | r<-work]
      preparationRows=[(preparationsGeneration r,preparationsPolicyJson r,preparationsDraftJson r,preparationsRetiredTxid r,preparationsCancelled r==1) | r<-sortOn preparationsGeneration preparations]
      attemptRows=[(attemptsTxid r,attemptsState r,attemptsPreparationGeneration r,attemptsCriticalSequence r,attemptsObservationJson r) | r<-sortOn (\r->(attemptsPreparationGeneration r,attemptsTxid r)) attempts]
      cancellationRows=[(preparationcancellationsGeneration r,preparationcancellationsReason r,preparationcancellationsCleanupJson r,preparationcancellationsCompleted r==1) | r<-sortOn preparationcancellationsGeneration cancellations]
      feeRows=[(feereservationsAsset r,feereservationsAmount r,feereservationsReleased r==1) | r<-fees]
      base=hashJson (obligationRows,workRows,preparationRows,attemptRows,cancellationRows,feeRows)
  pure base

sourceWorkHashC :: PG.Connection -> Text -> IO Text
sourceWorkHashC connection intent = do
  base <- paymentWorkHashC connection intent
  drafts <- O.runSelect connection $ do
    draft <- O.selectTable nativereplacementdraftsTable
    attempt <- O.selectTable attemptsTable
    O.where_ (nativereplacementdraftsParentTxid draft O..== attemptsTxid attempt O..&& attemptsIntentId attempt O..== O.sqlStrictText intent)
    pure draft
    :: IO [NativeReplacementDrafts]
  cancelled <- O.runSelect connection $ do
    decision <- O.selectTable nativereplacementcancellationsTable
    draft <- O.selectTable nativereplacementdraftsTable
    attempt <- O.selectTable attemptsTable
    O.where_ (nativereplacementcancellationsDraftSequence decision O..== nativereplacementdraftsCriticalSequence draft O..&& nativereplacementdraftsParentTxid draft O..== attemptsTxid attempt O..&& attemptsIntentId attempt O..== O.sqlStrictText intent)
    pure decision
    :: IO [NativeReplacementCancellations]
  let draftRows=[(nativereplacementdraftsCriticalSequence r,nativereplacementdraftsParentTxid r,nativereplacementdraftsFee r,nativereplacementdraftsDraftJson r,nativereplacementdraftsWorkHash r,nativereplacementdraftsReason r) | r<-sortOn nativereplacementdraftsCriticalSequence drafts]
      cancelledRows=[(nativereplacementcancellationsDraftSequence r,nativereplacementcancellationsReason r,nativereplacementcancellationsCriticalSequence r) | r<-sortOn nativereplacementcancellationsCriticalSequence cancelled]
  pure (if null drafts && null cancelled then base else hashJson (base,draftRows,cancelledRows))

matching :: (a -> O.Field O.SqlBool) -> O.Select a -> O.Select a
matching predicate query = do
  row <- query
  O.where_ (predicate row)
  pure row

hashJson :: ToJSON a => a -> Text
hashJson = digest . LBS.toStrict . encode

-- Restored source approval retains the exact suspended work and original state.
-- All final checks and the approval write share one PostgreSQL transaction.
recoveryApprovalC :: PG.Connection -> Text -> Int64 -> IO (Maybe Text)
recoveryApprovalC c intent restoration = do
  rows <- O.runSelect c $ do
    row <- O.selectTable sourcerecoveryapprovalsTable
    O.where_ (sourcerecoveryapprovalsObligationId row O..== O.sqlStrictText intent O..&& sourcerecoveryapprovalsRestorationSequence row O..== O.sqlInt8 restoration)
    pure(sourcerecoveryapprovalsReason row)
    :: IO [Text]
  case rows of []->pure Nothing; [reason]->pure(Just reason); _->reject "duplicate_source_approval"
recoveryApproval :: Ledger -> Text -> Int64 -> IO (Maybe Text)
recoveryApproval ledger intent restoration = ledgerAction ledger (\c->recoveryApprovalC c intent restoration)

recoveryContextC :: PG.Connection -> Bool -> Text -> Int64 -> IO (Obligation,Text,Int64,Text,Maybe Int64)
recoveryContextC c covered intent restoration = do
  rows <- O.runSelect c $ do
    ob <- O.selectTable obligationsTable
    deposit <- O.selectTable depositsTable
    O.where_ (obligationsId ob O..== O.sqlStrictText intent O..&& obligationsDepositId ob O..== depositsId deposit)
    pure(ob,deposit)
    :: IO [(Obligations,Deposits)]
  (ob,deposit) <- case rows of [pair]->pure pair; _->reject "source_approval_not_expected"
  history <- O.runSelect c $ do
    row <- O.selectTable sourcerecoveriesTable
    O.where_ (sourcerecoveriesDepositId row O..== O.sqlStrictText (depositsId deposit))
    pure row
    :: IO [SourceRecoveries]
  require (obligationsStatus ob=="review" && case reverse(sortOn sourcerecoveriesId history) of
    current:_->sourcerecoveriesCriticalSequence current==restoration &&
      if covered then depositsAsset deposit=="Native" && depositsEligible deposit==0 && sourcerecoveriesState current=="missing" && sourcerecoveriesShortfall current==depositsAmount deposit
      else depositsEligible deposit==1 && sourcerecoveriesState current=="restored" && sourcerecoveriesShortfall current==0
    _->False) "source_approval_not_expected"
  cover <- if covered then activeCoverC c deposit >>= maybe (reject "source_loss_not_covered") (pure . Just) else pure Nothing
  approvals <- O.runSelect c $ do
    row <- O.selectTable sourcerecoveryapprovalsTable
    O.where_ (sourcerecoveryapprovalsObligationId row O..== O.sqlStrictText intent)
    pure(sourcerecoveryapprovalsCriticalSequence row)
    :: IO [Int64]
  let cutoff=maximum(0:approvals)
      eligible=[row | row<-reverse(sortOn sourcerecoveriesId history),sourcerecoveriesCriticalSequence row>cutoff,sourcerecoveriesCriticalSequence row<restoration]
  reviews <- mapM (\row->do
    evidence <- decodeRecord "invalid_source_recovery_evidence" (sourcerecoveriesEvidenceJson row)
    case evidence of
      Object fields | KM.lookup "reason" fields==Just(String "source_eligibility_lost")->do
        entries <- fieldValue "reviewedObligations" evidence :: IO [Value]
        matches <- fmap catMaybes $ mapM (\entry->do
          target <- fieldValue "intent" entry
          if target/=intent then pure Nothing else do
            previous <- fieldValue "previousStatus" entry
            expected <- fieldValue "workHash" entry
            pure(Just(sourcerecoveriesCriticalSequence row,previous,expected))) entries
        case matches of []->pure Nothing; [match]->pure(Just match); _->reject "source_review_context_missing"
      _->pure Nothing) eligible
  (loss,previous,expected) <- case catMaybes reviews of
    match@(_,state,_):_ | state `elem` ["ready","paying"]->pure match
    _->reject "source_review_context_missing"
  actual <- sourceWorkHashC c intent
  require (actual==expected) "source_review_work_changed"
  cancellations <- O.runSelect c $ do
    row <- O.selectTable preparationcancellationsTable
    O.where_ (preparationcancellationsIntentId row O..== O.sqlStrictText intent O..&& preparationcancellationsCompleted row O..== O.sqlInt8 0)
    pure(preparationcancellationsGeneration row)
    :: IO [Int64]
  require (null cancellations) "preparation_cancellation_pending"
  pure(asObligation ob,previous,loss,actual,cover)

recoveryObligation :: Ledger -> Text -> Int64 -> IO Obligation
recoveryObligation ledger intent restoration = ledgerAction ledger $ \c->do
  (ob,_,_,_,_) <- recoveryContextC c False intent restoration
  pure ob

recoveryRecord :: Ledger -> Text -> Int64 -> Int64 -> Text -> IO ()
recoveryRecord = recordApproval False Nothing

coveredRecord :: Ledger -> Text -> Int64 -> Int64 -> Text -> Value -> IO ()
coveredRecord ledger intent sequenceNo now reason proof = recordApproval True (Just proof) ledger intent sequenceNo now reason

coveredObligation :: Ledger -> Text -> Int64 -> IO Obligation
coveredObligation ledger intent sequenceNo = ledgerAction ledger $ \c->do
  (ob,_,_,_,_) <- recoveryContextC c True intent sequenceNo
  pure ob

coveredApproval :: Ledger -> Text -> Int64 -> IO (Maybe Text)
coveredApproval ledger intent sequenceNo = ledgerAction ledger $ \c->do
  old <- recoveryApprovalC c intent sequenceNo
  case old of
    Nothing->pure Nothing
    Just reason->do
      rows <- O.runSelect c $ matching (\r->sourcerecoveryapprovalsObligationId r O..== O.sqlStrictText intent O..&& sourcerecoveryapprovalsRestorationSequence r O..== O.sqlInt8 sequenceNo) (O.selectTable sourcerecoveryapprovalsTable) :: IO [SourceRecoveryApprovals]
      require (case rows of [r]->proofCover (sourcerecoveryapprovalsProofJson r)/=Nothing; _->False) "source_approval_kind_mismatch"
      pure(Just reason)

recordApproval :: Bool -> Maybe Value -> Ledger -> Text -> Int64 -> Int64 -> Text -> IO ()
recordApproval covered sourceProof ledger intent restoration now reason = ledgerAction ledger $ \c->do
  require (restoration>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
  states <- O.runSelect c (fmap deploymentPaused $ O.selectTable deploymentTable) :: IO [Int64]
  require (states==[1]) "pause_before_operator_action"
  old <- recoveryApprovalC c intent restoration
  case old of
    Just previous->do
      require(previous==reason) "source_approval_conflict"
      rows <- O.runSelect c $ matching (\r->sourcerecoveryapprovalsObligationId r O..== O.sqlStrictText intent O..&& sourcerecoveryapprovalsRestorationSequence r O..== O.sqlInt8 restoration) (O.selectTable sourcerecoveryapprovalsTable) :: IO [SourceRecoveryApprovals]
      require (case rows of [r]->covered==(proofCover(sourcerecoveryapprovalsProofJson r)/=Nothing); _->False) "source_approval_kind_mismatch"
    Nothing->do
      (ob,previous,loss,workHash,cover) <- recoveryContextC c covered intent restoration
      freshC c now
      checks <- O.runSelect c (O.selectTable custodycheckTable) :: IO [CustodyCheck]
      when covered $ do
        evidence <- maybe (reject "source_loss_not_proven") pure sourceProof
        txid <- fieldValue "transaction" evidence :: IO Text
        index <- fieldValue "output" evidence :: IO Int64
        depth <- fieldValue "confirmations" evidence :: IO Int64
        observedHash <- fieldValue "observationHash" evidence :: IO Text
        sourceBlock <- fieldValue "nodeBlock" evidence :: IO Text
        sourceHeight <- fieldValue "nodeHeight" evidence :: IO Int64
        require (depth<0 && index>=0 && obligationDeposit ob=="native:"<>txid<>":"<>T.pack(show index)) "source_loss_not_proven"
        hashes <- O.runSelect c $ do
          event <- O.selectTable chaineventsTable
          O.where_(chaineventsChain event O..== O.sqlStrictText "Native" O..&& chaineventsEventId event O..== O.sqlStrictText txid O..&& chaineventsNeedsReview event O..== O.sqlInt8 0)
          pure(chaineventsEvidenceHash event)
          :: IO [Text]
        require (hashes==[observedHash]) "source_recovery_scan_not_current"
        report <- case checks of
          [r] | Just saved<-custodycheckReportJson r->decodeRecord "custody_not_reconciled" saved
          _->reject "custody_not_reconciled"
        matched <- fieldValue "matches" report :: IO Bool
        block <- fieldValue "nativeBlock" report :: IO Text
        height <- fieldValue "nativeHeight" report :: IO Int64
        require (matched && block==sourceBlock && height==sourceHeight) "source_loss_custody_view_changed"
      let proof=encodeRecord $ object $
            ["custody" .= [(custodycheckRevision row,custodycheckCheckedAt row,custodycheckReportJson row) | row<-checks],"sourceRestoration" .= restoration] <> maybe [] (\n->["sourceCover" .= n,"source" .= sourceProof]) cover
      require (T.length proof<=32768) "source_approval_evidence_too_large"
      sequenceNo <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=sourcerecoveryapprovalsTable,O.iRows=[SourceRecoveryApprovals (O.sqlStrictText intent) (O.sqlInt8 restoration) (O.sqlInt8 loss) (O.sqlStrictText previous) (O.sqlStrictText workHash) (O.sqlStrictText reason) (O.sqlStrictText proof) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \row->row {obligationsStatus=O.sqlStrictText previous},O.uWhere= \row->obligationsId row O..== O.sqlStrictText intent,O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "source_recovery_approved") (O.sqlStrictText intent)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()

-- A capital cover is not a physical deposit. Authorization stays attached to
-- one immutable obligation and its active cover; neither changes eligibility.
activeCoverC :: PG.Connection -> Deposits -> IO (Maybe Int64)
activeCoverC c deposit = do
  rows <- unreturnedCoversC c (depositsId deposit)
  case [sourcelosscoversCriticalSequence r | r<-rows,sourcelosscoversAmount r==depositsAmount deposit] of
    []->pure Nothing
    [n]->pure(Just n)
    _->reject "duplicate_source_loss_cover"

proofCover :: Text -> Maybe Int64
proofCover proof = case eitherDecodeStrict' (TE.encodeUtf8 proof) of
  Right (Object fields) | Just value<-KM.lookup "sourceCover" fields->case Data.Aeson.fromJSON value of
    Data.Aeson.Success n | n>0->Just n
    _->Nothing
  _->Nothing

coveredAuthorizedC :: PG.Connection -> Text -> IO Bool
coveredAuthorizedC c intent = do
  rows <- O.runSelect c $ do
    ob <- O.selectTable obligationsTable
    d <- O.selectTable depositsTable
    O.where_(obligationsId ob O..== O.sqlStrictText intent O..&& obligationsDepositId ob O..== depositsId d)
    pure(ob,d)
    :: IO [(Obligations,Deposits)]
  case rows of
    [(ob,d)] | depositsAsset d=="Native" && depositsEligible d==0 && obligationsStatus ob `elem` ["ready","paying"]->do
      accounted <- O.runSelect c $ do
        did <- Order.accountedLosses
        O.where_(did O..== O.sqlStrictText(depositsId d))
        pure did
        :: IO [Text]
      txid <- case T.splitOn ":" (depositsId d) of
        ["native",tx,_]->pure tx
        _->reject "invalid_native_deposit_id"
      events <- O.runSelect c $ do
        event <- O.selectTable chaineventsTable
        O.where_(chaineventsChain event O..== O.sqlStrictText "Native" O..&& chaineventsEventId event O..== O.sqlStrictText txid O..&& chaineventsNeedsReview event O..== O.sqlInt8 0 O..&&
          (chaineventsKind event O..== O.sqlStrictText "incoming" O..|| chaineventsKind event O..== O.sqlStrictText "unmatched_incoming"))
        pure(chaineventsEventId event)
        :: IO [Text]
      cover <- activeCoverC c d
      approvals <- O.runSelect c $ matching (\r->sourcerecoveryapprovalsObligationId r O..== O.sqlStrictText intent) (O.selectTable sourcerecoveryapprovalsTable) :: IO [SourceRecoveryApprovals]
      pure (accounted==[depositsId d] && events==[txid] && case cover of
        Just n->any (\r->proofCover(sourcerecoveryapprovalsProofJson r)==Just n && sourcerecoveryapprovalsCriticalSequence r>n) approvals
        Nothing->False)
    _->pure False

coveredAuthorized :: Ledger -> Text -> IO Bool
coveredAuthorized ledger intent = ledgerAction ledger (\c->coveredAuthorizedC c intent)

authorizedC :: PG.Connection -> Text -> IO Bool
authorizedC c intent = do
  rows <- O.runSelect c $ do
    ob <- O.selectTable obligationsTable
    d <- O.selectTable depositsTable
    O.where_(obligationsId ob O..== O.sqlStrictText intent O..&& obligationsDepositId ob O..== depositsId d)
    pure(depositsEligible d)
    :: IO [Int64]
  if rows==[1] then pure True else coveredAuthorizedC c intent

-- Typed read of the latest recovery view, matching the legacy candidate rules.
sourceStateTable :: O.Table (O.Field O.SqlText,O.Field O.SqlText) (O.Field O.SqlText,O.Field O.SqlText)
sourceStateTable = O.table "source_recovery_state" (p2 (O.requiredTableField "deposit_id",O.requiredTableField "state"))
candidates :: Ledger -> IO [Deposit]
candidates ledger = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc depositsFirstSeen <> O.asc depositsId) $ do
    (deposit,(_,state)) <- (O.leftJoin (O.selectTable depositsTable) (O.selectTable sourceStateTable)
      (\(deposit,(did,_))->depositsId deposit O..== did)
      :: O.Select (DepositsRead,(O.FieldNullable O.SqlText,O.FieldNullable O.SqlText)))
    O.where_ (depositsAsset deposit O..== O.sqlStrictText "Native" O..&&
      (depositsEligible deposit O..== O.sqlInt8 0 O..|| O.matchNullable (O.sqlBool False) (\value->value O../= O.sqlStrictText "restored") state))
    pure deposit
    :: IO [Deposits]
  mapM asNativeDeposit rows

asNativeDeposit :: Deposits -> IO Deposit
asNativeDeposit row = do
  require (depositsAsset row=="Native" && depositsConfirmations row>=0 && toInteger(depositsConfirmations row)<=toInteger(maxBound::Int)) "invalid_native_source_receipt"
  quantity <- either reject pure(amount $ toInteger $ depositsAmount row)
  pure(Deposit (depositsId row) (depositsOrderId row) Native quantity (depositsAnchor row) (fromIntegral $ depositsConfirmations row) (depositsEligible row==1) (depositsFirstSeen row))

recordCheck :: Ledger -> Deposit -> SourceCheck -> IO ()
recordCheck ledger expected check = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    row <- O.selectTable depositsTable
    O.where_(depositsId row O..== O.sqlStrictText (depositId expected))
    pure row
    :: IO [Deposits]
  current <- mapM asNativeDeposit rows
  require (current==[expected]) "source_recovery_changed"
  let proof=case check of SourcePending p->Just p; SourceMissing p->Just p; SourceRestored p->Just p; SourceUnavailable _->Nothing
  forM_ proof $ \value->do
    expectedHash <- fieldValue "observationHash" value :: IO Text
    txid <- case T.splitOn ":" (depositId expected) of ["native",tx,_]->pure tx; _->reject "invalid_native_deposit_id"
    hashes <- O.runSelect c $ do
      event <- O.selectTable chaineventsTable
      O.where_(chaineventsChain event O..== O.sqlStrictText "Native" O..&& chaineventsEventId event O..== O.sqlStrictText txid)
      pure(chaineventsEvidenceHash event)
      :: IO [Text]
    require (hashes==[expectedHash]) "source_recovery_scan_not_current"
  recordSourceCheckC c (depositId expected) check

orderBinding :: Ledger -> Text -> IO (Text,Text)
orderBinding ledger oid = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    row <- O.selectTable ordersTable
    O.where_(ordersId row O..== O.sqlStrictText oid)
    pure(ordersInstruction row,ordersPolicyJson row)
    :: IO [(Maybe Text,Text)]
  case rows of [(Just instruction,policy)]->pure(instruction,policy); _->reject "native_source_binding_missing"

eventEvidence :: Ledger -> Text -> IO (Text,Text)
eventEvidence ledger txid = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    event <- O.selectTable chaineventsTable
    evidence <- O.selectTable observationevidenceTable
    O.where_ (chaineventsChain event O..== O.sqlStrictText "Native" O..&& chaineventsEventId event O..== O.sqlStrictText txid O..&&
      (chaineventsKind event O..== O.sqlStrictText "incoming" O..|| chaineventsKind event O..== O.sqlStrictText "unmatched_incoming") O..&&
      chaineventsNeedsReview event O..== O.sqlInt8 0 O..&& chaineventsEvidenceHash event O..== observationevidenceHash evidence)
    pure(chaineventsEvidenceHash event,observationevidenceEvidenceJson evidence)
    :: IO [(Text,Text)]
  case rows of [saved]->pure saved; _->reject "source_recovery_scan_not_current"

-- All cover consumers exclude returned capital by the same immutable sequence.
-- Keep this query inside the source-recovery operations' ledger transaction.
unreturnedCoversC :: PG.Connection -> Text -> IO [SourceLossCovers]
unreturnedCoversC c did=do
  covers <- O.runSelect c $ matching
    (\row->sourcelosscoversDepositId row O..== O.sqlStrictText did)
    (O.selectTable sourcelosscoversTable)
  returns <- O.runSelect c $ do
    returned <- O.selectTable sourcelossreturnsTable
    cover <- O.selectTable sourcelosscoversTable
    O.where_ (sourcelossreturnsCoverSequence returned O..== sourcelosscoversCriticalSequence cover
      O..&& sourcelosscoversDepositId cover O..== O.sqlStrictText did)
    pure (sourcelossreturnsCoverSequence returned)
    :: IO [Int64]
  pure [row | row<-covers,sourcelosscoversCriticalSequence row `notElem` returns]

lossCoverRowsC :: PG.Connection -> Text -> Int64 -> IO [SourceLossCovers]
lossCoverRowsC c did recovery=O.runSelect c $ do
  r <- O.selectTable sourcelosscoversTable
  O.where_(sourcelosscoversDepositId r O..== text did O..&& sourcelosscoversRecoverySequence r O..== num recovery)
  pure r
lossCapitalOf :: SourceLossCovers -> IO LossCapital
lossCapitalOf row=LossCapital <$> quantity(sourcelosscoversFloatAmount row) <*> quantity(sourcelosscoversEarnedAmount row)
 where quantity=either reject pure . amount . toInteger
lossCoverDecision :: Ledger -> Text -> Int64 -> IO (Maybe(LossCapital,Text))
lossCoverDecision ledger did recovery=ledgerAction ledger $ \c->do
  rows <- lossCoverRowsC c did recovery
  case rows of
    []->pure Nothing
    [r]->do
      capital <- lossCapitalOf r
      pure(Just(capital,sourcelosscoversReason r))
    _->reject "duplicate_source_loss_cover"

recordLossCover :: Ledger -> Deposit -> Int64 -> Int64 -> LossCapital -> Text -> Value -> Value -> IO ()
recordLossCover ledger source recovery now capital reason sourceProof custodyProof=ledgerAction ledger $ \c->do
  require (recovery>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_loss_cover"
  state <- O.runSelect c $ fmap deploymentPaused $ O.selectTable deploymentTable :: IO [Int64]
  require (state==[1]) "pause_before_operator_action"
  let did=depositId source
      fromFloat=units(lossFloat capital)
      fromEarned=units(lossEarned capital)
      quantity=units(depositAmount source)
  old <- lossCoverRowsC c did recovery
  case old of
    [r]->do saved <- lossCapitalOf r; require (saved==capital && sourcelosscoversReason r==reason) "source_loss_cover_conflict"
    []->do
      require (depositAsset source==Native && not(depositEligible source)) "source_loss_not_proven"
      deposits <- O.runSelect c $ do
        row <- O.selectTable depositsTable
        O.where_(depositsId row O..== text did O..&& depositsAsset row O..== text "Native" O..&& depositsEligible row O..== num 0)
        pure row
        :: IO [Deposits]
      history <- O.runSelect c $ O.limit 1 $ O.orderBy (O.desc sourcerecoveriesId) $ do
        row <- O.selectTable sourcerecoveriesTable
        O.where_(sourcerecoveriesDepositId row O..== text did)
        pure row
        :: IO [SourceRecoveries]
      require (toInteger fromFloat+toInteger fromEarned==toInteger quantity) "source_loss_allocation_mismatch"
      require (case (deposits,history) of
        ([d],[r])->depositsOrderId d==depositOrder source && depositsAmount d==quantity && depositsAnchor d==depositAnchor source &&
          depositsConfirmations d==fromIntegral(depositConfirmations source) && depositsFirstSeen d==depositSeenAt source &&
          sourcerecoveriesState r=="missing" && sourcerecoveriesShortfall r==quantity && sourcerecoveriesCriticalSequence r==recovery
        _->False) "source_loss_not_proven"
      covers <- unreturnedCoversC c did
      require (null covers) "source_loss_already_covered"
      txid <- fieldValue "transaction" sourceProof :: IO Text
      index <- fieldValue "output" sourceProof :: IO Int64
      observationHash <- fieldValue "observationHash" sourceProof :: IO Text
      depth <- fieldValue "confirmations" sourceProof :: IO Int64
      require (depth<0 && index>=0 && did=="native:"<>txid<>":"<>T.pack(show index)) "source_loss_not_proven"
      observed <- O.runSelect c $ do
        e <- O.selectTable chaineventsTable
        O.where_(chaineventsChain e O..== text "Native" O..&& chaineventsEventId e O..== text txid O..&& chaineventsNeedsReview e O..== num 0)
        pure(chaineventsEvidenceHash e)
        :: IO [Text]
      require (observed==[observationHash]) "source_recovery_scan_not_current"
      revision <- fieldValue "revision" custodyProof :: IO Int64
      checked <- fieldValue "checkedAt" custodyProof :: IO Int64
      report <- fieldValue "report" custodyProof :: IO Value
      matched <- fieldValue "matches" report :: IO Bool
      block <- fieldValue "nativeBlock" report :: IO Text
      height <- fieldValue "nativeHeight" report :: IO Int64
      sourceBlock <- fieldValue "nodeBlock" sourceProof :: IO Text
      sourceHeight <- fieldValue "nodeHeight" sourceProof :: IO Int64
      require (block==sourceBlock && height==sourceHeight) "source_loss_custody_view_changed"
      current <- O.runSelect c $ fmap custodycheckRevision $ O.selectTable custodycheckTable :: IO [Int64]
      require (matched && current==[revision] && checked>=0 && checked<=now && toInteger now-toInteger checked<=60) "source_loss_custody_not_current"
      bs <- balances c
      held <- O.runSelect c $ do
        r <- O.selectTable reservationsTable
        O.where_(reservationsAsset r O..== text "Native" O..&& reservationsPhase r O../= text "released")
        pure(reservationsAmount r)
        :: IO [Int64]
      let free=M.findWithDefault 0 ("Native","float") bs-sum(map toInteger held)
          earned=M.findWithDefault 0 ("Native","earned") bs
      require (free>=toInteger fromFloat && earned>=toInteger fromEarned) "insufficient_loss_capital"
      let proof=encodeRecord $ object["source" .= sourceProof,"custody" .= custodyProof]
      require (T.length proof<=32768) "source_loss_evidence_too_large"
      sequenceNo <- criticalSequence c
      count <- O.runInsert c O.Insert {O.iTable=sourcelosscoversTable,O.iRows=[SourceLossCovers (num sequenceNo) (text did) (num recovery) (num quantity) (num fromFloat) (num fromEarned) (text reason) (text proof)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "source_loss_cover_insert_failed"
      posting c ("source-loss-cover:"<>T.pack(show sequenceNo)) "operator capital covers verified source shortfall" [(Native,"float",negate $ toInteger fromFloat),(Native,"earned",negate $ toInteger fromEarned),(Native,"source_deficit",toInteger quantity)]
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "source_loss_covered") (text did)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    _->reject "duplicate_source_loss_cover"

text :: Text -> O.Field O.SqlText
text=O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num=O.sqlInt8
