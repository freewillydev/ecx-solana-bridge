{-# LANGUAGE GADTs #-}
-- Read-only preflight; simulation always contains zero signatures.
module Token.Network (Network(..),Safe(..),Critical(..),evalSafe,evalCritical,inspectPolicy,inspectNonce) where
import Bridge.AdminStatus (Status,inspectStatus,Recovery(..),newRecovery,renewRecovery,validateRecovery,attemptPath,readFamily,withSavedFamily,successor)
import qualified Bridge.AdminStatus as Admin
import Bridge.AdminKey (readKey,savePrivate,newPrivatePath,withFamily)
import Bridge.Identity (digest)
import qualified Token.Metadata as M
import Token.Signing (Saved(..),validateSaved)
import qualified Token
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteArray as BA
import qualified Crypto.PubKey.Ed25519 as Ed
import Token (Request(..),Action(..),validate)
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.Solana (inspectMint,inspectClassicAccount)
import Bridge.SolanaMessage (Transaction(..),publicKey,base58,boundedBase64)
import Control.Monad (unless,forM_)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Data.Binary.Get (runGetOrFail,getWord32le,getWord64le,getByteString)

data Network = Devnet | Mainnet deriving (Eq,Show)
data Safe a where
  RecentBlockhash :: Network -> String -> Safe Text
  NonceValue :: Network -> String -> Text -> Text -> Safe Text
  NonceRent :: Network -> String -> Safe Word64
  InspectSaved :: Network -> String -> FilePath -> Safe Status
  Check :: Network -> String -> Word64 -> Request -> Text -> Safe Word64
  InspectPolicy :: Network -> String -> String -> Text -> Text -> Text -> Maybe Text -> Safe [(Word64,Word64,Word64)]

evalSafe :: Safe a -> IO a
evalSafe (NonceRent network endpoint)=
  withSolanaRpc endpoint (genesis network) ("invalid_token_rpc_policy","wrong_token_network") $ \call->do
    rent<-call "getMinimumBalanceForRentExemption" [toJSON (80::Int),object ["commitment" .= ("finalized"::Text)]] >>= parseValue parseJSON
    require (rent>0) "invalid_nonce_rent"
    pure rent
evalSafe (NonceValue network endpoint owner address)=do
  mapM_ (either reject (const $ pure ()) . publicKey) [owner,address]
  withSolanaRpc endpoint (genesis network) ("invalid_token_rpc_policy","wrong_token_network") $ \call->do
    accountValue<-call "getAccountInfo" [toJSON address,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text)]] >>= fieldValue "value"
    fst <$> parseValue (inspectNonce owner) accountValue
evalSafe (RecentBlockhash network endpoint)=
  withSolanaRpc endpoint (genesis network) ("invalid_token_rpc_policy","wrong_token_network") $ \call->do
    recent<-call "getLatestBlockhash" [object ["commitment" .= ("finalized"::Text)]]
      >>= fieldValue "value" >>= fieldValue "blockhash" >>= parseValue parseJSON
    either reject (const $ pure recent) (publicKey recent)
evalSafe (InspectSaved network endpoint path)=do
  (_,saved)<-readFamily path
  case savedRequest saved of
    NonceMint{}->reject "nonce_status_requires_submit_file"
    _->pure ()
  forM_ (savedRecovery saved) $ \context->either reject pure $
    validateRecovery (genesis network) (authority $ savedRequest saved)
      (recoveryFeeLimit context) (blockhash $ savedRequest saved) context
  inspectStatus (genesis network) endpoint (savedId saved) (savedTransaction saved) (blockhash $ savedRequest saved)
evalSafe (InspectPolicy network primary verifier key owner custody issuer)=do
  mapM_ (either reject (const $ pure ()) . publicKey) ([key,owner,custody]<>maybe [] pure issuer)
  independentHttps primary verifier
  readings<-mapM (\endpoint->withSolanaRpc endpoint (genesis network) ("invalid_token_rpc_policy","wrong_token_network") $ \call->
      call "getMultipleAccounts" [toJSON [key,custody],object ["encoding" .= ("jsonParsed"::Text),"commitment" .= ("finalized"::Text)]]
        >>= parseValue (inspectPolicy key owner issuer)) [primary,verifier]
  require (case readings of [(_,supply,balance),(_,otherSupply,otherBalance)]->supply==otherSupply && balance==otherBalance; _->False) "token_provider_policy_mismatch"
  pure readings
