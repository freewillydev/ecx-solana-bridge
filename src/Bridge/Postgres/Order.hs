module Bridge.Postgres.Order
  ( readSavedOrder, findSavedOrder, bindInstruction, instructionBackup, createOrder, checkIntakeReady, exposeOrder, readOrderC ) where

import Bridge.Config
import qualified Bridge.Postgres.Budget as Budget
import qualified Bridge.Postgres.Ledger as Ledger
import Control.Monad (when)
import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
import Bridge.Types
import Bridge.Postgres.Schema
import Bridge.Postgres.Ledger (Ledger, ledgerAction, criticalSequence)
import Data.Aeson (encode, ToJSON, FromJSON, eitherDecodeStrict')
import Data.Profunctor.Product (p2)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as LBS
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
    let hash=digest (TE.encodeUtf8 (fingerprint cfg<>TE.decodeUtf8 (LBS.toStrict (encode request))))
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
  fee <- either reject pure (feeFor 100 (input req))
  netAmount <- either reject pure (amount (toInteger (units (input req))-toInteger (units fee)))
  require (units netAmount>0) "nonpositive_net"
  oid <- randomId
  ledgerAction ledger $ \connection->do
    previous <- O.runSelect connection $ do
      row <- O.selectTable ordersTable
      O.where_ (ordersCapabilityHash row O..== O.sqlStrictText cap O..&& ordersIdempotencyKey row O..== O.sqlStrictText (idempotencyKey req))
      pure row
    let hash=digest (TE.encodeUtf8 (fingerprint cfg<>jsonText req))
    case previous of
      [row]->require (ordersRequestHash row==hash) "idempotency_conflict" >> pure row
      []->do
        checkIntakeReadyC connection now
        require (input req>=minInput cfg && input req<=maxInput cfg) "amount_outside_limits"
        -- The new connection-free contract will replace this legacy owner binding
        -- together with observer validation, not relax it in isolation.
        when (direction req==WrappedToNative) $ require (sourceOwner req==Just (refund req)) "refund_owner_mismatch"
        require (not (T.null (recipient req)) && not (T.null (refund req)) && T.length (recipient req)<=128 && T.length (refund req)<=128) "invalid_destination"
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
        bs <- Ledger.balances connection
        let asset=T.pack (show (destinationAsset (direction req)))
        holds <- O.runSelect connection $ do
          row <- O.selectTable reservationsTable
          O.where_ (reservationsAsset row O..== O.sqlStrictText asset O..&& reservationsPhase row O../= O.sqlStrictText "released")
          pure (reservationsAmount row)
          :: IO [Int64]
        require (M.findWithDefault 0 (asset,"float") bs-sum (map toInteger holds)>=toInteger (units netAmount)) "insufficient_inventory"
        require (now>=0 && toInteger now+toInteger (quoteSeconds cfg)+toInteger (confirmationGraceSeconds cfg)<=toInteger (maxBound::Int64)) "invalid_order_time"
        let end=now+quoteSeconds cfg
            row=Orders (O.sqlStrictText oid) (O.sqlStrictText cap) (O.sqlStrictText (idempotencyKey req)) (O.sqlStrictText hash)
              (O.sqlStrictText (jsonText req)) (O.sqlStrictText (jsonText (Quote (input req) fee netAmount)))
              (O.sqlStrictText (jsonText (PolicySnapshot (nativeConfirmations cfg) "finalized" (fingerprint cfg))))
              (O.sqlStrictText "Provisioning") (O.sqlInt8 end) (O.sqlInt8 (end+confirmationGraceSeconds cfg))
              O.null O.null O.null (O.sqlInt8 0)
        _ <- O.runInsert connection O.Insert {O.iTable=ordersTable,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        _ <- O.runInsert connection O.Insert
          {O.iTable=reservationsTable,O.iRows=[Reservations (O.sqlStrictText oid) (O.sqlStrictText asset) (O.sqlInt8 (units netAmount)) (O.sqlStrictText "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        Budget.reserveOrderCosts connection cfg oid (direction req)
        readSavedOrder connection cap oid
      _->reject "duplicate_idempotency"

jsonText :: ToJSON a => a -> Text
jsonText = TE.decodeUtf8 . LBS.toStrict . encode

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
decodeSaved = either (const $ reject "corrupt_ledger_json") pure . eitherDecodeStrict' . TE.encodeUtf8

exposeOrder :: Ledger -> Bool -> Text -> Text -> IO OrderView
exposeOrder ledger remote capability oid = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction ledger $ \connection->do
    view <- readOrderC connection cap oid
    row <- readSavedOrder connection cap oid
    case (ordersInstructionSequence row,ordersInstructionIssued row) of
      (Just sequenceNo,1)->do
        coverage <- O.runSelect connection $ fmap deploymentBackupSequence (O.selectTable deploymentTable) :: IO [Int64]
        require (not remote || case coverage of [covered]->covered>=sequenceNo; _->False) "backup_pending"
        pure view
      (_,0)->pure view {depositInstruction=Nothing}
      _->reject "invalid_instruction_state"
