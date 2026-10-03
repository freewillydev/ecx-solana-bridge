{-# LANGUAGE GADTs #-}
-- Read-only preflight; simulation always contains zero signatures.
module Token.Network (Network(..),Safe(..),Critical(..),evalSafe,evalCritical) where
import Token.Signing (Saved(..),validateSaved)
import qualified Data.ByteString as BS
import System.IO (withBinaryFile,IOMode(ReadMode))
import Token (Request(..),Action(..),validate)
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.Solana (tokenProgram)
import Bridge.SolanaMessage (Transaction(..),publicKey)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Network.HTTP.Client (parseRequest,secure,closeManager)
import Text.Read (readMaybe)

data Network = Devnet | Mainnet deriving (Eq,Show)
data Safe a where
  Check :: Network -> String -> Word64 -> Request -> Text -> Safe Word64

evalSafe :: Safe a -> IO a
evalSafe (Check network endpoint feeLimit request unsigned)=do
  transport<-parseRequest endpoint
  require (secure transport && feeLimit>0) "invalid_token_rpc_policy"
  Transaction _ _ message<-either reject pure (validate request unsigned)
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
        options=object ["encoding" .= ("jsonParsed"::Text),"commitment" .= ("finalized"::Text)]
        accountInfo address=call "getAccountInfo" [toJSON address,options] >>= fieldValue "value"
    genesis<-call "getGenesisHash" [] >>= parseValue parseJSON :: IO Text
    require (genesis==case network of Devnet->"EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"; Mainnet->"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d") "wrong_token_network"
    mintInfo<-accountInfo (mint request) >>= parseValue inspectMint
    tokenInfo<-accountInfo (account request) >>= parseValue inspectAccount
    let (mintAuthority,supply)=mintInfo
        (owner,balance,token)=tokenInfo
    require (token==mint request) "token_account_mint_mismatch"
    case action request of
      Mint->require (mintAuthority==Just(authority request) && toInteger supply+toInteger(quantity request)<=toInteger(maxBound::Word64)) "token_mint_authority_or_supply"
      Burn->require (owner==authority request && balance>=quantity request && supply>=quantity request) "token_burn_authority_or_balance"
    -- Both writable token accounts and the mint are checked above; reject a
    -- non-system fee payer, even if an RPC simulation would accept it.
    payer<-accountInfo (authority request)
    payerOwner<-fieldValue "owner" payer :: IO Text
    executable<-fieldValue "executable" payer
    lamports<-fieldValue "lamports" payer :: IO Integer
    require (payerOwner=="11111111111111111111111111111111" && not executable) "unsupported_token_fee_payer"
    feeValue<-call "getFeeForMessage" [toJSON $ TE.decodeUtf8 $ B64.encode message,object ["commitment" .= ("finalized"::Text)]]
    fee<-fieldValue "value" feeValue :: IO (Maybe Integer)
    n<-case fee of Just n | n>0 && n<=toInteger feeLimit && n<=lamports->pure(fromInteger n); _->reject "token_fee_unavailable_or_excessive"
    simulation<-call "simulateTransaction" [toJSON unsigned,object
      ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"sigVerify" .= False,"replaceRecentBlockhash" .= False]]
    result<-fieldValue "value" simulation
    failure<-fieldValue "err" result :: IO Value
    require (failure==Null) "token_simulation_failed"
    pure n

-- Submission has no signing capability: retries can only send the saved bytes.
data Critical a where
  Submit :: Network -> String -> Word64 -> FilePath -> Critical Value

