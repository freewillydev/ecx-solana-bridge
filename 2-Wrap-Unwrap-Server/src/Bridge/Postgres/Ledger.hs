{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Postgres.Ledger
  ( Ledger, withLedger, withGuardedLedger, ledgerAction, readiness, pause, criticalSequence, acknowledgeBackup, balances, posting
  , reserveOrderCosts, earnedFees, freeInventory, freeOperating, checkOperatingCapacity, transferOrderCosts ) where

import Bridge.Postgres.Schema
import Bridge.Postgres.Catalog (claimWorkerSession)
import Bridge.Config (Config(..))
import Bridge.Types (Availability(..), Asset, Direction(..), amount, units, require, reject)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless, when, forM_)
import Data.Int (Int64)
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import qualified Opaleye.Internal.Locking as Locking

-- Internal financial capability. Do not pass it to safe HTTP interpreters.
data Ledger = Ledger (MVar (Maybe PG.Connection)) (Maybe (Int64 -> IO ()))

withLedger :: PG.ConnectInfo -> Text -> (Ledger -> IO a) -> IO a
withLedger settings identity = withGuardedLedger settings identity Nothing

withGuardedLedger :: PG.ConnectInfo -> Text -> Maybe (Int64 -> IO ()) -> (Ledger -> IO a) -> IO a
withGuardedLedger settings identity guard action = bracket (PG.connect settings) PG.close $ \connection -> do
  -- Session ownership survives individual commits and is released on close.
  claimWorkerSession connection
  metadata <- O.runSelect connection (O.selectTable deploymentTable)
    :: IO [Deployment]
  require (case metadata of [row]->deploymentSingleton row==1 && deploymentSchemaVersion row==18 && deploymentFingerprint row==identity; _->False) "ledger_profile_or_schema_mismatch"
  case (guard,metadata) of
    (Just checkpoint,[row])->checkpoint(deploymentCriticalSequence row)
    _->pure ()
  ledger <- flip Ledger guard <$> newMVar (Just connection)
  pause ledger "restart_requires_reconciliation"
  action ledger

ledgerAction :: Ledger -> (PG.Connection -> IO a) -> IO a
ledgerAction (Ledger cell guard) action = do
  result <- modifyMVar cell $ \case
    Nothing -> pure (Nothing,Left (toException (userError "ledger_connection_fenced")))
    Just connection -> mask $ \restore -> do
      outcome <- try $ do
        PG.begin connection
        -- Serialize mutations even if a maintenance session also accesses state.
        locked <- O.runSelect connection $ Locking.forUpdate $ do
          row <- O.selectTable deploymentTable
          O.where_ (deploymentSingleton row O..== O.sqlInt8 1)
          pure (deploymentSingleton row)
        require (locked==[1::Int64]) "corrupt_deployment"
        value <- restore (action connection)
        case guard of
          Nothing->pure ()
          Just checkpoint->do
            sequences <- O.runSelect connection $ fmap deploymentCriticalSequence (O.selectTable deploymentTable) :: IO [Int64]
            case sequences of [sequenceNo]->checkpoint sequenceNo; _->reject "corrupt_sequence"
        PG.commit connection
        pure value
      case outcome of
        Right value -> pure (Just connection,Right value)
        Left (err :: SomeException) -> do
          cleanup <- try (PG.rollback connection) :: IO (Either SomeException ())
          let sqlFailure = case fromException err of Just (_ :: PG.SqlError)->True; Nothing->False
              ioFailure = case fromException err of Just (_ :: IOException)->True; Nothing->False
              reusable = not sqlFailure && not ioFailure && case cleanup of Right _->True; Left _->False
          pure (if reusable then Just connection else Nothing,Left err)
  either throwIO pure result

readiness :: Ledger -> IO Availability
readiness ledger = ledgerAction ledger $ \connection -> do
  rows <- O.runSelect connection $ fmap (\row->(deploymentPaused row,deploymentPauseReason row)) (O.selectTable deploymentTable)
    :: IO [(Int64,Text)]
  case rows of [(paused,reason)]->pure (Availability (paused==0) reason); _->reject "corrupt_deployment"

