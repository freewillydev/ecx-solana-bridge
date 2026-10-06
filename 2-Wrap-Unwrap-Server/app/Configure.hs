{-# LANGUAGE ScopedTypeVariables #-}
-- Offline installation material only: no database, RPC, signing or activation.
module Configure (configure,start) where
import qualified Bridge.Config as C
import Bridge.SDKBuild (sdkLibraryPath,sdkSourceDirectory)
import Bridge.BrowserBuild (browserAssetsDirectory)
import System.Environment (getExecutablePath)
import Bridge.Error
import Bridge.AdminKey (privateParent,readPrivate,savePrivate)
import Bridge.Signer (verifySigningKey,verifyNativeUnlock)
import Control.Exception (IOException,catch,onException)
import Control.Monad (foldM,forM_,when)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Maybe (fromMaybe)
import Data.List (sort)
import Control.Concurrent (threadDelay)
import Network.HTTP.Client (HttpException)
import System.Process (rawSystem,readProcessWithExitCode)
import System.Exit (ExitCode(..))
import System.Info (os,arch)
import Text.Read (readMaybe)
import System.Posix.User (getEffectiveUserID)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as M
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import System.Directory (makeAbsolute,canonicalizePath,removeDirectoryRecursive,doesFileExist)
import System.FilePath ((</>))
import qualified System.Posix.Directory as P
import System.IO (hFlush,stdout,isEOF)

configure :: IO ()
configure=do
  putStrLn "For fresh Ubuntu installation, run configure and start with sudo; source secret files must be root-owned and private."
  putStrLn "Prepare NEW installation material. Existing deployments must use recovery/upgrade."
  putStrLn "No network calls, wallet creation, database changes or payments. Amounts are base units."
  destination<-prompt "New private output directory" ".ecx-bridge" makeAbsolute
  -- Exclusive directory creation refuses overwriting an existing configuration or custody.
  P.createDirectory destination 0o700
  build destination `onException` removeDirectoryRecursive destination

build :: FilePath -> IO ()
build directory=do
  privateParent (directory</>"worker.json")
  selected<-prompt "Network: L2LSignetDevnet / ECXBetanetDevnet / CanonicalBeta (real funds)" "L2LSignetDevnet" $ \s->do
    require (s `elem` ["L2LSignetDevnet","ECXBetanetDevnet","CanonicalBeta"]) "choose_listed_network"
    pure s
  let canonical=selected=="CanonicalBeta"; signet=selected=="L2LSignetDevnet"
      replace k v=M.insert k v
      defaults=replace "profile" (String $ T.pack selected)
        $ replace "deploymentId" (String "ecx-bridge")
        $ replace "nativeRpc" (String $ if signet then "http://127.0.0.1:29432" else "http://127.0.0.1:28532")
        $ replace "nativeCheckpointHeight" (Number $ if signet then 16000 else 967680)
        $ replace "nativeCheckpointHash" (String $ if signet then "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47" else "00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042")
        $ replace "mint" (String $ if canonical then "EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq" else "")
        $ replace "solanaRpc" (String $ if canonical then "" else "https://api.devnet.solana.com")
        $ replace "backupRequired" (Bool canonical) template
  config<-collect defaults
  installed<-prompt "Is this an existing installer-managed bridge (database and services already set up)? yes/no" "no" yesNo
  setup<-if installed then pure(object ["existing" .= True]) else do
    provision<-prompt "Set up PostgreSQL, restricted roles and a NEW paused ledger when starting? yes/no" "yes" yesNo
    if not provision then do
      putStrLn "Database setup skipped; start will require an existing installer-managed deployment."
      pure(object ["existing" .= True])
     else do
      method<-prompt "Installation source: source (your local Cabal build) / release (signed package)" "source" $ \s->do
        require (s `elem` ["source","release"]) "choose_source_or_release"
        pure s
      if method=="source" then do
        putStrLn "Trust the local checkout and this executable. No release signature is claimed; start does not compile as root."
        defaultRoot<-canonicalizePath (sdkSourceDirectory</>"../..")
        root<-prompt "Path to trusted repository checkout" defaultRoot makeAbsolute
        restic<-prompt "Path to reviewed restic backup executable (see docs/INSTALL.md)" "" $ \path->do
          file<-makeAbsolute path
          exists<-doesFileExist file
          require exists "restic_executable_file_required"
          pure file
        pure(object ["existing" .= False,"method" .= method,"sourceRoot" .= root,"restic" .= restic])
       else do
        auth<-prompt "Repository release-auth script path" "2-Wrap-Unwrap-Server/scripts/release-auth" makeAbsolute
        trust<-prompt "Path to trusted release PUBLIC key file (prefer absolute path; obtained independently of package)" "" makeAbsolute
        candidate<-prompt "Path to reviewed signed installer directory" "" makeAbsolute
        pure(object ["existing" .= False,"method" .= method,"installer" .= auth,"trustKey" .= trust,"candidate" .= candidate])
  key<-prompt "Existing custody Solana JSON keypair FILE (private; never type the key here)" "" $ \path->do
    file<-makeAbsolute path
    verifySigningKey (C.custodyOwner config) file
    pure file
  workerAuth<-credential "Restricted native WORKER credential FILE (user:password)"
  signerAuth<-prompt "Distinct native SIGNER credential FILE (user:password)" "" $ \path->do
    file<-makeAbsolute path
    bytes<-readCredential file
    workerBytes<-readCredential workerAuth
    require (bytes/=workerBytes) "worker_signer_credentials_must_differ"
    pure file
  unlock<-optionalFile "Native wallet passphrase FILE (blank if unencrypted)"
  backups<-if C.backupRequired config then do
    repository<-prompt "Initialized HTTPS restic repository FILE (private)" "" $ \path->do
      file<-makeAbsolute path
      bytes<-readPrivate file
      require (any (`B.isPrefixOf` bytes) ["rest:https://","https://"]) "https_backup_repository_required"
      pure file
    password<-prompt "Restic encryption password FILE (private)" "" $ \path->do
      file<-makeAbsolute path
      bytes<-readPrivate file
      require (not $ B.null bytes) "backup_password_required"
      pure file
    pure [("backup.repository",repository),("backup.password",password)]
   else pure []
  links<-collectLinks config
  tls<-prompt "Public HTTPS? yes/no (certificate must already exist)" "no" yesNo
  tlsFiles<-if tls then do
    cert<-requiredFile "TLS full-chain certificate FILE (private source copy)"
    secret<-requiredFile "TLS private-key FILE (separate from custody key)"
    secretBytes<-readPrivate secret
    keyBytes<-readPrivate key
    require (secretBytes/=keyBytes) "separate_tls_key_required"
    pure [("public-fullchain.pem",cert),("public-privkey.pem",secret)]
   else pure []
  let worker=config {C.nativeCookie=workerAuth,C.nativeUnlockFile=Nothing}
      signer=config {C.nativeCookie=signerAuth,C.nativeUnlockFile=if null unlock then Nothing else Just unlock}
      sources=[("solana.keypair.json",key),("native-worker.auth",workerAuth),("native-signer.auth",signerAuth)]
        <>[("native-unlock",unlock) | not(null unlock)]<>backups<>tlsFiles
      records=[("setup.json",L.toStrict $ encode setup),("sources.json",L.toStrict $ encode $ object [K.fromString name .= path | (name,path)<-sources])
        ,("interface.json",L.toStrict $ encode links),("signer.json",L.toStrict $ encode signer),("worker.json",L.toStrict $ encode worker)]
  C.validateConfig worker; C.validateConfig signer
  mapM_ (\(name,bytes)->savePrivate (directory</>name) bytes) records
  putStrLn $ "Saved settings and source-file references (no copied key files) in "<>directory
  putStrLn $ "Next: ecx-bridge start "<>directory<>" (Ubuntu 24.04; sudo for installation)."
  putStrLn "Node/RPC permissions, initialized remote backup, DNS, certificate renewal and funding still require provisioning."
  putStrLn "Nothing has been installed or activated. Never initialize a fresh ledger for existing custody."
 where
  requiredFile label=prompt label "" $ \path->do
    file<-makeAbsolute path
    _<-readPrivate file
    pure file
  optionalFile label=prompt label "-" $ \path->if path=="-" then pure "" else do
    file<-makeAbsolute path
    privateParent file
    verifyNativeUnlock file
    pure file
  credential label=prompt label "" $ \path->do
    file<-makeAbsolute path
    _<-readCredential file
    pure file
  readCredential path=do
    bytes<-makeAbsolute path >>= readPrivate
    let value=B8.dropWhileEnd (`elem` ['\r','\n']) bytes
    require (not(B.null value) && B8.elem ':' value && not(B8.any (`elem` ['\r','\n','\0']) value)) "expected_native_user_password"
    pure value

-- Reuse the full runtime validator; cross-field errors allow editing the collected answers.
collect :: Object -> IO C.Config
collect initial=do
  fields<-foldM ask initial [k | k<-sort (M.keys initial),k `notElem` fixed]
  case fromJSON (Object fields) of
    Error _->putStrLn "Invalid field type or amount; correct the settings." >> collect fields
    Success c->(C.validateConfig c >> pure c) `catch` (\(BridgeError code)->do
      putStrLn $ "Please correct settings: "<>T.unpack code
      collect fields) `catch` (\(_::HttpException)->putStrLn "Invalid RPC URL; correct the endpoint fields." >> collect fields)
 where
  fixed=["profile","nativeCookie","nativeUnlockFile","signerAuthFile","fenceDirectory","solanaSdkLibrary"]
  ask fields key=do
    let old=fromMaybe Null (M.lookup key fields)
        shown=case old of String t | "REQUIRED_" `T.isPrefixOf` t->""; String t->T.unpack t; Null->"-"; _->B8.unpack $ L.toStrict $ encode old
    value<-prompt (K.toString key<>(if old==Null then " (- = none)" else "")) shown $ \input->
      case old of
        String _->pure(String $ T.pack input)
        Null->pure(if input=="-" then Null else String $ T.pack input)
        Number _->case readMaybe input :: Maybe Integer of
          Just n | n>=0 && n<=9223372036854775807->pure(Number $ fromInteger n)
          _->reject "enter_nonnegative_bounded_integer"
        _->case eitherDecodeStrict' (B8.pack input) of
          Right v | sameKind old v->pure v
          _->reject "enter_boolean_or_integer_as_shown"
    pure(M.insert key value fields)
  sameKind (Bool _) (Bool _)=True
  sameKind _ _=False

collectLinks :: C.Config -> IO Value
collectLinks config=go
 where
  go=do
    entries<-mapM (\key->do
      value<-prompt (K.toString key<>" (- = none)") "-" pure
      pure(key,if value=="-" then Null else String $ T.pack value))
      ["publicOrigin","supportUrl","jupiterUrl","nativeExplorerBase","orcaUrl"]
    let value=Object(M.fromList entries)
    case fromJSON value of
      Error _->reject "invalid_interface_fields"
      Success links->(C.validateInterface config links >> pure value) `catch` (\(BridgeError code)->putStrLn(T.unpack code) >> go)

yesNo :: String -> IO Bool
yesNo "yes"=pure True
yesNo "no"=pure False
yesNo _=reject "enter_yes_or_no"

prompt :: String -> String -> (String -> IO a) -> IO a
prompt label fallback validate=do
  putStr $ label<>(if null fallback then "" else " ["<>fallback<>"]")<>": "
  hFlush stdout
  ended<-isEOF
  when ended (reject "configuration_cancelled_eof")
  raw<-getLine
  let value=if null raw then fallback else raw
  (do require (not(null value) && length value<=8192 && all (\x->x>=' ' && x/='\DEL') value) "value_required_or_too_long"
      validate value)
    `catch` (\(BridgeError code)->putStrLn(T.unpack code) >> prompt label fallback validate)
    `catch` (\(_::HttpException)->putStrLn "Invalid RPC URL." >> prompt label fallback validate)
    `catch` (\(_::IOException)->putStrLn "Cannot read that private file/path; check ownership and permissions." >> prompt label fallback validate)

template :: Object
template=case eitherDecodeStrict' "{\"profile\":\"ECXBetanetDevnet\",\"deploymentId\":\"ecx-betanet-devnet-operator\",\"nativeRpc\":\"http://127.0.0.1:28532\",\"nativeCookie\":\"/run/ecx-betanet/rpc.cookie\",\"nativeWallet\":\"ecx-bridge-betanet-test\",\"nativeCheckpointHeight\":967680,\"nativeCheckpointHash\":\"00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042\",\"solanaRpc\":\"https://api.devnet.solana.com\",\"solanaVerifierRpc\":null,\"mint\":\"REQUIRED_REAL_DEVNET_MINT\",\"custodyOwner\":\"REQUIRED_DEVNET_CUSTODY_OWNER\",\"custodyAta\":\"REQUIRED_DEVNET_CUSTODY_ATA\",\"signerPort\":8081,\"signerAuthFile\":\"/etc/ecx-bridge/signing.auth\",\"solanaSdkLibrary\":\"/opt/ecx-bridge/current/lib/libecx_solana_sdk.so\",\"minInput\":\"10000\",\"maxInput\":\"100000\",\"maxQueued\":4,\"quoteSeconds\":300,\"confirmationGraceSeconds\":1200,\"nativeConfirmations\":1,\"maxNativeFee\":\"1000\",\"maxSolFee\":\"10000\",\"maxSolAccountRent\":\"2100000\",\"maxNativeDailyCost\":\"10000\",\"maxSolDailyCost\":\"10000000\",\"backupRequired\":false,\"solanaHistoryStart\":\"REQUIRED_EARLIEST_CUSTODY_TOKEN_HISTORY_SIGNATURE\",\"solanaOperatingHistoryStart\":\"REQUIRED_EARLIEST_FEE_PAYER_SOL_HISTORY_SIGNATURE\",\"serverPort\":8080,\"fenceDirectory\":\"/var/lib/ecx-bridge/fence\",\"nativeUnlockFile\":null}" of
  Right (Object fields)->fields
  _->error "invalid embedded configuration template"

-- The installer remains the single owner of database/service provisioning.
-- No shell interpolation, fresh-ledger fallback or automatic service activation on import.
start :: FilePath -> IO ()
start path=do
  require (os=="linux") "start_requires_ubuntu_24_04"
  directory<-makeAbsolute path
  bytes<-readPrivate (directory</>"setup.json")
  value<-either (const $ reject "invalid_setup_json") pure (eitherDecodeStrict' bytes)
  existing<-field "existing" value
  uid<-getEffectiveUserID
  let execute program args=do
        result<-if uid==0 then rawSystem program args else rawSystem "sudo" (program:args)
        require (result==ExitSuccess) "setup_command_failed_state_preserved"
  (present,_,_)<-readProcessWithExitCode "systemctl" ["cat","ecx-bridge-worker.service","ecx-bridge-signer.service"] ""
  when (present/=ExitSuccess) $ do
    require (not existing) "existing_services_missing_use_recovery_not_fresh"
    method<-either (const $ reject "invalid_setup_method") pure
      (parseEither (withObject "setup" (\o->o .:? "method" .!= ("release"::String))) value)
    -- Old setup files retain signed-release verification; never silently downgrade.
    require (uid==0) "fresh_install_run_sudo_ecx_bridge_configure_then_sudo_ecx_bridge_start"
    case method of
      "source"->do
        root<-field "sourceRoot" value
        restic<-field "restic" value
        binaryPath<-getExecutablePath
        execute "/bin/sh" [root</>"2-Wrap-Unwrap-Server/install/source",binaryPath,sdkLibraryPath,browserAssetsDirectory,restic,directory]
      "release"->do
        installer<-field "installer" value
        trust<-field "trustKey" value
        candidate<-field "candidate" value
        architecture<-case arch of "aarch64"->pure "aarch64"; "x86_64"->pure "x86_64"; _->reject "unsupported_installer_architecture"
        execute installer ["install",trust,candidate,architecture,"--","fresh",directory]
      _->reject "invalid_setup_method"
  requested<-C.loadConfig (directory</>"worker.json")
  installedConfig<-C.loadConfig config
  let normalized=requested {C.nativeCookie=C.nativeCookie installedConfig,C.nativeUnlockFile=C.nativeUnlockFile installedConfig
        ,C.signerAuthFile=C.signerAuthFile installedConfig,C.fenceDirectory=C.fenceDirectory installedConfig
        ,C.solanaSdkLibrary=C.solanaSdkLibrary installedConfig}
  require (normalized==installedConfig) "installed_configuration_differs_use_reviewed_upgrade"
  sourceInterface<-B.readFile(directory</>"interface.json")
  installedInterface<-B.readFile "/etc/ecx-bridge/worker/interface.json"
  require (sourceInterface==installedInterface) "installed_material_differs_updated_package_required"
  sourceBytes<-readPrivate(directory</>"sources.json")
  sources<-either (const $ reject "invalid_source_references") pure (eitherDecodeStrict' sourceBytes :: Either String Object)
  forM_ ["public-fullchain.pem","public-privkey.pem"] $ \name->
    when (M.member (K.fromString name) sources) $ do
      exists<-doesFileExist("/etc/ecx-bridge/worker"</>name)
      require exists "installed_tls_missing_updated_package_required"
  execute "systemctl" ["start","ecx-bridge-signer","ecx-bridge-worker"]
  putStrLn "Services started paused. Checking readiness before enabling orders."
  let operatorArgs=if uid==0 then ["-u","ecxbridgew","--",binary,"operator",config]
                   else ["-u","ecxbridgew",binary,"operator",config]
      operator=readProcessWithExitCode (if uid==0 then "runuser" else "sudo") operatorArgs
      waitReady :: Int -> IO ()
      waitReady remaining=do
        (code,_,_)<-operator "{\"operation\":\"status\"}"
        if code==ExitSuccess then pure () else do
          require (remaining>0) "worker_startup_failed_check_systemctl_status"
          threadDelay 500000
          waitReady (remaining-1)
  waitReady 20
  (result,_,failure)<-readProcessWithExitCode (if uid==0 then "runuser" else "sudo")
    (if uid==0 then ["-u","ecxbridgew","--",binary,"operator",config]
     else ["-u","ecxbridgew",binary,"operator",config]) "{\"operation\":\"resume\"}"
  if result==ExitSuccess then putStrLn "Bridge ready; customer orders enabled."
    else do
      case eitherDecodeStrict' (B8.pack failure) of
        Right (Object err) | Just (String reason)<-M.lookup "error" err->putStrLn ("Readiness refused: "<>T.unpack reason)
        _->putStrLn "Readiness check failed; inspect operator status and service logs."
      reject "bridge_paused_complete_prerequisites_then_rerun_start"
 where
  binary="/opt/ecx-bridge/current/bin/ecx-bridge"
  config="/etc/ecx-bridge/worker/config.json"
  field name value=either (const $ reject "invalid_setup_json") pure (parseEither (withObject "setup" (.:name)) value)
