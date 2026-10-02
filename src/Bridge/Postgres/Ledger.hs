{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Postgres.Ledger
  ( Ledger, withLedger, ledgerAction, readiness, pause, criticalSequence, acknowledgeBackup, balances, posting ) where

import Bridge.Postgres.Schema
import Bridge.Types (Availability(..), Asset, require, reject)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless, when)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

-- Internal financial capability. Do not pass it to safe HTTP interpreters.
newtype Ledger = Ledger (MVar (Maybe PG.Connection))

withLedger :: PG.ConnectInfo -> Text -> (Ledger -> IO a) -> IO a
withLedger settings identity action = bracket (PG.connect settings) PG.close $ \connection -> do
  -- Session ownership survives individual commits and is released on close.
  locked <- PG.query_ connection "SELECT pg_try_advisory_lock(1162041393,18)" :: IO [PG.Only Bool]
  require (locked == [PG.Only True]) "worker_already_running"
  metadata <- O.runSelect connection (O.selectTable deploymentTable)
    :: IO [Deployment]
  require (case metadata of [row]->deploymentSingleton row==1 && deploymentSchemaVersion row==18 && deploymentFingerprint row==identity; _->False) "ledger_profile_or_schema_mismatch"
  ledger <- Ledger <$> newMVar (Just connection)
  pause ledger "restart_requires_reconciliation"
  action ledger

ledgerAction :: Ledger -> (PG.Connection -> IO a) -> IO a
ledgerAction (Ledger cell) action = do
  result <- modifyMVar cell $ \case
    Nothing -> pure (Nothing,Left (toException (userError "ledger_connection_fenced")))
    Just connection -> mask $ \restore -> do
      outcome <- try $ do
        _ <- PG.execute_ connection "BEGIN"
        -- Serialize mutations even if a maintenance session also accesses state.
        _ <- PG.query_ connection "SELECT singleton FROM deployment WHERE singleton=1 FOR UPDATE" :: IO [PG.Only Int64]
        value <- restore (action connection)
        _ <- PG.execute_ connection "COMMIT"
        pure value
      case outcome of
        Right value -> pure (Just connection,Right value)
        Left (err :: SomeException) -> do
          cleanup <- try (PG.execute_ connection "ROLLBACK") :: IO (Either SomeException Int64)
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
