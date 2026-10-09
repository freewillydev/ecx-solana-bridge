-- Real journal files and subprocesses, with fake service status/restore output.
-- No database, node, root directory or live custody is accessed by this contract.
module RestoreGuideCheck (contract,rootContract) where
import RestoreGuide (restoreStep)
import qualified RestoreNative
import qualified Bridge.Config as C
import Bridge.Identity (digest)
import Paths_ecx_bridge (getDataFileName)
import System.Info (os)
import System.Posix.User (getEffectiveUserID,getUserEntryForName,userID,userGroupID)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import qualified Data.Map.Strict as M
import Bridge.AdminKey (savePrivate,readPrivate)
import Bridge.Error (BridgeError(..))
import Control.Exception (bracket,try,finally)
import Control.Monad (forM)
import Data.Aeson (Value,encode,object,(.=),eitherDecodeStrict')
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import System.Directory
import System.Environment (lookupEnv,setEnv,unsetEnv)
import System.FilePath ((</>),takeDirectory,takeFileName)
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode,setOwnerAndGroup,createSymbolicLink)

contract :: IO Bool
contract=bracket temporary removeDirectoryRecursive $ \directory->do
  -- This is the production ancestry guard, before any ownership mutation.
  RestoreNative.checkRootAncestors "/"
  unsafeAncestor<-try (RestoreNative.checkRootAncestors directory) :: IO (Either BridgeError ())
  nativeStage<-RestoreNative.newStage
  ledgerStage<-RestoreNative.newLedgerStage
  let ancestry=case unsafeAncestor of Left(BridgeError "unsafe_restore_ancestor")->True; _->False
      stagePaths=takeDirectory nativeStage=="/var/lib/ecx-bridge-restore-stage/native"
        && takeDirectory ledgerStage=="/var/lib/ecx-bridge-restore-stage/ledger"
  RestoreNative.checkStages nativeStage ledgerStage
  legacy<-try (RestoreNative.checkStages ("/var/lib/ecx-betanet/bridge-restore/"<>replicate 64 'a') ledgerStage) :: IO (Either BridgeError ())
  legacyLedger<-try (RestoreNative.checkStages nativeStage ("/var/lib/postgresql/bridge-restore/"<>replicate 64 'b')) :: IO (Either BridgeError ())
  let oldRefused result=case result of Left(BridgeError "legacy_restore_staging_requires_review")->True; _->False
  original<-lookupEnv "PATH"
  let restorePath=maybe (unsetEnv "PATH") (setEnv "PATH") original
      fake=directory</>"restore-child"
      calls=directory</>"calls"
      response=object ["database" .= ("ecx_restore_0123456789abcdef0123456789abcdef"::String),"criticalSequence" .= (42::Int),"paused" .= True]
  -- Scripts are fixed controlled test fixtures. Caller inputs never become shell source.
  writeFile (directory</>"systemctl") "#!/bin/sh\nprintf 'LoadState=loaded\nActiveState=inactive\nMainPID=0\nUnitFileState=masked\n'\n"
  setFileMode (directory</>"systemctl") 0o700
  writeFile fake "#!/bin/sh\nprintf 'called\n' >> \"$1\"\ncase \"$2\" in fail) exit 1;; invalid) printf 'not-json';; *) printf '%s' \"$3\";; esac\n"
  setFileMode fake 0o700
  setEnv "PATH" (directory<>maybe "" (':' :) original)
  flip finally restorePath $ do
    successDir<-new directory "success"
    let args=[calls,"ok",B.unpack $ L.toStrict $ encode response]
    first<-restoreStep successDir fake "ledger" args
    again<-restoreStep successDir fake "ledger" args
    unchanged<-B.readFile calls
    changed<-refused "restore_step_arguments_changed" $ restoreStep successDir fake "ledger" (args<>["different-minimum-or-identity"])
    missingChild<-restoreStep successDir (directory</>"does-not-exist") "ledger" args
    -- Successful records are reused even when a child cannot be invoked. No
    -- second database/wallet creation is permitted after a recorded success.
    outcomes<-forM ["ledger","native-wallet"] $ \label->do
      interrupted<-new directory (label<>"-interrupted")
      savePrivate (interrupted</>label<>".started") (L.toStrict $ encode args)
      before<-B.readFile calls
      rejected<-refused "restore_interrupted_requires_review" $ restoreStep interrupted fake label args
      after<-B.readFile calls
      complete<-doesFileExist(interrupted</>label<>".completed")
      pure(rejected && before==after && not complete)
    failedDir<-new directory "failed"
    failed<-refused "restore_command_failed_journal_retained" $ restoreStep failedDir fake "native-wallet" [calls,"fail"]
    failureCalls<-B.readFile calls
    retry<-refused "restore_interrupted_requires_review" $ restoreStep failedDir fake "native-wallet" [calls,"fail"]
    retryCalls<-B.readFile calls
    falseSuccess<-doesFileExist(failedDir</>"native-wallet.completed")
    invalidDir<-new directory "invalid"
    invalid<-refused "invalid_restore_command_result" $ restoreStep invalidDir fake "ledger" [calls,"invalid"]
    invalidCompleted<-doesFileExist(invalidDir</>"ledger.completed")
    orphan<-new directory "orphan"
    savePrivate (orphan</>"ledger.completed") (L.toStrict $ encode response)
    rejectedOrphan<-refused "restore_completion_without_start" $ restoreStep orphan fake "ledger" args
    saved<-readPrivate(successDir</>"ledger.completed")
    pure(ancestry && stagePaths && oldRefused legacy && oldRefused legacyLedger && first==response && again==response && missingChild==response && unchanged=="called\n" && changed
      && and outcomes && failed && retry && failureCalls==retryCalls && not falseSuccess
      && invalid && not invalidCompleted && rejectedOrphan && saved==L.toStrict(encode response))

