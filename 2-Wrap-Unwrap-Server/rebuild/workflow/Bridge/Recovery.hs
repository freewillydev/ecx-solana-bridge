{-# LANGUAGE GADTs #-}
-- Offline custody bundle. No HTTP route, signing capability or backup receipt.
-- The writer session is held across export, but no DB transaction spans RPC.
module Bridge.Recovery (CustodyRecovery(..),evalCustodyRecovery) where

import qualified Bridge.Config as C
import Bridge.Error
import Bridge.Identity (digest)
import qualified Bridge.Native as N
import Bridge.RPC (fieldValue)
import Bridge.Signer (verifySigningKey)
import Bridge.Store
import Control.Exception (bracket,bracketOnError)
import Control.Monad (forM,void)
import Crypto.Hash (Context,Digest,SHA256,hashInit,hashUpdate,hashFinalize)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import Network.HTTP.Client (Manager)
import System.Directory (removeDirectoryRecursive)
import System.FilePath (isAbsolute,normalise,takeDirectory,takeFileName,(</>))
import System.IO (Handle,hClose,hFlush)
import qualified System.Posix.Directory as PD
import System.Posix.Files
import System.Posix.IO hiding (sync)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

-- Credentials originate only at offline startup. Inspection needs neither a
-- database connection nor network access, so it remains usable after host loss.
data CustodyRecovery a where
  ExportCustody :: PG.ConnectInfo -> PG.ConnectInfo -> FilePath -> FilePath -> CustodyRecovery (FilePath,Int64)
  InspectCustody :: FilePath -> Int64 -> CustodyRecovery Int64

evalCustodyRecovery :: Manager -> C.Config -> CustodyRecovery a -> IO a
evalCustodyRecovery manager config operation = do
  C.validateConfig config
  let identity=C.fingerprint config
      native=C.nativeSettings config
      call=N.nativeCall manager native
  case operation of
    ExportCustody writerSettings readerSettings key parent -> do
      require (PG.connectHost writerSettings==PG.connectHost readerSettings
        && PG.connectPort writerSettings==PG.connectPort readerSettings
        && PG.connectDatabase writerSettings==PG.connectDatabase readerSettings) "custody_backup_database_mismatch"
      privateDirectory parent
      verifySigningKey (C.custodyOwner config) key
      withFencedWriter writerSettings (C.storePolicy config) (C.fenceDirectory config) $ \_ ->
       withReader readerSettings identity (C.backupRequired config) $ \reader->do
        before<-evalRead reader ReadState
        require (ledgerPaused before) "custody_backup_requires_pause"
        -- Check again after export so encryption during the snapshot cannot
        -- silently introduce a dependency on missing unlock material.
        let unencrypted=do
              wallet<-N.nativeWalletInfoWith call native
              require (case wallet of Object o->not(KM.member "unlocked_until" o); _->False)
                "encrypted_native_wallet_recovery_material_required"
        unencrypted
        suffix<-T.unpack . T.take 32 . digest <$> (getRandomBytes 16 :: IO BS.ByteString)
        let directory=parent </> "custody-"<>suffix
        bracketOnError (PD.createDirectory directory 0o700 >> pure directory) removeDirectoryRecursive $ \_->do
          keyBytes<-readPrivate 4096 key
          writePrivate (directory </> "solana-key.json") (BL.fromStrict keyBytes)
          verifySigningKey (C.custodyOwner config) (directory </> "solana-key.json")
          writePrivate (directory </> "deployment.json") (encode config)
          archive<-evalBackup reader (ExportLedger directory)
          void $ N.evalNativeRecoveryWith call native (N.BackupNativeWallet $ directory </> "native-wallet")
          unencrypted
          after<-evalRead reader ReadState
          require (ledgerPaused after && ledgerSequence before==ledgerSequence after
            && archiveSequence archive==ledgerSequence after) "custody_backup_changed"
          currentKey<-readPrivate 4096 key
          require (currentKey==keyBytes) "custody_backup_key_changed"
          files<-M.fromList <$> forM (bundleFiles archive) (\name->(,) name <$> hashFile (directory </> name))
          let manifest=directory </> "custody.json"
          writePrivate manifest (encode $ manifestValue identity (archiveSequence archive) (takeFileName $ manifestPath archive) files)
          sync directory
          sync parent
          pure (manifest,archiveSequence archive)
    InspectCustody manifest minimumSequence -> do
      require (minimumSequence>=0) "invalid_restore_policy"
      privateDirectory (takeDirectory manifest)
      bytes<-readPrivate 8192 manifest
      value<-either (const $ reject "invalid_custody_manifest") pure (eitherDecodeStrict' bytes)
      version<-fieldValue "format" value :: IO Int
      saved<-fieldValue "fingerprint" value
      sequenceNo<-fieldValue "criticalSequence" value
      ledger<-fieldValue "ledgerManifest" value
      files<-fieldValue "files" value
      require (version==1 && value==manifestValue saved sequenceNo ledger files
        && M.size files==6 && all basename (ledger:M.keys files)
        && all checksum (M.elems files)) "invalid_custody_manifest"
      require (saved==identity) "backup_identity_mismatch"
      require (sequenceNo>=minimumSequence) "backup_snapshot_too_old"
      let directory=takeDirectory manifest
          verify name expected=require (M.lookup name files==Just expected) "custody_backup_hash_mismatch"
      -- Each large archive is hashed once by its existing closed inspector.
      archive<-evalRestore PG.defaultConnectInfo (InspectLedger (directory </> ledger) identity minimumSequence)
      (wallet,nativePath,nativeHash)<-N.evalNativeRecoveryWith call native
        (N.InspectNativeWalletBackup $ directory </> "native-wallet.json")
      require (M.keys files==M.keys (M.fromList [(name,()) | name<-bundleFiles archive])
        && nativePath==directory </> "native-wallet" && wallet==C.nativeWallet config
        && archiveSequence archive==sequenceNo) "custody_backup_binding_mismatch"
      verify (takeFileName $ archivePath archive) (archiveHash archive)
      verify "native-wallet" nativeHash
      mapM_ (\name->hashFile (directory </> name) >>= verify name)
        [ledger,"native-wallet.json","deployment.json","solana-key.json"]
      savedConfig<-C.loadConfig (directory </> "deployment.json")
      require (C.fingerprint savedConfig==identity) "backup_identity_mismatch"
      verifySigningKey (C.custodyOwner config) (directory </> "solana-key.json")
      pure sequenceNo

bundleFiles :: LedgerArchive -> [FilePath]
bundleFiles archive=[takeFileName $ archivePath archive,takeFileName $ manifestPath archive,
  "native-wallet","native-wallet.json","deployment.json","solana-key.json"]
manifestValue :: Text -> Int64 -> FilePath -> M.Map FilePath Text -> Value
manifestValue identity sequenceNo ledger files=object
  ["format" .= (1::Int),"fingerprint" .= identity,"criticalSequence" .= sequenceNo
  ,"ledgerManifest" .= ledger,"files" .= files,"remoteDurabilityAcknowledged" .= False]
basename :: FilePath -> Bool
basename name=name==takeFileName name && name `notElem` ["",".",".."]
checksum :: Text -> Bool
checksum value=T.length value==64 && T.all (`elem` ("0123456789abcdef"::String)) value

privateDirectory :: FilePath -> IO ()
privateDirectory path=do
  require (isAbsolute path && normalise path==path) "invalid_custody_backup_directory"
  status<-getSymbolicLinkStatus path
  uid<-getEffectiveUserID
  require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_custody_backup_directory"
withPrivate :: FilePath -> (Handle -> IO a) -> IO a
withPrivate path action=do
  status<-getSymbolicLinkStatus path
  uid<-getEffectiveUserID
  require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o077==0
    && linkCount status==1) "unsafe_custody_backup_file"
  bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True} >>= fdToHandle) hClose action
readPrivate :: Int -> FilePath -> IO BS.ByteString
readPrivate limit path=withPrivate path $ \handle->do
  bytes<-BS.hGet handle (limit+1)
  require (BS.length bytes<=limit) "custody_backup_file_too_large"
  pure bytes
hashFile :: FilePath -> IO Text
hashFile path=withPrivate path (go hashInit)
 where
  go :: Context SHA256 -> Handle -> IO Text
  go context handle=do
    bytes<-BS.hGet handle 65536
    if BS.null bytes then pure (T.pack $ show (hashFinalize context :: Digest SHA256))
      else go (hashUpdate context bytes) handle
writePrivate :: FilePath -> BL.ByteString -> IO ()
writePrivate path bytes=do
  bracket (openFd path WriteOnly defaultFileFlags
    {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True} >>= fdToHandle) hClose $ \handle->do
      BL.hPut handle bytes
      hFlush handle
  sync path
sync :: FilePath -> IO ()
sync path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
