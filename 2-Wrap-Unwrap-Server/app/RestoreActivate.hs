-- Explicit activation of a verified staged recovery. No fresh ledger or wallet.
module RestoreActivate (activate) where
import qualified RestoreGuide as R
import qualified Bridge.Config as C
import qualified Bridge.Wire as W
import Bridge.AdminKey (readPrivate,savePrivate,privateParent,withFamily)
import Bridge.Error
import Bridge.Identity (digest)
import qualified NodeSetup
import qualified SetupPaths
import qualified Upgrade
import Control.Monad (unless,when,forM_)
import Control.Exception (onException,bracket)
import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import Data.Int (Int64)
import System.Directory
import System.Environment (getExecutablePath)
import System.FilePath ((</>),takeDirectory)
import System.Exit (ExitCode(..))
import qualified System.Posix.Directory as P
import System.Posix.IO hiding (sync)
import System.Posix.Unistd (fileSynchronise)
import System.Process (readProcessWithExitCode)

root,material,binary,worker :: FilePath
root="/var/lib/ecx-bridge-restore"
material=root</>"setup"
binary="/opt/ecx-bridge/current/bin/ecx-bridge"
worker="/etc/ecx-bridge/worker/config.json"

activate :: IO ()
activate=withFamily "/var/lib/ecx-bridge-upgrade/lifecycle" $ do
  privateParent(root</>"pending")
  pending<-doesFileExist(root</>"pending")
  require pending "no_pending_restoration"
  plan<-json(root</>"pending") :: IO R.Plan
  c<-C.loadConfig(R.config plan)
  readPrivate(R.config plan) >>= \b->require (digest b==R.configHash plan && C.fingerprint c==R.identity plan) "restore_configuration_changed"
  readPrivate(R.manifest plan) >>= \b->require (digest b==R.manifestHash plan) "restore_manifest_changed"
  result<-json(root</>"ledger.completed") :: IO Value
  database<-field "database" result :: IO String
  sequenceNo<-field "criticalSequence" result :: IO Int64
  paused<-field "paused" result
  require (paused && sequenceNo>=R.minimumSequence plan) "invalid_staged_ledger"
  wallet<-json(root</>"native-wallet.completed") >>= field "wallet"
  require (wallet==C.nativeWallet c) "restore_wallet_result_mismatch"
  bundle<-SetupPaths.bundleRoot >>= maybe (reject "reviewed_release_required_for_recovery") pure
  release<-Upgrade.verifyBundle bundle
  putStrLn "Activate this recovered server only after the old signer is permanently excluded. Wallet keys copied to another host remain capable of spending."
  answer<-R.prompt "Type SOURCE EXCLUDED to confirm old-host retirement and begin checked activation"
  require (answer=="SOURCE EXCLUDED") "restore_activation_cancelled"
  mark "source-excluded" (L.toStrict $ encode $ object ["identity" .= R.identity plan,"sequence" .= sequenceNo])
  mark "activation-release" (B8.pack $ T.unpack release)
  attempted<-doesFileExist(root</>"activation.started")
  when attempted $ do
    installedConfig<-C.loadConfig worker
    require (C.fingerprint installedConfig==R.identity plan) "recovery_active_identity_changed"
    mark "services.blocked" "restore\n"
    checked "systemctl" ["stop","ecx-bridge-worker","ecx-bridge-signer"]
  forM_ ["ecx-bridge-worker","ecx-bridge-signer"] $ \service->do
    (code,out,_)<-readProcessWithExitCode "systemctl" ["show",service,"--property=MainPID,ActiveState,LoadState"] ""
    require (code==ExitSuccess && ("LoadState=not-found" `elem` lines out || ("MainPID=0" `elem` lines out && any (`elem` lines out) ["ActiveState=inactive","ActiveState=failed"]))) "stop_custody_before_recovery_activation"
  executable<-getExecutablePath
  checked executable ["check-custody",R.config plan,R.manifest plan,show sequenceNo]
  mark "services.blocked" "restore\n"
  ready<-doesFileExist(material</>"ready")
  unless ready $ prepare bundle plan c
  -- The installer verifies the recovery journal and exact paused database before
  -- grants/adoption; it never invokes InitializeLedger in recover mode.
  checked "/bin/sh" [bundle</>"install","recover",material]
  installed<-C.loadConfig worker
  require (C.fingerprint installed==R.identity plan) "restored_install_identity_mismatch"
  selected<-B8.unpack . B8.strip <$> readPrivate "/var/lib/ecx-bridge-install/database"
  require (selected==database) "restored_install_database_mismatch"
  -- Add only this verified wallet to the managed node's reboot configuration.
  autoloaded<-doesFileExist(root</>"native-autoload.completed")
  unless autoloaded $ do
    NodeSetup.persistRestoredWallet (C.nativeWallet c)
    mark "native-autoload.completed" (L.toStrict $ encode $ C.nativeWallet c)
  checked "systemctl" ["unmask","ecx-bridge-worker","ecx-bridge-signer"]
  let registry="/var/lib/ecx-bridge-setup"
  exists<-doesDirectoryExist registry
  unless exists $ P.createDirectory registry 0o700
  saved<-doesFileExist(registry</>"installed-directory.json")
  if saved then json(registry</>"installed-directory.json") >>= \path->require (path==material) "installed_setup_registry_conflict"
    else savePrivate(registry</>"installed-directory.json") (L.toStrict $ encode material)
  mark "activation.started" (L.toStrict $ encode $ object ["identity" .= R.identity plan,"database" .= database])
  removeFile(root</>"services.blocked")
  sync root
  let stop=do
        mark "services.blocked" "restore\n"
        _<-readProcessWithExitCode "systemctl" ["stop","ecx-bridge-worker","ecx-bridge-signer"] ""
        pure ()
  (do
    checked "systemctl" ["daemon-reload"]
    checked "systemctl" ["start","ecx-bridge-signer","ecx-bridge-worker"]
    waitStatus 120
    -- Existing closed resume operation performs the real-chain reconciliation,
    -- saved-attempt and durability gates. Refusal keeps this recovery pending.
    reply<-operator "{\"operation\":\"resume\"}"
    require (reply==ExitSuccess) "restored_readiness_refused_check_status"
    state<-status
    require (not $ W.paused state) "restored_server_still_paused"
    mark "activation.completed" (L.toStrict $ encode $ object ["identity" .= R.identity plan,"database" .= database,"minimumSequence" .= sequenceNo])
    checked "systemctl" ["enable","ecx-bridge-worker","ecx-bridge-signer"]
    renameFile(root</>"pending") (root</>"completed-plan")
    sync root
    putStrLn "Recovery complete: restored custody is running and checked resume passed. Keep this recovery journal and independent backups."
    ) `onException` stop
 where
  waitStatus 0=reject "restored_worker_startup_timeout"
  waitStatus remaining=do
    code<-operator "{\"operation\":\"status\"}"
    if code==ExitSuccess then pure () else threadDelay 500000 >> waitStatus (remaining-1)

