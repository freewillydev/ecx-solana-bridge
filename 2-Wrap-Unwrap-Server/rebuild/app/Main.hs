{-# LANGUAGE LambdaCase, ScopedTypeVariables #-}
-- Startup owns resources; all customer/worker effects use their DSL evaluators.
module Main (main) where
import qualified Bridge.Config as C
import Bridge.BrowserBuild (browserAssetsDirectory)
import Bridge.Critical (CustomerSettings(..),withRuntime,runWorkerLoop)
import Bridge.Control (runControl,callControl)
import Bridge.Error
import Bridge.RPC (newRpcManager)
import Bridge.Signer
import Bridge.SigningTransport
import Bridge.Store (withReader,withFencedWriter,StoreRestore(..),evalRestore)
import Bridge.Web (publicApplication)
import Bridge.Wire (Profile(..))
import Control.Concurrent.Async (concurrently_)
import Control.Exception (bracket,catch)
import Data.Aeson (encode,object,(.=),eitherDecodeStrict')
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import Data.Maybe (fromMaybe)
import qualified Database.PostgreSQL.Simple as PG
import Network.HTTP.Client (closeManager)
import Network.Wai.Handler.Warp (runSettings,setHost,setPort,setTimeout,defaultSettings)
import System.Environment (getArgs,lookupEnv)
import System.Exit (die,exitFailure)
import System.FilePath (isAbsolute)
import System.IO (stderr,stdin)
import System.Posix.User (getEffectiveUserName)
import Text.Read (readMaybe)

main :: IO ()
main=(getArgs >>= command) `catch` (\(BridgeError code)->
  LBS.hPutStrLn stderr (encode $ object ["error" .= code]) >> exitFailure)
 where
  command ["check-config",path]=C.loadConfig path >>= LBS.putStrLn . encode . object . pure . ("fingerprint" .=) . C.fingerprint
  command ["check-signer",path,key]=C.loadConfig path >>= \c->verifySigningKey (C.custodyOwner c) key >> putStrLn "Custody signer valid"
  command ["restore-ledger",path,manifest,minimumText]=restoreCommand path minimumText (\c->RestoreLedger manifest (C.fingerprint c))
  command ["recover-ledger",path,backup,snapshot,directory,minimumText]=
    restoreCommand path minimumText (\c->RecoverLedger backup (T.pack snapshot) directory (C.fingerprint c))
  command [mode,path,minimumText] | mode `elem` ["adopt-ledger","retire-ledger"] =
    restoreCommand path minimumText (\c->(if mode=="adopt-ledger" then AdoptLedger else RetireLedger) (C.fenceDirectory c) (C.fingerprint c))
  command ["operator",path]=do
    c<-C.loadConfig path
    bytes<-BS.hGet stdin 4097
    require (BS.length bytes<=4096) "operator_message_too_large"
    value<-either (const $ reject "invalid_operator_request") pure (eitherDecodeStrict' bytes)
    callControl (C.fenceDirectory c) value >>= LBS.putStrLn . encode
  command ["signer",path,key]=do
    c<-C.loadConfig path
    database<-databaseSettings
    withReader database (C.fingerprint c) (C.backupRequired c) $ \reader->
      bracket newRpcManager closeManager $ \manager->
        withSigner manager reader (SignerSettings (C.nativeSettings c) (C.solanaSettings c) (C.solanaPolicy c) (C.solanaSdkLibrary c) key) $
          runSigningServer (SigningEndpoint (C.signerPort c) (C.signerAuthFile c))
  command [mode,path] | mode `elem` ["serve","observe"] = do
    c<-C.loadConfig path
    require (C.profile c `elem` [L2LSignetDevnet,ECXBetanetDevnet]) "public_test_profile_required"
    -- Remote recovery integration is unfinished. Never silently bypass coverage.
    require (not $ C.backupRequired c) "remote_backup_integration_required"
    database<-databaseSettings
    readUser<-lookupEnv "PGREADUSER" >>= maybe (reject "read_database_user_required") pure
    require (not(null readUser) && readUser/=PG.connectUser database) "distinct_read_database_user_required"
    readPassword<-fromMaybe "" <$> lookupEnv "PGREADPASSWORD"
    assets<-fromMaybe browserAssetsDirectory <$> lookupEnv "ECX_ASSETS"
    links<-lookupEnv "ECX_INTERFACE_CONFIG" >>= C.loadInterface c
    let readerSettings=database {PG.connectUser=readUser,PG.connectPassword=readPassword}
        policy=C.storePolicy c
        customer=CustomerSettings (C.publicConfiguration c links (mode=="serve")) policy
          (C.solanaSdkLibrary c) (const $ reject "remote_backup_integration_required")
        endpoint=SigningEndpoint (C.signerPort c) (C.signerAuthFile c)
    withReader readerSettings (C.fingerprint c) (C.backupRequired c) $ \reader->
      withFencedWriter database policy (C.fenceDirectory c) $ \writer->
        bracket newRpcManager closeManager $ \manager->
          withRuntime manager (C.observerSettings c) (C.solanaPolicy c) (Just customer) endpoint reader writer $ \worker evaluate operatorControl->do
            app<-publicApplication assets evaluate
            concurrently_
              (runSettings (setHost "127.0.0.1" $ setPort (C.serverPort c) $ setTimeout 65 defaultSettings) app)
              (concurrently_ (runWorkerLoop worker) (runControl (C.fenceDirectory c) operatorControl))
  command _=die "Usage: ecx-bridge-rebuild adopt-ledger CONFIG MINIMUM_SEQUENCE | retire-ledger CONFIG MINIMUM_SEQUENCE | recover-ledger CONFIG BACKUP_CONFIG SNAPSHOT STAGING MINIMUM_SEQUENCE | restore-ledger CONFIG MANIFEST MINIMUM_SEQUENCE (offline database owner) | check-config CONFIG | check-signer CONFIG KEYFILE | signer CONFIG KEYFILE (SELECT-only PGUSER) | operator CONFIG (JSON on stdin) | serve CONFIG | observe CONFIG (PG* and distinct PGREADUSER; existing migrated ledger and host fence required)"
  restoreCommand path minimumText operation=do
    c<-C.loadConfig path
    minimumSequence<-maybe (reject "invalid_restore_policy") pure (readMaybe minimumText)
    database<-databaseSettings
    (restored,sequenceNo)<-evalRestore database (operation c minimumSequence)
    LBS.putStrLn $ encode $ object ["database" .= restored,"criticalSequence" .= sequenceNo,"paused" .= True]

databaseSettings :: IO PG.ConnectInfo
databaseSettings = do
  localUser<-getEffectiveUserName
  host<-fromMaybe "/var/run/postgresql" <$> lookupEnv "PGHOST"
  require (isAbsolute host || host `elem` ["127.0.0.1","localhost","::1"]) "local_database_required"
  database<-lookupEnv "PGDATABASE" >>= maybe (reject "database_name_required") pure
  require (not $ null database) "database_name_required"
  portText<-fromMaybe "5432" <$> lookupEnv "PGPORT"
  port<-case readMaybe portText of Just n | n>0 && n<=65535->pure (n::Int); _->reject "invalid_database_port"
  user<-fromMaybe localUser <$> lookupEnv "PGUSER"
  password<-fromMaybe "" <$> lookupEnv "PGPASSWORD"
  pure PG.defaultConnectInfo {PG.connectHost=host,PG.connectPort=fromIntegral port,PG.connectDatabase=database,PG.connectUser=user,PG.connectPassword=password}
