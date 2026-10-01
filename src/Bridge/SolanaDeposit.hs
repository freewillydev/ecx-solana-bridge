-- Validation of actual getTransaction JSON, independent of current account state.
-- An unclassified result must remain a liability and must not authorize a payout.
module Bridge.SolanaDeposit
  ( DepositBinding(..), SolanaDeposit(..), verifyDeposit
  , CustodyEffect(..), custodyEffect, transactionMemo
  ) where

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
import Data.List (elemIndices)
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

-- Classification is intentionally broader than automatic deposit authorization:
-- a successful CPI or no-memo receipt still changes custody and must be held.
data CustodyEffect = CustodyEffect
  { effectSlot :: !Int64, effectDelta :: !Integer, effectFailed :: !Bool
  , effectClosed :: !Bool
  } deriving (Eq,Show)

custodyEffect :: Text -> Text -> Text -> Text -> Value -> Either Text CustodyEffect
custodyEffect signature mint custody owner =
  either (const $ Left "unclassified_custody_effect") Right . parseEither parseEffect
 where
  parseEffect value = do
    slot <- get "slot" value
    ensure (slot>=0) "invalid slot"
    transaction <- get "transaction" value
    signatures <- get "signatures" transaction :: Parser [Text]
    ensure (take 1 signatures==[signature]) "wrong signature"
    message <- get "message" transaction
    meta <- get "meta" value
    keys <- transactionAccounts message meta
    idx <- case elemIndices custody keys of [i] -> pure i; _ -> fail "missing or duplicate custody"
    before <- get "preTokenBalances" meta
    after <- get "postTokenBalances" meta
    preLamports <- get "preBalances" meta :: Parser [Integer]
    postLamports <- get "postBalances" meta :: Parser [Integer]
    ensure (length preLamports==length keys && length postLamports==length keys) "missing lamport balances"
    pre <- historical idx (preLamports!!idx) before
    post <- historical idx (postLamports!!idx) after
    err <- get "err" meta :: Parser Value
    ensure (err==Null || pre==post) "failed transaction changed token balance"
    pure $ CustodyEffect slot (post-pre) (err/=Null) (postLamports!!idx==0)
  historical idx lamports entries = do
    ensure (lamports>=0) "invalid lamports"
    indexes <- mapM (get "accountIndex") entries :: Parser [Int]
    case [v | (i,v)<-zip indexes entries,i==idx] of
      [] -> ensure (lamports==0) "missing historical token metadata" >> pure 0
      [v] -> do
        actualMint <- get "mint" v
        actualOwner <- get "owner" v
        ensure (actualMint==mint && actualOwner==owner) "historical custody identity mismatch"
        tokenAmount <- get "uiTokenAmount" v
        decimals <- get "decimals" tokenAmount :: Parser Int
        ensure (decimals==8) "wrong decimals"
        raw <- get "amount" tokenAmount
        quantity <- either (fail . T.unpack) pure (parseUnits raw)
        pure (toInteger $ units quantity)
      _ -> fail "duplicate balance"

transactionAccounts :: Value -> Value -> Parser [Text]
transactionAccounts message meta = do
  static <- get "accountKeys" message
  loaded <- optional "loadedAddresses" meta
  writable <- maybe (pure []) (get "writable") loaded
  readonly <- maybe (pure []) (get "readonly") loaded
  let accounts=static<>writable<>readonly
  ensure (not (null accounts) && length accounts<=256 && all ((<=44) . T.length) accounts) "invalid accounts"
  pure accounts

transactionMemo :: Value -> Maybe Text
transactionMemo value = either (const Nothing) id $ parseEither parseMemo value
 where
  parseMemo v = do
    transaction <- get "transaction" v
    message <- get "message" transaction
    meta <- get "meta" v
    keys <- transactionAccounts message meta
    instructions <- get "instructions" message :: Parser [Value]
    ensure (length instructions<=64) "too many instructions"
    candidates <- mapM (\ix -> do
      index <- get "programIdIndex" ix :: Parser Int
      ensure (index>=0 && index<length keys) "invalid program index"
      if keys!!index/="MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr" then pure Nothing else do
        encoded <- get "data" ix
        ensure (T.length encoded<=256) "memo too long"
        raw <- maybe (fail "invalid memo") pure (B58.decodeBase58 B58.bitcoinAlphabet (TE.encodeUtf8 encoded))
        memo <- either (const $ fail "non-UTF8 memo") pure (TE.decodeUtf8' raw)
        ensure (T.length memo<=160) "memo too long"
        pure (Just memo)) instructions
    case [memo | Just memo<-candidates] of [memo] -> pure (Just memo); _ -> pure Nothing

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
