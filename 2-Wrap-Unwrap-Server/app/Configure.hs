{-# LANGUAGE ScopedTypeVariables #-}
-- Offline installation material only: wallet generation, no RPC/signing/activation.
module Configure (launch,configure,configureAdvanced,start,initializeNative) where
import qualified Bridge.Config as C
import qualified Bootstrap
import qualified NodeSetup
import qualified SetupPaths
import qualified Token
import qualified Token.Operation as TokenOp
import Bridge.RPC (independentHttps)
import Bridge.SDKBuild (sdkLibraryPath,sdkSourceDirectory)
import Bridge.BrowserBuild (browserAssetsDirectory)
import System.Environment (getExecutablePath)
import Bridge.Wallet (mnemonic,walletKey,nativeDescriptors,derivationPath,protectWalletProcess)
import qualified Bridge.Native as N
import Bridge.SolanaMessage (base58)
import Crypto.Random (getRandomBytes)
import Bridge.Error
import Bridge.AdminKey (privateParent,readPrivate,savePrivate,withFamily)
import Bridge.Signer (verifySigningKey,verifyNativeUnlock)
import Control.Exception (IOException,catch,onException,bracket,finally)
import Control.Monad (foldM,forM_,when)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Maybe (fromMaybe)
import Data.List (sort,isPrefixOf)
import Control.Concurrent (threadDelay)
import Network.HTTP.Client (parseRequest,HttpException,closeManager,newManager,defaultManagerSettings,managerSetProxy,noProxy,managerResponseTimeout,managerRetryableException,responseTimeoutNone)
import System.Process (rawSystem,readProcessWithExitCode,readCreateProcessWithExitCode,proc,CreateProcess(cwd))
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
import System.Directory (makeAbsolute,canonicalizePath,removeDirectoryRecursive,doesFileExist,doesDirectoryExist,setCurrentDirectory,findExecutable)
import System.FilePath ((</>),takeDirectory,addTrailingPathSeparator)
import qualified System.Posix.Directory as P
import System.IO (hFlush,stdout,stdin,isEOF,hIsTerminalDevice,withFile,IOMode(ReadWriteMode),hPutStrLn,hPutStr,hGetLine)

-- One stable entry point; services continue independently after the console exits.
launch :: IO ()
launch=do
  require (os=="linux") "setup_requires_ubuntu_24_04"
  getEffectiveUserID >>= \uid->require (uid==0) "run_sudo_ecx_bridge"
  let home="/var/lib/ecx-bridge-setup"
  exists<-doesDirectoryExist home
  when (not exists) $ P.createDirectory home 0o700
  privateParent (home</>"state")
  setCurrentDirectory home
  configured<-doesFileExist(".ecx-bridge"</>"setup.json")
  when (not configured) configure
  start ".ecx-bridge"

-- The default path is fresh canonical custody. Advanced/recovery remains explicit.
configure :: IO ()
configure=do
  protectWalletProcess
  terminal<-hIsTerminalDevice stdin
  require terminal "wallet_generation_requires_interactive_terminal"
  directory<-makeAbsolute ".ecx-bridge"
  P.createDirectory directory 0o700
  simplified directory `onException` removeDirectoryRecursive directory

simplified :: FilePath -> IO ()
simplified directory=do
  putStrLn "Fresh CanonicalBeta bridge: ECX betanet / Solana Mainnet, canonical mint, 1% each way."
  putStrLn "Both wallets are generated. No payments or node changes occur during configure."
  putStrLn "Fresh Ubuntu installation: run configure and start with sudo."
  putStrLn "Use configure --advanced for other networks, existing wallets or installation choices."
  primary<-prompt "Solana Mainnet RPC URL (or path to private URL file)" "" rpcInput
  verifier<-prompt "Independent Mainnet RPC URL (or private URL file)" "" $ \input->do
    url<-rpcInput input
    independentHttps primary url
    pure url
  let nodeConfig="/var/lib/ecx-betanet/bitcoin.conf"::FilePath
      nodeService="ecx-betanet.service"::String
  putStrLn "A private pruned ECX node is installed automatically during start (Ubuntu 24.04 x86_64)."
  (admin,worker,signer)<-NodeSetup.credentials directory
  repository<-prompt "NEW HTTPS restic repository URL (or private URL file path)" "" $ \input->do
    require (not $ null input) "backup_repository_required"
    bytes<-if any (`isPrefixOf` input) ["rest:https://","https://"] then pure (B8.pack input)
      else B8.strip <$> (makeAbsolute input >>= readPrivate)
    require (any (`B.isPrefixOf` bytes) ["rest:https://","https://"] && not(B8.any (`elem` ['\r','\n',' ']) bytes)) "https_backup_repository_required"
    let file=directory</>"backup.repository"
    savePrivate file bytes
    pure file
  backupSecret<-getRandomBytes 32
  let password=directory</>"backup.password"
  savePrivate password (B8.pack $ T.unpack $ base58 backupSecret)
  origin<-prompt "Public HTTPS origin (https://bridge.example.com), or - for local testing" "-" $ \input->do
    let value=if input=="-" then Nothing else Just (T.pack input)
    -- Validate presentation without accepting arbitrary schemes or URL credentials.
    Bootstrap.validateOrigin value
    pure value
  tls<-case origin of
    Nothing->pure []
    Just _->do
      cert<-prompt "TLS full-chain certificate file path" "" privateFile
      key<-prompt "TLS private-key file path" "" privateFile
      pure [("public-fullchain.pem",cert),("public-privkey.pem",key)]
  bundle<-SetupPaths.bundleRoot
  root<-maybe (canonicalizePath (sdkSourceDirectory</>"../..")) pure bundle
  defaultRestic<-maybe (findExecutable "restic") (pure . Just . (</>"bin/restic")) bundle
  restic<-case defaultRestic of
    Just file->makeAbsolute file
    Nothing->prompt "Reviewed restic executable path (not found on PATH)" "" $ \input->do
      file<-makeAbsolute input
      exists<-doesFileExist file
      require exists "restic_executable_file_required"
      pure file
  (key,owner)<-prepareWallet directory "automatic"
  (phraseFile,_)<-prepareSeed directory "ecx" "automatic"
  let unlock=takeDirectory phraseFile</>"native-unlock"
  unlocked<-doesFileExist unlock
  if unlocked then verifyNativeUnlock unlock else do
    unlockBytes<-getRandomBytes 32
    savePrivate unlock (B8.pack $ T.unpack $ base58 unlockBytes)
  setupSdk<-SetupPaths.sdkPath
  ata<-TokenOp.runSafe (TokenOp.Request $ Token.AssociatedAddress setupSdk owner Bootstrap.canonicalMint)
  let defaults=M.union (M.fromList
        ["profile" .= String "CanonicalBeta","deploymentId" .= String ("ecx-"<>T.take 16 owner)
        ,"nativeWallet" .= String ("ecx-bridge-"<>T.take 16 owner),"backupRequired" .= Bool True
        ,"mint" .= String Bootstrap.canonicalMint,"custodyOwner" .= String owner,"custodyAta" .= String ata
        ,"solanaRpc" .= primary,"solanaVerifierRpc" .= verifier
        ,"nativeCookie" .= worker,"nativeUnlockFile" .= unlock
        ,"solanaHistoryStart" .= String "","solanaOperatingHistoryStart" .= String ""]) template
      setup=object ["existing" .= False,"method" .= String (maybe "source" (const "bundle") bundle),"sourceRoot" .= root,"restic" .= restic
        ,"nodeConfig" .= nodeConfig,"nodeService" .= nodeService,"managedNode" .= True
        ,"nativeSeedFile" .= phraseFile,"nativeAdminAuth" .= admin,"nativeRestore" .= False,"nativeRangeEnd" .= (999::Int)]
      sources=object [K.fromString name .= path | (name,path)<-
        [("solana.keypair.json",key),("native-worker.auth",worker),("native-signer.auth",signer)
        ,("native-unlock",unlock),("backup.repository",repository),("backup.password",password)]<>tls]
  mapM_ (\(name,value)->savePrivate (directory</>name) (L.toStrict $ encode value))
    [("setup.json",setup),("sources.json",sources),("bootstrap.json",Object defaults)
    ,("interface.json",Bootstrap.interface origin)]
  putStrLn "Saved private setup. Runtime configuration is published only after verified funding/history."
  putStrLn "Defaults: local ECX RPC http://127.0.0.1:28532; PostgreSQL and services installed automatically."
  putStrLn "Order range: 0.00010000–0.00100000 ECX; 4 queued orders; 1 native confirmation."
  putStrLn "Per-transaction caps: 1,000 native base units, 10,000 lamports fee, 2,100,000 lamports rent."
  putStrLn "Daily cost caps: 10,000 native base units and 10,000,000 lamports. Review before funding."
  putStrLn "Advanced values are in .ecx-bridge/bootstrap.json; never edit identity after bootstrap starts."
  putStrLn "Next: sudo ecx-bridge start. It prints funding instructions and resumes safely on rerun."
 where
  privateFile input=do
    require (not $ null input) "file_path_required"
    file<-makeAbsolute input
    bytes<-readPrivate file
    require (not $ B.null bytes) "empty_private_file"
    pure file
  rpcInput input=do
    require (not $ null input) "rpc_url_required"
    url<-if "https://" `isPrefixOf` input then pure input else B8.unpack . B8.strip <$> (makeAbsolute input >>= readPrivate)
    require ("https://" `isPrefixOf` url && not(any (`elem` ['\r','\n',' ']) url)) "solana_requires_https"
    _<-parseRequest url
    pure url

configureAdvanced :: IO ()
configureAdvanced=do
  protectWalletProcess
  putStrLn "For fresh Ubuntu installation, run configure and start with sudo; source secret files must be root-owned and private."
  putStrLn "Prepare NEW installation material. Existing deployments must use recovery/upgrade."
  putStrLn "No network calls, database changes or payments. Wallet generation is offline. Amounts are base units."
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
  walletMode<-prompt "Solana custody wallet: generate / import / restore" "generate" $ \s->do
    require (s `elem` ["generate","import","restore"]) "choose_generate_import_or_restore"
    pure s
  generated<-if walletMode=="import" then pure Nothing else Just <$> prepareWallet directory walletMode
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
  let walletDefaults=case generated of
        Nothing->defaults
        Just (_,owner)->replace "custodyOwner" (String owner) defaults
  config<-collect (if walletMode=="import" then [] else ["custodyOwner"]) walletDefaults
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
  key<-case generated of
    Just (file,_)->verifySigningKey (C.custodyOwner config) file >> pure file
    Nothing->prompt "Existing custody Solana JSON keypair FILE (private; never type the key here)" "" $ \path->do
      file<-makeAbsolute path
      verifySigningKey (C.custodyOwner config) file
      pure file
  nativeMode<-prompt "ECX wallet: existing / generate / restore" "existing" $ \s->do
    require (s `elem` ["existing","generate","restore"]) "choose_existing_generate_or_restore"
    pure s
  nativeSetup<-if nativeMode=="existing" then pure [] else do
    (phraseFile,phrase)<-prepareSeed directory "ecx" nativeMode
    _<-nativeDescriptors signet phrase >>= either reject pure
    putStrLn $ "ECX recovery path: m/84'/"<>(if signet then "1" else "0")<>"'/0'/0/* (receive), /1/* (change); empty BIP-39 passphrase."
    rangeEnd<-if nativeMode=="restore" then prompt "ECX recovery highest address index (cover ALL previously used receiving/change indexes)" "999" (\input->case readMaybe input of
      Just n | n>=999 && n<=1000000->pure (n::Int)
      _->reject "enter_recovery_index_999_to_1000000") else pure (999::Int)
    admin<-credential "Private native NODE ADMIN credential FILE (for one-time wallet creation/import only)"
    pure ["nativeSeedFile" .= phraseFile,"nativeAdminAuth" .= admin,"nativeRestore" .= (nativeMode=="restore"),"nativeRangeEnd" .= rangeEnd]
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
  let setupWithNative=case setup of Object values->Object (M.union (M.fromList (nativeSetup<>["restoredCustody" .= True | walletMode=="restore" || nativeMode=="restore"])) values); _->setup
      worker=config {C.nativeCookie=workerAuth,C.nativeUnlockFile=Nothing}
      signer=config {C.nativeCookie=signerAuth,C.nativeUnlockFile=if null unlock then Nothing else Just unlock}
      sources=[("solana.keypair.json",key),("native-worker.auth",workerAuth),("native-signer.auth",signerAuth)]
        <>[("native-unlock",unlock) | not(null unlock)]<>backups<>tlsFiles
      records=[("setup.json",L.toStrict $ encode setupWithNative),("sources.json",L.toStrict $ encode $ object [K.fromString name .= path | (name,path)<-sources])
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

-- Keep generated wallet files separate: cancelling settings must not erase a
-- wallet whose address the operator may already have funded. No secret on stdout.
prepareWallet :: FilePath -> String -> IO (FilePath,T.Text)
prepareWallet directory mode=do
  (phraseFile,phrase)<-prepareSeed directory "solana" mode
  bytes<-either reject pure (walletKey phrase)
  let key=takeDirectory phraseFile</>"solana.keypair.json"
      owner=base58 (B.drop 32 bytes)
  existing<-doesFileExist key
  let encoded=L.toStrict $ encode $ B.unpack bytes
  if existing then readPrivate key >>= \saved->require (saved==encoded) "generated_wallet_key_changed"
    else savePrivate key encoded
  putStrLn $ "Solana custody owner / SOL funding address: "<>T.unpack owner
  putStrLn $ "Recovery derivation: "<>derivationPath
  when (mode/="automatic") $ putStrLn "The custodyAta and history fields must describe this NEW wallet and its configured mint."
  pure (key,owner)

prepareSeed :: FilePath -> String -> String -> IO (FilePath,String)
prepareSeed directory asset mode=do
  when (mode/="restore") $ do
    terminal<-hIsTerminalDevice stdin
    require terminal "wallet_generation_requires_interactive_terminal"
  recovery<-if mode=="restore" then Just <$> prompt "Path to private 12-word recovery phrase file" "" (\path->do
    file<-makeAbsolute path
    phrase<-B8.unpack . B8.strip <$> readPrivate file
    _<-either reject pure (walletKey phrase)
    pure phrase) else pure Nothing
  settingsRoot<-canonicalizePath directory
  let choose=if mode=="automatic" then (\_ fallback check->check fallback) else prompt
  output<-choose "NEW private wallet directory (preserved if configuration is cancelled)" (directory<>"-"<>asset<>"-wallet") $ \path->do
    file<-makeAbsolute path >>= canonicalizePath
    require (file/=settingsRoot && not(addTrailingPathSeparator settingsRoot `isPrefixOf` file)) "wallet_directory_must_be_outside_settings"
    exists<-doesDirectoryExist file
    if exists && mode=="automatic" then privateParent(file</>"state") else P.createDirectory file 0o700
    pure file
  let phraseFile=output</>asset<>"-recovery.txt"
  saved<-doesFileExist phraseFile
  phrase<-if saved && mode=="automatic" then do
    value<-B8.unpack . B8.strip <$> readPrivate phraseFile
    _<-either reject pure (walletKey value)
    pure value
   else case recovery of
    Just value->pure value
    Nothing->getRandomBytes 16 >>= either reject pure . mnemonic
  when (not saved) $ savePrivate phraseFile (B8.pack $ phrase<>"\n")
  putStrLn $ "Recovery file saved privately in "<>output<>". Preserve it even if setup is cancelled."
  when (mode/="restore") $ withFile "/dev/tty" ReadWriteMode $ \terminal->do
    hPutStrLn terminal $ "Write down these 12 "<>asset<>" recovery words in order. Anyone with them can spend this wallet's funds:"
    hPutStrLn terminal phrase
    let acknowledge=do
          hPutStrLn terminal "Type saved once you have backed up the phrase:"
          hFlush terminal
          answer<-hGetLine terminal
          if answer=="saved" then pure () else acknowledge
    -- Clear both visible text and saved scrollback on supporting terminals.
    -- Also clear on an interrupted acknowledgement; never send this to stdout.
    acknowledge `finally` (hPutStr terminal "\ESC[2J\ESC[3J\ESC[H" >> hFlush terminal)
  putStrLn "Recovery phrases do not recover the bridge ledger or in-flight obligations."
  pure (phraseFile,phrase)

-- Closed setup action, never a customer/worker API. Root's one-time admin
-- credential is not copied to either service. Mutations are not retried.
initializeNative :: FilePath -> IO ()
initializeNative path=do
  protectWalletProcess
  directory<-makeAbsolute path
  bytes<-readPrivate (directory</>"setup.json")
  value<-either (const $ reject "invalid_setup_json") pure (eitherDecodeStrict' bytes)
  seed<-either (const $ reject "invalid_setup_json") pure (parseEither (withObject "setup" (.:? "nativeSeedFile")) value)
  forM_ seed $ \phraseFile->do
    admin<-field "nativeAdminAuth" value
    restoring<-field "nativeRestore" value
    rangeEnd<-field "nativeRangeEnd" value
    _<-readPrivate admin
    config<-Bootstrap.setupConfig directory
    let native=(C.nativeSettings config) {N.nativeCookie=admin}
    putStrLn "Initializing/checking the ECX descriptor wallet; recovery may require a full blockchain rescan."
    let managerSettings=managerSetProxy noProxy defaultManagerSettings
          {managerResponseTimeout=responseTimeoutNone,managerRetryableException=const False}
    address<-bracket (newManager managerSettings) closeManager $ \manager->N.evalNativeRecoveryWith (N.nativeCall manager native) native
      (N.InitializeNativeWallet phraseFile (C.nativeUnlockFile config) restoring rangeEnd)
    putStrLn $ "ECX wallet ready. Funding address: "<>T.unpack address
 where
  field name value=either (const $ reject "invalid_setup_json") pure (parseEither (withObject "setup" (.:name)) value)

-- Reuse the full runtime validator; cross-field errors allow editing the collected answers.
collect :: [K.Key] -> Object -> IO C.Config
collect locked initial=do
  fields<-foldM ask initial [k | k<-sort (M.keys initial),k `notElem` fixed]
  case fromJSON (Object fields) of
    Error _->putStrLn "Invalid field type or amount; correct the settings." >> collect locked fields
    Success c->(C.validateConfig c >> pure c) `catch` (\(BridgeError code)->do
      putStrLn $ "Please correct settings: "<>T.unpack code
      collect locked fields) `catch` (\(_::HttpException)->putStrLn "Invalid RPC URL; correct the endpoint fields." >> collect locked fields)
 where
  fixed=locked<>["profile","nativeCookie","nativeUnlockFile","signerAuthFile","fenceDirectory","solanaSdkLibrary"]
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
  directory<-makeAbsolute path
  withFamily (directory</>"start") (startUnlocked directory)

startUnlocked :: FilePath -> IO ()
startUnlocked path=do
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
    restored<-either (const $ reject "invalid_setup_json") pure
      (parseEither (withObject "setup" (\o->o .:? "restoredCustody" .!= False)) value)
    require (not restored) "phrase_restore_requires_ledger_recovery_not_fresh_install"
    method<-either (const $ reject "invalid_setup_method") pure
      (parseEither (withObject "setup" (\o->o .:? "method" .!= ("release"::String))) value)
    -- Old setup files retain signed-release verification; never silently downgrade.
    require (uid==0) "fresh_install_run_sudo_ecx_bridge_configure_then_sudo_ecx_bridge_start"
    residual<-doesFileExist config
    require (not residual) "installed_material_exists_use_recovery_not_fresh"
    when (method=="bundle") $ do
      root<-field "sourceRoot" value
      (verified,_,_)<-readCreateProcessWithExitCode ((proc "sha256sum" ["--check","--status","manifest.sha256"]) {cwd=Just root}) ""
      require (verified==ExitSuccess) "installed_setup_bundle_changed"
    Bootstrap.bind directory
    Bootstrap.initializeBackup directory
    NodeSetup.provision directory
    initializeNative directory
    Bootstrap.complete directory
    case method of
      "source"->do
        root<-field "sourceRoot" value
        restic<-field "restic" value
        binaryPath<-getExecutablePath
        execute "/bin/sh" [root</>"2-Wrap-Unwrap-Server/install/source",binaryPath,sdkLibraryPath,browserAssetsDirectory,restic,directory]
      "bundle"->do
        root<-field "sourceRoot" value
        execute "/bin/sh" [root</>"install","fresh",directory]
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
