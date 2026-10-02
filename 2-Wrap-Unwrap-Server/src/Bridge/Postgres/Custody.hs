module Bridge.Postgres.Custody (readSnapshot, readRevision, hasEvent, recordCheck, eventProof, checkFresh, freshC) where

import qualified Database.PostgreSQL.Simple as PG
import Bridge.Ledger.Model (encodeRecord, decodeRecord, View(..))
import Bridge.Config
import Bridge.Types
import Bridge.Postgres.Ledger (Ledger,ledgerAction)
import Bridge.Postgres.Schema
import Control.Monad (forM_,when)
import Data.Aeson (Value, FromJSON)
import Bridge.RPC (fieldValue)
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Opaleye as O
import Text.Read (readMaybe)

-- A revision-bound snapshot grants no payment permission by itself.
readSnapshot :: Config -> Ledger -> Int64 -> Bool -> IO View
readSnapshot cfg ledger now inspectLosses = ledgerAction ledger $ \connection->do
  checks <- O.runSelect connection (O.selectTable custodycheckTable) :: IO [CustodyCheck]
  current <- case checks of [row]->pure (custodycheckRevision row); _->reject "custody_check_missing"
  scans <- O.runSelect connection $ do
    health <- O.selectTable scanhealthTable
    checkpoint <- O.selectTable checkpointsTable
    O.where_ (scanhealthChain health O..== checkpointsChain checkpoint)
    pure (scanhealthChain health,scanhealthLastSuccess health,scanhealthLastError health,checkpointsAnchor checkpoint)
    :: IO [(Text,Maybe Int64,Maybe Text,Text)]
  let ordered=sortOn (\(chain,_,_,_)->chain) scans
  require (now>=0 && map (\(chain,_,_,_)->chain) ordered==["Native","Solana","SolanaOperating"] &&
    all (\(_,at,err,anchor)->err==Nothing && not (T.null anchor) && maybe False (\time->time>=0 && time<=now && toInteger now-toInteger time<=60) at) ordered) "scanners_not_fresh"
  origins <- O.runSelect connection (O.selectTable scanoriginsTable) :: IO [ScanOrigins]
  require ([(scanoriginsChain row,Just (scanoriginsAnchor row)) | row<-sortOn scanoriginsChain origins]==
    [("Native",Just (nativeCheckpointHash cfg)),("Solana",solanaHistoryStart cfg),("SolanaOperating",solanaOperatingHistoryStart cfg)]) "custody_scan_origin_mismatch"
  events <- O.runSelect connection (O.selectTable chaineventsTable) :: IO [ChainEvents]
  require (all ((==0).chaineventsNeedsReview) events) "chain_observations_require_review"
  accounted <- O.runSelect connection (O.selectTable (textColumn "accounted_source_losses" "deposit_id")) :: IO [Text]
  proven <- O.runSelect connection (O.selectTable (textColumn "proven_source_losses" "deposit_id")) :: IO [Text]
  let ignored did=did `elem` accounted || inspectLosses && did `elem` proven
  deposits <- O.runSelect connection $ do
    row <- O.selectTable depositsTable
    O.where_ (depositsAllocated row O..== O.sqlInt8 1 O..&& depositsEligible row O..== O.sqlInt8 0)
    pure (depositsId row)
    :: IO [Text]
  require (all ignored deposits) "source_reorg_requires_review"
  recovery <- O.runSelect connection (O.selectTable sourcerecoveriesTable) :: IO [SourceRecoveries]
  let latest=M.fromListWith (\left right->if sourcerecoveriesId left>sourcerecoveriesId right then left else right)
        [(sourcerecoveriesDepositId row,row) | row<-recovery]
  require (all (\row->sourcerecoveriesState row=="restored" || ignored (sourcerecoveriesDepositId row)) (M.elems latest)) "source_recovery_requires_review"
  nativeHistory <- O.runSelect connection $ do
    state <- O.selectTable (textColumn "native_payment_recovery_state" "state")
    pure state
    :: IO [Text]
  require (all (=="reconfirmed") nativeHistory) "native_settlement_requires_review"
  attempts <- O.runSelect connection $ do
    attempt <- O.selectTable attemptsTable
    intent <- O.selectTable intentsTable
    O.where_ (attemptsIntentId attempt O..== intentsId intent)
    pure (attempt,intentsChain intent)
    :: IO [(Attempts,Text)]
  proofs <- O.runSelect connection (O.selectTable observationevidenceTable) :: IO [ObservationEvidence]
  let eventMap=M.fromList [((chaineventsChain row,chaineventsEventId row),row) | row<-events]
      proofMap=M.fromList [(observationevidenceHash row,observationevidenceEvidenceJson row) | row<-proofs]
      findEvent chain txid=maybe (reject "settled_payment_observation_changed") pure (M.lookup (chain,txid) eventMap)
  forM_ attempts $ \(attempt,chain)->when (attemptsState attempt=="settled") $ do
    event <- findEvent chain (attemptsTxid attempt)
    require (chaineventsKind event=="outgoing") "settled_payment_observation_changed"
    observation <- maybe (reject "invalid_reconciliation_evidence") decode (attemptsObservationJson attempt)
    saved <- fieldValue "proof" observation >>= decode
    if chain=="Native" then do
      anchor <- fieldValue "blockhash" saved
      depth <- fieldValue "requiredDepth" saved :: IO Int64
      evidence <- maybe (reject "invalid_reconciliation_evidence") decode (M.lookup (chaineventsEvidenceHash event) proofMap)
      proof <- fieldValue "proof" evidence
      confirmations <- fieldValue "confirmations" proof :: IO Int64
      require (chaineventsAnchor event==anchor && confirmations>=depth) "settled_payment_observation_changed"
    else do
      outcome <- fieldValue "outcome" saved
      height <- fieldValue "outcomeSlot" outcome :: IO Int64
      require (chaineventsAnchor event==T.pack (show height)) "settled_payment_observation_changed"
  forM_ attempts $ \(attempt,chain)->when (chain=="Solana" && attemptsState attempt `elem` ["settled","failed"]) $ do
    operating <- findEvent "SolanaOperating" (attemptsTxid attempt)
    token <- findEvent "Solana" (attemptsTxid attempt)
    observation <- maybe (reject "invalid_reconciliation_evidence") decode (attemptsObservationJson attempt)
    saved <- if attemptsState attempt=="settled" then fieldValue "proof" observation >>= decode else pure observation
    outcome <- fieldValue "outcome" saved
    height <- fieldValue "outcomeSlot" outcome :: IO Int64
    require (chaineventsKind operating=="outgoing" && chaineventsAnchor operating==T.pack (show height) &&
      chaineventsAnchor token==chaineventsAnchor operating && chaineventsKind token==(if attemptsState attempt=="settled" then "outgoing" else "failed")) "booked_solana_observation_changed"
  postings <- O.runSelect connection (O.selectTable postingsTable) :: IO [Postings]
  let summed=M.fromListWith (\(a,b) (c,d)->(a+c,b+d)) [(postingsAsset row,(if postingsAccount row=="external" then 0 else toInteger (postingsDelta row),toInteger (postingsDelta row))) | row<-postings]
  require (all (\(asset,(owned,total))->asset `elem` ["Native","Wrapped","Sol"] && owned>=0 && total==0) (M.toList summed)) "invalid_custody_journal"
  numbers <- mapM (\(chain,_,_,signature)->do
    event <- findEvent chain signature
    maybe (reject "custody_history_anchor_missing") pure (readMaybe (T.unpack (chaineventsAnchor event)))) (filter (\(chain,_,_,_)->chain/="Native") ordered)
  require (length numbers==2 && all (>=0) numbers) "custody_history_anchor_missing"
  pure (View current (M.fromList [(asset,maybe 0 fst (M.lookup asset summed)) | asset<-["Native","Wrapped","Sol"]]) [(chain,anchor) | (chain,_,_,anchor)<-ordered] (maximum numbers))

