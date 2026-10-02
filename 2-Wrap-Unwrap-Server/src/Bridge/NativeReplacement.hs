{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.NativeReplacement
  ( replacementOutputs, validateNativeFamily, validateNativeReplacementDraft
  , draftNativeReplacementWith
  , NativeFamilyView(..), readNativeFamilyWith, signNativeReplacementDraftWith ) where

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

unsignedPsbtInput :: Value -> Bool
unsignedPsbtInput (Object fields)=all (\key->not $ KM.member key fields)
  ["partial_signatures","final_scriptSig","final_scriptwitness","taproot_key_path_sig","taproot_script_path_sigs"]
unsignedPsbtInput _=False

-- Sign only the already-journaled template. The caller must recheck durable
-- authorization/source/custody and save the bytes before any send decision.
signNativeReplacementDraftWith :: NativeRPC -> Config -> [NativeSigned] -> NativeDraft -> IO NativeSigned
signNativeReplacementDraftWith call c family draft=do
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
  before <- readNativeFamilyWith call c family
  require (maybe True (\(_,depth,_)->depth==0) $ familyActive before) "native_replacement_member_not_pending"
  current <- readNativePrevoutsWith False call (planDepth plan) inputs
  require (sameNativePrevouts current $ draftPrevouts draft) "native_previous_output_changed"
  _ <- ownedNativeLocks call points
  case familyActive before of
    Nothing->restoreNativeInputLocks call points >> pure ()
    Just _->pure () -- The mempool member already spends this shared set.
  signed <- signNativeTemplate call plan draft current
  either reject pure (validateNativeFamily $ family<>[signed])
  after <- readNativeFamilyWith call c family
  require (after==before) "native_family_view_changed"
  pure signed

-- Wallet records persist after eviction/replacement. Only the one member in
-- the active chain or spending ALL shared inputs in the mempool moves custody.
data NativeFamilyView = NativeFamilyView
  { familyWallet :: ![(Text,Maybe (Int,Value))]
  , familyActive :: !(Maybe (Text,Int,Value))
  } deriving (Eq,Show)

readNativeFamilyWith :: NativeRPC -> Config -> [NativeSigned] -> IO NativeFamilyView
readNativeFamilyWith call c family=do
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
    pure (position,NativeFamilyView observations selected)

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
  require (length unsignedInputs==length points && all unsignedPsbtInput unsignedInputs) "native_replacement_not_unsigned"
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
