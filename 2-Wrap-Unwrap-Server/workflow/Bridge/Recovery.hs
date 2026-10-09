{-# LANGUAGE GADTs #-}
-- Closed custody recovery. The signer may export with read-only authority;
-- only the worker can acknowledge a checkpoint. No DB transaction spans RPC.
module Bridge.Recovery (CustodyRecovery(..),evalCustodyRecovery) where

import qualified Bridge.Config as C
import Bridge.Error
import Bridge.Identity (digest)
import Bridge.File (withHandle,readBounded,hashHandle)
import qualified Bridge.Native as N
import Bridge.Credentials (verifySigningKey,readNativeUnlock,withNativeUnlock)
import Bridge.Store
import Control.Exception (bracket,bracketOnError)
import Control.Monad (forM,forM_,void,when)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import Network.HTTP.Client (Manager)
import System.Directory (removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.FilePath (isAbsolute,normalise,takeDirectory,takeFileName,(</>))
import System.IO (Handle,hFlush)
import qualified System.Posix.Directory as PD
import System.Posix.Files
import System.Posix.IO hiding (sync)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

-- Credentials originate only at process startup. Inspection needs neither a
-- database connection nor network access, so it remains usable after host loss.
data CustodyRecovery a where
  ExportCustody :: PG.ConnectInfo -> PG.ConnectInfo -> FilePath -> FilePath -> CustodyRecovery (FilePath,Int64)
  ExportCheckpoint :: Reader -> FilePath -> FilePath -> Int64 -> CustodyRecovery (FilePath,Int64)
  InspectCustody :: FilePath -> Int64 -> CustodyRecovery Int64
  UploadCustody :: FilePath -> FilePath -> Int64 -> CustodyRecovery BackupReceipt
  RecoverCustody :: FilePath -> Text -> FilePath -> Int64 -> CustodyRecovery (FilePath,Int64)

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
      withFencedWriter writerSettings (C.storePolicy config) (C.fenceDirectory config) $ \_ ->
        withReader readerSettings identity (C.backupRequired config) $ \reader->export True reader key parent 0
    ExportCheckpoint reader key parent minimumSequence -> export False reader key parent minimumSequence
    InspectCustody manifest minimumSequence -> do
      metadata<-evalRestore PG.defaultConnectInfo (InspectCustodyFiles manifest identity minimumSequence)
      let sequenceNo=custodySequence metadata; ledger=custodyLedger metadata; files=custodyFiles metadata
          encrypted=custodyEncrypted metadata
          directory=takeDirectory manifest
          verify name expected=require (M.lookup name files==Just expected) "custody_backup_hash_mismatch"
      -- Each large archive is hashed once by its existing closed inspector.
      archive<-evalRestore PG.defaultConnectInfo (InspectLedger (directory </> ledger) identity minimumSequence)
      (wallet,nativePath,nativeHash)<-N.evalNativeRecoveryWith call native
        (N.InspectNativeWalletBackup $ directory </> "native-wallet.json")
      require (M.keys files==M.keys (M.fromList [(name,()) | name<-bundleFiles archive encrypted])
        && nativePath==directory </> "native-wallet" && wallet==C.nativeWallet config
        && archiveSequence archive==sequenceNo) "custody_backup_binding_mismatch"
      verify (takeFileName $ archivePath archive) (archiveHash archive)
      verify "native-wallet" nativeHash
      mapM_ (\name->hashFile (directory </> name) >>= verify name)
        ([ledger,"native-wallet.json","deployment.json","solana-key.json"]<>["native-unlock" | encrypted])
      savedConfig<-C.loadConfig (directory </> "deployment.json")
      require (C.fingerprint savedConfig==identity) "backup_identity_mismatch"
      require (isJust(C.nativeUnlockFile savedConfig)==encrypted) "custody_backup_binding_mismatch"
      -- Configuration records its old operational path; inspection uses only
      -- the bound copy, so recovery remains offline after moving the bundle.
      when encrypted $ void $ readNativeUnlock (directory </> "native-unlock")
      verifySigningKey (C.custodyOwner config) (directory </> "solana-key.json")
      pure sequenceNo
    UploadCustody configuration manifest minimumSequence -> do
      sequenceNo<-evalCustodyRecovery manager config (InspectCustody manifest minimumSequence)
      originalHash<-digest <$> readPrivate 8192 manifest
      archive<-evalRestore PG.defaultConnectInfo (InspectCustodyFiles manifest identity sequenceNo)
      receipt<-evalRestore PG.defaultConnectInfo (UploadCustodyFiles configuration archive)
      require (receiptIdentity receipt==identity && receiptSequence receipt==sequenceNo
        && receiptArchiveHash receipt==originalHash) "custody_backup_binding_mismatch"
      -- Download and validate the complete encrypted snapshot before reporting
      -- success. A manifest-only readback is not evidence of recoverable keys.
      bracket (evalCustodyRecovery manager config $ RecoverCustody configuration (receiptSnapshot receipt) (takeDirectory manifest) sequenceNo)
        (removeDirectoryRecursive . takeDirectory . fst) $ \(recovered,n)->do
          actualHash<-digest <$> readPrivate 8192 recovered
          require (n==sequenceNo && actualHash==originalHash) "custody_backup_binding_mismatch"
      pure receipt
    RecoverCustody configuration snapshot directory minimumSequence ->
      bracketOnError (evalRestore PG.defaultConnectInfo $ DownloadCustodyFiles configuration snapshot identity minimumSequence directory)
        (removeDirectoryRecursive . takeDirectory . custodyManifest) $ \archive->do
          n<-evalCustodyRecovery manager config (InspectCustody (custodyManifest archive) minimumSequence)
          pure (custodyManifest archive,n)

 where
  export offline reader key parent minimumSequence=do
    privateDirectory parent
    verifySigningKey (C.custodyOwner config) key
    let identity=C.fingerprint config; native=C.nativeSettings config; call=N.nativeCall manager native
    before<-evalRead reader ReadState
    require (minimumSequence>=0 && ledgerSequence before>=minimumSequence) "invalid_custody_checkpoint"
    require (not offline || ledgerPaused before) "custody_backup_requires_pause"
    -- Validate the copied secret and recheck after export. Wallet administration
    -- must be quiescent: before/after checks cannot detect an A-to-B-to-A change.
    let unlockMaterial=do
          wallet<-N.nativeWalletInfoWith call native
          let encrypted=case wallet of Object o->KM.member "unlocked_until" o; _->False
          require (not encrypted || isJust(C.nativeUnlockFile config))
            "encrypted_native_wallet_recovery_material_required"
          traverse readNativeUnlock (C.nativeUnlockFile config)
    unlock<-unlockMaterial
    let encrypted=isJust unlock
    suffix<-T.unpack . T.take 32 . digest <$> (getRandomBytes 16 :: IO BS.ByteString)
    let directory=parent </> "custody-"<>suffix
    bracketOnError (PD.createDirectory directory 0o700 >> pure directory) removeDirectoryRecursive $ \_->do
      keyBytes<-readPrivate 4096 key
      writePrivate (directory </> "solana-key.json") (BL.fromStrict keyBytes)
      verifySigningKey (C.custodyOwner config) (directory </> "solana-key.json")
      writePrivate (directory </> "deployment.json") (encode config)
      forM_ unlock $ writePrivate (directory </> "native-unlock") . BL.fromStrict . TE.encodeUtf8
      let validateUnlock=withNativeUnlock call native ((const $ directory </> "native-unlock") <$> unlock) (pure ())
      validateUnlock
      archive<-evalBackup reader (ExportLedger directory)
      transfer<-lookupEnv "ECX_NATIVE_BACKUP_SERVICE"
      require (transfer `elem` [Nothing,Just "1"]) "invalid_native_backup_service_setting"
      let backup=if transfer==Just "1" then N.ReceiveNativeWalletBackup else N.BackupNativeWallet
      void $ N.evalNativeRecoveryWith call native (backup $ directory </> "native-wallet")
      validateUnlock
      currentUnlock<-unlockMaterial
      require (currentUnlock==unlock) "custody_backup_key_changed"
      after<-evalRead reader ReadState
      require ((not offline || ledgerPaused after) && ledgerSequence before==ledgerSequence after
        && archiveSequence archive==ledgerSequence after && archiveIdentity archive==identity) "custody_backup_changed"
      currentKey<-readPrivate 4096 key
      require (currentKey==keyBytes) "custody_backup_key_changed"
      files<-M.fromList <$> forM (bundleFiles archive encrypted) (\name->(,) name <$> hashFile (directory </> name))
      let manifest=directory </> "custody.json"
      writePrivate manifest (encode $ CustodyArchive manifest identity (archiveSequence archive) (takeFileName $ manifestPath archive) files encrypted)
      sync directory
      sync parent
      pure (manifest,archiveSequence archive)

bundleFiles :: LedgerArchive -> Bool -> [FilePath]
bundleFiles archive encrypted=[takeFileName $ archivePath archive,takeFileName $ manifestPath archive,
  "native-wallet","native-wallet.json","deployment.json","solana-key.json"]<>["native-unlock" | encrypted]

privateDirectory :: FilePath -> IO ()
privateDirectory path=do
  require (isAbsolute path && normalise path==path) "invalid_custody_backup_directory"
  status<-getSymbolicLinkStatus path
  uid<-getEffectiveUserID
  require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_custody_backup_directory"
withPrivate :: FilePath -> (Handle -> IO a) -> IO a
withPrivate path action=do
  getSymbolicLinkStatus path >>= privateStatus
  bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd->do
    getFdStatus fd >>= privateStatus
    withHandle fd action
 where
  privateStatus status=do
    uid<-getEffectiveUserID
    require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o077==0
      && linkCount status==1) "unsafe_custody_backup_file"
readPrivate :: Int -> FilePath -> IO BS.ByteString
readPrivate limit path=withPrivate path (readBounded limit) >>= maybe (reject "custody_backup_file_too_large") pure
hashFile :: FilePath -> IO Text
hashFile path=withPrivate path hashHandle
writePrivate :: FilePath -> BL.ByteString -> IO ()
writePrivate path bytes=do
  bracket (openFd path WriteOnly defaultFileFlags
    {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True}) closeFd $ \fd->do
      withHandle fd $ \handle->BL.hPut handle bytes >> hFlush handle
      fileSynchronise fd
sync :: FilePath -> IO ()
sync path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
