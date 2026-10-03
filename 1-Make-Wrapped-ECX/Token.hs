{-# LANGUAGE GADTs, ForeignFunctionInterface #-}
-- Administration has no custody credential, database or generic instruction input.
module Token (Action(..),Request(..),Safe(..),evalSafe,validate,mintAddress) where
import Bridge.Error (require,reject)
import Bridge.Solana (tokenProgram)
import Bridge.SolanaMessage
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson
import Crypto.Hash (hash,Digest,SHA256)
import qualified Data.ByteArray as BA
import qualified Data.Text.Encoding as TE
import Text.Read (readMaybe)
import Data.Binary.Put (runPut,putWord8,putWord32le,putWord64le,putByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import qualified Data.Text as T
import Foreign
import Foreign.C.Types
import System.Posix.DynamicLinker

data Action = Mint | Burn deriving (Eq,Show)
data Request = Request
  { action :: Action, authority :: Text, mint :: Text, account :: Text
  , quantity :: Word64, blockhash :: Text }
  | CreateMint {authority :: Text,mint :: Text,seed :: Text,rent :: Word64,blockhash :: Text}
  deriving (Eq,Show)

instance ToJSON Request where
  toJSON CreateMint{authority=owner,mint=key,seed=label,rent=lamports,blockhash=recent}=object
    ["protocol" .= (1::Int),"verb" .= ("create"::Text),"authority" .= owner,"mint" .= key
    ,"seed" .= label,"rent" .= T.pack(show lamports),"blockhash" .= recent]
  toJSON request=object
    ["protocol" .= (1::Int),"verb" .= (if action request==Mint then "mint" else "burn"::Text)
    ,"authority" .= authority request,"mint" .= mint request,"account" .= account request
    ,"amount" .= T.pack(show $ quantity request),"blockhash" .= blockhash request]
instance FromJSON Request where
  parseJSON=withObject "token preparation" $ \o->do
    protocol<-o .: "protocol"
    verb<-o .: "verb"
    raw<-o .: (if verb==("create"::Text) then "rent" else "amount")
    unless (length o==7 && protocol==(1::Int)) (fail "invalid_token_protocol")
    n<-case readMaybe (T.unpack raw) :: Maybe Integer of
      Just x | x>0 && x<=toInteger(maxBound::Word64) && T.pack(show x)==raw -> pure(fromInteger x)
      _->fail "invalid_token_amount"
    case (verb::Text) of
      "create"->CreateMint <$> o .: "authority" <*> o .: "mint" <*> o .: "seed" <*> pure n <*> o .: "blockhash"
      _->do
        operation<-case verb of "mint"->pure Mint; "burn"->pure Burn; _->fail "invalid_token_operation"
        Request operation <$> o .: "authority" <*> o .: "mint" <*> o .: "account" <*> pure n <*> o .: "blockhash"

data Safe a where
  Prepare :: FilePath -> Request -> Safe Text

evalSafe :: Safe a -> IO a
evalSafe (Prepare library request)=do
  either reject pure $ case request of
    CreateMint{seed=label,rent=n}->do
      derived<-mintAddress (authority request) label
      unless (derived==mint request && n>0) (Left "invalid_mint_creation")
    Request{quantity=n,account=address}->unless (n>0) (Left "invalid_token_amount") >> publicKey address >> pure ()
  mapM_ (either reject (const $ pure ()) . publicKey)
    [authority request,mint request,blockhash request]
  output<-invoke library (L.toStrict $ encode request)
  transaction<-either (const $ reject "invalid_token_sdk_reply") pure (eitherDecodeStrict' output)
  either reject (const $ pure transaction) (validate request transaction)

-- Independently check the SDK's entire message: one zero signature, exact keys,
-- writable roles, program, instruction, blockhash, integer amount and decimals.
validate :: Request -> Text -> Either Text Transaction
validate request@CreateMint{} encoded=do
  owner<-publicKey (authority request)
  key<-publicKey (mint request)
  token<-publicKey tokenProgram
  system<-publicKey "11111111111111111111111111111111"
  recent<-publicKey (blockhash request)
  derived<-mintAddress (authority request) (seed request)
  unless (derived==mint request && rent request>0) (Left "invalid_mint_creation")
  transaction<-decodeTransaction encoded
  case transaction of
    Transaction [signature] (Message 1 0 2 keys@[payer,created,_,_] recentHash instructions) _ -> do
      let bytes=TE.encodeUtf8 (seed request)
          creation=L.toStrict $ runPut $ do
            putWord32le 3; putByteString owner; putWord64le (fromIntegral $ B.length bytes)
            putByteString bytes; putWord64le (rent request); putWord64le 82; putByteString token
          initialization=B.pack [20,8]<>owner<>B.singleton 0
          expand (Instruction program indexes payload)=(lookup program (zip [0..] keys),traverse (flip lookup (zip [0..] keys)) indexes,payload)
      unless (payer==owner && created==key && signature==B.replicate 64 0 && recentHash==recent && map expand instructions==
        [(Just system,Just [owner,key,owner],creation),(Just token,Just [key],initialization)]) (Left "mint_creation_mismatch")
      pure transaction
    _->Left "mint_creation_shape"
validate request encoded=do
  unless (quantity request>0) (Left "invalid_token_amount")
  owner<-publicKey (authority request)
  token<-publicKey tokenProgram
  mintKey<-publicKey (mint request)
  tokenAccount<-publicKey (account request)
  recent<-publicKey (blockhash request)
  transaction<-decodeTransaction encoded
  case transaction of
    Transaction [signature] (Message 1 0 1 keys@[payer,_,_,programKey] recentHash [Instruction program indexes payload]) _ -> do
      let expectedAccounts=if action request==Mint then [mintKey,tokenAccount,owner] else [tokenAccount,mintKey,owner]
          expectedData=L.toStrict $ runPut $ do
            putWord8 (if action request==Mint then 14 else 15)
            putWord64le (quantity request)
            putWord8 8
      unless (payer==owner && programKey==token
        && signature==B.replicate 64 0 && recentHash==recent
        && lookup program (zip [0..] keys)==Just token
        && traverse (flip lookup (zip [0..] keys)) indexes==Just expectedAccounts && payload==expectedData)
        (Left "token_transaction_mismatch")
      pure transaction
    _->Left "token_transaction_shape"

-- Solana System Program's standard create-with-seed address, not a keypair.
mintAddress :: Text -> Text -> Either Text Text
mintAddress owner label=do
  base<-publicKey owner
  program<-publicKey tokenProgram
  let bytes=TE.encodeUtf8 label
  unless (not(B.null bytes) && B.length bytes<=32) (Left "invalid_mint_seed")
  pure $ base58 (BA.convert (hash (base<>bytes<>program) :: Digest SHA256))

-- Dedicated unsigned entry point; no caller-selected symbol or signing path.
type PrepareFn = Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt
foreign import ccall safe "dynamic" callPrepare :: FunPtr PrepareFn -> PrepareFn
invoke :: FilePath -> B.ByteString -> IO B.ByteString
invoke library request=do
  require (B.length request<=8192) "token_request_too_large"
  bracket (dlopen library [RTLD_NOW,RTLD_LOCAL]) dlclose $ \handle->do
    prepare<-callPrepare <$> dlsym handle "ecx_token_prepare_v1"
    B.useAsCString "{}" $ \config->B.useAsCStringLen request $ \(input,size)->
      allocaBytes 8192 $ \output->alloca $ \lengthPtr->do
        poke lengthPtr 0
        status<-prepare (castPtr config) 2 (castPtr input) (fromIntegral size) output 8192 lengthPtr
        count<-peek lengthPtr
        require (status==0 && count>0 && count<=8192) "token_sdk_failed"
        B.packCStringLen (castPtr output,fromIntegral count)