prepare :: FilePath -> R.Plan -> C.Config -> IO ()
prepare bundle plan c=do
  exists<-doesDirectoryExist material
  unless exists $ P.createDirectory material 0o700
  privateParent(material</>"setup.json")
  repository<-R.prompt "Private file path containing HTTPS backup repository URL"
  password<-R.prompt "Private file path containing its encryption password"
  _<-readPrivate repository; _<-readPrivate password
  -- Fresh restricted RPC credentials are generated; restored private keys are
  -- referenced, never regenerated or placed in prompts/logs.
  (admin,workerAuth,signerAuth)<-NodeSetup.credentials material
  let source=takeDirectory(R.manifest plan)
      configured=c {C.nativeCookie=admin}
  save "worker.json" (toJSON configured)
  save "signer.json" (toJSON configured)
  save "interface.json" (toJSON $ C.defaultInterface (C.profile c))
  encrypted<-doesFileExist(source</>"native-unlock")
  save "sources.json" $ object $ ["solana.keypair.json" .= (source</>"solana-key.json")
    ,"native-worker.auth" .= workerAuth,"native-signer.auth" .= signerAuth
    ,"backup.repository" .= repository,"backup.password" .= password]
    <>["native-unlock" .= (source</>"native-unlock") | encrypted]
  save "setup.json" $ object ["existing" .= True,"restoredCustody" .= True,"method" .= String "bundle"
    ,"sourceRoot" .= bundle,"managedNode" .= False,"nodeConfig" .= String "/var/lib/ecx-betanet/bitcoin.conf"
    ,"nodeService" .= String "ecx-betanet.service"]
  NodeSetup.provision material
  save "ready" (Bool True)
 where
  save name value=do
    let path=material</>name; bytes=L.toStrict $ encode value
    exists<-doesFileExist path
    if exists then readPrivate path >>= \old->require (old==bytes) "recovery_material_changed"
      else savePrivate path bytes

operator :: String -> IO ExitCode
operator request=do
  (code,_,_)<-readProcessWithExitCode "runuser" ["-u","ecxbridgew","--",binary,"operator",worker] request
  pure code
status :: IO W.ServiceStatus
status=do
  (code,out,_)<-readProcessWithExitCode "runuser" ["-u","ecxbridgew","--",binary,"operator",worker] "{\"operation\":\"status\"}"
  require (code==ExitSuccess) "restored_status_unavailable"
  either (const $ reject "invalid_restored_status") pure (eitherDecodeStrict' $ B8.pack out)
checked :: FilePath -> [String] -> IO ()
checked program arguments=do
  (code,_,_)<-readProcessWithExitCode program arguments ""
  require (code==ExitSuccess) "recovery_activation_step_failed_state_retained"
mark :: FilePath -> B.ByteString -> IO ()
mark name bytes=do
  exists<-doesFileExist(root</>name)
  if exists then readPrivate(root</>name) >>= \old->require (old==bytes) "recovery_activation_record_changed"
    else savePrivate(root</>name) bytes
json :: FromJSON a => FilePath -> IO a
json path=readPrivate path >>= either (const $ reject "invalid_recovery_record") pure . eitherDecodeStrict'
field :: FromJSON a => Key -> Value -> IO a
field name value=either (const $ reject "invalid_recovery_record") pure $ parseEither (withObject "recovery" (.:name)) value
sync :: FilePath -> IO ()
sync path=bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise
