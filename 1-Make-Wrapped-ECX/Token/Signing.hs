{-# LANGUAGE GADTs #-}
-- Offline key import/signing; no RPC or custody capabilities.
module Token.Signing (Critical(..),evalCritical,Saved(..),validateSaved,validateSuccessorSaved) where
import Token
import Bridge.Error (reject)
import Bridge.SolanaMessage (Transaction(..),base58,publicKey,decodeTransaction)
import Bridge.AdminKey (readPrivate,readKey,savePrivate,newPrivatePath)
import Bridge.AdminStatus (Recovery(..),validateRecovery,validateSuccessor)
import Crypto.Random (getRandomBytes)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson
import Control.Monad (unless)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Base58 as B58
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Data.Char (isSpace)

data Saved = Saved
  { savedRequest :: Request, savedId :: Text, savedTransaction :: Text
  , savedRecovery :: Maybe Recovery } deriving (Eq,Show)
instance ToJSON Saved where
  toJSON saved=object $ ["request" .= savedRequest saved,"signature" .= savedId saved,"transaction" .= savedTransaction saved]
    <>["recovery" .= recovery | Just recovery<-[savedRecovery saved]]
instance FromJSON Saved where
  parseJSON=withObject "signed token operation" $ \o->do
    recovery<-o .:? "recovery"
    unless (length o==case recovery of Nothing->3; Just _->4) (fail "Unexpected saved-operation fields")
    Saved <$> o .: "request" <*> o .: "signature" <*> o .: "transaction" <*> pure recovery

-- Verify both the signature and its exact request before using an archived file.
validateSaved :: Saved -> Either Text Text
validateSaved (Saved request identifier encoded recovery)=do
  case (request,recovery) of
    (NonceMint{},Just _)->Left "nonce_recovery_context_forbidden"
    _->pure ()
  mapM_ (\context->validateRecovery (recoveryGenesis context) (authority request)
    (recoveryFeeLimit context) (blockhash request) context) recovery
  Transaction signatures _ message<-decodeTransaction encoded
  let unsigned=T.decodeUtf8 $ B64.encode (B.singleton 1<>B.replicate 64 0<>message)
  _<-validate request unsigned
  owner<-publicKey (authority request)
  case (signatures,Ed.publicKey owner) of
    ([bytes],CryptoPassed key)->case Ed.signature bytes of
      CryptoPassed signature | base58 bytes==identifier && Ed.verify key message signature -> pure unsigned
      _->Left "invalid_token_signature"
    _->Left "invalid_token_signature"

-- A new blockhash is the only permitted change to the operation itself.
validateSuccessorSaved :: Saved -> Text -> Saved -> Either Text ()
validateSuccessorSaved parent parentHash child=do
  _<-validateSaved parent
  _<-validateSaved child
  before<-maybe (Left "token_recovery_context_required") Right (savedRecovery parent)
  after<-maybe (Left "token_recovery_context_required") Right (savedRecovery child)
  validateSuccessor before parentHash after
  unless ((savedRequest parent) {blockhash=blockhash(savedRequest child)}==savedRequest child)
    (Left "token_recovery_intent_mismatch")

data Critical a where
  GenerateKey :: FilePath -> Critical Text
  ImportKey :: FilePath -> FilePath -> Critical Text
  SignOffline :: FilePath -> Request -> Text -> FilePath -> Critical Text

evalCritical :: Critical a -> IO a
evalCritical (GenerateKey output)=do
  newPrivatePath output
  seed<-getRandomBytes 32 :: IO BA.ScrubbedBytes
  secret<-case Ed.secretKey seed of CryptoPassed key->pure key; _->reject "token_key_generation_failed"
  let public=BA.convert (Ed.toPublic secret) :: B.ByteString
      bytes=BA.convert seed<>public :: B.ByteString
  savePrivate output (L.toStrict $ encode $ B.unpack bytes)
  pure (base58 public)
evalCritical (ImportKey input output)=do
  newPrivatePath output
  exported<-readPrivate input
  let trimmed=B8.dropWhileEnd isSpace (B8.dropWhile isSpace exported)
  unless (B.length trimmed>=64 && B.length trimmed<=88)
    (reject "expected_base58_solana_64_byte_private_key")
  bytes<-case B58.decodeBase58 B58.bitcoinAlphabet trimmed of
    Just bytes | B.length bytes==64->pure bytes
    _->reject "expected_base58_solana_64_byte_private_key"
  secret<-case Ed.secretKey (B.take 32 bytes) of
    CryptoPassed key->pure key
    _->reject "invalid_imported_key"
  let public=BA.convert (Ed.toPublic secret) :: B.ByteString
  unless (B.drop 32 bytes==public) (reject "imported_key_public_half_mismatch")
  savePrivate output (L.toStrict $ encode $ B.unpack bytes)
  pure (base58 public)
evalCritical (SignOffline keyfile request unsigned output)=do
  newPrivatePath output
  Transaction _ _ message<-either reject pure (validate request unsigned)
  secret<-readKey (authority request) keyfile
  let signature=BA.convert (Ed.sign secret (Ed.toPublic secret) message) :: B.ByteString
      identifier=base58 signature
      signed=T.decodeUtf8 $ B64.encode (B.singleton 1<>signature<>message)
      saved=Saved request identifier signed Nothing
  _<-either reject pure (validateSaved saved)
  savePrivate output (L.toStrict $ encode saved)
  pure identifier
