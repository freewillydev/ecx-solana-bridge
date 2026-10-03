{-# LANGUAGE ScopedTypeVariables,DeriveGeneric #-}
-- Private archive mechanics. Only Store's closed backup evaluator supplies the
-- exported snapshot and metadata; no SQL or remote acknowledgment lives here.
module Bridge.Store.Backup (LedgerArchive(..),archiveLedger,RemoteBackup,loadRemoteBackup,uploadRemoteArchive,BackupReceipt(..),uploadArchive) where

import Bridge.Error
import Control.Exception (IOException,bracket,bracketOnError,catch,onException)
import Control.Monad (when)
import Crypto.Hash (Context,Digest,SHA256,hashInit,hashUpdate,hashFinalize)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.List (isPrefixOf,sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import System.Directory (removeFile)
import GHC.Generics (Generic)
import qualified Network.HTTP.Client as HTTP
import qualified Network.Socket as Socket
import qualified Data.Text.Encoding as TE
import System.Posix.Signals (signalProcess,sigKILL)
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

hashChunks :: Context SHA256 -> Handle -> IO Text
hashChunks context handle = do
  bytes <- BS.hGet handle 65536
  if BS.null bytes then pure (T.pack $ show (hashFinalize context :: Digest SHA256))
    else hashChunks (hashUpdate context bytes) handle

-- Operational configuration is private and separate from the financial identity.
-- No local repository constructor is exported by the Store component.
data RemoteBackup = RemoteBackup
  { restic :: FilePath, repositoryFile :: FilePath, passwordFile :: FilePath }
  deriving (Generic)
instance FromJSON RemoteBackup where
  parseJSON=genericParseJSON defaultOptions {rejectUnknownFields=True}
data BackupReceipt = BackupReceipt
  { receiptIdentity :: Text, receiptSequence :: Int64, receiptSnapshot :: Text
  , receiptArchiveHash :: Text } deriving (Eq,Show)

privateFile :: FilePath -> IO ()
privateFile path = do
  require (isAbsolute path && normalise path==path) "invalid_backup_file"
  status<-getSymbolicLinkStatus path
  uid<-getEffectiveUserID
  require (isRegularFile status && fileOwner status `elem` [0,uid] && fileMode status .&. 0o077==0) "unsafe_backup_file"

readPrivate :: FilePath -> IO BS.ByteString
readPrivate path = do
  privateFile path
  bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True} >>= fdToHandle) hClose $ \handle->do
    bytes<-BS.hGet handle 8193
    require (BS.length bytes<=8192) "backup_file_too_large"
    pure bytes

