module Main where
import Bridge.Config
import Bridge.Worker
import qualified Bridge.Postgres.Runtime as Postgres
import qualified Bridge.Postgres.Backup as Backup
import qualified Bridge.Postgres.Maintenance as Maintenance
import qualified Database.PostgreSQL.Simple as PG
import System.Posix.User (getEffectiveUserName)
import Bridge.Web
import Bridge.Types
import Control.Exception (catch)
import Data.Aeson (encode,object,(.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import System.Environment (getArgs,lookupEnv)
import Data.Maybe (fromMaybe)
import System.Exit (die,exitFailure)
import Text.Read (readMaybe)
main :: IO ()
main = go `catch` (\(BridgeError code) -> LBS.putStrLn (encode $ object ["error" .= code]) >> exitFailure)
 where
  go = getArgs >>= \case
    ["version"] -> putStrLn "ecx-bridge 0.1.0.0 (development; explicit public-test mode available)"
    ["check-config",path] -> loadConfig path >>= LBS.putStrLn . encode . object . pure . ("fingerprint" .=) . fingerprint
    ["check-interface",configPath,interfacePath] -> loadConfig configPath >>= \c -> loadInterface c (Just interfacePath) >> putStrLn "Interface configuration valid"
    ["check-signer",configPath,keyPath] -> loadConfig configPath >>= \c -> Maintenance.verifySigner c keyPath >> putStrLn "Custody signer valid"
    ["doctor",path] -> loadConfig path >>= doctor >>= LBS.putStrLn . encode
    ["scan",path] -> loadConfig path >>= scanOnce >>= LBS.putStrLn . encode
    ["reconcile",path] -> loadConfig path >>= reconcileOnce >>= LBS.putStrLn . encode
    ["recover",path] -> loadConfig path >>= recoverOnce >>= LBS.putStrLn . encode
    ["allocate-test-operating",path,signature,quantity] -> case readMaybe quantity >>= either (const Nothing) Just . amount of
      Just value | units value>0 -> loadConfig path >>= \c -> allocateTestOperating c (T.pack signature) value >>= LBS.putStrLn . encode
      _ -> die "Invalid operating funding amount (expected positive integer lamports)"
    ["approve-solana-retry",path,txid,reason] -> loadConfig path >>= \c -> approveRetry c (T.pack txid) (T.pack reason) >>= LBS.putStrLn . encode
    ["approve-source-recovery",path,intent,restoration,reason] -> case readMaybe restoration of
      Just sequenceNo | sequenceNo>0 -> loadConfig path >>= \c -> approveRestoredSource c (T.pack intent) sequenceNo (T.pack reason) >>= LBS.putStrLn . encode
      _ -> die "Invalid source restoration sequence (expected a positive integer)"
    ["cover-source-loss",path,deposit,recovery,fromFloat,fromEarned,reason] -> case (readMaybe recovery,readMaybe fromFloat,readMaybe fromEarned) of
      (Just sequenceNo,Just f,Just e) | sequenceNo>0,Right floatAmount<-amount f,Right earnedAmount<-amount e ->
        loadConfig path >>= \c -> coverLoss c (T.pack deposit) sequenceNo floatAmount earnedAmount (T.pack reason) >>= LBS.putStrLn . encode
      _ -> die "Invalid source loss sequence or capital allocation (use nonnegative integer base units)"
    ["prepare-native-replacement",path,parent,fee,reason] -> case readMaybe fee >>= either (const Nothing) Just . amount of
      Just quantity | units quantity>0 -> loadConfig path >>= \c -> draftReplacement c (T.pack parent) quantity (T.pack reason) >>= LBS.putStrLn . encode
      _ -> die "Invalid replacement fee (expected positive integer base units)"
    ["cancel-native-replacement",path,sequenceText,reason] -> case readMaybe sequenceText of
      Just sequenceNo | sequenceNo>0 -> loadConfig path >>= \c -> cancelReplacement c sequenceNo (T.pack reason) >>= LBS.putStrLn . encode
      _ -> die "Invalid native replacement draft sequence (expected a positive integer)"
    ["cancel-preparation",path,intent,generation,reason] -> case readMaybe generation of
      Just g | g>=0 && g<8 -> loadConfig path >>= \c -> cancelUnsigned c (T.pack intent) g (T.pack reason) >>= LBS.putStrLn . encode
      _ -> die "Invalid preparation generation (expected 0 through 7)"
    ["postgres-init",path] -> do
      cfg <- loadConfig path
      settings <- postgresSettings
      Maintenance.initialize settings cfg
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
    ["worker",path] -> loadConfig path >>= runWorker
    ["test-worker",path] -> loadConfig path >>= runTestWorker
    ["serve",socket,port,assets] -> case readMaybe port of
      Just p | p>=1024 && p<=65535 -> runPublic socket p assets
      _ -> die "Invalid unprivileged port"
    _ -> die "Usage: ecx-bridge version | check-config CONFIG | check-interface CONFIG INTERFACE | check-signer CONFIG KEYFILE (offline, no signing) | doctor CONFIG | scan CONFIG | reconcile CONFIG | recover CONFIG | allocate-test-operating CONFIG SIGNATURE LAMPORTS | approve-solana-retry CONFIG SIGNATURE REASON | approve-source-recovery CONFIG OBLIGATION RESTORATION_SEQUENCE REASON | cover-source-loss CONFIG DEPOSIT LOSS_SEQUENCE FLOAT_UNITS EARNED_UNITS REASON | prepare-native-replacement CONFIG TRANSACTION FEE_UNITS REASON | cancel-native-replacement CONFIG DRAFT_SEQUENCE REASON | cancel-preparation CONFIG INTENT GENERATION REASON | postgres-init CONFIG (offline maintenance) | postgres-test-worker CONFIG (PG* settings, Signet-or-betanet/Devnet) | check-backup BACKUP_CONFIG | postgres-backed-test-worker CONFIG BACKUP_CONFIG (PG* settings, backup-required Devnet only) | postgres-api CONFIG (PG* settings, paused test deployment) | worker CONFIG | test-worker CONFIG | serve CUSTOMER_SOCKET PORT ASSETS"

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
