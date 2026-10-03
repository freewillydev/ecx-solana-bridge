module Bridge.Postgres.Observation
  ( refreshDeposit, recordScan, readCheckpoint, lookupInstruction, maximumNativeDepth, pendingVerification, lookupReferences, promotionCandidates, commitScan, recordScanFailure, promoteDeposit ) where

import Bridge.Types
import Bridge.Ledger.Model (encodeRecord, decodeRecord, Deposit(..), SourceCheck(..), ScanBatch(..), ChainEvent(..), economicOutflow)
import Bridge.Postgres.Source (recordSourceCheckC, sourceWorkHashC)
import Bridge.Postgres.Ledger (Ledger, ledgerAction, posting)
import Bridge.Postgres.Schema
import Control.Monad (when, forM, forM_)
import Data.Aeson (FromJSON, object, (.=), Value)
import Data.List (sortOn)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

scanAssets :: [(Text,Asset)]
scanAssets=[("Native",Native),("Solana",Wrapped),("SolanaOperating",Sol)]

readCheckpoint :: Ledger -> Text -> IO (Maybe Text)
readCheckpoint ledger chain = ledgerAction ledger (\connection->readCheckpointC connection chain)
readCheckpointC :: PG.Connection -> Text -> IO (Maybe Text)
readCheckpointC connection chain = do
  rows <- O.runSelect connection $ do
    row <- O.selectTable checkpointsTable
    O.where_ (checkpointsChain row O..== O.sqlStrictText chain)
    pure (checkpointsAnchor row)
    :: IO [Text]
  case rows of []->pure Nothing; [anchor]->pure (Just anchor); _->reject "duplicate_checkpoint"