refused :: T.Text -> IO Value -> IO Bool
refused expected action=do
  result<-try action
  pure $ case result of Left (BridgeError actual)->actual==expected; Right _->False
new :: FilePath -> String -> IO FilePath
new parent name=do
  let path=parent</>name
  createDirectory path; setFileMode path 0o700; pure path
temporary :: IO FilePath
temporary=do
  base<-getTemporaryDirectory
  (path,handle)<-openTempFile base "ecx-restore-contract"
  hClose handle; removeFile path; createDirectory path; setFileMode path 0o700
  canonicalizePath path

-- Explicit opt-in on a root-operated Linux test host with ecxnode/postgres and
-- the managed node unit installed. Uses only generated dummy bytes; no RPC,
-- wallet restoration, database access, custody keys or service changes.
-- Keep the generated fixtures for inspection instead of deleting recovery data.
rootContract :: IO Bool
rootContract=do
  uid<-getEffectiveUserID
  if uid/=0 || os/="linux" then fail "root Linux recovery fixture required" else pure ()
  native<-RestoreNative.newStage
  ledger<-RestoreNative.newLedgerStage
  let root="/var/lib/ecx-recovery-contract-"<>takeFileName native
      journal=root</>"journal"
      bytes=M.fromList [("native-wallet","dummy wallet"),("native-wallet.json","{}")
        ,("ledger.json",L.toStrict $ encode $ object ["archive" .= ("ledger.dump"::String)])
        ,("ledger.dump","dummy ledger")]
  createDirectory root; setFileMode root 0o700
  createDirectory journal; setFileMode journal 0o700
  mapM_ (\(name,value)->savePrivate (root</>name) value) (M.toList bytes)
  let source=root</>"custody.json"
  savePrivate source (L.toStrict $ encode $ object ["files" .= M.map digest bytes])
  fixture<-getDataFileName "test/fixtures/deployment-config.json" >>= B.readFile
  config<-either fail pure (eitherDecodeStrict' fixture)
  let nativeConfig=config {C.nativeRpc="http://127.0.0.1:28532"}
  RestoreNative.stageNative journal source native nativeConfig
  RestoreNative.stageLedger journal source ledger "ledger.json"
  -- Completed replay verifies saved bytes; it must not perform new copies.
  RestoreNative.stageNative journal source native nativeConfig
  RestoreNative.stageLedger journal source ledger "ledger.json"
  access<-forM [("ecxnode",native,"native-wallet"),("postgres",ledger,"ledger.dump")] $ \(role,stage,file)->do
    (readCode,out,_)<-readProcessWithExitCode "/usr/sbin/runuser" ["-u",role,"--","/bin/cat",stage</>file] ""
    (writeCode,_,_)<-readProcessWithExitCode "/usr/sbin/runuser" ["-u",role,"--","/usr/bin/test","-w",takeDirectory stage] ""
    pure(readCode==ExitSuccess && Just(B.pack out)==M.lookup file bytes && writeCode/=ExitSuccess)
  -- Alternate hostile ancestors: service-owned, root-owned writable, symlink.
  outcomes<-forM ["owned","writable","symlink"] $ \kind->do
    let path=root</>kind
    if kind=="symlink" then createSymbolicLink "/" path else do
      createDirectory path
      if kind=="owned" then do
        user<-getUserEntryForName "postgres"
        setOwnerAndGroup path (userID user) (userGroupID user)
      else setFileMode path 0o777
    result<-try (RestoreNative.checkRootAncestors path) :: IO (Either BridgeError ())
    pure $ case result of Left(BridgeError "unsafe_restore_ancestor")->True; _->False
  putStrLn $ "Privileged recovery fixture retained: "<>root
  pure(and access && and outcomes)