pause :: Ledger -> Text -> IO ()
pause ledger reason = ledgerAction ledger $ \connection -> do
  changed <- O.runUpdate connection O.Update
    { O.uTable=deploymentTable, O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 1,deploymentPauseReason=O.sqlStrictText reason}
    , O.uWhere= \row->deploymentSingleton row O..== O.sqlInt8 1, O.uReturning=O.rCount }
  require (changed==1) "corrupt_deployment"
  _ <- O.runInsert connection O.Insert
    { O.iTable=auditTable, O.iRows=[Audit Nothing (O.sqlStrictText "pause") (O.sqlStrictText reason)]
    , O.iReturning=O.rCount, O.iOnConflict=Nothing }
  pure ()

criticalSequence :: PG.Connection -> IO Int64
criticalSequence connection = do
  sequenceNos <- O.runUpdate connection O.Update
    { O.uTable=deploymentTable, O.uUpdateWith= \row->row {deploymentCriticalSequence=deploymentCriticalSequence row+1}
    , O.uWhere= \row->deploymentSingleton row O..== O.sqlInt8 1
    , O.uReturning=O.rReturning deploymentCriticalSequence }
  case sequenceNos of [sequenceNo]->pure sequenceNo; _->reject "corrupt_sequence"

-- Internal worker capability, never an HTTP operation. The uploader must first
-- obtain a durable remote receipt for the exact snapshot and its manifest.
-- A receipt covers only that snapshot's sequence, never the current sequence
-- observed after upload: financial writes can continue during the backup.
acknowledgeBackup :: Ledger -> Text -> Int64 -> Text -> IO ()
acknowledgeBackup ledger identity sequenceNo snapshot = ledgerAction ledger $ \connection->do
  require (T.length snapshot==64 && T.all (`elem` ("0123456789abcdef"::String)) snapshot) "invalid_backup_receipt"
  metadata <- O.runSelect connection (O.selectTable deploymentTable) :: IO [Deployment]
  case metadata of
    [row]->do
      require (deploymentFingerprint row==identity) "snapshot_profile_mismatch"
      require (sequenceNo>=deploymentBackupSequence row && sequenceNo<=deploymentCriticalSequence row) "invalid_backup_coverage"
      if sequenceNo==deploymentBackupSequence row then pure () else do
        count <- O.runUpdate connection O.Update
          { O.uTable=deploymentTable
          , O.uUpdateWith= \d->d {deploymentBackupSequence=O.sqlInt8 sequenceNo}
          , O.uWhere= \d->deploymentSingleton d O..== O.sqlInt8 1
          , O.uReturning=O.rCount }
        require (count==1) "corrupt_sequence"
        inserted <- O.runInsert connection O.Insert
          { O.iTable=auditTable
          , O.iRows=[Audit Nothing (O.sqlStrictText "backup") (O.sqlStrictText $ T.pack(show sequenceNo)<>":"<>snapshot)]
          , O.iReturning=O.rCount, O.iOnConflict=Nothing }
        require (inserted==1) "backup_receipt_insert_failed"
    _->reject "corrupt_sequence"

balances :: PG.Connection -> IO (M.Map (Text,Text) Integer)
balances connection = do
  rows <- O.runSelect connection $ fmap (\row->(postingsAsset row,postingsAccount row,postingsDelta row)) (O.selectTable postingsTable)
    :: IO [(Text,Text,Int64)]
  pure $ M.fromListWith (+) [((asset,account),toInteger delta) | (asset,account,delta)<-rows]

