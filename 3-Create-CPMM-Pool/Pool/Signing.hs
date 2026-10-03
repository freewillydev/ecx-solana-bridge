{-# LANGUAGE GADTs #-}
-- Only these closed operations read LP keys or submit a saved creation.
module Pool.Signing (Action(..),Critical(..),evalCritical,Saved(..),validateSaved) where
import Pool
import qualified Pool.Position as P
import qualified Pool.Liquidity as Q
import Bridge.AdminKey (readKey,savePrivate,newPrivatePath)
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.SolanaMessage (Transaction(..),Message(..),decodePoolTransaction,decodePositionTransaction,decodeLiquidityTransaction,base58)
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

-- Closed alternatives share execution without a sign-arbitrary-message operation.
data Action = Creation Create Prepared | Opening P.Request P.Prepared | Liquidity Q.Request Q.Prepared deriving (Eq,Show)
data Saved = Saved {network :: Network,action :: Action,feeLimit :: Word64,costLimit :: Word64
  ,identifier :: Text,transaction :: Text} deriving (Eq,Show)
instance ToJSON Saved where
  toJSON s=object $ ["network" .= (case network s of Devnet->"devnet"; Mainnet->"mainnet"::Text)
    ,"feeLimit" .= show(feeLimit s),"costLimit" .= show(costLimit s),"signature" .= identifier s,"transaction" .= transaction s]
    <> case action s of
      Creation r p->["request" .= r,"prepared" .= p]
      Opening r p->["operation" .= ("open-position"::Text),"request" .= r,"prepared" .= p]
      Liquidity r p->["operation" .= ("liquidity"::Text),"request" .= r,"prepared" .= p]
instance FromJSON Saved where
  parseJSON=withObject "saved pool creation" $ \o->do
    kind<-o .:? "operation" :: Parser (Maybe Text)
    operation<-case kind of
      Nothing | length o==7->Creation <$> o .: "request" <*> o .: "prepared"
      Just "open-position" | length o==8->Opening <$> o .: "request" <*> o .: "prepared"
      Just "liquidity" | length o==8->Liquidity <$> o .: "request" <*> o .: "prepared"
      _->fail "unexpected saved operation fields"
    name<-o .: "network" :: Parser Text
    selected<-case name of "devnet"->pure Devnet; "mainnet"->pure Mainnet; _->fail "unknown network"
    fee<-o .: "feeLimit" >>= amount; cost<-o .: "costLimit" >>= amount
    Saved selected operation fee cost <$> o .: "signature" <*> o .: "transaction"
   where
    amount text=case readMaybe text :: Maybe Integer of
      Just n | n>0 && n<=toInteger(maxBound::Word64) && show n==text->pure(fromInteger n)
      _->fail "invalid pool cost limit"

validateSaved :: Saved -> Either Text ()
validateSaved s=do
  Transaction _ _ expected<-validateAction (network s) (action s)
  Transaction signatures (Message _ _ _ keys _ _) message<-decodeAction (action s) (transaction s)
  unless (expected==message && feeLimit s>0 && costLimit s>=feeLimit s) (Left "pool_saved_message_or_policy_mismatch")
  valid<-zipWithM (verify message) (take (length signatures) keys) signatures
  unless (and valid && case signatures of first:_->base58 first==identifier s; _->False) (Left "invalid_pool_signatures")
 where
  verify message key bytes=case (Ed.publicKey key,Ed.signature bytes) of
    (CryptoPassed public,CryptoPassed signature)->pure(Ed.verify public message signature)
    _->Left "invalid_pool_signature_encoding"

validateAction :: Network -> Action -> Either Text Transaction
validateAction selected (Creation r p)=validatePrepared selected r p
validateAction _ (Opening r p)=P.validate r p
validateAction _ (Liquidity r p)=Q.validate r p
decodeAction :: Action -> Text -> Either Text Transaction
decodeAction Creation{}=decodePoolTransaction
decodeAction Opening{}=decodePositionTransaction
decodeAction Liquidity{}=decodeLiquidityTransaction
checkAction :: FilePath -> Network -> String -> Word64 -> Word64 -> Action -> IO ()
checkAction library selected endpoint fee cost operation=case operation of
  Creation r p->evalSafe (Check library selected endpoint fee cost r p) >> pure ()
  Opening r p->P.evalSafe (P.Check library selected endpoint fee cost r p) >> pure ()
  Liquidity r p->Q.evalSafe (Q.Check library selected endpoint fee cost r p) >> pure ()
checkDerivation :: FilePath -> Network -> Action -> IO ()
checkDerivation library selected operation=do
  matches<-case operation of
    Creation r p->(==p) <$> evalSafe (Prepare library selected r)
    Opening r p->(==p) <$> P.evalSafe (P.Prepare library r)
    Liquidity r p->(==p) <$> Q.evalSafe (Q.Prepare library r)
  require matches "pool_saved_derivation_mismatch"

data Critical a where
  Sign :: FilePath -> Network -> String -> Word64 -> Word64 -> Action -> [FilePath] -> FilePath -> Critical Text
  Submit :: FilePath -> String -> FilePath -> Critical Value

evalCritical :: Critical a -> IO a
evalCritical (Sign library selected endpoint fee cost operation keyfiles output)=do
  newPrivatePath output
  checkAction library selected endpoint fee cost operation
  Transaction _ (Message _ _ _ keys _ _) message<-either reject pure (validateAction selected operation)
  let owners=case operation of Creation r _->[payer r,createVaultA r,createVaultB r]; Opening r _->[P.payer r,P.positionMint r]; Liquidity r _->[P.payer $ Q.positionRequest r]
      sources=zip owners keyfiles
  require (length keyfiles==length owners) "pool_signer_count_mismatch"
  signatures<-mapM (\key->do
    path<-maybe (reject "pool_signer_mismatch") pure (lookup (base58 key) sources)
    secret<-readKey (base58 key) path
    pure (BA.convert (Ed.sign secret (Ed.toPublic secret) message) :: B.ByteString)) (take (length owners) keys)
  first<-case signatures of a:_->pure a; _->reject "missing_pool_signature"
  let encoded=TE.decodeUtf8 $ B64.encode (B.singleton (fromIntegral $ length signatures)<>B.concat signatures<>message)
      saved=Saved selected operation fee cost (base58 first) encoded
  either reject pure (validateSaved saved)
  savePrivate output (L.toStrict $ encode saved)
  pure(identifier saved)
evalCritical (Submit library endpoint path)=do
  bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
  require (B.length bytes<=8192) "pool_attempt_too_large"
  saved<-either (const $ reject "invalid_pool_attempt") pure (eitherDecodeStrict' bytes)
  either reject pure (validateSaved saved)
  checkDerivation library (network saved) (action saved)
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
      checkAction library (network saved) endpoint (feeLimit saved) (costLimit saved) (action saved)
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
