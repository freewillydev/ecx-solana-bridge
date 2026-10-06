{-# LANGUAGE GADTs #-}
-- Explicit liquidity units and token limits; no floating-point price approximation.
module Pool.Liquidity (Verb(..),Request(..),Prepared(..),Effect(..),Safe(..),evalSafe,validate,validateEffects) where
import qualified Pool as Pool
import qualified Pool.Position as Position
import Bridge.Error (reject,require)
import Bridge.Domain (parseNatural)
import Bridge.RPC
import Data.Binary.Get
import qualified Data.ByteString.Base64 as B64
import qualified Data.Text.Encoding as TE
import Bridge.Solana (tokenProgram)
import Bridge.SolanaMessage (publicKey,base58,decodeLiquidityTransaction,Transaction(..),Message(..),Instruction(..))
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import qualified Data.ByteString as B
import Data.List (nub,sort)
import Data.Text (Text)
import Data.Word (Word64)

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
    units bound text=maybe (fail "invalid canonical liquidity amount") pure (parseNatural bound text)
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
  unless (if collect then liquidity r>=0 && liquidity r<2^(128::Int) && limitA r==0 && limitB r==0 else liquidity r>0 && liquidity r<2^(128::Int)) (Left "invalid_liquidity_limits")
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
      expected=if collect then (if liquidity r>0 then [update] else [])<>[collectFees] else [change]
      semantic (Instruction ix indices payload)=(keys !! fromIntegral ix,map ((keys !!) . fromIntegral) indices,payload)
      refresh=not collect || liquidity r>0
      identities=[owner,pool,pos,nft,oa,ob,va,vb,token,program]<>(if refresh then [lo,hi] else [])
      writable=[owner,pos,oa,ob,va,vb]<>(if refresh then [pool] else [])<>(if collect then [] else [lo,hi])
  unless (n==1 && rs==0 && fromIntegral ru==length keys-length writable && take 1 keys==[owner] && recent==hash
    && length(nub identities)==(if refresh then 12 else 10) && sort keys==sort identities && sort(take (length writable) keys)==sort writable
    && map semantic instructions==expected && all (B.all (==0)) signatures) (Left "liquidity_transaction_mismatch")
  pure tx

data Effect = Effect {spentA :: Integer,spentB :: Integer,liquidityDelta :: Integer,maximumDebit :: Integer} deriving (Eq,Show)
instance ToJSON Effect where
  toJSON e=object ["spentA" .= show(spentA e),"spentB" .= show(spentB e),"liquidityDelta" .= show(liquidityDelta e),"maximumDebit" .= show(maximumDebit e)]

data Safe a where
  Check :: FilePath -> Pool.Network -> String -> Word64 -> Word64 -> Request -> Prepared -> Safe Effect
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

evalSafe (Check library network endpoint feeLimit costLimit r p)=do
  canonical<-evalSafe(Prepare library r)
  require (canonical==p && feeLimit>0 && costLimit>=feeLimit) "liquidity_preparation_or_limits_mismatch"
  Transaction _ _ message<-either reject pure(validate r p)
  withSolanaRpc endpoint (Pool.networkGenesis network) ("liquidity_requires_https","wrong_liquidity_network") $ \call->do
    let request=positionRequest r
        identities=[Position.pool request,Pool.configuration network,Position.mintA request,Position.mintB request,vaultA r,vaultB r
          ,position p,Position.positionMint request,positionToken p,ownerA p,ownerB p,Position.payer request]
        simulatedIndices=[0,4,5,6,7,8,9,10,11::Int]
        options=object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text)]
    before<-call "getMultipleAccounts" [toJSON identities,options]
    context<-fieldValue "context" before
    height<-fieldValue "slot" context
    rows<-fieldValue "value" before
    let snapshot=Pool.Snapshot height rows
    state<-either reject pure(inspect network r snapshot)
    require (verb r/=Collect || positionLiquidity state==liquidity r) "collection_liquidity_changed"
    poolAddress<-Pool.evalSafe(Pool.Address library network (Position.mintA request) (Position.mintB request) (Pool.tier $ poolState state))
    require (poolAddress==Position.pool request) "liquidity_pool_address_mismatch"
    quote<-call "getFeeForMessage" [toJSON $ TE.decodeUtf8 $ B64.encode message,object ["commitment" .= ("finalized"::Text),"minContextSlot" .= height]] >>= fieldValue "value" :: IO (Maybe Integer)
    fee<-case quote of Just n | n>0 && n<=toInteger feeLimit && n<=payerBalance state->pure n; _->reject "liquidity_fee_unavailable_or_excessive"
    result<-call "simulateTransaction" [toJSON(transaction p),object
      ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"minContextSlot" .= height,"sigVerify" .= False,"replaceRecentBlockhash" .= False
      ,"accounts" .= object ["encoding" .= ("base64"::Text),"addresses" .= [identities !! index | index<-simulatedIndices]]]]
    simulation<-fieldValue "value" result
    failure<-fieldValue "err" simulation :: IO Value
    require (failure==Null) "liquidity_simulation_failed"
    simulatedContext<-fieldValue "context" result
    simulatedSlot<-fieldValue "slot" simulatedContext
    simulatedRows<-fieldValue "accounts" simulation :: IO [Value]
    require (length simulatedRows==length simulatedIndices) "liquidity_simulation_account_count"
    -- Config and pool-asset mints are absent from the validated instruction's
    -- writable set. Keep their preflight facts; request every mutable balance,
    -- position, and ownership account within Solana's simulation account limit.
    let afterRows=[maybe original id (lookup index $ zip simulatedIndices simulatedRows) | (index,original)<-zip [0..] rows]
    either reject pure(validateEffects network r fee costLimit snapshot (Pool.Snapshot simulatedSlot afterRows))

