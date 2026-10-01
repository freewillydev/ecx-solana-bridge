{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- Read-only check of the family reader against one previously confirmed real
-- Signet member. Multiple members and changing winners remain separate gates.
import Bridge.Config
import Bridge.Native (nativeCall)
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Observer (epochSeconds)
import Bridge.RPC
import Bridge.Types
import Control.Exception (catch)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Text (Text)
import System.Environment (getArgs)
import System.Exit (die,exitFailure)

main :: IO ()
main=run `catch` (\(BridgeError code)->LBS.putStrLn (encode $ object ["error" .= code]) >> exitFailure)
 where
  run=do
    args<-getArgs
    path<-case args of [p]->pure p; _->die "Usage: native-family-readback CONFIG"
    c<-loadConfig path
    require (profile c==L2LSignetDevnet && nativeWallet c=="ecx-bridge-test"
      && fingerprint c=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "dedicated_public_test_required"
    fixture<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either (const $ reject "invalid_fixture") pure . eitherDecodeStrict'
    plan<-fieldValue "plan" fixture
    previous<-fieldValue "previous" fixture
    fee<-fieldValue "fee" fixture
    raw<-fieldValue "raw" fixture
    tx<-fieldValue "decoded" fixture >>= either reject pure . decodeNativeTx
    require (nativeTxid tx=="b2278e8dd0be7be001a5630545ddb73c83423ee1ee7dbd0327675e27f1642bd3") "known_payment_required"
    manager<-newRpcManager
    let call wallet method params=do
          require (method `elem` ["getbalances","getwalletinfo","getblockchaininfo","getblockhash","getblockheader"
            ,"getconnectioncount","decoderawtransaction","gettransaction","gettxspendingprevout"]) "read_only_probe"
          nativeCall manager c wallet method params
        walletSnapshot=do
          balance<-call True "getbalances" [] >>= fieldValue "mine" :: IO Value
          wallet<-call True "getwalletinfo" []
          count<-fieldValue "txcount" wallet :: IO Int
          external<-fieldValue "keypoolsize" wallet :: IO Int
          internal<-fieldValue "keypoolsize_hd_internal" wallet :: IO Int
          pure(balance,count,external,internal)
    before<-walletSnapshot
    view<-readNativeFamilyWith call c [NativeSigned raw tx plan previous fee]
    (txid,depth,value)<-case familyActive view of Just active->pure active; _->reject "confirmed_payment_missing"
    block<-fieldValue "blockhash" value :: IO Text
    require (txid==nativeTxid tx && depth>=planDepth plan && length (familyWallet view)==1) "confirmed_payment_changed"
    after<-walletSnapshot
    require (before==after) "readback_wallet_changed"
    at<-epochSeconds
    LBS.putStrLn $ encode $ object ["checkedAt" .= at,"network" .= ("public L2L Signet"::Text)
      ,"memberCount" .= (1::Int),"activeTransaction" .= txid,"confirmations" .= depth,"block" .= block
      ,"walletBalancesTransactionCountAndKeyPoolsUnchanged" .= True,"signedOrSent" .= False
      ,"limitations" .= ("One existing confirmed real payment verifies the live RPC contract. Multiple-member signing, replacement and winner changes are not established by this readback."::Text)]
