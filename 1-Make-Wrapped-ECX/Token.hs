{-# LANGUAGE GADTs, ForeignFunctionInterface #-}
-- Administration has no custody credential, database or generic instruction input.
module Token (Action(..),Request(..),Safe(..),evalSafe,validate,mintAddress,nonceAddress,parseIntent) where
import qualified Token.Metadata as M
import Bridge.Error (require,reject)
import Bridge.Solana (tokenProgram)
import Bridge.SolanaMessage
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser)
import Data.List (nub,sort)
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
  | Associated {authority :: Text,mint :: Text,account :: Text,owner :: Text,rent :: Word64,blockhash :: Text}
  | Metadata {authority :: Text,mint :: Text,metadata :: M.Terms,blockhash :: Text}
  | NonceMint {authority :: Text,mint :: Text,account :: Text,quantity :: Word64,blockhash :: Text,nonceAccount :: Text}
  | CreateNonce {authority :: Text,nonceAccount :: Text,owner :: Text,seed :: Text,rent :: Word64,blockhash :: Text}
  deriving (Eq,Show)

instance ToJSON Request where
  toJSON CreateNonce{authority=payer,nonceAccount=address,owner=holder,seed=label,rent=n,blockhash=recent}=object
    ["protocol" .= (1::Int),"verb" .= ("create_nonce"::Text),"authority" .= payer,"nonceAccount" .= address
    ,"owner" .= holder,"seed" .= label,"rent" .= T.pack(show n),"blockhash" .= recent]
  toJSON NonceMint{authority=payer,mint=key,account=address,quantity=n,blockhash=recent,nonceAccount=nonce}=object
    ["protocol" .= (1::Int),"verb" .= ("nonce_mint"::Text),"authority" .= payer,"mint" .= key
    ,"account" .= address,"amount" .= T.pack(show n),"blockhash" .= recent,"nonceAccount" .= nonce]
  toJSON Associated{authority=payer,mint=key,account=address,owner=recipient,rent=lamports,blockhash=recent}=object
    ["protocol" .= (1::Int),"verb" .= ("associated"::Text),"authority" .= payer,"mint" .= key
    ,"account" .= address,"owner" .= recipient,"rent" .= T.pack(show lamports),"blockhash" .= recent]
  toJSON Metadata{authority=owner,mint=key,metadata=terms,blockhash=recent}=object
    ["protocol" .= (1::Int),"verb" .= ("metadata"::Text),"authority" .= owner,"mint" .= key
    ,"metadata" .= terms,"blockhash" .= recent]
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
    unless (protocol==(1::Int)) (fail "invalid_token_protocol")
    if verb==("metadata"::Text) then do
      unless (length o==6) (fail "invalid_metadata_fields")
      Metadata <$> o .: "authority" <*> o .: "mint" <*> o .: "metadata" <*> o .: "blockhash"
    else do
      raw<-o .: (if verb `elem` (["create","associated","create_nonce"]::[Text]) then "rent" else "amount")
      unless (length o==(if verb `elem` ["associated","nonce_mint","create_nonce"] then 8 else 7)) (fail "invalid_token_fields")
      n<-case readMaybe (T.unpack raw) :: Maybe Integer of
        Just x | x>0 && x<=toInteger(maxBound::Word64) && T.pack(show x)==raw -> pure(fromInteger x)
        _->fail "invalid_token_amount"
      case (verb::Text) of
        "create_nonce"->CreateNonce <$> o .: "authority" <*> o .: "nonceAccount" <*> o .: "owner" <*> o .: "seed" <*> pure n <*> o .: "blockhash"
        "nonce_mint"->NonceMint <$> o .: "authority" <*> o .: "mint" <*> o .: "account" <*> pure n <*> o .: "blockhash" <*> o .: "nonceAccount"
        "associated"->Associated <$> o .: "authority" <*> o .: "mint" <*> o .: "account" <*> o .: "owner" <*> pure n <*> o .: "blockhash"
        "create"->CreateMint <$> o .: "authority" <*> o .: "mint" <*> o .: "seed" <*> pure n <*> o .: "blockhash"
        _->do
          operation<-case verb of "mint"->pure Mint; "burn"->pure Burn; _->fail "invalid_token_operation"
          Request operation <$> o .: "authority" <*> o .: "mint" <*> o .: "account" <*> pure n <*> o .: "blockhash"

