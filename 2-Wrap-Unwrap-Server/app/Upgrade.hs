{-# LANGUAGE DeriveGeneric #-}
-- Root-only service orchestration. Financial work remains in closed CLI/DSL operations.
module Upgrade (withLifecycle) where
import Bridge.AdminKey (privateParent,readPrivate,savePrivate,withFamily)
import Bridge.Error (require,reject)
import Bridge.Identity (digest)
import qualified Bridge.Config as C
import qualified Bridge.Wire as W
import qualified SetupPaths
import Control.Exception (bracket)
import Control.Monad (forM_,unless,when)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bits ((.&.))
import Data.List (isPrefixOf,isInfixOf)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import qualified Data.Aeson.KeyMap as KM
import GHC.Generics (Generic)
import System.Directory (canonicalizePath,doesDirectoryExist,doesFileExist,listDirectory,removeFile)
import System.Exit (ExitCode(..))
import System.FilePath ((</>),takeDirectory)
import System.Info (arch,os)
import System.Posix.Files (getSymbolicLinkStatus,isDirectory,isRegularFile,fileOwner,fileMode)
import qualified System.Posix.Directory as P
import System.Posix.IO (openFd,closeFd,OpenMode(ReadOnly),defaultFileFlags)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcessWithExitCode,readCreateProcessWithExitCode,proc,CreateProcess(cwd))

-- Immutable phase files, plus one durable pending pointer. Completed records remain.
data Upgrade = Upgrade
  { oldRelease :: T.Text, newRelease :: T.Text, candidate :: FilePath
  , setupDirectory :: FilePath, identity :: T.Text, configuration :: T.Text
  } deriving (Eq,Show,Generic)
instance ToJSON Upgrade
instance FromJSON Upgrade

root,installed,current,workerConfig :: FilePath
root="/var/lib/ecx-bridge-upgrade"
installed="/etc/ecx-bridge/installed"
current="/opt/ecx-bridge/current"
workerConfig="/etc/ecx-bridge/worker/config.json"

-- One lock across all setup directories. No evaluator or signer capability escapes.
withLifecycle :: FilePath -> IO () -> IO ()
withLifecycle directory start=do
  require (os=="linux") "start_requires_ubuntu_24_04"
  getEffectiveUserID >>= \uid->require (uid==0) "run_sudo_ecx_bridge"
  exists<-doesDirectoryExist root
  unless exists $ do
    P.createDirectory root 0o700
    bracket (openFd (takeDirectory root) ReadOnly defaultFileFlags) closeFd fileSynchronise
  privateParent (root</>"pending")
  withFamily (root</>"lifecycle") $ do
    pending<-doesFileExist(root</>"pending")
    completed<-doesFileExist installed
    if pending then do
      plan<-decodeRecord =<< readPrivate(root</>"pending")
      require (setupDirectory plan==directory) "upgrade_requires_original_setup_directory"
      continue plan start
    else if not completed then start else do
      executing<-SetupPaths.bundleRoot
      case executing of
        Nothing->start
        Just bundle->do
          next<-verifyBundle bundle
          previous<-T.strip . b8ToText <$> B.readFile installed
          actual<-canonicalizePath current >>= verifyBundle
          require (previous==actual) "installed_release_marker_mismatch_requires_recovery"
          if next==previous then start else do
            compatible bundle
            config<-C.loadConfig workerConfig
            fingerprint<-configurationHash
            let plan=Upgrade previous next bundle directory (C.fingerprint config) fingerprint
            -- Publish before any stop. Reruns cannot accidentally become fresh setup.
            savePrivate (root</>"pending") (L.toStrict $ encode plan)
            continue plan start

