{-# LANGUAGE GADTs #-}
-- Key creation and pure saved-intent validation. Network owns signing authority.
module Token.Signing (Critical(..),evalCritical,Saved(..),validateSaved,validateSuccessorSaved) where
import Token
import Bridge.Error (reject)
import Bridge.SolanaMessage (Transaction(..),base58,publicKey,decodeTransaction)
import Bridge.AdminKey (savePrivate,newPrivatePath)
import Bridge.AdminStatus (Recovery(..),validateRecovery,validateSuccessor)
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

evalCritical :: Critical a -> IO a
evalCritical (GenerateKey output)=do
  newPrivatePath output
  seed<-getRandomBytes 32 :: IO BA.ScrubbedBytes
  secret<-case Ed.secretKey seed of CryptoPassed key->pure key; _->reject "token_key_generation_failed"
  let public=BA.convert (Ed.toPublic secret) :: B.ByteString
      bytes=BA.convert seed<>public :: B.ByteString
  savePrivate output (L.toStrict $ encode $ B.unpack bytes)
  pure (base58 public)
