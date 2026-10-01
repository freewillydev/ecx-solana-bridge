{-# LANGUAGE OverloadedStrings #-}
-- Public Signet only. Reuses the earlier confirmed transaction fixture and
-- constructs unsigned PSBT data. Never signs, sends, locks or opens the ledger.
import Bridge.Config
import Bridge.Native
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.RPC
import Bridge.Types
import Control.Exception (try)
import Control.Monad (forM)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.IORef
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import System.Directory (doesPathExist)
import System.Environment (getArgs)

main :: IO ()
main=do
  args<-getArgs
  (path,target)<-case args of [p,t]->pure(p,t); _->fail "native-replacement-probe CONFIG NEW_FIXTURE_PATH"
  doesPathExist target >>= \exists->require (not exists) "fixture_already_exists"
  c<-loadConfig path
  require (profile c==L2LSignetDevnet && nativeWallet c=="ecx-bridge-test"
    && fingerprint c=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "dedicated_public_signet_test_only"
  fixture<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  plan<-fieldValue "plan" fixture
  previous<-fieldValue "previous" fixture
  oldFee<-fieldValue "fee" fixture
  oldTx<-fieldValue "decoded" fixture >>= either reject pure . decodeNativeTx
  raw<-fieldValue "raw" fixture
  let original=NativeSigned raw oldTx plan previous oldFee
  fee<-either reject pure $ amount (toInteger (units oldFee)+100)
  manager<-newRpcManager
  methods<-newIORef ([]::[Text])
  let call wallet method params=do
        require (method `elem` ["getblockchaininfo","getblockhash","getconnectioncount","getnetworkinfo","getbalances"
          ,"getwalletinfo","gettransaction","decoderawtransaction","getaddressinfo","decodescript","gettxout"
          ,"gettxspendingprevout","listlockunspent","createpsbt","walletprocesspsbt","decodepsbt"]) "unexpected_replacement_probe_rpc"
        if method=="walletprocesspsbt" then case params of
          [_,Bool False,String "ALL",Bool False,Bool False]->pure ()
          _->reject "replacement_probe_signing_forbidden"
         else pure ()
        modifyIORef' methods (<>[method])
        nativeCall manager c wallet method params
  identity<-nativeIdentityWith call c
  network<-call False "getnetworkinfo" []
  version<-fieldValue "version" network :: IO Int
  before<-walletState call
  saved<-call True "gettransaction" [toJSON $ nativeTxid oldTx,Bool False,Bool True]
  depth<-fieldValue "confirmations" saved :: IO Int
  require (depth>=planDepth plan) "probe_requires_already_confirmed_payment"
  refusal<-try (draftNativeReplacementWith call c [original] fee) :: IO (Either BridgeError NativeDraft)
  require (case refusal of Left (BridgeError "native_replacement_member_not_pending")->True; _->False) "replacement_probe_expected_refusal"
  -- Separate RPC-shape diagnostic, deliberately using already-spent real
  -- inputs. This unsigned candidate cannot pass the production pending guard.
  outputs<-either reject pure $ replacementOutputs original fee
  let inputs=[object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"sequence" .= nativeSequence input]
             | input<-nativeInputs oldTx,let point=nativeOutpoint input]
      destinations=[object [Key.fromText (if nativeOutputScript output==planRecipientScript plan then planRecipient plan else planChange plan)
        .= nativeNumber (nativeOutputAmount output)] | output<-outputs]
  created<-call False "createpsbt" [toJSON inputs,toJSON destinations,toJSON $ nativeLocktime oldTx,Bool False] >>= parseValue parseJSON :: IO Text
  updated<-call True "walletprocesspsbt" [toJSON created,Bool False,String "ALL",Bool False,Bool False]
  psbt<-fieldValue "psbt" updated
  complete<-fieldValue "complete" updated
  require (not complete) "replacement_probe_unexpected_signature"
  decoded<-call False "decodepsbt" [toJSON psbt]
  require (publicMetadata decoded) "replacement_probe_private_metadata"
  candidate<-fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
  actualFee<-fieldValue "fee" decoded >>= either reject pure . nativeAmount
  let draft=NativeDraft psbt candidate previous actualFee
  either reject pure $ validateNativeReplacementDraft [original] fee draft
  after<-walletState call
  require (before==after) "replacement_probe_changed_wallet_state"
  recorded<-getCurrentTime
  calls<-readIORef methods
  tip<-fieldValue "bestblockhash" identity :: IO Text
  let scope="Unsigned RPC construction and confirmed-member refusal on the actual public L2L Signet node. The input payment was already confirmed. This is not live fee-replacement, mempool acceptance, signing, family settlement or recovery acceptance."::Text
  LBS.writeFile target $ encode $ object ["provenance" .= scope,"originalTransaction" .= nativeTxid oldTx
    ,"draft" .= draft,"decoded" .= decoded,"createdPsbt" .= created]
  LBS.putStrLn $ encode $ object ["recordedUtc" .= recorded,"network" .= ("public-l2l-signet"::Text)
    ,"daemonVersion" .= version,"chainTip" .= tip,"originalTransaction" .= nativeTxid oldTx,"unsignedTransaction" .= nativeTxid candidate
    ,"originalFee" .= oldFee,"newFee" .= fee,"recipientAmount" .= planAmount plan
    ,"retainedEveryInput" .= True,"walletStateUnchanged" .= True,"rpcMethods" .= calls
    ,"confirmedMemberRefusal" .= ("native_replacement_member_not_pending"::Text)
    ,"signerInvoked" .= False,"broadcast" .= False,"ledgerOpened" .= False,"scope" .= scope]
 where
  walletState call=do
    info<-call True "getwalletinfo" []
    fields<-forM ["txcount","keypoolsize","keypoolsize_hd_internal"] (\key->fieldValue key info) :: IO [Int]
    locks<-call True "listlockunspent" []
    balances<-call True "getbalances" []
    pure (fields,locks,balances)
  publicMetadata (Object fields)=all allowed (KM.toList fields)
  publicMetadata (Array values)=all publicMetadata values
  publicMetadata _=True
  allowed (key,value)
    | key `elem` ["global_xpubs","bip32_derivs","taproot_bip32_derivs","partial_signatures","final_scriptSig","final_scriptwitness","taproot_key_path_sig","taproot_script_path_sigs"] = value==Null || value==object [] || value==toJSON ([]::[Value])
    | otherwise=publicMetadata value
