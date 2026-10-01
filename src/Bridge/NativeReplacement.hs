{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.NativeReplacement
  ( replacementOutputs, validateNativeFamily, validateNativeReplacementDraft
  , draftNativeReplacement, draftNativeReplacementWith ) where

import Bridge.Config
import Bridge.Native
import Bridge.NativePayment
import Bridge.RPC
import Bridge.Types
import Control.Exception (try)
import Control.Monad (forM, forM_, unless)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Int (Int64)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)

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

draftNativeReplacement :: Manager -> Config -> [NativeSigned] -> Amount -> IO NativeDraft
draftNativeReplacement manager c=draftNativeReplacementWith (nativeCall manager c) c

-- This is an unsigned adapter primitive, not operator authorization. It does
-- not lock, reserve, sign, send or allocate keys. Durable family intent, backup,
-- source and custody gates must surround its eventual worker integration.
draftNativeReplacementWith :: NativeRPC -> Config -> [NativeSigned] -> Amount -> IO NativeDraft
draftNativeReplacementWith call c family fee = do
  either reject pure (validateNativeFamily family)
  require (length family<8) "native_replacement_family_bounds"
  previous <- case reverse family of p:_->pure p; _->reject "native_replacement_family_bounds"
  let plan=signedNativePlan previous
      original=signedNativeTransaction previous
      points=map nativeOutpoint $ nativeInputs original
      identifiers=map (nativeTxid.signedNativeTransaction) family
  require (planProfile plan==profile c) "payment_profile_mismatch"
  outputs <- either reject pure (replacementOutputs previous fee)
  forM_ family $ \member->do
    actual <- call False "decoderawtransaction" [toJSON $ signedNativeBytes member] >>= either reject pure . decodeNativeTx
    require (actual==signedNativeTransaction member) "native_signed_bytes_mismatch"
  script <- validateNativeRecipientWith call (planRecipient plan)
  change <- ownedScript call (planChange plan)
  require (script==planRecipientScript plan && change==planChangeScript plan) "native_replacement_script_changed"
  before <- inspect previous points identifiers
  let inputs=[object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"sequence" .= nativeSequence input]
             | input<-nativeInputs original,let point=nativeOutpoint input]
      destinations=[object [Key.fromText (if nativeOutputScript output==planRecipientScript plan then planRecipient plan else planChange plan)
                    .= nativeNumber (nativeOutputAmount output)] | output<-outputs]
  created <- call False "createpsbt" [toJSON inputs,toJSON destinations,toJSON $ nativeLocktime original,Bool False] >>= parseValue parseJSON
  boundedPsbt created
  updated <- call True "walletprocesspsbt" [toJSON created,Bool False,String "ALL",Bool False,Bool False]
  complete <- fieldValue "complete" updated
  require (not complete) "native_replacement_not_unsigned"
  psbt <- fieldValue "psbt" updated
  boundedPsbt psbt
  decoded <- call False "decodepsbt" [toJSON psbt]
  unsignedInputs <- fieldValue "inputs" decoded :: IO [Value]
  require (length unsignedInputs==length points && all unsignedInput unsignedInputs) "native_replacement_not_unsigned"
  actualFee <- fieldValue "fee" decoded >>= either reject pure . nativeAmount
  tx <- fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
  let (_,previousOutputs,_,_)=before
      draft=NativeDraft psbt tx previousOutputs actualFee
  either reject pure (validateNativeReplacementDraft family fee draft)
  after <- inspect previous points identifiers
  require (after==before) "native_replacement_view_changed"
  pure draft
 where
  boundedPsbt psbt=require (not (T.null psbt) && T.length psbt<=100000) "invalid_native_psbt"
  unsignedInput (Object fields)=all (\key->not $ KM.member key fields)
    ["partial_signatures","final_scriptSig","final_scriptwitness","taproot_key_path_sig","taproot_script_path_sigs"]
  unsignedInput _=False
  inspect previous points identifiers=do
    let plan=signedNativePlan previous
    chain <- nativeIdentityWith call c
    block <- fieldValue "bestblockhash" chain
    height <- fieldValue "blocks" chain :: IO Int64
    active <- call False "getblockhash" [toJSON height] >>= parseValue parseJSON
    require (transactionId block && active==block) "native_replacement_view_changed"
    now <- floor <$> getPOSIXTime
    nativeWalletReadyWith call c now
    wallet <- call True "getwalletinfo" []
    position <- fieldValue "lastprocessedblock" wallet
    require (position==object ["hash" .= block,"height" .= height]) "native_replacement_wallet_behind"
    observed <- forM family $ \member->do
      result <- try (call True "gettransaction" [toJSON $ nativeTxid $ signedNativeTransaction member,Bool False,Bool True]) :: IO (Either BridgeError Value)
      case result of
        Left (BridgeError "rpc_error_-5")->pure Nothing
        Left (BridgeError code)->reject code
        Right value->do
          txid <- fieldValue "txid" value
          raw <- fieldValue "hex" value
          actual <- fieldValue "decoded" value >>= either reject pure . decodeNativeTx
          cost <- fieldValue "fee" value >>= either reject pure . nativeAmount . negate
          depth <- fieldValue "confirmations" value :: IO Int
          conflicts <- fieldValue "walletconflicts" value :: IO [Text]
          processed <- fieldValue "lastprocessedblock" value
          require (txid==nativeTxid (signedNativeTransaction member) && actual==signedNativeTransaction member
            && raw==signedNativeBytes member && cost==signedNativeFee member) "native_replacement_member_changed"
          require (depth==0 && length conflicts<=8 && txid `notElem` conflicts && length conflicts==length (nub conflicts) && all (`elem` identifiers) conflicts
            && processed==position) "native_replacement_member_not_pending"
          pure (Just value)
    -- A known family member may spend these inputs in the mempool. The active
    -- chain must still contain every exact confirmed, owned original prevout.
    previousOutputs <- forM points $ \point->do
      value <- call False "gettxout" [toJSON $ outpointTxid point,toJSON $ outpointVout point,Bool False]
      require (value/=Null) "native_replacement_input_spent"
      anchor <- fieldValue "bestblock" value
      quantity <- fieldValue "value" value >>= either reject pure . nativeAmount
      depth <- fieldValue "confirmations" value
      coinbase <- fieldValue "coinbase" value
      info <- fieldValue "scriptPubKey" value
      script <- fieldValue "hex" info
      address <- fieldValue "address" info
      owned <- ownedScript call address
      require (anchor==block && script==owned && depth>=max (planDepth plan) (if coinbase then 101 else 1)) "native_replacement_input_changed"
      pure (NativePrevout point quantity script depth coinbase)
    require (sameNativePrevouts previousOutputs (signedNativePrevouts previous)) "native_previous_output_changed"
    spenders <- call False "gettxspendingprevout" [toJSON points] >>= parseValue parseJSON :: IO [Value]
    bindings <- forM spenders $ parseValue $ withObject "mempool spender" $ \o->(,) <$> parseJSON (Object o) <*> o .:? "spendingtxid"
    require (map fst bindings==points && length (nub $ map snd bindings)<=1
      && all (maybe True (`elem` identifiers).snd) bindings) "native_replacement_unknown_spender"
    locks <- ownedNativeLocks call points
    pure (position,previousOutputs,observed,(bindings,locks))