recordScan :: Ledger -> Text -> Maybe Text -> Text -> [Deposit] -> IO ()
recordScan ledger chain previous next deposits = ledgerAction ledger $ \connection->do
  require (chain `elem` map fst scanAssets && not (T.null next) && T.length next<=128 && length deposits<=1000) "invalid_scan_batch"
  require (all (\deposit->Just (depositAsset deposit)==lookup chain scanAssets) deposits) "scan_asset_mismatch"
  current <- readCheckpointC connection chain
  require (current==previous) "stale_scan_cursor"
  mapM_ (observeDepositC connection) deposits
  case current of
    Nothing->do
      _ <- O.runInsert connection O.Insert {O.iTable=checkpointsTable,O.iRows=[Checkpoints (O.sqlStrictText chain) (O.sqlStrictText next)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    Just _->do
      _ <- O.runUpdate connection O.Update
        {O.uTable=checkpointsTable,O.uUpdateWith= \row->row {checkpointsAnchor=O.sqlStrictText next},O.uWhere= \row->checkpointsChain row O..== O.sqlStrictText chain,O.uReturning=O.rCount}
      pure ()

refreshDeposit :: Ledger -> Deposit -> IO ()
refreshDeposit ledger deposit = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    row <- O.selectTable depositsTable
    O.where_ (depositsId row O..== O.sqlStrictText(depositId deposit))
    pure(depositsId row)
    :: IO [Text]
  require (rows==[depositId deposit]) "source_deposit_missing"
  observeDepositC c deposit

observeDepositC :: PG.Connection -> Deposit -> IO ()
observeDepositC connection Deposit{..} = do
  require (units depositAmount>0 && depositConfirmations>=0 && depositSeenAt>=0) "invalid_deposit"
  case depositOrder of
    Nothing->pure ()
    Just oid->do
      orders <- O.runSelect connection $ do
        row <- O.selectTable ordersTable
        O.where_ (ordersId row O..== O.sqlStrictText oid)
        pure (ordersRequestJson row,ordersPolicyJson row)
        :: IO [(Text,Text)]
      case orders of
        [(requestJson,policyJson)]->do
          req <- decodeSaved requestJson
          savedPolicy <- decodeSaved policyJson
          require (sourceAsset (direction req)==depositAsset) "deposit_asset_mismatch"
          when (depositAsset==Native && depositEligible) $ require (depositConfirmations>=nativeDepth savedPolicy) "deposit_confirmation_policy_mismatch"
        _->reject "deposit_order_missing"
  existing <- O.runSelect connection $ do
    row <- O.selectTable depositsTable
    O.where_ (depositsId row O..== O.sqlStrictText depositId)
    pure row
    :: IO [Deposits]
  let eligible=if depositEligible then 1 else 0
      optionalOrder=maybe O.null (O.toNullable . O.sqlStrictText) depositOrder
  case existing of
    []->do
      _ <- O.runInsert connection O.Insert
        { O.iTable=depositsTable
        , O.iRows=[Deposits (O.sqlStrictText depositId) optionalOrder (O.sqlStrictText (T.pack (show depositAsset)))
            (O.sqlInt8 (units depositAmount)) (O.sqlStrictText depositAnchor) (O.sqlInt8 depositSeenAt)
            (O.sqlInt8 (fromIntegral depositConfirmations)) (O.sqlInt8 eligible) (O.sqlInt8 0) (O.sqlStrictText "observed")]
        , O.iReturning=O.rCount,O.iOnConflict=Nothing }
      let account=maybe "unallocated" (const "principal") depositOrder
      posting connection ("deposit:"<>depositId) "observed customer value"
        [(depositAsset,account,toInteger (units depositAmount)),(depositAsset,"external",negate (toInteger (units depositAmount)))]
    [old]->do
      require (depositsOrderId old==depositOrder && depositsAsset old==T.pack (show depositAsset) && depositsAmount old==units depositAmount) "conflicting_deposit_evidence"
      _ <- O.runUpdate connection O.Update
        { O.uTable=depositsTable
        , O.uUpdateWith= \row->row {depositsAnchor=O.sqlStrictText depositAnchor,depositsConfirmations=O.sqlInt8 (fromIntegral depositConfirmations),depositsEligible=O.sqlInt8 eligible}
        , O.uWhere= \row->depositsId row O..== O.sqlStrictText depositId,O.uReturning=O.rCount }
      when (depositsEligible old==1 && not depositEligible) $ do
        reviewed <- O.runSelect connection $ do
          row <- O.selectTable obligationsTable
          O.where_ (obligationsDepositId row O..== O.sqlStrictText depositId O..&&
            (obligationsStatus row O..== O.sqlStrictText "ready" O..|| obligationsStatus row O..== O.sqlStrictText "paying"))
          pure (obligationsId row,obligationsStatus row)
          :: IO [(Text,Text)]
        work <- forM reviewed $ \(intent,state)->do
          hash <- sourceWorkHashC connection intent
          pure (object ["intent" .= intent,"previousStatus" .= state,"workHash" .= hash])
        recordSourceCheckC connection depositId $ SourceUnavailable $ object
          ["reason" .= ("source_eligibility_lost"::Text),"previousAnchor" .= depositsAnchor old,"anchor" .= depositAnchor,"reviewedObligations" .= work]
      when (depositAsset/=Native && depositEligible) $ do
        history <- O.runSelect connection $ do
          row <- O.selectTable sourcerecoveriesTable
          O.where_ (sourcerecoveriesDepositId row O..== O.sqlStrictText depositId)
          pure row
          :: IO [SourceRecoveries]
        case reverse (sortOn sourcerecoveriesId history) of
          latest:_ | sourcerecoveriesState latest/="restored" && sourcerecoveriesShortfall latest==0 ->
            recordSourceCheckC connection depositId (SourceRestored (object ["anchor" .= depositAnchor,"verifiedBy" .= ("source_observer"::Text)]))
          _->pure ()
      when (not depositEligible && depositsAllocated old==1) $ do
        covered <- O.runSelect connection $ do
          did <- O.selectTable (O.table "accounted_source_losses" (O.requiredTableField "deposit_id"))
          O.where_ (did O..== O.sqlStrictText depositId)
          pure did
          :: IO [Text]
        when (null covered) $ do
          _ <- O.runUpdate connection O.Update
            {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 1,deploymentPauseReason=O.sqlStrictText "source_reorg_review"},O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount}
          _ <- O.runUpdate connection O.Update
            {O.uTable=obligationsTable,O.uUpdateWith= \row->row {obligationsStatus=O.sqlStrictText "review"},O.uWhere= \row->obligationsDepositId row O..== O.sqlStrictText depositId O..&& obligationsStatus row O../= O.sqlStrictText "paid" O..&& obligationsStatus row O../= O.sqlStrictText "cancelled",O.uReturning=O.rCount}
          pure ()
      pure ()
    _->reject "duplicate_deposit"

lookupInstruction :: Ledger -> Text -> IO (Maybe (Text,OrderRequest,PolicySnapshot))
lookupInstruction ledger instruction = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable ordersTable
    O.where_ (O.matchNullable (O.sqlBool False) (\value->value O..== O.sqlStrictText instruction) (ordersInstruction row))
    pure (ordersId row,ordersRequestJson row,ordersPolicyJson row)
    :: IO [(Text,Text,Text)]
  case rows of
    []->pure Nothing
    [(oid,req,savedPolicy)]->Just <$> ((,,) oid <$> decodeSaved req <*> decodeSaved savedPolicy)
    _->reject "duplicate_deposit_instruction"

maximumNativeDepth :: Ledger -> Int -> IO Int
maximumNativeDepth ledger minimumDepth = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ fmap ordersPolicyJson (O.selectTable ordersTable) :: IO [Text]
  policies <- mapM decodeSaved rows
  pure (maximum (minimumDepth:1:map nativeDepth policies))

decodeSaved :: FromJSON a => Text -> IO a
decodeSaved = decodeRecord "corrupt_ledger_json"

checkpointC :: PG.Connection -> Text -> Text -> IO ()
checkpointC connection chain anchor = do
  previous <- readCheckpointC connection chain
  case previous of
    Nothing->do
      _ <- O.runInsert connection O.Insert {O.iTable=checkpointsTable,O.iRows=[Checkpoints (O.sqlStrictText chain) (O.sqlStrictText anchor)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    Just _->do
      _ <- O.runUpdate connection O.Update
        {O.uTable=checkpointsTable,O.uUpdateWith= \row->row {checkpointsAnchor=O.sqlStrictText anchor},O.uWhere= \row->checkpointsChain row O..== O.sqlStrictText chain,O.uReturning=O.rCount}
      pure ()

commitScan :: Ledger -> ScanBatch -> IO ()
commitScan ledger ScanBatch{..} = ledgerAction ledger $ \connection->do
  require (scanChain `elem` map fst scanAssets && scanTime>=0 && length scanDeposits<=1000 && length scanEvents<=1000) "invalid_scan_batch"
  require (all (\anchor->not (T.null anchor) && T.length anchor<=128) [scanOrigin,scanNext]) "invalid_scan_anchor"
  require (all (\deposit->Just (depositAsset deposit)==lookup scanChain scanAssets) scanDeposits) "scan_asset_mismatch"
  previous <- readCheckpointC connection scanChain
  require (previous==scanPrevious) "stale_scan_cursor"
  origins <- O.runSelect connection $ do
    row <- O.selectTable scanoriginsTable
    O.where_ (scanoriginsChain row O..== O.sqlStrictText scanChain)
    pure (scanoriginsAnchor row)
    :: IO [Text]
  case origins of
    []->do
      _ <- O.runInsert connection O.Insert {O.iTable=scanoriginsTable,O.iRows=[ScanOrigins (O.sqlStrictText scanChain) (O.sqlStrictText scanOrigin)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    [origin]->require (origin==scanOrigin) "scan_origin_mismatch"
    _->reject "duplicate_scan_origin"
  mapM_ (observeDepositC connection) scanDeposits
  forM_ scanEvents $ \ChainEvent{..}->do
    require (not (T.null chainEventId) && T.length chainEventId<=128 && T.length chainEventAnchor<=128) "invalid_observation_identity"
    require (chainEventKind `elem` ["incoming","unmatched_incoming","outgoing","failed","reference","unsupported","unclassified","awaiting_verifier","disputed"]) "invalid_observation_kind"
    let evidence=encodeRecord (object ["chain" .= scanChain,"id" .= chainEventId,"anchor" .= chainEventAnchor,"kind" .= chainEventKind,"proof" .= chainEventEvidence])
        hash=digest (TE.encodeUtf8 evidence)
        paymentChain=if scanChain=="SolanaOperating" then "Solana" else scanChain
    require (T.length evidence<=8192) "observation_evidence_too_large"
    candidates <- O.runSelect connection $ do
      attempt <- O.selectTable attemptsTable
      intent <- O.selectTable intentsTable
      O.where_ (attemptsIntentId attempt O..== intentsId intent O..&& attemptsTxid attempt O..== O.sqlStrictText chainEventId O..&& intentsChain intent O..== O.sqlStrictText paymentChain)
      pure (attemptsState attempt,attemptsCriticalSequence attempt,attemptsObservationJson attempt)
      :: IO [(Text,Maybe Int64,Maybe Text)]
    formerWinners <- O.runSelect connection $ do
      row <- O.selectTable nativewinnerchangesTable
      O.where_ (nativewinnerchangesPreviousTxid row O..== O.sqlStrictText chainEventId)
      pure (nativewinnerchangesPreviousObservation row)
      :: IO [Text]
    let known=any (\(state,sequenceNo,observation)->state `elem` ["broadcast_intent","settled","failed"] ||
          state=="review" && paymentChain=="Native" && maybe False (>0) sequenceNo && maybe False (`elem` formerWinners) observation) candidates
    treasury <- O.runSelect connection $ do
      row <- O.selectTable treasuryspendsTable
      O.where_ (treasuryspendsChain row O..== O.sqlStrictText scanChain O..&& treasuryspendsEventId row O..== O.sqlStrictText chainEventId)
      pure (treasuryspendsAnchor row,treasuryspendsEconomicJson row)
      :: IO [(Text,Text)]
    let approved=case economicOutflow scanChain chainEventEvidence of Right economic->treasury==[(chainEventAnchor,encodeRecord economic)]; Left _->False
        review=chainEventKind `elem` ["unsupported","unclassified","disputed"] || chainEventKind=="outgoing" && not known && not approved
        reviewed=if review then 1 else 0
    proofs <- O.runSelect connection $ do
      row <- O.selectTable observationevidenceTable
      O.where_ (observationevidenceHash row O..== O.sqlStrictText hash)
      pure (observationevidenceHash row)
      :: IO [Text]
    when (null proofs) $ do
      _ <- O.runInsert connection O.Insert
        {O.iTable=observationevidenceTable,O.iRows=[ObservationEvidence (O.sqlStrictText hash) (O.sqlStrictText scanChain) (O.sqlStrictText chainEventId) (O.sqlStrictText evidence)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    existing <- O.runSelect connection $ do
      row <- O.selectTable chaineventsTable
      O.where_ (chaineventsChain row O..== O.sqlStrictText scanChain O..&& chaineventsEventId row O..== O.sqlStrictText chainEventId)
      pure (chaineventsEventId row)
      :: IO [Text]
    if null existing then do
      _ <- O.runInsert connection O.Insert
        {O.iTable=chaineventsTable,O.iRows=[ChainEvents (O.sqlStrictText scanChain) (O.sqlStrictText chainEventId) (O.sqlStrictText chainEventKind) (O.sqlStrictText chainEventAnchor) (O.sqlStrictText hash) (O.sqlInt8 scanTime) (O.sqlInt8 scanTime) (O.sqlInt8 reviewed)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    else do
      _ <- O.runUpdate connection O.Update
        { O.uTable=chaineventsTable,O.uUpdateWith= \row->row {chaineventsKind=O.sqlStrictText chainEventKind,chaineventsAnchor=O.sqlStrictText chainEventAnchor,chaineventsEvidenceHash=O.sqlStrictText hash,chaineventsLastSeen=O.sqlInt8 scanTime,
            chaineventsNeedsReview=O.ifThenElse (chaineventsNeedsReview row O..> O.sqlInt8 reviewed) (chaineventsNeedsReview row) (O.sqlInt8 reviewed)}
        , O.uWhere= \row->chaineventsChain row O..== O.sqlStrictText scanChain O..&& chaineventsEventId row O..== O.sqlStrictText chainEventId,O.uReturning=O.rCount }
      pure ()
    when review (pauseC connection ("chain_review:"<>scanChain<>":"<>chainEventKind))
  checkpointC connection scanChain scanNext
  healthC connection scanChain (Just scanTime) Nothing scanTime True

pauseC :: PG.Connection -> Text -> IO ()
pauseC connection reason = do
  _ <- O.runUpdate connection O.Update
    {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 1,deploymentPauseReason=O.sqlStrictText reason},O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount}
  pure ()

healthC :: PG.Connection -> Text -> Maybe Int64 -> Maybe Text -> Int64 -> Bool -> IO ()
healthC connection chain success failure now replaceSuccess = do
  previous <- O.runSelect connection $ do
    row <- O.selectTable scanhealthTable
    O.where_ (scanhealthChain row O..== O.sqlStrictText chain)
    pure row
    :: IO [ScanHealth]
  let nullableTime=maybe O.null (O.toNullable . O.sqlInt8) success
      nullableError=maybe O.null (O.toNullable . O.sqlStrictText) failure
  case previous of
    []->do
      _ <- O.runInsert connection O.Insert {O.iTable=scanhealthTable,O.iRows=[ScanHealth (O.sqlStrictText chain) nullableTime nullableError (O.sqlInt8 now)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    [_]->do
      _ <- O.runUpdate connection O.Update
        {O.uTable=scanhealthTable,O.uUpdateWith= \row->row {scanhealthLastSuccess=if replaceSuccess then nullableTime else scanhealthLastSuccess row,scanhealthLastError=nullableError,scanhealthCheckedAt=O.sqlInt8 now},O.uWhere= \row->scanhealthChain row O..== O.sqlStrictText chain,O.uReturning=O.rCount}
      pure ()
    _->reject "duplicate_scan_health"

recordScanFailure :: Ledger -> Text -> Int64 -> Text -> IO ()
recordScanFailure ledger chain now code = ledgerAction ledger $ \connection->do
  require (chain `elem` map fst scanAssets && T.length code<=160) "invalid_scan_failure"
  previous <- O.runSelect connection $ do
    row <- O.selectTable scanhealthTable
    O.where_ (scanhealthChain row O..== O.sqlStrictText chain)
    pure (scanhealthLastError row)
    :: IO [Maybe Text]
  when (previous/=[Just code]) $ do
    _ <- O.runInsert connection O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "scanner_failure") (O.sqlStrictText (chain<>":"<>code))],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()
  healthC connection chain Nothing (Just code) now False
  pauseC connection ("scanner_unavailable:"<>chain)


promoteDeposit :: Ledger -> Int64 -> Text -> IO Bool
promoteDeposit ledger now did = ledgerAction ledger $ \connection->do
  deposits <- O.runSelect connection $ do
    row <- O.selectTable depositsTable
    O.where_ (depositsId row O..== O.sqlStrictText did)
    pure row
    :: IO [Deposits]
  case deposits of
    [deposit] | depositsOrderId deposit==Nothing || depositsAllocated deposit==1 || depositsEligible deposit==0 ->pure False
    [deposit] | Just oid<-depositsOrderId deposit, depositsEligible deposit==1, depositsAllocated deposit==0 ->do
      orders <- O.runSelect connection $ do
        row <- O.selectTable ordersTable
        O.where_ (ordersId row O..== O.sqlStrictText oid)
        pure row
        :: IO [Orders]
      order <- case orders of [row]->pure row; _->reject "order_not_found"
      req <- decodeSaved (ordersRequestJson order)
      quote <- decodeSaved (ordersQuoteJson order)
      previous <- O.runSelect connection $ do
        row <- O.selectTable obligationsTable
        O.where_ (obligationsOrderId row O..== O.sqlStrictText oid O..&& obligationsKind row O..== O.sqlStrictText "conversion")
        pure (obligationsId row)
        :: IO [Text]
      let exact=depositsAmount deposit==units (gross quote) && depositsAsset deposit==T.pack (show (sourceAsset (direction req)))
      if not exact || not (null previous) || now>ordersGraceDeadline order || depositsFirstSeen deposit>ordersDeadline order then do
        _ <- O.runUpdate connection O.Update {O.uTable=ordersTable,O.uUpdateWith= \row->row {ordersStatus=O.sqlStrictText "NeedsReview"},O.uWhere= \row->ordersId row O..== O.sqlStrictText oid O..&& ordersStatus row O../= O.sqlStrictText "Paid",O.uReturning=O.rCount}
        pure False
      else do
        holds <- O.runSelect connection $ do
          row <- O.selectTable reservationsTable
          O.where_ (reservationsOrderId row O..== O.sqlStrictText oid)
          pure (reservationsPhase row)
          :: IO [Text]
        require (holds==["quote"]) "reservation_not_provisional"
        _ <- O.runInsert connection O.Insert {O.iTable=obligationsTable,O.iRows=[Obligations (O.sqlStrictText ("convert:"<>oid)) (O.sqlStrictText oid) (O.sqlStrictText did) (O.sqlStrictText "conversion") (O.sqlStrictText (T.pack (show (destinationAsset (direction req))))) (O.sqlInt8 (units (net quote))) (O.sqlStrictText (recipient req)) (O.sqlStrictText "ready")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        _ <- O.runUpdate connection O.Update {O.uTable=depositsTable,O.uUpdateWith= \row->row {depositsAllocated=O.sqlInt8 1},O.uWhere= \row->depositsId row O..== O.sqlStrictText did,O.uReturning=O.rCount}
        _ <- O.runUpdate connection O.Update {O.uTable=reservationsTable,O.uUpdateWith= \row->row {reservationsPhase=O.sqlStrictText "obligation"},O.uWhere= \row->reservationsOrderId row O..== O.sqlStrictText oid,O.uReturning=O.rCount}
        _ <- O.runUpdate connection O.Update {O.uTable=operatingreservationsTable,O.uUpdateWith= \row->row {operatingreservationsPhase=O.sqlStrictText "obligation"},O.uWhere= \row->operatingreservationsOrderId row O..== O.sqlStrictText oid O..&& operatingreservationsPhase row O..== O.sqlStrictText "quote",O.uReturning=O.rCount}
        _ <- O.runUpdate connection O.Update {O.uTable=ordersTable,O.uUpdateWith= \row->row {ordersStatus=O.sqlStrictText "Ready"},O.uWhere= \row->ordersId row O..== O.sqlStrictText oid,O.uReturning=O.rCount}
        pure True
    _->reject "deposit_not_found"

pendingVerification :: Ledger -> IO [Text]
pendingVerification ledger = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable chaineventsTable
    O.where_ (chaineventsChain row O..== O.sqlStrictText "Solana" O..&& chaineventsKind row O..== O.sqlStrictText "awaiting_verifier")
    pure (chaineventsFirstSeen row,chaineventsEventId row)
    :: IO [(Int64,Text)]
  pure (map snd (take 1000 (sortOn fst rows)))

lookupReferences :: Ledger -> [Text] -> IO (Maybe (Text,OrderRequest,PolicySnapshot,Text))
lookupReferences ledger keys = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable ordersTable
    O.where_ (O.matchNullable (O.sqlBool False) (\instruction->foldr (O..||) (O.sqlBool False) [instruction O..== O.sqlStrictText ("solana-pay:"<>key) | key<-keys]) (ordersInstruction row))
    pure(ordersId row,ordersRequestJson row,ordersPolicyJson row,ordersInstruction row)
    :: IO [(Text,Text,Text,Maybe Text)]
  case rows of
    [(oid,request,policy,Just instruction)] | Just reference<-T.stripPrefix "solana-pay:" instruction->do
      req <- decodeSaved request
      saved <- decodeSaved policy
      pure(Just(oid,req,saved,reference))
    _->pure Nothing

promotionCandidates :: Ledger -> IO [Text]
promotionCandidates ledger = do
  candidates <- ledgerAction ledger $ \connection->O.runSelect connection $ do
    deposit <- O.selectTable depositsTable
    order <- O.selectTable ordersTable
    O.where_ (O.matchNullable (O.sqlBool False) (\oid->oid O..== ordersId order) (depositsOrderId deposit) O..&&
      depositsEligible deposit O..== O.sqlInt8 1 O..&& depositsAllocated deposit O..== O.sqlInt8 0 O..&&
      (ordersStatus order O..== O.sqlStrictText "Provisioning" O..|| ordersStatus order O..== O.sqlStrictText "AwaitingDeposit"))
    pure (depositsFirstSeen deposit,depositsId deposit)
    :: IO [(Int64,Text)]
  pure (map snd (take 1000 (sortOn id candidates)))
