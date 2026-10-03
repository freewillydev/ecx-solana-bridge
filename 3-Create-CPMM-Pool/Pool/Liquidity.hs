{-# LANGUAGE GADTs #-}
-- Explicit liquidity units and token limits; no floating-point price approximation.
module Pool.Liquidity (Verb(..),Request(..),Prepared(..),Safe(..),evalSafe,validate) where
import qualified Pool as Pool
import qualified Pool.Position as Position
import Bridge.Error (reject)
import Bridge.Solana (tokenProgram)
import Bridge.SolanaMessage (publicKey,decodeLiquidityTransaction,Transaction(..),Message(..),Instruction(..))
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as B
import Data.List (nub,sort)
import Data.Text (Text)
import Data.Word (Word64)
import Text.Read (readMaybe)

data Verb = Deposit | Withdraw | Collect deriving (Eq,Show)
verbName :: Verb -> Text
verbName Deposit="deposit"
verbName Withdraw="withdraw"
verbName Collect="collect"
data Request = Request {verb :: Verb,positionRequest :: Position.Request,liquidity :: Integer
  ,limitA :: Word64,limitB :: Word64,vaultA :: Text,vaultB :: Text} deriving (Eq,Show)
instance FromJSON Request where
  parseJSON=withObject "liquidity request" $ \o->do
    unless (length o==7) (fail "unexpected liquidity fields")
    name<-o .: "verb" :: Parser Text
    action<-case name of "deposit"->pure Deposit; "withdraw"->pure Withdraw; "collect"->pure Collect; _->fail "unknown liquidity operation"
    quantity<-o .: "liquidity" >>= units (2^(128::Int)-1)
    a<-o .: "limitA" >>= units (toInteger(maxBound::Word64))
    b<-o .: "limitB" >>= units (toInteger(maxBound::Word64))
    Request action <$> o .: "position" <*> pure quantity <*> pure(fromInteger a) <*> pure(fromInteger b) <*> o .: "vaultA" <*> o .: "vaultB"
   where
    units bound text=case readMaybe text of
      Just n | n>=0 && n<=bound && show (n::Integer)==text->pure n
      _->fail "invalid canonical liquidity amount"
instance ToJSON Request where
  toJSON r=object ["verb" .= verbName(verb r),"position" .= positionRequest r,"liquidity" .= show(liquidity r)
    ,"limitA" .= show(limitA r),"limitB" .= show(limitB r),"vaultA" .= vaultA r,"vaultB" .= vaultB r]
data Prepared = Prepared {position :: Text,positionToken :: Text,ownerA :: Text,ownerB :: Text
  ,lowerArray :: Text,upperArray :: Text,transaction :: Text} deriving (Eq,Show)
instance FromJSON Prepared where
  parseJSON=withObject "prepared liquidity" $ \o->do
    unless (length o==7) (fail "unexpected prepared liquidity fields")
    Prepared <$> o .: "position" <*> o .: "positionToken" <*> o .: "ownerA" <*> o .: "ownerB"
      <*> o .: "lowerArray" <*> o .: "upperArray" <*> o .: "transaction"
instance ToJSON Prepared where
  toJSON p=object ["position" .= position p,"positionToken" .= positionToken p,"ownerA" .= ownerA p,"ownerB" .= ownerB p
    ,"lowerArray" .= lowerArray p,"upperArray" .= upperArray p,"transaction" .= transaction p]

validate :: Request -> Prepared -> Either Text Transaction
validate r p=do
  let request=positionRequest r
      collect=verb r==Collect
  unless (if collect then liquidity r==0 && limitA r==0 && limitB r==0 else liquidity r>0 && liquidity r<2^(128::Int)) (Left "invalid_liquidity_limits")
  a<-publicKey(Position.mintA request); b<-publicKey(Position.mintB request)
  unless (a<b) (Left "liquidity_mints_not_ordered")
  owner<-publicKey(Position.payer request); pool<-publicKey(Position.pool request); pos<-publicKey(position p)
  nft<-publicKey(positionToken p); oa<-publicKey(ownerA p); ob<-publicKey(ownerB p)
  va<-publicKey(vaultA r); vb<-publicKey(vaultB r); lo<-publicKey(lowerArray p); hi<-publicKey(upperArray p)
  token<-publicKey tokenProgram; program<-publicKey Pool.program; hash<-publicKey(Position.blockhash request)
  _<-publicKey(Position.positionMint request)
  tx@(Transaction signatures (Message n rs ru keys recent instructions) _)<-decodeLiquidityTransaction(transaction p)
  let le width value=[fromInteger(value `div` (256^i)) | i<-[0..width-1::Int]]
      change=(program,[pool,token,owner,pos,nft,oa,ob,va,vb,lo,hi],B.pack
        ((if verb r==Deposit then [46,156,243,118,13,205,251,178] else [160,38,208,111,104,91,44,1])
         <>le 16 (liquidity r)<>le 8 (toInteger $ limitA r)<>le 8 (toInteger $ limitB r)))
      update=(program,[pool,pos,lo,hi],B.pack [154,230,250,13,236,209,75,223])
      collectFees=(program,[pool,owner,pos,nft,oa,va,ob,vb,token],B.pack [164,152,207,99,30,186,19,182])
      expected=if collect then [update,collectFees] else [change]
      semantic (Instruction ix indices payload)=(keys !! fromIntegral ix,map ((keys !!) . fromIntegral) indices,payload)
      identities=[owner,pool,pos,nft,oa,ob,va,vb,lo,hi,token,program]
      writable=[owner,pool,pos,oa,ob,va,vb]<>(if collect then [] else [lo,hi])
  unless (n==1 && rs==0 && fromIntegral ru==length keys-length writable && take 1 keys==[owner] && recent==hash
    && length(nub identities)==12 && sort keys==sort identities && sort(take (length writable) keys)==sort writable
    && map semantic instructions==expected && all (B.all (==0)) signatures) (Left "liquidity_transaction_mismatch")
  pure tx

data Safe a where
  Prepare :: FilePath -> Request -> Safe Prepared

evalSafe :: Safe a -> IO a
evalSafe (Prepare library r)=do
  let p=positionRequest r
  bytes<-Pool.evalSafe $ Pool.LiquidityBytes library $ object
    ["protocol" .= (1::Int),"verb" .= verbName(verb r),"owner" .= Position.payer p,"pool" .= Position.pool p,"position_mint" .= Position.positionMint p
    ,"mint_a" .= Position.mintA p,"mint_b" .= Position.mintB p,"vault_a" .= vaultA r,"vault_b" .= vaultB r
    ,"liquidity" .= show(liquidity r),"amount_a" .= show(limitA r),"amount_b" .= show(limitB r),"blockhash" .= Position.blockhash p]
  prepared<-either (const $ reject "invalid_liquidity_reply") pure (eitherDecodeStrict' bytes)
  either reject (const $ pure prepared) (validate r prepared)
