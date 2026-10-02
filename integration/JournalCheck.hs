module Main (main) where

import Bridge.Types (Asset(..), require, BridgeError)
import qualified Bridge.Postgres.Ledger as L
import Control.Exception (bracket, try)
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
  bracket (PG.connect settings) PG.close $ \connection->do
    existing <- PG.query_ connection "SELECT count(*) FROM deployment" :: IO [PG.Only Int64]
    require (existing==[PG.Only 0]) "fresh_contract_database_required"
    PG.withTransaction connection $ do
      _ <- PG.execute_ connection "INSERT INTO deployment(singleton,schema_version,fingerprint) VALUES(1,18,'journal-contract')"
      _ <- PG.execute_ connection "INSERT INTO custody_check(singleton,revision) VALUES(1,0)"
      pure ()
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
        coverage=L.ledgerAction ledger $ \connection->PG.query_ connection
          "SELECT critical_sequence,backup_sequence,(SELECT count(*) FROM audit WHERE action='backup') FROM deployment"
          :: IO [(Int64,Int64,Int64)]
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
    coverage <- L.ledgerAction ledger $ \connection->PG.query_ connection "SELECT critical_sequence,backup_sequence FROM deployment" :: IO [(Int64,Int64)]
    require (coverage==[(2,1)]) "backup_acknowledgment_not_durable"
  putStrLn "PostgreSQL journal and backup acknowledgment: balanced writes, ownership, exact coverage, identity/receipt/stale refusal, idempotence and durable reopen passed"
