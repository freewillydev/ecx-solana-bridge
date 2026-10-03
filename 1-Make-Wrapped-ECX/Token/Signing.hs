{-# LANGUAGE GADTs #-}
-- Offline authority: only validated mint/burn messages, saved before returning.
module Token.Signing (Critical(..),evalCritical,Saved(..),validateSaved) where
import Token
import Bridge.Error (require,reject)
import Bridge.SolanaMessage (Transaction(..),base58,publicKey,decodeTransaction)
import Control.Exception (bracket,bracketOnError)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson
import Control.Monad (unless)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Data.Word (Word8)
import System.FilePath (isAbsolute,takeDirectory,normalise)
import System.IO (hClose,hFlush)
import System.Posix.Files
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

data Saved = Saved { savedRequest :: Request, savedId :: Text, savedTransaction :: Text } deriving (Eq,Show)
instance FromJSON Saved where
  parseJSON=withObject "signed token operation" $ \o->do
    unless (length o==3) (fail "Unexpected saved-operation fields")
    Saved <$> o .: "request" <*> o .: "signature" <*> o .: "transaction"

-- Verify both the signature and its exact request before using an archived file.
validateSaved :: Saved -> Either Text Text
validateSaved (Saved request identifier encoded)=do
  Transaction signatures _ message<-decodeTransaction encoded
  let unsigned=T.decodeUtf8 $ B64.encode (B.singleton 1<>B.replicate 64 0<>message)
  _<-validate request unsigned
  owner<-publicKey (authority request)
  case (signatures,Ed.publicKey owner) of
    ([bytes],CryptoPassed key)->case Ed.signature bytes of
      CryptoPassed signature | base58 bytes==identifier && Ed.verify key message signature -> pure unsigned
      _->Left "invalid_token_signature"
    _->Left "invalid_token_signature"

data Critical a where
  Sign :: FilePath -> FilePath -> Request -> Text -> Critical Text

evalCritical :: Critical a -> IO a
evalCritical (Sign keyfile output request unsigned)=do
  Transaction _ _ message<-either reject pure (validate request unsigned)
  privateParent keyfile
  privateParent output
  secret<-bracket (openFd keyfile ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd $ \fd->do
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
          expected<-either reject pure (publicKey $ authority request)
          require ((BA.convert (Ed.toPublic value)::B.ByteString)==expected && B.drop 32 key==expected) "token_authority_mismatch"
          pure value
  let signature=Ed.sign secret (Ed.toPublic secret) message
      signatureBytes=BA.convert signature :: B.ByteString
      identifier=base58 signatureBytes
      transaction=T.decodeUtf8 $ B64.encode (B.singleton 1<>signatureBytes<>message)
      record=L.toStrict $ encode $ object
        ["request" .= request,"signature" .= identifier,"transaction" .= transaction]
  require (Ed.verify (Ed.toPublic secret) message signature) "token_signature_invalid"
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
  pure identifier

privateParent :: FilePath -> IO ()
privateParent path=do
  require (isAbsolute path && normalise path==path) "absolute_token_path_required"
  status<-getSymbolicLinkStatus (takeDirectory path)
  uid<-getEffectiveUserID
  require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_token_directory"
