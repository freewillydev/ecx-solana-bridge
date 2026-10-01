-- Validation of actual getTransaction JSON, independent of current account state.
-- An unclassified result must remain a liability and must not authorize a payout.
module Bridge.SolanaDeposit (DepositBinding(..), SolanaDeposit(..), verifyDeposit) where

import Bridge.Config (tokenProgram)
import Bridge.Types
import Control.Monad (unless,when)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import Data.Binary.Get (getWord64le,runGet)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base58 as B58
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data DepositBinding = DepositBinding
  { boundSignature :: Text, boundOwner :: Text, boundMint :: Text
  , boundCustody :: Text, boundCustodyOwner :: Text, boundMemo :: Text
  } deriving (Eq,Show)
data SolanaDeposit = SolanaDeposit
  { verifiedSignature :: Text, verifiedSlot :: Int64, verifiedSourceAccount :: Text
  , verifiedOwner :: Text, verifiedMint :: Text, verifiedCustody :: Text
  , verifiedAmount :: Amount, verifiedMemo :: Text
  } deriving (Eq,Show)
get :: FromJSON a => Key -> Value -> Parser a
get key = withObject "RPC object" (.: key)
optional :: FromJSON a => Key -> Value -> Parser (Maybe a)
optional key = withObject "RPC object" (.:? key)
ensure :: Bool -> String -> Parser ()
ensure ok msg = unless ok (fail msg)
verifyDeposit :: DepositBinding -> Value -> Either Text SolanaDeposit
verifyDeposit binding = either (const $ Left "unclassified_solana_deposit") Right . parseEither (verify binding)
verify :: DepositBinding -> Value -> Parser SolanaDeposit
verify DepositBinding{..} value = do
  slot <- get "slot" value
  ensure (slot >= 0) "invalid slot"
  meta <- get "meta" value
  err <- get "err" meta :: Parser Value
  ensure (err==Null) "failed transaction"
  version <- optional "version" value :: Parser (Maybe Value)
  ensure (version==Nothing || version==Just (String "legacy") || version==Just (Number 0)) "unsupported transaction version"
  transaction <- get "transaction" value
  signatures <- get "signatures" transaction :: Parser [Text]
  ensure (signatures==[boundSignature]) "unexpected signer count or transaction"
  message <- get "message" transaction
  header <- get "header" message
  required <- get "numRequiredSignatures" header :: Parser Int
  keys <- get "accountKeys" message :: Parser [Text]
  ensure (required==1 && take 1 keys==[boundOwner]) "bound owner must be the payer and sole signer"
  loaded <- optional "loadedAddresses" meta
  writable <- maybe (pure []) (get "writable") loaded
  readonly <- maybe (pure []) (get "readonly") loaded
  let accounts=keys<>writable<>readonly
      account i = if i>=0 && i<length accounts then pure (accounts!!i) else fail "bad account index"
  ensure (length accounts<=256) "too many accounts"
  instructions <- get "instructions" message :: Parser [Value]
  ensure (length instructions>=2 && length instructions<=4) "unsupported instructions"
  decoded <- mapM (\v -> do
    p<-get "programIdIndex" v >>= account
    is<-get "accounts" v :: Parser [Int]
    as<-mapM account is
    raw<-get "data" v
    ensure (T.length raw<=512) "instruction too large"
    dat<-maybe (fail "bad base58") pure (B58.decodeBase58 B58.bitcoinAlphabet (TE.encodeUtf8 raw))
    pure (p,is,as,dat)) instructions
  let budgetProgram="ComputeBudget111111111111111111111111111111"
      memoProgram="MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
      semantic=[x | x@(p,_,_,_)<-decoded,p/=budgetProgram]
  mapM_ (\(p,is,_,dat)->when (p==budgetProgram) $ ensure (null is && (BS.take 1 dat==BS.singleton 2 && BS.length dat==5 || BS.take 1 dat==BS.singleton 3 && BS.length dat==9)) "unexpected budget instruction") decoded
  (sourceIndex,custodyIndex,source,rawAmount) <- case semantic of
    [(p,[sourceIndex,_,custodyIndex,_],[source,mint,custody,owner],dat),(m,[0],[memoOwner],memoBytes)] -> do
      ensure (p==tokenProgram && mint==boundMint && custody==boundCustody && owner==boundOwner) "wrong transfer"
      ensure (m==memoProgram && memoOwner==boundOwner && memoBytes==TE.encodeUtf8 boundMemo) "wrong signer-bound memo"
      ensure (BS.length dat==10 && BS.head dat==12 && BS.last dat==8) "not TransferChecked with 8 decimals"
      let n=toInteger (runGet getWord64le (LBS.fromStrict $ BS.take 8 $ BS.drop 1 dat))
      quantity<-either (fail . T.unpack) pure (amount n)
      ensure (units quantity>0) "zero transfer"
      pure (sourceIndex,custodyIndex,source,quantity)
    _ -> fail "unsupported transfer shape"
  inner <- optional "innerInstructions" meta :: Parser (Maybe [Value])
  case inner of
    Nothing -> pure ()
    Just groups -> mapM_ (\g->get "instructions" g >>= \xs -> ensure (null (xs::[Value])) "inner transfer unsupported") groups
  pre <- get "preTokenBalances" meta
  post <- get "postTokenBalances" meta
  sourceBefore <- balance sourceIndex boundOwner pre
  sourceAfter <- balance sourceIndex boundOwner post
  custodyBefore <- balance custodyIndex boundCustodyOwner pre
  custodyAfter <- balance custodyIndex boundCustodyOwner post
  ensure (custodyAfter-custodyBefore==toInteger (units rawAmount) && sourceBefore-sourceAfter==toInteger (units rawAmount)) "inconsistent historical token balances"
  pure $ SolanaDeposit boundSignature slot source boundOwner boundMint boundCustody rawAmount boundMemo
 where
  balance :: Int -> Text -> [Value] -> Parser Integer
  balance idx owner entries = do
    indexes <- mapM (get "accountIndex") entries :: Parser [Int]
    let matches=[entry | (index,entry)<-zip indexes entries,index==idx]
    case matches of
      [v] -> do
        actualOwner<-get "owner" v
        actualMint<-get "mint" v
        ensure (actualOwner==owner && actualMint==boundMint) "historical owner or mint mismatch"
        tokenAmount<-get "uiTokenAmount" v
        decimals<-get "decimals" tokenAmount :: Parser Int
        ensure (decimals==8) "wrong decimals"
        raw<-get "amount" tokenAmount
        a<-either (fail . T.unpack) pure (parseUnits raw)
        pure (toInteger $ units a)
      _ -> fail "missing or duplicated historical balance"
