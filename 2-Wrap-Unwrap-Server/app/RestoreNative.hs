-- Root orchestration transfers only the native backup and public node settings.
module RestoreNative (newStage,newLedgerStage,stageNative,stageLedger,nodeCommand,ledgerCommand,checkExecutable) where
import Bridge.AdminKey (savePrivate,readPrivate)
import qualified Bridge.Config as C
import Bridge.Error (require,reject)
import Bridge.File (withHandle,hashHandle)
import Bridge.Identity (digest)
import Crypto.Random (getRandomBytes)
import Control.Exception (bracket)
import Control.Monad (unless,forM_)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import System.Directory (doesDirectoryExist,doesFileExist)
import System.Exit (ExitCode(..))
import System.FilePath ((</>),takeDirectory,takeFileName)
import qualified System.Posix.Directory as P
import System.Posix.Files
import System.Posix.IO hiding (sync)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.Types (UserID)
import System.Posix.User (getUserEntryForName,userID,userGroupID)
import System.Process (readProcessWithExitCode)

base,ledgerBase :: FilePath
base="/var/lib/ecx-betanet/bridge-restore"
ledgerBase="/var/lib/postgresql/bridge-restore"
newStage :: IO FilePath
newStage=(base</>) . T.unpack . digest <$> (getRandomBytes 32 :: IO B.ByteString)
newLedgerStage :: IO FilePath
newLedgerStage=(ledgerBase</>) . T.unpack . digest <$> (getRandomBytes 32 :: IO B.ByteString)
ledgerCommand :: FilePath -> T.Text -> FilePath -> Int64 -> [String]
ledgerCommand binary fingerprint manifest minimumValue=["-u","postgres","--","/usr/bin/env","-i","PATH=/usr/bin:/bin","PGHOST=/var/run/postgresql","PGPORT=5432","PGUSER=postgres","PGDATABASE=postgres","ecx_bridge_datadir="<>(takeDirectory(takeDirectory binary)</>"share"),binary,"restore-ledger","--fingerprint",T.unpack fingerprint,manifest,show minimumValue]
nodeCommand :: FilePath -> String -> FilePath -> [String]
nodeCommand binary mode staging=nodeArguments binary [mode,staging</>"node.json",staging</>"native-wallet.json"]
nodeArguments :: FilePath -> [String] -> [String]
nodeArguments binary arguments=["-u","ecxnode","--","/usr/bin/env","-i","PATH=/usr/bin:/bin",binary]<>arguments
checkExecutable :: FilePath -> IO ()
checkExecutable binary=do
  (code,_,_)<-readProcessWithExitCode "/usr/sbin/runuser" (nodeArguments binary ["version"]) ""
  require (code==ExitSuccess) "restore_candidate_not_executable_by_node_use_verified_traversable_release"
  (databaseCode,_,_)<-readProcessWithExitCode "/usr/sbin/runuser" ["-u","postgres","--","/usr/bin/env","-i","PATH=/usr/bin:/bin",binary,"version"] ""
  require (databaseCode==ExitSuccess) "restore_candidate_not_executable_by_postgres_use_verified_traversable_release"

