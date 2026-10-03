-- Private startup credential validation shared by signing and recovery.
module Bridge.Credentials (verifySigningKey,protectedSignerFile) where
import Bridge.Error
import Data.Text (Text)
import Bridge.Identity (publicKey)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.Aeson (eitherDecodeStrict')
import Data.Bits ((.&.))
import Data.Word (Word8)
import System.FilePath (isAbsolute,takeDirectory)
import System.IO (withBinaryFile,IOMode(ReadMode))
import System.Posix.Files
import System.Posix.User (getEffectiveUserID)

-- Secret files permit group read only for the shared auth token. Certificates
-- may be public, but neither they nor their parent may be replaced by that group.
protectedSignerFile :: FilePath -> Bool -> Bool -> IO ()
protectedSignerFile path secret shared = do
  require (isAbsolute path) "absolute_credential_path_required"
  uid<-getEffectiveUserID
  file<-getSymbolicLinkStatus path
  parent<-getFileStatus (takeDirectory path)
  let mode=fileMode file .&. 0o777
  require (isRegularFile file && fileOwner file `elem` [0,uid]
    && fileOwner parent `elem` [0,uid] && fileMode parent .&. 0o022==0
    && if secret then mode==0o600 || shared && mode==0o640 else mode .&. 0o022==0) "unsafe_signer_file_permissions"

-- Standard Solana CLI keypair: seed plus derived public key, never printed.
-- Validate before accepting requests; the SDK checks again when it signs.
verifySigningKey :: Text -> FilePath -> IO ()
verifySigningKey owner filename = do
  protectedSignerFile filename True False
  bytes<-withBinaryFile filename ReadMode (`BS.hGet` 4097)
  require (BS.length bytes<=4096) "signer_file_too_large"
  values<-either (const $ reject "invalid_signer_json") pure
    (eitherDecodeStrict' bytes :: Either String [Word8])
  require (length values==64) "invalid_signer_length"
  expected<-either reject pure (publicKey owner)
  let key=BS.pack values
  case Ed.secretKey (BS.take 32 key) of
    CryptoPassed secret->do
      let actual=BA.convert(Ed.toPublic secret) :: BS.ByteString
      require (actual==BS.drop 32 key && actual==expected) "signer_mismatch"
    CryptoFailed _->reject "invalid_signer"
