{-# LANGUAGE DeriveGeneric #-}
-- Stopped recovery orchestration; all custody effects remain closed CLI operations.
module RestoreGuide (restoreGuide,restoreStep,Plan(..),prompt,stopped) where
import Bridge.AdminKey (privateParent,readPrivate,savePrivate,withFamily)
import qualified Bridge.Config as C
import qualified RestoreNative
import Bridge.Error (require,reject)
import Bridge.Identity (digest)
import Control.Monad (unless,forM_,when)
import Data.Aeson
import Data.Aeson.Types (parseEither,Parser)
import qualified Data.ByteString.Lazy as L
import Data.Int (Int64)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as B
import GHC.Generics (Generic)
import System.Directory (doesDirectoryExist,doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode(..))
import System.FilePath ((</>),takeDirectory,takeFileName,isAbsolute,normalise)
import System.Info (os)
import System.IO (hFlush,stdout,isEOF)
import qualified System.Posix.Directory as P
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

data Plan = Plan
  { config :: FilePath, manifest :: FilePath, minimumSequence :: Int64
  , configHash :: T.Text, manifestHash :: T.Text, identity :: T.Text
  , nativeStage :: FilePath, ledgerStage :: FilePath, databaseEnvironment :: [(String,String)]
  } deriving (Eq,Show,Generic)
instance ToJSON Plan
instance FromJSON Plan

root,upgradeRoot :: FilePath
root="/var/lib/ecx-bridge-restore"
upgradeRoot="/var/lib/ecx-bridge-upgrade"

restoreGuide :: IO ()
restoreGuide=do
  require (os=="linux") "restore_requires_linux"
  getEffectiveUserID >>= \uid->require (uid==0) "restore_requires_root"
  forM_ [root,upgradeRoot] $ \directory->do
    exists<-doesDirectoryExist directory
    unless exists $ P.createDirectory directory 0o700
    privateParent(directory</>"pending")
  withFamily (upgradeRoot</>"lifecycle") $ do
    upgrading<-doesFileExist(upgradeRoot</>"pending")
    require (not upgrading) "finish_or_review_pending_upgrade_first"
    stopped
    putStrLn "Restore stages a NEW paused database and the original native wallet. It never starts custody, adopts a fence or switches the active database."
    pending<-doesFileExist(root</>"pending")
    plan<-if pending then decode =<< readPrivate(root</>"pending") else prepare
    validate plan
    binary<-getExecutablePath
    RestoreNative.checkExecutable binary
    checked<-invoke binary ["check-custody",config plan,manifest plan,show(minimumSequence plan)]
    (fingerprint,sequenceNo)<-parse (withObject "custody result" $ \o->(,) <$> o .: "fingerprint" <*> o .: "criticalSequence") checked
    require (fingerprint==identity plan && sequenceNo>=minimumSequence plan) "restore_custody_result_mismatch"
    bundle<-decodeValue =<< readPrivate(manifest plan)
    ledger<-parse (withObject "custody manifest" (.: "ledgerManifest")) bundle
    require (ledger==takeFileName ledger && ledger `notElem` ["",".",".."]) "invalid_ledger_manifest_path"
    unless pending $ savePrivate(root</>"pending") (L.toStrict $ encode plan)
    c<-C.loadConfig(config plan)
    RestoreNative.stageNative root (manifest plan) (nativeStage plan) c
    walletStarted<-doesFileExist(root</>"native-wallet.started")
    unless walletStarted $ do
      _<-invoke "/usr/sbin/runuser" (RestoreNative.nodeCommand binary "check-native-restore" (nativeStage plan))
      pure ()
    RestoreNative.stageLedger root (manifest plan) (ledgerStage plan) ledger
    database<-restoreStep root "/usr/sbin/runuser" "ledger" (RestoreNative.ledgerCommand binary (identity plan) (ledgerStage plan</>ledger) (minimumSequence plan))
    (name,n,paused)<-parse (withObject "ledger result" $ \o->(,,) <$> o .: "database" <*> o .: "criticalSequence" <*> o .: "paused") database
    require (n==sequenceNo && paused && T.length name==44 && "ecx_restore_" `T.isPrefixOf` name
      && T.all (`elem` ("0123456789abcdef"::String)) (T.drop 12 name)) "restore_ledger_result_mismatch"
    wallet<-restoreStep root "/usr/sbin/runuser" "native-wallet" (RestoreNative.nodeCommand binary "native-restore-service" (nativeStage plan))
    walletName<-parse (withObject "wallet result" (.: "wallet")) wallet
    require (walletName==C.nativeWallet c) "restore_wallet_result_mismatch"
    putStrLn $ "Staging complete. Paused database: "<>T.unpack name<>"; native wallet: "<>T.unpack walletName
    putStrLn $ "Journal retained at "<>root<>". Native autoload remains disabled; no server has been activated."
    putStrLn "Before activation: independently verify old-host exclusion; install recovered keys/unlock files with service ownership; configure fresh credentials and the new database; explicitly adopt the custody fence; reconcile saved attempts and chain observations; then explicitly resume. See docs/OPERATIONS.md, recovery procedure."

prepare :: IO Plan
prepare=do
  putStrLn "First download and verify the full custody bundle with Backup and recovery. Keep the original native wallet name; it must be unused on this destination node."
  putStrLn "Use a root-owned private recovered bundle and root-owned target configuration. Only the native wallet backup and public node settings are staged for ecxnode; the full bundle and keys remain private."
  putStrLn "The verified ledger archive is staged privately for the local postgres account; local peer authentication is used without exposing wallet keys or configuration."
  path<-prompt "Target configuration (absolute path)"
  archive<-prompt "Verified custody.json (absolute path)"
  minimumText<-prompt "Independently retained minimum critical sequence (no default)"
  minimumValue<-maybe (reject "invalid_restore_minimum_sequence") pure (readMaybe minimumText)
  require (minimumValue>=0) "invalid_restore_minimum_sequence"
  c<-C.loadConfig path
  configBytes<-readPrivate path
  manifestBytes<-readPrivate archive
  putStrLn "Confirm source custody cannot continue paying (stop/exclude the old host and retain evidence). This acknowledgement is not a machine-verified fence."
  answer<-prompt "Type SOURCE EXCLUDED to stage recovery"
  require (answer=="SOURCE EXCLUDED") "restore_cancelled"
  staging<-RestoreNative.newStage
  ledgerStaging<-RestoreNative.newLedgerStage
  let plan=Plan path archive minimumValue (digest configBytes) (digest manifestBytes) (C.fingerprint c) staging ledgerStaging managedDatabase
  validate plan
  pure plan

validate :: Plan -> IO ()
validate plan=do
  forM_ [config plan,manifest plan] $ \path->require (isAbsolute path && normalise path==path) "absolute_restore_path_required"
  readPrivate(config plan) >>= \bytes->require (digest bytes==configHash plan) "restore_configuration_changed"
  readPrivate(manifest plan) >>= \bytes->require (digest bytes==manifestHash plan) "restore_manifest_changed"
  C.loadConfig(config plan) >>= \c->require (C.fingerprint c==identity plan) "restore_identity_changed"
  require (databaseEnvironment plan==managedDatabase) "restore_database_environment_changed"

managedDatabase :: [(String,String)]
managedDatabase=[("PGHOST","/var/run/postgresql"),("PGPORT","5432"),("PGUSER","postgres"),("PGDATABASE","postgres")]

-- Publication precedes the effect. A missing completion after any failure is
-- uncertain, even when the child reported failure: never repeat it automatically.
restoreStep :: FilePath -> FilePath -> String -> [String] -> IO Value
restoreStep directory binary label arguments=do
  require (label `elem` ["ledger","native-wallet"]) "invalid_restore_step"
  let started=directory</>label<>".started"; finished=directory</>label<>".completed"
  done<-doesFileExist finished
  began<-doesFileExist started
  if done then do
    require began "restore_completion_without_start"
    saved<-decode =<< readPrivate started
    require (saved==arguments) "restore_step_arguments_changed"
    decodeValue =<< readPrivate finished
  else do
    when began $ do
      putStrLn $ "Unknown outcome for "<>label<>". Inspect retained database/wallet and journal before any retry; do not delete markers or repeat the command blindly. No automatic activation is permitted."
      reject "restore_interrupted_requires_review"
    stopped
    putStrLn $ "Restoring "<>label<>"; interruption requires review of "<>started
    savePrivate started (L.toStrict $ encode arguments)
    value<-invoke binary arguments
    savePrivate finished (L.toStrict $ encode value)
    pure value

stopped :: IO ()
stopped=forM_ ["ecx-bridge-worker.service","ecx-bridge-signer.service"] $ \unit->do
  (code,result,_)<-readProcessWithExitCode "systemctl" ["show",unit,"--property=LoadState,ActiveState,MainPID,UnitFileState"] ""
  let properties=lines result
  require (code==ExitSuccess && ("LoadState=not-found" `elem` properties ||
    ("MainPID=0" `elem` properties && any (`elem` properties) ["ActiveState=inactive","ActiveState=failed"]
      && "UnitFileState=masked" `elem` properties))) "restore_requires_absent_or_stopped_masked_custody_services"

invoke :: FilePath -> [String] -> IO Value
invoke binary arguments=do
  (code,result,_)<-readProcessWithExitCode binary arguments ""
  require (code==ExitSuccess) "restore_command_failed_journal_retained"
  either (const $ reject "invalid_restore_command_result") pure (eitherDecode $ L.fromStrict $ encodeUtf8 result)
 where encodeUtf8=TE.encodeUtf8 . T.pack

parse :: (Value -> Parser a) -> Value -> IO a
parse parser value=either (const $ reject "invalid_restore_result") pure (parseEither parser value)
decode :: FromJSON a => B.ByteString -> IO a
decode bytes=either (const $ reject "invalid_restore_journal") pure (eitherDecodeStrict' bytes)
decodeValue :: B.ByteString -> IO Value
decodeValue bytes=decode bytes :: IO Value
prompt :: String -> IO String
prompt label=do
  putStr(label<>": "); hFlush stdout
  end<-isEOF
  require (not end) "restore_cancelled"
  value<-T.unpack . T.strip . T.pack <$> getLine
  if null value then putStrLn "A value is required; Ctrl-D cancels." >> prompt label else pure value
