-- Captured public L2L Signet payment plus offline mutation/RPC contracts.
-- The spent fixture input is not a spendable wallet or live acceptance evidence.
module NativePaymentCheck (checks) where

import Bridge.Domain (Asset(..),amount, units,refund,earnedFees,payment)
import Bridge.Payment
import Bridge.PaymentObservation
import Bridge.Store
import qualified Bridge.Wire as W
import qualified Bridge.SolanaHelper as H
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Bridge.Error
import Bridge.Native (nativeNumber, NativeSettings(..), signetChallenge)
import Bridge.NativePayment
import Bridge.RPC (fieldValue)
import Bridge.Wire (Profile(..))
import Control.Exception (try)
import Control.Monad (forM)
import Data.Aeson hiding (Result)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Paths_ecx_bridge (getDataFileName)
import Test.QuickCheck hiding (Success)

checks :: IO [Result]
checks = do
  path <- getDataFileName "test/fixtures/native-signet-payment.json"
  fixture <- BS.readFile path >>= either fail pure . eitherDecodeStrict'
  plan <- fieldValue "plan" fixture
  previous <- fieldValue "previous" fixture
  fee <- fieldValue "fee" fixture
  raw <- fieldValue "raw" fixture
  decoded <- fieldValue "decoded" fixture
  tx <- either (fail . T.unpack) pure (decodeNativeTx decoded)
  let recoverySettings=NativeSettings L2LSignetDevnet "http://127.0.0.1:1" "/unused" "offline-recovery" 16000
        "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
      validate p ps f t=validateNativeTx p ps f t
      valid=validate plan previous fee
      draft=NativeDraft "offline-psbt" tx previous fee
      alteredPlans=[plan {planAmount=amt 100001},plan {planRecipientScript="0014"<>T.replicate 40 "a"},
        plan {planChangeScript="0014"<>T.replicate 40 "b"}]
      badTransactions=[tx {nativeTxid="invalid"},tx {nativeLocktime=1},tx {nativeVersion=1},
        tx {nativeInputs=nativeInputs tx<>nativeInputs tx},
        tx {nativeOutputs=nativeOutputs tx<>[NativeOutput "6a00" (amt 1)]},
        tx {nativeOutputs=map (\o->o {nativeOutputAmount=amt 0}) (nativeOutputs tx)}]
  let contract tweak action=do
        locks <- newIORef ([]::[Outpoint]); calls <- newIORef ([]::[Text])
        let tip=T.replicate 64 "b"
            anchor=if planDepth plan==1 then tip else T.replicate 64 "e"
            position=object ["hash" .= tip,"height" .= (16010::Int)]
            base _ method args=case (method,args) of
              ("getblockchaininfo",[])->pure $ object ["chain" .= ("signet"::Text),"initialblockdownload" .= False
                ,"blocks" .= (16010::Int),"bestblockhash" .= tip,"signet_challenge" .= signetChallenge]
              ("getconnectioncount",[])->pure $ toJSON (1::Int)
              ("getwalletinfo",[])->pure $ object ["walletname" .= nativeWallet recoverySettings,"descriptors" .= True
                ,"scanning" .= False,"lastprocessedblock" .= position]
              ("gettransaction",[String ident,Bool False,Bool True]) | ident==nativeTxid tx->pure $ object
                ["hex" .= (raw::Text),"decoded" .= decoded,"txid" .= nativeTxid tx,"fee" .= Number (negate $ fromIntegral(units fee)/100000000)
                ,"confirmations" .= planDepth plan,"walletconflicts" .= ([]::[Text]),"blockhash" .= anchor,"lastprocessedblock" .= position]
              ("gettxspendingprevout",_)->pure $ toJSON $ map nativeOutpoint $ nativeInputs tx
              ("getmempoolentry",_)->pure $ object ["vsize" .= (140::Int)]
              ("getblockheader",[String block])->pure $ object ["hash" .= block,"height" .= (16011-planDepth plan),"confirmations" .= planDepth plan]
              ("getblockhash",[height]) | height==toJSON(nativeCheckpointHeight recoverySettings)->pure $ toJSON $ nativeCheckpointHash recoverySettings
              ("getblockhash",[Number 16010])->pure $ String tip
              ("getblockhash",[height]) | height==toJSON(16011-planDepth plan)->pure $ String anchor
              ("listunspent",[_,_,_,Bool False,_])->pure $ toJSON [object ["safe" .= True,"spendable" .= True,
                "solvable" .= True,"confirmations" .= planDepth plan,"address" .= planChange plan]]
              ("listlockunspent",[])->toJSON <$> readIORef locks
              ("lockunspent",[Bool False,v])->case fromJSON v of
                Success ps | not(null ps)->modifyIORef' locks (<>ps) >> pure (Bool True)
                _->fail "invalid lock mutation"
              ("walletcreatefundedpsbt",[_,_,_,options,Bool True])->do
                locksInputs<-fieldValue "lockUnspents" options
                require (not locksInputs) "preparation_must_not_lock"
                pure $ object ["psbt" .= ("offline-psbt"::Text),"fee" .= nativeNumber fee,"changepos" .= (0::Int)]
              ("decodepsbt",_)->pure $ object ["tx" .= decoded,"fee" .= nativeNumber fee]
              ("gettxout",[String txid,vout,Bool _])->case [p | p<-previous,toJSON(outpointVout $ prevout p)==vout,outpointTxid(prevout p)==txid] of
                [p]->pure $ object ["value" .= nativeNumber(prevoutAmount p),"confirmations" .= prevoutDepth p,
                  "coinbase" .= prevoutCoinbase p,"scriptPubKey" .= object ["hex" .= prevoutScript p,"address" .= ("offline-prevout"::Text)]]
                _->fail "unexpected prevout"
              ("getaddressinfo",[String address])->do
                script<-if address==planRecipient plan then pure(planRecipientScript plan)
                  else if address==planChange plan then pure(planChangeScript plan)
                  else case previous of [p] | address=="offline-prevout"->pure(prevoutScript p); _->fail "unexpected address"
                pure $ object ["ismine" .= (address/=planRecipient plan),"scriptPubKey" .= script]
              ("decodescript",_)->pure $ object ["type" .= ("witness_v0_keyhash"::Text)]
              ("walletprocesspsbt",[String "offline-psbt",Bool True,String "ALL",Bool True])->pure $ object ["complete" .= True,"psbt" .= ("offline-signed-psbt"::Text)]
              ("finalizepsbt",[String "offline-signed-psbt",Bool True])->pure $ object ["complete" .= True,"hex" .= (raw::Text)]
              ("decoderawtransaction",[String bytes]) | bytes==raw->pure decoded
              ("testmempoolaccept",[v]) | v==toJSON [raw]->pure $ toJSON [object ["txid" .= nativeTxid tx,"allowed" .= True,"fees" .= object ["base" .= nativeNumber fee]]]
              _->fail ("unexpected native method: "<>T.unpack method)
            call wallet method args=modifyIORef' calls (<>[method]) >> base wallet method args >>= tweak method
        result<-action call
        methods<-readIORef calls
        pure (result,methods)
  funding<-either reject pure (refund "order" "receipt" Native $ planAmount plan)
  outgoing<-either reject pure (payment "refund:order" funding $ planRecipient plan)
  let encoded value=TE.decodeUtf8 (BL.toStrict $ encode value)
      config=H.SolanaPolicy "unused-native-test" "workflow" "" "" "" (amt 1) (amt 0)
      terms=W.PaymentTerms (W.PolicySnapshot (planDepth plan) "finalized" "workflow") (W.CostLimits (planFeeLimit plan) (amt 1) (amt 0))
      prepared=PreparedPayment (PaymentView outgoing terms PaymentPaying) 0 (encoded plan) (Just $ encoded draft) (planFeeLimit plan)
      boundSigned=NativeSigned raw tx plan previous fee
      observe call=do
        view<-readNativeFamily call recoverySettings [boundSigned]
        case familyActive view of
          Nothing->pure PaymentUnseen
          Just (_,depth,value)->nativeConfirmation call boundSigned depth value
      unconfirmed method (Object fields) | method=="gettransaction"=pure $ Object $ KM.delete "blockhash" $ KM.insert "confirmations" (Number 0) fields
      unconfirmed _ value=pure value
      mempool method _ | method=="gettxspendingprevout"=pure $ toJSON
        [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"spendingtxid" .= nativeTxid tx]
          | point<-map nativeOutpoint $ nativeInputs tx]
      mempool method value=unconfirmed method value
  sequence
    [ check "native admission previews actual policy without allocating locking signing or sending" $ once $ ioProperty $ do
        (_,methods)<-contract (\_ v->pure v) $ \call->previewNativePayment call (planProfile plan) (planDepth plan) (planFeeLimit plan) (planRecipient plan) (planAmount plan)
        (empty,_)<-contract (\method value->pure $ if method=="listunspent" then toJSON ([]::[Value]) else value) $ \call->
          rejects "native_admission_funds_unavailable" (previewNativePayment call (planProfile plan) (planDepth plan) (planFeeLimit plan) (planRecipient plan) (planAmount plan))
        pure (empty && "walletcreatefundedpsbt" `elem` methods && "gettxout" `elem` methods
          && all (`notElem` methods) ["getnewaddress","getrawchangeaddress","lockunspent","walletprocesspsbt","sendrawtransaction"])
    , check "native settlement requires exact wallet effect and canonical confirmation depth" $ once $ ioProperty $ do
        (observed,methods)<-contract (\_ v->pure v) observe
        (waiting,waitMethods)<-contract mempool observe
        (forked,_)<-contract (\_ v->pure v) $ \call->do
          view<-readNativeFamily call recoverySettings [boundSigned]
          let changed wallet method args=if method=="getblockhash" then pure $ String(T.replicate 64 "a") else call wallet method args
          case familyActive view of
            Just (_,depth,value)->rejects "native_settlement_not_canonical" (nativeConfirmation changed boundSigned depth value)
            Nothing->pure False
        (unseen,_)<-contract (\method value->if method=="gettransaction" then reject "rpc_error_-5" else pure value) observe
        (unavailable,_)<-contract (\method value->if method=="gettransaction" then reject "rpc_transport_unknown_outcome" else pure value) $ \call->
          rejects "rpc_transport_unknown_outcome" (observe call)
        pure $ "getblockheader" `elem` methods && "getmempoolentry" `elem` waitMethods && "getblockheader" `notElem` waitMethods
          && waiting==PaymentWaiting && unseen==PaymentUnseen && forked && unavailable
          && case observed of PaymentConfirmed costs proof->costs==W.PaymentCosts fee (amt 0) && not(T.null proof); _->False
    , check "native outcome refuses changed bytes and wallet conflict evidence" $ once $ ioProperty $ do
        let corrupt key value method (Object fields) | method=="gettransaction"=pure $ Object $ KM.insert key value fields
            corrupt _ _ _ value=pure value
        (bytes,_)<-contract (corrupt "hex" $ String "changed") $ \call->rejects "native_family_member_changed" (observe call)
        (conflict,_)<-contract (corrupt "walletconflicts" $ toJSON ["other"::Text]) $ \call->rejects "native_family_unknown_conflict" (observe call)
        pure (bytes && conflict)
    , check "worker independently decodes returned native bytes against the durable draft" $ once $ ioProperty $ do
        (attempt,methods)<-contract (\_ v->pure v) $ \call->verifySigningReply call L2LSignetDevnet config prepared (NativeReply boundSigned)
        (refused,_)<-contract (\method value->pure $ if method=="decoderawtransaction" then changedVersion value else value) $ \call->
          rejects "native_signed_bytes_mismatch" (verifySigningReply call L2LSignetDevnet config prepared $ NativeReply boundSigned)
        pure (signedBytes attempt==raw && signedId attempt==nativeTxid tx && methods==["decoderawtransaction"] && refused)
    , check "signing boundary rejects mismatched profile reserved fee and returned fee" $ once $ ioProperty $ do
        wrongProfile<-rejects "saved_native_policy_mismatch" (resolveSigningPlan ECXBetanetDevnet config prepared)
        wrongFee<-rejects "saved_native_policy_mismatch" (resolveSigningPlan L2LSignetDevnet config prepared {preparedFee=amt 1})
        wrongTemplate<-rejects "native_signed_template_changed" $ verifySigningReply (\_ _ _->fail "unexpected RPC") L2LSignetDevnet config prepared (NativeReply boundSigned {signedNativeFee=amt 1})
        pure (wrongProfile && wrongFee && wrongTemplate)
    , check "native preparation and signing retain captured template and bytes without sending" $ once $ ioProperty $ do
        (signed,methods)<-contract (\_ v->pure v) $ \call->do
          funded<-fundNativeDraft call plan
          signNativeDraft call plan funded
        pure (signedNativeBytes signed==raw && signedNativeTransaction signed==tx && signedNativeFee signed==fee &&
          length(filter (=="walletprocesspsbt") methods)==1 && last methods=="testmempoolaccept" &&
          all (`notElem` methods) ["sendrawtransaction","sendtoaddress"])
    , check "changed current input value refuses before locking or signing" $ once $ ioProperty $ do
        let change method (Object fields) | method=="gettxout"=pure $ Object $ KM.insert "value" (nativeNumber $ amt 1) fields
            change _ value=pure value
        (refused,methods)<-contract change $ \call->rejects "native_previous_output_changed" (signNativeDraft call plan draft)
        pure (refused && all (`notElem` methods) ["lockunspent","walletprocesspsbt"])
    , check "native final signed template and mempool fee are rechecked" $ once $ ioProperty $ do
        let changedFinal method value=pure $ if method=="decoderawtransaction" then changedVersion value else value
            changedFee method value=pure $ if method=="testmempoolaccept"
              then toJSON [object ["txid" .= nativeTxid tx,"allowed" .= True,"fees" .= object ["base" .= nativeNumber (amt 283)]]]
              else value
        (badFinal,_)<-contract changedFinal $ \call->rejects "native_replay_policy_mismatch" (signNativeDraft call plan draft)
        (badFee,_)<-contract changedFee $ \call->rejects "native_fee_mismatch" (signNativeDraft call plan draft)
        pure (badFinal && badFee)
    , check "captured native payment preserves exact transaction and fee" $ once $
        valid tx==Right () && fee==amt 282 &&
        nativeTxid tx=="b2278e8dd0be7be001a5630545ddb73c83423ee1ee7dbd0327675e27f1642bd3"
    , check "replacement drafting matches captured PSBT without signing locking or sending" $ once $ ioProperty $
        withNativeReplacementContract $ \c original expected call calls->do
          actual<-draftNativeReplacement call c [original] (draftFee expected)
          methods<-readIORef calls
          pure (actual==expected && all (\(method,args)->method `notElem` ["sendrawtransaction","getnewaddress","lockunspent"]
            && (method/="walletprocesspsbt" || case args of _:Bool False:_->True; _->False)) methods)
    , check "replacement permits an absent saved family but rejects a changed construction tip" $ once $ ioProperty $
        withNativeReplacementContract $ \c original expected call _->do
          let points=map nativeOutpoint $ nativeInputs $ signedNativeTransaction original
              absent wallet method args=case method of
                "gettransaction"->reject "rpc_error_-5"
                "gettxspendingprevout"->pure (toJSON points)
                _->call wallet method args
          actual<-draftNativeReplacement absent c [original] (draftFee expected)
          changed<-newIORef False
          let moving wallet method args=do
                value<-absent wallet method args
                whenChanged<-readIORef changed
                if method=="createpsbt" then writeIORef changed True >> pure value else
                  if not whenChanged then pure value else do
                    let tip=T.replicate 64 "f"; position=object ["hash" .= tip,"height" .= (16010::Int)]
                    pure $ case (method,args,value) of
                      ("getblockchaininfo",_,Object fields)->Object (KM.insert "bestblockhash" (String tip) fields)
                      ("getwalletinfo",_,Object fields)->Object (KM.insert "lastprocessedblock" position fields)
                      ("getblockhash",[Number 16010],_)->String tip
                      _->value
          refused<-rejects "native_replacement_view_changed" (draftNativeReplacement moving c [original] $ draftFee expected)
          pure (actual==expected && refused)
    , check "replacement refuses a canonical confirmed winner before creating a PSBT" $ once $ ioProperty $
        withNativeReplacementContract $ \c original expected call calls->do
          let points=map nativeOutpoint $ nativeInputs $ signedNativeTransaction original
              tip=T.replicate 64 "b"
              confirmed wallet method args=case method of
                "gettxspendingprevout"->pure (toJSON points)
                "getblockheader"->pure $ object ["hash" .= tip,"height" .= (16010::Int),"confirmations" .= (1::Int)]
                _->do
                  value<-call wallet method args
                  pure $ case value of Object fields | method=="gettransaction"->Object (KM.insert "blockhash" (String tip) $ KM.insert "confirmations" (Number 1) fields); _->value
          refused<-rejects "native_replacement_member_not_pending" (draftNativeReplacement confirmed c [original] $ draftFee expected)
          methods<-map fst <$> readIORef calls
          pure (refused && "createpsbt" `notElem` methods)
    , check "singleton family distinguishes a retained evicted wallet record from an active spender" $ once $ ioProperty $
        withNativeReplacementContract $ \c original _ call calls->do
          let txid=nativeTxid $ signedNativeTransaction original
              points=map nativeOutpoint $ nativeInputs $ signedNativeTransaction original
              evicted wallet method args=case method of
                "gettxspendingprevout"->pure (toJSON points)
                "getmempoolentry"->reject "rpc_error_-5"
                _->call wallet method args
              unseen wallet method args=if method=="gettransaction" then reject "rpc_error_-5" else evicted wallet method args
          active<-readNativeFamily call c [original]
          writeIORef calls []
          retained<-readNativeFamily evicted c [original]
          missing<-readNativeFamily unseen c [original]
          methods<-map fst <$> readIORef calls
          let activeId=fmap (\(key,depth,_)->(key,depth)) $ familyActive active
              retainedRecord=case familyWallet retained of [(key,Just (0,_))]->key==txid; _->False
          pure (activeId==Just(txid,0) && retainedRecord && familyActive retained==Nothing
            && familyWallet missing==[(txid,Nothing)] && familyActive missing==Nothing
            && "gettxout" `elem` methods && all (`notElem` methods)
              ["getmempoolentry","walletprocesspsbt","lockunspent","sendrawtransaction"])
    , check "singleton absence requires stable owned inputs and rejects missing or conflicting evidence" $ once $ ioProperty $
        withNativeReplacementContract $ \c original _ call calls->do
          let points=map nativeOutpoint $ nativeInputs $ signedNativeTransaction original
              absent wallet method args=if method=="gettxspendingprevout" then pure (toJSON points) else call wallet method args
              inspect rpc=readNativeFamily rpc c [original]
              unavailable wallet method args=if method=="gettxspendingprevout" then reject "rpc_transport_unknown_outcome" else call wallet method args
              spent wallet method args=if method=="gettxout" then pure Null else absent wallet method args
              missingEntry wallet method args=if method=="getmempoolentry" then reject "rpc_error_-5" else call wallet method args
              conflict wallet method args=do
                value<-absent wallet method args
                pure $ case value of
                  Object fields | method=="gettransaction"->Object $ KM.insert "walletconflicts" (toJSON [T.replicate 64 "f"]) fields
                  _->value
              foreignSpender wallet method args=if method=="gettxspendingprevout" then pure $ toJSON
                [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"spendingtxid" .= T.replicate 64 "f"] | point<-points]
                else call wallet method args
          unknown<-rejects "rpc_transport_unknown_outcome" (inspect unavailable)
          unavailableInput<-rejects "native_input_unavailable" (inspect spent)
          unavailableEntry<-rejects "rpc_error_-5" (inspect missingEntry)
          walletConflict<-rejects "native_family_unknown_conflict" (inspect conflict)
          foreignSpend<-rejects "native_family_unknown_spender" (inspect foreignSpender)
          reads<-newIORef (0::Int)
          let changed wallet method args
                | method=="gettxspendingprevout"=do
                    n<-readIORef reads
                    modifyIORef' reads (+1)
                    if n==0 then pure (toJSON points) else call wallet method args
                | otherwise=call wallet method args
          unstable<-rejects "native_family_view_changed" (inspect changed)
          methods<-map fst <$> readIORef calls
          pure (and [unknown,unavailableInput,unavailableEntry,walletConflict,foreignSpend,unstable]
            && all (`notElem` methods) ["walletprocesspsbt","lockunspent","sendrawtransaction"])
    , check "replacement signer checks the captured draft and never broadcasts" $ once $ ioProperty $
        withNativeReplacementContract $ \c original expected call calls->do
          signed<-signNativeReplacement call c [original] expected
          methods<-map fst <$> readIORef calls
          pure (signedNativeTransaction signed==draftTransaction expected && signedNativeFee signed==draftFee expected
            && "sendrawtransaction" `notElem` methods && "getnewaddress" `notElem` methods)
    , check "replacement rejects foreign spenders and signed PSBT inputs before construction or signing" $ once $ ioProperty $
        withNativeReplacementContract $ \c original expected call calls->do
          let foreignSpender wallet method args=if method=="gettxspendingprevout" then pure $ toJSON
                [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"spendingtxid" .= T.replicate 64 "f"]
                  | point<-map nativeOutpoint $ nativeInputs $ signedNativeTransaction original] else call wallet method args
              signedInput wallet method args=do
                value<-call wallet method args
                pure $ case value of Object fields | method=="decodepsbt"->Object $ KM.insert "inputs" (toJSON [object ["partial_signatures" .= object []]]) fields; _->value
          foreignRefused<-rejects "native_family_unknown_spender" (draftNativeReplacement foreignSpender c [original] $ draftFee expected)
          signatureRefused<-rejects "native_replacement_draft_changed" (signNativeReplacement signedInput c [original] expected)
          methods<-readIORef calls
          pure (foreignRefused && signatureRefused && all (\(method,args)->method/="walletprocesspsbt" || case args of _:Bool False:_->True; _->False) methods)
    , check "family recovery selects one verified spender and restores absent inputs only once" $ once $ ioProperty $
        withNativeReplacementContract $ \c original replacement call calls->do
          firstWire<-verifySigningReply call L2LSignetDevnet config prepared (NativeReply original)
          let child=original {signedNativeBytes="00",signedNativeTransaction=draftTransaction replacement,signedNativeFee=draftFee replacement}
              childWire=firstWire {signedId=nativeTxid $ signedNativeTransaction child,signedBytes="00",signedPolicy=encoded child}
              record wire=RecordedAttempt "refund:order" "Native" 0 (planFeeLimit plan) "broadcast_intent" (Just 1) Nothing wire
              family=[record firstWire,record childWire]
              points=map nativeOutpoint $ nativeInputs tx
              tip=T.replicate 64 "b"; anchor=if planDepth plan==1 then tip else T.replicate 64 "c"
              position=object ["hash" .= tip,"height" .= (16010::Int)]
          locks<-newIORef []
          mutations<-newIORef (0::Int)
          let transport mode wallet method args=case (method,args) of
                ("gettransaction",[String txid,Bool False,Bool True]) | txid `elem` map signedId [firstWire,childWire]->
                  if mode==0 then reject "rpc_error_-5" else do
                    let signed=if txid==signedId firstWire then original else child
                        winner=if mode `elem` [1,4] then signedId firstWire else signedId childWire
                        confirmations=if mode<3 then 0 else if txid==winner then planDepth plan else negate(planDepth plan)
                    decodedTx<-call False "decoderawtransaction" [toJSON $ signedNativeBytes signed]
                    pure $ object (["txid" .= txid,"hex" .= signedNativeBytes signed,"decoded" .= decodedTx
                      ,"fee" .= Number (negate(fromIntegral $ units $ signedNativeFee signed)/100000000)
                      ,"confirmations" .= confirmations,"lastprocessedblock" .= position
                      ,"walletconflicts" .= (if confirmations<0 then [winner] else [])]
                      <> if confirmations>0 then ["blockhash" .= anchor] else [])
                ("gettxspendingprevout",_)->pure $ toJSON
                  [object (["txid" .= outpointTxid point,"vout" .= outpointVout point]
                    <> if mode `elem` [1,2] then ["spendingtxid" .= (if mode==1 then signedId firstWire else signedId childWire)] else [])|point<-points]
                ("getblockheader",[String hash]) | hash==anchor->pure $ object
                  ["hash" .= anchor,"height" .= (16011-planDepth plan),"confirmations" .= planDepth plan]
                ("getblockhash",[height]) | mode>=3 && height==toJSON (16011-planDepth plan)->pure $ String anchor
                ("gettxout",[txid,index,Bool True])->call wallet method [txid,index,Bool False]
                ("listlockunspent",[])->toJSON <$> readIORef locks
                ("lockunspent",[Bool False,requested])->do
                  require (requested==toJSON points && not(null points)) "unexpected_family_locks"
                  writeIORef locks points
                  modifyIORef' mutations (+1)
                  pure (Bool True)
                _->call wallet method args
          results<-forM [0..4::Int] $ \mode->do
            writeIORef locks []
            writeIORef mutations 0
            let rpc=transport mode
            (members,view)<-verifyNativeFamily rpc c config prepared family
            selected<-activeNativeMember members view
            first<-restoreNativeWork rpc c config (Just $ NativeLockWork prepared False family)
            second<-restoreNativeWork rpc c config (Just $ NativeLockWork prepared False family)
            count<-readIORef mutations
            observation<-case selected of
              Nothing->pure PaymentUnseen
              Just (_,signed,depth,value)->nativeConfirmation rpc signed depth value
            let expected=if mode==0 then Nothing else Just(if mode `elem` [1,4] then signedId firstWire else signedId childWire)
                actual=fmap (\(saved,_,_,_)->signedId $ recordedSigned saved) selected
                correctCost=case observation of
                  PaymentConfirmed costs _->W.networkFee costs==(if mode==4 then signedNativeFee original else signedNativeFee child)
                  PaymentUnseen->mode==0
                  PaymentWaiting->mode `elem` [1,2]
                  _->False
            pure (actual==expected && correctCost && second==0
              && if mode==0 then first==length points && count==1 else first==0 && count==0)
          unauthorized<-rejects "unrecorded_broadcast_observed" (verifyNativeFamily (transport 2) c config prepared
            [head family,(last family) {recordedState="signed",recordedSequence=Nothing}])
          methods<-map fst <$> readIORef calls
          pure (and results && unauthorized && all (`notElem` methods) ["walletprocesspsbt","sendrawtransaction","getnewaddress","getrawchangeaddress"])
    , check "replacement fees consume only change within the saved ceiling" $ forAll (chooseInteger (283,1000)) $ \nextFee ->
        case replacementOutputs boundSigned (amt nextFee) of
          Left _->False
          Right outputs->
            let nextTx=tx {nativeTxid=T.replicate 64 "a",nativeOutputs=outputs}
                next=boundSigned {signedNativeTransaction=nextTx,signedNativeFee=amt nextFee}
                nextDraft=draft {draftTransaction=nextTx,draftFee=amt nextFee}
                recipients=filter ((==planRecipientScript plan).nativeOutputScript)
            in validateNativeFamily [boundSigned,next]==Right ()
              && validateNativeReplacementDraft [boundSigned] (amt nextFee) nextDraft==Right ()
              && recipients outputs==recipients(nativeOutputs tx)
              && sum(map (toInteger.units.nativeOutputAmount) outputs)+nextFee
                ==sum(map (toInteger.units.nativeOutputAmount) (nativeOutputs tx))+toInteger(units fee)
    , check "replacement rejects equal or excessive fees and duplicate families" $ once $
        replacementOutputs boundSigned fee==Left "native_replacement_fee_bounds"
        && replacementOutputs boundSigned (amt 1001)==Left "native_replacement_fee_bounds"
        && validateNativeFamily []==Left "native_replacement_family_bounds"
        && validateNativeFamily [boundSigned,boundSigned]==Left "native_replacement_duplicate_member"
        && validateNativeFamily (replicate 9 boundSigned)==Left "native_replacement_family_bounds"
    , check "replacement never changes input sequence recipient or replay policy" $ once $
        case replacementOutputs boundSigned (amt 300) of
          Left _->False
          Right outputs->
            let nextTx=tx {nativeTxid=T.replicate 64 "a",nativeOutputs=outputs}
                bad=[nextTx {nativeLocktime=1},nextTx {nativeVersion=1},
                  nextTx {nativeInputs=map (\i->i {nativeSequence=0}) (nativeInputs tx)},
                  nextTx {nativeOutputs=reverse outputs}]
                validate changed=validateNativeReplacementDraft [boundSigned] (amt 300)
                  draft {draftTransaction=changed,draftFee=amt 300}
            in all (either (const True) (const False).validate) bad
    , check "native recipient and change mutations are rejected" $ forAll (elements alteredPlans) $ \p ->
        validate p previous fee tx==Left "native_output_mismatch"
    , check "native fee is recomputed from actual prevouts" $ forAll (chooseInteger (1,100000)) $ \delta ->
        validate plan previous (amt $ 282+delta) tx==Left "native_fee_mismatch" &&
        validate plan (map (\p->p {prevoutAmount=amt $ toInteger(units $ prevoutAmount p)+delta}) previous) fee tx==Left "native_fee_mismatch"
    , check "valid native fees respect the saved ceiling with a distinct budget error" $ forAll (chooseInteger (1,281)) $ \delta ->
        let capped n=validate plan {planFeeLimit=amt n} previous fee tx
        in capped (282-delta)==Left "native_fee_budget_exceeded" && capped 282==Right () && capped (282+delta)==Right ()
    , check "native malformed saved transaction is rejected before any wallet RPC" $ forAll (elements badTransactions) $ \t -> ioProperty $ do
        result <- try (signNativeDraft (\_ _ _->fail "unexpected wallet RPC") plan draft {draftTransaction=t})
        pure $ case result of Left (BridgeError _)->True; Right _->False
    , check "native confirmations and coinbase maturity are mandatory" $ once $
        validate plan (map (\p->p {prevoutDepth=0}) previous) fee tx==Left "native_input_not_confirmed" &&
        validate plan (map (\p->p {prevoutDepth=100,prevoutCoinbase=True}) previous) fee tx==Left "native_input_not_confirmed" &&
        validate plan (map (\p->p {prevoutDepth=101,prevoutCoinbase=True}) previous) fee tx==Right ()
    , check "native replay policy separates Signet from both ECX profiles" $ forAll (elements [ECXBetanetDevnet,CanonicalBeta]) $ \profile ->
        valid tx {nativeLocktime=499999999}==Left "native_replay_policy_mismatch" &&
        validate plan {planProfile=profile} previous fee tx==Left "native_replay_policy_mismatch" &&
        validate plan {planProfile=profile} previous fee tx {nativeLocktime=499999999}==Right ()
    , check "native PSBT mismatch refuses signing" $ once $ ioProperty $ do
        calls <- newIORef ([]::[Text])
        let call _ method _=modifyIORef' calls (<>[method]) >> pure (object ["tx" .= changedVersion decoded])
        refused <- rejects "native_psbt_changed" (signNativeDraft call plan draft)
        methods <- readIORef calls
        pure (refused && methods==["decodepsbt"])
    , check "native empty or oversized PSBT refuses all RPC" $ forAll (elements ["",T.replicate 100001 "a"]) $ \psbt -> ioProperty $
        rejects "invalid_native_psbt" (signNativeDraft (\_ _ _->fail "unexpected wallet RPC") plan draft {draftPsbt=psbt})
    , check "durable native lock recovery is idempotent and cannot sign send or allocate" $ once $ ioProperty $ do
        let work=Just $ NativeLockWork prepared False []
        ((first,second),methods)<-contract (\_ v->pure v) $ \call->do
          first<-restoreNativeWork call recoverySettings config work
          second<-restoreNativeWork call recoverySettings config work
          pure (first,second)
        earned<-either reject pure (earnedFees "revenue" Native $ planAmount plan)
        outgoingFee<-either reject pure (payment "fee:revenue" earned $ planRecipient plan)
        (feeLocks,_)<-contract (\_ v->pure v) $ \call->restoreNativeWork call recoverySettings config
          (Just $ NativeLockWork prepared {preparedView=PaymentView outgoingFee terms PaymentPaying} False [])
        pure (first==length(nativeInputs tx) && second==0 && feeLocks==first
          && length(filter (=="lockunspent") methods)==1
          && all (`notElem` methods) ["walletprocesspsbt","sendrawtransaction","getrawchangeaddress","getnewaddress"])
    , check "undrafted and cancelling native work verifies locks without restoring them" $ once $ ioProperty $ do
        (empty,emptyCalls)<-contract (\_ v->pure v) $ \call->restoreNativeWork call recoverySettings config Nothing
        (undrafted,undraftedCalls)<-contract (\_ v->pure v) $ \call->restoreNativeWork call recoverySettings config
          (Just $ NativeLockWork prepared {preparedDraft=Nothing} False [])
        (cancelled,cancelCalls)<-contract (\_ v->pure v) $ \call->restoreNativeWork call recoverySettings config
          (Just $ NativeLockWork prepared True [])
        pure (empty==0 && undrafted==0 && cancelled==0 && emptyCalls==["listlockunspent"]
          && undraftedCalls==emptyCalls && cancelCalls==["decodepsbt","listlockunspent"])
    , check "saved native attempts restore unseen or evicted inputs but not active spends" $ once $ ioProperty $ do
        (signed,_)<-contract (\_ v->pure v) $ \call->verifySigningReply call L2LSignetDevnet config prepared (NativeReply boundSigned)
        let recorded=RecordedAttempt "refund:order" "Native" 0 (planFeeLimit plan) "broadcast_intent" (Just 1) Nothing signed
            work attempt=Just $ NativeLockWork prepared False [attempt]
            missing method value=if method=="gettransaction" then reject "rpc_error_-5" else pure value
        (unseen,unseenCalls)<-contract missing $ \call->restoreNativeWork call recoverySettings config (work recorded {recordedState="signed",recordedSequence=Nothing})
        ((evicted,repeated),evictedCalls)<-contract unconfirmed $ \call->do
          first<-restoreNativeWork call recoverySettings config (work recorded)
          second<-restoreNativeWork call recoverySettings config (work recorded)
          pure (first,second)
        (confirmed,confirmedCalls)<-contract (\_ v->pure v) $ \call->restoreNativeWork call recoverySettings config (work recorded)
        (pending,pendingCalls)<-contract mempool $ \call->restoreNativeWork call recoverySettings config (work recorded)
        (unauthorized,_)<-contract (\_ v->pure v) $ \call->rejects "unrecorded_broadcast_observed"
          (restoreNativeWork call recoverySettings config $ work recorded {recordedState="signed",recordedSequence=Nothing})
        (changed,_)<-contract (\_ v->pure v) $ \call->rejects "native_lock_work_changed"
          (restoreNativeWork call recoverySettings config $ work recorded {recordedGeneration=1})
        family<-rejects "native_replacement_duplicate_member" (restoreNativeWork (\_ _ _->fail "family reached RPC") recoverySettings config (Just $ NativeLockWork prepared False [recorded,recorded]))
        pure (unseen==length(nativeInputs tx) && "lockunspent" `elem` unseenCalls && confirmed==0 && pending==0
          && evicted==length(nativeInputs tx) && repeated==0 && length(filter (=="lockunspent") evictedCalls)==1
          && "getmempoolentry" `notElem` evictedCalls && "gettxout" `notElem` confirmedCalls
          && all (`notElem` (confirmedCalls<>pendingCalls)) ["lockunspent","walletprocesspsbt"]
          && all (`notElem` evictedCalls) ["walletprocesspsbt","sendrawtransaction"]
          && "getmempoolentry" `elem` pendingCalls && unauthorized && changed && family)
    , check "native recovery rejects changed PSBT fees and owned prevouts before locking" $ once $ ioProperty $ do
        let altered key method (Object fields) | method==key=pure $ Object $ KM.insert (if key=="decodepsbt" then "fee" else "value") (nativeNumber $ amt 1) fields
            altered _ _ value=pure value
            run change code=contract change $ \call->rejects code (restoreNativeWork call recoverySettings config (Just $ NativeLockWork prepared False []))
        (badFee,feeCalls)<-run (altered "decodepsbt") "native_psbt_changed"
        (badPrevious,previousCalls)<-run (altered "gettxout") "native_previous_output_changed"
        pure (badFee && badPrevious && all (`notElem` (feeCalls<>previousCalls)) ["lockunspent","walletprocesspsbt"])
    , check "cancellation derives exact saved native inputs without signing or unlocking" $ once $ ioProperty $ do
        ((points,cleanup),calls)<-contract (\_ v->pure v) $ \call->cancellationPlan call L2LSignetDevnet config prepared
        ((empty,_),emptyCalls)<-contract (\_ v->pure v) $ \call->cancellationPlan call L2LSignetDevnet config prepared {preparedDraft=Nothing}
        pure (points==map nativeOutpoint(nativeInputs tx) && not(T.null cleanup) && calls==["decodepsbt"] && null empty && null emptyCalls)
    , check "cancellation cleanup handles lost replies and never unlocks foreign or empty inputs" $ once $ ioProperty $ do
        let points=map nativeOutpoint(nativeInputs tx)
        locked<-newIORef points; mutations<-newIORef (0::Int); lost<-newIORef True
        let call _ method args=case (method,args) of
              ("listlockunspent",[])->toJSON <$> readIORef locked
              ("lockunspent",[Bool True,v])->case fromJSON v of
                Success ps | not(null ps) && ps==points->do
                  modifyIORef' locked (filter (`notElem` ps))
                  modifyIORef' mutations (+1)
                  unknown<-readIORef lost
                  if unknown then writeIORef lost False >> reject "rpc_transport_unknown_outcome" else pure (Bool True)
                _->fail "empty or foreign unlock"
              _->fail "unexpected cancellation RPC"
        unknown<-rejects "rpc_transport_unknown_outcome" (releaseNativeInputLocks call points)
        releaseNativeInputLocks call points
        releaseNativeInputLocks call []
        count<-readIORef mutations
        writeIORef locked [Outpoint (T.replicate 64 "a") 0]
        refused<-rejects "native_preparation_locks_require_review" (releaseNativeInputLocks call points)
        pure (unknown && refused && count==1)
    , check "native lock recovery never clears foreign locks or sends empty mutations" $ once $ ioProperty $ do
        let points=map nativeOutpoint (nativeInputs tx)
        locked <- newIORef ([]::[Outpoint]); mutations <- newIORef (0::Int)
        let call _ method args=case (method,args) of
              ("listlockunspent",[])->toJSON <$> readIORef locked
              ("lockunspent",[Bool False,v])->case fromJSON v of
                Success ps | not(null ps)->modifyIORef' locked (<>ps) >> modifyIORef' mutations (+1) >> pure (Bool True)
                _->fail "invalid lock mutation"
              _->fail "unexpected lock RPC"
        first <- restoreNativeInputLocks call points
        second <- restoreNativeInputLocks call points
        writeIORef locked [Outpoint (T.replicate 64 "a") 0]
        refused <- rejects "native_preparation_locks_require_review" (restoreNativeInputLocks call points)
        count <- readIORef mutations
        pure (first==length points && second==0 && count==1 && refused)
    ]
 where
  check name p=putStrLn name >> quickCheckWithResult stdArgs {maxSuccess=100} p
  amt n=either (error . T.unpack) id (amount n)
  -- Alter the actual daemon schema, retaining its input/output fields.
  changedVersion (Object fields)=Object $ KM.insert "version" (Number 1) fields
  changedVersion _=error "fixture object required"
  rejects code action=do
    result<-try action
    pure $ case result of Left(BridgeError actual)->actual==code; Right _->False