recordCheck :: Ledger -> Int64 -> Int64 -> Maybe Text -> Maybe Value -> IO ()
recordCheck ledger expected now failure report = ledgerAction ledger $ \connection->do
  checks <- O.runSelect connection (O.selectTable custodycheckTable) :: IO [CustodyCheck]
  old <- case checks of [row]->pure row; _->reject "custody_check_missing"
  require (custodycheckRevision old==expected) "custody_ledger_changed"
  forM_ failure $ \code->do
    when (custodycheckLastError old/=Just code) $ do
      _ <- O.runInsert connection O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "custody_failure") (O.sqlStrictText code)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    when (code `notElem` ["custody_native_history_advanced","custody_solana_history_advanced","custody_ledger_changed"]) $ do
      _ <- O.runUpdate connection O.Update {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 1,deploymentPauseReason=O.sqlStrictText ("custody:"<>code)},O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount}
      pure ()
  _ <- O.runUpdate connection O.Update
    {O.uTable=custodycheckTable,O.uUpdateWith= \row->row {custodycheckCheckedRevision=if report==Nothing then O.null else O.toNullable (O.sqlInt8 expected),custodycheckCheckedAt=O.toNullable (O.sqlInt8 now),custodycheckLastError=maybe O.null (O.toNullable . O.sqlStrictText) failure,custodycheckReportJson=maybe O.null (O.toNullable . O.sqlStrictText . encodeRecord) report},O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount}
  pure ()

