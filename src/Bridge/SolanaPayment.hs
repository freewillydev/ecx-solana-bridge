module Bridge.SolanaPayment where

import Bridge.Config
import Bridge.RPC
import Bridge.Solana (inspectTokenAccount)
import Bridge.SolanaHelper
import Bridge.SolanaMessage (publicKey,Transaction(..),Message(..),Instruction(..),base58)
import Bridge.Types
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import GHC.Generics (Generic)
import Control.Monad (unless)
import Data.Aeson.Types (Parser,parseEither)
import Data.List (elemIndices)

type SolanaRPC = Text -> [Value] -> IO Value
data RecentBlockhash = RecentBlockhash
  { recentHash :: !Text, recentLastValidHeight :: !Int64, recentSlot :: !Int64
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)
data SolanaPlan = SolanaPlan
  { solPlanFingerprint :: !Text, solPlanRecipient :: !Text, solPlanAmount :: !Amount
  , solPlanReference :: !Text, solPlanRecent :: !RecentBlockhash
  , solPlanFeeLimit :: !Amount, solPlanRentLimit :: !Amount
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)
data SolanaSigned = SolanaSigned
  { signedSolanaPlan :: !SolanaPlan, signedSolanaReply :: !HelperReply
  , signedSolanaFeeEstimate :: !Amount, signedSolanaRentEstimate :: !Amount
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)

contextValue :: Int64 -> Value -> IO (Int64,Value)
contextValue minimumSlot response = do
  slot <- fieldValue "context" response >>= fieldValue "slot"
  require (slot>=minimumSlot && slot>=0) "solana_context_too_old"
  value <- fieldValue "value" response
  pure (slot,value)

-- A conservative preparation floor, measured in block heights rather than
-- wall-clock seconds. First-send handling must check it again after backups.
checkBlockhashWindow :: SolanaRPC -> RecentBlockhash -> IO ()
checkBlockhashWindow call RecentBlockhash{..} = do
  _ <- either reject pure (publicKey recentHash)
  require (recentSlot>=0 && recentLastValidHeight>0) "invalid_blockhash_context"
  height <- call "getBlockHeight" [object ["commitment" .= ("confirmed"::Text),"minContextSlot" .= recentSlot]] >>= parseValue parseJSON :: IO Int64
  require (height>=0 && toInteger recentLastValidHeight-toInteger height>=40) "solana_blockhash_window_too_short"

getRecentBlockhash :: SolanaRPC -> IO RecentBlockhash
getRecentBlockhash call = do
  (slot,value) <- call "getLatestBlockhash" [object ["commitment" .= ("finalized"::Text)]] >>= contextValue 0
  recent <- RecentBlockhash <$> fieldValue "blockhash" value <*> fieldValue "lastValidBlockHeight" value <*> pure slot
  checkBlockhashWindow call recent
  pure recent

solanaOperatingLimit :: SolanaPlan -> Either Text Amount
solanaOperatingLimit plan = amount (toInteger (units $ solPlanFeeLimit plan)+toInteger (units $ solPlanRentLimit plan))

solanaPayoutRequest :: Config -> SolanaPlan -> HelperRequest
solanaPayoutRequest c plan = HelperRequest True (custodyOwner c) (solPlanRecipient plan)
  (solPlanAmount plan) (recentHash $ solPlanRecent plan) (solPlanReference plan)

-- Missing accounts and ordinary pre-funded system accounts can both become
-- ATAs. An unsolicited lamport transfer must not permanently block a recipient.
systemLamports :: Value -> IO Amount
systemLamports account = do
  program <- fieldValue "owner" account :: IO Text
  executable <- fieldValue "executable" account
  bytes <- fieldValue "data" account :: IO [Text]
  require (program=="11111111111111111111111111111111" && not executable && bytes==["","base64"]) "unsupported_system_account"
  fieldValue "lamports" account >>= either reject pure . amount