posting :: PG.Connection -> Text -> Text -> [(Asset,Text,Integer)] -> IO ()
posting connection event note rows = do
  let totals = M.fromListWith (+) [(asset,delta) | (asset,_,delta)<-rows]
  require (all (==0) (M.elems totals)) "unbalanced_journal"
  require (all (\(_,_,delta)->abs delta<=toInteger (maxBound::Int64)) rows) "posting_overflow"
  count <- O.runInsert connection O.Insert
    { O.iTable=eventsTable, O.iRows=[Events (O.sqlStrictText event) (O.sqlStrictText note)], O.iReturning=O.rCount, O.iOnConflict=Nothing }
  require (count==1) "event_insert_failed"
  let entries=[Postings Nothing (O.sqlStrictText event) (O.sqlStrictText (T.pack (show asset))) (O.sqlStrictText account) (O.sqlInt8 (fromInteger delta))
              | (asset,account,delta)<-rows,delta/=0]
  unless (null entries) $ do
    inserted <- O.runInsert connection O.Insert
      { O.iTable=postingsTable,O.iRows=entries,O.iReturning=O.rCount,O.iOnConflict=Nothing }
    when (inserted/=fromIntegral (length entries)) (reject "posting_insert_failed")

-- Operating allowances share the journal transaction and lock.
freeInventory :: PG.Connection -> Asset -> IO Integer
freeInventory connection asset = do
  let name=T.pack(show asset)
  available <- accountBalance connection name "float"
  held <- O.runSelect connection $ fmap reservationsAmount $ selectWhere
    (\row->reservationsAsset row O..== O.sqlStrictText name O..&& reservationsPhase row O../= O.sqlStrictText "released")
    (O.selectTable reservationsTable) :: IO [Int64]
  pure (available-sum(map toInteger held))

earnedFees :: PG.Connection -> Asset -> IO Integer
earnedFees connection asset = accountBalance connection (T.pack(show asset)) "earned"

operatingHolds :: PG.Connection -> Text -> IO Integer
operatingHolds connection asset = do
  fees <- O.runSelect connection $ fmap feereservationsAmount $ selectWhere
    (\row->feereservationsAsset row O..== O.sqlStrictText asset O..&& feereservationsReleased row O..== O.sqlInt8 0)
    (O.selectTable feereservationsTable) :: IO [Int64]
  orders <- O.runSelect connection $ fmap operatingreservationsAmount $ selectWhere
    (\row->operatingreservationsAsset row O..== O.sqlStrictText asset O..&&
      (operatingreservationsPhase row O..== O.sqlStrictText "quote" O..|| operatingreservationsPhase row O..== O.sqlStrictText "obligation"))
    (O.selectTable operatingreservationsTable) :: IO [Int64]
  pure (sum (map toInteger (fees<>orders)))

-- Filter before reading the journal; summation remains unbounded Integer.
accountBalance :: PG.Connection -> Text -> Text -> IO Integer
accountBalance connection asset account = do
  rows <- O.runSelect connection $ fmap postingsDelta $ selectWhere
    (\row->postingsAsset row O..== O.sqlStrictText asset O..&& postingsAccount row O..== O.sqlStrictText account)
    (O.selectTable postingsTable) :: IO [Int64]
  pure (sum $ map toInteger rows)

freeOperating :: PG.Connection -> Text -> IO Integer
freeOperating connection asset = do
  available <- accountBalance connection asset "operating"
  held <- operatingHolds connection asset
  pure (available-held)

operatingTime :: PG.Connection -> IO Int64
operatingTime connection = do
  now <- floor <$> getPOSIXTime
  times <- O.runUpdate connection O.Update
    { O.uTable=operatingclockTable
    , O.uUpdateWith= \row->row {operatingclockLastTime=O.ifThenElse (operatingclockLastTime row O..> O.sqlInt8 now) (operatingclockLastTime row) (O.sqlInt8 now)}
    , O.uWhere= \row->operatingclockSingleton row O..== O.sqlInt8 1
    , O.uReturning=O.rReturning operatingclockLastTime }
  case times of [time]->pure time; _->reject "operating_clock_missing"

operatingSpent :: PG.Connection -> Text -> Int64 -> IO Integer
operatingSpent connection asset now = do
  rows <- O.runSelect connection $ fmap (postingsDelta . fst) $ selectWhere
    (\(entry,cost)->postingsId entry O..== operatingcostsPostingId cost O..&&
      postingsAsset entry O..== O.sqlStrictText asset O..&& operatingcostsRecordedAt cost O..> O.sqlInt8 (now-86400)) $ do
        entry <- O.selectTable postingsTable
        cost <- O.selectTable operatingcostsTable
        pure (entry,cost)
    :: IO [Int64]
  pure (negate (sum (map toInteger rows)))

