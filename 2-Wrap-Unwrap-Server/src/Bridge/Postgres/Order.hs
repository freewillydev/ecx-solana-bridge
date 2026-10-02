module Bridge.Postgres.Order
  ( recoveryPayments, recoverySources, accountedLosses, checkIntakeReadyC, exposeOrderC, readSavedOrder, findSavedOrder, bindInstruction, instructionBackup, createOrder, checkIntakeReady, exposeOrder, readOrderC, claimNativeAllocation, recordNativeInstruction, issueInstruction, expireQuotes ) where

import Bridge.Config
import qualified Bridge.Postgres.Ledger as Ledger
import Control.Monad (when, forM_)
import Data.List (nub, sortOn)
import Bridge.Ledger.Model (encodeRecord, decodeRecord)
import Bridge.Types
import qualified Bridge.Types as Types
import Bridge.Postgres.Schema
import Bridge.Postgres.Ledger (Ledger, ledgerAction, criticalSequence, reserveOrderCosts)
import Data.Aeson (FromJSON)
import Data.Profunctor.Product (p2)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

-- Storage records are internal; public views must additionally apply recovery
-- review state and instruction visibility/backup checks before serialization.
readSavedOrder :: PG.Connection -> Text -> Text -> IO Orders
readSavedOrder connection cap oid = do
  rows <- O.runSelect connection $ do
    row <- O.selectTable ordersTable
    O.where_ (ordersId row O..== O.sqlStrictText oid O..&& ordersCapabilityHash row O..== O.sqlStrictText cap)
    pure row
  case rows of [row]->pure row; _->reject "order_not_found"

findSavedOrder :: Ledger -> Config -> Text -> OrderRequest -> IO (Maybe Orders)
findSavedOrder ledger cfg capability request = do
  cap <- either reject pure (capabilityHash capability)
  require (validIdentifier (idempotencyKey request)) "invalid_idempotency_key"
  ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable ordersTable
      O.where_ (ordersCapabilityHash row O..== O.sqlStrictText cap O..&& ordersIdempotencyKey row O..== O.sqlStrictText (idempotencyKey request))
      pure row
    let hash=digest (TE.encodeUtf8 (fingerprint cfg<>encodeRecord request))
    case rows of
      [row]->require (ordersRequestHash row==hash) "idempotency_conflict" >> pure (Just row)
      []->pure Nothing
      _->reject "duplicate_idempotency"

bindInstruction :: Ledger -> Text -> Text -> IO ()
bindInstruction ledger oid instruction = ledgerAction ledger $ \connection->do
  require (not (T.null instruction) && T.length instruction<=160) "invalid_instruction"
  rows <- O.runSelect connection $ do
    row <- O.selectTable ordersTable
    O.where_ (ordersId row O..== O.sqlStrictText oid)
    pure (ordersInstruction row,ordersStatus row)
    :: IO [(Maybe Text,Text)]
  case rows of
    [(Nothing,"Provisioning")]->do
      sequenceNo <- criticalSequence connection
      count <- O.runUpdate connection O.Update
        { O.uTable=ordersTable
        , O.uUpdateWith= \row->row {ordersInstruction=O.toNullable (O.sqlStrictText instruction),
            ordersInstructionSequence=O.toNullable (O.sqlInt8 sequenceNo),ordersStatus=O.sqlStrictText "AwaitingDeposit"}
        , O.uWhere= \row->ordersId row O..== O.sqlStrictText oid
        , O.uReturning=O.rCount }
      require (count==1) "order_not_found"
    [(Just old,_)]->require (old==instruction) "instruction_is_immutable"
    [(Nothing,_)]->reject "order_no_longer_provisioning"
    _->reject "order_not_found"

instructionBackup :: Ledger -> Bool -> Text -> Text -> IO (Maybe Int64)
instructionBackup ledger remote capability oid = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction ledger $ \connection->do
    row <- readSavedOrder connection cap oid
    coverage <- O.runSelect connection $ fmap deploymentBackupSequence (O.selectTable deploymentTable) :: IO [Int64]
    case (ordersInstructionSequence row,coverage) of
      (Just sequenceNo,[covered])->pure (if remote && covered<sequenceNo then Just sequenceNo else Nothing)
      _->reject "instruction_not_recorded"

