module Bridge.Solana where

import Bridge.Config
import Bridge.RPC
import Bridge.Types
import Bridge.SolanaMessage (publicKey)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager)

solanaCall :: Manager -> Config -> Text -> [Value] -> IO Value
solanaCall manager c = rpc manager (solanaRpc c) Nothing
solanaIdentity :: Manager -> Config -> IO Value
solanaIdentity manager c = do
  genesis <- solanaCall manager c "getGenesisHash" [] >>= parseValue parseJSON
  require (genesis==solanaGenesis (profile c)) "wrong_solana_genesis"
  let opts=object ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]
  response <- solanaCall manager c "getAccountInfo" [toJSON (mint c),opts]
  account <- fieldValue "value" response
  require (account/=Null) "mint_not_found"
  program <- fieldValue "owner" account
  require (program==tokenProgram) "wrong_token_program"
  dataValue <- fieldValue "data" account
  parsed <- fieldValue "parsed" dataValue
  kind <- fieldValue "type" parsed :: IO Text
  info <- fieldValue "info" parsed
  decimals <- fieldValue "decimals" info :: IO Int
  initialized <- fieldValue "isInitialized" info :: IO Bool
  freeze <- fieldValue "freezeAuthority" info :: IO (Maybe Text)
  require (kind=="mint" && decimals==8 && initialized && freeze==Nothing) "unsupported_mint_policy"
  _ <- tokenAccount manager c (custodyAta c) (custodyOwner c)
  case solanaVerifierRpc c of
    Just verifier -> do
      independent <- rpc manager verifier Nothing "getGenesisHash" [] >>= parseValue parseJSON
      require (independent==genesis) "verifier_wrong_genesis"
    Nothing -> require (profile c/=CanonicalBeta) "verifier_required"
  pure info

tokenAccount :: Manager -> Config -> Text -> Text -> IO Value
tokenAccount manager c address expectedOwner = do
  _ <- either reject pure (publicKey address)
  response <- solanaCall manager c "getAccountInfo" [toJSON address,object ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]]
  v <- fieldValue "value" response
  require (v/=Null) "token_account_missing"
  _ <- either reject pure (inspectTokenAccount (mint c) expectedOwner v)
  fieldValue "data" v >>= fieldValue "parsed" >>= fieldValue "info"

inspectTokenAccount :: Text -> Text -> Value -> Either Text Amount
inspectTokenAccount expectedMint expectedOwner = either (const $ Left "token_account_policy_mismatch") Right . parseEither inspect
 where
  field key = withObject "account field" (.: key)
  inspect v = do
    program <- field "owner" v
    executable <- field "executable" v :: Parser Bool
    dat <- field "data" v
    space <- field "space" dat :: Parser Int
    parsed <- field "parsed" dat
    kind <- field "type" parsed :: Parser Text
    info <- field "info" parsed
    owner <- field "owner" info
    token <- field "mint" info
    state <- field "state" info :: Parser Text
    isNative <- field "isNative" info :: Parser Bool
    delegate <- withObject "token info" (.:? "delegate") info :: Parser (Maybe Text)
    closeAuthority <- withObject "token info" (.:? "closeAuthority") info :: Parser (Maybe Text)
    balance <- field "tokenAmount" info
    decimals <- field "decimals" balance :: Parser Int
    unless (program==tokenProgram && not executable && space==165 && kind=="account"
      && owner==expectedOwner && token==expectedMint && state=="initialized" && not isNative
      && delegate==Nothing && closeAuthority==Nothing && decimals==8) (fail "unsupported token account")
    field "amount" balance >>= either (fail . T.unpack) pure . parseUnits
finalizedTransaction :: Manager -> Config -> Text -> IO Value
finalizedTransaction manager c signature = solanaCall manager c "getTransaction"
  [toJSON signature,object ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
solanaHistory :: Manager -> Config -> Maybe Text -> Maybe Text -> IO Value
solanaHistory manager c before untilSig = solanaCall manager c "getSignaturesForAddress"
  [toJSON (custodyAta c),object $ ["commitment" .= ("finalized"::Text),"limit" .= (100::Int)] <> maybe [] (\t->["before" .= t]) before <> maybe [] (\t->["until" .= t]) untilSig]
broadcastSolana :: Manager -> Config -> Text -> IO Text
broadcastSolana manager c bytes = solanaCall manager c "sendTransaction"
  [toJSON bytes,object ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("confirmed"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
