-- Fixed local native-wallet file transfer. No signer API, keys, SQL or caller paths.
module Bridge.NativeBackup (request,send,receive) where
import Bridge.Error
import Bridge.File (withHandle,hashHandle)
import qualified Bridge.AdminKey as Private
import Control.Exception (bracket,bracketOnError,onException)
import Control.Monad (unless)
import Data.Binary.Get (runGet,getWord64be)
import Data.Binary.Put (runPut,putWord64be)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as SB
import System.IO
import System.Posix.Files
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID,getEffectiveGroupID)
import System.Timeout (timeout)
import System.FilePath (takeDirectory)

limit :: Integer
limit=268435456 -- 256 MiB, streamed with bounded memory.
token :: T.Text -> B.ByteString
token identity="ECX-NATIVE-BACKUP/1 "<>TE.encodeUtf8 identity<>"\n"

-- systemd supplies only an accepted connection on stdin/stdout. Read through EOF
-- before work; the peer cannot choose a file, wallet, RPC method or argument.
request :: T.Text -> IO ()
request identity=do
  hSetBinaryMode stdin True
  bytes<-B.hGet stdin 128
  require (bytes==token identity) "invalid_native_backup_request"

send :: FilePath -> IO ()
send path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd->do
  status<-getFdStatus fd
  uid<-getEffectiveUserID
  require (isRegularFile status && fileOwner status==uid && linkCount status==1
    && fileMode status .&. 0o777==0o600 && fileSize status>0 && toInteger(fileSize status)<=limit)
    "unsafe_native_backup_transfer"
  withHandle fd $ \input->do
    checksum<-hashHandle input
    hSeek input AbsoluteSeek 0
    hSetBinaryMode stdout True
    L.hPut stdout (runPut $ putWord64be $ fromIntegral $ fileSize status)
    B.hPut stdout (TE.encodeUtf8 checksum)
    copy (fromIntegral $ fileSize status) input stdout
    hFlush stdout

receive :: T.Text -> FilePath -> IO ()
receive identity destination=do
  Private.privateParent destination
  parent<-getSymbolicLinkStatus "/run/ecx-native-backup"
  endpoint<-getSymbolicLinkStatus "/run/ecx-native-backup/export.sock"
  group<-getEffectiveGroupID
  require (isDirectory parent && fileOwner parent==0 && fileMode parent .&. 0o022==0
    && isSocket endpoint && fileOwner endpoint==0 && fileGroup endpoint==group
    && fileMode endpoint .&. 0o777==0o660) "unsafe_native_backup_socket"
  let connect=bracketOnError (S.socket S.AF_UNIX S.Stream S.defaultProtocol) S.close $ \socket->do
        S.connect socket (S.SockAddrUnix "/run/ecx-native-backup/export.sock")
        SB.sendAll socket (token identity)
        S.shutdown socket S.ShutdownSend
        S.socketToHandle socket ReadMode
  result<-timeout 240000000 $ bracket connect hClose $ \handle->do
        header<-B.hGet handle 72
        require (B.length header==72) "native_backup_transfer_truncated"
        let size=runGet getWord64be (L.fromStrict $ B.take 8 header)
            checksum=B.drop 8 header
        require (size>0 && toInteger size<=limit && B.all (\c->c>=48 && c<=57 || c>=97 && c<=102) checksum)
          "invalid_native_backup_transfer_header"
        -- Only private output is ever supplied by the closed Native operation.
        bracket (openFd destination ReadWrite defaultFileFlags {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True}) closeFd
          (\fd->(withHandle fd $ \out->do
            copy (fromIntegral size) handle out
            trailing<-B.hGet handle 1
            require (B.null trailing) "native_backup_transfer_trailing_data"
            hFlush out
            hSeek out AbsoluteSeek 0
            actual<-hashHandle out
            require (TE.encodeUtf8 actual==checksum) "native_backup_transfer_hash_mismatch"
            fileSynchronise fd) `onException` removeLink destination)
        bracket (openFd (takeDirectory destination) ReadOnly defaultFileFlags) closeFd fileSynchronise
  require (result==Just ()) "native_backup_transfer_timeout"

copy :: Int -> Handle -> Handle -> IO ()
copy remaining input output=unless (remaining==0) $ do
  bytes<-B.hGet input (min 65536 remaining)
  require (not $ B.null bytes) "native_backup_transfer_truncated"
  B.hPut output bytes
  copy (remaining-B.length bytes) input output
