module Bridge.Solana where

import Bridge.Config
import Bridge.RPC
import Bridge.Types
import Bridge.SolanaMessage (publicKey)
import Data.Aeson
import Data.Text (Text)
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
  program <- fieldValue "owner" v
  require (program==tokenProgram) "unsupported_account_program"
  dat <- fieldValue "data" v
  parsed <- fieldValue "parsed" dat
  info <- fieldValue "info" parsed
  owner <- fieldValue "owner" info
  token <- fieldValue "mint" info
  state <- fieldValue "state" info :: IO Text
  delegate <- parseValue (withObject "token info" (.:? "delegate")) info :: IO (Maybe Text)
  require (owner==expectedOwner && token==mint c && state=="initialized" && delegate==Nothing) "token_account_policy_mismatch"
  pure info
finalizedTransaction :: Manager -> Config -> Text -> IO Value
finalizedTransaction manager c signature = solanaCall manager c "getTransaction"
  [toJSON signature,object ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
solanaHistory :: Manager -> Config -> Maybe Text -> Maybe Text -> IO Value
solanaHistory manager c before untilSig = solanaCall manager c "getSignaturesForAddress"
  [toJSON (custodyAta c),object $ ["commitment" .= ("finalized"::Text),"limit" .= (100::Int)] <> maybe [] (\t->["before" .= t]) before <> maybe [] (\t->["until" .= t]) untilSig]
broadcastSolana :: Manager -> Config -> Text -> IO Text
broadcastSolana manager c bytes = solanaCall manager c "sendTransaction"
  [toJSON bytes,object ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("confirmed"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
