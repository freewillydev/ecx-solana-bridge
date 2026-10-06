-- Private startup credential validation shared by signing and recovery.
module Bridge.Credentials (verifySigningKey,protectedSignerFile,readSignerAuth,readSignerCertificate,readNativeUnlock,withNativeUnlock) where
import Bridge.Error
import Bridge.File (withHandle,readBounded)
import qualified Bridge.Native as N
import Bridge.NativePayment (NativeRPC)
import Bridge.RPC (parseValue)
import Control.Exception (bracket,finally)
import Data.Text (Text)
import Bridge.Identity (publicKey)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.Aeson (eitherDecodeStrict',Value(..),withObject,(.:?))
import Data.Bits ((.&.))
import Data.Word (Word8)
import Data.Int (Int64)
import Data.Maybe (isJust)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.FilePath (isAbsolute,takeDirectory)
import System.Posix.Files
import System.Posix.IO
import System.Posix.User (getEffectiveUserID)

-- Secret files permit group read only for the shared auth token. Certificates
-- may be public, but neither they nor their parent may be replaced by that group.
protectedSignerFile :: FilePath -> Bool -> Bool -> IO ()
protectedSignerFile path secret shared = do
  require (isAbsolute path) "absolute_credential_path_required"
  uid<-getEffectiveUserID
  file<-getSymbolicLinkStatus path
  parent<-getFileStatus (takeDirectory path)
  require (isDirectory parent && fileOwner parent `elem` [0,uid] && fileMode parent .&. 0o022==0) "unsafe_signer_file_permissions"
  signerStatus secret shared file

signerStatus :: Bool -> Bool -> FileStatus -> IO ()
signerStatus secret shared file = do
  uid<-getEffectiveUserID
  let mode=fileMode file .&. 0o777
  require (isRegularFile file && fileOwner file `elem` [0,uid] && linkCount file==1
    && if secret then mode==0o600 || shared && mode==0o640 else mode .&. 0o022==0) "unsafe_signer_file_permissions"

-- Policy selection stays private; exported readers have fixed purpose/bounds.
readSignerMaterial :: Bool -> Bool -> Int -> Text -> FilePath -> IO BS.ByteString
readSignerMaterial secret shared limit tooLarge path = do
  protectedSignerFile path secret shared
  bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd->do
    getFdStatus fd >>= signerStatus secret shared
    withHandle fd (readBounded limit) >>= maybe (reject tooLarge) pure

readSignerAuth, readSignerCertificate :: FilePath -> IO BS.ByteString
readSignerAuth = readSignerMaterial True True 65 "invalid_signer_auth_token"
readSignerCertificate = readSignerMaterial False False 8192 "signer_certificate_too_large"

-- Preserve the exact passphrase; line-oriented files are intentionally refused.
-- Validate the opened descriptor too, so pathname checks cannot authorize a replacement.
readNativeUnlock :: FilePath -> IO Text
readNativeUnlock filename = do
  bytes<-readSignerMaterial True False 1024 "invalid_native_unlock_file" filename
  require (not(BS.null bytes) && not(BS.any (`elem` [0,10,13]) bytes)) "invalid_native_unlock_file"
  either (const $ reject "invalid_native_unlock_file") pure (TE.decodeUtf8' bytes)

-- Only the private signer/recovery interpreters supply this scoped capability.
-- The node's finite lease bounds exposure after process loss. Cleanup also runs
-- when an unlock reply is lost; an uncertain outcome never permits signing.
withNativeUnlock :: NativeRPC -> N.NativeSettings -> Maybe FilePath -> IO a -> IO a
withNativeUnlock call native unlock action = case unlock of
  Nothing->ready >> action
  Just filename->do
    wallet<-N.nativeWalletKeysWith call native
    encrypted<-parseValue (withObject "wallet" (.:? "unlocked_until")) wallet :: IO (Maybe Int64)
    require (isJust encrypted) "native_unlock_requires_encrypted_wallet"
    secret<-readNativeUnlock filename
    let request method arguments=call True method arguments >>= \value->require (value==Null) "unexpected_rpc_schema"
    (request "walletpassphrase" [String secret,Number 120] >> ready >> action)
      `finally` request "walletlock" []
 where
  ready=(floor <$> getPOSIXTime) >>= N.nativeWalletReadyWith call native

-- Standard Solana CLI keypair: seed plus derived public key, never printed.
-- Validate before accepting requests; the SDK checks again when it signs.
verifySigningKey :: Text -> FilePath -> IO ()
verifySigningKey owner filename = do
  bytes<-readSignerMaterial True False 4096 "signer_file_too_large" filename
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
