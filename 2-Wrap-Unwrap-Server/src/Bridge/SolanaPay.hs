-- Solana Pay v1 transfer requests and validation of finalized RPC effects.
module Bridge.SolanaPay
  ( PayBinding(..), payInstruction, payReference, payURIFor, transactionKeys, verifyPay ) where
import Bridge.Config (tokenProgram)
import Bridge.Types
import Bridge.SolanaDeposit (SolanaDeposit(..))
import Bridge.SolanaMessage (publicKey)
import Control.Monad (unless,when)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import Data.Binary.Get (getWord64le,runGet)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Hex
import qualified Data.ByteString.Base58 as B58
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.List (nub,elemIndices)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data PayBinding = PayBinding
  { paySignature :: Text, payMint :: Text, payCustody :: Text
  , payCustodyOwner :: Text, payOrderReference :: Text } deriving (Eq,Show)

payReference :: Text -> Either Text Text
payReference oid = do
  raw <- either (const $ Left "invalid_order_reference") Right(Hex.decode $ TE.encodeUtf8 oid)
  if BS.length raw/=32 then Left "invalid_order_reference" else Right(TE.decodeUtf8 $ B58.encodeBase58 B58.bitcoinAlphabet raw)
payInstruction :: Text -> Either Text Text
payInstruction oid = ("solana-pay:"<>) <$> payReference oid
payURIFor :: Text -> Text -> Text -> Amount -> Either Text Text
payURIFor owner mintId instruction quantity = do
  reference <- maybe (Left "invalid_pay_reference") Right(T.stripPrefix "solana-pay:" instruction)
  _ <- publicKey reference
  _ <- publicKey owner
  _ <- publicKey mintId
  pure("solana:"<>owner<>"?amount="<>renderCoins quantity<>"&spl-token="<>mintId<>"&reference="<>reference<>"&label=ECX%20Bridge")

get :: FromJSON a => Key -> Value -> Parser a
get key = withObject "RPC" (.: key)
optional :: FromJSON a => Key -> Value -> Parser(Maybe a)
optional key = withObject "RPC" (.:? key)
ensure :: Bool -> String -> Parser ()
ensure ok message=unless ok(fail message)
accounts :: Value -> Value -> Parser [Text]
accounts message meta = do
  keys <- get "accountKeys" message
  loaded <- optional "loadedAddresses" meta
  writable <- maybe (pure []) (get "writable") loaded
  readonly <- maybe (pure []) (get "readonly") loaded
  let allKeys=keys<>writable<>readonly
  ensure (length allKeys<=256 && length(nub allKeys)==length allKeys) "duplicate/oversized keys"
  mapM_ (either (fail . T.unpack) (const $ pure ()) . publicKey) allKeys
  pure allKeys
transactionKeys :: Value -> Either Text [Text]
transactionKeys = either (const $ Left "invalid_pay_accounts") Right . parseEither (\value->do
  transaction <- get "transaction" value; message <- get "message" transaction; meta <- get "meta" value; accounts message meta)

verifyPay :: PayBinding -> Value -> Either Text SolanaDeposit
verifyPay binding = either (const $ Left "unclassified_solana_pay_deposit") Right . parseEither (verify binding)
verify :: PayBinding -> Value -> Parser SolanaDeposit
verify PayBinding{..} value = do
  slot <- get "slot" value :: Parser Int64
  ensure (slot>=0) "invalid slot"
  meta <- get "meta" value
  err <- get "err" meta :: Parser Value
  ensure (err==Null) "failed transfer"
  version <- optional "version" value :: Parser(Maybe Value)
  ensure (version==Nothing || version==Just(String "legacy") || version==Just(Number 0)) "unsupported version"
  tx <- get "transaction" value
  signatures <- get "signatures" tx :: Parser [Text]
  message <- get "message" tx
  header <- get "header" message
  static <- get "accountKeys" message :: Parser [Text]
  required <- get "numRequiredSignatures" header :: Parser Int
  readonlySigned <- get "numReadonlySignedAccounts" header :: Parser Int
  readonlyUnsigned <- get "numReadonlyUnsignedAccounts" header :: Parser Int
  ensure (required>0 && required<=length static && length signatures==required && take 1 signatures==[paySignature] && readonlySigned>=0 && readonlySigned<=required && readonlyUnsigned>=0 && readonlyUnsigned<=length static-required) "invalid signers"
  keys <- accounts message meta
  referenceIndex <- case elemIndices payOrderReference static of [i]->pure i; _->fail "reference must be static"
  ensure (referenceIndex>=required && referenceIndex>=length static-readonlyUnsigned) "reference must be read-only non-signer"
  let account i=if i>=0 && i<length keys then pure(keys!!i) else fail "invalid index"
  instructions <- get "instructions" message :: Parser [Value]
  ensure (not(null instructions) && length instructions<=4) "unsupported instructions"
  decoded <- mapM (\ix->do
    program <- get "programIdIndex" ix >>= account
    indices <- get "accounts" ix :: Parser [Int]
    names <- mapM account indices
    raw <- get "data" ix
    ensure (T.length raw<=512) "oversized instruction"
    bytes <- maybe (fail "invalid instruction") pure(B58.decodeBase58 B58.bitcoinAlphabet $ TE.encodeUtf8 raw)
    pure(program,indices,names,bytes)) instructions
  let budget="ComputeBudget111111111111111111111111111111"
  forMDecoded decoded budget
  let semantic=[row | row@(p,_,_,_)<-decoded,p/=budget]
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
  beforeSource <- balance payMint sourceIndex owner pre
  afterSource <- balance payMint sourceIndex owner post
  beforeCustody <- balance payMint destinationIndex payCustodyOwner pre
  afterCustody <- balance payMint destinationIndex payCustodyOwner post
  ensure (beforeSource-afterSource==toInteger(units n) && afterCustody-beforeCustody==toInteger(units n)) "historical balance mismatch"
  pure(SolanaDeposit paySignature slot source owner payMint payCustody n ("solana-pay:"<>payOrderReference))
 where
  forMDecoded rows budget = mapM_ (\(p,indices,_,bytes)->when (p==budget) $ ensure (null indices && (BS.take 1 bytes==BS.singleton 2 && BS.length bytes==5 || BS.take 1 bytes==BS.singleton 3 && BS.length bytes==9)) "unsupported budget") rows
balance :: Text -> Int -> Text -> [Value] -> Parser Integer
balance mint index owner entries = do
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
