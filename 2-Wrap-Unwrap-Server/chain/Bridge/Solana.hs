module Bridge.Solana
  ( SolanaSettings(..),validateSolanaSettings,solanaCall,solanaIdentity,solanaIdentityWith,solanaGenesisWith,inspectMintAccount
  , inspectMint,inspectClassicAccount,inspectTokenAccount,finalizedTransaction,finalizedTransactionWith,solanaHistory,solanaAddressHistory,solanaAddressHistoryWith
  , SignatureInfo(..), HistoryProgress(..), HistoryStep(..), historyProgressValid, collectObservationHistory, collectSignatures, tokenProgram,solanaGenesis ) where

import Bridge.Wire (Profile(..))
import Bridge.RPC
import Bridge.Error
import Bridge.Domain
import Bridge.Identity (publicKey)
import Bridge.SolanaMessage (signatureBytes)
import Data.Int (Int64)
import Data.Word (Word64)
import qualified Data.Set as Set
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser,parseEither)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager,parseRequest,secure)

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
  mapM_ (\endpoint->require (rpcHost endpoint/=rpcHost primary) "independent_rpc_required") verifier
  if solanaProfile c==CanonicalBeta then do
    require (mint c==canonicalMint && maybe False (const True) verifier) "canonical_identity_or_verifier_required"
  else require (mint c/=canonicalMint) "canonical_mint_forbidden_on_devnet"

solanaCall :: Manager -> SolanaSettings -> Text -> [Value] -> IO Value
solanaCall manager c method params = validateSolanaSettings c >> rpc manager (solanaRpc c) Nothing method params
solanaIdentity :: Manager -> SolanaSettings -> IO Value
solanaIdentity manager c = solanaIdentityWith (solanaCall manager c)
  (fmap (\url->rpc manager url Nothing) $ solanaVerifierRpc c) c
solanaIdentityWith :: (Text -> [Value] -> IO Value) -> Maybe (Text -> [Value] -> IO Value) -> SolanaSettings -> IO Value
solanaIdentityWith call verifier c = do
  solanaGenesisWith call verifier c
  (authority,info) <- readMint call
  response<-call "getAccountInfo" [toJSON (custodyAta c),object
    ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]]
  account<-fieldValue "value" response
  require (account/=Null) "token_account_missing"
  _<-either reject pure (inspectTokenAccount (mint c) (custodyOwner c) account)
  case verifier of
    Just verify -> do
      (otherAuthority,_) <- readMint verify
      -- Both reads enforce the same fixed mint policy. Supply can change between
      -- finalized provider views; only issuance authority must also agree.
      require (otherAuthority==authority) "mint_verifier_policy_mismatch"
    Nothing -> require (solanaProfile c/=CanonicalBeta) "verifier_required"
  pure info
 where
  readMint :: (Text -> [Value] -> IO Value) -> IO (Maybe Text,Value)
  readMint request=do
    response <- request "getAccountInfo" [toJSON (mint c),object
      ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]]
    fieldValue "value" response >>= inspectMintAccount

-- Standalone custody reconciliation still authenticates both provider networks.
solanaGenesisWith :: (Text -> [Value] -> IO Value) -> Maybe (Text -> [Value] -> IO Value) -> SolanaSettings -> IO ()
solanaGenesisWith call verifier c = do
  validateSolanaSettings c
  require (maybe False (const True) verifier==maybe False (const True) (solanaVerifierRpc c)) "verifier_configuration_mismatch"
  genesis <- call "getGenesisHash" [] >>= parseValue parseJSON
  require (genesis==solanaGenesis (solanaProfile c)) "wrong_solana_genesis"
  case verifier of
    Just verify -> do
      independent <- verify "getGenesisHash" [] >>= parseValue parseJSON
      require (independent==genesis) "verifier_wrong_genesis"
    Nothing -> require (solanaProfile c/=CanonicalBeta) "verifier_required"