continue :: Upgrade -> IO () -> IO ()
continue plan start=do
  verifyBundle (candidate plan) >>= \value->require (value==newRelease plan) "upgrade_candidate_changed"
  configurationHash >>= \value->require (value==configuration plan) "upgrade_configuration_changed"
  active<-canonicalizePath current >>= verifyBundle
  marker<-T.strip . b8ToText <$> B.readFile installed
  require ((active,marker) `elem` [(oldRelease plan,oldRelease plan),(newRelease plan,oldRelease plan),(newRelease plan,newRelease plan)])
    "upgrade_installed_release_changed"
  config<-C.loadConfig workerConfig
  require (C.fingerprint config==identity plan) "upgrade_identity_changed"
  let name=T.unpack(oldRelease plan<>"-"<>newRelease plan)
      phase suffix=root</>(name<>suffix)
      prepared="/opt/ecx-bridge/releases"</>T.unpack(newRelease plan)
      binary=prepared</>"bin/ecx-bridge"
      blocked role=root</>(role<>".blocked")
      mark path bytes=do
        exists<-doesFileExist path
        if exists then readPrivate path >>= \old->require(old==bytes) "upgrade_phase_conflict"
          else savePrivate path bytes
      unblock role=do
        exists<-doesFileExist(blocked role)
        when exists $ removeFile(blocked role) >> syncRoot
      checkpointFile=phase ".checkpoint"
      publishedFile=phase ".published"
  published<-doesFileExist publishedFile
  unless published $ do
    compatible (candidate plan)
    command "/bin/sh" [candidate plan</>"install","prepare-upgrade"]
    verifyBundle prepared >>= \value->require(value==newRelease plan) "upgrade_staged_bundle_changed"
    putStrLn "Upgrade: stopping intake and saving existing custody state."
    -- Persistent systemd conditions survive reboot, including on older releases.
    forM_ ["worker","signer"] installInterlock
    mark (blocked "worker") "upgrade\n"
    command "systemctl" ["daemon-reload"]
    command "systemctl" ["stop","ecx-bridge-worker"]
    stopped "ecx-bridge-worker"
    checkpointed<-doesFileExist checkpointFile
    unless checkpointed $ do
      -- Older signers cannot export across the managed node UID boundary.
      -- Transition only the verified same-schema signer while the worker remains
      -- persistently blocked. Reentry stops it before republishing the same plan.
      mark (blocked "signer") "upgrade\n"
      command "systemctl" ["stop","ecx-bridge-signer"]
      stopped "ecx-bridge-signer"
      managed<-doesFileExist "/etc/systemd/system/ecx-betanet.service"
      installSignerTransition prepared managed (phase ".signer-transition")
      when managed $ command "/bin/sh" [prepared</>"native-backup"]
      verifySignerCommand prepared managed
      unblock "signer"
      command "systemctl" ["start","ecx-bridge-signer"]
      -- The bounded process itself pauses and owns the existing writer/fence.
      result<-output "runuser" ["-u","ecxbridgew","--","env"
        ,"PGHOST=/var/run/postgresql","PGPORT=5432","PGDATABASE=ecx_bridge"
        ,"PGUSER=ecxbridgew","PGREADUSER=ecxbridger","ecx_bridge_datadir="<>(prepared</>"share")
        ,binary,"checkpoint",workerConfig]
      receipt<-decodeRecord (B8.pack result)
      require (W.receiptIdentity receipt==identity plan && W.receiptSequence receipt>=0)
        "upgrade_checkpoint_identity_mismatch"
      -- Receipt is acknowledged by the critical evaluator before publication here.
      savePrivate checkpointFile (L.toStrict $ encode (receipt::W.BackupReceipt))
    receipt<-decodeRecord =<< readPrivate checkpointFile
    require (W.receiptIdentity receipt==identity plan) "upgrade_checkpoint_identity_mismatch"
    mark (blocked "signer") "upgrade\n"
    command "systemctl" ["stop","ecx-bridge-signer"]
    stopped "ecx-bridge-signer"
    -- Bind the host fence evidence alongside the receipt, without modifying it.
    fence<-checkFence binary receipt True
    mark (phase ".fence") fence
    putStrLn "Upgrade: verified checkpoint saved; installing the reviewed version."
    command "/bin/sh" [candidate plan</>"install","upgrade"]
    installedRelease<-T.strip . b8ToText <$> B.readFile installed
    actual<-canonicalizePath current >>= verifyBundle
    require (installedRelease==newRelease plan && actual==newRelease plan) "upgrade_publication_incomplete"
    removeSignerTransition (phase ".signer-transition")
    managed<-doesFileExist "/etc/systemd/system/ecx-betanet.service"
    verifySignerCommand current managed
    savePrivate publishedFile (L.toStrict $ encode plan)
  recorded<-decodeRecord =<< readPrivate publishedFile
  require (recorded==plan) "upgrade_phase_conflict"
  actual<-canonicalizePath current >>= verifyBundle
  require (actual==newRelease plan) "upgrade_published_release_changed"
  removeSignerTransition (phase ".signer-transition")
  markerNow<-T.strip . b8ToText <$> B.readFile installed
  require (markerNow==newRelease plan) "upgrade_installed_marker_changed"
  -- A crash may follow successful resume but precede the completion record.
  -- Stop again to obtain a fresh paused boot; never reset advanced durable state.
  mark (blocked "worker") "upgrade\n"
  command "systemctl" ["stop","ecx-bridge-worker"]
  stopped "ecx-bridge-worker"
  receipt<-decodeRecord =<< readPrivate checkpointFile
  _<-checkFence binary receipt False
  unblock "signer"
  unblock "worker"
  putStrLn "Upgrade: recovering saved work and reconciling current chains before resume."
  start
  mark (phase ".complete") (L.toStrict $ encode plan)
  removeFile(root</>"pending")
  syncRoot
  putStrLn "Upgrade complete. Existing wallets, ledger and settings retained."

