{-# LANGUAGE OverloadedStrings #-}
-- One-time classification of this deployment's already completed public-test
-- setup and adapter probes. Re-running verifies the same immutable decisions.
-- No signer, send, order creation or resume operation is invoked here.
import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment
import Bridge.Observer
import Bridge.RPC
import Bridge.Solana
import Bridge.SolanaDeposit
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Types
import Control.Monad (forM,forM_)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import System.Environment (getArgs)

readJSON :: FilePath -> IO Value
readJSON path=BS.readFile path >>= either fail pure . eitherDecodeStrict'
quantity :: Integer -> IO Amount
quantity=either reject pure . amount

main :: IO ()
main=do
  args<-getArgs
  path<-case args of [p]->pure p; _->fail "run from repository root: reconcile-test-treasury CONFIG"
  c<-loadConfig path
  require (profile c==L2LSignetDevnet && fingerprint c=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "different_public_test_deployment"
  withLedger (dbPath c) (fingerprint c) $ \l -> do
    orders<-ledgerAction l $ \db -> query_ db "SELECT COUNT(*) FROM orders" :: IO [Only Int]
    require (orders==[Only 0]) "bootstrap_before_customer_orders_only"
    manager<-newRpcManager
    _<-observeOnce manager c l
    _<-nativeIdentity manager c
    _<-solanaIdentity manager c
    let native=nativeCall manager c
        faucet="d42c6d553922668bd9176bf52b0e1b446751da7dd6d818cb97e48581856453fe"::Text
    receipt<-native True "gettransaction" [toJSON faucet,Bool False,Bool True]
    confirmations<-fieldValue "confirmations" receipt :: IO Int
    require (confirmations>=nativeConfirmations c) "native_funding_not_confirmed"
    receiptAmount<-fieldValue "amount" receipt >>= either reject pure . nativeAmount
    require (units receiptAmount==2000000) "unexpected_native_funding"

    fixture<-readJSON "test/fixtures/native-signet-payment.json"
    plan<-fieldValue "plan" fixture
    previous<-fieldValue "previous" fixture
    expectedFee<-fieldValue "fee" fixture
    recorded<-fieldValue "decoded" fixture >>= either reject pure . decodeNativeTx
    paid<-native True "gettransaction" [toJSON (nativeTxid recorded),Bool False,Bool True]
    actual<-fieldValue "decoded" paid >>= either reject pure . decodeNativeTx
    signedBytes<-fieldValue "hex" paid :: IO Text
    originalBytes<-fieldValue "raw" fixture
    require (signedBytes==originalBytes && actual==recorded) "native_probe_bytes_changed"
    paidDepth<-fieldValue "confirmations" paid :: IO Int
    require (paidDepth>=nativeConfirmations c) "native_probe_not_confirmed"
    fee<-fieldValue "fee" paid >>= either reject pure . nativeAmount . abs
    require (fee==expectedFee) "native_probe_fee_changed"
    either reject pure (validateNativeTx plan previous fee actual)

    setup<-readJSON "docs/evidence/devnet-setup.json"
    setupSig<-fieldValue "manifest" setup >>= fieldValue "setupSignature"
    require (solanaHistoryStart c==Just setupSig && solanaOperatingHistoryStart c==Just setupSig) "wrong_setup_origin"
    setupProof<-finalizedTransaction manager c setupSig
    tokens<-either reject pure (custodyEffect setupSig (mint c) (custodyAta c) (custodyOwner c) setupProof)
    sol<-either reject pure (lamportEffect setupSig (custodyOwner c) setupProof)
    require (not (effectFailed tokens) && effectDelta tokens==100000000000
      && not (lamportFailed sol) && lamportDelta sol==5000000) "unexpected_setup_funding"
    payouts<-forM ["existing","new"] $ \kind -> do
      evidence<-readJSON ("docs/evidence/solana-devnet-"<>kind<>"-payment.json")
      signed<-fieldValue "signed" evidence
      sig<-maybe (reject "missing_probe_signature") pure (replySignature $ signedSolanaReply signed)
      proof<-finalizedTransaction manager c sig
      outcome<-either reject pure (verifySolanaOutcome c signed proof)
      require (outcomeSucceeded outcome && units (solPlanAmount $ signedSolanaPlan signed)==3) "unexpected_solana_probe"
      pure (sig,object ["signature" .= sig,"outcome" .= outcome,"signed" .= signed])

    nativeFloat<-quantity 1850000
    nativeFees<-quantity 150000
    tokenFloat<-quantity 100000000000
    solFees<-quantity 5000000
    let claim txid=object ["operatorClaim" .= ("dedicated public-test treasury"::Text),"fundingTransaction" .= txid]
    allocateTreasuryReceipt l ("native:"<>faucet<>":1") [("float",nativeFloat),("operating",nativeFees)] (claim faucet)
    allocateTreasuryReceipt l ("solana:"<>setupSig) [("float",tokenFloat)] (claim setupSig)
    allocateTreasuryReceipt l ("sol-operating:"<>setupSig) [("operating",solFees)] (claim setupSig)
    recordTreasurySpend l "Native" (nativeTxid actual)
      (object ["txid" .= nativeTxid actual,"plan" .= plan,"fee" .= fee,"raw" .= signedBytes])
    forM_ payouts $ \(sig,proof) -> do
      recordTreasurySpend l "Solana" sig proof
      recordTreasurySpend l "SolanaOperating" sig proof
    scan<-observeOnce manager c l
    reviews<-fieldValue "review" scan :: IO [Value]
    require (null reviews) "unresolved_chain_review"

    nativeBalances<-native True "getbalances" [] >>= fieldValue "mine"
    nativeUnits<-mapM (\key -> fieldValue key nativeBalances >>= either reject pure . nativeAmount)
      ["trusted","untrusted_pending","immature"]
    require (all ((==0) . units) (drop 1 nativeUnits)) "native_pending_balance_requires_reconciliation"
    accounts<-solanaCall manager c "getMultipleAccounts" [toJSON [custodyAta c,custodyOwner c]
      ,object ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]]
    values<-fieldValue "value" accounts
    (tokenValue,ownerAccount)<-case values of [a,b]->pure(a,b); _->reject "missing_custody_balances"
    tokenUnits<-either reject pure (inspectTokenAccount (mint c) (custodyOwner c) tokenValue)
    solUnits<-systemLamports ownerAccount
    rows<-ledgerAction l $ \db -> query_ db "SELECT asset,account,delta FROM postings" :: IO [(Text,Text,Int64)]
    let observed=[("Native",sum $ map (toInteger . units) nativeUnits),("Wrapped",toInteger $ units tokenUnits),("Sol",toInteger $ units solUnits)]
        balance asset=sum [toInteger n | (a,account,n)<-rows,a==asset,account/="external"]
    require (all (\(asset,n) -> balance asset==n) observed) "custody_ledger_balance_mismatch"
    audit<-auditExport l
    health<-readiness l
    require (not $ available health) "bootstrap_must_remain_paused"
    LBS.putStrLn $ encode $ object ["profile" .= profile c,"schema" .= schemaVersion,"accountingMatches" .= True
      ,"chainBalances" .= object [Key.fromText asset .= T.pack(show n) | (asset,n)<-observed]
      ,"audit" .= audit,"scanners" .= scan,"availability" .= health
      ,"scope" .= ("Known public-test treasury and prior probes only; not customer settlement or canonical readiness"::Text)]
