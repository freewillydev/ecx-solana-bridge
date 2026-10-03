{-# LANGUAGE GADTs, ForeignFunctionInterface #-}
-- Closed, read-only liquidity operations. No signing key, ledger or custody access.
module Pool (Network(..),Safe(..),Create(..),Prepared(..),validatePrepared,Expected(..),Snapshot(..),Report(..),Whirlpool(..),evalSafe,validate,decodePool,program,configuration) where
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.Solana (tokenProgram)
import Bridge.SolanaMessage (publicKey,base58,decodePoolTransaction,Transaction(..),Message(..),Instruction(..))
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Binary.Get
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as L
import Data.List (nub,sort)
import qualified Data.Aeson.KeyMap as KM
import Text.Read (readMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign
import Foreign.C.Types
import Network.HTTP.Client (parseRequest,secure,closeManager)
import System.Posix.DynamicLinker

data Network = Devnet | Mainnet deriving (Eq,Show)
program :: Text
program="whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc"
configuration :: Network -> Text
configuration network=base58 $ B.pack $ case network of
  Mainnet->[19,228,65,248,57,19,202,104,176,99,79,176,37,253,234,168,135,55,232,65,16,209,37,94,53,123,51,119,221,238,28,205]
  Devnet->[217,51,106,61,244,143,54,30,87,6,230,156,60,182,182,217,23,116,228,121,53,200,82,109,229,160,245,159,33,90,35,106]

data Expected = Expected {pool :: Text,expectedA :: Text,expectedB :: Text} deriving (Eq,Show)
data Whirlpool = Whirlpool
  {config :: Text,spacing :: Word16,tier :: Word16,fee :: Word16,protocolFee :: Word16,liquidity :: Integer,sqrtPrice :: Integer
  ,tick :: Int32,owedA :: Word64,owedB :: Word64,mintA :: Text,vaultA :: Text,mintB :: Text,vaultB :: Text} deriving (Eq,Show)
data Snapshot = Snapshot {slot :: Integer,accounts :: [Value]} deriving (Eq,Show)
data Report = Report Expected Snapshot Whirlpool Value
instance ToJSON Report where
  toJSON (Report expected snapshot p detail)=object
    ["pool" .= pool expected,"slot" .= slot snapshot,"program" .= program,"configuration" .= config p
    ,"tickSpacing" .= spacing p,"fullRangeOnly" .= True,"baseFeeMillionths" .= fee p,"feeTierIndex" .= tier p,"adaptiveFeeTier" .= (tier p/=spacing p)
    ,"protocolFeeTenThousandths" .= protocolFee p,"liquidity" .= show(liquidity p)
    ,"sqrtPriceX64" .= show(sqrtPrice p),"currentTick" .= tick p,"tokens" .= detail]

-- A separate liquidity payer and two new vault identities; no custody capability.
data Create = Create {payer :: Text,createMintA :: Text,createMintB :: Text,createVaultA :: Text,createVaultB :: Text
  ,initialPrice :: Integer,recentBlockhash :: Text} deriving (Eq,Show)
instance FromJSON Create where
  parseJSON=withObject "pool creation" $ \o->do
    unless (KM.size o==7) (fail "unexpected pool request fields")
    price<-o .: "sqrtPriceX64"
    n<-case readMaybe price of
      Just value | show (value::Integer)==price->pure value
      _->fail "noncanonical pool price"
    Create <$> o .: "payer" <*> o .: "mintA" <*> o .: "mintB" <*> o .: "vaultA" <*> o .: "vaultB" <*> pure n <*> o .: "blockhash"
instance ToJSON Create where
  toJSON r=object ["payer" .= payer r,"mintA" .= createMintA r,"mintB" .= createMintB r
    ,"vaultA" .= createVaultA r,"vaultB" .= createVaultB r,"sqrtPriceX64" .= show(initialPrice r),"blockhash" .= recentBlockhash r]
data Prepared = Prepared {createdPool :: Text,feeTier :: Text,poolBump :: Word8,unsignedTransaction :: Text} deriving (Eq,Show)
instance FromJSON Prepared where
  parseJSON=withObject "prepared pool" $ \o->do
    unless (KM.size o==4) (fail "unexpected prepared fields")
    Prepared <$> o .: "pool" <*> o .: "feeTier" <*> o .: "bump" <*> o .: "transaction"
instance ToJSON Prepared where
  toJSON p=object ["pool" .= createdPool p,"feeTier" .= feeTier p,"bump" .= poolBump p,"transaction" .= unsignedTransaction p]

validatePrepared :: Network -> Create -> Prepared -> Either Text Transaction
validatePrepared network r p=do
  unless (initialPrice r>=4295048016 && initialPrice r<=79226673515401279992447579055) (Left "invalid_pool_price")
  expected<-mapM publicKey [configuration network,createMintA r,createMintB r,payer r,createdPool p
    ,createVaultA r,createVaultB r,feeTier p,tokenProgram,"11111111111111111111111111111111"
    ,"SysvarRent111111111111111111111111111111111"]
  prog<-publicKey program; hash<-publicKey(recentBlockhash r)
  a<-publicKey(createMintA r); b<-publicKey(createMintB r)
  owner<-publicKey(payer r); va<-publicKey(createVaultA r); vb<-publicKey(createVaultB r); address<-publicKey(createdPool p)
  tx@(Transaction signatures (Message n rs ru keys recent instructions) _)<-decodePoolTransaction(unsignedTransaction p)
  let payload=B.pack ([95,180,10,172,84,174,232,40,poolBump p,128,128]
        <>[fromInteger(initialPrice r `div` (256^i)) | i<-[0..15::Int]])
      semantic (Instruction ix indices bytes)=(keys !! fromIntegral ix,map ((keys !!) . fromIntegral) indices,bytes)
  unless (a<b && length(nub(prog:expected))==12 && sort keys==sort(prog:expected)
    && n==3 && rs==0 && ru==8 && take 1 keys==[owner] && sort(take 3 keys)==sort[owner,va,vb]
    && sort(take 4 keys)==sort[owner,va,vb,address] && recent==hash
    && map semantic instructions==[(prog,expected,payload)] && all (B.all (==0)) signatures)
    (Left "pool_transaction_mismatch")
  pure tx

data Safe a where
  Prepare :: FilePath -> Network -> Create -> Safe Prepared
  Address :: FilePath -> Network -> Text -> Text -> Word16 -> Safe Text
  Inspect :: FilePath -> Network -> String -> Expected -> Safe Report

evalSafe :: Safe a -> IO a
evalSafe (Prepare library network r)=do
  require (initialPrice r>=4295048016 && initialPrice r<=79226673515401279992447579055) "invalid_pool_price"
  reply<-invoke "ecx_pool_prepare_v1" library $ object
    ["protocol" .= (1::Int),"config" .= configuration network,"payer" .= payer r,"mint_a" .= createMintA r,"mint_b" .= createMintB r
    ,"vault_a" .= createVaultA r,"vault_b" .= createVaultB r,"sqrt_price" .= show(initialPrice r),"blockhash" .= recentBlockhash r]
  prepared<-either (const $ reject "invalid_pool_prepare_reply") pure (eitherDecodeStrict' reply)
  either reject (const $ pure prepared) (validatePrepared network r prepared)
evalSafe (Address library network a b index)=do
  keys<-mapM (either reject pure . publicKey) [a,b]
  require (case keys of [x,y]->x<y; _->False) "pool_mints_not_ordered"
  reply<-invoke "ecx_pool_address_v1" library $ object ["protocol" .= (1::Int),"config" .= configuration network,"mint_a" .= a,"mint_b" .= b,"fee_tier_index" .= index]
  address<-either (const $ reject "invalid_pool_address_reply") pure (eitherDecodeStrict' reply)
  either reject (const $ pure address) (publicKey address)
evalSafe (Inspect library network endpoint expected)=do
  mapM_ (either reject (const $ pure ()) . publicKey) [pool expected,expectedA expected,expectedB expected]
  transport<-parseRequest endpoint
  require (secure transport) "pool_requires_https"
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
        options=object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text)]
    genesis<-call "getGenesisHash" [] >>= parseValue parseJSON :: IO Text
    require (genesis==case network of Devnet->"EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"; Mainnet->"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d") "wrong_pool_network"
    initial<-call "getAccountInfo" [toJSON (pool expected),options] >>= fieldValue "value"
    p<-either reject pure (accountData program 653 initial >>= decodePool)
    canonical<-evalSafe (Address library network (expectedA expected) (expectedB expected) (tier p))
    require (pool expected==canonical) "pool_address_mismatch"
    -- Include the pool again so all reported values come from one finalized bank.
    result<-call "getMultipleAccounts" [toJSON [pool expected,configuration network,expectedA expected,expectedB expected,vaultA p,vaultB p],options]
    context<-fieldValue "context" result
    height<-fieldValue "slot" context
    values<-fieldValue "value" result
    report@(Report _ _ current _)<-either reject pure (validate network expected (Snapshot height values))
    require (vaultA current==vaultA p && vaultB current==vaultB p && tier current==tier p) "pool_changed_during_read"
    pure report

validate :: Network -> Expected -> Snapshot -> Either Text Report
validate network expected snapshot=do
  a<-publicKey(expectedA expected); b<-publicKey(expectedB expected)
  unless (a<b && slot snapshot>=0) (Left "invalid_pool_expectation")
  case accounts snapshot of
    [poolInfo,configInfo,mintInfoA,mintInfoB,vaultInfoA,vaultInfoB]->do
      p<-accountData program 653 poolInfo >>= decodePool
      unless (config p==configuration network && mintA p==expectedA expected && mintB p==expectedB expected
        && length(nub [pool expected,mintA p,mintB p,vaultA p,vaultB p])==5) (Left "pool_identity_mismatch")
      settings<-accountData program 108 configInfo
      unless (B.take 8 settings==B.pack [157,20,49,224,217,87,193,254]) (Left "invalid_pool_config")
      mintDataA<-accountData tokenProgram 82 mintInfoA >>= parse mintParser
      mintDataB<-accountData tokenProgram 82 mintInfoB >>= parse mintParser
      amountA<-accountData tokenProgram 165 vaultInfoA >>= parse (vaultParser (mintA p) (pool expected))
      amountB<-accountData tokenProgram 165 vaultInfoB >>= parse (vaultParser (mintB p) (pool expected))
      unless (owedA p<=amountA && owedB p<=amountB) (Left "pool_protocol_fees_exceed_vault")
      let describe token vault amount (decimals,supply,issuer,freeze)=object
            ["mint" .= token,"vault" .= vault,"balance" .= show amount,"decimals" .= decimals
            ,"supply" .= show supply,"mintAuthority" .= issuer,"freezeAuthority" .= freeze]
      pure $ Report expected snapshot p $ object
        ["a" .= describe (mintA p) (vaultA p) amountA mintDataA,"b" .= describe (mintB p) (vaultB p) amountB mintDataB]
    _->Left "pool_snapshot_account_count"

-- Exact classic Whirlpool layout from pinned Orca client source; no guessed offsets.
decodePool :: B.ByteString -> Either Text Whirlpool
decodePool bytes=do
  unless (B.length bytes==653) (Left "invalid_pool_size")
  parse parser bytes
 where
  parser=do
    discriminator<-getByteString 8
    unless (discriminator==B.pack [63,149,209,12,225,128,99,9]) (fail "invalid pool discriminator")
    config<-key; skip 1
    spacing<-getWord16le; tier<-getWord16le; fee<-getWord16le; protocolFee<-getWord16le
    liquidity<-word128; sqrtPrice<-word128; tick<-getInt32le
    owedA<-getWord64le; owedB<-getWord64le
    mintA<-key; vaultA<-key; skip 16; mintB<-key; vaultB<-key; skip 16; skip 8; skip (128*3)
    unless (spacing>=32768 && protocolFee<=10000
      && sqrtPrice>=4295048016 && sqrtPrice<=79226673515401279992447579055 && tick>= -443636 && tick<=443636)
      (fail "unsupported full-range pool")
    pure Whirlpool{config,spacing,tier,fee,protocolFee,liquidity,sqrtPrice,tick,owedA,owedB,mintA,vaultA,mintB,vaultB}
  word128=do lo<-getWord64le; hi<-getWord64le; pure(toInteger lo+toInteger hi*2^(64::Int))

mintParser :: Get (Word8,Word64,Maybe Text,Maybe Text)
mintParser=do
  issuer<-optionalKey; supply<-getWord64le; decimals<-getWord8; initialized<-getWord8; freeze<-optionalKey
  unless (initialized==1) (fail "uninitialized mint")
  pure (decimals,supply,issuer,freeze)
vaultParser :: Text -> Text -> Get Word64
vaultParser expectedMint expectedOwner=do
  mint<-key; owner<-key; amount<-getWord64le; delegate<-optionalKey; state<-getWord8
  native<-getWord32le; skip 8; delegated<-getWord64le; close<-optionalKey
  unless (mint==expectedMint && owner==expectedOwner && state==1 && delegate==Nothing && delegated==0 && close==Nothing
    && (native==0 || (native==1 && mint=="So11111111111111111111111111111111111111112"))) (fail "invalid pool vault")
  pure amount
key :: Get Text
key=base58 <$> getByteString 32
optionalKey :: Get (Maybe Text)
optionalKey=do
  tag<-getWord32le; value<-key
  case tag of 0->pure Nothing; 1->pure(Just value); _->fail "invalid optional key"
parse :: Get a -> B.ByteString -> Either Text a
parse parser bytes=case runGetOrFail (parser <* (isEmpty >>= \empty->unless empty (fail "trailing bytes"))) (L.fromStrict bytes) of
  Right (_,_,value)->Right value
  Left _->Left "invalid_pool_account_layout"
accountData :: Text -> Int -> Value -> Either Text B.ByteString
accountData owner size value=do
  (actual,executable,encoded)<-either (Left . T.pack) Right $ parseEither (withObject "chain account" $ \o->
    (,,) <$> o .: "owner" <*> o .: "executable" <*> o .: "data") value :: Either Text (Text,Bool,[Text])
  unless (actual==owner && not executable) (Left "wrong_pool_account_owner")
  raw<-case encoded of [text,"base64"]->either (const $ Left "invalid_pool_base64") Right (B64.decode $ TE.encodeUtf8 text); _->Left "invalid_pool_encoding"
  unless (B.length raw==size) (Left "invalid_pool_account_size")
  pure raw

-- Pure PDA derivation through the existing Solana SDK; caller-owned bounded buffers.
type DeriveFn = Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt
foreign import ccall safe "dynamic" callDerive :: FunPtr DeriveFn -> DeriveFn
invoke :: String -> FilePath -> Value -> IO B.ByteString
invoke symbol library value=do
  let request=L.toStrict(encode value)
  require (B.length request<=8192) "pool_request_too_large"
  bracket (dlopen library [RTLD_NOW,RTLD_LOCAL]) dlclose $ \handle->do
    derive<-callDerive <$> dlsym handle symbol
    B.useAsCString "{}" $ \config->B.useAsCStringLen request $ \(input,size)->
      allocaBytes 8192 $ \output->alloca $ \lengthPtr->do
        poke lengthPtr 0
        status<-derive (castPtr config) 2 (castPtr input) (fromIntegral size) output 8192 lengthPtr
        count<-peek lengthPtr
        require (status==0 && count>0 && count<=8192) "pool_sdk_failed"
        B.packCStringLen (castPtr output,fromIntegral count)