-- Fixed offline infrastructure read: descriptor checks and the live fence lock
-- remain in Bridge.Fence. No raw ledger query or new signing path is introduced.
checkFence :: FilePath -> W.BackupReceipt -> Bool -> IO B.ByteString
checkFence binary receipt exact=do
  result<-output "runuser" ["-u","ecxbridgew","--",binary,"check-fence",workerConfig]
  value<-decodeRecord (B8.pack result)
  (fingerprint,sequenceNo)<-either (const $ reject "invalid_upgrade_fence") pure $
    parseEither (withObject "fence" $ \o->(,) <$> o .: "fingerprint" <*> o .: "sequence") value
  require (fingerprint==W.receiptIdentity receipt &&
    (if exact then sequenceNo==W.receiptSequence receipt else sequenceNo>=W.receiptSequence receipt))
    "upgrade_fence_checkpoint_mismatch"
  pure(B8.pack result)

compatible :: FilePath -> IO ()
compatible bundle=do
  old<-B.readFile(current</>"migrations.sha256")
  new<-B.readFile(bundle</>"migrations.sha256")
  require (old==new) "schema_change_requires_reviewed_offline_migration"

configurationHash :: IO T.Text
configurationHash=digest . B.concat <$> mapM B.readFile
  [workerConfig,"/etc/ecx-bridge/signer/config.json","/etc/ecx-bridge/worker/interface.json"]

verifyBundle :: FilePath -> IO T.Text
verifyBundle path=do
  canonical<-canonicalizePath path
  require (canonical==path) "upgrade_bundle_requires_canonical_path"
  -- Trusted release material is root-owned throughout, with no writable/link leaves.
  let check name=do
        status<-getSymbolicLinkStatus name
        require (fileOwner status==0 && fileMode status .&. 0o022==0
          && (isDirectory status || isRegularFile status)) "unsafe_upgrade_bundle"
        when (isDirectory status) $ listDirectory name >>= mapM_ (check . (name</>))
      ancestors name=do
        status<-getSymbolicLinkStatus name
        require (isDirectory status && fileOwner status==0 && fileMode status .&. 0o022==0) "unsafe_upgrade_ancestor"
        when (name/="/") $ ancestors(takeDirectory name)
  ancestors(takeDirectory path)
  check path
  architecture<-B8.strip <$> B.readFile(path</>"architecture")
  require (architecture==B8.pack arch) "upgrade_architecture_mismatch"
  (code,_,_)<-readCreateProcessWithExitCode ((proc "sha256sum" ["--check","--status","manifest.sha256"]) {cwd=Just path}) ""
  require (code==ExitSuccess) "upgrade_bundle_digest_mismatch"
  digest <$> B.readFile(path</>"manifest.sha256")

installInterlock :: String -> IO ()
installInterlock role=do
  let directory="/etc/systemd/system/ecx-bridge-"<>role<>".service.d"
      path=directory</>"90-upgrade.conf"
      bytes=B8.pack("[Unit]\nConditionPathExists=!"<>root</>(role<>".blocked")<>"\n")
      staged=root</>(role<>".condition")
  exists<-doesFileExist staged
  unless exists $ savePrivate staged bytes
  readPrivate staged >>= \value->require(value==bytes) "upgrade_interlock_changed"
  command "install" ["-d","-o","root","-g","root","-m","0755",directory]
  present<-doesFileExist path
  if present then do
    status<-getSymbolicLinkStatus path
    require (isRegularFile status && fileOwner status==0 && fileMode status .&. 0o022==0) "unsafe_upgrade_interlock"
    B.readFile path >>= \value->require(value==bytes) "upgrade_interlock_changed"
    else command "install" ["-o","root","-g","root","-m","0644",staged,path]
  command "sync" ["-f",directory]

