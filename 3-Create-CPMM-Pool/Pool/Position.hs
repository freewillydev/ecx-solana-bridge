{-# LANGUAGE GADTs #-}
module Pool.Position (Request(..),Prepared(..),Safe(..),evalSafe,validate,validateOpened) where
import qualified Pool as P
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.Solana (tokenProgram)
import Bridge.SolanaMessage (publicKey,base58,decodePositionTransaction,Transaction(..),Message(..),Instruction(..))
import Control.Monad (unless)
import Data.Aeson
import Data.Binary.Get
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import Data.List (nub,sort)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word8,Word64)

data Request = Request {payer :: Text,pool :: Text,mintA :: Text,mintB :: Text,positionMint :: Text,blockhash :: Text} deriving (Eq,Show)
instance FromJSON Request where
  parseJSON=withObject "position request" $ \o->do
    unless (length o==6) (fail "unexpected position fields")
    Request <$> o .: "payer" <*> o .: "pool" <*> o .: "mintA" <*> o .: "mintB" <*> o .: "positionMint" <*> o .: "blockhash"
instance ToJSON Request where
  toJSON r=object ["payer" .= payer r,"pool" .= pool r,"mintA" .= mintA r,"mintB" .= mintB r,"positionMint" .= positionMint r,"blockhash" .= blockhash r]
data Prepared = Prepared {position :: Text,tokenAccount :: Text,lowerArray :: Text,upperArray :: Text,bump :: Word8,transaction :: Text} deriving (Eq,Show)
instance FromJSON Prepared where
  parseJSON=withObject "prepared position" $ \o->do
    unless (length o==6) (fail "unexpected preparation fields")
    Prepared <$> o .: "position" <*> o .: "tokenAccount" <*> o .: "lowerArray" <*> o .: "upperArray" <*> o .: "bump" <*> o .: "transaction"
instance ToJSON Prepared where
  toJSON p=object ["position" .= position p,"tokenAccount" .= tokenAccount p,"lowerArray" .= lowerArray p,"upperArray" .= upperArray p,"bump" .= bump p,"transaction" .= transaction p]

validate :: Request -> Prepared -> Either Text Transaction
validate r p=do
  a<-publicKey(mintA r); b<-publicKey(mintB r)
  unless (a<b) (Left "position_mints_not_ordered")
  owner<-publicKey(payer r); mint<-publicKey(positionMint r); poolKey<-publicKey(pool r)
  pos<-publicKey(position p); ata<-publicKey(tokenAccount p); lo<-publicKey(lowerArray p); hi<-publicKey(upperArray p)
  program<-publicKey P.program; token<-publicKey tokenProgram; system<-publicKey "11111111111111111111111111111111"
  rent<-publicKey "SysvarRent111111111111111111111111111111111"; associated<-publicKey "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
  hash<-publicKey(blockhash r)
  tx@(Transaction signatures (Message n rs ru keys recent instructions) _)<-decodePositionTransaction(transaction p)
  let int32 n=[fromInteger(n `mod` 2^(32::Int) `div` 256^i) | i<-[0..3::Int]]
      array address start=(program,[poolKey,owner,address,system],B.pack([41,33,165,200,120,231,142,50]<>int32 start<>[1]))
      open=(program,[owner,owner,pos,mint,ata,poolKey,token,system,rent,associated],B.pack([135,128,47,77,15,152,240,49,bump p]<>int32 (-427648)<>int32 427648))
      expected=[array lo (-2894848),array hi 0,open]
      semantic (Instruction ix indices payload)=(keys !! fromIntegral ix,map ((keys !!) . fromIntegral) indices,payload)
      identities=[owner,mint,pos,ata,lo,hi,poolKey,token,system,rent,associated,program]
  unless (n==2 && rs==0 && ru==6 && recent==hash && take 2 keys==[owner,mint]
    && length(nub identities)==12 && sort keys==sort identities && sort(take 6 keys)==sort[owner,mint,pos,ata,lo,hi]
    && map semantic instructions==expected && all (B.all (==0)) signatures) (Left "position_transaction_mismatch")
  pure tx

