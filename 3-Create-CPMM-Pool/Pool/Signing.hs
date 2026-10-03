{-# LANGUAGE GADTs #-}
-- Only these closed operations read LP keys or submit a saved creation.
module Pool.Signing (Critical(..),evalCritical,Saved(..),validateSaved) where
import Pool
import Bridge.AdminKey (readKey,savePrivate,privateParent)
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.SolanaMessage (Transaction(..),Message(..),decodePoolTransaction,base58)
import Control.Exception (bracket)
import Control.Monad (unless,zipWithM)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Network.HTTP.Client (parseRequest,secure,closeManager)
import System.IO (withBinaryFile,IOMode(ReadMode))
import Text.Read (readMaybe)

data Saved = Saved {network :: Network,request :: Create,prepared :: Prepared,feeLimit :: Word64,costLimit :: Word64
  ,identifier :: Text,transaction :: Text} deriving (Eq,Show)
instance ToJSON Saved where
  toJSON s=object ["network" .= (case network s of Devnet->"devnet"; Mainnet->"mainnet"::Text)
    ,"request" .= request s,"prepared" .= prepared s,"feeLimit" .= show(feeLimit s),"costLimit" .= show(costLimit s)
    ,"signature" .= identifier s,"transaction" .= transaction s]
instance FromJSON Saved where
  parseJSON=withObject "saved pool creation" $ \o->do
    unless (length o==7) (fail "unexpected saved pool fields")
    name<-o .: "network" :: Parser Text
    selected<-case name of "devnet"->pure Devnet; "mainnet"->pure Mainnet; _->fail "unknown network"
    fee<-o .: "feeLimit" >>= amount; cost<-o .: "costLimit" >>= amount
    Saved selected <$> o .: "request" <*> o .: "prepared" <*> pure fee <*> pure cost <*> o .: "signature" <*> o .: "transaction"
   where
    amount text=case readMaybe text :: Maybe Integer of
      Just n | n>0 && n<=toInteger(maxBound::Word64) && show n==text->pure(fromInteger n)
      _->fail "invalid pool cost limit"

validateSaved :: Saved -> Either Text ()
validateSaved s=do
  Transaction _ _ expected<-validatePrepared (network s) (request s) (prepared s)
  Transaction signatures (Message _ _ _ keys _ _) message<-decodePoolTransaction(transaction s)
  unless (expected==message && feeLimit s>0 && costLimit s>=feeLimit s) (Left "pool_saved_message_or_policy_mismatch")
  valid<-zipWithM (verify message) (take 3 keys) signatures
  unless (and valid && case signatures of first:_->base58 first==identifier s; _->False) (Left "invalid_pool_signatures")
 where
  verify message key bytes=case (Ed.publicKey key,Ed.signature bytes) of
    (CryptoPassed public,CryptoPassed signature)->pure(Ed.verify public message signature)
    _->Left "invalid_pool_signature_encoding"

data Critical a where
  Sign :: FilePath -> Network -> String -> Word64 -> Word64 -> Create -> Prepared -> FilePath -> FilePath -> FilePath -> FilePath -> Critical Text
  Submit :: FilePath -> String -> FilePath -> Critical Value

evalCritical :: Critical a -> IO a
evalCritical (Sign library selected endpoint fee cost r p payerKey vaultKeyA vaultKeyB output)=do
  privateParent output
  _<-evalSafe (Check library selected endpoint fee cost r p)
  Transaction _ (Message _ _ _ keys _ _) message<-either reject pure (validatePrepared selected r p)
  let sources=[(payer r,payerKey),(createVaultA r,vaultKeyA),(createVaultB r,vaultKeyB)]
  signatures<-mapM (\key->do
    path<-maybe (reject "pool_signer_mismatch") pure (lookup (base58 key) sources)
    secret<-readKey (base58 key) path
    pure (BA.convert (Ed.sign secret (Ed.toPublic secret) message) :: B.ByteString)) (take 3 keys)
  first<-case signatures of a:_->pure a; _->reject "missing_pool_signature"
  let encoded=TE.decodeUtf8 $ B64.encode (B.singleton 3<>B.concat signatures<>message)
      saved=Saved selected r p fee cost (base58 first) encoded
  either reject pure (validateSaved saved)
  savePrivate output (L.toStrict $ encode saved)
  pure(identifier saved)
evalCritical (Submit library endpoint path)=do
  bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
  require (B.length bytes<=8192) "pool_attempt_too_large"
  saved<-either (const $ reject "invalid_pool_attempt") pure (eitherDecodeStrict' bytes)
  either reject pure (validateSaved saved)
  canonical<-evalSafe (Prepare library (network saved) (request saved))
  require (canonical==prepared saved) "pool_saved_derivation_mismatch"
  transport<-parseRequest endpoint
  require (secure transport) "pool_requires_https"
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
        name=identifier saved
        response state=object ["signature" .= name,"status" .= (state::Text)]
    genesis<-call "getGenesisHash" [] >>= parseValue parseJSON
    require (genesis==networkGenesis(network saved)) "wrong_pool_network"
    values<-call "getSignatureStatuses" [toJSON [name],object ["searchTransactionHistory" .= True]] >>= fieldValue "value" :: IO [Value]
    status<-case values of [value]->pure value; _->reject "invalid_pool_status"
    if status==Null then do
      _<-evalSafe (Check library (network saved) endpoint (feeLimit saved) (costLimit saved) (request saved) (prepared saved))
      returned<-call "sendTransaction" [toJSON(transaction saved),object
        ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("finalized"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
      require (returned==name) "pool_submission_identifier_mismatch"
      pure(response "submitted")
    else do
      commitment<-fieldValue "confirmationStatus" status :: IO (Maybe Text)
      if commitment/=Just "finalized" then pure(response "pending") else do
        result<-call "getTransaction" [toJSON name,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
        encoded<-fieldValue "transaction" result :: IO [Text]
        require (encoded==[transaction saved,"base64"]) "pool_finalized_bytes_mismatch"
        meta<-fieldValue "meta" result
        failure<-fieldValue "err" meta :: IO Value
        statusFailure<-fieldValue "err" status :: IO Value
        fee<-fieldValue "fee" meta :: IO Integer
        before<-fieldValue "preBalances" meta :: IO [Integer]
        after<-fieldValue "postBalances" meta :: IO [Integer]
        require (failure==statusFailure && fee>=0 && fee<=toInteger(feeLimit saved)
          && case (before,after) of (a:_,b:_)->a>=b && b>=0 && a-b>=fee && a-b<=toInteger(costLimit saved); _->False)
          "pool_finalized_cost_or_status_mismatch"
        pure(response $ if failure==Null then "finalized" else "failed")