prepareSolanaSigned :: SolanaRPC -> (HelperRequest -> IO HelperReply) -> Config -> SolanaPlan -> IO SolanaSigned
prepareSolanaSigned call helper c plan = do
  require (solPlanFingerprint plan==fingerprint c && solPlanFeeLimit plan<=maxSolFee c
    && solPlanRentLimit plan<=maxSolAccountRent c) "saved_solana_policy_mismatch"
  checkBlockhashWindow call (solPlanRecent plan)
  let request=solanaPayoutRequest c plan
  reply <- helper request
  transaction <- either reject pure (validateHelperReply c request reply)
  let options=object ["commitment" .= ("confirmed"::Text),"minContextSlot" .= recentSlot (solPlanRecent plan)]
  (_,feeValue) <- call "getFeeForMessage" [toJSON (replyMessage reply),options] >>= contextValue (recentSlot $ solPlanRecent plan)
  require (feeValue/=Null) "solana_fee_unavailable"
  fee <- parseValue parseJSON feeValue >>= either reject pure . amount
  require (units fee>0 && fee<=solPlanFeeLimit plan) "solana_fee_above_limit"
  let accountOptions=object ["commitment" .= ("confirmed"::Text),"encoding" .= ("jsonParsed"::Text),"minContextSlot" .= recentSlot (solPlanRecent plan)]
  (accountSlot,accountsValue) <- call "getMultipleAccounts"
    [toJSON [custodyAta c,replyDestination reply,custodyOwner c],accountOptions] >>= contextValue (recentSlot $ solPlanRecent plan)
  accounts <- parseValue parseJSON accountsValue
  (source,destination,payer) <- case accounts of [a,b,d] -> pure (a,b,d); _ -> reject "solana_account_snapshot_incomplete"
  sourceBalance <- either reject pure (inspectTokenAccount (mint c) (custodyOwner c) source)
  require (sourceBalance>=solPlanAmount plan) "insufficient_custody_tokens"
  rent <- if destination==Null then newAccountRent 0 else do
    program <- fieldValue "owner" destination :: IO Text
    if program==tokenProgram then do
      _ <- either reject pure (inspectTokenAccount (mint c) (solPlanRecipient plan) destination)
      either reject pure (amount 0)
    else systemLamports destination >>= newAccountRent . toInteger . units
  require (rent<=solPlanRentLimit plan) "solana_rent_above_limit"
  balance <- systemLamports payer
  require (toInteger (units balance)>=toInteger (units fee)+toInteger (units rent)) "insufficient_operating_sol"
  -- The RPC never receives the custody signature during preparation. Signature
  -- validity is checked locally; simulation runs the exact unsigned message.
  (_,simulation) <- call "simulateTransaction" [toJSON (unsignedSimulation transaction),object
    ["encoding" .= ("base64"::Text),"commitment" .= ("confirmed"::Text)
    ,"sigVerify" .= False,"replaceRecentBlockhash" .= False,"minContextSlot" .= accountSlot]] >>= contextValue accountSlot
  err <- fieldValue "err" simulation :: IO Value
  require (err==Null) "solana_simulation_failed"
  checkBlockhashWindow call (solPlanRecent plan)
  pure (SolanaSigned plan reply fee rent)
 where
  newAccountRent prefunded = do
    required <- call "getMinimumBalanceForRentExemption" [toJSON (165::Int),object ["commitment" .= ("confirmed"::Text)]] >>= parseValue parseJSON :: IO Integer
    require (required>0) "invalid_solana_rent_quote"
    either reject pure (amount $ max 0 (required-prefunded))

-- The caller must obtain this getTransaction result with finalized commitment.
-- Matching the entire SDK message prevents unrelated transfers from being
-- mistaken for this payout; historical balances account for ATA rent separately.
data SolanaOutcome = SolanaOutcome
  { outcomeSlot :: !Int64, outcomeSucceeded :: !Bool
  , outcomeFee :: !Amount, outcomeRent :: !Amount
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)

