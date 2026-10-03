-- Protected administration files shared by closed token and pool evaluators.
-- No signing or network authority is exposed here.
module Bridge.AdminKey (readKey,savePrivate,privateParent) where
import Bridge.Error (require,reject)
import Bridge.SolanaMessage (publicKey)
import Control.Exception (bracket,bracketOnError)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson (eitherDecodeStrict')
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import Data.Text (Text)
import Data.Word (Word8)
import System.FilePath (isAbsolute,takeDirectory,normalise)
import System.IO (hClose,hFlush)
import System.Posix.Files
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

readKey :: Text -> FilePath -> IO Ed.SecretKey
readKey expectedOwner keyfile=do
  privateParent keyfile
  bracket (openFd keyfile ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd $ \fd->do
    status<-getFdStatus fd
    uid<-getEffectiveUserID
    require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o777==0o600) "unsafe_token_key"
    bracket (dup fd >>= fdToHandle) hClose $ \handle->do
      bytes<-B.hGet handle 4097
      require (B.length bytes<=4096) "token_key_too_large"
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

-- Internal file plumbing; operation evaluators decide what may be saved.
savePrivate :: FilePath -> B.ByteString -> IO ()
savePrivate output record=do
  privateParent output
  -- Exclusive creation refuses retries with a different blockhash or amount.
  -- Keep even a partial file on failure: operators must inspect, never overwrite.
  bracket (openFd output WriteOnly defaultFileFlags
    {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True}) closeFd $ \fd->
      bracketOnError (dup fd >>= fdToHandle) hClose $ \handle->do
        B.hPut handle record
        hFlush handle
        fileSynchronise fd
        hClose handle
  bracket (openFd (takeDirectory output) ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise

privateParent :: FilePath -> IO ()
privateParent path=do
  require (isAbsolute path && normalise path==path) "absolute_token_path_required"
  status<-getSymbolicLinkStatus (takeDirectory path)
  uid<-getEffectiveUserID
  require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_token_directory"
