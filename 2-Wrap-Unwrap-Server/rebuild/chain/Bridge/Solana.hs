module Bridge.Solana
  ( SolanaSettings(..),validateSolanaSettings,solanaCall,solanaIdentity,tokenAccount
  , inspectTokenAccount,finalizedTransaction,solanaHistory,solanaAddressHistory
  , SignatureInfo(..), collectSignatures, tokenProgram,solanaGenesis ) where

import Bridge.Wire (Profile(..))
import Bridge.RPC
import Bridge.Error
import Bridge.Domain
import Bridge.Identity (publicKey)
import Bridge.SolanaMessage (signatureBytes)
import Data.Int (Int64)
import qualified Data.Set as Set
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager,parseRequest,secure,host)
import qualified Data.ByteString as BS

data SolanaSettings = SolanaSettings
  { solanaProfile :: Profile, solanaRpc :: String, solanaVerifierRpc :: Maybe String
  , mint :: Text, custodyOwner :: Text, custodyAta :: Text } deriving (Eq,Show)
tokenProgram, canonicalMint :: Text
tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
canonicalMint = "EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq"
solanaGenesis :: Profile -> Text
solanaGenesis CanonicalBeta = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
solanaGenesis _ = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
validateSolanaSettings :: SolanaSettings -> IO ()
validateSolanaSettings c = do
  mapM_ (either reject (const $ pure ()) . publicKey) [mint c,custodyOwner c,custodyAta c]
  primary <- parseRequest (solanaRpc c)
  verifier <- traverse parseRequest (solanaVerifierRpc c)
  mapM_ (\endpoint->require (secure endpoint) "solana_requires_https") (primary:maybe [] pure verifier)
  let normalized endpoint=BS.dropWhileEnd (==46) $ BS.map (\b->if b>=65 && b<=90 then b+32 else b) (host endpoint)
  mapM_ (\endpoint->require (normalized endpoint/=normalized primary) "independent_rpc_required") verifier
  if solanaProfile c==CanonicalBeta then do
    require (mint c==canonicalMint && maybe False (const True) verifier) "canonical_identity_or_verifier_required"
  else require (mint c/=canonicalMint) "canonical_mint_forbidden_on_devnet"

solanaCall :: Manager -> SolanaSettings -> Text -> [Value] -> IO Value
solanaCall manager c method params = validateSolanaSettings c >> rpc manager (solanaRpc c) Nothing method params
solanaIdentity :: Manager -> SolanaSettings -> IO Value
solanaIdentity manager c = do
  genesis <- solanaCall manager c "getGenesisHash" [] >>= parseValue parseJSON
  require (genesis==solanaGenesis (solanaProfile c)) "wrong_solana_genesis"
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
    Nothing -> require (solanaProfile c/=CanonicalBeta) "verifier_required"
  pure info

tokenAccount :: Manager -> SolanaSettings -> Text -> Text -> IO Value
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
finalizedTransaction :: Manager -> SolanaSettings -> Text -> IO Value
finalizedTransaction manager c signature = solanaCall manager c "getTransaction"
  [toJSON signature,object ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
solanaHistory :: Manager -> SolanaSettings -> Maybe Text -> Maybe Text -> IO Value
solanaHistory manager c = solanaAddressHistory manager c (custodyAta c)
solanaAddressHistory :: Manager -> SolanaSettings -> Text -> Maybe Text -> Maybe Text -> IO Value
solanaAddressHistory manager c address before untilSig = solanaCall manager c "getSignaturesForAddress"
  [toJSON address,object $ ["commitment" .= ("finalized"::Text),"limit" .= (100::Int)] <> maybe [] (\t->["before" .= t]) before <> maybe [] (\t->["until" .= t]) untilSig]

data SignatureInfo = SignatureInfo
  { historySignature :: !Text, historySlot :: !Int64, historyFailed :: !Bool
  } deriving (Eq,Show)
instance FromJSON SignatureInfo where
  parseJSON = withObject "signature history" $ \o -> do
    sig <- o .: "signature"
    _ <- either (fail . T.unpack) pure (signatureBytes sig)
    slot <- o .: "slot"
    finality <- o .: "confirmationStatus" :: Parser Text
    err <- o .: "err" :: Parser Value
    if slot<0 || finality/="finalized" then fail "history is not finalized"
      else pure (SignatureInfo sig slot (err/=Null))

-- Fetch newest-first pages through an explicit, known anchor. A short/empty
-- response is never accepted as proof of complete history. Return oldest first,
-- including the previous cursor as a one-transaction finality overlap.
collectSignatures :: Text -> Maybe Text -> (Maybe Text -> IO [SignatureInfo]) -> IO [SignatureInfo]
collectSignatures origin previous fetch = go Nothing [] Set.empty 0
 where
  target=maybe origin id previous
  go before accumulated seen pages = do
    require (pages<10) "solana_history_batch_too_large"
    page <- fetch before
    require (not (null page) && length page<=100) "solana_history_gap"
    let ids=map historySignature page
    require (length ids==Set.size (Set.fromList ids) && all (`Set.notMember` seen) ids) "solana_history_repeated_page"
    let combined=accumulated<>page
        slots=map historySlot combined
    require (and (zipWith (>=) slots (drop 1 slots))) "solana_history_order_invalid"
    case break ((==target) . historySignature) page of
      (prefix,anchor:_) -> pure (reverse $ accumulated<>prefix<>[anchor])
      (_,[]) -> go (Just $ last ids) combined (Set.union seen $ Set.fromList ids) (pages+1::Int)