eventProof :: Ledger -> Text -> Text -> IO (Text,Text,Value)
eventProof ledger stream txid = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    event <- O.selectTable chaineventsTable
    proof <- O.selectTable observationevidenceTable
    O.where_ (chaineventsChain event O..== O.sqlStrictText stream O..&& chaineventsEventId event O..== O.sqlStrictText txid O..&& chaineventsNeedsReview event O..== O.sqlInt8 0 O..&& chaineventsEvidenceHash event O..== observationevidenceHash proof)
    pure (chaineventsKind event,chaineventsAnchor event,observationevidenceEvidenceJson proof)
    :: IO [(Text,Text,Text)]
  case rows of
    [(kind,anchor,saved)]->do
      proof <- decode saved >>= fieldValue "proof"
      pure (kind,anchor,proof)
    _->reject "custody_history_not_current"

decode :: FromJSON a => Text -> IO a
decode = decodeRecord "invalid_reconciliation_evidence"

textColumn :: String -> String -> O.Table (O.Field O.SqlText) (O.Field O.SqlText)
textColumn name column = O.table name (O.requiredTableField column)

freshC :: PG.Connection -> Int64 -> IO ()
freshC c now = do
  checks <- O.runSelect c(O.selectTable custodycheckTable) :: IO [CustodyCheck]
  require (case checks of
    [r]->custodycheckCheckedRevision r==Just(custodycheckRevision r) && custodycheckLastError r==Nothing && maybe False (\at->at>=0 && at<=now && toInteger now-toInteger at<=60) (custodycheckCheckedAt r)
    _->False) "custody_not_reconciled"

readRevision :: Ledger -> IO Int64
readRevision ledger = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection (fmap custodycheckRevision $ O.selectTable custodycheckTable) :: IO [Int64]
  case rows of [revision]->pure revision; _->reject "custody_check_missing"
hasEvent :: Ledger -> Text -> Text -> IO Bool
hasEvent ledger txid chain = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable chaineventsTable
    O.where_ (chaineventsEventId row O..== O.sqlStrictText txid O..&&
      (chaineventsChain row O..== O.sqlStrictText chain O..|| chaineventsChain row O..== O.sqlStrictText (if chain=="Solana" then "SolanaOperating" else "Native")))
    pure (chaineventsEventId row)
    :: IO [Text]
  pure (not $ null rows)

checkFresh :: Ledger -> Int64 -> IO ()
checkFresh ledger now = ledgerAction ledger (\c->freshC c now)