inspectMintAccount :: Value -> IO (Maybe Text,Value)
inspectMintAccount account = do
  require (account/=Null) "mint_not_found"
  program <- fieldValue "owner" account
  require (program==tokenProgram) "wrong_token_program"
  (authority,_) <- either (const $ reject "unsupported_mint_policy") pure (parseEither (inspectMint $ Just 8) account)
  info <- fieldValue "data" account >>= fieldValue "parsed" >>= fieldValue "info"
  pure (authority,info)

-- Shared with token administration; accepting other decimals is explicit there.
-- Supply uses the SPL u64 range, independent of the bridge's signed ledger range.
inspectMint :: Maybe Int -> Value -> Parser (Maybe Text,Word64)
inspectMint expectedDecimals value=do
  program<-field "owner" value
  executable<-field "executable" value
  dat<-field "data" value
  space<-field "space" dat :: Parser Int
  parsed<-field "parsed" dat
  kind<-field "type" parsed :: Parser Text
  info<-field "info" parsed
  initialized<-field "isInitialized" info
  decimals<-field "decimals" info :: Parser Int
  freeze<-field "freezeAuthority" info :: Parser (Maybe Text)
  unless (program==tokenProgram && not executable && space==82 && kind=="mint" && initialized
    && decimals>=0 && decimals<=255 && maybe True (==decimals) expectedDecimals && freeze==Nothing) (fail "unsupported mint")
  authority<-field "mintAuthority" info
  mapM_ (either (fail . T.unpack) (const $ pure ()) . publicKey) authority
  supply<-field "supply" info
  quantity<-maybe (fail "invalid mint supply") (pure . fromInteger) (parseNatural (toInteger(maxBound::Word64)) supply)
  pure (authority,quantity)
 where
  field :: FromJSON a => Key -> Value -> Parser a
  field key=withObject "mint field" (.: key)

inspectTokenAccount :: Text -> Text -> Value -> Either Text Amount
inspectTokenAccount expectedMint expectedOwner value = either (const $ Left "token_account_policy_mismatch") Right $ do
  (owner,balance,token)<-parseEither inspectClassicAccount value
  unless (owner==expectedOwner && token==expectedMint) (Left "unexpected account identity")
  either (Left . T.unpack) Right (amount $ toInteger balance)

-- Same classic SPL layout for administration and custody. Its u64 balance is
-- narrowed only at the ledger boundary; these facts alone authorize no transfer.
inspectClassicAccount :: Value -> Parser (Text,Word64,Text)
inspectClassicAccount = inspect
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
      && state=="initialized" && not isNative
      && delegate==Nothing && closeAuthority==Nothing && decimals==8) (fail "unsupported token account")
    mapM_ (either (fail . T.unpack) (const $ pure ()) . publicKey) [owner,token]
    raw<-field "amount" balance
    quantity<-maybe (fail "invalid token units") (pure . fromInteger) (parseNatural (toInteger(maxBound::Word64)) raw)
    pure (owner,quantity,token)
finalizedTransaction :: Manager -> SolanaSettings -> Text -> IO Value
finalizedTransaction manager c = finalizedTransactionWith (solanaCall manager c)
finalizedTransactionWith :: (Text -> [Value] -> IO Value) -> Text -> IO Value
finalizedTransactionWith call signature = call "getTransaction"
  [toJSON signature,object ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (1::Int)]]
solanaHistory :: Manager -> SolanaSettings -> Maybe Text -> Maybe Text -> IO Value
solanaHistory manager c = solanaAddressHistory manager c (custodyAta c)
solanaAddressHistory :: Manager -> SolanaSettings -> Text -> Maybe Text -> Maybe Text -> IO Value
solanaAddressHistory manager c = solanaAddressHistoryWith (solanaCall manager c)
solanaAddressHistoryWith :: (Text -> [Value] -> IO Value) -> Text -> Maybe Text -> Maybe Text -> IO Value
solanaAddressHistoryWith call address before untilSig = call "getSignaturesForAddress"
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

