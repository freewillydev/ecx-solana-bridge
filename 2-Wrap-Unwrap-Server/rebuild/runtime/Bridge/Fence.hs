{-# LANGUAGE ForeignFunctionInterface,ScopedTypeVariables #-}
module Bridge.Fence (initializeFence,retireFence,withFence) where

import Bridge.Error
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (when)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Bits ((.&.))
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.C.Types (CInt(..))
import System.Directory
import System.FilePath
import System.IO
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
import System.Posix.IO
import System.Posix.Types (Fd(..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

-- flock uses an open-file-description lock on the supported macOS/Ubuntu
-- hosts. Unlike process-scoped fcntl locks, two opens in one process conflict.
-- LOCK_EX | LOCK_NB = 2 | 4 on both supported platforms; close releases it.
foreign import ccall unsafe "flock" flock :: CInt -> CInt -> IO CInt

data State = State Text Int64 Bool
instance ToJSON State where
  toJSON (State identity sequenceNo retired)=object["format" .= (1::Int),"fingerprint" .= identity,"sequence" .= sequenceNo,"retired" .= retired]
instance FromJSON State where
  parseJSON=withObject "worker fence" $ \o->do
    version <- o .: "format" :: Parser Int
    identity <- o .: "fingerprint"
    sequenceNo <- o .: "sequence"
    retired <- o .:? "retired" .!= False
    if version==1 && sequenceNo>=0 then pure(State identity sequenceNo retired) else fail "invalid worker fence"

privateStatus :: Bool -> FileStatus -> IO ()
privateStatus directory status=do
  uid <- getEffectiveUserID
  require ((if directory then isDirectory status else isRegularFile status) &&
    fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_worker_fence_permissions"

withLock :: FilePath -> IO a -> IO a
withLock directory action=do
  require (isAbsolute directory && normalise directory==directory) "invalid_worker_fence_directory"
  getSymbolicLinkStatus directory >>= privateStatus True
  bracket (openFd (directory </> "worker.lock") ReadWrite defaultFileFlags
    {creat=Just 0o600,nofollow=True,cloexec=True}) closeFd $ \fd@(Fd descriptor)->do
      getFdStatus fd >>= privateStatus False
      result <- flock descriptor 6
      require (result==0) "worker_fence_locked"
      action

readState :: FilePath -> IO State
readState directory=bracket (openFd (directory </> "sequence.json") ReadOnly defaultFileFlags
  {nofollow=True,cloexec=True} >>= fdToHandle) hClose $ \handle->do
    bytes <- BS.hGet handle 8193
    require (BS.length bytes<=8192) "invalid_worker_fence_state"
    either (const $ reject "invalid_worker_fence_state") pure (eitherDecodeStrict' bytes)

validateState :: FilePath -> Text -> IO Int64
validateState directory identity=do
  getSymbolicLinkStatus (directory </> "sequence.json") >>= privateStatus False
  State saved sequenceNo retired <- readState directory
  require (saved==identity) "worker_fence_identity_mismatch"
  require (not retired) "worker_fence_retired"
  pure sequenceNo

writeState :: FilePath -> State -> IO ()
writeState directory state=mask_ $ bracketOnError (openBinaryTempFile directory ".sequence-")
  (\(path,handle)->do
    hClose handle `catch` (\(_::IOException)->pure ())
    removeFile path `catch` (\(_::IOException)->pure ())) $ \(path,handle)->do
      setFileMode path 0o600
      LBS.hPut handle (encode state)
      hFlush handle
      fd <- handleToFd handle
      bracket (pure fd) closeFd fileSynchronise
      renameFile path (directory </> "sequence.json")
      bracket (openFd directory ReadOnly defaultFileFlags {nofollow=True,cloexec=True,directory=True}) closeFd fileSynchronise

-- Deliberate first initialization only. Never replace/lower an existing fence,
-- and never include this host-local watermark in ledger rollback archives.
initializeFence :: FilePath -> Text -> Int64 -> IO ()
initializeFence directory identity sequenceNo=do
  require (sequenceNo>=0 && T.length identity==64 && T.all (`elem` ("0123456789abcdef"::String)) identity) "invalid_worker_fence_initialization"
  require (isAbsolute directory && normalise directory==directory) "invalid_worker_fence_directory"
  createDirectoryIfMissing True directory
  status <- getSymbolicLinkStatus directory
  uid <- getEffectiveUserID
  require (isDirectory status && fileOwner status==uid) "unsafe_worker_fence_permissions"
  setFileMode directory 0o700
  withLock directory $ do
    existing <- try(getSymbolicLinkStatus $ directory </> "sequence.json") :: IO(Either IOException FileStatus)
    require (case existing of Left err->isDoesNotExistError err; _->False) "worker_fence_already_initialized"
    writeState directory (State identity sequenceNo False)

-- Explicit offline retirement. A subsequent initializer cannot erase it.
-- This disables cooperating paying workers, not other software holding a key.
retireFence :: FilePath -> Text -> Int64 -> IO ()
retireFence directory identity sequenceNo=withLock directory $ do
  getSymbolicLinkStatus (directory </> "sequence.json") >>= privateStatus False
  State saved previous retired <- readState directory
  require (saved==identity) "worker_fence_identity_mismatch"
  require (sequenceNo>=previous) "stale_ledger_below_worker_fence"
  require (not retired || sequenceNo==previous) "worker_fence_already_retired"
  when (not retired) $ writeState directory (State identity sequenceNo True)

-- The callback runs BEFORE committing any new critical sequence. If commit
-- becomes uncertain after this fsync, refuse the older database on restart;
-- never silently lower the watermark to improve availability.
withFence :: FilePath -> Text -> ((Int64 -> IO ()) -> IO a) -> IO a
withFence directory identity action=do
  initialized <- doesPathExist(directory </> "sequence.json")
  require initialized "worker_fence_not_initialized"
  withLock directory $ do
    initial <- validateState directory identity
    watermark <- newMVar initial
    action $ \sequenceNo->modifyMVar_ watermark $ \previous->do
      require (sequenceNo>=previous) "stale_ledger_below_worker_fence"
      when (sequenceNo>previous) $ writeState directory (State identity sequenceNo False)
      pure sequenceNo