-- Only the selected network supplies freshness; signed archives keep Request's
-- strict blockhash field and retain their existing immutable format.
parseIntent :: Text -> Value -> Parser Request
parseIntent recent=withObject "token signing input" $ \o->do
  unless (not $ KM.member "blockhash" o) (fail "Remove blockhash; signing obtains it from the network")
  parseJSON (Object $ KM.insert "blockhash" (String recent) o)

data Safe a where
  MintAddress :: Text -> Text -> Safe Text
  NonceAddress :: Text -> Text -> Safe Text
  Prepare :: FilePath -> Request -> Safe Text
  MetadataAddress :: FilePath -> Text -> Safe Text
  AssociatedAddress :: FilePath -> Text -> Text -> Safe Text

evalSafe :: Safe a -> IO a
evalSafe (MintAddress owner label)=either reject pure (mintAddress owner label)
evalSafe (NonceAddress owner label)=either reject pure (nonceAddress owner label)
evalSafe (AssociatedAddress library recipient key)=do
  mapM_ (either reject (const $ pure ()) . publicKey) [recipient,key]
  output<-invoke library (L.toStrict $ encode $ object ["protocol" .= (1::Int),"verb" .= ("associated_address"::Text),"mint" .= key,"owner" .= recipient])
  address<-either (const $ reject "invalid_associated_address_reply") pure (eitherDecodeStrict' output)
  either reject (const $ pure address) (publicKey address)
evalSafe (MetadataAddress library key)=do
  _<-either reject pure (publicKey key)
  output<-invoke library (L.toStrict $ encode $ object ["protocol" .= (1::Int),"verb" .= ("metadata_address"::Text),"mint" .= key])
  address<-either (const $ reject "invalid_metadata_address_reply") pure (eitherDecodeStrict' output)
  either reject (const $ pure address) (publicKey address)
evalSafe (Prepare library request)=do
  either reject pure $ case request of
    CreateNonce{authority=payer,nonceAccount=address,owner=holder,seed=label,rent=n}->do
      derived<-nonceAddress payer label
      unless (derived==address && n>0) (Left "invalid_nonce_creation")
      publicKey holder >> pure ()
    Associated{account=address,owner=recipient,rent=n}->do
      unless (n>0) (Left "invalid_account_rent")
      mapM_ publicKey [address,recipient]
    Metadata{metadata=terms}->M.checkTerms terms
    CreateMint{seed=label,rent=n}->do
      derived<-mintAddress (authority request) label
      unless (derived==mint request && n>0) (Left "invalid_mint_creation")
    Request{quantity=n,account=address}->unless (n>0) (Left "invalid_token_amount") >> publicKey address >> pure ()
    NonceMint{quantity=n,account=address,nonceAccount=nonce}->do
      unless (n>0) (Left "invalid_token_amount")
      mapM_ publicKey [address,nonce]
  mapM_ (either reject (const $ pure ()) . publicKey)
    [authority request,case request of CreateNonce{nonceAccount=address}->address; _->mint request,blockhash request]
  output<-invoke library (L.toStrict $ encode request)
  transaction<-either (const $ reject "invalid_token_sdk_reply") pure (eitherDecodeStrict' output)
  either reject (const $ pure transaction) (validate request transaction)

-- Independently check the SDK's entire message: one zero signature, exact keys,
-- writable roles, program, instruction, blockhash, integer amount and decimals.
validate :: Request -> Text -> Either Text Transaction
validate CreateNonce{authority=payer,nonceAccount=address,owner=holder,seed=label,rent=n,blockhash=recent} encoded=do
  paying<-publicKey payer; created<-publicKey address; nonceOwner<-publicKey holder; recentHash<-publicKey recent
  system<-publicKey "11111111111111111111111111111111"
  hashes<-publicKey "SysvarRecentB1ockHashes11111111111111111111"
  rentSysvar<-publicKey "SysvarRent111111111111111111111111111111111"
  derived<-nonceAddress payer label
  let expectedKeys=[paying,created,system,hashes,rentSysvar]
      seedBytes=TE.encodeUtf8 label
      creation=L.toStrict $ runPut $ do
        putWord32le 3; putByteString paying; putWord64le (fromIntegral $ B.length seedBytes)
        putByteString seedBytes; putWord64le n; putWord64le 80; putByteString system
  unless (derived==address && n>0 && length(nub expectedKeys)==5) (Left "invalid_nonce_creation")
  transaction<-decodeTransaction encoded
  case transaction of
    Transaction [signature] (Message 1 0 3 keys hash instructions) _->do
      let at i=keys !! fromIntegral i
          expand (Instruction program indexes payload)=(at program,map at indexes,payload)
      unless (signature==B.replicate 64 0 && hash==recentHash && take 2 keys==[paying,created]
        && sort keys==sort expectedKeys && map expand instructions==
          [(system,[paying,created,paying],creation),(system,[created,hashes,rentSysvar],B.pack [6,0,0,0]<>nonceOwner)])
        (Left "nonce_creation_mismatch")
      pure transaction
    _->Left "nonce_creation_shape"
validate NonceMint{authority=payer,mint=key,account=address,quantity=n,blockhash=recent,nonceAccount=nonce} encoded=do
  paying<-publicKey payer; token<-publicKey key; destination<-publicKey address
  stored<-publicKey nonce; recentHash<-publicKey recent; spl<-publicKey tokenProgram
  system<-publicKey "11111111111111111111111111111111"
  hashes<-publicKey "SysvarRecentB1ockHashes11111111111111111111"
  let expectedKeys=[paying,token,destination,stored,spl,system,hashes]
      mintData=L.toStrict $ runPut $ putWord8 14 >> putWord64le n >> putWord8 8
  unless (n>0 && length(nub expectedKeys)==7) (Left "invalid_nonce_mint_accounts")
  transaction<-decodeTransaction encoded
  case transaction of
    Transaction [signature] (Message 1 0 3 keys hash instructions) _->do
      let at i=keys !! fromIntegral i
          expand (Instruction program indexes payload)=(at program,map at indexes,payload)
      unless (signature==B.replicate 64 0 && hash==recentHash && take 1 keys==[paying]
        && sort keys==sort expectedKeys && sort(take 4 keys)==sort [paying,token,destination,stored]
        && map expand instructions==[(system,[stored,hashes,paying],B.pack [4,0,0,0]),(spl,[token,destination,paying],mintData)])
        (Left "nonce_mint_transaction_mismatch")
      pure transaction
    _->Left "nonce_mint_transaction_shape"
validate Associated{authority=payer,mint=key,account=address,owner=recipient,rent=lamports,blockhash=recent} encoded=do
  unless (lamports>0) (Left "invalid_account_rent")
  paying<-publicKey payer; token<-publicKey key; destination<-publicKey address; holder<-publicKey recipient
  recentHash<-publicKey recent; spl<-publicKey tokenProgram
  system<-publicKey "11111111111111111111111111111111"
  ata<-publicKey "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
  transaction<-decodeTransaction encoded
  case transaction of
    Transaction [signature] (Message 1 0 readonly keys hash [Instruction program indexes payload]) _->do
      let at i=keys !! fromIntegral i -- decoder bounds indices
          accounts=[paying,destination,holder,token,system,spl]
      unless (paying/=destination && token/=holder && token/=paying && signature==B.replicate 64 0
        && hash==recentHash && take 1 keys==[paying] && sort keys==sort(nub $ ata:accounts)
        && sort(take (length keys-fromIntegral readonly) keys)==sort [paying,destination]
        && at program==ata && map at indexes==accounts && payload==B.singleton 1) (Left "associated_account_mismatch")
      pure transaction
    _->Left "associated_account_shape"
validate Metadata{authority=owner,mint=key,metadata=terms,blockhash=recent} encoded=M.validate owner key recent terms encoded
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
mintAddress=seedAddress tokenProgram

nonceAddress :: Text -> Text -> Either Text Text
nonceAddress=seedAddress "11111111111111111111111111111111"

seedAddress :: Text -> Text -> Text -> Either Text Text
seedAddress programKey owner label=do
  base<-publicKey owner
  program<-publicKey programKey
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