-- A fixed service override, not a caller-selected command. All existing unit
-- restrictions/credentials/SELECT-only role are retained. Record before publication.
transitionPath :: FilePath
transitionPath="/etc/systemd/system/ecx-bridge-signer.service.d/80-upgrade-executable.conf"
installSignerTransition :: FilePath -> Bool -> FilePath -> IO ()
installSignerTransition prepared managed record=do
  backup<-doesFileExist "/etc/ecx-bridge/signer/backup.json"
  require backup "custody_checkpoint_not_configured"
  user<-output "systemctl" ["show","ecx-bridge-signer","--property=User","--value"]
  require (words user==["ecxbridges"]) "upgrade_unrecognized_signer_service"
  stopped "ecx-bridge-signer"
  binding<-configurationHash
  let bytes=B8.pack $ "# Configuration SHA256: "<>T.unpack binding<>"\n[Service]\nExecStart=\nExecStart="<>(prepared</>"bin/ecx-bridge")
        <>" signer /etc/ecx-bridge/signer/config.json /etc/ecx-bridge/signer/solana.keypair.json"
        <>" /etc/ecx-bridge/signer/backup.json /var/lib/ecx-bridge/signer\n"
        <>"Environment=ecx_bridge_datadir="<>(prepared</>"share")<>"\n"
        <>(if managed then "Environment=ECX_NATIVE_BACKUP_SERVICE=1\n" else "")
  exists<-doesFileExist record
  if exists then readPrivate record >>= \saved->require(saved==bytes) "upgrade_transition_changed"
    else savePrivate record bytes
  present<-doesFileExist transitionPath
  if present then do
    status<-getSymbolicLinkStatus transitionPath
    require (isRegularFile status && fileOwner status==0 && fileMode status .&. 0o022==0) "unsafe_upgrade_transition"
    B.readFile transitionPath >>= \saved->require(saved==bytes) "upgrade_transition_changed"
    else command "install" ["-o","root","-g","root","-m","0644",record,transitionPath]
  command "sync" ["-f",takeDirectory transitionPath]
  command "systemctl" ["daemon-reload"]

removeSignerTransition :: FilePath -> IO ()
removeSignerTransition record=do
  present<-doesFileExist transitionPath
  when present $ do
    saved<-readPrivate record
    status<-getSymbolicLinkStatus transitionPath
    require (isRegularFile status && fileOwner status==0 && fileMode status .&. 0o022==0) "unsafe_upgrade_transition"
    actual<-B.readFile transitionPath
    require (actual==saved) "upgrade_transition_changed"
    stopped "ecx-bridge-signer"
    removeFile transitionPath
    command "sync" ["-f",takeDirectory transitionPath]
    command "systemctl" ["daemon-reload"]

-- Check systemd's merged unit, including later operator drop-ins. Do not print
-- Environment: unrelated entries may contain credentials.
verifySignerCommand :: FilePath -> Bool -> IO ()
verifySignerCommand bundle managed=do
  execution<-output "systemctl" ["show","ecx-bridge-signer","--property=ExecStart","--value"]
  environment<-words <$> output "systemctl" ["show","ecx-bridge-signer","--property=Environment","--value"]
  let binary=bundle</>"bin/ecx-bridge"
      expected="{ path="<>binary<>" ; argv[]="<>binary
        <>" signer /etc/ecx-bridge/signer/config.json /etc/ecx-bridge/signer/solana.keypair.json"
        <>" /etc/ecx-bridge/signer/backup.json /var/lib/ecx-bridge/signer ; ignore_errors=no ;"
  require (expected `isPrefixOf` execution && not ("} {" `isInfixOf` execution))
    "upgrade_signer_command_changed"
  require (("ecx_bridge_datadir="<>(bundle</>"share")) `elem` environment
    && (not managed || "ECX_NATIVE_BACKUP_SERVICE=1" `elem` environment))
    "upgrade_signer_environment_changed"

stopped :: String -> IO ()
stopped service=do
  pid<-output "systemctl" ["show",service,"--property=MainPID","--value"]
  state<-output "systemctl" ["show",service,"--property=ActiveState","--value"]
  require (words pid==["0"] && words state `elem` [["inactive"],["failed"]]) "upgrade_service_still_running"

output :: FilePath -> [String] -> IO String
output program args=do
  (code,result,failure)<-readProcessWithExitCode program args ""
  unless (code==ExitSuccess) $ case eitherDecodeStrict' (B8.pack failure) of
    Right (Object fields) | Just (String reason)<-KM.lookup "error" fields
      ,not(T.null reason),T.length reason<=128
      ,T.all (\c->c `elem` ("abcdefghijklmnopqrstuvwxyz0123456789_"::String)) reason->reject reason
    _->reject "upgrade_step_failed_state_preserved_check_service_status"
  pure result
command :: FilePath -> [String] -> IO ()
command program args=output program args >> pure ()
decodeRecord :: FromJSON a => B.ByteString -> IO a
decodeRecord=either (const $ reject "invalid_upgrade_record") pure . eitherDecodeStrict'
b8ToText :: B.ByteString -> T.Text
b8ToText=T.pack . B8.unpack
syncRoot :: IO ()
syncRoot=bracket (openFd root ReadOnly defaultFileFlags) closeFd fileSynchronise