stageLedger :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
stageLedger journal source staging manifestName=do
  require (manifestName==takeFileName manifestName && manifestName `notElem` ["",".",".."]) "invalid_ledger_manifest_path"
  bytes<-readPrivate(takeDirectory source</>manifestName)
  value<-either (const $ reject "invalid_backup_manifest") pure (eitherDecodeStrict' bytes)
  archive<-either (const $ reject "invalid_backup_manifest") pure $ parseEither (withObject "ledger" (.: "archive")) value
  require (archive==takeFileName archive && archive `notElem` ["",".",".."]) "invalid_ledger_archive_path"
  stageFiles Ledger journal source staging [manifestName,archive] Nothing

stageNative :: FilePath -> FilePath -> FilePath -> C.Config -> IO ()
stageNative journal source staging c=do
  require (C.nativeRpc c=="http://127.0.0.1:28532") "restore_requires_managed_native_rpc"
  (code,name,_)<-readProcessWithExitCode "systemctl" ["show","ecx-betanet.service","--property=User","--value"] ""
  require (code==ExitSuccess && words name==["ecxnode"]) "restore_requires_verified_managed_node_identity"
  let node=object ["profile" .= C.profile c,"nativeRpc" .= C.nativeRpc c,"nativeWallet" .= C.nativeWallet c
        ,"nativeCheckpointHeight" .= C.nativeCheckpointHeight c,"nativeCheckpointHash" .= C.nativeCheckpointHash c
        ,"nativeCookie" .= ("/var/lib/ecx-betanet/.cookie"::FilePath)]
  stageFiles Native journal source staging ["native-wallet","native-wallet.json"] (Just node)

-- Closed role selection; no caller-selected owner, parent or external command.
data StageOwner = Native | Ledger
stageFiles :: StageOwner -> FilePath -> FilePath -> FilePath -> [FilePath] -> Maybe Value -> IO ()
stageFiles owner journal source staging files node=do
  let (parentBase,role,label)=case owner of Native->(base,"ecxnode","native-stage"); Ledger->(ledgerBase,"postgres","ledger-stage")
  require (takeDirectory staging==parentBase && length(takeFileName staging)==64
    && all (`elem` ("0123456789abcdef"::String)) (takeFileName staging)) "invalid_restore_staging"
  user<-getUserEntryForName role
  parent<-getSymbolicLinkStatus(takeDirectory parentBase)
  require (isDirectory parent && fileOwner parent==userID user && fileMode parent .&. 0o022==0) "unsafe_restore_role_directory"
  bundle<-readPrivate source >>= either (const $ reject "invalid_custody_manifest") pure . eitherDecodeStrict'
  hashes<-either (const $ reject "invalid_custody_hashes") pure $ parseEither (withObject "custody" (.: "files")) bundle
  let expected file=maybe (reject "missing_restore_file_hash") pure (M.lookup file (hashes :: M.Map FilePath T.Text))
      started=journal</>label<>".started"; completed=journal</>label<>".completed"
      verify=do
        status<-getSymbolicLinkStatus staging
        require (isDirectory status && fileOwner status==userID user && fileMode status .&. 0o777==0o700) "unsafe_restore_staging"
        forM_ files $ \file->do
          checksum<-expected file
          actual<-hashPrivate (userID user) (staging</>file)
          require (actual==checksum) "restore_staging_changed"
        forM_ node $ \settings->do
          actual<-hashPrivate (userID user) (staging</>"node.json")
          require (actual==digest(L.toStrict $ encode settings)) "native_restore_settings_changed"
  done<-doesFileExist completed
  began<-doesFileExist started
  if done then do
    require began "restore_stage_missing_start"
    forM_ [started,completed] $ \path->do
      saved<-readPrivate path
      require (saved==L.toStrict(encode staging)) "restore_stage_changed"
    verify
  else do
    require (not began) "restore_stage_interrupted_requires_review"
    exists<-doesDirectoryExist parentBase
    unless exists $ do
      P.createDirectory parentBase 0o700
      -- Setup runs under umask 077; explicitly allow traversal of this empty
      -- root-owned parent. Each role's actual staging directory stays 0700.
      setFileMode parentBase 0o711
      sync parentBase; sync(takeDirectory parentBase)
    status<-getSymbolicLinkStatus parentBase
    require (isDirectory status && fileOwner status==0 && fileMode status .&. 0o777==0o711) "unsafe_restore_parent"
    savePrivate started (L.toStrict $ encode staging)
    P.createDirectory staging 0o700
    sync parentBase
    forM_ files $ \file->do
      checksum<-expected file
      original<-hashPrivate 0 (takeDirectory source</>file)
      require (original==checksum) "restore_source_changed"
      (copied,_,_)<-readProcessWithExitCode "/usr/bin/install" ["-m","0600","-o",role,"-g",role,"--",takeDirectory source</>file,staging</>file] ""
      require (copied==ExitSuccess) "restore_copy_failed"
      sync(staging</>file)
    forM_ node $ \settings->do
      savePrivate (staging</>"node.json") (L.toStrict $ encode settings)
      setOwnerAndGroup (staging</>"node.json") (userID user) (userGroupID user)
      sync(staging</>"node.json")
    setOwnerAndGroup staging (userID user) (userGroupID user)
    sync staging; sync parentBase
    verify
    savePrivate completed (L.toStrict $ encode staging)

hashPrivate :: UserID -> FilePath -> IO T.Text
hashPrivate uid path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd->do
  status<-getFdStatus fd
  require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o777==0o600 && linkCount status==1) "unsafe_restore_file"
  withHandle fd hashHandle
sync :: FilePath -> IO ()
sync path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
