{-# LANGUAGE GADTs #-}
-- Read-only preflight; simulation always contains zero signatures.
module Token.Network (Network(..),Safe(..),Critical(..),evalSafe,evalCritical,inspectPolicy) where
import Bridge.AdminStatus (Status,inspectStatus,Recovery(..),newRecovery,renewRecovery,validateRecovery,attemptPath)
import Bridge.AdminKey (readPrivate,readKey,savePrivate,newPrivatePath,withFamily)
import Bridge.Identity (digest)
import qualified Token.Metadata as M
import Token.Signing (Saved(..),validateSaved,validateSuccessorSaved)
import qualified Token
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteArray as BA
import qualified Crypto.PubKey.Ed25519 as Ed
import Token (Request(..),Action(..),validate)
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.Solana (tokenProgram,inspectMint)
import Bridge.SolanaMessage (Transaction(..),publicKey,base58)
import Control.Exception (bracket)
import Control.Monad (unless,forM_)
import System.Posix.Files (fileExist)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Network.HTTP.Client (parseRequest,secure,host,closeManager)
import qualified Data.ByteString.Char8 as B8
import Data.Char (toLower)
import Text.Read (readMaybe)

data Network = Devnet | Mainnet deriving (Eq,Show)
data Safe a where
  RecentBlockhash :: Network -> String -> Safe Text
  InspectSaved :: Network -> String -> FilePath -> Safe Status
  Check :: Network -> String -> Word64 -> Request -> Text -> Safe Word64
  InspectPolicy :: Network -> String -> String -> Text -> Text -> Text -> Maybe Text -> Safe [(Word64,Word64,Word64)]

evalSafe :: Safe a -> IO a
evalSafe (RecentBlockhash network endpoint)=do
  transport<-parseRequest endpoint
  require (secure transport) "invalid_token_rpc_policy"
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
    actual<-call "getGenesisHash" [] >>= parseValue parseJSON
    require (actual==genesis network) "wrong_token_network"
    recent<-call "getLatestBlockhash" [object ["commitment" .= ("finalized"::Text)]]
      >>= fieldValue "value" >>= fieldValue "blockhash" >>= parseValue parseJSON
    either reject (const $ pure recent) (publicKey recent)
evalSafe (InspectSaved network endpoint path)=do
  (saved,_)<-loadFamily path
  forM_ (savedRecovery saved) $ \context->either reject pure $
    validateRecovery (genesis network) (authority $ savedRequest saved)
      (recoveryFeeLimit context) (blockhash $ savedRequest saved) context
  inspectStatus (genesis network) endpoint (savedId saved) (savedTransaction saved) (blockhash $ savedRequest saved)
evalSafe (InspectPolicy network primary verifier key owner custody issuer)=do
  mapM_ (either reject (const $ pure ()) . publicKey) ([key,owner,custody]<>maybe [] pure issuer)
  first<-parseRequest primary; second<-parseRequest verifier
  require (secure first && secure second && B8.dropWhileEnd (=='.') (B8.map toLower $ host first)/=B8.dropWhileEnd (=='.') (B8.map toLower $ host second)) "independent_https_providers_required"
  bracket newRpcManager closeManager $ \manager->do
    readings<-mapM (\endpoint->do
      let call=rpc manager endpoint Nothing
      actual<-call "getGenesisHash" [] >>= parseValue parseJSON
      require (actual==genesis network) "wrong_token_network"
      call "getMultipleAccounts" [toJSON [key,custody],object ["encoding" .= ("jsonParsed"::Text),"commitment" .= ("finalized"::Text)]]
        >>= parseValue (inspectPolicy key owner issuer)) [primary,verifier]
    require (case readings of [(_,supply,balance),(_,otherSupply,otherBalance)]->supply==otherSupply && balance==otherBalance; _->False) "token_provider_policy_mismatch"
    pure readings
evalSafe (Check network endpoint feeLimit request unsigned)=do
  transport<-parseRequest endpoint
  require (secure transport && feeLimit>0) "invalid_token_rpc_policy"
  Transaction _ _ message<-either reject pure (validate request unsigned)
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
        options=object ["encoding" .= ("jsonParsed"::Text),"commitment" .= ("finalized"::Text)]
        accountInfo address=call "getAccountInfo" [toJSON address,options] >>= fieldValue "value"
    actual<-call "getGenesisHash" [] >>= parseValue parseJSON :: IO Text
    require (actual==genesis network) "wrong_token_network"
    rentCost<-case request of
      CreateMint{}->do
        existing<-accountInfo (mint request)
        require (existing==Null) "mint_already_exists"
        minimumRent<-call "getMinimumBalanceForRentExemption" [toJSON (82::Int),object ["commitment" .= ("finalized"::Text)]] >>= parseValue parseJSON :: IO Integer
        require (minimumRent>0 && minimumRent==toInteger(rent request)) "mint_rent_mismatch"
        pure minimumRent
      Associated{owner=recipient}->do
        _<-accountInfo (mint request) >>= parseValue (inspectMint Nothing)
        minimumRent<-call "getMinimumBalanceForRentExemption" [toJSON (165::Int),object ["commitment" .= ("finalized"::Text)]] >>= parseValue parseJSON :: IO Integer
        require (minimumRent>0 && minimumRent==toInteger(rent request)) "account_rent_mismatch"
        existing<-accountInfo (account request)
        if existing==Null then pure minimumRent else do
          (actualOwner,_,actualMint)<-parseValue inspectAccount existing
          require (actualOwner==recipient && actualMint==mint request) "associated_account_identity_mismatch"
          pure 0
      Metadata{metadata=terms}->do
        (issuer,_)<-accountInfo (mint request) >>= parseValue (inspectMint (Just 8))
        existing<-accountInfo (M.address terms)
        if M.create terms then require (issuer==Just(authority request) && existing==Null) "metadata_creation_authority_or_exists"
        else do
          _<-metadataState request existing
          pure ()
        pure 0
      Request{}->do
        mintInfo<-accountInfo (mint request) >>= parseValue (inspectMint (Just 8))
        tokenInfo<-accountInfo (account request) >>= parseValue inspectAccount
        let (mintAuthority,supply)=mintInfo
            (owner,balance,token)=tokenInfo
        require (token==mint request) "token_account_mint_mismatch"
        case action request of
          Mint->require (mintAuthority==Just(authority request) && toInteger supply+toInteger(quantity request)<=toInteger(maxBound::Word64)) "token_mint_authority_or_supply"
          Burn->require (owner==authority request && balance>=quantity request && supply>=quantity request) "token_burn_authority_or_balance"
        pure 0
    -- Both writable token accounts and the mint are checked above; reject a
    -- non-system fee payer, even if an RPC simulation would accept it.
    payer<-accountInfo (authority request)
    payerOwner<-fieldValue "owner" payer :: IO Text
    executable<-fieldValue "executable" payer
    lamports<-fieldValue "lamports" payer :: IO Integer
    require (payerOwner=="11111111111111111111111111111111" && not executable) "unsupported_token_fee_payer"
    feeValue<-call "getFeeForMessage" [toJSON $ TE.decodeUtf8 $ B64.encode message,object ["commitment" .= ("finalized"::Text)]]
    fee<-fieldValue "value" feeValue :: IO (Maybe Integer)
    n<-case fee of Just n | n>0 && n<=toInteger feeLimit && n+rentCost<=lamports->pure(fromInteger n); _->reject "token_fee_unavailable_or_excessive"
    simulation<-call "simulateTransaction" [toJSON unsigned,object
      (["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"sigVerify" .= False,"replaceRecentBlockhash" .= False]
       <> case request of
         Metadata{metadata=terms}->["accounts" .= object ["encoding" .= ("base64"::Text),"addresses" .= [authority request,M.address terms]]]
         _->[]) ]
    result<-fieldValue "value" simulation
    failure<-fieldValue "err" result :: IO Value
    require (failure==Null) "token_simulation_failed"
    case request of
      Metadata{metadata=terms}->do
        states<-fieldValue "accounts" result :: IO [Value]
        (after,fields)<-case states of
          [payerState,metadataAccount]->(,) <$> fieldValue "lamports" payerState <*> metadataState request metadataAccount
          _->reject "metadata_simulation_accounts"
        -- Include the fee conservatively even when the RPC already deducted it.
        let debit=lamports-after+toInteger n
        require (after<=lamports && debit<=toInteger(M.maxCost terms)
          && fields==(M.name terms,M.symbol terms,M.uri terms)) "metadata_simulation_effect_or_cost"
      _->pure ()
    pure n

metadataState :: Request -> Value -> IO (Text,Text,Text)
metadataState Metadata{authority=owner,mint=key} value=do
  actualOwner<-fieldValue "owner" value
  executable<-fieldValue "executable" value
  encoded<-fieldValue "data" value :: IO [Text]
  require (actualOwner==M.program && not executable) "invalid_metadata_account_owner"
  raw<-case encoded of
    [bytes,"base64"]->either (const $ reject "invalid_metadata_base64") pure (B64.decode $ TE.encodeUtf8 bytes)
    _->reject "invalid_metadata_encoding"
  either reject pure (M.inspect owner key raw)
metadataState _ _=reject "metadata_operation_required"

-- Fresh signing and expiry recovery are explicit critical operations. Submission
-- can only send saved bytes; all three serialize on the same durable family root.
data Critical a where
  Sign :: FilePath -> Network -> String -> Word64 -> Request -> Text -> FilePath -> FilePath -> Critical Text
  Recover :: FilePath -> String -> String -> FilePath -> FilePath -> Critical Text
  Submit :: Network -> String -> Word64 -> FilePath -> Critical Value

evalCritical :: Critical a -> IO a
evalCritical (Sign library network endpoint feeLimit request unsigned key output)=withFamily output $ do
  _<-either reject pure (validate request unsigned)
  newPrivatePath output
  _<-readKey (authority request) key
  recovery<-newRecovery (genesis network) endpoint (authority request) feeLimit output
  prepareAndSign library network endpoint key request recovery
evalCritical (Recover library primary verifier path key)=withSavedFamily path $ \saved bytes->do
  before<-maybe (reject "token_recovery_context_required") pure (savedRecovery saved)
  network<-networkFor (recoveryGenesis before)
  require (recoveryGeneration before<7) "administration_recovery_limit"
  let child=attemptPath (before {recoveryGeneration=recoveryGeneration before+1})
  exists<-fileExist child
  if exists then do
    (next,_)<-loadFamily child
    either reject pure (validateSuccessorSaved saved (digest bytes) next)
    pure (savedId next)
  else do
    _<-readKey (authority $ savedRequest saved) key
    after<-renewRecovery primary verifier (savedId saved) (savedTransaction saved) (digest bytes) before
    prepareAndSign library network primary key (savedRequest saved) after
evalCritical (Submit network endpoint feeLimit path)=withSavedFamily path $ \saved _->do
  forM_ (savedRecovery saved) $ \context->do
    either reject pure $ validateRecovery (genesis network) (authority $ savedRequest saved)
      feeLimit (blockhash $ savedRequest saved) context
    whenSuccessor context $ \child->do
      _<-loadFamily child
      reject "token_attempt_superseded"
  submitSaved network endpoint feeLimit saved

prepareAndSign :: FilePath -> Network -> String -> FilePath -> Request -> Recovery -> IO Text
prepareAndSign library network endpoint key original context=do
  let request=original {blockhash=recoveryBlockhash context}
  unsigned<-Token.evalSafe (Token.Prepare library request)
  _<-evalSafe (Check network endpoint (recoveryFeeLimit context) request unsigned)
  signPrepared key request unsigned context


-- Private to the critical network interpreter: callers cannot supply fabricated
-- recovery context to a separately exported signing function.
signPrepared :: FilePath -> Request -> Text -> Recovery -> IO Text
signPrepared keyfile request unsigned recovery=do
  either reject pure $ validateRecovery (recoveryGenesis recovery) (authority request)
    (recoveryFeeLimit recovery) (blockhash request) recovery
  Transaction _ _ message<-either reject pure (validate request unsigned)
  let output=attemptPath recovery
  newPrivatePath output
  secret<-readKey (authority request) keyfile
  let signature=Ed.sign secret (Ed.toPublic secret) message
      signatureBytes=BA.convert signature :: BS.ByteString
      identifier=base58 signatureBytes
      transaction=TE.decodeUtf8 $ B64.encode (BS.singleton 1<>signatureBytes<>message)
      record=L.toStrict $ encode $ Saved request identifier transaction (Just recovery)
  require (Ed.verify (Ed.toPublic secret) message signature) "token_signature_invalid"
  savePrivate output record
  pure identifier

readSaved :: FilePath -> IO (Saved,BS.ByteString)
readSaved path=do
  bytes<-readPrivate path
  saved<-either (const $ reject "invalid_token_attempt") pure (eitherDecodeStrict' bytes)
  _<-either reject pure (validateSaved saved)
  forM_ (savedRecovery saved) $ \context->require (path==attemptPath context) "token_attempt_path_mismatch"
  pure (saved,bytes)

-- Verify the direct parent before following it. The checked generation then
-- decreases on every read, bounding the complete family to eight archives.
loadFamily :: FilePath -> IO (Saved,BS.ByteString)
loadFamily path=do
  current<-readSaved path
  ancestors current
  pure current
 where
  ancestors (saved,_)=forM_ (savedRecovery saved) $ \context->
    unless (recoveryGeneration context==0) $ do
      parent@(before,bytes)<-readSaved (attemptPath (context {recoveryGeneration=recoveryGeneration context-1}))
      either reject pure (validateSuccessorSaved before (digest bytes) saved)
      ancestors parent

withSavedFamily :: FilePath -> (Saved -> BS.ByteString -> IO a) -> IO a
withSavedFamily path action=do
  (initial,_)<-readSaved path
  let root=maybe path recoveryRoot (savedRecovery initial)
  withFamily root $ do
    (saved,bytes)<-loadFamily path
    require (maybe path recoveryRoot (savedRecovery saved)==root) "token_attempt_family_changed"
    action saved bytes

whenSuccessor :: Recovery -> (FilePath -> IO ()) -> IO ()
whenSuccessor context action=unless (recoveryGeneration context>=7) $ do
  let child=attemptPath (context {recoveryGeneration=recoveryGeneration context+1})
  exists<-fileExist child
  if exists then action child else pure ()

networkFor :: Text -> IO Network
networkFor value
  | value==genesis Devnet=pure Devnet
  | value==genesis Mainnet=pure Mainnet
  | otherwise=reject "wrong_token_network"

submitSaved :: Network -> String -> Word64 -> Saved -> IO Value
submitSaved network endpoint feeLimit saved=do
  unsigned<-either reject pure (validateSaved saved)
  transport<-parseRequest endpoint
  require (secure transport && feeLimit>0) "invalid_token_rpc_policy"
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
        identifier=savedId saved
    actual<-call "getGenesisHash" [] >>= parseValue parseJSON :: IO Text
    require (actual==genesis network) "wrong_token_network"
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
        let costLimit=case savedRequest saved of
              Metadata{metadata=terms}->Just (toInteger $ M.maxCost terms)
              Associated{rent=lamports}->Just (toInteger lamports+fee)
              CreateMint{rent=lamports}->Just (toInteger lamports+fee)
              Request{}->Nothing
        case costLimit of
          Just maximumDebit->do
            before<-fieldValue "preBalances" metadata :: IO [Integer]
            after<-fieldValue "postBalances" metadata :: IO [Integer]
            require (case (before,after) of
              (a:_,b:_)->a>=0 && b>=0 && a>=b && a-b>=fee && a-b<=maximumDebit
              _->False) "token_finalized_cost_exceeded"
          Nothing->pure ()
        pure $ object ["signature" .= identifier,"status" .= (if failure==Null then "finalized" else "failed"::Text),"feeLamports" .= fee]
    else do
      _<-evalSafe (Check network endpoint feeLimit (savedRequest saved) unsigned)
      result<-call "sendTransaction" [toJSON (savedTransaction saved),object
        ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("finalized"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
      require (result==identifier) "token_submission_identifier_mismatch"
      pure $ object ["signature" .= identifier,"status" .= ("submitted"::Text)]

-- Strict classic SPL policies: no extensions, frozen/delegated/native accounts,
-- or hidden close/freeze authority. JSON amounts are canonical unsigned integers.
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

genesis :: Network -> Text
genesis Devnet="EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
genesis Mainnet="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"

-- Both accounts come from the same finalized response on each provider.
inspectPolicy :: Text -> Text -> Maybe Text -> Value -> Parser (Word64,Word64,Word64)
inspectPolicy key owner issuer value=do
  slot<-field "context" value >>= field "slot"
  accounts<-field "value" value
  case accounts of
    [mintValue,custodyValue]->do
      (actualIssuer,supply)<-inspectMint (Just 8) mintValue
      (actualOwner,balance,actualMint)<-inspectAccount custodyValue
      unless (slot>0 && actualIssuer==issuer && actualOwner==owner && actualMint==key && balance<=supply) (fail "token policy mismatch")
      pure (slot,supply,balance)
    _->fail "expected mint and custody accounts"
