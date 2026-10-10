-- Validation of actual getTransaction JSON, independent of current account state.
-- An unclassified result must remain a liability and must not authorize a payout.
{-# LANGUAGE RecordWildCards #-}
module Bridge.SolanaDeposit
  ( PayBinding(..), payInstruction, payReference, payURIFor, transactionKeys, verifyPay
  , DepositBinding(..), SolanaDeposit(..), verifyDeposit
  , CustodyEffect(..), custodyEffect, LamportEffect(..), lamportEffect, transactionMemo, transactionAccounts, historicalTokenBalance, depositInstructions
  ) where

import Bridge.Solana (tokenProgram)
import Bridge.Identity (publicKey, payInstruction, payReference)
import Bridge.Domain (Amount, amount, units, parseUnits, renderCoins)
import Control.Monad (unless,when)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import Data.Binary.Get (getWord64le,runGet)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base58 as B58
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.List (elemIndices,nub)
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

-- RPC JSON normalizes instruction/account indexing across legacy, v0 and v1.
-- v1 has inline accounts only. Fees/effects are read from finalized metadata,
-- never inferred from its new transactionConfig or ComputeBudget instructions.
transactionFormat :: Value -> Parser ()
transactionFormat value = do
  version <- optional "version" value :: Parser (Maybe Value)
  ensure (version `elem` [Nothing,Just(String "legacy"),Just(Number 0),Just(Number 1)]) "unsupported transaction version"
  when (version==Just(Number 1)) $ do
    message <- get "transaction" value >>= get "message"
    meta <- get "meta" value
    static <- get "accountKeys" message :: Parser [Text]
    accounts <- transactionAccounts message meta
    lookups <- optional "addressTableLookups" message :: Parser (Maybe [Value])
    _ <- get "transactionConfig" message :: Parser Object
    ensure (length static<=64 && accounts==static && maybe True null lookups) "invalid v1 accounts"

-- Classification is intentionally broader than automatic deposit authorization:
-- a successful CPI or no-memo receipt still changes custody and must be held.
data CustodyEffect = CustodyEffect
  { effectSlot :: !Int64, effectDelta :: !Integer, effectFailed :: !Bool
  , effectClosed :: !Bool
  } deriving (Eq,Show)

data LamportEffect = LamportEffect
  { lamportSlot :: !Int64, lamportDelta :: !Integer
  , lamportFailed :: !Bool, lamportFee :: !Amount, lamportBefore :: !Amount
  } deriving (Eq,Show)

-- Observe every change to the dedicated fee-payer address, including fees of
-- failed transactions and ordinary SOL funding with no token-account reference.
lamportEffect :: Text -> Text -> Value -> Either Text LamportEffect
lamportEffect signature address = either (const $ Left "unclassified_lamport_effect") Right . parseEither inspect
 where
  inspect value = do
    transactionFormat value
    slot <- get "slot" value
    ensure (slot>=0) "invalid slot"
    tx <- get "transaction" value
    signatures <- get "signatures" tx :: Parser [Text]
    ensure (take 1 signatures==[signature]) "wrong signature"
    msg <- get "message" tx
    meta <- get "meta" value
    keys <- transactionAccounts msg meta
    idx <- case elemIndices address keys of [i]->pure i; _->fail "missing or duplicate fee address"
    before <- get "preBalances" meta :: Parser [Integer]
    after <- get "postBalances" meta :: Parser [Integer]
    ensure (length before==length keys && length after==length keys && all (>=0) (before<>after)) "invalid lamport balances"
    err <- get "err" meta :: Parser Value
    transactionFee <- get "fee" meta >>= either (fail . T.unpack) pure . amount
    let delta=after!!idx-before!!idx
    charged <- if idx==0 then pure transactionFee else either (fail . T.unpack) pure (amount 0)
    ensure (err==Null || delta==negate (toInteger $ units charged)) "failed transaction changed principal"
    initial <- either (fail . T.unpack) pure (amount $ before!!idx)
    pure (LamportEffect slot delta (err/=Null) charged initial)

custodyEffect :: Text -> Text -> Text -> Text -> Value -> Either Text CustodyEffect
custodyEffect signature mint custody owner =
  either (const $ Left "unclassified_custody_effect") Right . parseEither parseEffect
 where
  parseEffect value = do
    transactionFormat value
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
      [_] -> historicalTokenBalance mint idx owner entries
      _ -> fail "duplicate balance"

transactionAccounts :: Value -> Value -> Parser [Text]
transactionAccounts message meta = do
  static <- get "accountKeys" message
  loaded <- optional "loadedAddresses" meta
  writable <- maybe (pure []) (get "writable") loaded
  readonly <- maybe (pure []) (get "readonly") loaded
  let accounts=static<>writable<>readonly
  ensure (not (null static) && length accounts<=256 && length (nub accounts)==length accounts) "invalid accounts"
  mapM_ (either (fail . T.unpack) pure . publicKey) accounts
  pure accounts

transactionMemo :: Value -> Maybe Text
transactionMemo value = either (const Nothing) id $ parseEither parseMemo value
 where
  parseMemo v = do
    transactionFormat v
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
  transactionFormat value
  transaction <- get "transaction" value
  signatures <- get "signatures" transaction :: Parser [Text]
  ensure (signatures==[boundSignature]) "unexpected signer count or transaction"
  message <- get "message" transaction
  header <- get "header" message
  required <- get "numRequiredSignatures" header :: Parser Int
  keys <- get "accountKeys" message :: Parser [Text]
  ensure (required==1 && take 1 keys==[boundOwner]) "bound owner must be the payer and sole signer"
  accounts <- transactionAccounts message meta
  instructions <- get "instructions" message :: Parser [Value]
  ensure (length instructions>=2 && length instructions<=4) "unsupported instructions"
  semantic <- depositInstructions accounts instructions
  let memoProgram="MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
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
  balance = historicalTokenBalance boundMint

-- Require one historical entry with the expected owner, mint and precision.
historicalTokenBalance :: Text -> Int -> Text -> [Value] -> Parser Integer
historicalTokenBalance mint index owner entries = do
  matches <- mapM (\entry->do i <- get "accountIndex" entry; pure(i::Int,entry)) entries
  case [entry | (i,entry)<-matches,i==index] of
    [entry]->do
      actualMint <- get "mint" entry; actualOwner <- get "owner" entry
      ensure (actualMint==mint && actualOwner==owner) "wrong historical identity"
      tokens <- get "uiTokenAmount" entry
      decimals <- get "decimals" tokens :: Parser Int
      ensure (decimals==8) "wrong decimals"
      raw <- get "amount" tokens
      toInteger . units <$> either (fail . T.unpack) pure(parseUnits raw)
    _->fail "missing historical balance"

-- Decode bounded top-level instructions and remove only supported compute-budget
-- directives. Each deposit protocol checks its own remaining instruction shape.
depositInstructions :: [Text] -> [Value] -> Parser [(Text,[Int],[Text],BS.ByteString)]
depositInstructions keys instructions = do
  ensure (length instructions<=4) "too many deposit instructions"
  decoded <- mapM (\ix->do
    program <- get "programIdIndex" ix >>= account
    indices <- get "accounts" ix :: Parser [Int]
    ensure (length indices<=8) "too many instruction accounts"
    names <- mapM account indices
    raw <- get "data" ix
    ensure (T.length raw<=512) "oversized instruction"
    bytes <- maybe (fail "invalid instruction") pure (B58.decodeBase58 B58.bitcoinAlphabet $ TE.encodeUtf8 raw)
    when (program==budget) $ ensure (null indices &&
      (BS.take 1 bytes==BS.singleton 2 && BS.length bytes==5 ||
       BS.take 1 bytes==BS.singleton 3 && BS.length bytes==9)) "unsupported budget"
    pure (program,indices,names,bytes)) instructions
  pure [row | row@(program,_,_,_)<-decoded,program/=budget]
 where
  budget="ComputeBudget111111111111111111111111111111"
  account i=if i>=0 && i<length keys then pure(keys!!i) else fail "invalid index"

data PayBinding = PayBinding
  { paySignature :: Text, payMint :: Text, payCustody :: Text
  , payCustodyOwner :: Text, payOrderReference :: Text } deriving (Eq,Show)

payURIFor :: Text -> Text -> Text -> Amount -> Either Text Text
payURIFor owner mintId instruction quantity = do
  reference <- maybe (Left "invalid_pay_reference") Right(T.stripPrefix "solana-pay:" instruction)
  _ <- publicKey reference
  _ <- publicKey owner
  _ <- publicKey mintId
  pure("solana:"<>owner<>"?amount="<>renderCoins quantity<>"&spl-token="<>mintId<>"&reference="<>reference<>"&label=ECX%20Bridge")

transactionKeys :: Value -> Either Text [Text]
transactionKeys = either (const $ Left "invalid_pay_accounts") Right . parseEither (\value->do
  transactionFormat value
  transaction <- get "transaction" value; message <- get "message" transaction; meta <- get "meta" value; transactionAccounts message meta)

verifyPay :: PayBinding -> Value -> Either Text SolanaDeposit
verifyPay binding = either (const $ Left "unclassified_solana_pay_deposit") Right . parseEither (verifyPayProof binding)
verifyPayProof :: PayBinding -> Value -> Parser SolanaDeposit
verifyPayProof PayBinding{..} value = do
  slot <- get "slot" value :: Parser Int64
  ensure (slot>=0) "invalid slot"
  meta <- get "meta" value
  err <- get "err" meta :: Parser Value
  ensure (err==Null) "failed transfer"
  transactionFormat value
  tx <- get "transaction" value
  signatures <- get "signatures" tx :: Parser [Text]
  message <- get "message" tx
  header <- get "header" message
  static <- get "accountKeys" message :: Parser [Text]
  required <- get "numRequiredSignatures" header :: Parser Int
  readonlySigned <- get "numReadonlySignedAccounts" header :: Parser Int
  readonlyUnsigned <- get "numReadonlyUnsignedAccounts" header :: Parser Int
  ensure (required>0 && required<=length static && length signatures==required && take 1 signatures==[paySignature] && readonlySigned>=0 && readonlySigned<=required && readonlyUnsigned>=0 && readonlyUnsigned<=length static-required) "invalid signers"
  keys <- transactionAccounts message meta
  referenceIndex <- case elemIndices payOrderReference static of [i]->pure i; _->fail "reference must be static"
  ensure (referenceIndex>=required && referenceIndex>=length static-readonlyUnsigned) "reference must be read-only non-signer"
  instructions <- get "instructions" message :: Parser [Value]
  ensure (not(null instructions) && length instructions<=4) "unsupported instructions"
  semantic <- depositInstructions keys instructions
  ensure (length semantic==1) "only the requested transfer is accepted"
  (sourceIndex,destinationIndex,source,owner,n) <- case semantic of
    [(p,indices,names,bytes)] | p==tokenProgram->do
      (si,di,source,owner) <- case (indices,names) of
        ([si,_,di,authority,reference],[source,mint,destination,owner,ref]) | BS.length bytes==10 && BS.head bytes==12 && BS.last bytes==8->do
          ensure (mint==payMint && destination==payCustody && ref==payOrderReference && reference==referenceIndex && authority<required) "wrong checked transfer"
          pure(si,di,source,owner)
        ([si,di,authority,reference],[source,destination,owner,ref]) | BS.length bytes==9 && BS.head bytes==3->do
          ensure (destination==payCustody && ref==payOrderReference && reference==referenceIndex && authority<required) "wrong transfer"
          pure(si,di,source,owner)
        _->fail "unsupported transfer"
      quantity <- either (fail . T.unpack) pure(amount $ toInteger $ runGet getWord64le $ LBS.fromStrict $ BS.take 8 $ BS.drop 1 bytes)
      ensure (units quantity>0 && source/=payCustody && owner/=payCustodyOwner) "invalid source"
      pure(si,di,source,owner,quantity)
    _->fail "wrong transfer"
  inner <- optional "innerInstructions" meta :: Parser(Maybe [Value])
  mapM_ (\group->get "instructions" group >>= \rows->ensure (null(rows::[Value])) "unexpected CPI") (maybe [] id inner)
  pre <- get "preTokenBalances" meta
  post <- get "postTokenBalances" meta
  beforeSource <- historicalTokenBalance payMint sourceIndex owner pre
  afterSource <- historicalTokenBalance payMint sourceIndex owner post
  beforeCustody <- historicalTokenBalance payMint destinationIndex payCustodyOwner pre
  afterCustody <- historicalTokenBalance payMint destinationIndex payCustodyOwner post
  ensure (beforeSource-afterSource==toInteger(units n) && afterCustody-beforeCustody==toInteger(units n)) "historical balance mismatch"
  pure(SolanaDeposit paySignature slot source owner payMint payCustody n ("solana-pay:"<>payOrderReference))
