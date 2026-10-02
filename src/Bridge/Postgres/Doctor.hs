{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Postgres.Doctor (doctor,checkDatabase) where
import Bridge.Config (Config,profile,fingerprint)
import Bridge.Types (BridgeError(..),reject)
import Bridge.Native (nativeIdentity)
import Bridge.Solana (solanaIdentity)
import Bridge.RPC (newRpcManager)
import Bridge.Postgres.Schema
import Control.Exception (bracket,catch,try,IOException)
import Data.Aeson
import Data.Int (Int64)
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

-- Diagnostic reads neither claim the worker lock nor initialize/migrate a ledger.
checkDatabase :: PG.ConnectInfo -> Config -> IO Value
checkDatabase settings cfg = protected $ bracket (PG.connect settings) PG.close $ \db ->
  PG.withTransaction db $ do
    _ <- PG.execute_ db "SET TRANSACTION READ ONLY"
    _ <- PG.execute_ db "SET LOCAL statement_timeout='10s'"
    rows <- O.runSelect db (O.selectTable deploymentTable) :: IO [Deployment]
    row <- case rows of
      [d] | deploymentSingleton d==1 && deploymentSchemaVersion d==18
          && deploymentFingerprint d==fingerprint cfg -> pure d
      _ -> reject "ledger_profile_or_schema_mismatch"
    versions <- PG.query_ db "SELECT current_setting('server_version_num')::bigint" :: IO [PG.Only Int64]
    version <- case versions of [PG.Only v] -> pure v; _ -> reject "postgres_identity_unavailable"
    pure $ object ["engine" .= ("PostgreSQL" :: String),"serverVersionNumber" .= version
      ,"schemaVersion" .= deploymentSchemaVersion row,"fingerprint" .= deploymentFingerprint row
      ,"paused" .= (deploymentPaused row/=0),"criticalSequence" .= deploymentCriticalSequence row
      ,"readOnly" .= True]
 where
  protected action = action
    `catch` (\(_ :: PG.SqlError) -> reject "postgres_diagnostic_unavailable")
    `catch` (\(_ :: IOException) -> reject "postgres_diagnostic_unavailable")

doctor :: PG.ConnectInfo -> Config -> IO Value
doctor settings cfg = do
  manager <- newRpcManager
  native <- inspect (nativeIdentity manager cfg)
  solana <- inspect (solanaIdentity manager cfg)
  database <- inspect (checkDatabase settings cfg)
  pure $ object ["profile" .= profile cfg,"fingerprint" .= fingerprint cfg
    ,"native" .= native,"solana" .= solana,"database" .= database
    ,"implementationReady" .= False]
 where
  inspect action = do
    result <- try (action `catch` (\(_ :: IOException) -> reject "diagnostic_io_unavailable")) :: IO (Either BridgeError Value)
    pure $ case result of
      Right evidence -> object ["ok" .= True,"evidence" .= evidence]
      Left (BridgeError code) -> object ["ok" .= False,"error" .= code]
