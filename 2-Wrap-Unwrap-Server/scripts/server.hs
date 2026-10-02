module Main where
import Bridge.Config
import Bridge.Control (callControl)
import qualified Bridge.Signer as Signer
import qualified Bridge.Postgres.Runtime as Postgres
import qualified Bridge.Postgres.Backup as Backup
import qualified Bridge.Postgres.Maintenance as Maintenance
import qualified Database.PostgreSQL.Simple as PG
import System.Posix.User (getEffectiveUserName)
import Bridge.Types
import Control.Exception (catch)
import Data.Aeson (encode,object,(.=),eitherDecodeStrict')
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import System.Environment (getArgs,lookupEnv)
import Data.Maybe (fromMaybe)
import System.IO (stdin)
import System.Exit (die,exitFailure)
import Text.Read (readMaybe)
main :: IO ()
main = go `catch` (\(BridgeError code) -> LBS.putStrLn (encode $ object ["error" .= code]) >> exitFailure)
 where
  go = getArgs >>= \case
    ["signer",configPath,privatePath] -> do
      cfg <- loadConfig configPath
      settings <- postgresSettings
      Signer.runSigner settings cfg privatePath
    ["operator",path] -> do
      cfg <- loadConfig path
      bytes <- BS.hGet stdin 16385
      require (BS.length bytes<=16384) "operator_message_too_large"
      command <- either (const $ reject "invalid_operator_request") pure (eitherDecodeStrict' bytes)
      callControl cfg command >>= LBS.putStrLn . encode
    ["version"] -> putStrLn "ecx-bridge 0.1.0.0 (development; explicit public-test mode available)"
    ["check-config",path] -> loadConfig path >>= LBS.putStrLn . encode . object . pure . ("fingerprint" .=) . fingerprint
    ["check-interface",configPath,interfacePath] -> loadConfig configPath >>= \c -> loadInterface c (Just interfacePath) >> putStrLn "Interface configuration valid"
    ["check-signer",configPath,keyPath] -> loadConfig configPath >>= \c -> Maintenance.verifySigner c keyPath >> putStrLn "Custody signer valid"
    ["doctor",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Postgres.doctor settings cfg >>= LBS.putStrLn . encode
    command:_ | command `elem` ["scan","reconcile","recover","allocate-test-operating","approve-solana-retry","approve-source-recovery","cover-source-loss","prepare-native-replacement","cancel-native-replacement","cancel-preparation"] -> reject "local_operator_command_required"
    ["postgres-init",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Maintenance.initialize settings cfg
    ["postgres-init-worker-fence",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Maintenance.initializeWorkerFence settings cfg
      putStrLn "Host-local worker fence initialized; intake remains paused"
    ["postgres-retire-worker",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Maintenance.retireWorkerFence settings cfg
      putStrLn "Host-local paying worker retired; no automatic reactivation"
    ["postgres-test-worker",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Postgres.runTestWorker settings cfg
    ["check-backup",path] -> Backup.loadRemoteBackup path >> putStrLn "Backup configuration valid"
    ["postgres-backed-test-worker",path,backupPath] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      policy <- Backup.loadRemoteBackup backupPath
      Postgres.runBackedTestWorker settings cfg policy
    ["postgres-api",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Postgres.runAPI settings cfg
    ["worker",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Postgres.runAPI settings cfg
    ["test-worker",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Postgres.runTestWorker settings cfg
    _ -> die "Usage: ecx-bridge signer CONFIG PRIVATE_SIGNER_CONFIG (SELECT-only PG role) | version | check-config CONFIG | check-interface CONFIG INTERFACE | check-signer CONFIG KEYFILE | doctor CONFIG | postgres-init CONFIG | postgres-init-worker-fence CONFIG (stopped worker, ECX_WORKER_FENCE_DIR) | postgres-retire-worker CONFIG (stopped worker) | postgres-test-worker CONFIG (PG* settings, real Devnet profiles) | check-backup BACKUP_CONFIG | postgres-backed-test-worker CONFIG BACKUP_CONFIG | postgres-api CONFIG | worker CONFIG (PostgreSQL observer alias) | test-worker CONFIG (PostgreSQL paying alias) (ECX_PORT defaults to 8080; ECX_ASSETS defaults to Cabal-generated browser assets). Financial operator actions: operator CONFIG < command.json (private local socket; no HTTP)."


postgresSettings :: IO PG.ConnectInfo
postgresSettings = do
  user <- getEffectiveUserName
  host <- fromMaybe "/var/run/postgresql" <$> lookupEnv "PGHOST"
  database <- lookupEnv "PGDATABASE" >>= maybe (die "PGDATABASE is required") pure
  portText <- fromMaybe "5432" <$> lookupEnv "PGPORT"
  port <- case readMaybe portText of Just n | n>0 && n<=65535->pure n; _->die "Invalid PGPORT"
  name <- fromMaybe user <$> lookupEnv "PGUSER"
  password <- fromMaybe "" <$> lookupEnv "PGPASSWORD"
  pure PG.defaultConnectInfo {PG.connectHost=host,PG.connectPort=fromIntegral (port::Int),PG.connectDatabase=database,PG.connectUser=name,PG.connectPassword=password}