verifySolanaOutcome :: Config -> SolanaSigned -> Value -> Either Text SolanaOutcome
verifySolanaOutcome c signed proof = do
  let plan=signedSolanaPlan signed
      reply=signedSolanaReply signed
  -- Reconcile against the cost policy saved when signing. Lowering limits for
  -- future payments cannot change the outcome of an already-broadcast attempt.
  unless (solPlanFingerprint plan==fingerprint c && units (solPlanFeeLimit plan)>0)
    (Left "saved_solana_policy_mismatch")
  _ <- solanaOperatingLimit plan
  Transaction _ (Message required signedReadonly readonly keys blockhash instructions) _ <-
    validateHelperReply c (solanaPayoutRequest c plan) reply
  either (const $ Left "solana_settlement_evidence_mismatch") Right $ parseEither (inspect plan reply required signedReadonly readonly keys blockhash instructions) proof
 where
  field key = withObject "settlement field" (.: key)
  ensure ok = unless ok (fail "invalid payment evidence")
  inspect plan reply required signedReadonly readonly keys blockhash instructions v = do
    slot <- field "slot" v
    ensure (slot>=recentSlot (solPlanRecent plan))
    version <- field "version" v :: Parser Value
    ensure (version==String "legacy")
    tx <- field "transaction" v
    signatures <- field "signatures" tx :: Parser [Text]
    ensure (Just signatures==fmap pure (replySignature reply))
    msg <- field "message" tx
    actualKeys <- field "accountKeys" msg
    ensure (actualKeys==map base58 keys)
    header <- field "header" msg
    actualRequired <- field "numRequiredSignatures" header
    actualSignedReadonly <- field "numReadonlySignedAccounts" header
    actualReadonly <- field "numReadonlyUnsignedAccounts" header
    actualHash <- field "recentBlockhash" msg
    ensure (actualRequired==required && actualSignedReadonly==signedReadonly && actualReadonly==readonly && actualHash==base58 blockhash)
    actualInstructions <- field "instructions" msg >>= mapM (\ix -> (,,) <$> field "programIdIndex" ix <*> field "accounts" ix <*> field "data" ix)
    ensure (actualInstructions==[(p,as,base58 dat) | Instruction p as dat<-instructions])
    meta <- field "meta" v
    err <- field "err" meta :: Parser Value
    actualFee <- field "fee" meta >>= either (fail . show) pure . amount
    ensure (units actualFee>0 && actualFee<=solPlanFeeLimit plan)
    before <- field "preBalances" meta :: Parser [Integer]
    after <- field "postBalances" meta :: Parser [Integer]
    ensure (length before==length keys && length after==length keys && all (>=0) (before<>after))
    dest <- case elemIndices (replyDestination reply) actualKeys of [i]->pure i; _->fail "missing destination"
    source <- case elemIndices (replySource reply) actualKeys of [i]->pure i; _->fail "missing source"
    let rentChange=after!!dest-before!!dest
        debit=before!!0-after!!0
    ensure (all (\i -> i==0 || i==dest || before!!i==after!!i) [0..length keys-1])
    rent <- either (fail . show) pure (amount rentChange)
    ensure (rent<=solPlanRentLimit plan && debit==toInteger (units actualFee)+rentChange)
    preTokens <- field "preTokenBalances" meta
    postTokens <- field "postTokenBalances" meta
    sourceBefore <- tokenBalance c source (custodyOwner c) False preTokens
    sourceAfter <- tokenBalance c source (custodyOwner c) False postTokens
    -- An ATA may start as an empty, lamport-funded system account. The exact
    -- idempotent-creation instruction binds its owner/mint on success.
    destBefore <- tokenBalance c dest (solPlanRecipient plan) True preTokens
    destAfter <- tokenBalance c dest (solPlanRecipient plan) (err/=Null) postTokens
    let delta=if err==Null then toInteger (units $ solPlanAmount plan) else 0
    ensure (sourceBefore-sourceAfter==delta && destAfter-destBefore==delta && (err==Null || rentChange==0))
    pure (SolanaOutcome slot (err==Null) actualFee rent)
  tokenBalance config idx owner allowMissing entries = do
    indexes <- mapM (field "accountIndex") entries :: Parser [Int]
    case [entry | (i,entry)<-zip indexes entries,i==idx] of
      [] -> ensure allowMissing >> pure 0
      [entry] -> do
        actualMint <- field "mint" entry
        actualOwner <- field "owner" entry
        balance <- field "uiTokenAmount" entry
        decimals <- field "decimals" balance :: Parser Int
        quantity <- field "amount" balance >>= either (fail . show) pure . parseUnits
        ensure (actualMint==mint config && actualOwner==owner && decimals==8)
        pure (toInteger $ units quantity)
      _ -> fail "duplicate token balance"
