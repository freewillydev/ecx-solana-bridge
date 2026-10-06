-- Protected administration files shared by closed token and pool evaluators.
-- No signing or network authority is exposed here.
module Bridge.AdminKey (readKey,readPrivate,withFamily,savePrivate,privateParent,newPrivatePath) where
import Bridge.Error (require,reject)
import Bridge.File (withHandle,readBounded)
import Bridge.SolanaMessage (publicKey,base58)
import Control.Exception (bracket,finally)
import Crypto.Random (getRandomBytes)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson (eitherDecodeStrict')
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)
import System.FilePath (isAbsolute,takeDirectory,normalise)
import System.IO (hFlush,SeekMode(AbsoluteSeek))
import System.Posix.Files
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Posix.Types (Fd)

readKey :: Text -> FilePath -> IO Ed.SecretKey
readKey expectedOwner keyfile=do
  privateParent keyfile
  bracket (openFd keyfile ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd->do
    status<-getFdStatus fd
    uid<-getEffectiveUserID
    require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o777==0o600 && linkCount status==1) "unsafe_token_key"
    withHandle fd $ \handle->do
      bytes<-readBounded 4096 handle >>= maybe (reject "token_key_too_large") pure
      numbers<-either (const $ reject "invalid_token_key") pure
        (eitherDecodeStrict' bytes :: Either String [Integer])
      require (length numbers==64 && all (\n->n>=0 && n<=255) numbers) "invalid_token_key"
      let key=B.pack (map fromInteger numbers :: [Word8])
      case Ed.secretKey (B.take 32 key) of
        CryptoFailed _->reject "invalid_token_key"
        CryptoPassed value->do
          expected<-either reject pure (publicKey expectedOwner)
          require ((BA.convert (Ed.toPublic value)::B.ByteString)==expected && B.drop 32 key==expected) "token_authority_mismatch"
          pure value

-- Files become visible only after their complete bytes have reached storage.
-- Link publication is exclusive (rename would silently replace an old attempt).
savePrivate :: FilePath -> B.ByteString -> IO ()
savePrivate output record=do
  privateParent output
  require (B.length record<=8192) "administration_attempt_too_large"
  nonce<-getRandomBytes 16
  let staging=output<>".pending-"<>T.unpack(base58 nonce)
  bracket (openFd staging WriteOnly defaultFileFlags
    {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True})
    (\fd->closeFd fd `finally` (removeLink staging >> syncParent output)) $ \fd->do
      withHandle fd $ \handle->B.hPut handle record >> hFlush handle
      fileSynchronise fd
      createLink staging output
      syncParent output

-- A prior writer may have died after publication but before syncing its directory.
-- Sync the exact protected record before allowing a critical caller to submit it.
readPrivate :: FilePath -> IO B.ByteString
readPrivate path=do
  privateParent path
  bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd->do
    privateFile fd
    bytes<-withHandle fd (readBounded 8192) >>= maybe (reject "administration_attempt_too_large") pure
    fileSynchronise fd; syncParent path
    pure bytes

-- All mutation/submission of one retained attempt family takes this OS lock.
-- A typeclass cannot serialize concurrent CLI processes. Never unlink this file:
-- doing so could let another process lock a different inode for the same family.
withFamily :: FilePath -> IO a -> IO a
withFamily root action=do
  privateParent root
  bracket (openFd (root<>".lock") ReadWrite defaultFileFlags
    {creat=Just 0o600,nofollow=True,cloexec=True}) closeFd $ \fd->do
      privateFile fd
      setLock fd (WriteLock,AbsoluteSeek,0,0)
      action

privateFile :: Fd -> IO ()
privateFile fd=do
  status<-getFdStatus fd; uid<-getEffectiveUserID
  require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o777==0o600
    && linkCount status==1) "unsafe_administration_file"

syncParent :: FilePath -> IO ()
syncParent path=bracket (openFd (takeDirectory path) ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise

privateParent :: FilePath -> IO ()
privateParent path=do
  require (isAbsolute path && normalise path==path) "absolute_token_path_required"
  status<-getSymbolicLinkStatus (takeDirectory path)
  uid<-getEffectiveUserID
  require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_token_directory"

-- Fast rejection before RPC or signing; exclusive creation remains the final guard.
newPrivatePath :: FilePath -> IO ()
newPrivatePath path=do
  privateParent path
  exists<-fileExist path
  require (not exists) "private_output_already_exists"
