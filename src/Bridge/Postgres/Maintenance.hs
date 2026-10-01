-- Explicit offline installation authority; never reachable from Servant/DSL.
module Bridge.Postgres.Maintenance (initialize) where
import Bridge.Config (Config,fingerprint)
import Bridge.Types (require,reject)
import Bridge.Observer (epochSeconds)
import Bridge.Postgres.Schema
import Control.Exception (bracket)
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

-- DDL is supplied by the reviewed installer. Repeat initialization verifies the
-- identity without changing an existing ledger, pause state or critical sequence.
initialize :: PG.ConnectInfo -> Config -> IO ()
initialize settings cfg = bracket (PG.connect settings) PG.close $ \c->PG.withTransaction c $ do
  existing <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
  case existing of
    []->do
      locked <- PG.query_ c "SELECT pg_try_advisory_xact_lock(1162041393,18)" :: IO [PG.Only Bool]
      require (locked==[PG.Only True]) "worker_already_running"
      now <- epochSeconds
      _ <- O.runInsert c O.Insert {O.iTable=deploymentTable,O.iRows=[Deployment (O.sqlInt8 1) (O.sqlInt8 18) (O.sqlStrictText $ fingerprint cfg) (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "installation_requires_reconciliation")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runInsert c O.Insert {O.iTable=custodycheckTable,O.iRows=[CustodyCheck (O.sqlInt8 1) (O.sqlInt8 0) O.null O.null O.null O.null],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runInsert c O.Insert {O.iTable=operatingclockTable,O.iRows=[OperatingClock (O.sqlInt8 1) (O.sqlInt8 now)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    [row]->require (deploymentSingleton row==1 && deploymentSchemaVersion row==18 && deploymentFingerprint row==fingerprint cfg) "ledger_profile_or_schema_mismatch"
    _->reject "corrupt_deployment"
