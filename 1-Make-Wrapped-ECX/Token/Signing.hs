{-# LANGUAGE GADTs #-}
-- Offline key creation and validated administration signing, saved before returning.
module Token.Signing (Critical(..),evalCritical,Saved(..),validateSaved) where
import Token
import Bridge.Error (require,reject)
import Bridge.SolanaMessage (Transaction(..),base58,publicKey,decodeTransaction)
import Bridge.AdminKey (readKey,savePrivate,privateParent,newPrivatePath)
import Crypto.Random (getRandomBytes)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson
import Control.Monad (unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import qualified Data.Text.Encoding as T

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
  GenerateKey :: FilePath -> Critical Text
  Sign :: FilePath -> FilePath -> Request -> Text -> Critical Text

evalCritical :: Critical a -> IO a
evalCritical (GenerateKey output)=do
  newPrivatePath output
  seed<-getRandomBytes 32 :: IO BA.ScrubbedBytes
  secret<-case Ed.secretKey seed of CryptoPassed key->pure key; _->reject "token_key_generation_failed"
  let public=BA.convert (Ed.toPublic secret) :: B.ByteString
      bytes=BA.convert seed<>public :: B.ByteString
  savePrivate output (L.toStrict $ encode $ B.unpack bytes)
  pure (base58 public)
evalCritical (Sign keyfile output request unsigned)=do
  Transaction _ _ message<-either reject pure (validate request unsigned)
  privateParent keyfile
  newPrivatePath output
  secret<-readKey (authority request) keyfile
  let signature=Ed.sign secret (Ed.toPublic secret) message
      signatureBytes=BA.convert signature :: B.ByteString
      identifier=base58 signatureBytes
      transaction=T.decodeUtf8 $ B64.encode (B.singleton 1<>signatureBytes<>message)
      record=L.toStrict $ encode $ object
        ["request" .= request,"signature" .= identifier,"transaction" .= transaction]
  require (Ed.verify (Ed.toPublic secret) message signature) "token_signature_invalid"
  savePrivate output record
  pure identifier
