module Main (main) where

import Bridge.Types (Asset(..), require, BridgeError)
import qualified Bridge.Postgres.Ledger as L
import Control.Exception (bracket, try)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import qualified Database.PostgreSQL.Simple as PG
import System.Posix.User (getEffectiveUserName)

-- Dedicated fresh schema contract, never the funded bridge's database.
main :: IO ()
main = do
  user <- getEffectiveUserName
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,
        PG.connectDatabase="ecx_financial_schema",PG.connectUser=user}
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
  L.withLedger settings "journal-contract" $ \ledger->do
    bs <- L.ledgerAction ledger L.balances
    require (M.lookup ("Native","float") bs==Just 100) "reopen_balance_failed"
  putStrLn "PostgreSQL journal: balanced write, rejected unbalanced write, sequence, exclusive ownership and reopen passed"