validateOpened :: Request -> [Value] -> Either Text ()
validateOpened r [positionInfo,mintInfo,tokenInfo]=do
  bytes<-P.accountData P.program 216 positionInfo
  (actualPool,actualMint)<-P.parse (do
    discriminator<-getByteString 8; poolKey<-base58 <$> getByteString 32; mint<-base58 <$> getByteString 32
    liquidity<-getByteString 16; lower<-getInt32le; upper<-getInt32le; remainder<-getByteString 120
    unless (discriminator==B.pack [170,188,143,228,122,64,247,208] && B.all (==0) liquidity
      && lower== -427648 && upper==427648 && B.all (==0) remainder) (fail "unexpected new position")
    pure(poolKey,mint)) bytes
  unless (actualPool==pool r && actualMint==positionMint r) (Left "position_identity_mismatch")
  mint<-P.accountData tokenProgram 82 mintInfo >>= P.parse P.mintParser
  amount<-P.accountData tokenProgram 165 tokenInfo >>= P.parse (P.vaultParser (positionMint r) (payer r))
  unless (mint==(0,1,Nothing,Nothing) && amount==1) (Left "position_ownership_mismatch")
validateOpened _ _=Left "position_account_count"

data Safe a where
  Prepare :: FilePath -> Request -> Safe Prepared
  Check :: FilePath -> P.Network -> String -> Word64 -> Word64 -> Request -> Prepared -> Safe Word64

evalSafe :: Safe a -> IO a
evalSafe (Prepare library r)=do
  bytes<-P.evalSafe(P.PositionBytes library (payer r) (pool r) (positionMint r) (blockhash r))
  p<-either (const $ reject "invalid_position_reply") pure (eitherDecodeStrict' bytes)
  either reject (const $ pure p) (validate r p)
evalSafe (Check library network endpoint feeLimit costLimit r p)=do
  canonical<-evalSafe(Prepare library r)
  require (canonical==p && feeLimit>0 && costLimit>=feeLimit) "position_preparation_or_limits_mismatch"
  Transaction _ _ message<-either reject pure(validate r p)
  P.Report _ _ state _<-P.evalSafe(P.Inspect library network endpoint (P.Expected (pool r) (mintA r) (mintB r)))
  require (P.spacing state==32896) "unsupported_position_spacing"
  withSolanaRpc endpoint (P.networkGenesis network) ("position_requires_https","wrong_position_network") $ \call->do
    let identities=[position p,positionMint r,tokenAccount p,payer r]
        options=object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text)]
    before<-call "getMultipleAccounts" [toJSON identities,options]
    context<-fieldValue "context" before
    height<-fieldValue "slot" context :: IO Integer
    values<-fieldValue "value" before :: IO [Value]
    balance<-case values of
      [Null,Null,Null,payerInfo]->do
        owner<-fieldValue "owner" payerInfo :: IO Text
        executable<-fieldValue "executable" payerInfo
        amount<-fieldValue "lamports" payerInfo :: IO Integer
        require (owner=="11111111111111111111111111111111" && not executable && amount>=0) "invalid_position_payer"
        pure amount
      _->reject "position_accounts_already_exist"
    quote<-call "getFeeForMessage" [toJSON $ TE.decodeUtf8 $ B64.encode message,object ["commitment" .= ("finalized"::Text)]] >>= fieldValue "value" :: IO (Maybe Integer)
    fee<-case quote of Just n | n>0 && n<=toInteger feeLimit && n<=balance->pure n; _->reject "position_fee_unavailable_or_excessive"
    simulation<-call "simulateTransaction" [toJSON(transaction p),object
      ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"minContextSlot" .= height,"sigVerify" .= False,"replaceRecentBlockhash" .= False
      ,"accounts" .= object ["encoding" .= ("base64"::Text),"addresses" .= identities]]]
    result<-fieldValue "value" simulation
    failure<-fieldValue "err" result :: IO Value
    require (failure==Null) "position_simulation_failed"
    accounts<-fieldValue "accounts" result :: IO [Value]
    case accounts of
      [pos,mint,token,payerInfo]->do
        either reject pure(validateOpened r [pos,mint,token])
        after<-fieldValue "lamports" payerInfo :: IO Integer
        let debit=balance-after+fee
        require (after>=0 && after<=balance && debit<=toInteger costLimit) "position_simulation_cost_limit"
        pure(fromInteger debit)
      _->reject "position_simulation_account_count"