loadRemoteBackup :: FilePath -> IO RemoteBackup
loadRemoteBackup path = do
  bytes<-readPrivate path
  remote<-either (const $ reject "invalid_backup_configuration") pure (eitherDecodeStrict' bytes)
  require (isAbsolute $ restic remote) "invalid_backup_configuration"
  repository<-readPrivate (repositoryFile remote)
  url<-either (const $ reject "invalid_backup_repository") pure (TE.decodeUtf8' repository)
  endpoint<-maybe (reject "https_backup_repository_required") pure (T.stripPrefix "rest:https://" $ T.strip url)
  request<-HTTP.parseRequest ("https://"<>T.unpack endpoint) `catch` (\(_::HTTP.HttpException)->reject "invalid_backup_repository")
  let host=T.toLower $ TE.decodeUtf8 $ HTTP.host request
      hostname=T.dropAround (`elem` ("[]"::String)) host
  require (HTTP.secure request && not(T.null hostname) && hostname `notElem` ["localhost","localhost."]
    && not(".localhost" `T.isSuffixOf` T.dropWhileEnd (=='.') hostname)) "off_host_backup_required"
  addresses<-(Socket.getAddrInfo Nothing (Just $ T.unpack hostname) Nothing :: IO [Socket.AddrInfo])
  require (not(null addresses) && all (offHost . Socket.addrAddress) addresses) "off_host_backup_required"
  password<-readPrivate (passwordFile remote)
  require (not $ BS.null password) "invalid_backup_password"
  pure remote
 where
  offHost (Socket.SockAddrInet _ address)=let (a,_,_,_)=Socket.hostAddressToTuple address in a/=0 && a/=127
  offHost (Socket.SockAddrInet6 _ _ address _)=case Socket.hostAddress6ToTuple address of
    (0,0,0,0,0,marker,a,_) | marker==0 || marker==65535 -> a `div` 256 `notElem` [0,127]
    _->True
  offHost _=False

uploadRemoteArchive :: RemoteBackup -> LedgerArchive -> IO BackupReceipt
uploadRemoteArchive remote = uploadArchive (restic remote) (repositoryFile remote) (passwordFile remote)

-- Private storage seam also exercised against a real local encrypted repository.
-- It cannot acknowledge ledger coverage. Production reaches it only after the
-- RemoteBackup HTTPS/off-host/configuration checks above.
uploadArchive :: FilePath -> FilePath -> FilePath -> LedgerArchive -> IO BackupReceipt
uploadArchive program repository password archive = do
  require (isAbsolute program) "invalid_backup_configuration"
  privateFile repository
  privateFile password
  privateFile (archivePath archive)
  manifest<-readPrivate (manifestPath archive)
  checksum<-withBinaryFile (archivePath archive) ReadMode (hashChunks hashInit)
  value<-either (const $ reject "invalid_backup_manifest") pure (eitherDecodeStrict' manifest)
  let identity=archiveIdentity archive; sequenceNo=archiveSequence archive
      expected=object ["format" .= (2::Int),"archive" .= takeFileName(archivePath archive),"sha256" .= checksum
        ,"fingerprint" .= identity,"schemaVersion" .= (21::Int),"criticalSequence" .= sequenceNo
        ,"remoteDurabilityAcknowledged" .= False]
      tags=["ecx-bridge-critical","deployment:"<>identity,"sequence:"<>T.pack(show sequenceNo)]
      paths=[archivePath archive,manifestPath archive]
      run=resticJSON program repository password
  require (value==expected && checksum==archiveHash archive && sequenceNo>=0) "backup_archive_mismatch"
  messages<-run (["backup","--json"]<>concatMap (\tag->["--tag",T.unpack tag]) tags<>paths)
  records<-mapM decode (filter (not . BS.null) $ BS.split 10 messages)
  let summaries=[record | record@(Object fields)<-records, parseEither (.: "message_type") fields==Right ("summary"::Text)]
  snapshot<-case summaries of
    [summary]->member "snapshot_id" summary
    _->reject "backup_receipt_missing"
  require (T.length snapshot==64 && T.all (`elem` ("0123456789abcdef"::String)) snapshot) "invalid_backup_receipt"
  metadata<-run ["cat","snapshot",T.unpack snapshot] >>= decode
  savedPaths<-member "paths" metadata
  savedTags<-member "tags" metadata
  require (sort savedPaths==sort paths && all (`elem` (savedTags::[Text])) tags) "backup_snapshot_mismatch"
  downloaded<-run ["dump",T.unpack snapshot,manifestPath archive]
  require (downloaded==manifest) "backup_manifest_readback_mismatch"
  pure (BackupReceipt identity sequenceNo snapshot checksum)
 where
  decode bytes=either (const $ reject "invalid_backup_receipt") pure (eitherDecodeStrict' bytes)
  member :: FromJSON a => Key -> Value -> IO a
  member key value=either (const $ reject "invalid_backup_receipt") pure (parseEither (withObject "backup receipt" (.: key)) value)

-- One bounded stdout pipe; stderr is discarded without risking credentials in
-- errors. No shell, ambient repository/password override, cache or child workers.
resticJSON :: FilePath -> FilePath -> FilePath -> [String] -> IO BS.ByteString
resticJSON program repository password arguments = do
  inherited<-getEnvironment
  let environment=("GOMAXPROCS","2"):filter ((`elem` ["PATH","HOME","TMPDIR","LANG"]) . fst) inherited
      args=["--no-cache","--repository-file",repository,"--password-file",password]<>arguments
  withBinaryFile "/dev/null" WriteMode $ \sink->
    withCreateProcess (proc program args) {env=Just environment,std_in=NoStream,std_out=CreatePipe,std_err=UseHandle sink,close_fds=True} $ \_ output _ process->do
      let kill=do
            running<-getProcessExitCode process
            when (running==Nothing) $ getPid process >>= mapM_ (signalProcess sigKILL)
          action=case output of
            Nothing->reject "backup_process_pipe_missing"
            Just handle->do
              bytes<-readBounded handle 0 []
              code<-waitForProcess process
              require (code==ExitSuccess) "backup_process_failed"
              pure bytes
      result<-(timeout (300*1000000) action >>= maybe (kill >> reject "backup_process_timeout") pure) `onException` kill
      pure result
 where
  readBounded handle total chunks=do
    bytes<-BS.hGetSome handle 4096
    let size=total+BS.length bytes
    require (size<=4*1024*1024) "backup_response_too_large"
    if BS.null bytes then pure(BS.concat $ reverse chunks) else readBounded handle size (bytes:chunks)
