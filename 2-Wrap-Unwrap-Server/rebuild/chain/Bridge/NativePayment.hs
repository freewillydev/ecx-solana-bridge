{-# LANGUAGE DeriveAnyClass, RecordWildCards #-}
module Bridge.NativePayment
  ( NativeRPC, Outpoint(..), NativeInput(..), NativeOutput(..), NativeTx(..)
  , NativePrevout(..), NativePlan(..), NativeDraft(..), NativeSigned(..)
  , transactionId, ownedScript, decodeNativeTx, validateNativeTx, sameNativeTemplate, sameNativePrevouts
  , NativeFamilyView(..), readNativeFamily, draftNativeReplacement, signNativeReplacement
  , replacementOutputs, validateNativeFamily, validateNativeReplacementDraft
  , previewNativePayment, newNativePlan, fundNativeDraft, checkNativeDraft, signNativeDraft
  , readNativePrevoutsWith, ownedNativeLocks, releaseNativeInputLocks, restoreNativeInputLocks, checkNativeAcceptance
  ) where

import Bridge.Wire (Profile(..))
import Bridge.Native
import Bridge.RPC
import Bridge.Domain (Amount, amount, units)
import Bridge.Error
import Control.Exception (try)
import qualified Data.Aeson.KeyMap as KM
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.Key as Key
import Data.Int (Int64)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- Only this dedicated wallet's RPC is supplied. Tests can exercise the same
-- method contract without selecting a substitute network in the application.
type NativeRPC = Bool -> Text -> [Value] -> IO Value

data Outpoint = Outpoint { outpointTxid :: !Text, outpointVout :: !Int }
  deriving (Eq,Ord,Show,Generic)
instance ToJSON Outpoint where toJSON (Outpoint txid vout) = object ["txid" .= txid,"vout" .= vout]
instance FromJSON Outpoint where parseJSON = withObject "outpoint" $ \o -> Outpoint <$> o .: "txid" <*> o .: "vout"

data NativeInput = NativeInput { nativeOutpoint :: !Outpoint, nativeSequence :: !Int64 }
  deriving (Eq,Show,Generic,ToJSON,FromJSON)
data NativeOutput = NativeOutput { nativeOutputScript :: !Text, nativeOutputAmount :: !Amount }
  deriving (Eq,Show,Generic,ToJSON,FromJSON)
data NativeTx = NativeTx
  { nativeTxid :: !Text, nativeVersion :: !Int, nativeLocktime :: !Int64
  , nativeInputs :: ![NativeInput], nativeOutputs :: ![NativeOutput]
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)
data NativePrevout = NativePrevout
  { prevout :: !Outpoint, prevoutAmount :: !Amount, prevoutScript :: !Text
  , prevoutDepth :: !Int, prevoutCoinbase :: !Bool
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)
data NativePlan = NativePlan
  { planProfile :: !Profile, planRecipient :: !Text, planRecipientScript :: !Text
  , planChange :: !Text, planChangeScript :: !Text, planAmount :: !Amount
  , planDepth :: !Int, planFeeLimit :: !Amount
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)
data NativeDraft = NativeDraft
  { draftPsbt :: !Text, draftTransaction :: !NativeTx
  , draftPrevouts :: ![NativePrevout], draftFee :: !Amount
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)
data NativeSigned = NativeSigned
  { signedNativeBytes :: !Text, signedNativeTransaction :: !NativeTx
  , signedNativePlan :: !NativePlan, signedNativePrevouts :: ![NativePrevout]
  , signedNativeFee :: !Amount
  } deriving (Eq,Show,Generic,ToJSON,FromJSON)

hexText :: Text -> Bool
hexText t = not (T.null t) && even (T.length t) && T.all (`elem` ("0123456789abcdef"::String)) t
transactionId :: Text -> Bool
transactionId t = T.length t==64 && hexText t

decodeNativeTx :: Value -> Either Text NativeTx
decodeNativeTx = either (const $ Left "invalid_native_transaction") Right . parseEither parser
 where
  parser = withObject "transaction" $ \o -> do
    txid <- o .: "txid"
    version <- o .: "version"
    locktime <- o .: "locktime"
    ins <- o .: "vin"
    outs <- o .: "vout"
    unless (transactionId txid && not (null ins) && length ins<=100 && not (null outs) && length outs<=2) (fail "transaction bounds")
    inputs <- mapM (withObject "input" $ \i -> do
      point <- parseJSON (Object i)
      sequenceNumber <- i .: "sequence"
      unless (transactionId (outpointTxid point) && outpointVout point>=0) (fail "invalid outpoint")
      pure (NativeInput point sequenceNumber)) ins
    outputs <- forM (zip [0::Int ..] outs) $ \(index,v) -> withObject "output" (\out -> do
      n <- out .: "n"
      unless (n==index) (fail "output index")
      script <- out .: "scriptPubKey" >>= withObject "script" (.: "hex")
      value <- out .: "value" >>= either (fail . T.unpack) pure . nativeAmount
      unless (hexText script && T.length script<=200 && units value>0) (fail "output script or amount")
      pure (NativeOutput script value)) v
    pure (NativeTx txid version locktime inputs outputs)

-- Independently total the actual previous outputs. The daemon's reported fee
-- and the PSBT's own previous-output metadata are not sufficient by themselves.
validateNativeTx :: NativePlan -> [NativePrevout] -> Amount -> NativeTx -> Either Text ()
validateNativeTx NativePlan{..} previous fee tx = do
  let check condition code = unless condition (Left code)
      points=map nativeOutpoint (nativeInputs tx)
      outputs=nativeOutputs tx
      expected=NativeOutput planRecipientScript planAmount
      change=[o | o<-outputs,nativeOutputScript o==planChangeScript]
      locktime=if planProfile==L2LSignetDevnet then 0 else 499999999
      totalInputs=sum (map (toInteger.units.prevoutAmount) previous)
      totalOutputs=sum (map (toInteger.units.nativeOutputAmount) outputs)
  check (planDepth>0 && planDepth<=1008 && units planAmount>0 && units planFeeLimit>0
    && all validScript [planRecipientScript,planChangeScript] && planRecipientScript/=planChangeScript) "invalid_native_plan"
  check (transactionId (nativeTxid tx) && nativeVersion tx==2 && nativeLocktime tx==locktime && all ((==4294967294) . nativeSequence) (nativeInputs tx)) "native_replay_policy_mismatch"
  check (not (null points) && length points<=100 && length points==length (nub points) && all validPoint points && map prevout previous==points) "native_input_mismatch"
  check (all (\p->prevoutDepth p>=max planDepth (if prevoutCoinbase p then 101 else 1) && units (prevoutAmount p)>0 && validScript (prevoutScript p)) previous) "native_input_not_confirmed"
  check (all ((>0) . units . nativeOutputAmount) outputs && length (filter (==expected) outputs)==1 && (outputs==[expected] || length outputs==2 && length change==1 && all (\o->o==expected || nativeOutputScript o==planChangeScript) outputs)) "native_output_mismatch"
  check (units fee>0 && fee<=planFeeLimit && totalInputs-totalOutputs==toInteger (units fee)) "native_fee_mismatch"

 where
  validScript s=hexText s && T.length s<=200
  validPoint p=transactionId (outpointTxid p) && outpointVout p>=0

sameNativeTemplate :: NativeTx -> NativeTx -> Bool
sameNativeTemplate a b = nativeVersion a==nativeVersion b && nativeLocktime a==nativeLocktime b
  && nativeInputs a==nativeInputs b && nativeOutputs a==nativeOutputs b

ownedScript :: NativeRPC -> Text -> IO Text
ownedScript call address = do
  info <- call True "getaddressinfo" [toJSON address]
  mine <- fieldValue "ismine" info :: IO Bool
  require mine "native_input_or_change_not_owned"
  script <- fieldValue "scriptPubKey" info
  require (hexText script && T.length script<=200) "invalid_native_script"
  pure script

-- Admission uses existing owned change: no address allocation, locks or signing.
previewNativePayment :: NativeRPC -> Profile -> Int -> Amount -> Text -> Amount -> IO ()
previewNativePayment call selectedProfile depth feeLimit recipient quantity = do
  require (depth>0 && depth<=1008 && units quantity>0 && units feeLimit>0) "invalid_native_plan"
  script<-validateNativeRecipientWith call recipient
  coins<-call True "listunspent" [toJSON depth,toJSON (9999999::Int),toJSON ([]::[Text]),Bool False,
    object ["maximumCount" .= (100::Int)]] >>= parseValue parseJSON :: IO [Value]
  require (length coins<=100) "native_admission_utxo_bounds"
  addresses<-forM coins $ parseValue $ withObject "unspent" $ \o->do
    safe<-o .: "safe"; spendable<-o .: "spendable"; solvable<-o .: "solvable"
    confirmations<-o .: "confirmations"; address<-o .:? "address"
    pure $ if safe && spendable && solvable && confirmations>=depth then address else Nothing
  change<-case [a|Just a<-addresses] of a:_->pure a; []->reject "native_admission_funds_unavailable"
  changeScript<-ownedScript call change
  require (script/=changeScript) "bridge_owned_destination"
  _<-fundNativeDraft call (NativePlan selectedProfile recipient script change changeScript quantity depth feeLimit)
  locks<-call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
  require (null locks) "native_preparation_locks_require_review"

newNativePlan :: NativeRPC -> Profile -> Int -> Amount -> Text -> Amount -> IO NativePlan
newNativePlan call selectedProfile depth feeLimit recipient quantity = do
  require (depth>0 && depth<=1008 && units quantity>0 && units feeLimit>0 && T.length recipient<=128) "invalid_native_plan"
  script <- validateNativeRecipientWith call recipient
  change <- call True "getrawchangeaddress" [String "bech32"] >>= parseValue parseJSON
  changeScript <- ownedScript call change
  require (script/=changeScript) "bridge_owned_destination"
  pure (NativePlan selectedProfile recipient script change changeScript quantity depth feeLimit)

readNativePrevouts :: NativeRPC -> Int -> [NativeInput] -> IO [NativePrevout]
readNativePrevouts = readNativePrevoutsWith True

readNativePrevoutsWith :: Bool -> NativeRPC -> Int -> [NativeInput] -> IO [NativePrevout]
readNativePrevoutsWith includeMempool call depth inputs = forM inputs $ \input -> do
  let point= nativeOutpoint input
  value <- call False "gettxout" [toJSON (outpointTxid point),toJSON (outpointVout point),Bool includeMempool]
  require (value/=Null) "native_input_unavailable"
  quantity <- fieldValue "value" value >>= either reject pure . nativeAmount
  confirmations <- fieldValue "confirmations" value
  coinbase <- fieldValue "coinbase" value
  require (confirmations>=max depth (if coinbase then 101 else 1)) "native_input_not_confirmed"
  scriptInfo <- fieldValue "scriptPubKey" value
  script <- fieldValue "hex" scriptInfo
  address <- fieldValue "address" scriptInfo
  owned <- ownedScript call address
  require (script==owned) "native_input_script_mismatch"
  pure (NativePrevout point quantity script confirmations coinbase)

fundNativeDraft :: NativeRPC -> NativePlan -> IO NativeDraft
fundNativeDraft call plan@NativePlan{..} = do
  -- Unknown locks may be the result of an interrupted earlier RPC. Do not
  -- discard them or quietly select a fresh set of inputs.
  locked <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
  require (null locked) "native_preparation_locks_require_review"
  funded <- call True "walletcreatefundedpsbt"
    [ toJSON ([]::[Value]),toJSON [object [Key.fromText planRecipient .= nativeNumber planAmount]]
    , toJSON (if planProfile==L2LSignetDevnet then 0::Int64 else 499999999)
    , object ["add_inputs" .= True,"include_unsafe" .= False,"lockUnspents" .= False
      ,"replaceable" .= False,"minconf" .= planDepth,"changeAddress" .= planChange
      ,"subtractFeeFromOutputs" .= ([]::[Int]),"conf_target" .= planDepth
      ,"estimate_mode" .= ("conservative"::Text),"max_tx_weight" .= (40000::Int)]
    , Bool True ]
  psbt <- fieldValue "psbt" funded
  require (not (T.null psbt) && T.length psbt<=100000) "invalid_native_psbt"
  fee <- fieldValue "fee" funded >>= either reject pure . nativeAmount
  decoded <- call False "decodepsbt" [toJSON psbt]
  decodedFee <- fieldValue "fee" decoded >>= either reject pure . nativeAmount
  require (fee==decodedFee) "native_fee_mismatch"
  tx <- fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
  previous <- readNativePrevouts call planDepth (nativeInputs tx)
  either reject pure (validateNativeTx plan previous fee tx)
  changePosition <- fieldValue "changepos" funded :: IO Int
  let actualChange=[i | (i,o)<-zip [0..] (nativeOutputs tx),nativeOutputScript o==planChangeScript]
  require (actualChange==if changePosition== -1 then [] else [changePosition]) "native_change_position_mismatch"
  pure (NativeDraft psbt tx previous fee)

signNativeDraft :: NativeRPC -> NativePlan -> NativeDraft -> IO NativeSigned
signNativeDraft call plan draft = do
  unsigned<-checkNativeDraft call plan draft
  current <- readNativePrevouts call (planDepth plan) (nativeInputs unsigned)
  require (sameNativePrevouts current (draftPrevouts draft)) "native_previous_output_changed"
  -- Restore only saved inputs; this grants no broadcast authority.
  _ <- restoreNativeInputLocks call (map nativeOutpoint $ nativeInputs unsigned)
  signNativeTemplate call plan draft current

checkNativeDraft :: NativeRPC -> NativePlan -> NativeDraft -> IO NativeTx
checkNativeDraft call plan draft = do
  require (not (T.null $ draftPsbt draft) && T.length (draftPsbt draft)<=100000) "invalid_native_psbt"
  either reject pure (validateNativeTx plan (draftPrevouts draft) (draftFee draft) (draftTransaction draft))
  decoded <- call False "decodepsbt" [toJSON (draftPsbt draft)]
  unsigned <- fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
  require (sameNativeTemplate unsigned (draftTransaction draft)) "native_psbt_changed"
  fee<-fieldValue "fee" decoded >>= either reject pure . nativeAmount
  require (fee==draftFee draft) "native_psbt_changed"
  pure unsigned

-- Both original and replacement adapters validate the saved PSBT and current
-- input ownership before invoking this shared daemon signer. It never sends.
signNativeTemplate :: NativeRPC -> NativePlan -> NativeDraft -> [NativePrevout] -> IO NativeSigned
signNativeTemplate call plan draft current=do
  recipientScript <- validateNativeRecipientWith call (planRecipient plan)
  changeScript <- ownedScript call (planChange plan)
  require (recipientScript==planRecipientScript plan && changeScript==planChangeScript plan) "native_output_ownership_changed"
  signed <- call True "walletprocesspsbt" [toJSON (draftPsbt draft),Bool True,String "ALL",Bool True]
  complete <- fieldValue "complete" signed
  require complete "native_signing_incomplete"
  processed <- fieldValue "psbt" signed :: IO Text
  require (not (T.null processed) && T.length processed<=100000) "invalid_native_psbt"
  finalized <- call False "finalizepsbt" [toJSON processed,Bool True]
  finalComplete <- fieldValue "complete" finalized
  require finalComplete "native_finalization_incomplete"
  bytes <- fieldValue "hex" finalized
  require (T.length bytes<=200000 && hexText bytes) "invalid_native_signed_bytes"
  final <- call False "decoderawtransaction" [toJSON bytes] >>= either reject pure . decodeNativeTx
  either reject pure (validateNativeTx plan current (draftFee draft) final)
  require (sameNativeTemplate (draftTransaction draft) final) "native_signed_template_changed"
  let result=NativeSigned bytes final plan current (draftFee draft)
  checkNativeAcceptance call result
  pure result

sameNativePrevouts :: [NativePrevout] -> [NativePrevout] -> Bool
sameNativePrevouts a b = map economic a==map economic b
 where economic p=(prevout p,prevoutAmount p,prevoutScript p,prevoutCoinbase p)

-- The caller validates the saved draft/attempt and current owned prevouts first.
-- Never unlock unknown inputs or pass an empty mutation to the wallet.
ownedNativeLocks :: NativeRPC -> [Outpoint] -> IO [Outpoint]
ownedNativeLocks call expected=do
  require (length expected<=100 && length expected==length (nub expected)
    && all (\p->transactionId (outpointTxid p) && outpointVout p>=0) expected) "native_input_mismatch"
  locked <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
  require (length locked<=100 && length locked==length (nub locked) && all (`elem` expected) locked) "native_preparation_locks_require_review"
  pure locked

-- Never use Core's empty-list unlock-all operation. An unknown reply leaves the
-- durable cancellation pending; a retry observes which expected locks remain.
releaseNativeInputLocks :: NativeRPC -> [Outpoint] -> IO ()
releaseNativeInputLocks call expected=do
  locked<-ownedNativeLocks call expected
  when (not $ null locked) $ do
    ok<-call True "lockunspent" [Bool True,toJSON locked] >>= parseValue parseJSON
    require ok "native_input_unlock_failed"
  after<-ownedNativeLocks call expected
  require (null after) "native_input_unlock_unverified"

restoreNativeInputLocks :: NativeRPC -> [Outpoint] -> IO Int
restoreNativeInputLocks call expected=do
  locked <- ownedNativeLocks call expected
  let missing=filter (`notElem` locked) expected
  when (not $ null missing) $ do
    ok <- call True "lockunspent" [Bool False,toJSON missing] >>= parseValue parseJSON
    require ok "native_input_lock_failed"
  after <- ownedNativeLocks call expected
  require (length after==length expected) "native_input_lock_unverified"
  pure (length missing)

checkNativeAcceptance :: NativeRPC -> NativeSigned -> IO ()
checkNativeAcceptance call signed = do
  response <- call False "testmempoolaccept" [toJSON [signedNativeBytes signed]] >>= parseValue parseJSON :: IO [Value]
  case response of
    [result] -> do
      txid <- fieldValue "txid" result
      allowed <- parseValue (withObject "mempool acceptance" (\o -> o .:? "allowed" .!= False)) result
      require (txid==nativeTxid (signedNativeTransaction signed) && allowed) "native_transaction_not_accepted"
      fees <- fieldValue "fees" result
      fee <- fieldValue "base" fees >>= either reject pure . nativeAmount
      require (fee==signedNativeFee signed) "native_fee_mismatch"
    _ -> reject "invalid_native_acceptance_response"

-- The first replacement policy keeps ALL original inputs. The common input
-- therefore persists through every member, even if an earlier member returns.
-- Increasing the fee never changes the customer output or the saved ceiling.
replacementOutputs :: NativeSigned -> Amount -> Either Text [NativeOutput]
replacementOutputs previous fee = do
  let plan=signedNativePlan previous
      tx=signedNativeTransaction previous
  validateNativeTx plan (signedNativePrevouts previous) (signedNativeFee previous) tx
  unless (fee>signedNativeFee previous && fee<=planFeeLimit plan) (Left "native_replacement_fee_bounds")
  let delta=toInteger (units fee)-toInteger (units $ signedNativeFee previous)
      outputs=nativeOutputs tx
  unless (length [o | o<-outputs,nativeOutputScript o==planChangeScript plan]==1) (Left "native_replacement_change_unavailable")
  forM outputs $ \output->if nativeOutputScript output/=planChangeScript plan then pure output else do
    unless (toInteger (units $ nativeOutputAmount output)>delta) (Left "native_replacement_change_unavailable")
    remaining <- amount (toInteger (units $ nativeOutputAmount output)-delta)
    pure output{nativeOutputAmount=remaining}

validateNativeFamily :: [NativeSigned] -> Either Text ()
validateNativeFamily [] = Left "native_replacement_family_bounds"
validateNativeFamily family@(first:_) = do
  unless (length family<=8) (Left "native_replacement_family_bounds")
  let identifiers=map (nativeTxid.signedNativeTransaction) family
  unless (length identifiers==length (nub identifiers)) (Left "native_replacement_duplicate_member")
  forM_ family $ \member->do
    let tx=signedNativeTransaction member
    unless (transactionId (nativeTxid tx) && hexText (signedNativeBytes member)
      && T.length (signedNativeBytes member)<=200000) (Left "invalid_native_signed_bytes")
    validateNativeTx (signedNativePlan member) (signedNativePrevouts member) (signedNativeFee member) tx
    unless (signedNativePlan member==signedNativePlan first
      && nativeInputs tx==nativeInputs (signedNativeTransaction first)
      && sameNativePrevouts (signedNativePrevouts member) (signedNativePrevouts first)) (Left "native_replacement_family_changed")
  forM_ (zip family $ drop 1 family) $ \(older,newer)->do
    expected <- replacementOutputs older (signedNativeFee newer)
    unless (nativeOutputs (signedNativeTransaction newer)==expected) (Left "native_replacement_outputs_changed")

validateNativeReplacementDraft :: [NativeSigned] -> Amount -> NativeDraft -> Either Text ()
validateNativeReplacementDraft family fee draft = do
  validateNativeFamily family
  unless (length family<8) (Left "native_replacement_family_bounds")
  previous <- case reverse family of p:_->Right p; _->Left "native_replacement_family_bounds"
  let tx=draftTransaction draft
      plan=signedNativePlan previous
  expected <- replacementOutputs previous fee
  validateNativeTx plan (draftPrevouts draft) fee tx
  unless (transactionId (nativeTxid tx) && draftFee draft==fee && nativeInputs tx==nativeInputs (signedNativeTransaction previous)
    && sameNativePrevouts (draftPrevouts draft) (signedNativePrevouts previous)
    && nativeOutputs tx==expected && nativeTxid tx `notElem` map (nativeTxid.signedNativeTransaction) family)
    (Left "native_replacement_draft_changed")

unsignedPsbtInput :: Value -> Bool
unsignedPsbtInput (Object fields)=all (\key->not $ KM.member key fields)
  ["partial_signatures","final_scriptSig","final_scriptwitness","taproot_key_path_sig","taproot_script_path_sigs"]
unsignedPsbtInput _=False

-- Sign only the already-journaled template. The caller must recheck durable
-- authorization/source/custody and save the bytes before any send decision.
signNativeReplacement :: NativeRPC -> NativeSettings -> [NativeSigned] -> NativeDraft -> IO NativeSigned
signNativeReplacement call c family draft=do
  either reject pure (validateNativeReplacementDraft family (draftFee draft) draft)
  previous <- case reverse family of s:_->pure s; _->reject "native_replacement_family_bounds"
  let plan=signedNativePlan previous
      inputs=nativeInputs $ draftTransaction draft
      points=map nativeOutpoint inputs
  require (not (T.null $ draftPsbt draft) && T.length (draftPsbt draft)<=100000) "invalid_native_psbt"
  decoded <- call False "decodepsbt" [toJSON $ draftPsbt draft]
  tx <- fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
  fee <- fieldValue "fee" decoded >>= either reject pure . nativeAmount
  psbtInputs <- fieldValue "inputs" decoded :: IO [Value]
  require (tx==draftTransaction draft && fee==draftFee draft
    && length psbtInputs==length inputs && all unsignedPsbtInput psbtInputs) "native_replacement_draft_changed"
  before <- readNativeFamily call c family
  require (maybe True (\(_,depth,_)->depth==0) $ familyActive before) "native_replacement_member_not_pending"
  current <- readNativePrevoutsWith False call (planDepth plan) inputs
  require (sameNativePrevouts current $ draftPrevouts draft) "native_previous_output_changed"
  _ <- ownedNativeLocks call points
  case familyActive before of
    Nothing->restoreNativeInputLocks call points >> pure ()
    Just _->pure () -- The mempool member already spends this shared set.
  signed <- signNativeTemplate call plan draft current
  either reject pure (validateNativeFamily $ family<>[signed])
  after <- readNativeFamily call c family
  require (after==before) "native_family_view_changed"
  pure signed

-- Wallet records persist after eviction/replacement. Only the one member in
-- the active chain or spending ALL shared inputs in the mempool moves custody.
data NativeFamilyView = NativeFamilyView
  { familyPosition :: !Value
  , familyWallet :: ![(Text,Maybe (Int,Value))]
  , familyActive :: !(Maybe (Text,Int,Value))
  } deriving (Eq,Show)

readNativeFamily :: NativeRPC -> NativeSettings -> [NativeSigned] -> IO NativeFamilyView
readNativeFamily call c family=do
  either reject pure (validateNativeFamily family)
  first <- case family of a:_->pure a; _->reject "native_replacement_family_bounds"
  require (planProfile (signedNativePlan first)==profile c) "payment_profile_mismatch"
  forM_ family $ \signed->do
    actual <- call False "decoderawtransaction" [toJSON $ signedNativeBytes signed] >>= either reject pure . decodeNativeTx
    require (actual==signedNativeTransaction signed) "native_signed_bytes_mismatch"
  before <- inspect first
  after <- inspect first
  require (after==before) "native_family_view_changed"
  pure (snd before)
 where
  identifiers=map (nativeTxid.signedNativeTransaction) family
  inspect first=do
    chain <- nativeIdentityWith call c
    block <- fieldValue "bestblockhash" chain
    height <- fieldValue "blocks" chain :: IO Int64
    wallet <- call True "getwalletinfo" []
    name <- fieldValue "walletname" wallet
    descriptors <- fieldValue "descriptors" wallet
    scanning <- fieldValue "scanning" wallet :: IO Value
    position <- fieldValue "lastprocessedblock" wallet
    active <- call False "getblockhash" [toJSON height] >>= parseValue parseJSON
    require (name==nativeWallet c && descriptors && scanning==Bool False
      && transactionId block && active==block && position==object ["hash" .= block,"height" .= height]) "native_family_wallet_behind"
    observations <- forM family $ \signed->do
      let txid=nativeTxid $ signedNativeTransaction signed
      found <- try (call True "gettransaction" [toJSON txid,Bool False,Bool True]) :: IO (Either BridgeError Value)
      value <- case found of
        Left (BridgeError "rpc_error_-5")->pure Nothing
        Left (BridgeError code)->reject code
        Right value->do
          actual <- fieldValue "decoded" value >>= either reject pure . decodeNativeTx
          raw <- fieldValue "hex" value
          actualId <- fieldValue "txid" value
          fee <- fieldValue "fee" value >>= either reject pure . nativeAmount . negate
          depth <- fieldValue "confirmations" value
          processed <- fieldValue "lastprocessedblock" value
          require (actualId==txid && raw==signedNativeBytes signed && actual==signedNativeTransaction signed
            && fee==signedNativeFee signed && processed==position) "native_family_member_changed"
          forM_ ["walletconflicts","mempoolconflicts"] $ \key->do
            conflicts <- parseValue (withObject "conflicts" (\o->o .:? key .!= [])) value :: IO [Text]
            require (length conflicts<=7 && length conflicts==length (nub conflicts)
              && txid `notElem` conflicts && all (`elem` identifiers) conflicts) "native_family_unknown_conflict"
          pure (Just (depth,value))
      pure (txid,value)
    let points=map nativeOutpoint $ nativeInputs $ signedNativeTransaction first
    spending <- call False "gettxspendingprevout" [toJSON points] >>= parseValue parseJSON :: IO [Value]
    bindings <- forM spending $ parseValue $ withObject "spender" $ \o->(,) <$> parseJSON (Object o) <*> o .:? "spendingtxid"
    require (map fst bindings==points && length (nub $ map snd bindings)==1
      && all (maybe True (`elem` identifiers).snd) bindings) "native_family_unknown_spender"
    let mempool=case bindings of (_,Just txid):_->Just txid; _->Nothing
        confirmed=[(txid,depth,value) | (txid,Just (depth,value))<-observations,depth>0]
    selected <- case confirmed of
      [winner@(txid,depth,value)]->do
        require (mempool==Nothing) "native_family_conflicting_effects"
        anchor <- fieldValue "blockhash" value
        header <- call False "getblockheader" [toJSON (anchor::Text)]
        actualHash <- fieldValue "hash" header
        actualDepth <- fieldValue "confirmations" header :: IO Int
        actualHeight <- fieldValue "height" header :: IO Int64
        canonical <- call False "getblockhash" [toJSON actualHeight] >>= parseValue parseJSON
        require (transactionId anchor && actualHash==anchor && canonical==anchor && actualDepth==depth
          && toInteger actualHeight+toInteger depth-1==toInteger height) "native_family_winner_not_canonical"
        forM_ observations $ \(_,seen)->case seen of
          Just (n,other) | n<0->do
            conflicts <- fieldValue "walletconflicts" other :: IO [Text]
            require (txid `elem` conflicts && toInteger n==negate (toInteger depth)) "native_family_conflict_not_proven"
          _->pure ()
        pure (Just winner)
      []->do
        require (all (maybe True ((>=0).fst).snd) observations) "native_family_conflict_not_proven"
        previous <- readNativePrevoutsWith False call (planDepth $ signedNativePlan first) (nativeInputs $ signedNativeTransaction first)
        require (sameNativePrevouts previous (signedNativePrevouts first)) "native_previous_output_changed"
        case mempool of
          Nothing->pure Nothing
          Just txid->do
            value <- case lookup txid observations of Just (Just (0,v))->pure v; _->reject "native_family_spender_unavailable"
            entry <- call False "getmempoolentry" [toJSON txid]
            size <- fieldValue "vsize" entry :: IO Int
            require (size>0) "native_mempool_evidence_invalid"
            pure (Just (txid,0,value))
      _->reject "native_family_multiple_winners"
    -- Fence both the wallet's view and the node's active tip after all reads.
    end <- call True "getwalletinfo" [] >>= fieldValue "lastprocessedblock"
    tip <- call False "getblockchaininfo" [] >>= fieldValue "bestblockhash"
    require (end==position && tip==block) "native_family_view_changed"
    pure (position,NativeFamilyView position observations selected)

-- Unsigned construction reuses the same family reader as signing/settlement.
-- It allocates no keys, changes no locks and never supplies signing=true.
draftNativeReplacement :: NativeRPC -> NativeSettings -> [NativeSigned] -> Amount -> IO NativeDraft
draftNativeReplacement call c family fee = do
  either reject pure (validateNativeFamily family)
  require (length family<8) "native_replacement_family_bounds"
  previous<-case reverse family of p:_->pure p; _->reject "native_replacement_family_bounds"
  let plan=signedNativePlan previous; original=signedNativeTransaction previous
      inputs=nativeInputs original; points=map nativeOutpoint inputs
  outputs<-either reject pure (replacementOutputs previous fee)
  script<-validateNativeRecipientWith call (planRecipient plan)
  change<-ownedScript call (planChange plan)
  require (script==planRecipientScript plan && change==planChangeScript plan) "native_replacement_script_changed"
  let inspect=do
        view<-readNativeFamily call c family
        require (maybe True (\(_,depth,_)->depth==0) $ familyActive view) "native_replacement_member_not_pending"
        prevouts<-readNativePrevoutsWith False call (planDepth plan) inputs
        require (sameNativePrevouts prevouts $ signedNativePrevouts previous) "native_previous_output_changed"
        locks<-ownedNativeLocks call points
        pure (view,prevouts,locks)
  before@(_,prevouts,_)<-inspect
  let sources=[object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"sequence" .= nativeSequence input]
              | input<-inputs,let point=nativeOutpoint input]
      destinations=[object [Key.fromText (if nativeOutputScript output==planRecipientScript plan then planRecipient plan else planChange plan)
                     .= nativeNumber (nativeOutputAmount output)] | output<-outputs]
  created<-call False "createpsbt" [toJSON sources,toJSON destinations,toJSON $ nativeLocktime original,Bool False] >>= parseValue parseJSON
  bounded created
  updated<-call True "walletprocesspsbt" [toJSON created,Bool False,String "ALL",Bool False,Bool False]
  complete<-fieldValue "complete" updated
  require (not complete) "native_replacement_not_unsigned"
  psbt<-fieldValue "psbt" updated
  bounded psbt
  decoded<-call False "decodepsbt" [toJSON psbt]
  unsigned<-fieldValue "inputs" decoded :: IO [Value]
  require (length unsigned==length inputs && all unsignedPsbtInput unsigned) "native_replacement_not_unsigned"
  actualFee<-fieldValue "fee" decoded >>= either reject pure . nativeAmount
  tx<-fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
  let draft=NativeDraft psbt tx prevouts actualFee
  either reject pure (validateNativeReplacementDraft family fee draft)
  after<-inspect
  require (after==before) "native_replacement_view_changed"
  pure draft
 where bounded psbt=require (not(T.null psbt) && T.length psbt<=100000) "invalid_native_psbt"
