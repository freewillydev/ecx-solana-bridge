{-# LANGUAGE OverloadedStrings #-}
-- Real public-Signet checks only. No key allocation, input locks, signer or send.
-- Stop this deployment's worker first; the ledger lock excludes other workers.
import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment
import Bridge.RPC
import Bridge.Types
import Control.Exception (try)
import Control.Monad (forM)
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import System.Environment (getArgs)

main :: IO ()
main=do
  args<-getArgs
  (path,target)<-case args of [p,a]->pure(p,T.pack a); _->fail "native-admission-probe CONFIG TESTER_NATIVE_ADDRESS"
  c<-loadConfig path
  require (profile c==L2LSignetDevnet && nativeWallet c=="ecx-bridge-test"
    && fingerprint c=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "dedicated_public_signet_test_only"
  withLedger (dbPath c) (fingerprint c) $ \ledger -> do
    pendingAttempts ledger >>= \xs->require (null xs) "pending_payment_must_resolve_first"
    pendingPreparations ledger >>= \xs->require (null xs) "pending_payment_must_resolve_first"
    manager<-newRpcManager
    identity<-nativeIdentity manager c
    network<-nativeCall manager c False "getnetworkinfo" []
    version<-fieldValue "version" network :: IO Int
    tester<-nativeCall manager c{nativeWallet="ecx-bridge-tester"} True "getaddressinfo" [toJSON target]
    fieldValue "ismine" tester >>= \owned->require owned "dedicated_tester_address_required"
    before<-walletState manager c
    coins<-nativeCall manager c True "listunspent" [toJSON (1::Int),toJSON (9999999::Int),toJSON ([]::[Text]),Bool False,object ["maximumCount" .= (1::Int)]] >>= parseValue parseJSON :: IO [Value]
    ownedAddress<-case coins of [coin]->fieldValue "address" coin; _->reject "native_admission_funds_unavailable"
    calls<-newIORef ([]::[Text])
    let call wallet method params=do
          require (method `elem` ["getaddressinfo","decodescript","listunspent","listlockunspent","walletcreatefundedpsbt","decodepsbt","gettxout"]) "unexpected_admission_rpc"
          modifyIORef' calls (<>[method])
          nativeCall manager c wallet method params
        amt n=either (error . T.unpack) id (amount n)
        owner="HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg"
        wrap=OrderRequest NativeToWrapped (amt 10000) owner target Nothing "admission-wrap"
        redeem=OrderRequest WrappedToNative (amt 10000) target owner (Just owner) "admission-redeem"
        cases=[("native-refund",c,wrap,Right $ amt 10000)
              ,("native-payout",c,redeem,Right $ amt 9900)
              ,("wpkh-294-boundary",c{minInput=amt 2},wrap{input=amt 294},Right $ amt 294)
              ,("wpkh-293-dust",c{minInput=amt 2},wrap{input=amt 293},Left "rpc_error_-4")
              ,("wrong-network",c,wrap{refund="1BoatSLRHtKNngkdXEeobR76b53LETtpyT"},Left "rpc_error_-5")
              ,("bridge-owned-refund",c,wrap{refund=ownedAddress},Left "bridge_owned_destination")]
    results<-forM cases $ \(name,configured,request,expected)->do
      result<-try (checkNativeQuoteWith call configured request) :: IO (Either BridgeError NativeQuoteCheck)
      case (expected,result) of
        (Right quantity,Right proof)->do
          require (checkedNativeAmount proof==quantity) "admission_probe_amount_mismatch"
          pure $ object ["case" .= (name::Text),"accepted" .= True,"evidence" .= proof]
        (Left code,Left (BridgeError actual))->do
          require (actual==code) "admission_probe_refusal_mismatch"
          pure $ object ["case" .= name,"accepted" .= False,"error" .= actual]
        _->reject "admission_probe_unexpected_result"
    after<-walletState manager c
    require (before==after) "admission_probe_changed_wallet_state"
    tip<-fieldValue "bestblockhash" identity :: IO Text
    recorded<-getCurrentTime
    methods<-readIORef calls
    LBS.putStrLn $ encode $ object ["recordedUtc" .= recorded,"network" .= ("public-l2l-signet"::Text)
      ,"daemonVersion" .= version,"chainTipAtStart" .= tip,"recipient" .= target,"checks" .= results
      ,"walletStateUnchanged" .= True,"walletState" .= before,"rpcMethods" .= methods
      ,"signerInvoked" .= False,"broadcast" .= False,"ordersCreated" .= (0::Int),"ledgerSchema" .= schemaVersion
      ,"scope" .= ("Actual unsigned funding on the existing node; low-value cases change only this probe's minimum input, not deployment policy. No order or payment was created."::Text)]
 where
  walletState manager c=do
    info<-nativeCall manager c True "getwalletinfo" []
    keys<-fieldValue "keypoolsize" info :: IO Int
    internal<-fieldValue "keypoolsize_hd_internal" info :: IO Int
    txs<-fieldValue "txcount" info :: IO Int
    locks<-nativeCall manager c True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
    require (null locks) "native_preparation_locks_require_review"
    pure $ object ["keypoolsize" .= keys,"keypoolsize_hd_internal" .= internal,"txcount" .= txs,"locks" .= locks]
