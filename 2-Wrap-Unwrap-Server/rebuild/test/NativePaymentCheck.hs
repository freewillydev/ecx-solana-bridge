-- Captured public L2L Signet payment plus offline mutation/RPC contracts.
-- The spent fixture input is not a spendable wallet or live acceptance evidence.
module NativePaymentCheck (checks) where

import Bridge.Domain (Asset(..),amount, units,refund,payment)
import Bridge.Payment
import Bridge.Store
import qualified Bridge.Wire as W
import qualified Bridge.SolanaHelper as H
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Bridge.Error
import Bridge.Native (nativeNumber)
import Bridge.NativePayment
import Bridge.RPC (fieldValue)
import Bridge.Wire (Profile(..))
import Control.Exception (try)
import Data.Aeson hiding (Result)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Paths_ecx_bridge_rebuild (getDataFileName)
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
  let validate p ps f t=validateNativeTx p ps f t
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
        let base _ method args=case (method,args) of
              ("listlockunspent",[])->toJSON <$> readIORef locks
              ("lockunspent",[Bool False,v])->case fromJSON v of
                Success ps | not(null ps)->modifyIORef' locks (<>ps) >> pure (Bool True)
                _->fail "invalid lock mutation"
              ("walletcreatefundedpsbt",[_,_,_,options,Bool True])->do
                locksInputs<-fieldValue "lockUnspents" options
                require (not locksInputs) "preparation_must_not_lock"
                pure $ object ["psbt" .= ("offline-psbt"::Text),"fee" .= nativeNumber fee,"changepos" .= (0::Int)]
              ("decodepsbt",_)->pure $ object ["tx" .= decoded,"fee" .= nativeNumber fee]
              ("gettxout",[String txid,vout,Bool True])->case [p | p<-previous,toJSON(outpointVout $ prevout p)==vout,outpointTxid(prevout p)==txid] of
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
      signed=NativeSigned raw tx plan previous fee
  sequence
    [ check "worker independently decodes returned native bytes against the durable draft" $ once $ ioProperty $ do
        (attempt,methods)<-contract (\_ v->pure v) $ \call->verifySigningReply call L2LSignetDevnet config prepared (NativeReply signed)
        (refused,_)<-contract (\method value->pure $ if method=="decoderawtransaction" then changedVersion value else value) $ \call->
          rejects "native_signed_bytes_mismatch" (verifySigningReply call L2LSignetDevnet config prepared $ NativeReply signed)
        pure (signedBytes attempt==raw && signedId attempt==nativeTxid tx && methods==["decoderawtransaction"] && refused)
    , check "signing boundary rejects mismatched profile reserved fee and returned fee" $ once $ ioProperty $ do
        wrongProfile<-rejects "saved_native_policy_mismatch" (resolveSigningPlan ECXBetanetDevnet config prepared)
        wrongFee<-rejects "saved_native_policy_mismatch" (resolveSigningPlan L2LSignetDevnet config prepared {preparedFee=amt 1})
        wrongTemplate<-rejects "native_signed_template_changed" $ verifySigningReply (\_ _ _->fail "unexpected RPC") L2LSignetDevnet config prepared (NativeReply signed {signedNativeFee=amt 1})
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
    , check "native recipient and change mutations are rejected" $ forAll (elements alteredPlans) $ \p ->
        validate p previous fee tx==Left "native_output_mismatch"
    , check "native fee is recomputed from actual prevouts" $ forAll (chooseInteger (1,100000)) $ \delta ->
        validate plan previous (amt $ 282+delta) tx==Left "native_fee_mismatch" &&
        validate plan (map (\p->p {prevoutAmount=amt $ toInteger(units $ prevoutAmount p)+delta}) previous) fee tx==Left "native_fee_mismatch"
    , check "native malformed saved transaction is rejected before any wallet RPC" $ forAll (elements badTransactions) $ \t -> ioProperty $ do
        result <- try (signNativeDraft (\_ _ _->fail "unexpected wallet RPC") plan draft {draftTransaction=t})
        pure $ case result of Left (BridgeError _)->True; Right _->False
    , check "native confirmations and coinbase maturity are mandatory" $ once $
        validate plan (map (\p->p {prevoutDepth=0}) previous) fee tx==Left "native_input_not_confirmed" &&
        validate plan (map (\p->p {prevoutDepth=100,prevoutCoinbase=True}) previous) fee tx==Left "native_input_not_confirmed" &&
        validate plan (map (\p->p {prevoutDepth=101,prevoutCoinbase=True}) previous) fee tx==Right ()
    , check "native replay policy separates Signet and ECX" $ once $
        valid tx {nativeLocktime=499999999}==Left "native_replay_policy_mismatch" &&
        validate plan {planProfile=ECXBetanetDevnet} previous fee tx==Left "native_replay_policy_mismatch" &&
        validate plan {planProfile=ECXBetanetDevnet} previous fee tx {nativeLocktime=499999999}==Right ()
    , check "native PSBT mismatch refuses signing" $ once $ ioProperty $ do
        calls <- newIORef ([]::[Text])
        let call _ method _=modifyIORef' calls (<>[method]) >> pure (object ["tx" .= changedVersion decoded])
        refused <- rejects "native_psbt_changed" (signNativeDraft call plan draft)
        methods <- readIORef calls
        pure (refused && methods==["decodepsbt"])
    , check "native empty or oversized PSBT refuses all RPC" $ forAll (elements ["",T.replicate 100001 "a"]) $ \psbt -> ioProperty $
        rejects "invalid_native_psbt" (signNativeDraft (\_ _ _->fail "unexpected wallet RPC") plan draft {draftPsbt=psbt})
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
