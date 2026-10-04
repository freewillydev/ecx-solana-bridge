{-# LANGUAGE ScopedTypeVariables,DeriveGeneric #-}
-- Private archive mechanics. Only Store's closed backup evaluator supplies the
-- exported snapshot and metadata; no SQL or remote acknowledgment lives here.
module Bridge.Store.Backup (LedgerArchive(..),archiveLedger,RemoteBackup,loadRemoteBackup,uploadRemoteArchive,BackupReceipt(..),uploadArchive,loadLedgerArchive,restoreLedger,discardRestore,downloadRemoteArchive,downloadArchive
  , CustodyArchive(..),loadCustodyArchive,uploadRemoteCustody,uploadCustodyArchive,downloadRemoteCustody,downloadCustodyArchive) where

import Bridge.Wire (BackupReceipt(..))
import Bridge.Error
import Bridge.Identity (digest)
import Control.Exception (IOException,bracket,bracketOnError,catch,onException,mask)
import Control.Monad (when,void)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base16 as Hex
import Crypto.Hash (Context,Digest,SHA256,hashInit,hashUpdate,hashFinalize)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.List (isPrefixOf,isSuffixOf,sort)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types (Identifier(..))
import System.Directory (removeFile,removeDirectoryRecursive)
import qualified System.Posix.Directory as PosixDirectory
import GHC.Generics (Generic)
import qualified Network.HTTP.Client as HTTP
import qualified Network.Socket as Socket
import qualified Data.Text.Encoding as TE
import System.Posix.Signals (signalProcess,sigKILL)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..))
import System.FilePath (isAbsolute,normalise,takeFileName,takeDirectory,(</>))
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
  privateDirectory directory
  require (not(T.null snapshot) && T.length snapshot<=128 && T.all (`elem` ("0123456789abcdefABCDEF-"::String)) snapshot) "invalid_backup_snapshot"
  let run=databaseTool settings
      cleanup (path,handle) = do
        hClose handle `catch` (\(_::IOException)->pure ())
        removeFile path
      syncFile path = bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
  bracketOnError (openBinaryTempFile directory "ledger.dump-") cleanup $ \(path,handle) -> do
    setFileMode path 0o600
    run "pg_dump" ["--format=custom","--no-owner","--no-privileges","--no-password","--snapshot="<>T.unpack snapshot] (UseHandle handle)
    hClose handle
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

privateDirectory :: FilePath -> IO ()
privateDirectory directory = do
  require (isAbsolute directory && normalise directory==directory) "invalid_backup_directory"
  status<-getSymbolicLinkStatus directory
  uid<-getEffectiveUserID
  require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_backup_directory"

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
  validated<-loadLedgerArchive (archiveIdentity archive) 0 (manifestPath archive)
  require (validated==archive) "backup_archive_mismatch"
  manifest<-readPrivate (manifestPath archive)
  let identity=archiveIdentity archive; sequenceNo=archiveSequence archive
      tags=["ecx-bridge-critical","deployment:"<>identity,"sequence:"<>T.pack(show sequenceNo)]
  snapshot<-uploadFiles program repository password tags [archivePath archive,manifestPath archive] (manifestPath archive) manifest
  pure (BackupReceipt identity sequenceNo snapshot $ archiveHash archive)

-- Private fixed-file transport shared by the two closed archive operations.
-- Neither callers nor manifests can choose a restic command or extraction path.
uploadFiles :: FilePath -> FilePath -> FilePath -> [Text] -> [FilePath] -> FilePath -> BS.ByteString -> IO Text
uploadFiles program repository password tags paths manifestPath manifest = do
  mapM_ privateFile paths
  let run=resticJSON program repository password
  messages<-run (["backup","--json"]<>concatMap (\tag->["--tag",T.unpack tag]) tags<>paths)
  records<-mapM decodeReceipt (filter (not . BS.null) $ BS.split 10 messages)
  let summaries=[record | record@(Object fields)<-records, parseEither (.: "message_type") fields==Right ("summary"::Text)]
  snapshot<-case summaries of
    [summary]->receiptField "snapshot_id" summary
    _->reject "backup_receipt_missing"
  require (T.length snapshot==64 && T.all (`elem` ("0123456789abcdef"::String)) snapshot) "invalid_backup_receipt"
  metadata<-run ["cat","snapshot",T.unpack snapshot] >>= decodeReceipt
  savedPaths<-receiptField "paths" metadata
  savedTags<-receiptField "tags" metadata
  require (sort savedPaths==sort paths && all (`elem` (savedTags::[Text])) tags) "backup_snapshot_mismatch"
  downloaded<-run ["dump",T.unpack snapshot,manifestPath]
  require (downloaded==manifest) "backup_manifest_readback_mismatch"
  pure snapshot

