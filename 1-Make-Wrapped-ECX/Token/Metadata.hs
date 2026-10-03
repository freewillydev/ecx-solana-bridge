-- Narrow fungible-token metadata policy; no royalties, creators or authority changes.
module Token.Metadata (Terms(..),program,checkTerms,validate,inspect) where
import Bridge.SolanaMessage
import Control.Monad (unless)
import Data.Aeson
import Data.Binary.Get
import Data.Binary.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Text.Read (readMaybe)

data Terms = Terms {create :: Bool,address :: Text,name :: Text,symbol :: Text,uri :: Text,maxCost :: Word64}
  deriving (Eq,Show)
instance ToJSON Terms where
  toJSON m=object ["create" .= create m,"address" .= address m,"name" .= name m,"symbol" .= symbol m
    ,"uri" .= uri m,"max_cost" .= T.pack(show $ maxCost m)]
instance FromJSON Terms where
  parseJSON=withObject "metadata" $ \o->do
    unless (length o==6) (fail "invalid_metadata_fields")
    raw<-o .: "max_cost"
    cap<-case readMaybe (T.unpack raw) :: Maybe Integer of
      Just n | n>0 && n<=toInteger(maxBound::Word64) && T.pack(show n)==raw->pure(fromInteger n)
      _->fail "invalid_metadata_cost"
    m<-Terms <$> o .: "create" <*> o .: "address" <*> o .: "name" <*> o .: "symbol" <*> o .: "uri" <*> pure cap
    either (fail . T.unpack) (const $ pure m) (checkTerms m)
program :: Text
program="metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
checkTerms :: Terms -> Either Text ()
checkTerms m=do
  _<-publicKey(address m)
  unless (valid 32 (name m) && valid 10 (symbol m) && B.length(TE.encodeUtf8 $ uri m)<=200
    && T.all (>= ' ') (uri m) && (T.null(uri m) || any (`T.isPrefixOf` uri m) ["https://","ipfs://"])
    && maxCost m>0) (Left "invalid_metadata_terms")
 where valid limit text=not(T.null text) && T.all (>= ' ') text && B.length(TE.encodeUtf8 text)<=limit

-- Independently compare the complete Metaplex Borsh instruction and account roles.
validate :: Text -> Text -> Text -> Terms -> Text -> Either Text Transaction
validate authority mint blockhash m encoded=do
  checkTerms m
  owner<-publicKey authority; token<-publicKey mint; metadata<-publicKey(address m)
  executable<-publicKey program; system<-publicKey "11111111111111111111111111111111"
  recent<-publicKey blockhash
  transaction<-decodeTransaction encoded
  let payload=L.toStrict $ runPut $ do
        if create m then putWord8 33 else putWord8 15 >> putWord8 1
        mapM_ (\text->let bytes=TE.encodeUtf8 text in putWord32le(fromIntegral $ B.length bytes) >> putByteString bytes) [name m,symbol m,uri m]
        putWord16le 0 -- seller fee
        putByteString (B.replicate 3 0) -- no creators, collection or uses
        putByteString (if create m then B.pack [1,0] else B.replicate 3 0)
      accounts=if create m then [metadata,token,owner,owner,owner,system] else [metadata,owner]
      expectedKeys=if create m then [owner,metadata,token,system,executable] else [owner,metadata,executable]
  case transaction of
    Transaction [signature] (Message 1 0 readonly keys recentHash [Instruction p indexes dat]) _->do
      let at i=keys !! fromIntegral i -- indices bounded by decoder
      unless (signature==B.replicate 64 0 && recentHash==recent && take 1 keys==[owner]
        && sort keys==sort expectedKeys && readonly==if create m then 3 else 1) (Left "metadata_message_mismatch")
      unless (sort(take (length keys-fromIntegral readonly) keys)==sort [owner,metadata]
        && at p==executable && map at indexes==accounts && dat==payload) (Left "metadata_instruction_mismatch")
      pure transaction
    _->Left "metadata_transaction_shape"

-- Account prefix from Metaplex MetadataV1. Reject unsupported authorities/royalties
-- before updating; trailing versioned fields are retained by UpdateMetadataAccountV2.
inspect :: Text -> Text -> B.ByteString -> Either Text (Text,Text,Text)
inspect authority mint bytes=do
  owner<-publicKey authority; token<-publicKey mint
  unless (B.length bytes>=80 && B.length bytes<=679) (Left "invalid_metadata_account_size")
  case runGetOrFail (parser owner token) (L.fromStrict bytes) of
    Right (_,_,fields)->Right fields
    Left _->Left "unsupported_metadata_account"
 where
  parser owner token=do
    key<-getWord8; actualOwner<-getByteString 32; actualMint<-getByteString 32
    title<-string 32; ticker<-string 10; link<-string 200
    fee<-getWord16le; creators<-getWord8; sale<-getWord8; mutable<-getWord8
    unless (key==4 && actualOwner==owner && actualMint==token && fee==0 && creators==0 && sale<=1 && mutable==1)
      (fail "unsupported metadata")
    nonce<-getWord8
    unless (nonce<=1) (fail "invalid edition nonce")
    if nonce==1 then getWord8 >> pure () else pure ()
    standard<-getWord8
    unless (standard<=1) (fail "invalid token standard")
    if standard==1 then getWord8 >>= \n->unless (n==2) (fail "not fungible") else pure ()
    fields<-getByteString 4 -- no collection, uses, collection details or programmable config
    unless (fields==B.replicate 4 0) (fail "unsupported metadata extensions")
    pure (title,ticker,link)
  string limit=do
    n<-getWord32le
    unless (n<=limit) (fail "oversized metadata string")
    raw<-getByteString(fromIntegral n)
    either (const $ fail "invalid UTF8") (pure . T.dropWhileEnd (=='\0')) (TE.decodeUtf8' raw)