-- Observation catch-up only. Absence/expiry proofs MUST retain collectSignatures.
-- The bounded oldest window trades refetching for constant memory and storage.
-- It is never eligible for accounting until the exact previous anchor is found.
data HistoryProgress = HistoryProgress
  { progressOrigin :: !Text, progressPrevious :: !(Maybe Text), progressTime :: !Int64
  , progressHead :: !SignatureInfo, progressWindow :: ![SignatureInfo], progressDropped :: !Bool
  } deriving (Eq,Show)
data HistoryStep = HistoryMore !HistoryProgress | HistoryReady ![SignatureInfo] !Int64 !Bool
  deriving (Eq,Show)
instance ToJSON SignatureInfo where
  toJSON h=object ["signature" .= historySignature h,"slot" .= historySlot h
    ,"confirmationStatus" .= ("finalized"::Text),"err" .= if historyFailed h then Bool True else Null]
instance ToJSON HistoryProgress where
  toJSON p=object ["version" .= (1::Int),"origin" .= progressOrigin p,"previous" .= progressPrevious p
    ,"time" .= progressTime p,"head" .= progressHead p,"window" .= progressWindow p,"dropped" .= progressDropped p]
instance FromJSON HistoryProgress where
  parseJSON=withObject "observation history progress" $ \o->do
    version<-o .: "version" :: Parser Int
    p<-HistoryProgress <$> o .: "origin" <*> o .: "previous" <*> o .: "time"
      <*> o .: "head" <*> o .: "window" <*> o .: "dropped"
    if version==1 && historyProgressValid p then pure p else fail "invalid observation history progress"

historyProgressValid :: HistoryProgress -> Bool
historyProgressValid p=progressTime p>=0 && not(null window) && length window<=500
  && all valid (progressOrigin p:maybe [] pure (progressPrevious p)<>ids<>[historySignature $ progressHead p])
  && length ids==Set.size(Set.fromList ids) && target `notElem` ids
  && all ((>=0).historySlot) window && historySlot(progressHead p)>=historySlot(head window)
  && and(zipWith (>=) slots (drop 1 slots))
  && (progressDropped p || head window==progressHead p)
 where
  window=progressWindow p; ids=map historySignature window; slots=map historySlot window
  target=maybe (progressOrigin p) id (progressPrevious p)
  valid sig=case signatureBytes sig of Right _->True; Left _->False

collectObservationHistory :: Text -> Maybe Text -> Int64 -> Maybe HistoryProgress
  -> (Maybe Text -> IO [SignatureInfo]) -> IO HistoryStep
collectObservationHistory origin previous now saved fetch=do
  require (now>=0) "invalid_scan_time"
  mapM_ (either reject (const $ pure ()) . signatureBytes) (origin:maybe [] pure previous)
  case saved of
    Nothing->go 0 [] Nothing False now
    Just p->do
      require (historyProgressValid p && progressOrigin p==origin && progressPrevious p==previous
        && progressTime p<=now) "solana_history_progress_changed"
      go 0 (progressWindow p) (Just $ progressHead p) (progressDropped p) (progressTime p)
 where
  target=maybe origin id previous
  go pages window headSeen dropped started=do
    page<-fetch (if null window then Nothing else Just $ historySignature $ last window)
    require (not(null page) && length page<=100) "solana_history_gap"
    let joined=window<>page; ids=map historySignature joined; slots=map historySlot joined
    require (length ids==Set.size(Set.fromList ids)) "solana_history_repeated_page"
    require (all (>=0) slots && and(zipWith (>=) slots (drop 1 slots))) "solana_history_order_invalid"
    mapM_ (either reject (const $ pure ()) . signatureBytes) ids
    let first=maybe (head page) id headSeen
        trim xs=drop (max 0 $ length xs-500) xs
    case break ((==target).historySignature) page of
      (prefix,anchor:_)->do
        let reached=window<>prefix<>[anchor]; lost=dropped || length reached>500
        pure(HistoryReady (reverse $ trim reached) started (not lost))
      (_,[])->do
        let next=trim joined; lost=dropped || length joined>500
            p=HistoryProgress origin previous started first next lost
        require (historyProgressValid p) "invalid_solana_history_progress"
        if pages+1>=4 then pure(HistoryMore p)
        else go (pages+1::Int) next (Just first) lost started