decodeReceipt :: BS.ByteString -> IO Value
decodeReceipt bytes=either (const $ reject "invalid_backup_receipt") pure (eitherDecodeStrict' bytes)
receiptField :: FromJSON a => Key -> Value -> IO a
receiptField key value=either (const $ reject "invalid_backup_receipt") pure (parseEither (withObject "backup receipt" (.: key)) value)

-- One bounded stdout pipe; stderr is discarded without risking credentials in
-- errors. No shell, ambient repository/password override, cache or child workers.
resticJSON :: FilePath -> FilePath -> FilePath -> [String] -> IO BS.ByteString
resticJSON program repository password arguments = do
  inherited<-getEnvironment
  let environment=("GOMAXPROCS","2"):filter ((`elem` ["PATH","HOME","TMPDIR","LANG"]) . fst) inherited
      readOnly=case arguments of command:_->command `elem` ["cat","dump"]; _->False
      args=["--no-cache"]<>["--no-lock" | readOnly]<>["--repository-file",repository,"--password-file",password]<>arguments
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

-- Validate a trusted private manifest before any restore DDL. A checksum binds
-- contents; provenance comes from protected local custody or authenticated restic.
loadLedgerArchive :: Text -> Int64 -> FilePath -> IO LedgerArchive
loadLedgerArchive identity minimumSequence manifest = do
  require (minimumSequence>=0 && not(T.null identity)) "invalid_restore_policy"
  privateDirectory (takeDirectory manifest)
  bytes<-readPrivate manifest
  archive<-manifestArchive identity minimumSequence manifest bytes
  privateFile (archivePath archive)
  actual<-withBinaryFile (archivePath archive) ReadMode (hashChunks hashInit)
  require (archiveHash archive==actual) "backup_archive_mismatch"
  pure archive

manifestArchive :: Text -> Int64 -> FilePath -> BS.ByteString -> IO LedgerArchive
manifestArchive identity minimumSequence manifest bytes = do
  require (BS.length bytes<=8192) "backup_file_too_large"
  value<-either (const $ reject "invalid_backup_manifest") pure (eitherDecodeStrict' bytes)
  (version,name,checksum,saved,schema,sequenceNo,remote)<-
    either (const $ reject "invalid_backup_manifest") pure $ parseEither
      (withObject "ledger manifest" $ \o->(,,,,,,) <$> o .: "format" <*> o .: "archive" <*> o .: "sha256"
        <*> o .: "fingerprint" <*> o .: "schemaVersion" <*> o .: "criticalSequence" <*> o .: "remoteDurabilityAcknowledged") value
  require (version==(2::Int) && schema==(21::Int) && not remote && sequenceNo>=0
    && name==takeFileName name && name `notElem` ["",".",".."])
    "invalid_backup_manifest"
  require (saved==identity) "backup_identity_mismatch"
  require (sequenceNo>=minimumSequence) "backup_snapshot_too_old"
  let path=takeDirectory manifest</>name
      expected=object ["format" .= version,"archive" .= name,"sha256" .= (checksum::Text)
        ,"fingerprint" .= (saved::Text),"schemaVersion" .= schema,"criticalSequence" .= (sequenceNo::Int64)
        ,"remoteDurabilityAcknowledged" .= remote]
  require (value==expected) "invalid_backup_manifest"
  pure (LedgerArchive path manifest checksum saved sequenceNo)

-- Authentication is provided by restic; only these two bound files are fetched,
-- never a directory/tree extraction or an archive-selected local destination.
downloadRemoteArchive :: RemoteBackup -> Text -> Text -> Int64 -> FilePath -> IO LedgerArchive
downloadRemoteArchive remote=downloadArchive (restic remote) (repositoryFile remote) (passwordFile remote)

downloadArchive :: FilePath -> FilePath -> FilePath -> Text -> Text -> Int64 -> FilePath -> IO LedgerArchive
downloadArchive program repository password snapshot identity minimumSequence directory = do
  require (isAbsolute program) "invalid_backup_configuration"
  require (T.length snapshot==64 && T.all (`elem` ("0123456789abcdef"::String)) snapshot) "invalid_backup_snapshot"
  require (minimumSequence>=0 && not(T.null identity)) "invalid_restore_policy"
  privateDirectory directory
  privateFile repository
  privateFile password
  let run=resticJSON program repository password
  metadata<-run ["cat","snapshot",T.unpack snapshot] >>= decodeReceipt
  paths<-receiptField "paths" metadata
  tags<-receiptField "tags" metadata
  require (length paths==2 && all (\path->isAbsolute path && normalise path==path) paths) "backup_snapshot_mismatch"
  (archiveSource,manifestSource)<-case ([path | path<-paths,".dump-" `isSuffixOf` path],[path | path<-paths,".manifest-" `isSuffixOf` path]) of
    ([archive],[manifest]) | takeDirectory archive==takeDirectory manifest -> pure(archive,manifest)
    _->reject "backup_snapshot_mismatch"
  manifestBytes<-run ["dump",T.unpack snapshot,manifestSource]
  suffix<-TE.decodeUtf8 . Hex.encode <$> (getRandomBytes 16 :: IO BS.ByteString)
  let stage=directory</>"recovery-"<>T.unpack suffix
      manifest=stage</>takeFileName manifestSource
      writePrivate path bytes=bracket
        (openFd path WriteOnly defaultFileFlags {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True} >>= fdToHandle)
        hClose (\handle->BS.hPut handle bytes)
  archive<-manifestArchive identity minimumSequence manifest manifestBytes
  let expectedTags=["ecx-bridge-critical","deployment:"<>identity,"sequence:"<>T.pack(show $ archiveSequence archive)]
  require (takeFileName(archivePath archive)==takeFileName archiveSource && all (`elem` (tags::[Text])) expectedTags) "backup_snapshot_mismatch"
  bracketOnError (PosixDirectory.createDirectory stage 0o700 >> pure stage) removeDirectoryRecursive $ \_->do
    writePrivate manifest manifestBytes
    writePrivate (archivePath archive) BS.empty
    _<-run ["dump",T.unpack snapshot,archiveSource,"--target",archivePath archive]
    loadLedgerArchive identity minimumSequence manifest

-- Seven fixed files, or eight for an encrypted native wallet, share one grammar for
-- transport. Parsing establishes paths/identity, not semantic recovery authority.
data CustodyArchive = CustodyArchive
  { custodyManifest :: FilePath, custodyIdentity :: Text, custodySequence :: Int64
  , custodyLedger :: FilePath, custodyFiles :: M.Map FilePath Text, custodyEncrypted :: Bool } deriving (Eq,Show)
instance ToJSON CustodyArchive where
  toJSON archive=object $ ["format" .= (if custodyEncrypted archive then 2 else 1::Int),"fingerprint" .= custodyIdentity archive
    ,"criticalSequence" .= custodySequence archive,"ledgerManifest" .= custodyLedger archive
    ,"files" .= custodyFiles archive,"remoteDurabilityAcknowledged" .= False]
    <> ["nativeEncrypted" .= True | custodyEncrypted archive]

loadCustodyArchive :: Text -> Int64 -> FilePath -> IO CustodyArchive
loadCustodyArchive identity minimumSequence manifest = do
  privateDirectory (takeDirectory manifest)
  readPrivate manifest >>= custodyArchive identity minimumSequence manifest
custodyArchive :: Text -> Int64 -> FilePath -> BS.ByteString -> IO CustodyArchive
custodyArchive identity minimumSequence manifest bytes = do
  require (minimumSequence>=0 && not(T.null identity)) "invalid_restore_policy"
  require (BS.length bytes<=8192) "backup_file_too_large"
  value<-either (const $ reject "invalid_custody_manifest") pure (eitherDecodeStrict' bytes)
  (saved,n,ledger,files,encrypted)<-either (const $ reject "invalid_custody_manifest") pure $
    parseEither (withObject "custody manifest" $ \o->(,,,,) <$> o .: "fingerprint" <*> o .: "criticalSequence"
      <*> o .: "ledgerManifest" <*> o .: "files" <*> o .:? "nativeEncrypted" .!= False) value
  let archive=CustodyArchive manifest saved n ledger files encrypted
      basename name=name==takeFileName name && name `notElem` ["",".",".."]
      checksum value=T.length value==64 && T.all (`elem` ("0123456789abcdef"::String)) value
      dumps=filter (".dump-" `isSuffixOf`) (M.keys files)
  require (takeFileName manifest=="custody.json" && value==toJSON archive && all basename (M.keys files) && all checksum (M.elems files)
    && ".manifest-" `isSuffixOf` ledger && length dumps==1
    && sort(M.keys files)==sort([ledger,"native-wallet","native-wallet.json","deployment.json","solana-key.json"]<>dumps<>["native-unlock" | encrypted]))
    "invalid_custody_manifest"
  require (saved==identity) "backup_identity_mismatch"
  require (n>=minimumSequence) "backup_snapshot_too_old"
  pure archive

uploadRemoteCustody :: RemoteBackup -> CustodyArchive -> IO BackupReceipt
uploadRemoteCustody remote=uploadCustodyArchive (restic remote) (repositoryFile remote) (passwordFile remote)
uploadCustodyArchive :: FilePath -> FilePath -> FilePath -> CustodyArchive -> IO BackupReceipt
uploadCustodyArchive program repository password archive = do
  require (isAbsolute program) "invalid_backup_configuration"
  mapM_ privateFile [repository,password]
  actual<-loadCustodyArchive (custodyIdentity archive) (custodySequence archive) (custodyManifest archive)
  require (actual==archive) "custody_backup_binding_mismatch"
  bytes<-readPrivate (custodyManifest archive)
  let paths=custodyManifest archive:map (takeDirectory(custodyManifest archive)</>) (M.keys $ custodyFiles archive)
  snapshot<-uploadFiles program repository password (custodyTags archive) paths (custodyManifest archive) bytes
  pure (BackupReceipt (custodyIdentity archive) (custodySequence archive) snapshot $ digest bytes)

custodyTags :: CustodyArchive -> [Text]
custodyTags archive=["ecx-bridge-custody","deployment:"<>custodyIdentity archive,"sequence:"<>T.pack(show $ custodySequence archive)]
downloadRemoteCustody :: RemoteBackup -> Text -> Text -> Int64 -> FilePath -> IO CustodyArchive
downloadRemoteCustody remote=downloadCustodyArchive (restic remote) (repositoryFile remote) (passwordFile remote)
downloadCustodyArchive :: FilePath -> FilePath -> FilePath -> Text -> Text -> Int64 -> FilePath -> IO CustodyArchive
downloadCustodyArchive program repository password snapshot identity minimumSequence directory = do
  require (isAbsolute program) "invalid_backup_configuration"
  require (T.length snapshot==64 && T.all (`elem` ("0123456789abcdef"::String)) snapshot) "invalid_backup_snapshot"
  require (minimumSequence>=0 && not(T.null identity)) "invalid_restore_policy"
  privateDirectory directory
  mapM_ privateFile [repository,password]
  let run=resticJSON program repository password
  metadata<-run ["cat","snapshot",T.unpack snapshot] >>= decodeReceipt
  paths<-receiptField "paths" metadata
  tags<-receiptField "tags" metadata
  require (length paths `elem` [7,8] && all (\path->isAbsolute path && normalise path==path) paths) "backup_snapshot_mismatch"
  source<-case filter ((=="custody.json").takeFileName) paths of
    [manifest]->pure manifest
    _->reject "backup_snapshot_mismatch"
  bytes<-run ["dump",T.unpack snapshot,source]
  suffix<-TE.decodeUtf8 . Hex.encode <$> (getRandomBytes 16 :: IO BS.ByteString)
  let stage=directory</>"custody-recovery-"<>T.unpack suffix
      manifest=stage</>"custody.json"
      writePrivate path contents=bracket
        (openFd path WriteOnly defaultFileFlags {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True} >>= fdToHandle)
        hClose (\handle->BS.hPut handle contents)
      sync path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
  archive<-custodyArchive identity minimumSequence manifest bytes
  require (sort paths==sort(source:map (takeDirectory source</>) (M.keys $ custodyFiles archive))
    && all (`elem` (tags::[Text])) (custodyTags archive)) "backup_snapshot_mismatch"
  bracketOnError (PosixDirectory.createDirectory stage 0o700 >> pure stage) removeDirectoryRecursive $ \_->do
    mapM_ (\name->do
      let target=stage</>name
      writePrivate target BS.empty
      _<-run ["dump",T.unpack snapshot,takeDirectory source</>name,"--target",target]
      privateFile target
      sync target) (M.keys $ custodyFiles archive)
    writePrivate manifest bytes
    sync manifest
    sync stage
    sync directory
    -- The custody evaluator validates every component before returning success.
    pure archive

-- Explicit offline schema infrastructure. Generated names, template0 and revoked
-- PUBLIC access isolate staging; never restore into a caller-selected database.
-- No financial row query/update lives here, and no existing database is dropped.
restoreLedger :: PG.ConnectInfo -> LedgerArchive -> IO PG.ConnectInfo
restoreLedger settings archive = mask $ \restore->do
  suffix<-TE.decodeUtf8 . Hex.encode <$> (getRandomBytes 16 :: IO BS.ByteString)
  let target=settings {PG.connectDatabase="ecx_restore_"<>T.unpack suffix}
      name=PG.Only $ Identifier $ T.pack $ PG.connectDatabase target
  bracket (PG.connect settings {PG.connectDatabase="postgres"}) PG.close $ \admin->do
    void $ PG.execute admin "CREATE DATABASE ? WITH TEMPLATE template0 ALLOW_CONNECTIONS false" name
    (restore $ do
      void $ PG.execute admin "REVOKE ALL ON DATABASE ? FROM PUBLIC" name
      void $ PG.execute admin "ALTER DATABASE ? ALLOW_CONNECTIONS true" name
      withBinaryFile "/dev/null" WriteMode $ \sink->databaseTool target "pg_restore"
        ["--exit-on-error","--single-transaction","--no-owner","--no-privileges","--no-password"
        ,"--dbname="<>PG.connectDatabase target,archivePath archive] (UseHandle sink)
      pure target) `onException` void (PG.execute admin "DROP DATABASE ?" name)

-- Only the freshly generated staging identity may be discarded after a failed
-- verification. No FORCE: unexpected connections require operator inspection.
discardRestore :: PG.ConnectInfo -> IO ()
discardRestore settings = do
  let name=T.pack $ PG.connectDatabase settings
  require (T.length name==44 && "ecx_restore_" `T.isPrefixOf` name
    && T.all (`elem` ("0123456789abcdef"::String)) (T.drop 12 name)) "invalid_restore_database"
  bracket (PG.connect settings {PG.connectDatabase="postgres"}) PG.close $ \admin->
    void $ PG.execute admin "DROP DATABASE ?" (PG.Only $ Identifier name)

databaseTool :: PG.ConnectInfo -> FilePath -> [String] -> StdStream -> IO ()
databaseTool settings program arguments output = do
  inherited<-getEnvironment
  let environment=[("PGHOST",PG.connectHost settings),("PGPORT",show $ PG.connectPort settings)
        ,("PGDATABASE",PG.connectDatabase settings),("PGUSER",PG.connectUser settings)
        ,("PGPASSWORD",PG.connectPassword settings),("PGCONNECT_TIMEOUT","10")]
        <>filter (not . isPrefixOf "PG" . fst) inherited
  withCreateProcess (proc program arguments)
    {env=Just environment,std_in=NoStream,std_out=output,std_err=NoStream,close_fds=True} $ \_ _ _ process->do
      let kill=getProcessExitCode process >>= \state->when (state==Nothing) (getPid process >>= mapM_ (signalProcess sigKILL))
      (do
        result<-timeout (300*1000000) (waitForProcess process)
        when (result==Nothing) kill
        require (result==Just ExitSuccess) "ledger_archive_process_failed") `onException` kill
