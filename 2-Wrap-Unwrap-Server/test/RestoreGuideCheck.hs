-- Real journal files and subprocesses, with fake service status/restore output.
-- No database, node, root directory or live custody is accessed by this contract.
module RestoreGuideCheck (contract) where
import RestoreGuide (restoreStep)
import Bridge.AdminKey (savePrivate,readPrivate)
import Bridge.Error (BridgeError(..))
import Control.Exception (bracket,try,finally)
import Control.Monad (forM)
import Data.Aeson (Value,encode,object,(.=))
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import System.Directory
import System.Environment (lookupEnv,setEnv,unsetEnv)
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode)

contract :: IO Bool
contract=bracket temporary removeDirectoryRecursive $ \directory->do
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
    pure(first==response && again==response && missingChild==response && unchanged=="called\n" && changed
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