withNativeReplacementContract :: (NativeSettings -> NativeSigned -> NativeDraft -> NativeRPC -> IORef [(Text,[Value])] -> IO a) -> IO a
withNativeReplacementContract action=do
  captured<-getDataFileName "test/fixtures/native-signet-payment.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  replacement<-getDataFileName "test/fixtures/native-signet-replacement-draft.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  oldDecoded<-fieldValue "decoded" captured :: IO Value
  newDecoded<-fieldValue "decoded" replacement :: IO Value
  draft<-fieldValue "draft" replacement
  created<-fieldValue "createdPsbt" replacement :: IO Text
  plan0<-fieldValue "plan" captured
  prevouts<-fieldValue "previous" captured
  fee0<-fieldValue "fee" captured
  raw0<-fieldValue "raw" captured
  tx0<-either reject pure (decodeNativeTx oldDecoded)
  let original=NativeSigned raw0 tx0 plan0 prevouts fee0
  calls<-newIORef []
  let c=NativeSettings L2LSignetDevnet "http://127.0.0.1:1" "/unused" "offline-native-replacement" 16000
          "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
      custodyNativeTip=T.replicate 64 "b"
      equal a b=require (a==b) "offline_replacement_request_mismatch"
      plan=signedNativePlan original
      tx=signedNativeTransaction original
      position=object ["hash" .= custodyNativeTip,"height" .= (16010::Int)]
      call _ method params=do
        modifyIORef' calls (<>[(method,params)])
        case (method,params) of
          ("getblockchaininfo",[])->pure $ object ["chain" .= ("signet"::Text),"initialblockdownload" .= False
            ,"blocks" .= (16010::Int),"bestblockhash" .= custodyNativeTip,"signet_challenge" .= signetChallenge]
          ("getblockhash",[height]) | height==toJSON (nativeCheckpointHeight c)->pure $ toJSON $ nativeCheckpointHash c
          ("getblockhash",[Number 16010])->pure $ toJSON custodyNativeTip
          ("getconnectioncount",[])->pure $ toJSON (1::Int)
          ("getwalletinfo",[])->pure $ object ["walletname" .= nativeWallet c,"descriptors" .= True,"private_keys_enabled" .= True
            ,"external_signer" .= False,"scanning" .= False,"lastprocessedblock" .= position]
          ("decoderawtransaction",[raw]) | raw==toJSON (signedNativeBytes original)->pure oldDecoded
          ("getaddressinfo",[address]) | address==toJSON (planRecipient plan)->pure $ object ["ismine" .= False,"scriptPubKey" .= planRecipientScript plan]
          ("getaddressinfo",[address]) | address==toJSON (planChange plan)->pure $ object ["ismine" .= True,"scriptPubKey" .= planChangeScript plan]
          ("decodescript",[_])->pure $ object ["type" .= ("witness_v0_keyhash"::Text)]
          ("gettransaction",[txid,Bool False,Bool True]) | txid==toJSON (nativeTxid tx)->pure $ object
            ["txid" .= nativeTxid tx,"hex" .= signedNativeBytes original,"decoded" .= oldDecoded
            ,"fee" .= Number (negate(fromIntegral $ units $ signedNativeFee original)/100000000),"confirmations" .= (0::Int)
            ,"walletconflicts" .= ([]::[Text]),"lastprocessedblock" .= position]
          ("gettxout",[txid,index,Bool False])->case [p | p<-signedNativePrevouts original
              ,txid==toJSON (outpointTxid $ prevout p),index==toJSON (outpointVout $ prevout p)] of
            [p]->pure $ object ["bestblock" .= custodyNativeTip,"value" .= nativeNumber (prevoutAmount p)
              ,"confirmations" .= prevoutDepth p,"coinbase" .= prevoutCoinbase p
              ,"scriptPubKey" .= object ["hex" .= prevoutScript p,"address" .= ("offline-prevout-address"::Text)]]
            _->reject "unexpected_replacement_prevout"
          ("getaddressinfo",[String "offline-prevout-address"])->case signedNativePrevouts original of
            [p]->pure $ object ["ismine" .= True,"scriptPubKey" .= prevoutScript p]
            _->reject "unexpected_fixture_prevouts"
          ("gettxspendingprevout",[points])->do
            points `equal` toJSON (map nativeOutpoint $ nativeInputs tx)
            pure $ toJSON [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"spendingtxid" .= nativeTxid tx]
              | point<-map nativeOutpoint $ nativeInputs tx]
          ("getmempoolentry",[_])->pure $ object ["vsize" .= (140::Int)]
          ("walletprocesspsbt",[psbt,Bool True,String "ALL",Bool True]) | psbt==toJSON (draftPsbt draft)->pure $ object ["psbt" .= ("offline-signed"::Text),"complete" .= True]
          ("finalizepsbt",[String "offline-signed",Bool True])->pure $ object ["hex" .= ("00"::Text),"complete" .= True]
          ("decoderawtransaction",[String "00"])->fieldValue "tx" newDecoded
          ("testmempoolaccept",[bytes]) | bytes==toJSON ["00"::Text]->pure $ toJSON [object ["txid" .= nativeTxid(draftTransaction draft),"allowed" .= True,"fees" .= object ["base" .= nativeNumber(draftFee draft)]]]
          ("listlockunspent",[])->pure $ toJSON $ map nativeOutpoint $ nativeInputs tx
          ("createpsbt",[inputs,outputs,locktime,Bool False])->do
            inputs `equal` toJSON [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"sequence" .= nativeSequence input]
              | input<-nativeInputs tx,let point=nativeOutpoint input]
            locktime `equal` toJSON (nativeLocktime tx)
            outputs `equal` toJSON [object [Key.fromText (if nativeOutputScript o==planRecipientScript plan then planRecipient plan else planChange plan)
              .= nativeNumber (nativeOutputAmount o)] | o<-nativeOutputs $ draftTransaction draft]
            pure $ toJSON created
          ("walletprocesspsbt",[psbt,Bool False,String "ALL",Bool False,Bool False])->do
            psbt `equal` toJSON created
            pure $ object ["psbt" .= draftPsbt draft,"complete" .= False]
          ("decodepsbt",[psbt]) | psbt==toJSON (draftPsbt draft)->pure newDecoded
          _->reject $ "unexpected_replacement_rpc:"<>method
  action c original draft call calls