evalCritical :: Critical a -> IO a
evalCritical (Submit network endpoint feeLimit path)=do
  bytes<-withBinaryFile path ReadMode (`BS.hGet` 8193)
  require (BS.length bytes<=8192) "token_attempt_too_large"
  saved<-either (const $ reject "invalid_token_attempt") pure (eitherDecodeStrict' bytes)
  unsigned<-either reject pure (validateSaved saved)
  transport<-parseRequest endpoint
  require (secure transport && feeLimit>0) "invalid_token_rpc_policy"
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
        identifier=savedId saved
    genesis<-call "getGenesisHash" [] >>= parseValue parseJSON :: IO Text
    require (genesis==case network of Devnet->"EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"; Mainnet->"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d") "wrong_token_network"
    statuses<-call "getSignatureStatuses" [toJSON [identifier],object ["searchTransactionHistory" .= True]] >>= fieldValue "value"
    status<-case statuses of [value]->pure value; _->reject "invalid_token_status"
    if status/=Null then do
      commitment<-fieldValue "confirmationStatus" status :: IO (Maybe Text)
      failure<-fieldValue "err" status :: IO Value
      if commitment/=Just "finalized" then pure $ object ["signature" .= identifier,"status" .= ("pending"::Text)] else do
        result<-call "getTransaction" [toJSON identifier,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
        transaction<-fieldValue "transaction" result :: IO [Text]
        require (transaction==[savedTransaction saved,"base64"]) "token_finalized_bytes_mismatch"
        metadata<-fieldValue "meta" result
        errorValue<-fieldValue "err" metadata :: IO Value
        fee<-fieldValue "fee" metadata :: IO Integer
        require (errorValue==failure && fee>=0 && fee<=toInteger feeLimit) "token_finalized_metadata_mismatch"
        pure $ object ["signature" .= identifier,"status" .= (if failure==Null then "finalized" else "failed"::Text),"feeLamports" .= fee]
    else do
      _<-evalSafe (Check network endpoint feeLimit (savedRequest saved) unsigned)
      result<-call "sendTransaction" [toJSON (savedTransaction saved),object
        ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("finalized"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
      require (result==identifier) "token_submission_identifier_mismatch"
      pure $ object ["signature" .= identifier,"status" .= ("submitted"::Text)]

-- Strict classic SPL policies: no extensions, frozen/delegated/native accounts,
-- or hidden close/freeze authority. JSON amounts are canonical unsigned integers.
inspectMint :: Value -> Parser (Maybe Text,Word64)
inspectMint value=do
  info<-accountFields 82 "mint" value
  initialized<-field "isInitialized" info
  decimals<-field "decimals" info :: Parser Int
  freeze<-field "freezeAuthority" info :: Parser (Maybe Text)
  unless (initialized && decimals==8 && freeze==Nothing) (fail "unsupported mint")
  authority<-field "mintAuthority" info
  supply<-field "supply" info >>= units
  pure (authority,supply)
inspectAccount :: Value -> Parser (Text,Word64,Text)
inspectAccount value=do
  info<-accountFields 165 "account" value
  owner<-field "owner" info
  mint<-field "mint" info
  state<-field "state" info :: Parser Text
  native<-field "isNative" info
  delegate<-withObject "token" (.:? "delegate") info :: Parser (Maybe Text)
  close<-withObject "token" (.:? "closeAuthority") info :: Parser (Maybe Text)
  amount<-field "tokenAmount" info
  decimals<-field "decimals" amount :: Parser Int
  unless (state=="initialized" && not native && delegate==Nothing && close==Nothing && decimals==8) (fail "unsupported token account")
  mapM_ (either (fail . T.unpack) (const $ pure ()) . publicKey) [owner,mint]
  balance<-field "amount" amount >>= units
  pure (owner,balance,mint)
accountFields :: Int -> Text -> Value -> Parser Value
accountFields size kind value=do
  owner<-field "owner" value
  executable<-field "executable" value
  dat<-field "data" value
  space<-field "space" dat
  parsed<-field "parsed" dat
  actual<-field "type" parsed
  unless (owner==tokenProgram && not executable && space==size && actual==kind) (fail "unsupported token layout")
  field "info" parsed
field :: FromJSON a => Key -> Value -> Parser a
field key=withObject "field" (.:key)
units :: Text -> Parser Word64
units text=case readMaybe (T.unpack text) :: Maybe Integer of
  Just n | n>=0 && n<=toInteger(maxBound::Word64) && T.pack(show n)==text->pure(fromInteger n)
  _->fail "invalid token units"
