{-# LANGUAGE ScopedTypeVariables #-}
-- Private archive mechanics. Only Store's closed backup evaluator supplies the
-- exported snapshot and metadata; no SQL or remote acknowledgment lives here.
module Bridge.Store.Backup (LedgerArchive(..),archiveLedger) where

import Bridge.Error
import Control.Exception (IOException,bracket,bracketOnError,catch)
import Crypto.Hash (Context,Digest,SHA256,hashInit,hashUpdate,hashFinalize)
import Data.Aeson (encode,object,(.=))
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import System.Directory (removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..))
import System.FilePath (isAbsolute,normalise,takeFileName)
import System.IO
import System.Posix.Files
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Process
import System.Timeout (timeout)

data LedgerArchive = LedgerArchive
  { archivePath :: FilePath, manifestPath :: FilePath, archiveHash :: Text
  , archiveIdentity :: Text, archiveSequence :: Int64 } deriving (Eq,Show)

-- The existing private directory is supplied by startup, never a customer.
-- pg_dump streams to disk with bounded memory. Keeping the exporting read-only
-- transaction open binds the entire dump and manifest to one MVCC snapshot;
-- no paying-writer transaction or row lock is held during this operation.
archiveLedger :: PG.ConnectInfo -> FilePath -> Text -> Int64 -> Int64 -> Text -> IO LedgerArchive
archiveLedger settings directory identity version sequenceNo snapshot = do
  require (isAbsolute directory && normalise directory==directory) "invalid_backup_directory"
  status <- getSymbolicLinkStatus directory
  uid <- getEffectiveUserID
  require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_backup_directory"
  require (not(T.null snapshot) && T.length snapshot<=128 && T.all (`elem` ("0123456789abcdefABCDEF-"::String)) snapshot) "invalid_backup_snapshot"
  inherited <- getEnvironment
  let environment = [("PGHOST",PG.connectHost settings),("PGPORT",show $ PG.connectPort settings)
                    ,("PGDATABASE",PG.connectDatabase settings),("PGUSER",PG.connectUser settings)
                    ,("PGPASSWORD",PG.connectPassword settings),("PGCONNECT_TIMEOUT","10")]
                    <> filter (not . isPrefixOf "PG" . fst) inherited
      run program arguments output = withCreateProcess (proc program arguments)
        {env=Just environment,std_in=NoStream,std_out=output,std_err=NoStream,close_fds=True} $ \_ _ _ process -> do
          result <- timeout (300*1000000) (waitForProcess process)
          require (result==Just ExitSuccess) (if program=="pg_dump" then "ledger_archive_dump_failed" else "ledger_archive_validation_failed")
      cleanup (path,handle) = do
        hClose handle `catch` (\(_::IOException)->pure ())
        removeFile path
      syncFile path = bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
  bracketOnError (openBinaryTempFile directory "ledger.dump-") cleanup $ \(path,handle) -> do
    setFileMode path 0o600
    run "pg_dump" ["--format=custom","--no-owner","--no-privileges","--no-password","--snapshot="<>T.unpack snapshot] (UseHandle handle)
    syncFile path
    withBinaryFile "/dev/null" WriteMode $ \sink->run "pg_restore" ["--list",path] (UseHandle sink)
    checksum <- withBinaryFile path ReadMode (hashChunks hashInit)
    bracketOnError (openBinaryTempFile directory "ledger.manifest-") cleanup $ \(manifest,output) -> do
      setFileMode manifest 0o600
      BL.hPut output $ encode $ object
        ["format" .= (2::Int),"archive" .= takeFileName path,"sha256" .= checksum
        ,"fingerprint" .= identity,"schemaVersion" .= version,"criticalSequence" .= sequenceNo
        ,"remoteDurabilityAcknowledged" .= False]
      hFlush output
      hClose output
      syncFile manifest
      bracket (openFd directory ReadOnly defaultFileFlags {nofollow=True,cloexec=True,directory=True}) closeFd fileSynchronise
      pure (LedgerArchive path manifest checksum identity sequenceNo)
 where
  hashChunks :: Context SHA256 -> Handle -> IO Text
  hashChunks context handle = do
    bytes <- BS.hGet handle 65536
    if BS.null bytes then pure (T.pack $ show (hashFinalize context :: Digest SHA256))
      else hashChunks (hashUpdate context bytes) handle
