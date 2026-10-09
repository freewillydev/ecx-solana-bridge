{-# LANGUAGE ScopedTypeVariables #-}
-- Console orchestration only. Financial reads/writes use the existing closed
-- operator transport; keys, chain RPC, SQL and signer clients never enter here.
module Menu (launch) where

import qualified Configure
import qualified Bootstrap
import qualified SetupPaths
import qualified Bridge.Config as C
import Bridge.AdminKey (readPrivate,privateParent)
import Bridge.Domain (Asset(..),Amount,parseCoins,renderCoins,units)
import Bridge.Error
import qualified Bridge.Wire as W
import Control.Exception (catch,IOException)
import Control.Monad (when,unless,forM_)
import Data.Aeson
import Data.Int (Int64)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.Text as T
import System.Directory
import System.Environment (getExecutablePath)
import System.Exit (ExitCode(..))
import System.FilePath ((</>),takeDirectory,isAbsolute)
import System.Info (os)
import System.IO (stdin,stdout,hIsTerminalDevice,hFlush,isEOF)
import qualified System.Posix.Directory as P
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

workerConfig,installedBinary,defaultSetup,pointer,pending :: FilePath
workerConfig="/etc/ecx-bridge/worker/config.json"
installedBinary="/opt/ecx-bridge/current/bin/ecx-bridge"
defaultSetup="/var/lib/ecx-bridge-setup/.ecx-bridge"
pointer="/var/lib/ecx-bridge-setup/installed-directory.json"
pending="/var/lib/ecx-bridge-upgrade/pending"

launch :: IO ()
launch=do
  require (os=="linux") "setup_requires_ubuntu_24_04"
  getEffectiveUserID >>= \uid->require (uid==0) "run_sudo_ecx_bridge"
  hIsTerminalDevice stdin >>= flip require "interactive_menu_requires_terminal"
  loop
 where
  loop=do
    installed<-doesDirectoryExist "/etc/ecx-bridge"
    upgrading<-doesFileExist pending
    found<-(Right <$> discover) `catch` (\(_::BridgeError)->pure $ Left ())
      `catch` (\(_::IOException)->pure $ Left ())
    let setup=either (const Nothing) id found
        discoveryOK=case found of Right _->True; _->False
    unless discoveryOK $ putStrLn "Saved setup location needs repair. Status and Exit remain available; no setup or upgrade will be started."
    configured<-maybe (pure False) (doesFileExist . (</>"setup.json")) setup
    putStrLn "\nECX Bridge — 1% each way"
    putStrLn $ if upgrading then "Upgrade unfinished. Continue uses its saved, verified plan."
      else if installed then "Existing custody detected. Wallets and ledger will be retained."
      else if configured then "Setup saved. Continue checks funding, node and backup readiness."
      else "New or interrupted setup. Accepted answers are saved privately."
    putStrLn $ "1. "<>(if installed || configured || upgrading then "Continue setup / start safely" else "Set up this server")
    putStrLn "2. Status\n3. Funding and treasury allocation\n4. Upgrade\n5. Backup and recovery"
    when installed $ putStrLn "6. Pause orders"
    putStrLn "0. Exit"
    choice<-ask "Choose" "0"
    case choice of
      Nothing->pure ()
      Just "0"->pure ()
      Just number->do
        handle $ case number of
          "1"->do
            require discoveryOK "saved_setup_location_requires_review"
            if installed || configured || upgrading
              then existing setup >>= continue
              else confirm "Generate or resume this server's wallets and private setup?" $ do
                homeExists<-doesDirectoryExist(takeDirectory defaultSetup)
                unless homeExists $ P.createDirectory (takeDirectory defaultSetup) 0o700
                privateParent (takeDirectory defaultSetup</>"state")
                withCurrentDirectory (takeDirectory defaultSetup) Configure.configure
                putStrLn "Setup saved. Choose Continue when ready; funding details are under 3."
          "2"->status
          "3"->if not discoveryOK then reject "saved_setup_location_requires_review"
            else if not installed && not configured then putStrLn "Complete Set up this server first. No funding address has been created yet."
            else funding setup installed
          "4"->if installed then do
              require discoveryOK "saved_setup_location_requires_review"
              bundle<-SetupPaths.bundleRoot
              current<-canonicalizePath "/opt/ecx-bridge/current"
              putStrLn $ "Installed release: "<>current
              putStrLn $ "Candidate release: "<>maybe "source build (no release package)" id bundle
              same<-maybe (pure True) (\path->(==) <$> B.readFile(path</>"manifest.sha256") <*> B.readFile(current</>"manifest.sha256")) bundle
              if not upgrading && same
                then putStrLn "No new release selected. Run the reviewed new installer and choose Upgrade; use Continue to resume this version."
                else existing setup >>= continue
            else putStrLn "Complete initial setup before upgrading."
          "5"->recovery
          "6" | installed->confirm "Pause new orders and payouts for operator review?" $ do
            _<-operator(object ["operation" .= String "pause","reason" .= String "operator menu review"]) :: IO Value
            putStrLn "Orders paused. Choose Continue only when ready for checked resume."
          _->putStrLn "Choose a number shown above. Nothing was changed."
        loop
  continue directory=confirm "Continue the checked setup/upgrade and resume orders and saved payments when ready?" (Configure.start directory)

-- A missing installed pointer never turns existing custody into a fresh setup.
discover :: IO (Maybe FilePath)
discover=do
  upgrading<-doesFileExist pending
  saved<-doesFileExist pointer
  ordinary<-doesDirectoryExist defaultSetup
  if upgrading then do
    record<-jsonFile pending
    path<-either (const $ reject "invalid_upgrade_journal") pure $ parseEither (withObject "upgrade" (.: "setupDirectory")) record
    pure(Just path)
  else if saved then do
    directory<-jsonFile pointer
    require (isAbsolute directory) "invalid_saved_setup_directory"
    _<-readPrivate(directory</>"setup.json")
    pure(Just directory)
  else pure(if ordinary then Just defaultSetup else Nothing)

existing :: Maybe FilePath -> IO FilePath
existing selected=do
  directory<-case selected of
    Just path->pure path
    Nothing->do
      putStrLn "Existing services have no registered setup folder. Locate the original private folder containing setup.json and worker.json; do not create new wallets."
      required "Original setup directory path" >>= makeAbsolute
  require (isAbsolute directory) "absolute_setup_directory_required"
  _<-readPrivate(directory</>"setup.json")
  pure directory

ask :: String -> String -> IO (Maybe String)
ask label fallback=do
  putStr $ label<>(if null fallback then "" else " ["<>fallback<>"]")<>": "
  hFlush stdout
  end<-isEOF
  if end then pure Nothing else do
    answer<-T.unpack . T.strip . T.pack <$> getLine
    pure $ Just(if null answer then fallback else answer)

required :: String -> IO String
required label=ask label "" >>= \answer->case answer of
  Nothing->reject "menu_cancelled"
  Just ""->putStrLn "Please enter a value, or press Ctrl-D to return." >> required label
  Just value->pure value

confirm :: String -> IO () -> IO ()
confirm preview action=do
  putStrLn preview
  answer<-ask "Type yes to continue" "no"
  if answer==Just "yes" then action else putStrLn "Cancelled."

handle :: IO () -> IO ()
handle action=action `catch` (\(BridgeError code)->do
    when (code `elem` ["rpc_method_forbidden","rpc_required_history_unavailable","rpc_error_-32002"]) $
      putStrLn "This RPC plan does not provide required transaction history. Use a provider/plan supporting getSignaturesForAddress and getTransaction; free tiers differ."
    when (code `elem` ["rpc_rate_limited","rpc_preflight_timeout"]) $
      putStrLn "RPC capacity or response time is insufficient right now. Saved setup is retained; check your provider allowance before retrying."
    putStrLn $ "Not completed: "<>T.unpack code<>". Saved progress is retained; check Status before retrying.")
  `catch` (\(_::IOException)->putStrLn "Could not access the service or private file. Check Status and file permissions; no automatic retry was made.")

jsonFile :: FromJSON a => FilePath -> IO a
jsonFile file=readPrivate file >>= either (const $ reject "invalid_private_json") pure . eitherDecodeStrict'

operator :: FromJSON a => Value -> IO a
operator request=do
  (code,out,err)<-readProcessWithExitCode "runuser" ["-u","ecxbridgew","--",installedBinary,"operator",workerConfig] (L.unpack $ encode request)
  unless (code==ExitSuccess) $ case eitherDecode (L.pack err) of
    Right (Object fields) | Just (String reason)<-KM.lookup "error" fields->reject reason
    _->reject "operator_unavailable_or_refused_check_status"
  either (const $ reject "invalid_operator_reply") pure (eitherDecode $ L.pack out)

status :: IO ()
status=do
  forM_ ["ecx-betanet","postgresql","ecx-bridge-worker","ecx-bridge-signer"] $ \service->do
    (_,out,_)<-readProcessWithExitCode "systemctl" ["is-active",service] ""
    putStrLn $ service<>": "<>T.unpack(T.strip $ T.pack out)
  configured<-doesFileExist workerConfig
  when configured $ do
    state<-operator (object ["operation" .= String "status"]) :: IO W.ServiceStatus
    putStrLn $ "Orders: "<>(if W.paused state then "paused — "<>T.unpack(W.pauseReason state) else "enabled")
    putStrLn $ "Ledger sequence: "<>show(W.criticalSequence state)<>"; backup coverage: "<>show(W.backupSequence state)
    putStrLn "Coverage does not prove the backup destination is currently reachable."

funding :: Maybe FilePath -> Bool -> IO ()
funding setup installed=do
  runtime<-doesFileExist workerConfig
  c<-if runtime then C.loadConfig workerConfig else existing setup >>= Bootstrap.setupConfig
  putStrLn $ "Network: "<>(case C.profile c of W.CanonicalBeta->"ECX betanet / Solana Mainnet"; W.ECXBetanetDevnet->"ECX betanet / Solana Devnet"; W.L2LSignetDevnet->"L2L Signet / Solana Devnet")
  putStrLn $ "Wrapped token mint: "<>T.unpack(C.mint c)
  putStrLn $ "SOL / wrapped ECX recipient owner: "<>T.unpack(C.custodyOwner c)
  putStrLn $ "Wrapped token account (ATA): "<>T.unpack(C.custodyAta c)
  putStrLn "Use a dedicated funding wallet. SOL pays network costs; wrapped ECX supplies swap inventory."
  forM_ setup $ \directory->do
    record<-jsonFile(directory</>"setup.json")
    phrase<-either (const $ reject "invalid_setup_json") pure $ parseEither (withObject "setup" (.:? "nativeSeedFile")) record
    forM_ phrase $ \file->do
      ready<-doesFileExist(file<>".initialized.json")
      if not ready then putStrLn "ECX address will appear after Continue initializes the real node wallet."
      else do
        saved<-jsonFile(file<>".initialized.json")
        address<-either (const $ reject "invalid_native_initialization") pure $ parseEither (withObject "native initialization" $ \o->do
          wallet<-o .: "wallet"; profile<-o .: "profile"
          unless (wallet==C.nativeWallet c && profile==C.profile c) (fail "wrong wallet")
          o .: "address") saved
        putStrLn $ "ECX funding address: "<>(address::String)
  when (installed && runtime) $ do
    putStrLn "Deposits must be independently verified and operator-owned before allocation. Allocation moves ledger capital; it does not transfer coins."
    answer<-ask "Review verified unallocated receipts now? yes/no" "no"
    when (answer==Just "yes") allocate

allocate :: IO ()
allocate=do
  receipts<-operator(object ["operation" .= String "treasury-receipts"]) :: IO [(T.Text,Asset,Amount)]
  forM_ (zip [1::Int ..] receipts) $ \(n,(identifier,asset,quantity))->
    putStrLn $ show n<>". "<>show asset<>" "<>(if asset==Sol then show(units quantity)<>" lamports" else T.unpack(renderCoins quantity)<>" coins")<>" — "<>T.unpack identifier
  if null receipts then putStrLn "No eligible unallocated receipts. Continue observation and check again after confirmation."
  else do
    selection<-ask "Receipt number (0 cancels)" "0"
    case selection >>= readMaybe of
      Just n | n>0 && n<=length receipts->do
        let (identifier,asset,quantity)=receipts!!(n-1)
        operating<-if asset==Sol then pure quantity else if asset==Wrapped then pureAmount "0" else do
          input<-required "ECX amount reserved for network fees (remaining amount becomes swap inventory)"
          value<-pureAmount input
          require (value<=quantity) "allocation_exceeds_receipt"
          pure value
        let inventory=units quantity-units operating
            split=filter ((/=String "0").snd)
              [("operating"::T.Text,String $ T.pack $ show $ units operating),("float",String $ T.pack $ show inventory)]
        reason<-required "Ownership attestation: explain why this deposit belongs to you, not a customer"
        confirm ("Allocate "<>show asset<>" receipt "<>T.unpack identifier<>" exactly as "<>show split<>"? Orders must already be paused.") $ do
          sequenceNo<-operator(object ["operation" .= String "allocate-treasury","deposit" .= identifier,"split" .= split,"reason" .= reason]) :: IO Integer
          putStrLn $ "Allocation recorded at sequence "<>show sequenceNo<>". Choose Continue for checked reconciliation/resume."
      Just 0->pure ()
      _->putStrLn "Invalid receipt selection. Nothing was changed."
 where pureAmount text=either reject pure (parseCoins $ T.pack text)

recovery :: IO ()
recovery=do
  putStrLn "1. Backup coverage/status\n2. Verify a custody backup\n3. Download and verify a specific backup\n4. Full server restoration requirements\n0. Back"
  selection<-ask "Choose" "0"
  case selection of
    Just "1"->status
    Just action | action `elem` ["2","3"]->do
      config<-required "Existing deployment configuration file path (same custody identity)"
      minimumSequence<-required "Independently retained minimum ledger sequence (never guess)"
      require (maybe False (>=0) (readMaybe minimumSequence :: Maybe Int64)) "invalid_restore_policy"
      args<-if action=="2" then do
        manifest<-required "Custody manifest file path"
        pure ["check-custody",config,manifest,minimumSequence]
      else do
        backup<-required "Private backup configuration file path"
        snapshot<-required "Exact backup snapshot ID"
        require (length snapshot==64 && all (`elem` ("0123456789abcdef"::String)) snapshot) "invalid_snapshot_id"
        directory<-required "NEW private destination directory path"
        require (isAbsolute directory) "absolute_restore_directory_required"
        exists<-doesPathExist directory
        require (not exists) "restore_destination_exists"
        pure ["recover-custody",config,backup,snapshot,directory,minimumSequence]
      confirm "Verify/download only. This does not replace a database, activate a wallet, adopt a fence or resume transfers." $ do
        executable<-getExecutablePath
        (code,out,_)<-readProcessWithExitCode executable args ""
        require (code==ExitSuccess) "backup_recovery_refused_check_identity_access_and_minimum_sequence"
        putStr out
    Just "4"->putStrLn "Full restoration requires a verified custody backup and trusted minimum sequence, exclusion of the old signer, restoration into a new database/native wallet, host-fence adoption, credentials and fresh independent reconciliation. This menu does not activate recovered custody. Follow docs/OPERATIONS.md on the reviewed release with your recovery operator; wallet seeds alone cannot reconstruct pending transfers."
    _->pure ()