checkOperatingCapacity :: PG.Connection -> Config -> [(Text,Int64)] -> IO ()
checkOperatingCapacity connection cfg costs = do
  now <- operatingTime connection
  forM_ costs $ \(asset,n)->do
    require (asset `elem` ["Native","Sol"] && n>=0) "invalid_operating_reservation"
    available <- accountBalance connection asset "operating"
    held <- operatingHolds connection asset
    require (available-held>=toInteger n) "insufficient_fee_budget"
    spent <- operatingSpent connection asset now
    let limit=if asset=="Native" then maxNativeDailyCost cfg else maxSolDailyCost cfg
    require (spent+held+toInteger n<=toInteger (units limit)) "operating_daily_limit"

reserveOrderCosts :: PG.Connection -> Config -> Text -> Direction -> IO ()
reserveOrderCosts connection cfg oid direction = do
  total <- either reject pure $ amount (toInteger (units (maxSolFee cfg))+toInteger (units (maxSolAccountRent cfg)))
  let costs=[("Native",units (maxNativeFee cfg)),("Sol",units total)]
  checkOperatingCapacity connection cfg costs
  _ <- O.runInsert connection O.Insert
    { O.iTable=ordercostlimitsTable
    , O.iRows=[OrderCostLimits (O.sqlStrictText oid) (O.sqlInt8 (units (maxNativeFee cfg))) (O.sqlInt8 (units (maxSolFee cfg))) (O.sqlInt8 (units (maxSolAccountRent cfg)))]
    , O.iReturning=O.rCount,O.iOnConflict=Nothing }
  forM_ costs $ \(asset,n)->do
    let conversion=(direction==NativeToWrapped && asset=="Sol") || (direction==WrappedToNative && asset=="Native")
        kind=if conversion then "conversion" else "refund"
    _ <- O.runInsert connection O.Insert
      { O.iTable=operatingreservationsTable
      , O.iRows=[OperatingReservations (O.sqlStrictText oid) (O.sqlStrictText kind) (O.sqlStrictText asset) (O.sqlInt8 n) (O.sqlStrictText "quote")]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    pure ()

transferOrderCosts :: PG.Connection -> Config -> Text -> Text -> Text -> Int64 -> IO ()
transferOrderCosts connection cfg oid kind asset feeLimit = do
  limits <- O.runSelect connection $ selectWhere (\row->ordercostlimitsOrderId row O..== O.sqlStrictText oid) (O.selectTable ordercostlimitsTable) :: IO [OrderCostLimits]
  limit <- case limits of
    [row]->pure $ if asset=="Native" then toInteger (ordercostlimitsNativeFee row) else toInteger (ordercostlimitsSolanaFee row)+toInteger (ordercostlimitsSolanaRent row)
    _->reject "order_cost_policy_missing"
  require (feeLimit>0 && toInteger feeLimit<=limit) "order_fee_limit_exceeded"
  _ <- O.runUpdate connection O.Update
    { O.uTable=operatingreservationsTable
    , O.uUpdateWith= \row->row {operatingreservationsPhase=O.sqlStrictText "transferred"}
    , O.uWhere= \row->operatingreservationsOrderId row O..== O.sqlStrictText oid O..&&
        operatingreservationsKind row O..== O.sqlStrictText kind O..&& operatingreservationsAsset row O..== O.sqlStrictText asset O..&&
        (operatingreservationsPhase row O..== O.sqlStrictText "quote" O..|| operatingreservationsPhase row O..== O.sqlStrictText "obligation")
    , O.uReturning=O.rCount }
  checkOperatingCapacity connection cfg [(asset,feeLimit)]

selectWhere :: (a -> O.Field O.SqlBool) -> O.Select a -> O.Select a
selectWhere predicate query = do
  row <- query
  O.where_ (predicate row)
  pure row