-- Facts needed to check one operation; all quantities stay unbounded until checked.
data State = State {poolState :: Pool.Whirlpool,positionLiquidity :: Integer,feesA :: Word64,feesB :: Word64
  ,balanceA :: Integer,balanceB :: Integer,vaultBalanceA :: Integer,vaultBalanceB :: Integer,payerBalance :: Integer}
inspect :: Pool.Network -> Request -> Pool.Snapshot -> Either Text State
inspect network r snapshot=do
  let request=positionRequest r
  Pool.Report _ _ pool _<-Pool.validate network (Pool.Expected (Position.pool request) (Position.mintA request) (Position.mintB request))
    snapshot {Pool.accounts=take 6 $ Pool.accounts snapshot}
  unless (Pool.spacing pool==32896 && Pool.vaultA pool==vaultA r && Pool.vaultB pool==vaultB r) (Left "liquidity_pool_identity_mismatch")
  case drop 6 (Pool.accounts snapshot) of
    [posInfo,mintInfo,nftInfo,aInfo,bInfo,payerInfo]->do
      (actualPool,actualMint,quantity,owedA,owedB)<-Pool.accountData Pool.program 216 posInfo >>= Pool.parse (do
        discriminator<-getByteString 8; pool<-base58 <$> getByteString 32; mint<-base58 <$> getByteString 32
        lo<-getWord64le; hi<-getWord64le; lower<-getInt32le; upper<-getInt32le
        skip 16; a<-getWord64le; skip 16; b<-getWord64le; skip 72
        unless (discriminator==B.pack [170,188,143,228,122,64,247,208] && lower== -427648 && upper==427648) (fail "invalid full-range position")
        pure(pool,mint,toInteger lo+toInteger hi*2^(64::Int),a,b))
      unless (actualPool==Position.pool request && actualMint==Position.positionMint request) (Left "liquidity_position_identity_mismatch")
      mint<-Pool.accountData tokenProgram 82 mintInfo >>= Pool.parse Pool.mintParser
      nft<-Pool.accountData tokenProgram 165 nftInfo >>= Pool.parse (Pool.vaultParser actualMint (Position.payer request))
      unless (mint==(0,1,Nothing,Nothing) && nft==1) (Left "liquidity_position_not_owned")
      a<-tokenBalance (Position.mintA request) (Position.payer request) aInfo
      b<-tokenBalance (Position.mintB request) (Position.payer request) bInfo
      va<-tokenBalance (Position.mintA request) (Position.pool request) (Pool.accounts snapshot !! 4)
      vb<-tokenBalance (Position.mintB request) (Position.pool request) (Pool.accounts snapshot !! 5)
      (owner,executable,lamports)<-either (const $ Left "invalid_liquidity_payer") Right $ parseEither
        (withObject "payer" $ \o->(,,) <$> o .: "owner" <*> o .: "executable" <*> o .: "lamports") payerInfo
      unless (owner==("11111111111111111111111111111111"::Text) && not executable && lamports>=0) (Left "invalid_liquidity_payer")
      pure(State pool quantity owedA owedB a b va vb lamports)
    _->Left "liquidity_snapshot_account_count"
 where
  tokenBalance mint owner value=toInteger <$> (Pool.accountData tokenProgram 165 value >>= Pool.parse (Pool.vaultParser mint owner))

validateEffects :: Pool.Network -> Request -> Integer -> Word64 -> Pool.Snapshot -> Pool.Snapshot -> Either Text Effect
validateEffects network r fee maxCost before after=do
  a<-inspect network r before; b<-inspect network r after
  let spentA=balanceA a-balanceA b; spentB=balanceB a-balanceB b
      delta=case verb r of Deposit->liquidity r; Withdraw->negate(liquidity r); Collect->0
      price=Pool.sqrtPrice(poolState a); tick=Pool.tick(poolState a)
      poolDelta=if tick>= -427648 && tick<427648 then delta else 0
      debit=payerBalance a-payerBalance b+fee
      limit x maximum=case verb r of Deposit->x>=0 && x<=toInteger maximum; Withdraw->x<=negate(toInteger maximum); Collect->x<=0
      unchanged index=Pool.accounts before !! index==Pool.accounts after !! index
  unless (Pool.slot after>=Pool.slot before && fee>0 && debit>=fee && debit<=toInteger maxCost
    && positionLiquidity b-positionLiquidity a==delta && Pool.liquidity(poolState b)-Pool.liquidity(poolState a)==poolDelta
    && Pool.sqrtPrice(poolState b)==price && Pool.tick(poolState b)==tick
    && spentA==vaultBalanceA b-vaultBalanceA a && spentB==vaultBalanceB b-vaultBalanceB a
    && limit spentA (limitA r) && limit spentB (limitB r) && all unchanged [1,2,3,7,8]
    && (verb r/=Collect || (positionLiquidity a==liquidity r && feesA b==0 && feesB b==0))) (Left "liquidity_effect_or_cost_mismatch")
  pure(Effect spentA spentB delta debit)