evalSafe (Check network endpoint feeLimit request unsigned)=do
  require (feeLimit>0) "invalid_token_rpc_policy"
  Transaction _ _ message<-either reject pure (validate request unsigned)
  withSolanaRpc endpoint (genesis network) ("invalid_token_rpc_policy","wrong_token_network") $ \call->do
    let options=object ["encoding" .= ("jsonParsed"::Text),"commitment" .= ("finalized"::Text)]
        accountInfo address=call "getAccountInfo" [toJSON address,options] >>= fieldValue "value"
    case request of
      NonceMint{nonceAccount=address}->do
        value<-call "getAccountInfo" [toJSON address,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text)]] >>= fieldValue "value"
        (stored,_)<-parseValue (inspectNonce $ authority request) value
        require (stored==blockhash request) "token_nonce_consumed_or_changed"
      _->pure ()
    rentCost<-case request of
      CreateNonce{nonceAccount=address,rent=lamports}->do
        existing<-accountInfo address
        require (existing==Null) "nonce_account_already_exists"
        minimumRent<-call "getMinimumBalanceForRentExemption" [toJSON (80::Int),object ["commitment" .= ("finalized"::Text)]] >>= parseValue parseJSON :: IO Integer
        require (minimumRent>0 && minimumRent==toInteger lamports) "nonce_rent_mismatch"
        pure minimumRent
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
          (actualOwner,_,actualMint)<-parseValue inspectClassicAccount existing
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
      _->do
        mintInfo<-accountInfo (mint request) >>= parseValue (inspectMint (Just 8))
        tokenInfo<-accountInfo (account request) >>= parseValue inspectClassicAccount
        let (mintAuthority,supply)=mintInfo
            (owner,balance,token)=tokenInfo
        require (token==mint request) "token_account_mint_mismatch"
        case request of
          NonceMint{}->require (mintAuthority==Just(authority request) && toInteger supply+toInteger(quantity request)<=toInteger(maxBound::Word64)) "token_mint_authority_or_supply"
          Request{action=Mint}->require (mintAuthority==Just(authority request) && toInteger supply+toInteger(quantity request)<=toInteger(maxBound::Word64)) "token_mint_authority_or_supply"
          Request{action=Burn}->require (owner==authority request && balance>=quantity request && supply>=quantity request) "token_burn_authority_or_balance"
          _->reject "invalid_token_operation"
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
    [bytes,"base64"]->either (const $ reject "invalid_metadata_base64") pure (boundedBase64 679 bytes)
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
  case request of NonceMint{}->reject "nonce_requires_offline_signing"; _->pure ()
  _<-either reject pure (validate request unsigned)
  newPrivatePath output
  _<-readKey (authority request) key
  recovery<-newRecovery (genesis network) endpoint (authority request) feeLimit output
  prepareAndSign library network endpoint key request recovery
evalCritical (Recover library primary verifier path key)=withSavedFamily path $ \bytes saved->do
  before<-maybe (reject "token_recovery_context_required") pure (savedRecovery saved)
  network<-networkFor (recoveryGenesis before)
  require (recoveryGeneration before<7) "administration_recovery_limit"
  child<-successor bytes saved
  case child of
    Just next->pure (savedId next)
    Nothing->do
      _<-readKey (authority $ savedRequest saved) key
      after<-renewRecovery primary verifier (savedId saved) (savedTransaction saved) (digest bytes) before
      prepareAndSign library network primary key (savedRequest saved) after
evalCritical (Submit network endpoint feeLimit path)=withSavedFamily path $ \bytes saved->do
  forM_ (savedRecovery saved) $ \context->do
    either reject pure $ validateRecovery (genesis network) (authority $ savedRequest saved)
      feeLimit (blockhash $ savedRequest saved) context
  child<-successor bytes saved
  forM_ child $ \_->reject "token_attempt_superseded"
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

networkFor :: Text -> IO Network
networkFor value
  | value==genesis Devnet=pure Devnet
  | value==genesis Mainnet=pure Mainnet
  | otherwise=reject "wrong_token_network"

submitSaved :: Network -> String -> Word64 -> Saved -> IO Value
submitSaved network endpoint feeLimit saved=do
  unsigned<-either reject pure (validateSaved saved)
  require (feeLimit>0) "invalid_token_rpc_policy"
  withSolanaRpc endpoint (genesis network) ("invalid_token_rpc_policy","wrong_token_network") $ \call->do
    let limit=case savedRequest saved of
          Metadata{metadata=terms}->Admin.TotalDebit (M.maxCost terms)
          Associated{rent=n}->Admin.RentAndFee n
          CreateMint{rent=n}->Admin.RentAndFee n
          CreateNonce{rent=n}->Admin.RentAndFee n
          Request{}->Admin.FeeOnly
          NonceMint{}->Admin.FeeOnly
    (state,fee)<-Admin.submitSavedWith call (savedId saved) (savedTransaction saved) feeLimit limit $
      evalSafe (Check network endpoint feeLimit (savedRequest saved) unsigned) >> pure ()
    pure $ object $ ["signature" .= savedId saved,"status" .= state]<>["feeLamports" .= n | Just n<-[fee]]

-- Exact current System Program nonce layout: version, initialized tag, authority,
-- durable hash and fee calculator. Legacy nonce versions are not durable hashes.
inspectNonce :: Text -> Value -> Parser (Text,Word64)
inspectNonce authority value=do
  owner<-field "owner" value :: Parser Text
  executable<-field "executable" value
  encoded<-field "data" value :: Parser [Text]
  raw<-case encoded of
    [bytes,"base64"]->either (const $ fail "invalid nonce encoding") pure (boundedBase64 80 bytes)
    _->fail "invalid nonce encoding"
  unless (owner=="11111111111111111111111111111111" && not executable && BS.length raw==80)
    (fail "invalid nonce account")
  let parser=(,,,,) <$> getWord32le <*> getWord32le <*> getByteString 32 <*> getByteString 32 <*> getWord64le
  case runGetOrFail parser (L.fromStrict raw) of
    Right (rest,_,(1,1,key,nonce,fee)) | L.null rest && base58 key==authority && fee>0->pure(base58 nonce,fee)
    _->fail "invalid nonce state or authority"

field :: FromJSON a => Key -> Value -> Parser a
field key=withObject "field" (.:key)

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
      (actualOwner,balance,actualMint)<-inspectClassicAccount custodyValue
      unless (slot>0 && actualIssuer==issuer && actualOwner==owner && actualMint==key && balance<=supply) (fail "token policy mismatch")
      pure (slot,supply,balance)
    _->fail "expected mint and custody accounts"