-- New PostgreSQL orders use 1% both ways; saved orders never recompute quotes.
createOrder :: Ledger -> Config -> Int64 -> Text -> OrderRequest -> IO Orders
createOrder ledger cfg now capability req = do
  cap <- either reject pure (capabilityHash capability)
  require (validIdentifier (idempotencyKey req)) "invalid_idempotency_key"
  fee <- either reject pure (feeFor (feeBps $ direction req) (input req))
  netAmount <- either reject pure (amount (toInteger (units (input req))-toInteger (units fee)))
  require (units netAmount>0) "nonpositive_net"
  oid <- randomId
  ledgerAction ledger $ \connection->do
    previous <- O.runSelect connection $ do
      row <- O.selectTable ordersTable
      O.where_ (ordersCapabilityHash row O..== O.sqlStrictText cap O..&& ordersIdempotencyKey row O..== O.sqlStrictText (idempotencyKey req))
      pure row
    let hash=digest (TE.encodeUtf8 (fingerprint cfg<>encodeRecord req))
    case previous of
      [row]->require (ordersRequestHash row==hash) "idempotency_conflict" >> pure row
      []->do
        checkIntakeReadyC connection now
        require (input req>=minInput cfg && input req<=maxInput cfg) "amount_outside_limits"
        require (sourceOwner req==Nothing && (direction req/=WrappedToNative || T.null(refund req))) "invalid_connection_free_order"
        require (not(T.null(recipient req)) && T.length(recipient req)<=128 && T.length(refund req)<=128 &&
          (direction req/=NativeToWrapped || not(T.null(refund req)))) "invalid_destination"
        pending <- O.runSelect connection $ do
          row <- O.selectTable ordersTable
          O.where_ (ordersStatus row O../= O.sqlStrictText "Paid" O..&& ordersStatus row O../= O.sqlStrictText "Refunded" O..&& ordersStatus row O../= O.sqlStrictText "ExpiredUnfunded")
          pure (ordersId row)
          :: IO [Text]
        obligations <- O.runSelect connection $ do
          row <- O.selectTable obligationsTable
          O.where_ (obligationsStatus row O../= O.sqlStrictText "paid" O..&& obligationsStatus row O../= O.sqlStrictText "cancelled")
          pure (obligationsOrderId row)
          :: IO [Text]
        require (length (nub (pending<>obligations))<maxQueued cfg) "queue_full"
        let asset=T.pack (show (destinationAsset (direction req)))
        inventory <- Ledger.freeInventory connection (destinationAsset (direction req))
        require (inventory>=toInteger (units netAmount)) "insufficient_inventory"
        require (now>=0 && toInteger now+toInteger (quoteSeconds cfg)+toInteger (confirmationGraceSeconds cfg)<=toInteger (maxBound::Int64)) "invalid_order_time"
        let end=now+quoteSeconds cfg
            row=Orders (O.sqlStrictText oid) (O.sqlStrictText cap) (O.sqlStrictText (idempotencyKey req)) (O.sqlStrictText hash)
              (O.sqlStrictText (encodeRecord req)) (O.sqlStrictText (encodeRecord (Quote (input req) fee netAmount)))
              (O.sqlStrictText (encodeRecord (PolicySnapshot (nativeConfirmations cfg) "finalized" (fingerprint cfg))))
              (O.sqlStrictText "Provisioning") (O.sqlInt8 end) (O.sqlInt8 (end+confirmationGraceSeconds cfg))
              O.null O.null O.null (O.sqlInt8 0)
        _ <- O.runInsert connection O.Insert {O.iTable=ordersTable,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        _ <- O.runInsert connection O.Insert
          {O.iTable=reservationsTable,O.iRows=[Reservations (O.sqlStrictText oid) (O.sqlStrictText asset) (O.sqlInt8 (units netAmount)) (O.sqlStrictText "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        reserveOrderCosts connection cfg oid (direction req)
        readSavedOrder connection cap oid
      _->reject "duplicate_idempotency"


checkIntakeReady :: Ledger -> Int64 -> IO ()
checkIntakeReady ledger now = ledgerAction ledger (\connection->checkIntakeReadyC connection now)

checkIntakeReadyC :: PG.Connection -> Int64 -> IO ()
checkIntakeReadyC connection now = do
  require (now>=0) "invalid_order_time"
  states <- O.runSelect connection $ fmap deploymentPaused (O.selectTable deploymentTable) :: IO [Int64]
  require (states==[0]) "intake_paused"
  scans <- O.runSelect connection $ do
    health <- O.selectTable scanhealthTable
    checkpoint <- O.selectTable checkpointsTable
    O.where_ (scanhealthChain health O..== checkpointsChain checkpoint)
    pure (scanhealthChain health,scanhealthLastSuccess health,scanhealthLastError health,checkpointsAnchor checkpoint)
    :: IO [(Text,Maybe Int64,Maybe Text,Text)]
  let ordered=sortOn (\(chain,_,_,_)->chain) scans
  require (map (\(chain,_,_,_)->chain) ordered==["Native","Solana","SolanaOperating"] &&
    all (\(_,success,err,anchor)->err==Nothing && not (T.null anchor) && maybe False (\time->time>=0 && time<=now && toInteger now-toInteger time<=60) success) ordered) "scanners_not_fresh"
  checks <- O.runSelect connection (O.selectTable custodycheckTable) :: IO [CustodyCheck]
  require (case checks of
    [row]->custodycheckCheckedRevision row==Just (custodycheckRevision row) && custodycheckLastError row==Nothing &&
      maybe False (\time->time>=0 && time<=now && toInteger now-toInteger time<=60) (custodycheckCheckedAt row)
    _->False) "custody_not_reconciled"

-- Views preserve the legacy latest-recovery and accounted-loss rules in SQL.
-- These private projections expose no update API.
recoveryPayments :: O.Select (O.Field O.SqlText,O.Field O.SqlText)
recoveryPayments = O.selectTable $ O.table "native_payment_recovery_state" $ p2
  (O.requiredTableField "txid",O.requiredTableField "state")
recoverySources :: O.Select (O.Field O.SqlText,O.Field O.SqlText)
recoverySources = O.selectTable $ O.table "source_recovery_state" $ p2
  (O.requiredTableField "deposit_id",O.requiredTableField "state")
accountedLosses :: O.Select (O.Field O.SqlText)
accountedLosses = O.selectTable $ O.table "accounted_source_losses" (O.requiredTableField "deposit_id")

readOrderC :: PG.Connection -> Text -> Text -> IO OrderView
readOrderC connection cap oid = do
  row <- readSavedOrder connection cap oid
  nativeReviews <- O.runSelect connection $ do
    (txid,state) <- recoveryPayments
    attempt <- O.selectTable attemptsTable
    intent <- O.selectTable intentsTable
    obligation <- O.selectTable obligationsTable
    O.where_ (txid O..== attemptsTxid attempt O..&& attemptsIntentId attempt O..== intentsId intent O..&&
      intentsObligationId intent O..== obligationsId obligation O..&& obligationsOrderId obligation O..== O.sqlStrictText oid O..&& state O../= O.sqlStrictText "reconfirmed")
    pure txid
    :: IO [Text]
  sourceReviews <- O.runSelect connection $ do
    (did,state) <- recoverySources
    deposit <- O.selectTable depositsTable
    O.where_ (did O..== depositsId deposit O..&& O.matchNullable (O.sqlBool False) (\value->value O..== O.sqlStrictText oid) (depositsOrderId deposit) O..&& state O../= O.sqlStrictText "restored")
    pure did
    :: IO [Text]
  accounted <- O.runSelect connection accountedLosses :: IO [Text]
  paid <- O.runSelect connection $ do
    obligation <- O.selectTable obligationsTable
    O.where_ (obligationsOrderId obligation O..== O.sqlStrictText oid O..&& obligationsStatus obligation O..== O.sqlStrictText "paid")
    pure (obligationsDepositId obligation)
    :: IO [Text]
  reviews <- O.runSelect connection $ do
    obligation <- O.selectTable obligationsTable
    O.where_ (obligationsOrderId obligation O..== O.sqlStrictText oid O..&& obligationsStatus obligation O..== O.sqlStrictText "review")
    pure (obligationsId obligation)
    :: IO [Text]
  let needsReview=not (null nativeReviews) || not (null reviews) || any (\did->not (did `elem` accounted && did `elem` paid)) sourceReviews
      state=if needsReview then "NeedsReview" else ordersStatus row
  OrderView oid <$> decodeSaved (ordersRequestJson row) <*> decodeSaved (ordersQuoteJson row) <*>
    pure state <*> pure (ordersDeadline row) <*> pure (ordersInstruction row) <*>
    pure (ordersPayoutTx row) <*> decodeSaved (ordersPolicyJson row)

decodeSaved :: FromJSON a => Text -> IO a
decodeSaved = decodeRecord "corrupt_ledger_json"

exposeOrder :: Ledger -> Bool -> Text -> Text -> IO OrderView
exposeOrder ledger remote capability oid = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction ledger $ \connection->do
    exposeOrderC connection remote cap oid

exposeOrderC :: PG.Connection -> Bool -> Text -> Text -> IO OrderView
exposeOrderC connection remote cap oid = do
  view <- readOrderC connection cap oid
  row <- readSavedOrder connection cap oid
  case (ordersInstructionSequence row,ordersInstructionIssued row) of
    (Just sequenceNo,1)->do
      coverage <- O.runSelect connection $ fmap deploymentBackupSequence (O.selectTable deploymentTable) :: IO [Int64]
      require (not remote || case coverage of [covered]->covered>=sequenceNo; _->False) "backup_pending"
      pure view
    (_,0)->pure view {depositInstruction=Nothing}
    _->reject "invalid_instruction_state"

claimNativeAllocation :: Ledger -> Config -> Int64 -> Text -> Text -> IO (Bool,Text)
claimNativeAllocation ledger cfg now capability oid = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction ledger $ \connection->do
    order <- readOrderC connection cap oid
    require (direction (request order)==NativeToWrapped && Types.deploymentFingerprint (policy order)==fingerprint cfg && depositInstruction order==Nothing) "invalid_native_provisioning_order"
    let label="ecx-bridge:v1:"<>deploymentId cfg<>":order:"<>oid
    saved <- O.runSelect connection $ do
      row <- O.selectTable nativeallocationsTable
      O.where_ (nativeallocationsOrderId row O..== O.sqlStrictText oid)
      pure (nativeallocationsLabel row)
      :: IO [Text]
    case saved of
      [old]->require (old==label) "allocation_label_mismatch" >> pure (False,label)
      []->do
        checkIntakeReadyC connection now
        require (status order=="Provisioning" && now<=deadline order) "deposit_window_closed"
        sequenceNo <- criticalSequence connection
        _ <- O.runInsert connection O.Insert
          {O.iTable=nativeallocationsTable,O.iRows=[NativeAllocations (O.sqlStrictText oid) (O.sqlStrictText label) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        pure (True,label)
      _->reject "duplicate_native_allocation"

recordNativeInstruction :: Ledger -> Text -> Text -> Text -> Text -> IO ()
recordNativeInstruction ledger capability oid label address = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction ledger $ \connection->do
    order <- readOrderC connection cap oid
    saved <- O.runSelect connection $ do
      row <- O.selectTable nativeallocationsTable
      O.where_ (nativeallocationsOrderId row O..== O.sqlStrictText oid)
      pure (nativeallocationsLabel row)
      :: IO [Text]
    require (saved==[label] && direction (request order)==NativeToWrapped && not (T.null address) && T.length address<=128) "invalid_native_allocation_result"
    case depositInstruction order of
      Just old->require (old==address) "instruction_is_immutable"
      Nothing->do
        require (status order `elem` ["Provisioning","ExpiredUnfunded"]) "order_no_longer_provisioning"
        sequenceNo <- criticalSequence connection
        _ <- O.runUpdate connection O.Update
          { O.uTable=ordersTable
          , O.uUpdateWith= \row->row {ordersInstruction=O.toNullable (O.sqlStrictText address),ordersInstructionSequence=O.toNullable (O.sqlInt8 sequenceNo),
              ordersStatus=O.ifThenElse (ordersStatus row O..== O.sqlStrictText "Provisioning") (O.sqlStrictText "AwaitingDeposit") (ordersStatus row)}
          , O.uWhere= \row->ordersId row O..== O.sqlStrictText oid,O.uReturning=O.rCount }
        pure ()

issueInstruction :: Ledger -> Config -> Int64 -> Text -> Text -> IO OrderView
issueInstruction ledger cfg now capability oid = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction ledger $ \connection->do
    order <- readOrderC connection cap oid
    require (Types.deploymentFingerprint (policy order)==fingerprint cfg) "order_profile_mismatch"
    saved <- readSavedOrder connection cap oid
    sequenceNo <- maybe (reject "instruction_not_recorded") pure (ordersInstructionSequence saved)
    coverage <- O.runSelect connection $ fmap deploymentBackupSequence (O.selectTable deploymentTable) :: IO [Int64]
    require (not (backupRequired cfg) || case coverage of [covered]->covered>=sequenceNo; _->False) "backup_pending"
    require (ordersInstructionIssued saved `elem` [0,1]) "invalid_instruction_state"
    when (ordersInstructionIssued saved==0) $ do
      checkIntakeReadyC connection now
      require (status order=="AwaitingDeposit" && now<=deadline order) "deposit_window_closed"
      held <- O.runSelect connection $ do
        row <- O.selectTable reservationsTable
        O.where_ (reservationsOrderId row O..== O.sqlStrictText oid)
        pure (reservationsPhase row)
        :: IO [Text]
      costs <- O.runSelect connection $ do
        row <- O.selectTable operatingreservationsTable
        O.where_ (operatingreservationsOrderId row O..== O.sqlStrictText oid)
        pure (operatingreservationsPhase row)
        :: IO [Text]
      require (held==["quote"] && costs==["quote","quote"]) "quote_reservations_unavailable"
      _ <- O.runUpdate connection O.Update
        {O.uTable=ordersTable,O.uUpdateWith= \row->row {ordersInstructionIssued=O.sqlInt8 1},O.uWhere= \row->ordersId row O..== O.sqlStrictText oid,O.uReturning=O.rCount}
      _ <- O.runInsert connection O.Insert
        {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "instruction_issued") (O.sqlStrictText oid)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    pure order

expireQuotes :: Ledger -> Int64 -> IO ()
expireQuotes ledger now = ledgerAction ledger $ \connection->do
  expired <- O.runSelect connection $ do
    row <- O.selectTable ordersTable
    O.where_ (ordersGraceDeadline row O..< O.sqlInt8 now)
    pure (ordersId row)
    :: IO [Text]
  forM_ expired $ \oid->do
    _ <- O.runUpdate connection O.Update
      { O.uTable=reservationsTable,O.uUpdateWith= \row->row {reservationsPhase=O.sqlStrictText "released"}
      , O.uWhere= \row->reservationsOrderId row O..== O.sqlStrictText oid O..&& reservationsPhase row O..== O.sqlStrictText "quote",O.uReturning=O.rCount }
    _ <- O.runUpdate connection O.Update
      { O.uTable=operatingreservationsTable,O.uUpdateWith= \row->row {operatingreservationsPhase=O.sqlStrictText "released"}
      , O.uWhere= \row->operatingreservationsOrderId row O..== O.sqlStrictText oid O..&& operatingreservationsPhase row O..== O.sqlStrictText "quote",O.uReturning=O.rCount }
    deposits <- O.runSelect connection $ do
      row <- O.selectTable depositsTable
      O.where_ (O.matchNullable (O.sqlBool False) (\value->value O..== O.sqlStrictText oid) (depositsOrderId row))
      pure (depositsId row)
      :: IO [Text]
    when (null deposits) $ do
      _ <- O.runUpdate connection O.Update
        { O.uTable=ordersTable,O.uUpdateWith= \row->row {ordersStatus=O.sqlStrictText "ExpiredUnfunded"}
        , O.uWhere= \row->ordersId row O..== O.sqlStrictText oid O..&&
            (ordersStatus row O..== O.sqlStrictText "Provisioning" O..|| ordersStatus row O..== O.sqlStrictText "AwaitingDeposit")
        , O.uReturning=O.rCount }
      pure ()
