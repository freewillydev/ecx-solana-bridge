{-# LANGUAGE LambdaCase, ScopedTypeVariables #-}
-- Startup owns resources; all customer/worker effects use their DSL evaluators.
module Main (main) where
import Data.Version (showVersion)
import qualified Paths_ecx_bridge as Package
import Configure (launch,configure,configureAdvanced,start,initializeNative)
import qualified Bridge.Config as C
import Bridge.BrowserBuild (browserAssetsDirectory)
import Bridge.Critical (Process(..),runProcess,CustomerSettings(..),SignerSettings(..))
import Bridge.Control (callControl)
import Bridge.Error
import Bridge.RPC (newRpcManager)
import qualified Bridge.Native as N
import Bridge.Recovery (CustodyRecovery(..),evalCustodyRecovery)
import Bridge.Signer
import Bridge.Store (Reader,withReader,withFencedWriter,StoreRestore(..),evalRestore,StoreSetup(..),evalSetup,BackupReceipt(..))
import Control.Exception (bracket,catch)
import Data.Aeson (Value(..),encode,object,(.=),eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import Data.Maybe (fromMaybe)
import qualified Database.PostgreSQL.Simple as PG
import Network.HTTP.Client (closeManager)
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
  command []=launch
  command [flag] | flag `elem` ["version","--version"] = putStrLn ("ecx-bridge " <> showVersion Package.version)
  command ["configure"]=configure
  command ["configure","--advanced"]=configureAdvanced
  command ["initialize-native-wallet",directory]=initializeNative directory
  command ["start"]=start ".ecx-bridge"
  command ["start",directory]=start directory
  command ["check-config",path]=C.loadConfig path >>= LBS.putStrLn . encode . object . pure . ("fingerprint" .=) . C.fingerprint
  command ["check-signer",path,key]=C.loadConfig path >>= \c->verifySigningKey (C.custodyOwner c) key >> putStrLn "Custody signer valid"
  command [mode,path,file] | mode `elem` ["backup-native-wallet","restore-native-wallet"] = do
    c<-C.loadConfig path
    bracket newRpcManager closeManager $ \manager->do
      let native=C.nativeSettings c
          run=N.evalNativeRecoveryWith (N.nativeCall manager native) native
      if mode=="backup-native-wallet"
        then run (N.BackupNativeWallet file) >>= LBS.putStrLn . encode . object . pure . ("manifest" .=)
        else run (N.RestoreNativeWallet file) >> LBS.putStrLn (encode $ object ["wallet" .= C.nativeWallet c])
  command ["backup-custody",path,key,directory]=do
    c<-C.loadConfig path
    database<-databaseSettings
    reader<-readDatabaseSettings database
    bracket newRpcManager closeManager $ \manager->do
      (manifest,sequenceNo)<-evalCustodyRecovery manager c (ExportCustody database reader key directory)
      LBS.putStrLn $ encode $ object ["manifest" .= manifest,"criticalSequence" .= sequenceNo]
  command ["check-custody",path,manifest,minimumText]=do
    c<-C.loadConfig path
    minimumSequence<-maybe (reject "invalid_restore_policy") pure (readMaybe minimumText)
    bracket newRpcManager closeManager $ \manager->do
      sequenceNo<-evalCustodyRecovery manager c (InspectCustody manifest minimumSequence)
      LBS.putStrLn $ encode $ object ["fingerprint" .= C.fingerprint c,"criticalSequence" .= sequenceNo]
  command ["upload-custody",path,backup,manifest,minimumText]=do
    c<-C.loadConfig path
    minimumSequence<-maybe (reject "invalid_restore_policy") pure (readMaybe minimumText)
    bracket newRpcManager closeManager $ \manager->do
      receipt<-evalCustodyRecovery manager c (UploadCustody backup manifest minimumSequence)
      LBS.putStrLn $ encode $ object ["fingerprint" .= receiptIdentity receipt,"criticalSequence" .= receiptSequence receipt
        ,"snapshot" .= receiptSnapshot receipt,"manifestHash" .= receiptArchiveHash receipt]
  command ["recover-custody",path,backup,snapshot,directory,minimumText]=do
    c<-C.loadConfig path
    minimumSequence<-maybe (reject "invalid_restore_policy") pure (readMaybe minimumText)
    bracket newRpcManager closeManager $ \manager->do
      (manifest,n)<-evalCustodyRecovery manager c (RecoverCustody backup (T.pack snapshot) directory minimumSequence)
      LBS.putStrLn $ encode $ object ["manifest" .= manifest,"criticalSequence" .= n]
  command ["restore-ledger",path,manifest,minimumText]=restoreCommand path minimumText (\c->RestoreLedger manifest (C.fingerprint c))
  command ["recover-ledger",path,backup,snapshot,directory,minimumText]=
    restoreCommand path minimumText (\c->RecoverLedger backup (T.pack snapshot) directory (C.fingerprint c))
  command [mode,path,minimumText] | mode `elem` ["adopt-ledger","retire-ledger"] =
    restoreCommand path minimumText (\c->(if mode=="adopt-ledger" then AdoptLedger else RetireLedger) (C.fenceDirectory c) (C.fingerprint c))
  command ["initialize-ledger",path]=do
    c<-C.loadConfig path
    initialize (C.fingerprint c)
  command ["initialize-ledger","--fingerprint",identity]=initialize (T.pack identity)
  command ["operator",path]=do
    c<-C.loadConfig path
    bytes<-BS.hGet stdin 4097
    require (BS.length bytes<=4096) "operator_message_too_large"
    value<-either (const $ reject "invalid_operator_request") pure (eitherDecodeStrict' bytes)
    reply<-callControl (C.fenceDirectory c) value
    case reply of
      Object fields | Just failure<-KM.lookup "error" fields -> case failure of
        String code->reject code
        _->reject "invalid_operator_reply"
      _->LBS.putStrLn (encode reply)
  command args | Just (path,mode)<-processArguments args = do
    c<-C.loadConfig path
    database<-databaseSettings
    withProcessResources c database mode $ \reader process->
      bracket newRpcManager closeManager $ \manager->runProcess manager reader process
  command _=die "Usage: ecx-bridge version | configure [--advanced] | initialize-native-wallet DIRECTORY | start [DIRECTORY] | initialize-ledger CONFIG (fresh database owner; installer may pass --fingerprint ID) | upload-custody CONFIG BACKUP_CONFIG MANIFEST MINIMUM_SEQUENCE | recover-custody CONFIG BACKUP_CONFIG SNAPSHOT DIRECTORY MINIMUM_SEQUENCE | backup-custody CONFIG KEYFILE DIRECTORY (offline custody authority, PG* and PGREADUSER) | check-custody CONFIG MANIFEST MINIMUM_SEQUENCE | backup-native-wallet CONFIG DESTINATION | restore-native-wallet CONFIG MANIFEST (offline custody authority; never overwrites a wallet) | adopt-ledger CONFIG MINIMUM_SEQUENCE | retire-ledger CONFIG MINIMUM_SEQUENCE | recover-ledger CONFIG BACKUP_CONFIG SNAPSHOT STAGING MINIMUM_SEQUENCE | restore-ledger CONFIG MANIFEST MINIMUM_SEQUENCE (offline database owner) | check-config CONFIG | check-signer CONFIG KEYFILE | signer CONFIG KEYFILE [BACKUP_CONFIG STAGING] (SELECT-only PGUSER) | operator CONFIG (JSON on stdin) | serve CONFIG | observe CONFIG (PG* and distinct PGREADUSER; existing migrated ledger and host fence required)"
  initialize identity=do
    database<-databaseSettings
    evalSetup database (InitializeLedger identity)
    LBS.putStrLn $ encode $ object ["fingerprint" .= identity]
  restoreCommand path minimumText operation=do
    c<-C.loadConfig path
    minimumSequence<-maybe (reject "invalid_restore_policy") pure (readMaybe minimumText)
    database<-databaseSettings
    (restored,sequenceNo)<-evalRestore database (operation c minimumSequence)
    LBS.putStrLn $ encode $ object ["database" .= restored,"criticalSequence" .= sequenceNo,"paused" .= True]

data ProcessMode = CustomerMode Bool | SigningMode FilePath (Maybe (FilePath,FilePath))

processArguments :: [String] -> Maybe (FilePath,ProcessMode)
processArguments ["serve",path]=Just (path,CustomerMode True)
processArguments ["observe",path]=Just (path,CustomerMode False)
processArguments ["signer",path,key]=Just (path,SigningMode key Nothing)
processArguments ["signer",path,key,backup,parent]=Just (path,SigningMode key $ Just (backup,parent))
processArguments _=Nothing

-- Only resource data crosses this bracket. Evaluators are created and consumed
-- inside runProcess; no callback here receives execution authority.
withProcessResources :: C.Config -> PG.ConnectInfo -> ProcessMode -> (Reader -> Process -> IO ()) -> IO ()
withProcessResources c database mode action=do
  readerSettings<-case mode of CustomerMode _->readDatabaseSettings database; SigningMode{}->pure database
  let endpoint=SigningEndpoint (C.signerPort c) (C.signerAuthFile c)
  withReader readerSettings (C.fingerprint c) (C.backupRequired c) $ \reader->case mode of
    SigningMode key backup->action reader $ SignerProcess
      (SignerSettings (C.nativeSettings c) (C.solanaSettings c) (C.solanaPolicy c) (C.solanaSdkLibrary c)
        key (C.nativeUnlockFile c) ((\(configuration,parent)->(c,configuration,parent)) <$> backup)) endpoint
    CustomerMode enabled->do
      assets<-fromMaybe browserAssetsDirectory <$> lookupEnv "ECX_ASSETS"
      links<-lookupEnv "ECX_INTERFACE_CONFIG" >>= C.loadInterface c
      let policy=C.storePolicy c
          customer=CustomerSettings (C.publicConfiguration c links enabled) policy (C.solanaSdkLibrary c)
      withFencedWriter database policy (C.fenceDirectory c) $ \writer->action reader $
        WorkerProcess (C.observerSettings c) (C.solanaPolicy c) (Just customer) endpoint writer
          (C.serverPort c) assets (C.fenceDirectory c)

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

readDatabaseSettings :: PG.ConnectInfo -> IO PG.ConnectInfo
readDatabaseSettings database=do
  user<-lookupEnv "PGREADUSER" >>= maybe (reject "read_database_user_required") pure
  require (not(null user) && user/=PG.connectUser database) "distinct_read_database_user_required"
  password<-fromMaybe "" <$> lookupEnv "PGREADPASSWORD"
  pure database {PG.connectUser=user,PG.connectPassword=password}
