{-# LANGUAGE GADTs #-}
module Main (main) where

import Bridge.Types (Asset(..), require, BridgeError)
import qualified Bridge.Postgres.Ledger as L
import Bridge.Postgres.Schema
import qualified Opaleye as O
import Control.Exception (bracket, try)
import Control.Concurrent.Async (withAsync,wait)
import System.Timeout (timeout)
import qualified Opaleye.Internal.Locking as Locking
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import qualified Database.PostgreSQL.Simple as PG
import System.Posix.User (getEffectiveUserName)
import qualified Data.Text as T
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)

-- Dedicated fresh schema contract, never the funded bridge's database.
main :: IO ()
main = do
  user <- getEffectiveUserName
  database <- fromMaybe "ecx_financial_schema" <$> lookupEnv "ECX_JOURNAL_CONTRACT_DATABASE"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,
        PG.connectDatabase=database,PG.connectUser=user}
  bracket (PG.connect settings) PG.close $ \connection->
    PG.withTransaction connection (fixture connection InitializeFixture)
  -- A second connection must wait for the Opaleye FOR UPDATE owner, then
  -- proceed after commit. This exercises the database lock, not a Haskell mutex.
  bracket (PG.connect settings) PG.close $ \first->
    bracket (PG.connect settings) PG.close $ \second->do
      PG.begin first
      fixture first LockDeployment
      withAsync (fixture second LockDeployment) $ \pending->do
        blocked <- timeout 200000 (wait pending)
        require (blocked==Nothing) "deployment_row_lock_missing"
        PG.commit first
        released <- timeout 2000000 (wait pending)
        require (released==Just ()) "deployment_row_lock_not_released"
  L.withLedger settings "journal-contract" $ \ledger->do
    L.ledgerAction ledger $ \connection->do
      L.posting connection "contract" "isolated accounting contract" [(Native,"float",100),(Native,"external",-100)]
      n <- L.criticalSequence connection
      require (n==1) "critical_sequence_failed"
    invalid <- try (L.ledgerAction ledger $ \connection->L.posting connection "invalid" "unbalanced" [(Native,"float",1)]) :: IO (Either BridgeError ())
    require (case invalid of Left _->True; _->False) "unbalanced_posting_accepted"
    bs <- L.ledgerAction ledger L.balances
    require (M.lookup ("Native","float") bs==Just 100 && M.lookup ("Native","external") bs==Just (-100)) "journal_balance_failed"
    competing <- try (L.withLedger settings "journal-contract" (const $ pure ())) :: IO (Either BridgeError ())
    require (case competing of Left _->True; _->False) "worker_lock_failed"
    let receipt=T.replicate 64 "a"
        refused action=do
          result <- try action :: IO(Either BridgeError ())
          require (case result of Left _->True; _->False) "invalid_backup_accepted"
        coverage=L.ledgerAction ledger (\connection->fixture connection ReadCoverage)
    refused $ L.acknowledgeBackup ledger "wrong-deployment" 1 receipt
    refused $ L.acknowledgeBackup ledger "journal-contract" 2 receipt
    refused $ L.acknowledgeBackup ledger "journal-contract" 1 "not-a-remote-receipt"
    coverage >>= \rows->require (rows==[(1,0,0)]) "rejected_backup_mutated_state"
    -- A concurrent financial commit after the snapshot must remain uncovered.
    L.ledgerAction ledger L.criticalSequence >>= \n->require (n==2) "backup_contract_sequence_failed"
    L.acknowledgeBackup ledger "journal-contract" 1 receipt
    L.acknowledgeBackup ledger "journal-contract" 1 receipt
    coverage >>= \rows->require (rows==[(2,1,1)]) "backup_covered_newer_work_or_replay_mutated_state"
    refused $ L.acknowledgeBackup ledger "journal-contract" 0 receipt
    coverage >>= \rows->require (rows==[(2,1,1)]) "backup_coverage_regressed"
  L.withLedger settings "journal-contract" $ \ledger->do
    bs <- L.ledgerAction ledger L.balances
    require (M.lookup ("Native","float") bs==Just 100) "reopen_balance_failed"
    coverage <- L.ledgerAction ledger (\connection->fixture connection ReadCoverage)
    require (coverage==[(2,1,1)]) "backup_acknowledgment_not_durable"
  putStrLn "PostgreSQL journal and backup acknowledgment: balanced writes, row locking, ownership, exact coverage, identity/receipt/stale refusal, idempotence and durable reopen passed"


-- Closed test operations: no arbitrary SQL/query callback in fixture access.
data Fixture a where
  InitializeFixture :: Fixture ()
  LockDeployment :: Fixture ()
  ReadCoverage :: Fixture [(Int64,Int64,Int64)]

fixture :: PG.Connection -> Fixture a -> IO a
fixture connection = \case
  LockDeployment -> do
    rows <- O.runSelect connection $ Locking.forUpdate $ do
      row <- O.selectTable deploymentTable
      O.where_ (deploymentSingleton row O..== O.sqlInt8 1)
      pure (deploymentSingleton row)
    require (rows==[1::Int64]) "fixture_deployment_missing"
  InitializeFixture -> do
    existing <- O.runSelect connection (O.selectTable deploymentTable) :: IO [Deployment]
    require (null existing) "fresh_contract_database_required"
    _ <- O.runInsert connection O.Insert
      { O.iTable=deploymentTable
      , O.iRows=[Deployment (O.sqlInt8 1) (O.sqlInt8 18) (O.sqlStrictText "journal-contract")
          (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "contract")]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    _ <- O.runInsert connection O.Insert
      { O.iTable=custodycheckTable
      , O.iRows=[CustodyCheck (O.sqlInt8 1) (O.sqlInt8 0) O.null O.null O.null O.null]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    pure ()
  ReadCoverage -> do
    rows <- O.runSelect connection $ do
      row <- O.selectTable deploymentTable
      pure (deploymentCriticalSequence row,deploymentBackupSequence row)
      :: IO [(Int64,Int64)]
    receipts <- O.runSelect connection $ do
      row <- O.selectTable auditTable
      O.where_ (auditAction row O..== O.sqlStrictText "backup")
      pure (auditId row)
      :: IO [Int64]
    pure [(current,covered,fromIntegral(length receipts)) | (current,covered)<-rows]
