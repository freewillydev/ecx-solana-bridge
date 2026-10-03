{-# LANGUAGE DeriveAnyClass, RecordWildCards #-}
module Bridge.NativePayment
  ( NativeRPC, Outpoint(..), NativeInput(..), NativeOutput(..), NativeTx(..)
  , NativePrevout(..), NativePlan(..), NativeDraft(..), NativeSigned(..)
  , decodeNativeTx, validateNativeTx, sameNativeTemplate, sameNativePrevouts
  , newNativePlan, fundNativeDraft, signNativeDraft
  , readNativePrevoutsWith, ownedNativeLocks, restoreNativeInputLocks, checkNativeAcceptance
  ) where

import Bridge.Wire (Profile(..))
import Bridge.Native
import Bridge.RPC
import Bridge.Domain (Amount, units)
import Bridge.Error
import Control.Monad (forM, unless, when)
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
  require (not (T.null $ draftPsbt draft) && T.length (draftPsbt draft)<=100000) "invalid_native_psbt"
  either reject pure (validateNativeTx plan (draftPrevouts draft) (draftFee draft) (draftTransaction draft))
  decoded <- call False "decodepsbt" [toJSON (draftPsbt draft)]
  unsigned <- fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
  require (sameNativeTemplate unsigned (draftTransaction draft)) "native_psbt_changed"
  current <- readNativePrevouts call (planDepth plan) (nativeInputs unsigned)
  require (sameNativePrevouts current (draftPrevouts draft)) "native_previous_output_changed"
  -- Reapply advisory locks, including after a daemon restart. Signing does
  -- not authorize sending; the caller must save the exact result to its ledger.
  _ <- restoreNativeInputLocks call (map nativeOutpoint $ nativeInputs unsigned)
  signNativeTemplate call plan draft current

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
