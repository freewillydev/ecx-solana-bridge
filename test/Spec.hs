{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import Bridge.Types
import Bridge.Config
import Bridge.Ledger
import Bridge.Reconciliation
import Bridge.Budget
import Bridge.SolanaMessage
import Bridge.SolanaDeposit
import Bridge.Solana (inspectTokenAccount)
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import qualified Data.Aeson.KeyMap as KM
import Bridge.Native (nativeAmount,nativeNumber,validateNativeRecipientWith)
import Bridge.NativePayment
import Bridge.Payment (prepareNativeWith,prepareSolanaWith)
import Bridge.Settlement
import Bridge.Deposit
import Bridge.Admission
import Bridge.Order
import Bridge.RPC
import Bridge.API
import Bridge.Worker
import Bridge.Backup
import Bridge.Observer
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently,withAsync)
import Control.Exception (bracket,try,SomeException)
import Control.Monad (forM_,when)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Base64 as B64
import Data.Int (Int64)
import Data.IORef
import Data.List (elemIndex)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.String (fromString)
import Data.Scientific (scientific)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Servant.API ((:<|>)(..))
import Servant.Client
import System.Directory
import System.FilePath ((</>),takeDirectory)
import System.Posix.Files (getFileStatus,fileMode)
import Data.Bits ((.&.))
import Test.Hspec hiding (before,after)
import Test.QuickCheck hiding ((.&.))

amt :: Integer -> Amount
amt n = either (error . T.unpack) id (amount n)
cap :: Text
cap=T.replicate 64 "a"
cfg :: FilePath -> Config
cfg dir = Config L2LSignetDevnet "unit-fixture" "http://127.0.0.1:29432" (dir</>"cookie") "fixture-wallet" 16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47" "https://api.devnet.solana.com" Nothing "Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM" "RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX" "11111111111111111111111111111111" (dir</>"private/ledger.sqlite") (dir</>"customer/api.sock") (dir</>"admin/api.sock") "/usr/bin/false" (dir</>"helper.json") (amt 2) (amt 1000000000000) 100 300 600 1 (amt 1000) (amt 10000) False Nothing (amt 0) Nothing (amt 100000) (amt 100000000)
req :: OrderRequest
req=OrderRequest NativeToWrapped (amt 100000) "fixture-solana-recipient" "fixture-native-refund" Nothing "retry-key"
withDir :: (FilePath -> IO a) -> IO a
withDir action=do
  base <- getTemporaryDirectory
  ident <- T.take 12 <$> randomId
  bracket (let p=base</>("ecx-test-"<>T.unpack ident) in createDirectory p >> pure p) removePathForcibly action
withFunded :: (Ledger -> Config -> IO a) -> IO a
withFunded action=withDir $ \dir -> let c=cfg dir in withLedger (dbPath c) (fingerprint c) $ \l -> do
  fundAllocation l "fixture-wrapped-float" Wrapped "float" (amt 1000000)
  fundAllocation l "fixture-native-float" Native "float" (amt 1000000)
  fundAllocation l "fixture-sol-fees" Sol "operating" (amt 100000)
  fundAllocation l "fixture-native-fees" Native "operating" (amt 100000)
  resumeAfterChecks l
  action l c
-- Offline fixture setup only. Runtime treasury allocation must move a verified
-- observed receipt; the application exposes no arbitrary-credit primitive.
fundAllocation :: Ledger -> Text -> Asset -> Text -> Amount -> IO ()
fundAllocation l ident asset account value=ledgerAction l $ \db -> do
  let event="fixture-fund:"<>ident
      name=T.pack(show asset)
  execute db "INSERT INTO events(id,description) VALUES(?,'offline test fixture funding')" (Only event)
  execute db "INSERT INTO postings(event_id,asset,account,delta) VALUES(?,?,?,?)" (event,name,account,units value)
  execute db "INSERT INTO postings(event_id,asset,account,delta) VALUES(?,?,'external',?)" (event,name,negate $ units value)
isError :: Text -> BridgeError -> Bool
isError expected (BridgeError actual)=expected==actual
fundOrder :: Ledger -> Config -> IO (OrderView,Obligation)
fundOrder l c=do
  o<-createOrder l c 100 cap req
  bindInstruction l (orderId o) "fixture-native-address"
  observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId o) Native (input req) "fixture-anchor" 1 True 100) "fixture-cursor"
  promoteDeposit l 110 "fixture-tx:0" `shouldReturn` True
  obligations<-readyObligations l
  case obligations of [ob]->pure(o,ob); _->error "expected single obligation"
-- Fixtures exercise ledger transitions only, never live network funding.
testAttempt :: Ledger -> Config -> Obligation -> Text -> Text -> Text -> Text -> Int64 -> Maybe Text -> IO ()
testAttempt l c ob chain txid bytes policy limit point = do
  beginPreparation l c ob chain limit "{\"fixture\":true}"
  storeAttempt l ob chain txid bytes policy limit point

nativeFixture :: IO (NativePlan,[NativePrevout],Amount,NativeTx)
nativeFixture = do
  value <- BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  plan <- fieldValue "plan" value
  previous <- fieldValue "previous" value
  fee <- fieldValue "fee" value
  decoded <- fieldValue "decoded" value >>= either (fail . T.unpack) pure . decodeNativeTx
  pure (plan,previous,fee,decoded)

-- The captured bytes supply economic validation; RPC responses below are
-- explicitly offline contracts, not evidence of a new chain transaction.
withNativeAdmission :: (Config -> NativePlan -> IORef [Text] -> NativeRPC -> IO a) -> IO a
withNativeAdmission action=do
  (plan,previous,fee,_)<-nativeFixture
  captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  decoded<-fieldValue "decoded" captured :: IO Value
  prev<-case previous of [p]->pure p; _->fail "expected one captured previous output"
  calls<-newIORef []
  let c=cfg "/unused-native-admission-fixture"
      call wallet method params=do
        modifyIORef' calls (<>[method])
        case (method,params) of
          ("getaddressinfo",[String address]) -> do
            wallet `shouldBe` True
            pure $ object ["ismine" .= (address/=planRecipient plan),"scriptPubKey" .=
              (if address==planRecipient plan then planRecipientScript plan
                else if address==planChange plan then planChangeScript plan else prevoutScript prev)]
          ("decodescript",[String script]) -> do
            wallet `shouldBe` False
            script `shouldBe` planRecipientScript plan
            pure $ object ["type" .= ("witness_v0_keyhash"::Text)]
          ("listunspent",[depth,_,_,unsafe,options]) -> do
            wallet `shouldBe` True
            depth `shouldBe` toJSON (nativeConfirmations c)
            unsafe `shouldBe` Bool False
            fieldValue "maximumCount" options `shouldReturn` (100::Int)
            pure $ toJSON [object ["address" .= planChange plan,"confirmations" .= (1000::Int),"safe" .= True,"spendable" .= True,"solvable" .= True]]
          ("listlockunspent",_) -> pure $ toJSON ([]::[Outpoint])
          ("walletcreatefundedpsbt",[_,outputs,locktime,options,_]) -> do
            fieldValue "lockUnspents" options `shouldReturn` False
            fieldValue "replaceable" options `shouldReturn` False
            fieldValue "include_unsafe" options `shouldReturn` False
            fieldValue "changeAddress" options `shouldReturn` planChange plan
            fieldValue "minconf" options `shouldReturn` nativeConfirmations c
            locktime `shouldBe` toJSON (0::Int)
            outputs `shouldBe` toJSON [object [fromString (T.unpack $ planRecipient plan) .= nativeNumber (planAmount plan)]]
            pure $ object ["psbt" .= ("unsigned-admission-fixture"::Text),"fee" .= nativeNumber fee,"changepos" .= (0::Int)]
          ("decodepsbt",_) -> pure $ object ["tx" .= decoded,"fee" .= nativeNumber fee]
          ("gettxout",_) -> pure $ object ["value" .= nativeNumber (prevoutAmount prev),"confirmations" .= (1000::Int),"coinbase" .= False
            ,"scriptPubKey" .= object ["hex" .= prevoutScript prev,"address" .= ("fixture-prevout"::Text)]]
          _ -> expectationFailure ("unexpected native admission RPC: "<>T.unpack method) >> pure Null
  action c plan calls call

main :: IO ()
main=hspec $ do
  describe "exact amounts" $ do
    it "rejects floats, exponents, leading zeros, signs, overflow and extra precision" $ do
      forM_ ["", "01", "-1", "+1", "1e8", "1.0", "9223372036854775808"] $ \s -> parseUnits s `shouldSatisfy` either (const True) (const False)
      forM_ ["1e3",".5","01.2","0.000000001","-0.1","1."] $ \s -> parseCoins s `shouldSatisfy` either (const True) (const False)
      (eitherDecodeStrict' "3"::Either String Amount) `shouldSatisfy` either (const True) (const False)
    it "preserves one and three atomic units" $ do
      parseCoins "0.00000001" `shouldBe` Right (amt 1)
      parseCoins "0.00000003" `shouldBe` Right (amt 3)
      nativeAmount (scientific 3 (-8)) `shouldBe` Right (amt 3)
      nativeAmount (scientific 1 (-1000000000)) `shouldBe` Left "native_amount_out_of_range"
    it "conserves principal and bounds upward rounding in both directions" $ property $ forAll (chooseInteger (1000,1000000000000)) $ \n -> all (valid n) [NativeToWrapped,WrappedToNative]
    it "never quotes an input consumed entirely by its fee" $ makeQuote NativeToWrapped (amt 1) `shouldBe` Left "nonpositive_net"
  describe "durable order and inventory invariants" $ do
    it "recovers a lost create response and rejects changed destinations" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      createOrder l c 999 cap req `shouldReturn` o
      createOrder l c 100 cap req{recipient="changed"} `shouldThrow` isError "idempotency_conflict"
      readOrder l (T.replicate 64 "b") (orderId o) `shouldThrow` isError "order_not_found"
    it "snapshots confirmation policy for idempotent retries after configuration changes" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      nativeDepth (policy o) `shouldBe` 1
      same<-createOrder l c{nativeConfirmations=6} 100 cap req
      policy same `shouldBe` policy o
      fresh<-createOrder l c{nativeConfirmations=6} 100 cap req{idempotencyKey="new-policy"}
      nativeDepth (policy fresh) `shouldBe` 6
      maximumNativeDepth l 1 `shouldReturn` 6
    it "does not oversubscribe inventory under concurrent orders" $ withFunded $ \l c -> do
      let create i=try (createOrder l c 100 cap req{idempotencyKey=T.pack(show i),input=amt 100000}) :: IO (Either BridgeError OrderView)
      results<-mapConcurrently create [1..20::Int]
      length [o|Right o<-results] `shouldBe` 10
      remaining<-ledgerAction l $ \db -> freeInventory db Wrapped
      remaining `shouldBe` 2000
    it "deduplicates deposits and quoted obligations" $ withFunded $ \l c -> do
      (o,_)<-fundOrder l c
      observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId o) Native (input req) "fixture-anchor" 2 True 100) "fixture-cursor-2"
      promoteDeposit l 120 "fixture-tx:0" `shouldReturn` False
      length <$> readyObligations l `shouldReturn` 1
      ledgerAction l (\db -> query_ db "SELECT count(*) FROM events WHERE id='deposit:fixture-tx:0'" :: IO [Only Int]) `shouldReturn` [Only 1]
    it "expiry cannot release an eligible obligation's reservation" $ withFunded $ \l c -> do
      _<-fundOrder l c
      expireQuotes l 100000
      ledgerAction l (\db -> freeInventory db Wrapped) `shouldReturn` 900200
    it "expired unfunded quotes release capacity without erasing their order" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      expireQuotes l 100000
      status <$> readOrder l cap (orderId o) `shouldReturn` "ExpiredUnfunded"
      bindInstruction l (orderId o) "late-address" `shouldThrow` isError "order_no_longer_provisioning"
      ledgerAction l (\db -> freeInventory db Wrapped) `shouldReturn` 1000000
    it "holds partial and excess deposits for review" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      observeDeposit l (Deposit "partial:0" (Just $ orderId o) Native (amt 10) "fixture-anchor" 1 True 100) "cursor"
      promoteDeposit l 110 "partial:0" `shouldReturn` False
      readyObligations l `shouldReturn` []
      status <$> readOrder l cap (orderId o) `shouldReturn` "NeedsReview"
    it "rolls back a failed database action as one financial decision" $ withFunded $ \l _ -> do
      originalAudit<-auditExport l
      result<-try (ledgerAction l $ \db -> do
        execute_ db "INSERT INTO events(id,description) VALUES('rollback','test')"
        execute_ db "INSERT INTO postings(event_id,asset,account,delta) VALUES('rollback','Native','float',NULL)") :: IO (Either SomeException ())
      result `shouldSatisfy` either (const True) (const False)
      auditExport l `shouldReturn` originalAudit
  describe "quote allowances and rolling operating budgets" $ do
    it "reserves payout rent and refund costs before accepting a quote" $ withFunded $ \l c -> do
      o<-createOrder l c{maxSolAccountRent=amt 80000} 100 cap req
      ledgerAction l (\db->query_ db "SELECT kind,asset,amount,phase FROM operating_reservations ORDER BY kind" :: IO [(Text,Text,Int64,Text)])
        `shouldReturn` [("conversion","Sol",90000,"quote"),("refund","Native",1000,"quote")]
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 10000
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 99000
      createOrder l c{maxSolAccountRent=amt 80000} 100 cap req{idempotencyKey="no-capacity"} `shouldThrow` isError "insufficient_fee_budget"
      ledgerAction l (\db->query_ db "SELECT id FROM orders" :: IO [Only Text]) `shouldReturn` [Only $ orderId o]
    it "refuses a quote without refund funds even when its payout is funded" $ withFunded $ \l c -> do
      createOrder l c{maxNativeFee=amt 100001} 100 cap req `shouldThrow` isError "insufficient_fee_budget"
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
      ledgerAction l (\db->query_ db "SELECT count(*) FROM orders" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "serializes concurrent admission against the shared daily cap" $ withFunded $ \l c -> do
      let limited=c{maxSolDailyCost=amt 25000}
          create i=try (createOrder l limited 100 cap req{idempotencyKey=T.pack(show i)}) :: IO (Either BridgeError OrderView)
      results<-mapConcurrently create [1..20::Int]
      length [o|Right o<-results] `shouldBe` 2
      [err|Left err<-results] `shouldBe` replicate 18 (BridgeError "operating_daily_limit")
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 80000
      ledgerAction l (\db->query_ db "SELECT count(*) FROM operating_reservations" :: IO [Only Int]) `shouldReturn` [Only 4]
    it "snapshots fee ceilings and never reserves twice on a repeated request" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      createOrder l c{maxNativeFee=amt 5,maxSolFee=amt 1,maxSolAccountRent=amt 999999} 100 cap req `shouldReturn` o
      ledgerAction l (\db->orderCostLimits db $ orderId o) `shouldReturn` CostLimits (amt 1000) (amt 10000) (amt 0)
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 90000
      result<-try (ledgerAction l $ \db->execute_ db "UPDATE order_cost_limits SET native_fee=5") :: IO (Either SomeException ())
      result `shouldSatisfy` either (const True) (const False)
    it "transfers the allowance once and charges only actual settled costs" $ withFunded $ \l c -> do
      let limited=c{maxSolFee=amt 9000,maxSolAccountRent=amt 1000,maxSolDailyCost=amt 10000}
      (_,ob)<-fundOrder l limited
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 90000
      testAttempt l limited ob "Solana" "budget-settlement" "bytes" "{}" 10000 Nothing
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 90000
      expireQuotes l 100000
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 99000
      _<-markBroadcastIntent l "budget-settlement"
      recordSettlement l "budget-settlement" (PaymentCosts (amt 5000) (amt 1000)) "proof"
      recordSettlement l "budget-settlement" (PaymentCosts (amt 5000) (amt 1000)) "proof"
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 94000
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 100000
      ledgerAction l (\db->query_ db "SELECT count(*) FROM operating_costs" :: IO [Only Int]) `shouldReturn` [Only 2]
      createOrder l limited 100 cap req{idempotencyKey="spent-budget"} `shouldThrow` isError "operating_daily_limit"
    it "keeps the separate refund allowance after a failed conversion" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "budget-failure" "bytes" "{}" 10000 Nothing
      _<-markBroadcastIntent l "budget-failure"
      recordFailedSolana l "budget-failure" 5000 "finalized-failure"
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 99000
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 95000
      refundOb<-createRefund l (obligationDeposit ob)
      testAttempt l c refundOb "Native" "budget-refund" "bytes" "{}" 1000 Nothing
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 99000
      obligationAmount refundOb `shouldBe` units (input req)
    it "releases only provisional costs on expiry and reacquires them for a late refund" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      expireQuotes l 100000
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 100000
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 100000
      observeDeposit l (Deposit "late-budget:0" (Just $ orderId o) Native (input req) "anchor" 1 True 100001) "cursor"
      ob<-createRefund l "late-budget:0"
      testAttempt l c ob "Native" "late-budget-refund" "bytes" "{}" 1000 Nothing
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 99000
    it "rolls back a failed transfer if the current spending cap was lowered" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      beginPreparation l c{maxSolDailyCost=amt 9999} ob "Solana" 10000 "policy" `shouldThrow` isError "operating_daily_limit"
      ledgerAction l (\db->query_ db "SELECT phase FROM operating_reservations WHERE kind='conversion'" :: IO [Only Text]) `shouldReturn` [Only "obligation"]
      pendingPreparations l `shouldReturn` []
      beginPreparation l c ob "Solana" 10000 "policy"
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 90000
    it "counts an extra refund on an already-paid order against queue capacity" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "queue-settlement" "bytes" "{}" 10000 Nothing
      _<-markBroadcastIntent l "queue-settlement"
      recordSettlement l "queue-settlement" (PaymentCosts (amt 5000) (amt 0)) "proof"
      observeDeposit l (Deposit "extra:0" (Just $ orderId o) Native (amt 5000) "anchor" 1 True 120) "cursor"
      _<-createRefund l "extra:0"
      status <$> readOrder l cap (orderId o) `shouldReturn` "Paid"
      createOrder l c{maxQueued=1} 120 cap req{idempotencyKey="queue-full"} `shouldThrow` isError "queue_full"
    it "cannot classify a treasury spend that consumes quoted operating funds" $ withFunded $ \l c -> do
      _<-createOrder l c 100 cap req
      commitScan l (ScanBatch "SolanaOperating" "origin" Nothing "quote-spend" 100 []
        [ChainEvent "quote-spend" "outgoing" "100" (object ["delta" .= ("-95000"::Text),"feeUnits" .= amt 5000])])
      recordTreasurySpend l "SolanaOperating" "quote-spend" (object ["fixture" .= True]) `shouldThrow` isError "treasury_spend_exceeds_free_allocation"
    it "counts fees once until the full rolling day ends, including future bookings" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "window-failure" "bytes" "{}" 10000 Nothing
      _<-markBroadcastIntent l "window-failure"
      recordFailedSolana l "window-failure" 5000 "finalized-failure"
      [Only booked]<-ledgerAction l (\db->query_ db "SELECT recorded_at FROM operating_costs" :: IO [Only Int64])
      ledgerAction l (\db->operatingSpent db "Sol" (booked-100)) `shouldReturn` 5000
      ledgerAction l (\db->operatingSpent db "Sol" (booked+86399)) `shouldReturn` 5000
      ledgerAction l (\db->operatingSpent db "Sol" (booked+86400)) `shouldReturn` 0
      tamper<-try (ledgerAction l $ \db->execute_ db "UPDATE operating_costs SET recorded_at=0") :: IO (Either SomeException ())
      tamper `shouldSatisfy` either (const True) (const False)
    it "retains holds and accounting time across restart and clock rollback" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        fundAllocation l "float" Wrapped "float" (amt 1000000)
        fundAllocation l "sol" Sol "operating" (amt 100000)
        fundAllocation l "native" Native "operating" (amt 100000)
        resumeAfterChecks l
        _<-createOrder l c 100 cap req
        -- Offline clock fault injection; no production clock/network is changed.
        ledgerAction l $ \db->execute_ db "UPDATE operating_clock SET last_time=4000000000"
        ledgerAction l operatingTime `shouldReturn` 4000000000
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        ledgerAction l operatingTime `shouldReturn` 4000000000
        ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 90000
        ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 99000
        available <$> readiness l `shouldReturn` False
  describe "atomic observer checkpoints" $ do
    it "rolls back an entire page and its cursor if any receipt conflicts" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      let deposit=Deposit "observed:0" (Just $ orderId o) Native (input req) "block-a" 1 True 100
      recordScan l "Native" Nothing "cursor-a" [deposit]
      let fresh=deposit{depositId="fresh:0"}
      recordScan l "Native" (Just "cursor-a") "cursor-b" [fresh,deposit{depositAmount=amt 1}]
        `shouldThrow` isError "conflicting_deposit_evidence"
      readCheckpoint l "Native" `shouldReturn` Just "cursor-a"
      ledgerAction l (\db->query_ db "SELECT id FROM deposits ORDER BY id" :: IO [Only Text]) `shouldReturn` [Only "observed:0"]
      recordScan l "Native" Nothing "old-cursor" [] `shouldThrow` isError "stale_scan_cursor"
    it "quarantines receipts without durable order bindings, including on replay" $ withFunded $ \l c -> do
      let unknown=Deposit "unrecognized:0" Nothing Native (amt 50000) "block-a" 1 True 100
      recordScan l "Native" Nothing "cursor-a" [unknown]
      recordScan l "Native" (Just "cursor-a") "cursor-b" [unknown]
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1000000
      ledgerAction l (\db->query_ db "SELECT delta FROM postings WHERE account='unallocated'" :: IO [Only Int64]) `shouldReturn` [Only 50000]
      promoteDeposit l 101 "unrecognized:0" `shouldReturn` False
      createRefund l "unrecognized:0" `shouldThrow` isError "refundable_deposit_not_found"
      o<-createOrder l c 100 cap req
      recordScan l "Native" (Just "cursor-b") "cursor-c" [unknown{depositOrder=Just $ orderId o}]
        `shouldThrow` isError "conflicting_deposit_evidence"
    it "requires each order's snapshotted confirmation depth before eligibility" $ withFunded $ \l c -> do
      o<-createOrder l c{nativeConfirmations=6} 100 cap req
      let deposit=Deposit "shallow:0" (Just $ orderId o) Native (input req) "block-a" 1 True 100
      recordScan l "Native" Nothing "cursor-a" [deposit] `shouldThrow` isError "deposit_confirmation_policy_mismatch"
      readCheckpoint l "Native" `shouldReturn` Nothing
      recordScan l "Native" Nothing "cursor-a" [deposit{depositConfirmations=6}]
      promoteDeposit l 110 "shallow:0" `shouldReturn` True
    it "commits immutable evidence, cursor and receipts together and preserves scan origin" $ withFunded $ \l _ -> do
      let receipt=Deposit "native:fixture:0" Nothing Native (amt 30) "block-a" 1 True 100
          event=ChainEvent "fixture" "unmatched_incoming" "block-a" (object ["amount" .= ("30"::Text)])
          batch=ScanBatch "Native" "origin" Nothing "cursor-a" 100 [receipt] [event]
      commitScan l batch
      commitScan l batch{scanPrevious=Just "cursor-a",scanNext="cursor-b",scanTime=200}
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM observation_evidence" :: IO [Only Int]) `shouldReturn` [Only 1]
      ledgerAction l (\db->query_ db "SELECT first_seen FROM deposits" :: IO [Only Int64]) `shouldReturn` [Only 100]
      commitScan l batch{scanPrevious=Just "cursor-b",scanOrigin="changed",scanNext="cursor-c"}
        `shouldThrow` isError "scan_origin_mismatch"
      readCheckpoint l "Native" `shouldReturn` Just "cursor-b"
      changed<-try (ledgerAction l $ \db->execute_ db "UPDATE observation_evidence SET evidence_json='tampered'") :: IO (Either SomeException ())
      changed `shouldSatisfy` either (const True) (const False)
    it "keeps scanner progress moving past unsupported activity while blocking spending" $ withFunded $ \l _ -> do
      let receipt=Deposit "solana:valid" Nothing Wrapped (amt 30) "123" 1 True 100
          unsupported=ChainEvent "unsupported-sig" "unsupported" "122" (object ["reason" .= ("unsupported_version"::Text)])
          validEvent=ChainEvent "valid-sig" "unmatched_incoming" "123" (object ["amount" .= ("30"::Text)])
      commitScan l (ScanBatch "Solana" "origin-sig" Nothing "valid-sig" 100 [receipt] [unsupported,validEvent])
      readCheckpoint l "Solana" `shouldReturn` Just "valid-sig"
      available <$> readiness l `shouldReturn` False
      resumeAfterChecks l `shouldThrow` isError "chain_observations_require_review"
      commitScan l (ScanBatch "Solana" "origin-sig" (Just "valid-sig") "newest-sig" 110 [] [])
      readCheckpoint l "Solana" `shouldReturn` Just "newest-sig"
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
    it "retains first-seen time while waiting for independent verification" $ withFunded $ \l c -> do
      let redeem=req{direction=WrappedToNative,recipient="native-recipient",refund="bound-owner",sourceOwner=Just "bound-owner"}
      o<-createOrder l c 100 cap redeem
      let deposit=Deposit "solana:pending" (Just $ orderId o) Wrapped (input redeem) "123" 1 False 390
          event=ChainEvent "pending" "awaiting_verifier" "123" Null
      commitScan l (ScanBatch "Solana" "origin" Nothing "pending" 391 [deposit] [event])
      pendingVerification l `shouldReturn` ["pending"]
      promoteDeposit l 391 "solana:pending" `shouldReturn` False
      commitScan l (ScanBatch "Solana" "origin" (Just "pending") "pending" 450 [deposit{depositEligible=True,depositSeenAt=450}] [event{chainEventKind="incoming"}])
      pendingVerification l `shouldReturn` []
      promoteDeposit l 450 "solana:pending" `shouldReturn` True
    it "records provider failures without moving a successful cursor or duplicating alerts" $ withFunded $ \l _ -> do
      commitScan l (ScanBatch "Native" "origin" Nothing "cursor-a" 100 [] [])
      recordScanFailure l "Native" 110 "rpc_transport_unknown_outcome"
      recordScanFailure l "Native" 120 "rpc_transport_unknown_outcome"
      readCheckpoint l "Native" `shouldReturn` Just "cursor-a"
      ledgerAction l (\db->query_ db "SELECT last_success,checked_at FROM scan_health" :: IO [(Int64,Int64)]) `shouldReturn` [(100,120)]
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM audit WHERE action='scanner_failure'" :: IO [Only Int]) `shouldReturn` [Only 1]
    it "quarantines a custody spend with no recorded intent" $ withFunded $ \l _ -> do
      commitScan l (ScanBatch "Native" "origin" Nothing "cursor" 100 [] [ChainEvent "unknown-spend" "outgoing" "block" Null])
      available <$> readiness l `shouldReturn` False
      resumeAfterChecks l `shouldThrow` isError "chain_observations_require_review"
  describe "Solana history pagination (transport contract tests)" $ do
    it "reads multiple pages through the exact saved anchor in durable order" $ do
      calls<-newIORef []
      let row n=SignatureInfo ("signature-"<>T.pack(show n)) n False
          fetch before=do
            modifyIORef' calls (<>[before])
            pure $ case before of
              Nothing -> map row [205,204..106]
              Just "signature-106" -> map row [105,104..6]
              Just "signature-6" -> map row [5,4..1]
              _ -> []
      found<-collectSignatures "signature-1" (Just "signature-3") fetch
      map historySlot found `shouldBe` [3..205]
      readIORef calls `shouldReturn` [Nothing,Just "signature-106",Just "signature-6"]
    it "rejects an empty/truncated history without the known anchor" $ do
      let fetch Nothing=pure [SignatureInfo "recent" 20 False]
          fetch _=pure []
      collectSignatures "known-origin" Nothing fetch `shouldThrow` isError "solana_history_gap"
    it "detects repeated provider pages instead of accepting a false cursor" $ do
      collectSignatures "known-origin" Nothing (const $ pure [SignatureInfo "repeated" 20 False])
        `shouldThrow` isError "solana_history_repeated_page"
    it "rejects a nonfinalized signature-history response" $ do
      let value=object ["signature" .= base58 (BS.replicate 64 1),"slot" .= (10::Int),"confirmationStatus" .= ("confirmed"::Text),"err" .= Null]
      (parseEither parseJSON value::Either String SignatureInfo) `shouldSatisfy` either (const True) (const False)
  describe "signed intent and settlement invariants" $ do
    it "reserves the destination and fee budget before signing, without allowing a refund race" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      beginPreparation l c ob "Solana" 6000 "fixture-policy" `shouldThrow` isError "preparation_conflict"
      length <$> pendingPreparations l `shouldReturn` 1
      pendingAttempts l `shouldReturn` []
      status <$> readOrder l cap (orderId o) `shouldReturn` "Preparing"
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(5000,False)]
      createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
      other<-createOrder l c 100 cap req{idempotencyKey="other-order"}
      observeDeposit l (Deposit "other-tx:0" (Just $ orderId other) Native (input req) "anchor" 1 True 100) "cursor"
      promoteDeposit l 110 "other-tx:0" `shouldReturn` True
      obs<-readyObligations l
      case obs of
        [otherOb]->beginPreparation l c otherOb "Solana" 5000 "other-policy" `shouldThrow` isError "destination_payment_unresolved"
        _->expectationFailure "expected one remaining ready obligation"
    it "retains an immutable unsigned draft after interruption and restart" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        fundAllocation l "float" Wrapped "float" (amt 1000000)
        fundAllocation l "fees" Sol "operating" (amt 10000)
        fundAllocation l "native-fees" Native "operating" (amt 1000)
        resumeAfterChecks l
        (_,ob)<-fundOrder l c
        beginPreparation l c ob "Solana" 5000 "fixture-policy"
        storeDraft l (obligationId ob) "fixture-unsigned-draft"
        storeDraft l (obligationId ob) "fixture-unsigned-draft"
        storeDraft l (obligationId ob) "different-draft" `shouldThrow` isError "preparation_draft_conflict"
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        map preparationDraft <$> pendingPreparations l `shouldReturn` [Just "fixture-unsigned-draft"]
        pendingAttempts l `shouldReturn` []
        available <$> readiness l `shouldReturn` False
        resumeAfterChecks l `shouldThrow` isError "unresolved_intents_require_review"
        createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
    it "cannot store signed bytes without a prior durable preparation" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      storeAttempt l ob "Solana" "signature" "bytes" "{}" 5000 Nothing `shouldThrow` isError "payment_not_prepared"
      pendingAttempts l `shouldReturn` []
    it "retains exact bytes across restart and starts paused" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        fundAllocation l "float" Wrapped "float" (amt 1000000)
        fundAllocation l "sol-fees" Sol "operating" (amt 10000)
        fundAllocation l "native-fees" Native "operating" (amt 1000)
        resumeAfterChecks l
        (_,ob)<-fundOrder l c
        testAttempt l c ob "Solana" "fixture-signature" "fixture-exact-bytes" "{}" 5000 Nothing
        _<-markBroadcastIntent l "fixture-signature"
        pure ()
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        available <$> readiness l `shouldReturn` False
        attempts<-pendingAttempts l
        map attemptBytes attempts `shouldBe` ["fixture-exact-bytes"]
        map attemptState attempts `shouldBe` ["broadcast_intent"]
        resumeAfterChecks l `shouldThrow` isError "unresolved_intents_require_review"
    it "cannot exceed the order's saved fee ceiling" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "fixture-signature" "bytes" "{}" 100001 Nothing `shouldThrow` isError "order_fee_limit_exceeded"
      pendingAttempts l `shouldReturn` []
    it "requires correct chain and database-bound obligation" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Native" "tx" "bytes" "{}" 1 Nothing `shouldThrow` isError "wrong_destination_chain"
      testAttempt l c ob{obligationRecipient="attacker"} "Solana" "tx" "bytes" "{}" 1 Nothing `shouldThrow` isError "obligation_mismatch"
    it "keeps earned fees out of available source float and settles once" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "fixture-signature" "bytes" "{}" 5000 Nothing
      _<-markBroadcastIntent l "fixture-signature"
      recordSettlement l "fixture-signature" (PaymentCosts (amt 5000) (amt 0)) "fixture-finalized-proof"
      recordSettlement l "fixture-signature" (PaymentCosts (amt 5000) (amt 0)) "fixture-finalized-proof"
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1099800
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 900200
      pendingAttempts l `shouldReturn` []
    it "cannot authorize a first send after loss of source eligibility" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "tx" "bytes" "{}" 5000 Nothing
      observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId o) Native (input req) "reorg" 0 False 100) "reorg-cursor"
      markBroadcastIntent l "tx" `shouldThrow` isError "attempt_not_sendable"
      length <$> pendingAttempts l `shouldReturn` 1
    it "rechecks backup coverage and source eligibility after a recorded broadcast intent" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "tx" "exact-bytes" "{}" 5000 Nothing
      authorizeRecordedSend l True "tx" `shouldThrow` isError "broadcast_intent_required"
      sequenceNumber<-markBroadcastIntent l "tx"
      authorizeRecordedSend l True "tx" `shouldThrow` isError "backup_pending"
      acknowledgeBackup l sequenceNumber "fixture-covered-snapshot"
      attemptBytes <$> authorizeRecordedSend l True "tx" `shouldReturn` "exact-bytes"
      observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId o) Native (input req) "reorg" 0 False 100) "reorg-cursor"
      markBroadcastIntent l "tx" `shouldReturn` sequenceNumber
      authorizeRecordedSend l True "tx" `shouldThrow` isError "source_not_eligible"
      length <$> pendingAttempts l `shouldReturn` 1
  describe "bounded rate-limit recovery (offline transport contracts)" $ do
    it "retries read-only requests with bounded waits and honors numeric Retry-After" $ do
      calls<-newIORef (0::Int)
      delays<-newIORef []
      let action=do
            n<-atomicModifyIORef' calls (\x->(x+1,x))
            pure $ if n==0 then Left (Just 5) else if n==1 then Left Nothing else Right True
      retryRateLimitedRead (\n->modifyIORef' delays (<>[n])) "getTransaction" action `shouldReturn` True
      readIORef calls `shouldReturn` 3
      readIORef delays `shouldReturn` [5000000,8000000]
    it "does not retry sends, wallet mutations, unknown methods, or indefinite throttling" $ do
      forM_ ["sendTransaction","sendrawtransaction","walletprocesspsbt","getnewaddress","futureMethod"] $ \method -> do
        calls<-newIORef (0::Int)
        let action=modifyIORef' calls (+1) >> pure (Left Nothing :: Either (Maybe Int) ())
        retryRateLimitedRead (const $ expectationFailure "unexpected wait") method action `shouldThrow` isError "rpc_rate_limited"
        readIORef calls `shouldReturn` 1
      calls<-newIORef (0::Int)
      retryRateLimitedRead (const $ pure ()) "getTransaction" (modifyIORef' calls (+1) >> pure (Left Nothing :: Either (Maybe Int) ()))
        `shouldThrow` isError "rpc_rate_limited"
      readIORef calls `shouldReturn` 3
      retryRateLimitedRead (const $ expectationFailure "unbounded wait") "getTransaction" (pure (Left (Just 60) :: Either (Maybe Int) ()))
        `shouldThrow` isError "rpc_rate_limited"
  describe "refund principal and failed transaction fees" $ do
    it "keeps a late Solana receipt out of conversion and refunds its full principal once" $ withFunded $ \l c -> do
      let redeem=req{direction=WrappedToNative,recipient="native-recipient",refund="bound-owner",sourceOwner=Just "bound-owner"}
      o<-createOrder l c 100 cap redeem
      let did="solana:late-receipt"
          receipt=Deposit did (Just $ orderId o) Wrapped (input redeem) "123" 1 True (deadline o+1)
      observeDeposit l receipt "cursor"
      promoteDeposit l (deadline o+2) did `shouldReturn` False
      status <$> readOrder l cap (orderId o) `shouldReturn` "NeedsReview"
      -- A later read cannot rewrite the immutable first observation time.
      observeDeposit l receipt{depositSeenAt=deadline o-1} "cursor"
      promoteDeposit l (deadline o+3) did `shouldReturn` False
      ob<-createRefund l did
      createRefund l did `shouldReturn` ob
      obligationAmount ob `shouldBe` units (input redeem)
      obligationRecipient ob `shouldBe` refund redeem
      testAttempt l c ob "Solana" "late-refund" "fixture-refund-bytes" "{}" 5000 Nothing
      _<-markBroadcastIntent l "late-refund"
      recordSettlement l "late-refund" (PaymentCosts (amt 5000) (amt 0)) "fixture-proof"
      recordSettlement l "late-refund" (PaymentCosts (amt 5000) (amt 0)) "fixture-proof"
      createRefund l did `shouldReturn` ob
      status <$> readOrder l cap (orderId o) `shouldReturn` "Refunded"
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1000000
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM postings WHERE account='earned'" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "separates rent from fees, caps their total, and refuses changed settlement evidence" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "costed-tx" "bytes" "{}" 10000 Nothing
      _<-markBroadcastIntent l "costed-tx"
      recordSettlement l "costed-tx" (PaymentCosts (amt 5000) (amt 5001)) "proof" `shouldThrow` isError "settlement_fee_or_evidence_invalid"
      recordSettlement l "costed-tx" (PaymentCosts (amt 5000) (amt 3000)) "proof"
      recordSettlement l "costed-tx" (PaymentCosts (amt 5000) (amt 3000)) "proof"
      recordSettlement l "costed-tx" (PaymentCosts (amt 5000) (amt 2999)) "proof" `shouldThrow` isError "settlement_evidence_conflict"
      ledgerAction l (\db->query_ db "SELECT event_id,delta FROM postings WHERE account='operating' AND event_id IN('network-fee:costed-tx','account-rent:costed-tx') ORDER BY event_id" :: IO [(Text,Int64)])
        `shouldReturn` [("account-rent:costed-tx",-3000),("network-fee:costed-tx",-5000)]
    it "refunds a confirmed partial deposit without consuming payout float" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      observeDeposit l (Deposit "partial:0" (Just $ orderId o) Native (amt 1000) "anchor" 1 True 100) "cursor"
      ob<-createRefund l "partial:0"
      obligationRecipient ob `shouldBe` refund req
      testAttempt l c ob "Native" "refund-tx" "fixture-refund-bytes" "{}" 100 Nothing
      _<-markBroadcastIntent l "refund-tx"
      recordSettlement l "refund-tx" (PaymentCosts (amt 100) (amt 0)) "fixture-refund-proof"
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1000000
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
      status <$> readOrder l cap (orderId o) `shouldReturn` "Refunded"
    it "will not refund a signed or possibly broadcast conversion" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "tx" "signed-bytes" "{}" 5000 Nothing
      createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
      _<-markBroadcastIntent l "tx"
      createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
    it "charges a failed Solana transaction fee and preserves full refundable principal" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "failed-tx" "bytes" "{}" 5000 Nothing
      _<-markBroadcastIntent l "failed-tx"
      recordFailedSolana l "failed-tx" 5000 "fixture-finalized-failure"
      recordFailedSolana l "failed-tx" 5000 "fixture-finalized-failure"
      refundOb<-createRefund l "fixture-tx:0"
      obligationAmount refundOb `shouldBe` units (input req)
      ledgerAction l (\db -> query_ db "SELECT delta FROM postings WHERE event_id='failed-fee:failed-tx' AND account='operating'" :: IO [Only Int64]) `shouldReturn` [Only (-5000)]
    it "does not promote a deposit first observed after its deposit deadline" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      observeDeposit l (Deposit "late:0" (Just $ orderId o) Native (input req) "anchor" 1 True 500) "cursor"
      promoteDeposit l 500 "late:0" `shouldReturn` False
  describe "verified treasury allocation and accounting" $ do
    it "moves an observed receipt exactly once instead of crediting the asset again" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        observeDeposit l (Deposit "treasury-receipt" Nothing Native (amt 1000) "fixture-block" 1 True 100) "cursor"
        let split=[("float",amt 900),("operating",amt 100)]
            proof=object ["operatorClaim" .= ("fixture-owned-funding"::Text)]
        allocateTreasuryReceipt l "treasury-receipt" split proof
        allocateTreasuryReceipt l "treasury-receipt" (reverse split) proof
        ledgerAction l (\db->freeInventory db Native) `shouldReturn` 900
        ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings WHERE account<>'external'" :: IO [Only Int64]) `shouldReturn` [Only 1000]
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` [Only 1]
        allocateTreasuryReceipt l "treasury-receipt" [("float",amt 1000)] proof `shouldThrow` isError "treasury_allocation_conflict"
    it "cannot allocate bound customer principal, unconfirmed receipts or an incorrect total" $ withFunded $ \l c -> do
      (o,_)<-fundOrder l c
      pause l "fixture-review"
      let proof=object ["operatorClaim" .= ("fixture"::Text)]
      allocateTreasuryReceipt l "fixture-tx:0" [("float",amt 100000)] proof `shouldThrow` isError "receipt_not_available_for_treasury"
      observeDeposit l (Deposit "unconfirmed" Nothing Native (amt 1000) "unconfirmed" 0 False 100) "cursor"
      allocateTreasuryReceipt l "unconfirmed" [("float",amt 1000)] proof `shouldThrow` isError "receipt_not_available_for_treasury"
      observeDeposit l (Deposit "unbound" Nothing Native (amt 1000) "fixture-block" 1 True 100) "cursor"
      allocateTreasuryReceipt l "unbound" [("float",amt 1001)] proof `shouldThrow` isError "treasury_allocation_amount_mismatch"
      status <$> readOrder l cap (orderId o) `shouldReturn` "Ready"
    it "separates SOL history from token history and restricts SOL to operating funds" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        let receipt=Deposit "sol-operating:fund" Nothing Sol (amt 10000) "100" 1 True 100
            event=ChainEvent "fund" "unmatched_incoming" "100" (object ["delta" .= ("10000"::Text)])
            batch=ScanBatch "SolanaOperating" "origin" Nothing "fund" 100 [receipt] [event]
            proof=object ["operatorClaim" .= ("fixture-SOL"::Text)]
        commitScan l batch
        readCheckpoint l "Solana" `shouldReturn` Nothing
        readCheckpoint l "SolanaOperating" `shouldReturn` Just "fund"
        allocateTreasuryReceipt l "sol-operating:fund" [("float",amt 10000)] proof `shouldThrow` isError "sol_reserved_for_operating"
        allocateTreasuryReceipt l "sol-operating:fund" [("operating",amt 10000)] proof
        commitScan l batch{scanPrevious=Just "fund"}
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM deposits" :: IO [Only Int]) `shouldReturn` [Only 1]
        commitScan l batch{scanChain="Solana",scanPrevious=Nothing} `shouldThrow` isError "scan_asset_mismatch"
    it "books a verified operator payment and fee once, preserving its review decision across scans" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        observeDeposit l (Deposit "capital" Nothing Native (amt 1000) "fixture-block" 1 True 100) "cursor"
        let proof=object ["verifiedOperatorPayment" .= ("fixture"::Text)]
            economic=object ["walletNetUnits" .= ("-100"::Text),"feeUnits" .= amt 2,"confirmations" .= (1::Int)]
            event=ChainEvent "operator-payment" "outgoing" "fixture-block" economic
            batch=ScanBatch "Native" "origin" (Just "cursor") "cursor" 101 [] [event]
        allocateTreasuryReceipt l "capital" [("float",amt 900),("operating",amt 100)] proof
        commitScan l batch
        recordTreasurySpend l "Native" "operator-payment" proof
        recordTreasurySpend l "Native" "operator-payment" proof
        ledgerAction l (\db->freeInventory db Native) `shouldReturn` 800
        ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings WHERE account<>'external'" :: IO [Only Int64]) `shouldReturn` [Only 898]
        commitScan l batch{scanEvents=[event{chainEventEvidence=setPath ["confirmations"] (Number 2) economic}]}
        ledgerAction l (\db->query_ db "SELECT needs_review FROM chain_events" :: IO [Only Bool]) `shouldReturn` [Only False]
        -- Changed block identity cannot inherit the earlier financial approval.
        commitScan l batch{scanEvents=[event{chainEventAnchor="different-block"}]}
        ledgerAction l (\db->query_ db "SELECT needs_review FROM chain_events" :: IO [Only Bool]) `shouldReturn` [Only True]
        recordTreasurySpend l "Native" "operator-payment" proof `shouldThrow` isError "treasury_spend_conflict"
    it "cannot classify an existing customer attempt as an operator spend" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "customer-signature" "bytes" "{}" 5000 Nothing
      pause l "fixture-review"
      commitScan l (ScanBatch "Solana" "origin" Nothing "customer-signature" 100 []
        [ChainEvent "customer-signature" "outgoing" "100" (object ["delta" .= ("-99800"::Text)])])
      recordTreasurySpend l "Solana" "customer-signature" (object ["fixture" .= True])
        `shouldThrow` isError "customer_attempt_cannot_be_treasury_spend"
    it "requires review when signed bytes appear on-chain before a recorded broadcast intent" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l c ob "Solana" "premature-signature" "bytes" "{}" 5000 Nothing
      commitScan l (ScanBatch "SolanaOperating" "origin" Nothing "premature-signature" 100 []
        [ChainEvent "premature-signature" "outgoing" "100" (object ["delta" .= ("-5000"::Text),"feeUnits" .= amt 5000])])
      ledgerAction l (\db->query_ db "SELECT needs_review FROM chain_events" :: IO [Only Bool]) `shouldReturn` [Only True]
      available <$> readiness l `shouldReturn` False
    it "preserves reserved operating funds when reconciling a separate operator spend" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      commitScan l (ScanBatch "SolanaOperating" "origin" Nothing "operator-sig" 100 []
        [ChainEvent "operator-sig" "outgoing" "100" (object ["delta" .= ("-96000"::Text),"feeUnits" .= amt 5000])])
      recordTreasurySpend l "SolanaOperating" "operator-sig" (object ["fixture" .= True])
        `shouldThrow` isError "treasury_spend_exceeds_free_allocation"
  describe "continuous custody reconciliation (offline RPC contracts)" $ do
    it "checks all three assets without resuming or changing any financial records" $ withFunded $ \l original -> do
      let c=expiryConfig original
      setupCustodyScans l c
      pause l "fixture-maintenance"
      before<-auditExport l
      result<-reconcileCustodyWith (pure 100) (custodyContract c (1100000,1000000,100000) []) c l
      fieldValue "lastError" result `shouldReturn` (Nothing::Maybe Text)
      (fieldValue "report" result >>= fieldValue "matches") `shouldReturn` True
      auditExport l `shouldReturn` before
      available <$> readiness l `shouldReturn` False
      resumeAfterChecks l
      checkIntakeReady l 100
      _<-createOrder l c 100 cap req
      checkIntakeReady l 100 -- reservations do not alter physical custody
      observeDeposit l (Deposit "new-receipt" Nothing Native (amt 1) "block" 0 False 100) "cursor"
      checkIntakeReady l 100 `shouldThrow` isError "custody_not_reconciled"
    it "pauses on either a shortfall or an unexplained surplus and deduplicates the alert" $ withFunded $ \l original -> do
      let c=expiryConfig original
      setupCustodyScans l c
      forM_ [999999,1000001] $ \wrapped->do
        result<-reconcileCustodyWith (pure 100) (custodyContract c (1100000,wrapped,100000) []) c l
        fieldValue "lastError" result `shouldReturn` Just ("custody_balance_mismatch"::Text)
        available <$> readiness l `shouldReturn` False
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM audit WHERE action='custody_failure'" :: IO [Only Int]) `shouldReturn` [Only 1]
      good<-reconcileCustodyWith (pure 100) (custodyContract c (1100000,1000000,100000) []) c l
      fieldValue "lastError" good `shouldReturn` (Nothing::Maybe Text)
      available <$> readiness l `shouldReturn` False
    it "rejects a journal mutation during the RPC snapshot even when the old totals match" $ withFunded $ \l original -> do
      let c=expiryConfig original
          transport=custodyContract c (1100000,1000000,100000) []
          sol method params=do
            when (method=="getMultipleAccounts") $ fundAllocation l "concurrent-receipt" Native "float" (amt 1)
            paymentSolana transport method params
      setupCustodyScans l c
      result<-reconcileCustodyWith (pure 100) transport{paymentSolana=sol} c l
      fieldValue "lastError" result `shouldReturn` Just ("custody_ledger_changed"::Text)
      available <$> readiness l `shouldReturn` False
    it "rejects a new Solana history head, an older balance context, and verifier disagreement" $ withFunded $ \l original -> do
      let c=expiryConfig original
          transport=custodyContract c (1100000,1000000,100000) []
          wrongHead=custodyContract c (1100000,1000000,100000) [("Solana",base58 $ BS.replicate 64 9)]
          stale method params=do
            value<-paymentSolana transport method params
            pure $ if method=="getMultipleAccounts" then setPath ["context","slot"] (Number 99) value else value
          disagree=paymentSolana (custodyContract c (1100000,999999,100000) [])
      setupCustodyScans l c
      forM_ [(wrongHead,"custody_solana_history_advanced"),(transport{paymentSolana=stale},"solana_context_too_old")
        ,(transport{paymentVerifier=Just disagree},"custody_verifier_disagreement")] $ \(changed,code)->do
          result<-reconcileCustodyWith (pure 100) changed c l
          fieldValue "lastError" result `shouldReturn` Just (code::Text)
    it "rejects a new native history cursor or balance changing during the read" $ withFunded $ \l original -> do
      let c=expiryConfig original
          transport=custodyContract c (1100000,1000000,100000) []
          advanced wallet method params=do
            value<-paymentNative transport wallet method params
            pure $ if method=="listsinceblock" then setPath ["lastblock"] (String $ T.replicate 64 "e") value else value
      setupCustodyScans l c
      first<-reconcileCustodyWith (pure 100) transport{paymentNative=advanced} c l
      fieldValue "lastError" first `shouldReturn` Just ("custody_native_history_advanced"::Text)
      calls<-newIORef (0::Int)
      let racing wallet method params=do
            value<-paymentNative transport wallet method params
            if method/="getbalances" then pure value else do
              n<-atomicModifyIORef' calls (\x->(x+1,x))
              pure $ if n==0 then value else setPath ["mine","trusted"] (nativeNumber $ amt 1100001) value
      result<-reconcileCustodyWith (pure 100) transport{paymentNative=racing} c l
      fieldValue "lastError" result `shouldReturn` Just ("custody_native_view_changed"::Text)
    it "does not accept equal totals with an unresolved chain review flag" $ withFunded $ \l original -> do
      let c=expiryConfig original
          transport=custodyContract c (1100000,1000000,100000) []
      setupCustodyScans l c
      previous<-readCheckpoint l "Native"
      commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 [] [ChainEvent "unknown" "outgoing" "block" Null])
      result<-reconcileCustodyWith (pure 100) transport c l
      fieldValue "lastError" result `shouldReturn` Just ("chain_observations_require_review"::Text)
    it "retains principal and pauses when an allocated source loses eligibility" $ withFunded $ \l original -> do
      let c=expiryConfig original
      (order,_)<-fundOrder l c
      setupCustodyScans l c
      observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId order) Native (input req) "unconfirmed" 0 False 100) custodyNativeTip
      before<-auditExport l
      result<-reconcileCustodyWith (pure 100) (custodyContract c (1200000,1000000,100000) []) c l
      fieldValue "lastError" result `shouldReturn` Just ("source_reorg_requires_review"::Text)
      auditExport l `shouldReturn` before
    it "invalidates a saved check on real SQLite reopen and never refreshes its age with RPC delay" $ withDir $ \dir -> do
      let c=expiryConfig (cfg dir)
          transport=custodyContract c (0,0,0) []
      withLedger (dbPath c) (fingerprint c) $ \l->do
        setupCustodyScans l c
        checked<-reconcileCustodyWith (pure 100) transport c l
        fieldValue "lastError" checked `shouldReturn` (Nothing::Maybe Text)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        resumeAfterChecks l
        checkIntakeReady l 100 `shouldThrow` isError "custody_not_reconciled"
        calls<-newIORef (0::Int)
        let clock=atomicModifyIORef' calls (\n->(n+1,if n==0 then 100 else 161))
        result<-reconcileCustodyWith clock transport c l
        fieldValue "lastError" result `shouldReturn` Just ("custody_check_timed_out"::Text)
    it "leaves unseen signed bytes and their reservations intact" $ withSendFixture $ \l original _ attempt _->do
      let c=expiryConfig original
          transport=custodyContract c (10004,10000,3000000) []
      setupCustodyScans l c
      before<-auditExport l
      result<-reconcileCustodyWith (pure 100) transport c l
      fieldValue "lastError" result `shouldReturn` (Nothing::Maybe Text)
      (fieldValue "report" result >>= fieldValue "inFlightEffects") `shouldReturn` ([]::[Value])
      pendingAttempts l `shouldReturn` [attempt]
      auditExport l `shouldReturn` before
    it "refuses an on-chain payment whose broadcast intent was never committed" $ withSendFixture $ \l original _ attempt _->do
      let c=expiryConfig original
          transport=custodyContract c (10004,9997,2995000) []
      setupCustodyScans l c
      signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy attempt)
      proof<-codecSettlementProof c signed True
      let call method params=if method=="getTransaction" then pure proof else paymentSolana transport method params
      result<-reconcileCustodyWith (pure 100) transport{paymentSolana=call} c l
      fieldValue "lastError" result `shouldReturn` Just ("unrecorded_broadcast_observed"::Text)
    forM_ [(True,0),(True,1488440),(False,0)] $ \(success,rent)->
      it ("normalizes a Solana outcome once, including rent/failure: "<>show (success,rent)) $ withSendFixture $ \l original _ attempt _->do
        let c=expiryConfig original
            txid=attemptId attempt
            outgoing=if success then 3 else 0
            cost=5000+rent
            base=custodyContract c (10004,10000-outgoing,3000000-cost) [("Solana",txid),("SolanaOperating",txid)]
        _<-markBroadcastIntent l txid
        [saved]<-pendingAttempts l
        signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy attempt)
        originalProof<-codecSettlementProof c signed success
        proof<-addCodecRent signed rent originalProof
        setupCustodyScans l c
        forM_ [("Solana",negate outgoing),("SolanaOperating",negate cost)] $ \(stream,delta)->do
          previous<-readCheckpoint l stream
          origin<-maybe (fail "missing origin") pure (if stream=="Solana" then solanaHistoryStart c else solanaOperatingHistoryStart c)
          let kind=if stream=="Solana" && not success then "failed" else "outgoing"
          commitScan l (ScanBatch stream origin previous txid 100 [] [ChainEvent txid kind "101" (object ["delta" .= T.pack(show delta),"feeUnits" .= amt 5000])])
        let call method params=if method=="getTransaction" then pure proof else paymentSolana base method params
            transport=base{paymentSolana=call}
        before<-auditExport l
        result<-reconcileCustodyWith (pure 100) transport c l
        fieldValue "lastError" result `shouldReturn` (Nothing::Maybe Text)
        auditExport l `shouldReturn` before
        settleAttemptWith transport c l saved `shouldReturn` (if success then "settled" else "failed")
        second<-reconcileCustodyWith (pure 100) transport c l
        fieldValue "lastError" second `shouldReturn` (Nothing::Maybe Text)
        (fieldValue "report" second >>= fieldValue "inFlightEffects") `shouldReturn` ([]::[Value])
        -- Equal current balances cannot excuse loss of a booked finality anchor.
        cursor<-readCheckpoint l "SolanaOperating"
        origin<-maybe (fail "missing origin") pure (solanaOperatingHistoryStart c)
        commitScan l (ScanBatch "SolanaOperating" origin cursor txid 100 [] [ChainEvent txid "outgoing" "102" (object ["delta" .= T.pack(show $ negate cost),"feeUnits" .= amt 5000])])
        changed<-reconcileCustodyWith (pure 100) transport c l
        fieldValue "lastError" changed `shouldReturn` Just ("booked_solana_observation_changed"::Text)
    it "normalizes a native mempool payment and its fee using the captured signed bytes" $ withFunded $ \l original->do
      (plan,previous,fee,tx)<-nativeFixture
      captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
      raw<-fieldValue "raw" captured
      decoded<-fieldValue "decoded" captured
      let c=(expiryConfig original){nativeConfirmations=planDepth plan,maxNativeFee=planFeeLimit plan}
          signed=NativeSigned raw tx plan previous fee
          txid=nativeTxid tx
          request'=req{input=planAmount plan,refund=planRecipient plan}
      order<-createOrder l c 100 cap request'
      bindInstruction l (orderId order) "fixture-native-instruction"
      observeDeposit l (Deposit "native-refund-source" (Just $ orderId order) Native (planAmount plan) "source-block" (planDepth plan) True 100) "source-cursor"
      ob<-createRefund l "native-refund-source"
      testAttempt l c ob "Native" txid raw (TE.decodeUtf8 $ LBS.toStrict $ encode signed) (units $ planFeeLimit plan) Nothing
      _<-markBroadcastIntent l txid
      setupCustodyScans l c
      cursor<-readCheckpoint l "Native"
      let evidence=object ["confirmations" .= (0::Int),"walletNetUnits" .= T.pack(show $ negate $ units $ planAmount plan),"feeUnits" .= fee]
      commitScan l (ScanBatch "Native" (nativeCheckpointHash c) cursor custodyNativeTip 100 [] [ChainEvent txid "outgoing" "unconfirmed" evidence])
      let transport=custodyContract c (1100000-toInteger (units fee),1000000,100000) []
          call wallet method params=case method of
            "decoderawtransaction"->pure decoded
            "gettransaction"->pure $ object ["hex" .= raw,"decoded" .= decoded,"txid" .= txid
              ,"confirmations" .= (0::Int),"walletconflicts" .= ([]::[Text]),"fee" .= scientific (negate $ toInteger $ units fee) (-8)]
            "getmempoolentry"->pure $ object ["vsize" .= (141::Int)]
            _->paymentNative transport wallet method params
      result<-reconcileCustodyWith (pure 100) transport{paymentNative=call} c l
      fieldValue "lastError" result `shouldReturn` (Nothing::Maybe Text)
      pendingAttempts l >>= \saved->map attemptState saved `shouldBe` ["broadcast_intent"]
  describe "SOL accounting from captured public Devnet metadata" $ do
    it "observes the actual SOL setup receipt without charging the external payer's fee to custody" $ do
      captured<-BS.readFile "test/fixtures/solana-devnet-accounts.json" >>= either fail pure . eitherDecodeStrict'
      sig<-fieldValue "manifest" captured >>= fieldValue "setupSignature"
      proof<-fieldValue "setupTransaction" captured
      effect<-either (fail . T.unpack) pure (lamportEffect sig (custodyOwner $ cfg "/unused") proof)
      lamportBefore effect `shouldBe` amt 0
      lamportDelta effect `shouldBe` 5000000
      lamportFee effect `shouldBe` amt 0
    forM_ [("existing",5000),("new",1493440)] $ \(kind,debit) -> it ("observes fee and account-rent SOL for the "<>kind<>" recipient") $ do
      (c,signed,proof,_)<-capturedSolanaPayment kind
      sig<-maybe (fail "missing signature") pure (replySignature $ signedSolanaReply signed)
      effect<-either (fail . T.unpack) pure (lamportEffect sig (custodyOwner c) proof)
      lamportDelta effect `shouldBe` negate debit
      lamportFee effect `shouldBe` amt 5000
    it "retains failed-transaction fees but rejects a failed transaction changing other principal" $ do
      (c,signed,proof,_)<-capturedSolanaPayment "existing"
      sig<-maybe (fail "missing signature") pure (replySignature $ signedSolanaReply signed)
      let failed=setPath ["meta","err"] (String "fixture-error") proof
      lamportFailed <$> lamportEffect sig (custodyOwner c) failed `shouldBe` Right True
      (newConfig,newSigned,newProof,_)<-capturedSolanaPayment "new"
      newSig<-maybe (fail "missing signature") pure (replySignature $ signedSolanaReply newSigned)
      lamportEffect newSig (custodyOwner newConfig) (setPath ["meta","err"] (String "fixture-error") newProof)
        `shouldBe` Left "unclassified_lamport_effect"
  describe "backup and schema protections" $ do
    it "migrates version one without losing financial rows or critical sequence" $ withDir $ \dir -> do
      let c=cfg dir
      createDirectoryIfMissing True (takeDirectory $ dbPath c)
      schema<-TE.decodeUtf8 <$> BS.readFile "migrations/001.sql"
      bracket (open $ dbPath c) close $ \db -> do
        forM_ (T.splitOn "-- @statement" schema) $ execute_ db . fromString . T.unpack
        execute db "INSERT INTO deployment(singleton,schema_version,fingerprint,critical_sequence,backup_sequence) VALUES(1,1,?,47,46)" (Only $ fingerprint c)
        execute_ db "INSERT INTO events(id,description) VALUES('legacy','existing receipt')"
        execute_ db "INSERT INTO postings(event_id,asset,account,delta) VALUES('legacy','Native','float',1000),('legacy','Native','external',-1000)"
        execute_ db "INSERT INTO events(id,description) VALUES('legacy-cost','historical fee with no trustworthy timestamp')"
        execute_ db "INSERT INTO postings(event_id,asset,account,delta) VALUES('legacy-cost','Native','operating',-10),('legacy-cost','Native','external',10)"
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        ledgerAction l (\db->query_ db "SELECT schema_version,critical_sequence,backup_sequence FROM deployment" :: IO [(Int,Int64,Int64)]) `shouldReturn` [(schemaVersion,47,46)]
        ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1000
        ledgerAction l (\db->operatingTime db >>= operatingSpent db "Native") `shouldReturn` 10
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM operating_costs" :: IO [Only Int]) `shouldReturn` [Only 1]
        available <$> readiness l `shouldReturn` False
    it "preserves an unfinished legacy order without inventing cost policy or allowing resume" $ withDir $ \dir -> do
      let c=cfg dir
          json value=TE.decodeUtf8 $ LBS.toStrict $ encode value
      capHash<-either (fail . T.unpack) pure (capabilityHash cap)
      quoted<-either (fail . T.unpack) pure (makeQuote (direction req) (input req))
      createDirectoryIfMissing True (takeDirectory $ dbPath c)
      bracket (open $ dbPath c) close $ \db -> do
        schema<-TE.decodeUtf8 <$> BS.readFile "migrations/001.sql"
        forM_ (T.splitOn "-- @statement" schema) $ execute_ db . fromString . T.unpack
        execute db "INSERT INTO deployment(singleton,schema_version,fingerprint) VALUES(1,1,?)" (Only $ fingerprint c)
        forM_ [2..6::Int] $ \v -> do
          migration<-TE.decodeUtf8 <$> BS.readFile ("migrations/00"<>show v<>".sql")
          forM_ (T.splitOn "-- @statement" migration) $ execute_ db . fromString . T.unpack
        execute db "INSERT INTO orders(id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,status,deadline,grace_deadline) VALUES('legacy-order',?,'legacy-key','legacy-request',?,?,?,'Provisioning',400,1000)"
          (capHash,json req,json quoted,json $ PolicySnapshot 1 "finalized" (fingerprint c))
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        request <$> readOrder l cap "legacy-order" `shouldReturn` req
        ledgerAction l (\db->orderCostLimits db "legacy-order") `shouldThrow` isError "order_cost_policy_missing"
        resumeAfterChecks l `shouldThrow` isError "legacy_order_cost_review_required"
        available <$> readiness l `shouldReturn` False
    it "does not expose canonical instructions before acknowledged coverage" $ withFunded $ \l c -> do
      freshScans l 100
      o<-createOrder l c 100 cap req
      bindInstruction l (orderId o) "fixture-address"
      depositInstruction <$> exposeOrder l True cap (orderId o) `shouldReturn` Nothing
      issueInstruction l c{backupRequired=True} 100 cap (orderId o) `shouldThrow` isError "backup_pending"
      acknowledgeBackup l 1 (T.replicate 64 "b")
      _<-issueInstruction l c{backupRequired=True} 100 cap (orderId o)
      depositInstruction <$> exposeOrder l True cap (orderId o) `shouldReturn` Just "fixture-address"
      acknowledgeBackup l 99 "bad" `shouldThrow` isError "invalid_backup_coverage"
    it "makes a consistent snapshot while the ledger is open" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      bindInstruction l (orderId o) "fixture-address"
      sqlite<-findExecutable "sqlite3" >>= maybe (fail "sqlite3 required for backup integration test") pure
      snapshot<-snapshotLedger sqlite (dbPath c) (takeDirectory (dbPath c)</>"snapshots") (fingerprint c)
      snapshotSequence snapshot `shouldBe` 1
      snapshotFingerprint snapshot `shouldBe` fingerprint c
    it "refuses repointing an existing database" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) (const $ pure ())
      withLedger (dbPath c) "other-profile" (const $ pure ()) `shouldThrow` isError "ledger_profile_or_schema_mismatch"
  describe "native quote admission (offline RPC contracts)" $ do
    it "checks the full native refund and exact net redemption without signing or locking" $ withNativeAdmission $ \c plan calls call -> do
      let wrap=req{refund=planRecipient plan}
          redeem=req{direction=WrappedToNative,input=amt 101011,recipient=planRecipient plan}
      checkNativeQuoteWith call c wrap `shouldReturn` NativeQuoteCheck "refund" (planRecipientScript plan) (amt 100000) (amt 282)
      checkNativeQuoteWith call c redeem `shouldReturn` NativeQuoteCheck "payout" (planRecipientScript plan) (amt 100000) (amt 282)
      methods<-readIORef calls
      methods `shouldSatisfy` all (`notElem` ["getnewaddress","getrawchangeaddress","lockunspent","walletprocesspsbt","finalizepsbt","sendrawtransaction"])
      length (filter (=="walletcreatefundedpsbt") methods) `shouldBe` 2
    it "rejects owned and watched destinations before wallet funding" $ withNativeAdmission $ \c plan calls call -> do
      forM_ [(True,False),(False,True)] $ \(mine,watched) -> do
        let owned wallet method params = if method=="getaddressinfo"
              then pure $ object ["ismine" .= mine,"iswatchonly" .= watched,"scriptPubKey" .= planRecipientScript plan]
              else call wallet method params
        checkNativeQuoteWith owned c req{refund=planRecipient plan} `shouldThrow` isError "bridge_owned_destination"
      readIORef calls `shouldReturn` []
    it "refuses unknown witness, anchor and nonstandard destination types" $ withNativeAdmission $ \c plan calls call -> do
      forM_ ["witness_unknown","anchor","nonstandard","nulldata","multisig"] $ \kind -> do
        let unsupported wallet method params = if method=="decodescript" then pure (object ["type" .= (kind::Text)]) else call wallet method params
        checkNativeQuoteWith unsupported c req{refund=planRecipient plan} `shouldThrow` isError "unsupported_native_destination"
      readIORef calls >>= (`shouldSatisfy` notElem "walletcreatefundedpsbt")
    it "rejects invalid address bounds and malformed script responses" $ withNativeAdmission $ \_ plan _ call -> do
      forM_ ["",T.replicate 129 "x"] $ \address -> validateNativeRecipientWith call address `shouldThrow` isError "invalid_native_address"
      forM_ ["", "0", "zz", T.replicate 202 "0"] $ \script -> do
        let malformed _ _ _=pure $ object ["ismine" .= False,"scriptPubKey" .= (script::Text)]
        validateNativeRecipientWith malformed (planRecipient plan) `shouldThrow` isError "invalid_native_script"
    it "requires a safe confirmed spendable wallet output for existing change" $ withNativeAdmission $ \c plan calls call -> do
      forM_ (["safe","spendable","solvable"]::[Text]) $ \flag -> do
        let noFunds wallet method params = if method=="listunspent"
              then pure $ toJSON [object ["address" .= planChange plan,"confirmations" .= (1000::Int)
                ,"safe" .= (flag/="safe"),"spendable" .= (flag/="spendable"),"solvable" .= (flag/="solvable")]]
              else call wallet method params
        checkNativeQuoteWith noFunds c req{refund=planRecipient plan} `shouldThrow` isError "native_admission_funds_unavailable"
      readIORef calls >>= (`shouldSatisfy` notElem "walletcreatefundedpsbt")
    it "does not touch locks belonging to another or interrupted payment" $ withNativeAdmission $ \c plan calls call -> do
      let locked wallet method params = if method=="listlockunspent"
            then pure $ toJSON [Outpoint (T.replicate 64 "a") 0] else call wallet method params
      checkNativeQuoteWith locked c req{refund=planRecipient plan} `shouldThrow` isError "native_preparation_locks_require_review"
      readIORef calls >>= (`shouldSatisfy` all (`notElem` ["lockunspent","walletcreatefundedpsbt"]))
    it "preserves a node refusal or unknown funding response without retrying or signing" $ withNativeAdmission $ \c plan calls call -> do
      forM_ ["rpc_error_-4","rpc_transport_unknown_outcome"] $ \code -> do
        writeIORef calls []
        let refused wallet method params = if method=="walletcreatefundedpsbt"
              then modifyIORef' calls (<>[method]) >> reject code else call wallet method params
        checkNativeQuoteWith refused c req{refund=planRecipient plan} `shouldThrow` isError code
        methods<-readIORef calls
        length (filter (=="walletcreatefundedpsbt") methods) `shouldBe` 1
        methods `shouldSatisfy` notElem "walletprocesspsbt"
    it "refuses funding above the native fee ceiling without changing the quoted output" $ withNativeAdmission $ \c plan calls call -> do
      checkNativeQuoteWith call c{maxNativeFee=amt 281} req{refund=planRecipient plan} `shouldThrow` isError "native_fee_mismatch"
      readIORef calls >>= (`shouldSatisfy` notElem "walletprocesspsbt")
  describe "native transaction validation (captured public-Signet transaction)" $ do
    it "accepts the exact recipient, change, input and fee in the recorded real payment" $ do
      (plan,previous,fee,tx)<-nativeFixture
      validateNativeTx plan previous fee tx `shouldBe` Right ()
      nativeTxid tx `shouldBe` "b2278e8dd0be7be001a5630545ddb73c83423ee1ee7dbd0327675e27f1642bd3"
    it "rejects changed amounts, destinations, third outputs and nonowned change scripts" $ do
      (plan,previous,fee,tx)<-nativeFixture
      let mutations=[plan{planAmount=amt 100001},plan{planRecipientScript="0014"<>T.replicate 40 "a"},plan{planChangeScript="0014"<>T.replicate 40 "b"}]
      forM_ mutations $ \changed->validateNativeTx changed previous fee tx `shouldBe` Left "native_output_mismatch"
      validateNativeTx plan previous fee tx{nativeOutputs=nativeOutputs tx<>[NativeOutput "6a00" (amt 1)]} `shouldBe` Left "native_output_mismatch"
    it "computes fees from verified prevouts and rejects unconfirmed or duplicate inputs" $ do
      (plan,previous,fee,tx)<-nativeFixture
      validateNativeTx plan{planFeeLimit=amt 281} previous fee tx `shouldBe` Left "native_fee_mismatch"
      validateNativeTx plan previous (amt 283) tx `shouldBe` Left "native_fee_mismatch"
      validateNativeTx plan (map (\p->p{prevoutAmount=amt 2000001}) previous) fee tx `shouldBe` Left "native_fee_mismatch"
      validateNativeTx plan (map (\p->p{prevoutDepth=0}) previous) fee tx `shouldBe` Left "native_input_not_confirmed"
      validateNativeTx plan (previous<>previous) fee tx{nativeInputs=nativeInputs tx<>nativeInputs tx} `shouldBe` Left "native_input_mismatch"
    it "enforces separate Signet and ECX locktime rules (pure mutation checks, not ECX acceptance)" $ do
      (plan,previous,fee,tx)<-nativeFixture
      validateNativeTx plan previous fee tx{nativeLocktime=499999999} `shouldBe` Left "native_replay_policy_mismatch"
      validateNativeTx plan{planProfile=ECXBetanetDevnet} previous fee tx `shouldBe` Left "native_replay_policy_mismatch"
      validateNativeTx plan{planProfile=ECXBetanetDevnet} previous fee tx{nativeLocktime=499999999} `shouldBe` Right ()
      validateNativeTx plan previous fee tx{nativeInputs=map (\i->i{nativeSequence=4294967295}) (nativeInputs tx)} `shouldBe` Left "native_replay_policy_mismatch"
    it "refuses a corrupted saved draft before invoking the wallet signer" $ do
      (plan,previous,fee,tx)<-nativeFixture
      let draft=NativeDraft "unused-transport-fixture" tx{nativeLocktime=1} previous fee
          unexpected _ _ _=expectationFailure "unexpected wallet RPC" >> pure Null
      signNativeDraft unexpected plan draft `shouldThrow` isError "native_replay_policy_mismatch"
    it "stores the draft before signing and reuses a recorded attempt (RPC contract test)" $ withFunded $ \l c -> do
      captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
      (plan,previous,fee,tx)<-nativeFixture
      previousOutput<-case previous of [p]->pure p; _->fail "expected one captured previous output"
      decoded<-fieldValue "decoded" captured
      raw<-fieldValue "raw" captured :: IO Text
      o<-createOrder l c 100 cap req{refund=planRecipient plan}
      observeDeposit l (Deposit "native-contract:0" (Just $ orderId o) Native (amt 100000) "fixture-anchor" 1 True 100) "fixture-cursor"
      ob<-createRefund l "native-contract:0"
      calls<-newIORef []
      locks<-newIORef ([]::[Outpoint])
      let call _ method params=do
            modifyIORef' calls (<>[method])
            case (method,params) of
              ("getaddressinfo",[String address]) -> pure $ object
                ["ismine" .= (address/=planRecipient plan),"scriptPubKey" .=
                  (if address==planRecipient plan then planRecipientScript plan
                   else if address==planChange plan then planChangeScript plan else prevoutScript previousOutput)]
              ("getrawchangeaddress",_) -> pure $ toJSON (planChange plan)
              ("decodescript",_) -> pure $ object ["type" .= ("witness_v0_keyhash"::Text)]
              ("listlockunspent",_) -> toJSON <$> readIORef locks
              ("walletcreatefundedpsbt",[_,_,_,options,_]) -> do
                -- These responses test the RPC contract, not chain acceptance.
                fieldValue "replaceable" options `shouldReturn` False
                fieldValue "lockUnspents" options `shouldReturn` True
                fieldValue "minconf" options `shouldReturn` planDepth plan
                writeIORef locks (map nativeOutpoint $ nativeInputs tx)
                pure $ object ["psbt" .= ("rpc-contract-psbt"::Text),"fee" .= nativeNumber fee,"changepos" .= (0::Int)]
              ("decodepsbt",_) -> pure $ object ["tx" .= (decoded::Value),"fee" .= nativeNumber fee]
              ("gettxout",_) -> pure $ object ["value" .= nativeNumber (prevoutAmount previousOutput),"confirmations" .= (1000::Int),"coinbase" .= False,"scriptPubKey" .= object ["hex" .= prevoutScript previousOutput,"address" .= ("rpc-contract-source"::Text)]]
              ("walletprocesspsbt",_) -> do
                saved<-pendingPreparations l
                length saved `shouldBe` 1
                map preparationDraft saved `shouldSatisfy` all (/=Nothing)
                pendingAttempts l `shouldReturn` []
                pure $ object ["complete" .= True,"psbt" .= ("rpc-contract-signed-psbt"::Text)]
              ("finalizepsbt",_) -> pure $ object ["complete" .= True,"hex" .= raw]
              ("decoderawtransaction",_) -> pure decoded
              ("testmempoolaccept",_) -> pure $ toJSON [object ["txid" .= nativeTxid tx,"allowed" .= True,"fees" .= object ["base" .= nativeNumber fee]]]
              _ -> expectationFailure ("unexpected RPC: "<>T.unpack method) >> pure Null
      prepareNativeWith call c l ob `shouldReturn` nativeTxid tx
      firstCalls<-readIORef calls
      prepareNativeWith call c l ob `shouldReturn` nativeTxid tx
      readIORef calls `shouldReturn` firstCalls
      firstCalls `shouldSatisfy` notElem "sendrawtransaction"
      map attemptState <$> pendingAttempts l `shouldReturn` ["signed"]
      map attemptBytes <$> pendingAttempts l `shouldReturn` [raw]
      pendingPreparations l `shouldReturn` []
    it "retains preparation and pauses if a funding response is lost (RPC contract test)" $ withFunded $ \l c -> do
      (plan,_,_,_)<-nativeFixture
      o<-createOrder l c 100 cap req{refund=planRecipient plan}
      observeDeposit l (Deposit "lost-reply:0" (Just $ orderId o) Native (amt 100000) "anchor" 1 True 100) "cursor"
      ob<-createRefund l "lost-reply:0"
      let call _ method _=case method of
            "getaddressinfo" -> pure $ object ["ismine" .= False,"scriptPubKey" .= planRecipientScript plan]
            _ -> reject "unused"
      -- Persisting an unsigned draft may be interrupted after node-side locks.
      -- The ledger must still prevent another payment/refund without recovery.
      beginPreparation l c ob "Native" 1000 (TE.decodeUtf8 $ LBS.toStrict $ encode plan)
      let lost _ method _=if method=="listlockunspent" then pure (toJSON ([]::[Outpoint])) else reject "simulated_lost_funding_reply"
      prepareNativeWith lost c l ob `shouldThrow` isError "simulated_lost_funding_reply"
      map preparationDraft <$> pendingPreparations l `shouldReturn` [Nothing]
      available <$> readiness l `shouldReturn` False
      pendingAttempts l `shouldReturn` []
      prepareNativeWith call c l ob `shouldThrow` isError "payouts_paused"
  describe "Solana preparation (SDK fixtures and RPC contract tests)" $ do
    it "binds the helper protocol, message, memo, signature and custody account" $ do
      (c,plan,reply)<-solanaFixture
      let request=solanaPayoutRequest c plan
      validateHelperReply c request reply `shouldSatisfy` either (const False) (const True)
      forM_ [reply{replyProtocol=2},reply{replyMemo="wrong"},reply{replySignature=Nothing}
        ,reply{replySource=replyDestination reply},reply{replyMessage="AAAA"}] $ \changed ->
          validateHelperReply c request changed `shouldSatisfy` either (const True) (const False)
      validateHelperReply c request{helperAmount=amt 2} reply `shouldSatisfy` either (const True) (const False)
    it "simulates the exact SDK message without exposing its valid signature" $ do
      (c,plan,reply)<-solanaFixture
      calls<-newIORef []
      let call method params=do
            modifyIORef' calls (<>[method])
            case (method,params) of
              ("getFeeForMessage",[message,_])->message `shouldBe` toJSON (replyMessage reply)
              ("simulateTransaction",[String encoded,options])->do
                transaction<-either (fail . T.unpack) pure (decodeTransaction encoded)
                case transaction of
                  Transaction signatures _ body -> do
                    signatures `shouldBe` [BS.replicate 64 0]
                    TE.decodeUtf8 (B64.encode body) `shouldBe` replyMessage reply
                fieldValue "sigVerify" options `shouldReturn` False
                fieldValue "replaceRecentBlockhash" options `shouldReturn` False
              _->pure ()
            solanaContract c plan Null method params
      signed<-prepareSolanaSigned call (const $ pure reply) c plan
      signedSolanaFeeEstimate signed `shouldBe` amt 5000
      signedSolanaRentEstimate signed `shouldBe` amt 1488440
      readIORef calls >>= (`shouldSatisfy` notElem "sendTransaction")
    it "charges no rent for an existing ATA and credits lamports pre-funded to a new ATA" $ do
      (c,plan,reply)<-solanaFixture
      let prepare destination=prepareSolanaSigned (solanaContract c plan destination) (const $ pure reply) c plan
      existing<-prepare (tokenContract c (solPlanRecipient plan))
      signedSolanaRentEstimate existing `shouldBe` amt 0
      prefunded<-prepare (systemContract 100000)
      signedSolanaRentEstimate prefunded `shouldBe` amt 1388440
      full<-prepare (systemContract 2000000)
      signedSolanaRentEstimate full `shouldBe` amt 0
    it "refuses excess rent/fees, missing fee quotes and insufficient operating SOL" $ do
      (c,plan,reply)<-solanaFixture
      let prepare p transport=prepareSolanaSigned transport (const $ pure reply) c p
          call=solanaContract c plan Null
          missingFee method params=if method=="getFeeForMessage" then pure (contextContract Null) else call method params
          noSol method params=if method=="getMultipleAccounts" then pure (contextContract $ toJSON [tokenContract c (custodyOwner c),Null,systemContract 1]) else call method params
      prepare plan{solPlanRentLimit=amt 1} call `shouldThrow` isError "solana_rent_above_limit"
      prepare plan{solPlanFeeLimit=amt 1} call `shouldThrow` isError "solana_fee_above_limit"
      prepare plan missingFee `shouldThrow` isError "solana_fee_unavailable"
      prepare plan noSol `shouldThrow` isError "insufficient_operating_sol"
    it "refuses short-lived blockhashes, stale account context and failed simulation" $ do
      (c,plan,reply)<-solanaFixture
      let call=solanaContract c plan Null
          prepare rpcCall=prepareSolanaSigned rpcCall (const $ pure reply) c plan
          expired method params=if method=="getBlockHeight" then pure (toJSON (970::Int)) else call method params
          stale method params=if method=="getMultipleAccounts" then pure (object ["context" .= object ["slot" .= (99::Int)],"value" .= Null]) else call method params
          failed method params=if method=="simulateTransaction" then pure (contextContract $ object ["err" .= ("fixture-error"::Text)]) else call method params
      prepare expired `shouldThrow` isError "solana_blockhash_window_too_short"
      prepare stale `shouldThrow` isError "solana_context_too_old"
      prepare failed `shouldThrow` isError "solana_simulation_failed"
    it "uses the quoted fee/rent ceilings after settings change and reuses saved bytes" $ withSolanaLedger $ \l c plan reply -> do
      (_,ob)<-fundSolanaOrder l c plan
      calls<-newIORef []
      let call method params=modifyIORef' calls (<>[method]) >> solanaContract c plan Null method params
          helper request=do
            preparations<-pendingPreparations l
            map preparationFeeLimit preparations `shouldBe` [2110000]
            map preparationDraft preparations `shouldBe` [Just $ TE.decodeUtf8 $ LBS.toStrict $ encode request]
            pendingAttempts l `shouldReturn` []
            -- The public deterministic codec key signs only this offline test.
            codecReply c request reply
      signature<-prepareSolanaWith call helper c{maxSolFee=amt 1,maxSolAccountRent=amt 0} l ob
      initialCalls<-readIORef calls
      pause l "fixture-restart"
      prepareSolanaWith call helper c l ob `shouldReturn` signature
      readIORef calls `shouldReturn` initialCalls
      attempts<-pendingAttempts l
      map attemptId attempts `shouldBe` [signature]
      map attemptState attempts `shouldBe` ["signed"]
      map attemptFeeLimit attempts `shouldBe` [2110000]
      pendingPreparations l `shouldReturn` []
      initialCalls `shouldSatisfy` notElem "sendTransaction"
    it "retains the request and pauses after a lost helper response" $ withSolanaLedger $ \l c plan _ -> do
      (_,ob)<-fundSolanaOrder l c plan
      let helper _=reject "fixture_helper_reply_lost"
      prepareSolanaWith (solanaContract c plan Null) helper c l ob `shouldThrow` isError "fixture_helper_reply_lost"
      preparations<-pendingPreparations l
      length preparations `shouldBe` 1
      map preparationDraft preparations `shouldSatisfy` all (/=Nothing)
      pendingAttempts l `shouldReturn` []
      available <$> readiness l `shouldReturn` False
      prepareSolanaWith (solanaContract c plan Null) helper c l ob `shouldThrow` isError "payouts_paused"
    it "does not invoke the helper after the current daily operating cap is lowered" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      (_,plan,_)<-solanaFixture
      let helper _=expectationFailure "signer called without budget" >> reject "unexpected"
      prepareSolanaWith (solanaContract c plan Null) helper c{maxSolDailyCost=amt 1} l ob `shouldThrow` isError "operating_daily_limit"
      pendingPreparations l `shouldReturn` []
      pendingAttempts l `shouldReturn` []
  describe "unsigned customer deposits (SDK fixture and offline RPC contracts)" $ do
    it "binds owner, amount and memo without a custody signature or payment intent" $ withDepositFixture $ \l c order recent reply call -> do
      let helper r=do
            helperPayout r `shouldBe` False
            helperOwner r `shouldBe` refund (request order)
            helperAmount r `shouldBe` input (request order)
            unsignedDepositReply c r reply
      prepared<-prepareSolanaDepositWith (pure 100) call helper c l cap (orderId order)
      bytes<-fieldValue "transaction" prepared
      Transaction signatures _ _<-either (fail . T.unpack) pure (decodeTransaction bytes)
      signatures `shouldBe` [BS.replicate 64 0]
      fieldValue "memo" prepared `shouldReturn` solanaDepositMemo c (orderId order)
      fieldValue "lastValidBlockHeight" prepared `shouldReturn` recentLastValidHeight recent
      pendingAttempts l `shouldReturn` []
      readyObligations l `shouldReturn` []
    it "refreshes a blockhash without changing the order or reserving more inventory" $ withDepositFixture $ \l c order _ reply call -> do
      let helper = \r -> unsignedDepositReply c r reply
          prepare rpcCall=prepareSolanaDepositWith (pure 100) rpcCall helper c l cap (orderId order)
          nextHash=base58 $ BS.replicate 32 7
          changed method params=if method=="getLatestBlockhash" then pure $ contextContract $ object ["blockhash" .= nextHash,"lastValidBlockHeight" .= (1000::Int)] else call method params
      first<-prepare call
      second<-prepare changed
      fieldValue "transaction" first >>= \bytes -> fieldValue "transaction" second >>= \newBytes -> (bytes::Text) `shouldNotBe` newBytes
      fieldValue "memo" first >>= \memo -> fieldValue "memo" second `shouldReturn` (memo::Text)
      request <$> readOrder l cap (orderId order) `shouldReturn` request order
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM reservations" :: IO [Only Int]) `shouldReturn` [Only 1]
    it "requires instruction backup coverage before invoking the helper" $ withDepositFixture $ \l c order _ reply call -> do
      let noHelper _=expectationFailure "helper called before backup coverage" >> reject "unexpected"
          prepare helper=prepareSolanaDepositWith (pure 100) call helper c{backupRequired=True} l cap (orderId order)
      prepare noHelper `shouldThrow` isError "backup_pending"
      sequenceRows<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
      sequenceNumber<-case sequenceRows of [Only n]->pure n; _->fail "missing sequence"
      acknowledgeBackup l sequenceNumber "fixture-covered-order"
      _<-prepare (\r->unsignedDepositReply c r reply)
      pure ()
    it "rechecks deadline and pause state after RPC without losing the quote" $ withDepositFixture $ \l c order _ reply call -> do
      ticks<-newIORef ([100,deadline order+1]::[Int64])
      let clock=atomicModifyIORef' ticks (\xs->case xs of a:rest->(rest,a); _->([],deadline order+1))
          helper = \r -> unsignedDepositReply c r reply
      prepareSolanaDepositWith clock call helper c l cap (orderId order) `shouldThrow` isError "deposit_window_closed"
      let stopped method params=do
            when (method=="getFeeForMessage") $ pause l "fixture-pause-during-RPC"
            call method params
      prepareSolanaDepositWith (pure 100) stopped helper c l cap (orderId order) `shouldThrow` isError "deposits_paused"
      status <$> readOrder l cap (orderId order) `shouldReturn` "AwaitingDeposit"
    it "rejects unauthorized access and insufficient user fee funds without signing" $ withDepositFixture $ \l c order _ reply call -> do
      let helper = \r -> unsignedDepositReply c r reply
      prepareSolanaDepositWith (pure 100) call helper c l (T.replicate 64 "b") (orderId order) `shouldThrow` isError "order_not_found"
      let poor method params=if method=="getMultipleAccounts" then pure $ contextContract $ toJSON
            [tokenContract c (refund $ request order),tokenContract c (custodyOwner c),systemContract 1] else call method params
      prepareSolanaDepositWith (pure 100) poor helper c l cap (orderId order) `shouldThrow` isError "insufficient_deposit_fee_sol"
      available <$> readiness l `shouldReturn` True
      pendingAttempts l `shouldReturn` []
  describe "recoverable order provisioning (offline RPC contracts)" $ do
    it "records and issues one address after admission, then reuses it while paused" $ withProvisioning $ \l c transport count -> do
      order<-createCustomerOrderWith transport c l cap req
      depositInstruction order `shouldBe` Just "fixture-receive-1"
      readIORef count `shouldReturn` 1
      pause l "fixture-paused"
      let noChecks=transport{orderAdmission=const $ reject "unexpected_admission",orderIdentity=reject "unexpected_identity"}
      createCustomerOrderWith noChecks c{maxInput=amt 2,maxSolFee=amt 1} l cap req `shouldReturn` order
      depositInstruction <$> exposeOrder l False cap (orderId order) `shouldReturn` depositInstruction order
      changed<-try (ledgerAction l $ \db -> execute_ db "UPDATE orders SET instruction='replacement'") :: IO (Either SomeException ())
      changed `shouldSatisfy` either (const True) (const False)
    it "rejects failed admission before storing an order or allocating an address" $ withProvisioning $ \l c transport count -> do
      createCustomerOrderWith transport{orderAdmission=const $ reject "fixture_admission_failed"} c l cap req
        `shouldThrow` isError "fixture_admission_failed"
      findOrder l c cap req `shouldReturn` Nothing
      readIORef count `shouldReturn` 0
    it "stops new orders when scans become stale or fail during admission" $ withProvisioning $ \l c transport count -> do
      createCustomerOrderWith transport{orderClock=pure 161} c l cap req `shouldThrow` isError "scanners_not_fresh"
      let stop=transport{orderAdmission=const $ recordScanFailure l "Solana" 100 "fixture-outage"}
      createCustomerOrderWith stop c l cap req `shouldThrow` isError "intake_paused"
      findOrder l c cap req `shouldReturn` Nothing
      readIORef count `shouldReturn` 0
    it "recovers a lost getnewaddress reply using the saved label without repeating allocation" $ withProvisioning $ \l c transport count -> do
      let lost wallet method params=do
            result<-orderNative transport wallet method params
            if method=="getnewaddress" then reject "rpc_transport_unknown_outcome" else pure result
      createCustomerOrderWith transport{orderNative=lost} c l cap req `shouldThrow` isError "rpc_transport_unknown_outcome"
      prior<-findOrder l c cap req >>= maybe (fail "missing durable order") pure
      status prior `shouldBe` "Provisioning"
      depositInstruction <$> exposeOrder l False cap (orderId prior) `shouldReturn` Nothing
      recovered<-createCustomerOrderWith transport c l cap req
      orderId recovered `shouldBe` orderId prior
      deadline recovered `shouldBe` deadline prior
      depositInstruction recovered `shouldBe` Just "fixture-receive-1"
      readIORef count `shouldReturn` 1
    it "does not allocate again when a claimed address is still absent" $ withProvisioning $ \l c transport count -> do
      let lost wallet method params=if method=="getnewaddress" then reject "rpc_transport_unknown_outcome" else orderNative transport wallet method params
      createCustomerOrderWith transport{orderNative=lost} c l cap req `shouldThrow` isError "rpc_transport_unknown_outcome"
      createCustomerOrderWith transport c l cap req `shouldThrow` isError "native_allocation_unresolved"
      readIORef count `shouldReturn` 0
    it "never treats malformed or ambiguous label reads as permission to allocate" $ withProvisioning $ \l c transport count -> do
      let values=[Null,object [],object ["one" .= object ["purpose" .= ("receive"::Text)],"two" .= object ["purpose" .= ("receive"::Text)]]]
      forM_ (zip [1::Int ..] values) $ \(i,value) -> do
        let bad wallet method params=if method=="getaddressesbylabel" then pure value else orderNative transport wallet method params
        createCustomerOrderWith transport{orderNative=bad} c l cap req{idempotencyKey="ambiguous-"<>T.pack(show i)}
          `shouldThrow` isError "native_allocation_ambiguous"
      readIORef count `shouldReturn` 0
    it "keeps an invalid address reply hidden until its wallet binding can be verified" $ withProvisioning $ \l c transport count -> do
      let bad wallet method params=do
            value<-orderNative transport wallet method params
            pure (if method=="getaddressinfo" then setPath ["ismine"] (Bool False) value else value)
      createCustomerOrderWith transport{orderNative=bad} c l cap req `shouldThrow` isError "native_allocation_policy_mismatch"
      prior<-findOrder l c cap req >>= maybe (fail "missing order") pure
      depositInstruction <$> exposeOrder l False cap (orderId prior) `shouldReturn` Nothing
      _<-createCustomerOrderWith transport c l cap req
      readIORef count `shouldReturn` 1
    it "retains the allocation claim across closing and reopening the actual SQLite ledger" $ withDir $ \dir -> do
      let c=cfg dir
      (transport,count)<-provisioningTransport c
      let lost wallet method params=do
            value<-orderNative transport wallet method params
            if method=="getnewaddress" then reject "rpc_transport_unknown_outcome" else pure value
      prior<-withLedger (dbPath c) (fingerprint c) $ \l -> do
        fundAllocation l "provisioning-tokens" Wrapped "float" (amt 1000000)
        fundAllocation l "provisioning-sol" Sol "operating" (amt 100000)
        fundAllocation l "provisioning-native" Native "operating" (amt 100000)
        freshScans l 100
        resumeAfterChecks l
        createCustomerOrderWith transport{orderNative=lost} c l cap req `shouldThrow` isError "rpc_transport_unknown_outcome"
        findOrder l c cap req >>= maybe (fail "missing durable order") pure
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        available <$> readiness l `shouldReturn` False
        resumeAfterChecks l
        createCustomerOrderWith transport c l cap req `shouldThrow` isError "custody_not_reconciled"
        freshScans l 100
        restored<-createCustomerOrderWith transport c l cap req
        orderId restored `shouldBe` orderId prior
        deadline restored `shouldBe` deadline prior
        readIORef count `shouldReturn` 1
    it "prevents duplicate addresses and reservations under concurrent request retries" $ withProvisioning $ \l c transport count -> do
      let run=try (createCustomerOrderWith transport c l cap req) :: IO (Either BridgeError OrderView)
      results<-mapConcurrently (const run) [1..20::Int]
      length [o | Right o<-results] `shouldSatisfy` (>0)
      readIORef count `shouldReturn` 1
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM orders" :: IO [Only Int]) `shouldReturn` [Only 1]
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM reservations" :: IO [Only Int]) `shouldReturn` [Only 1]
    it "records the address but hides it if intake pauses during the node call" $ withProvisioning $ \l c transport count -> do
      let stopping wallet method params=do
            result<-orderNative transport wallet method params
            when (method=="getnewaddress") $ pause l "fixture-pause-during-allocation"
            pure result
      createCustomerOrderWith transport{orderNative=stopping} c l cap req `shouldThrow` isError "intake_paused"
      order<-findOrder l c cap req >>= maybe (fail "missing order") pure
      depositInstruction order `shouldBe` Just "fixture-receive-1"
      depositInstruction <$> exposeOrder l False cap (orderId order) `shouldReturn` Nothing
      readIORef count `shouldReturn` 1
    it "requires actual backup acknowledgment before first exposure and rechecks the deadline after backup" $ withProvisioning $ \l c transport count -> do
      let canonical=c{backupRequired=True}
      createCustomerOrderWith transport canonical l cap req `shouldThrow` isError "backup_pending"
      prior<-findOrder l c cap req >>= maybe (fail "missing order") pure
      depositInstruction <$> exposeOrder l True cap (orderId prior) `shouldReturn` Nothing
      now<-newIORef (100::Int64)
      let delayed=transport{orderClock=readIORef now,orderBackup= \n->acknowledgeBackup l n "fixture-backup" >> writeIORef now 401 >> freshScans l 401}
      createCustomerOrderWith delayed canonical l cap req `shouldThrow` isError "deposit_window_closed"
      depositInstruction <$> exposeOrder l True cap (orderId prior) `shouldReturn` Nothing
      readIORef count `shouldReturn` 1
    it "recovers a late address without reopening an expired quote or exposing it" $ withProvisioning $ \l c transport count -> do
      let lost wallet method params=do
            result<-orderNative transport wallet method params
            if method=="getnewaddress" then reject "rpc_transport_unknown_outcome" else pure result
      createCustomerOrderWith transport{orderNative=lost} c l cap req `shouldThrow` isError "rpc_transport_unknown_outcome"
      freshScans l 1001
      createCustomerOrderWith transport{orderClock=pure 1001} c l cap req `shouldThrow` isError "deposit_window_closed"
      order<-findOrder l c cap req >>= maybe (fail "missing order") pure
      status order `shouldBe` "ExpiredUnfunded"
      depositInstruction order `shouldBe` Just "fixture-receive-1"
      depositInstruction <$> exposeOrder l False cap (orderId order) `shouldReturn` Nothing
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
      readIORef count `shouldReturn` 1
    it "binds a deterministic redemption memo without allocating a native address" $ withProvisioning $ \l c transport count -> do
      let redeem=OrderRequest WrappedToNative (amt 10000) "fixture-native-recipient" "fixture-solana-owner" (Just "fixture-solana-owner") "redemption-provision"
      order<-createCustomerOrderWith transport c l cap redeem
      depositInstruction order `shouldBe` Just (solanaDepositMemo c $ orderId order)
      readIORef count `shouldReturn` 0
    it "refuses an idempotency conflict before chain checks or allocation" $ withProvisioning $ \l c transport count -> do
      _<-createCustomerOrderWith transport c l cap req
      let noChecks=transport{orderAdmission=const $ reject "unexpected_admission",orderIdentity=reject "unexpected_identity"}
      createCustomerOrderWith noChecks c l cap req{recipient="changed"} `shouldThrow` isError "idempotency_conflict"
      readIORef count `shouldReturn` 1
  describe "Solana quote admission (offline official-SDK and RPC contracts)" $ do
    it "checks the exact net payout using only unsigned messages" $ withSolanaAdmission $ \c request call helper -> do
      result<-checkSolanaQuoteWith call helper c request
      checkedSolanaRole result `shouldBe` "payout"
      checkedSolanaAmount result `shouldBe` amt 3
      checkedSolanaOwner result `shouldBe` recipient request
      checkedSolanaFee result `shouldBe` amt 5000
      checkedSolanaRent result `shouldBe` amt 0
      checkedSolanaDepositFee result `shouldBe` Nothing
    it "admits an unfunded wrap recipient and missing ATA within the rent ceiling" $ withSolanaAdmission $ \c request call helper -> do
      let missing=changeAdmissionAccount (changeAdmissionAccount call 0 (const Null)) 1 (const Null)
      checkedSolanaRent <$> checkSolanaQuoteWith missing helper c request `shouldReturn` amt 1488440
    it "deducts only existing system-account lamports from ATA rent" $ withSolanaAdmission $ \c request call helper -> do
      let prefunded=changeAdmissionAccount call 1 (const $ systemContract 1000000)
      checkedSolanaRent <$> checkSolanaQuoteWith prefunded helper c request `shouldReturn` amt 488440
    it "checks gross redemption tokens, user deposit fees and the full-refund message" $ withSolanaAdmission $ \c request call helper -> do
      let redeem=redemptionAdmission request
          emptyCustody=changeAdmissionAccount call 2 (setPath ["data","parsed","info","tokenAmount","amount"] (String "0"))
      result<-checkSolanaQuoteWith emptyCustody helper c redeem
      checkedSolanaRole result `shouldBe` "refund"
      checkedSolanaAmount result `shouldBe` amt 3
      checkedSolanaDepositFee result `shouldBe` Just (amt 5000)
    it "rejects custody identities and mismatched source owners before any IO" $ withSolanaAdmission $ \c request _ _ -> do
      let noCall _ _=expectationFailure "RPC before owner binding" >> pure Null
          noHelper _=expectationFailure "helper before owner binding" >> reject "unexpected"
          check=checkSolanaQuoteWith noCall noHelper c
      forM_ [custodyOwner c,custodyAta c,mint c] $ \bad ->
        check request{recipient=bad} `shouldThrow` isError "bridge_owned_destination"
      check request{sourceOwner=Just $ recipient request} `shouldThrow` isError "invalid_solana_owner_binding"
      check (redemptionAdmission request){sourceOwner=Just $ custodyOwner c} `shouldThrow` isError "invalid_solana_owner_binding"
      check request{recipient=T.replicate 1000 "a"} `shouldThrow` isError "invalid_public_key"
    it "rejects token, nonce and executable accounts passed as wallet owners" $ withSolanaAdmission $ \c request call helper -> do
      let bad=[tokenContract c (recipient request),setPath ["data"] (toJSON ["AA==","base64"::Text]) (systemContract 10000)
            ,setPath ["executable"] (Bool True) (systemContract 10000)]
      forM_ bad $ \wallet -> checkSolanaQuoteWith (changeAdmissionAccount call 0 $ const wallet) helper c request
        `shouldThrow` isError "unsupported_system_account"
    it "rejects wrong-owner, frozen, delegated and extended recipient accounts" $ withSolanaAdmission $ \c request call helper -> do
      let info=["data","parsed","info"]
          bad=[(info<>["owner"],toJSON $ custodyOwner c),(info<>["state"],String "frozen")
            ,(info<>["delegate"],toJSON $ custodyOwner c),(info<>["closeAuthority"],toJSON $ custodyOwner c)
            ,(["data","space"],Number 166),(["owner"],String "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")]
      forM_ bad $ \(path,value) -> checkSolanaQuoteWith (changeAdmissionAccount call 1 $ setPath path value) helper c request
        `shouldThrow` (const True :: BridgeError -> Bool)
    it "rejects insufficient custody tokens or operating SOL" $ withSolanaAdmission $ \c request call helper -> do
      checkSolanaQuoteWith (changeAdmissionAccount call 2 $ setPath ["data","parsed","info","tokenAmount","amount"] (String "2")) helper c request
        `shouldThrow` isError "insufficient_custody_tokens"
      checkSolanaQuoteWith (changeAdmissionAccount call 3 $ const $ systemContract 4999) helper c request
        `shouldThrow` isError "insufficient_operating_sol"
    it "rejects missing/insufficient redemption tokens and insufficient customer SOL" $ withSolanaAdmission $ \c request call helper -> do
      let redeem=redemptionAdmission request
      checkSolanaQuoteWith (changeAdmissionAccount call 1 $ const Null) helper c redeem
        `shouldThrow` isError "token_account_policy_mismatch"
      checkSolanaQuoteWith (changeAdmissionAccount call 1 $ setPath ["data","parsed","info","tokenAmount","amount"] (String "2")) helper c redeem
        `shouldThrow` isError "insufficient_source_tokens"
      forM_ [Null,systemContract 4999] $ \wallet ->
        checkSolanaQuoteWith (changeAdmissionAccount call 0 $ const wallet) helper c redeem
          `shouldThrow` isError "insufficient_deposit_fee_sol"
    it "rejects fee/rent over budget and unavailable fee estimates" $ withSolanaAdmission $ \c request call helper -> do
      checkSolanaQuoteWith call helper c{maxSolFee=amt 4999} request `shouldThrow` isError "solana_fee_above_limit"
      checkSolanaQuoteWith (changeAdmissionAccount call 1 $ const Null) helper c{maxSolAccountRent=amt 1488439} request
        `shouldThrow` isError "solana_rent_above_limit"
      let noFee method params=if method=="getFeeForMessage" then pure (contextContract Null) else call method params
      checkSolanaQuoteWith noFee helper c request `shouldThrow` isError "solana_fee_unavailable"
    it "refuses stale/incomplete account responses and failed simulation" $ withSolanaAdmission $ \c request call helper -> do
      forM_ [("getMultipleAccounts",setPath ["context","slot"] (Number 99) (contextContract $ toJSON ([]::[Value])),"solana_context_too_old")
            ,("getMultipleAccounts",contextContract (toJSON ([]::[Value])),"solana_account_snapshot_incomplete")
            ,("simulateTransaction",contextContract (object ["err" .= ("fixture-error"::Text)]),"solana_simulation_failed")] $ \(method,value,err) -> do
        let altered name params=if name==method then pure value else call name params
        checkSolanaQuoteWith altered helper c request `shouldThrow` isError err
    it "rejects signed or altered preview bytes before account reads/simulation" $ withSolanaAdmission $ \c request call helper -> do
      let badHelper r=do
            reply<-helper r
            bytes<-either fail pure (B64.decode $ TE.encodeUtf8 $ replyTransaction reply)
            pure reply{replyTransaction=TE.decodeUtf8 $ B64.encode (BS.take 1 bytes<>BS.singleton 1<>BS.drop 2 bytes)}
          noAccounts method params=if method=="getMultipleAccounts" then expectationFailure "account read after invalid preview" >> pure Null else call method params
      checkSolanaQuoteWith noAccounts badHelper c request `shouldThrow` isError "signature_shape_mismatch"
    it "rechecks the blockhash after simulation" $ withSolanaAdmission $ \c request call helper -> do
      simulated<-newIORef False
      let aging method params=do
            when (method=="simulateTransaction") $ writeIORef simulated True
            done<-readIORef simulated
            if method=="getBlockHeight" && done then pure (Number 970) else call method params
      checkSolanaQuoteWith aging helper c request `shouldThrow` isError "solana_blockhash_window_too_short"
  describe "token account policy (captured finalized Devnet accounts)" $ do
    it "accepts the real eight-decimal custody balance" $ do
      (c,account)<-capturedCustodyAccount
      inspectTokenAccount (mint c) (custodyOwner c) account `shouldBe` Right (amt 100000000000)
    it "rejects owner/mint changes, delegates, close authorities, frozen and extended accounts" $ do
      (c,account)<-capturedCustodyAccount
      let info=["data","parsed","info"]
          mutations=[(["owner"],String "wrong"),(["executable"],Bool True),(["data","space"],Number 166)
            ,(info<>["owner"],String "wrong"),(info<>["mint"],String "wrong")
            ,(info<>["delegate"],toJSON $ custodyOwner c),(info<>["closeAuthority"],toJSON $ custodyOwner c)
            ,(info<>["state"],String "frozen"),(info<>["isNative"],Bool True)
            ,(info<>["tokenAmount","decimals"],Number 9)]
      forM_ mutations $ \(path,value) ->
        inspectTokenAccount (mint c) (custodyOwner c) (setPath path value account) `shouldBe` Left "token_account_policy_mismatch"
  describe "durable send orchestration (offline RPC contracts)" $ do
    it "backs up BroadcastIntent and rechecks the source before sending the exact saved bytes" $ withSendFixture $ \l c _ attempt transport -> do
      sourceReads<-newIORef (0::Int)
      let native wallet method params=do
            if method=="gettransaction" then modifyIORef' sourceReads (+1) else pure ()
            paymentNative transport wallet method params
          backup seqNo=do
            map attemptState <$> pendingAttempts l `shouldReturn` ["broadcast_intent"]
            readIORef sourceReads `shouldReturn` 1
            acknowledgeBackup l seqNo "fixture-remote-snapshot"
          sol method params=if method=="sendTransaction" then do
            readIORef sourceReads `shouldReturn` 2
            case params of String raw:_->raw `shouldBe` attemptBytes attempt; _->expectationFailure "missing bytes"
            attemptBytes <$> authorizeRecordedSend l True (attemptId attempt) `shouldReturn` attemptBytes attempt
            pure (toJSON $ attemptId attempt)
            else paymentSolana transport method params
      settleAttemptWith transport{paymentNative=native,paymentSolana=sol,paymentBackup=backup} c{backupRequired=True} l attempt `shouldReturn` "submitted"
      map attemptState <$> pendingAttempts l `shouldReturn` ["broadcast_intent"]
      readCheckpoint l "Native" `shouldReturn` Just "cursor"
    it "does not send when a backup callback returns without acknowledging coverage" $ withSendFixture $ \l c _ attempt transport -> do
      let sol method params=if method=="sendTransaction" then expectationFailure "sent without backup" >> pure Null else paymentSolana transport method params
      settleAttemptWith transport{paymentSolana=sol,paymentBackup=const $ pure ()} c{backupRequired=True} l attempt `shouldThrow` isError "backup_pending"
      map attemptState <$> pendingAttempts l `shouldReturn` ["broadcast_intent"]
    it "retains signed bytes and reservations if the source loses eligibility during backup" $ withSendFixture $ \l c ob attempt transport -> do
      depth<-newIORef 1
      let native wallet method params=readIORef depth >>= \n -> sourceNativeContract n wallet method params
          backup seqNo=acknowledgeBackup l seqNo "fixture-backup" >> writeIORef depth 0
          sol method params=if method=="sendTransaction" then expectationFailure "sent after reorg" >> pure Null else paymentSolana transport method params
      settleAttemptWith transport{paymentNative=native,paymentSolana=sol,paymentBackup=backup} c{backupRequired=True} l attempt `shouldThrow` isError "source_not_eligible"
      map attemptBytes <$> pendingAttempts l `shouldReturn` [attemptBytes attempt]
      createRefund l (obligationDeposit ob) `shouldThrow` isError "refundable_deposit_not_found"
      ledgerAction l (\db->query_ db "SELECT released FROM fee_reservations" :: IO [Only Bool]) `shouldReturn` [Only False]
    it "retries identical bytes after an unknown send response without another signature" $ withSendFixture $ \l c _ attempt transport -> do
      sent<-newIORef ([]::[Text])
      let sol method params=if method=="sendTransaction" then do
            case params of String raw:_->modifyIORef' sent (<>[raw]); _->expectationFailure "missing bytes"
            reject "fixture_lost_send_response"
            else paymentSolana transport method params
          rpcTransport=transport{paymentSolana=sol}
      settleAttemptWith rpcTransport c l attempt `shouldReturn` "broadcast_uncertain"
      [saved]<-pendingAttempts l
      settleAttemptWith rpcTransport c l saved `shouldReturn` "broadcast_uncertain"
      readIORef sent `shouldReturn` [attemptBytes attempt,attemptBytes attempt]
      pendingPreparations l `shouldReturn` []
    it "does not treat missing history or an expired blockhash as permission to replace" $ withSendFixture $ \l c _ attempt transport -> do
      let sol method params=if method=="getBlockHeight" then pure (Number 1100) else paymentSolana transport method params
      settleAttemptWith transport{paymentSolana=sol} c l attempt `shouldThrow` isError "solana_expiry_history_required"
      map attemptBytes <$> pendingAttempts l `shouldReturn` [attemptBytes attempt]
      available <$> readiness l `shouldReturn` False
    it "requires review if a signed-only transaction is observed as processed" $ withSendFixture $ \l c _ attempt transport -> do
      let sol method params=if method=="getSignatureStatuses" then pure $ contextContract $ toJSON [object ["confirmationStatus" .= ("processed"::Text)]] else paymentSolana transport method params
      settleAttemptWith transport{paymentSolana=sol} c l attempt `shouldThrow` isError "unrecorded_broadcast_observed"
    it "reconciles finalized success while paused without broadcasting again" $ withSendFixture $ \l c ob attempt transport -> do
      _<-markBroadcastIntent l (attemptId attempt)
      [saved]<-pendingAttempts l
      signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy saved)
      proof<-codecSettlementProof c signed True
      pause l "fixture-restart"
      let sol method _=if method=="getTransaction" then pure proof else expectationFailure "unexpected send/status RPC" >> pure Null
      settleAttemptWith transport{paymentSolana=sol} c l saved `shouldReturn` "settled"
      pendingAttempts l `shouldReturn` []
      status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "Paid"
      available <$> readiness l `shouldReturn` False
    it "books only the verified fee on finalized failure and retains customer principal" $ withSendFixture $ \l c ob attempt transport -> do
      _<-markBroadcastIntent l (attemptId attempt)
      [saved]<-pendingAttempts l
      signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy saved)
      proof<-codecSettlementProof c signed False
      let sol method _=if method=="getTransaction" then pure proof else expectationFailure "unexpected RPC" >> pure Null
      settleAttemptWith transport{paymentSolana=sol} c l saved `shouldReturn` "failed"
      status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
      ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings WHERE asset='Native' AND account='principal'" :: IO [Only Int64]) `shouldReturn` [Only 4]
      obligationAmount <$> createRefund l (obligationDeposit ob) `shouldReturn` 4
  describe "conclusive Solana expiry (offline recovery contracts)" $ do
    it "requires finalized absence on both complete account histories and every configured provider" $ withSendFixture $ \_ c _ attempt transport -> do
      signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy attempt)
      let configured=expiryConfig c
          call=expiryContract configured
      proof<-solanaExpiryEvidence transport{paymentSolana=call,paymentVerifier=Just call} configured signed
      proof `shouldSatisfy` (/=Nothing)
      let behind method params=if method=="getBlockHeight" then pure (Number 1000) else call method params
      solanaExpiryEvidence transport{paymentSolana=call,paymentVerifier=Just behind} configured signed
        `shouldThrow` isError "expiry_provider_behind"
      solanaExpiryEvidence transport{paymentSolana=behind} configured signed `shouldReturn` Nothing
    it "refuses missing history, observed signatures, valid blockhashes, old contexts and wrong identities" $ withSendFixture $ \_ c _ attempt transport -> do
      signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy attempt)
      let configured=expiryConfig c
          call=expiryContract configured
          changed target value method params=if method==target then pure value else call method params
          sigRow=object ["signature" .= attemptId attempt,"slot" .= (110::Int),"err" .= String "failed","confirmationStatus" .= ("finalized"::Text)]
          history method params=if method=="getSignaturesForAddress" then do
            original<-call method params >>= parseValue parseJSON :: IO [Value]
            pure (toJSON $ sigRow:original)
            else call method params
      forM_ [(changed "getSignaturesForAddress" (toJSON ([]::[Value])),"solana_history_gap")
            ,(changed "getTransaction" (object ["present" .= True]),"expired_transaction_observed")
            ,(changed "getSignatureStatuses" (contextContract $ toJSON [object ["confirmationStatus" .= ("processed"::Text)]]),"expired_signature_observed")
            ,(changed "isBlockhashValid" (contextContract $ Bool True),"blockhash_still_valid")
            ,(changed "isBlockhashValid" (object ["context" .= object ["slot" .= (99::Int)],"value" .= False]),"solana_context_too_old")
            ,(changed "getGenesisHash" (String "wrong"),"expiry_wrong_genesis")
            ,(history,"expired_signature_in_history")] $ \(bad,code) ->
        solanaExpiryEvidence transport{paymentSolana=bad} configured signed `shouldThrow` isError code
      let canonical=configured{profile=CanonicalBeta}
      solanaExpiryEvidence transport{paymentSolana=expiryContract canonical} canonical signed
        `shouldThrow` isError "independent_rpc_required"
    it "retires an expired attempt once while preserving principal, old bytes, and replacement barriers" $ withSendFixture $ \l c ob attempt transport -> do
      let configured=expiryConfig c
          verified=transport{paymentSolana=expiryContract configured}
      recordExpiryOrigins l configured
      pause l "fixture-restart"
      settleAttemptWith verified configured l attempt `shouldReturn` "expired"
      available <$> readiness l `shouldReturn` False
      pendingAttempts l `shouldReturn` []
      pendingPreparations l `shouldReturn` []
      ledgerAction l (\db->query_ db "SELECT signed_bytes FROM attempts" :: IO [Only Text]) `shouldReturn` [Only $ attemptBytes attempt]
      ledgerAction l (\db->query_ db "SELECT phase FROM reservations" :: IO [Only Text]) `shouldReturn` [Only "payment"]
      ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings WHERE asset='Native' AND account='principal'" :: IO [Only Int64]) `shouldReturn` [Only 4]
      ledgerAction l (\db->query_ db "SELECT released FROM fee_reservations" :: IO [Only Bool]) `shouldReturn` [Only True]
      [Only proof]<-ledgerAction l (\db->query_ db "SELECT proof_json FROM solana_expiries" :: IO [Only Text])
      recordSolanaExpiry l attempt proof
      recordSolanaExpiry l attempt "changed proof" `shouldThrow` isError "expiry_evidence_conflict"
      readyObligations l `shouldReturn` []
      resumeAfterChecks l
      beginPreparation l c ob "Solana" (attemptFeeLimit attempt) "new-policy" `shouldThrow` isError "obligation_not_ready"
      approveSolanaRetryWith verified configured l (attemptId attempt) "operator retry" `shouldThrow` isError "pause_before_operator_action"
      pause l "operator-action"
      approveSolanaRetryWith verified configured l (attemptId attempt) "operator retry"
      approveSolanaRetryWith verified{paymentIdentity=expectationFailure "duplicate approval performed chain IO"} configured l (attemptId attempt) "operator retry"
      approveSolanaRetryWith verified configured l (attemptId attempt) "changed reason" `shouldThrow` isError "retry_approval_conflict"
      available <$> readiness l `shouldReturn` False
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM solana_retry_approvals" :: IO [Only Int]) `shouldReturn` [Only 1]
      resumeAfterChecks l
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 3000000
      testAttempt l c{maxSolDailyCost=amt 1} ob "Solana" "unbudgeted-replacement" "bytes" "new-policy" (attemptFeeLimit attempt) Nothing
        `shouldThrow` isError "operating_daily_limit"
      pendingPreparations l `shouldReturn` []
      testAttempt l c ob "Solana" "replacement" "new-fixture-bytes" "new-policy" (attemptFeeLimit attempt) Nothing
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 890000
      ledgerAction l (\db->query_ db "SELECT generation,retired_txid FROM preparations ORDER BY generation" :: IO [(Int,Maybe Text)])
        `shouldReturn` [(0,Just $ attemptId attempt),(1,Nothing)]
      map attemptId <$> pendingAttempts l `shouldReturn` ["replacement"]
      createRefund l (obligationDeposit ob) `shouldThrow` isError "refund_would_race_payment"
      markBroadcastIntent l (attemptId attempt) `shouldThrow` isError "attempt_not_sendable"
      _<-markBroadcastIntent l "replacement"
      authorizeRecordedSend l True "replacement" `shouldThrow` isError "backup_pending"
      recordSettlement l (attemptId attempt) (PaymentCosts (amt 5000) (amt 0)) "contradictory late proof" `shouldThrow` isError "settlement_not_expected"
    it "preserves ambiguous broadcast history before authorizing a new preparation" $ withSendFixture $ \l c _ attempt transport -> do
      sequenceNumber<-markBroadcastIntent l (attemptId attempt)
      [saved]<-pendingAttempts l
      recordExpiryOrigins l (expiryConfig c)
      settleAttemptWith transport{paymentSolana=expiryContract (expiryConfig c)} (expiryConfig c) l saved `shouldReturn` "expired"
      ledgerAction l (\db->query_ db "SELECT critical_sequence FROM attempts" :: IO [Only Int64]) `shouldReturn` [Only sequenceNumber]
      ledgerAction l (\db->query_ db "SELECT critical_sequence FROM solana_expiries" :: IO [Only Int64]) `shouldReturn` [Only $ sequenceNumber+1]
      attemptBytes saved `shouldBe` attemptBytes attempt
    it "does not permit a changed configured history origin to retire a real intent" $ withSendFixture $ \l c _ attempt transport -> do
      settleAttemptWith transport{paymentSolana=expiryContract (expiryConfig c)} (expiryConfig c) l attempt
        `shouldThrow` isError "expiry_scan_origin_mismatch"
      map attemptId <$> pendingAttempts l `shouldReturn` [attemptId attempt]
    it "requires durable operator approval even if an expired obligation is made ready by a caller" $ withSendFixture $ \l c ob attempt transport -> do
      let configured=expiryConfig c
      recordExpiryOrigins l configured
      settleAttemptWith transport{paymentSolana=expiryContract configured} configured l attempt `shouldReturn` "expired"
      ledgerAction l $ \db->execute db "UPDATE obligations SET status='ready' WHERE id=?" (Only $ obligationId ob)
      beginPreparation l c ob "Solana" (attemptFeeLimit attempt) "new-policy" `shouldThrow` isError "solana_retry_not_authorized"
      pendingPreparations l `shouldReturn` []
    it "rechecks source eligibility before approving a replacement" $ withSendFixture $ \l c _ attempt transport -> do
      let configured=expiryConfig c
          verified=transport{paymentSolana=expiryContract configured}
      recordExpiryOrigins l configured
      settleAttemptWith verified configured l attempt `shouldReturn` "expired"
      pause l "operator-action"
      approveSolanaRetryWith verified{paymentNative=sourceNativeContract 0} configured l (attemptId attempt) "retry after expiry"
        `shouldThrow` isError "source_not_eligible"
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM solana_retry_approvals" :: IO [Only Int]) `shouldReturn` [Only 0]
      readyObligations l `shouldReturn` []
    it "does not revive an expired conversion after a refund has been authorized" $ withSendFixture $ \l c _ attempt transport -> do
      let configured=expiryConfig c
          verified=transport{paymentSolana=expiryContract configured}
      recordExpiryOrigins l configured
      settleAttemptWith verified configured l attempt `shouldReturn` "expired"
      _<-createRefund l ("native:"<>T.replicate 64 "a"<>":0")
      pause l "operator-action"
      approveSolanaRetryWith verified configured l (attemptId attempt) "retry after expiry" `shouldThrow` isError "solana_retry_not_expected"
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM solana_retry_approvals" :: IO [Only Int]) `shouldReturn` [Only 0]
  describe "native confirmation evidence (captured bytes and offline RPC contracts)" $ do
    it "requires the exact saved bytes and a confirmed active-chain anchor" $ do
      fixtureValue<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
      (plan,previous,fee,tx)<-nativeFixture
      raw<-fieldValue "raw" fixtureValue
      decoded<-fieldValue "decoded" fixtureValue
      let signed=NativeSigned raw tx plan previous fee
          anchor=T.replicate 64 "b"
          walletValue=object ["txid" .= nativeTxid tx,"hex" .= raw,"decoded" .= (decoded::Value)
            ,"fee" .= Number (scientific (negate $ toInteger $ units fee) (-8))
            ,"confirmations" .= (3::Int),"walletconflicts" .= ([]::[Text]),"blockhash" .= anchor]
          call _ method _=case method of
            "gettransaction"->pure walletValue
            "getblockheader"->pure $ object ["hash" .= anchor,"height" .= (123::Int),"confirmations" .= (3::Int)]
            "getblockhash"->pure (toJSON anchor)
            _->expectationFailure "unexpected native RPC" >> pure Null
      observeNativePayment call signed >>= \result -> case result of
        PaymentConfirmed costs _->costs `shouldBe` PaymentCosts fee (amt 0)
        _->expectationFailure "expected confirmed payment"
      let fork wallet method params=if method=="getblockhash" then pure (String $ T.replicate 64 "c") else call wallet method params
      observeNativePayment fork signed `shouldThrow` isError "native_settlement_not_canonical"
      let changed wallet method params=if method=="gettransaction" then pure (setPath ["hex"] (String "00") walletValue) else call wallet method params
      observeNativePayment changed signed `shouldThrow` isError "native_settlement_evidence_mismatch"
  describe "Solana settlement evidence (captured finalized public Devnet payments)" $ do
    forM_ ["existing","new"] $ \kind -> it ("validates exact bytes/units and actual costs for "<>kind<>" recipient ATA") $ do
      (c,signed,proof,outcome)<-capturedSolanaPayment kind
      verifySolanaOutcome c signed proof `shouldBe` Right outcome
      outcomeSucceeded outcome `shouldBe` True
      outcomeFee outcome `shouldBe` amt 5000
      outcomeRent outcome `shouldBe` amt (if kind=="new" then 1488440 else 0)
    it "rejects altered message/signature/slot/costs and missing token evidence" $ do
      (c,signed,proof,_)<-capturedSolanaPayment "new"
      let mutations=[(["slot"],Number 0),(["transaction","signatures"],toJSON ["wrong"::Text])
            ,(["transaction","message","recentBlockhash"],String "wrong")
            ,(["transaction","message","header","numRequiredSignatures"],Number 2)
            ,(["meta","fee"],Number 4999),(["meta","preBalances"],toJSON ([]::[Int]))
            ,(["meta","preTokenBalances"],toJSON ([]::[Value]))
            ,(["meta","postTokenBalances"],toJSON ([]::[Value]))]
      forM_ mutations $ \(path,value) -> verifySolanaOutcome c signed (setPath path value proof)
        `shouldBe` Left "solana_settlement_evidence_mismatch"
    it "rejects costs above the saved rent cap and a changed deployment" $ do
      (c,signed,proof,_)<-capturedSolanaPayment "new"
      let lowered=signed{signedSolanaPlan=(signedSolanaPlan signed){solPlanRentLimit=amt 1}}
      verifySolanaOutcome c lowered proof `shouldBe` Left "solana_settlement_evidence_mismatch"
      verifySolanaOutcome c{deploymentId="changed"} signed proof `shouldBe` Left "saved_solana_policy_mismatch"
    it "uses saved ceilings to reconcile an existing payment after future limits are lowered" $ do
      (c,signed,proof,outcome)<-capturedSolanaPayment "new"
      verifySolanaOutcome c{maxSolFee=amt 1,maxSolAccountRent=amt 0} signed proof `shouldBe` Right outcome
    it "rejects a changed token delta or historical owner and contradictory failure metadata" $ do
      (c,signed,proof,_)<-capturedSolanaPayment "existing"
      rows<-fieldValue "meta" proof >>= fieldValue "postTokenBalances" :: IO [Value]
      let changed path value=setPath ["meta","postTokenBalances"] (toJSON $ map (setPath path value) rows) proof
      forM_ [changed ["uiTokenAmount","amount"] (String "4"),changed ["owner"] (String "wrong")
        ,setPath ["meta","err"] (String "fixture-failure") proof] $ \bad ->
          verifySolanaOutcome c signed bad `shouldBe` Left "solana_settlement_evidence_mismatch"
  describe "public/private Unix socket boundary" $ do
    it "uses the shared Servant contract and separate admin socket" $ withDir $ \dir -> do
      let c=cfg dir
      withAsync (runWorkerWith c (const $ pure ())) $ \_ -> do
        awaitFile (customerSocket c) 100
        awaitFile (adminSocket c) 100
        manager <- unixManager (customerSocket c)
        do
          let configCall :<|> createCall :<|> _ :<|> _ :<|> _ :<|> healthCall :<|> _ = client customerAPI
              env=mkClientEnv manager (BaseUrl Http "localhost" 80 "")
          configResult<-runClientM configCall env
          configResult `shouldSatisfy` either (const False) (const True)
          runClientM healthCall env `shouldReturn` Right (Availability True "process_running")
          rejected<-runClientM (createCall "Bearer invalid" req) env
          rejected `shouldSatisfy` either (const True) (const False)
          let adminHealth :<|> _ :<|> _ :<|> _ = client adminAPI
          wrongSocket<-runClientM adminHealth env
          wrongSocket `shouldSatisfy` either (const True) (const False)
        publicMode<-fileMode <$> getFileStatus (customerSocket c)
        adminMode<-fileMode <$> getFileStatus (adminSocket c)
        publicMode .&. 0o777 `shouldBe` 0o660
        adminMode .&. 0o777 `shouldBe` 0o600
    it "refuses a second worker on the same ledger" $ withFunded $ \_ c ->
      withLedger (dbPath c) (fingerprint c) (const $ pure ()) `shouldThrow` isError "worker_already_running"
  describe "historical Solana deposit evidence" $ do
    it "validates the captured real Devnet order deposit without current account lookups" $ do
      captured<-BS.readFile "test/fixtures/solana-devnet-order-deposit.json" >>= either fail pure . eitherDecodeStrict'
      binding<-fieldValue "binding" captured
      expected<-DepositBinding <$> fieldValue "signature" binding <*> fieldValue "owner" binding
        <*> fieldValue "mint" binding <*> fieldValue "custody" binding <*> fieldValue "custodyOwner" binding <*> fieldValue "memo" binding
      proof<-fieldValue "transaction" captured
      quantity<-fieldValue "expectedAmount" captured
      verified<-either (fail . T.unpack) pure (verifyDeposit expected proof)
      verifiedAmount verified `shouldBe` quantity
      verifiedSlot verified `shouldSatisfy` (>0)
    it "validates owner, mint, memo, signer and exact historical custody increase" $ do
      (binding,proof)<-depositFixture
      verifiedAmount <$> verifyDeposit binding proof `shouldBe` Right (amt 3)
      effectDelta <$> custodyEffect (boundSignature binding) (boundMint binding) (boundCustody binding) (boundCustodyOwner binding) proof `shouldBe` Right 3
      transactionMemo proof `shouldBe` Just (boundMemo binding)
    it "retains an unmatched balance increase even when automatic authorization fails" $ do
      (binding,proof)<-depositFixture
      verifyDeposit binding{boundMemo="different-order"} proof `shouldSatisfy` either (const True) (const False)
      effectDelta <$> custodyEffect (boundSignature binding) (boundMint binding) (boundCustody binding) (boundCustodyOwner binding) proof `shouldBe` Right 3
      custodyEffect (boundSignature binding) (boundMint binding) (boundCustody binding) "incorrect-owner" proof `shouldSatisfy` either (const True) (const False)
    it "resolves a version-zero custody address loaded from historical metadata" $ do
      (binding,proof)<-depositFixture
      versioned<-versionZeroFixture (boundCustody binding) proof
      verifiedAmount <$> verifyDeposit binding versioned `shouldBe` Right (amt 3)
      effectDelta <$> custodyEffect (boundSignature binding) (boundMint binding) (boundCustody binding) (boundCustodyOwner binding) versioned `shouldBe` Right 3
    it "rejects copied memos, wrong historical owners and wrong custody" $ do
      (binding,proof)<-depositFixture
      verifyDeposit binding{boundOwner="different-owner"} proof `shouldSatisfy` either (const True) (const False)
      verifyDeposit binding{boundMemo="copied"} proof `shouldSatisfy` either (const True) (const False)
      verifyDeposit binding{boundCustody="wrong-custody"} proof `shouldSatisfy` either (const True) (const False)
    it "cannot authorize a failed or unsupported-version transaction" $ do
      (binding,proof)<-depositFixture
      let setMetaError (Object p)=Object $ case KM.lookup "meta" p of
            Just (Object m)->KM.insert "meta" (Object (KM.insert "err" (String "failed") m)) p
            _->p
          setMetaError x=x
          setVersion (Object p)=Object(KM.insert "version" (Number 1) p)
          setVersion x=x
      verifyDeposit binding (setMetaError proof) `shouldSatisfy` either (const True) (const False)
      verifyDeposit binding (setVersion proof) `shouldSatisfy` either (const True) (const False)
  describe "official SDK wire fixtures (not network evidence)" $ do
    forM_ ["unsigned-three-units.json","signed-three-units.json"] $ \name -> it ("independently validates "<>name) $ do
      (expected,encoded)<-fixture name
      validateTransaction expected encoded `shouldSatisfy` either (const False) (const True)
      validateTransaction expected{expectedAmount=amt 2} encoded `shouldSatisfy` either (const True) (const False)
      validateTransaction expected{expectedMemo="copied-memo"} encoded `shouldSatisfy` either (const True) (const False)
    it "rejects corrupted signed bytes" $ do
      (expected,encoded)<-fixture "signed-three-units.json"
      bytes<-either fail pure (B64.decode $ TE.encodeUtf8 encoded)
      let mutated=BS.take 4 bytes<>BS.singleton ((BS.index bytes 4+1)`mod`255)<>BS.drop 5 bytes
      validateTransaction expected (TE.decodeUtf8 $ B64.encode mutated) `shouldBe` Left "invalid_signature"
 where
  valid n d = case makeQuote d (amt n) of
    Right q -> let f=toInteger (units (fee q)); b=feeBps d in units (net q)+units (fee q)==fromInteger n && f*10000 >= n*b && (f-1)*10000<n*b
    Left _ -> False
fixture :: FilePath -> IO (Expected,Text)
fixture name=do
  bytes<-BS.readFile ("test/fixtures"</>name)
  value<-either fail pure (eitherDecodeStrict' bytes)
  either fail pure $ parseEither (withObject "fixture" $ \o->do
    r<-o .: "reply"
    expected<-Expected <$> o .: "owner" <*> o .: "recipient" <*> o .: "mint" <*> r .: "source_ata" <*> r .: "destination_ata" <*> o .: "blockhash" <*> o .: "amount" <*> r .: "memo" <*> o .: "createAta" <*> o .: "signed"
    encoded<-r .: "transaction"
    pure (expected,encoded)) value

awaitFile :: FilePath -> Int -> IO ()
awaitFile _ 0 = fail "socket startup timed out"
awaitFile path tries = do
  present<-doesPathExist path
  if present then pure () else threadDelay 10000 >> awaitFile path (tries-1)

-- Re-index the contract fixture using the documented v0 loaded-address layout.
-- This tests decoding only; it is not a signed or submitted chain transaction.
versionZeroFixture :: Text -> Value -> IO Value
versionZeroFixture custody proof = do
  root<-parseValue (withObject "proof" pure) proof
  transaction<-fieldValue "transaction" proof
  tx<-parseValue (withObject "transaction" pure) transaction
  message<-fieldValue "message" transaction
  msg<-parseValue (withObject "message" pure) message
  keys<-fieldValue "accountKeys" message :: IO [Text]
  metaValue<-fieldValue "meta" proof
  meta<-parseValue (withObject "meta" pure) metaValue
  idx<-case [i | (i,k)<-zip [0..] keys,k==custody] of [i]->pure i; _->fail "missing custody"
  let static=[i | i<-[0..length keys-1],i/=idx]
      order=static<>[idx]
      remap old=case lookup old (zip order [0..]) of Just new->new::Int; Nothing->error "fixture index"
  instructions<-fieldValue "instructions" message :: IO [Value]
  rewritten<-mapM (\v -> do
    p<-fieldValue "programIdIndex" v
    accounts<-fieldValue "accounts" v
    dat<-fieldValue "data" v :: IO Text
    pure $ object ["programIdIndex" .= remap p,"accounts" .= map remap accounts,"data" .= dat]) instructions
  let changeBalances key=do
        rows<-fieldValue key metaValue :: IO [Value]
        mapM (\v -> do
          fields<-parseValue (withObject "balance" pure) v
          i<-fieldValue "accountIndex" v
          pure $ Object (KM.insert "accountIndex" (toJSON $ remap i) fields)) rows
  before<-changeBalances "preTokenBalances"
  after<-changeBalances "postTokenBalances"
  preLamports<-fieldValue "preBalances" metaValue :: IO [Int64]
  postLamports<-fieldValue "postBalances" metaValue :: IO [Int64]
  let newMsg=Object $ KM.insert "accountKeys" (toJSON $ map (keys!!) static) $ KM.insert "instructions" (toJSON rewritten) msg
      newMeta=Object $ KM.insert "loadedAddresses" (object ["writable" .= [custody],"readonly" .= ([]::[Text])])
        $ KM.insert "preTokenBalances" (toJSON before) $ KM.insert "postTokenBalances" (toJSON after)
        $ KM.insert "preBalances" (toJSON $ map (preLamports!!) order) $ KM.insert "postBalances" (toJSON $ map (postLamports!!) order) meta
  pure $ Object $ KM.insert "version" (Number 0) $ KM.insert "meta" newMeta
    $ KM.insert "transaction" (Object $ KM.insert "message" newMsg tx) root

-- Contract fixture generated from official SDK message bytes, not chain evidence.
-- No current getAccountInfo is available or needed: ownership comes from metadata.
depositFixture :: IO (DepositBinding,Value)
depositFixture=do
  (expected,encoded)<-fixture "unsigned-three-units.json"
  tx<-either (fail . T.unpack) pure (decodeTransaction encoded)
  case tx of
    Transaction _ (Message required signedReadonly unsignedReadonly keys blockhash instructions) _ -> do
      let keyAt i=base58 (keys!!i)
          tokenBalance i n=object ["accountIndex" .= i,"mint" .= expectedMint expected,"owner" .= (if keyAt i==expectedSource expected then expectedOwner expected else expectedRecipient expected),"uiTokenAmount" .= object ["amount" .= (n::Text),"decimals" .= (8::Int)]]
          indexOf key=case [i | (i,k)<-zip [0..] keys,base58 k==key] of [i]->i; _->error "missing fixture account"
          sourceIndex=indexOf (expectedSource expected)
          destIndex=indexOf (expectedDestination expected)
          sig="fixture-signature"
          proof=object ["slot" .= (123::Int),"version" .= ("legacy"::Text)
            ,"transaction" .= object ["signatures" .= [sig],"message" .= object ["accountKeys" .= map base58 keys,"recentBlockhash" .= base58 blockhash,"header" .= object ["numRequiredSignatures" .= required,"numReadonlySignedAccounts" .= signedReadonly,"numReadonlyUnsignedAccounts" .= unsignedReadonly],"instructions" .= [object ["programIdIndex" .= p,"accounts" .= as,"data" .= base58 dat] | Instruction p as dat<-instructions]]]
            ,"meta" .= object ["err" .= Null,"preTokenBalances" .= [tokenBalance sourceIndex "10",tokenBalance destIndex "0"],"postTokenBalances" .= [tokenBalance sourceIndex "7",tokenBalance destIndex "3"],"preBalances" .= replicate (length keys) (2039280::Int64),"postBalances" .= replicate (length keys) (2039280::Int64),"innerInstructions" .= ([]::[Value])]]
          binding=DepositBinding sig (expectedOwner expected) (expectedMint expected) (expectedDestination expected) (expectedRecipient expected) (expectedMemo expected)
      pure(binding,proof)

-- Transport-only fixtures: no validator, network, or acceptance result is faked.
solanaFixture :: IO (Config,SolanaPlan,HelperReply)
solanaFixture=do
  value<-BS.readFile "test/fixtures/signed-three-units.json" >>= either fail pure . eitherDecodeStrict'
  reply<-fieldValue "reply" value
  owner<-fieldValue "owner" value
  target<-fieldValue "recipient" value
  token<-fieldValue "mint" value
  hash<-fieldValue "blockhash" value
  let c=(cfg "/unused-codec-test"){deploymentId="codec-fixture",mint=token,custodyOwner=owner,custodyAta=replySource reply,maxSolFee=amt 10000,maxSolAccountRent=amt 2100000}
      plan=SolanaPlan (fingerprint c) target (amt 3) "order-1" (RecentBlockhash hash 1000 100) (maxSolFee c) (maxSolAccountRent c)
  pure(c,plan,reply)

contextContract :: Value -> Value
contextContract value=object ["context" .= object ["slot" .= (100::Int)],"value" .= value]

custodyNativeTip :: Text
custodyNativeTip=T.replicate 64 "d"

-- These explicit RPC fixtures are unit contracts, not substitute networks.
setupCustodyScans :: Ledger -> Config -> IO ()
setupCustodyScans l c=do
  previous<-readCheckpoint l "Native"
  commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 [] [])
  forM_ [("Solana",solanaHistoryStart c),("SolanaOperating",solanaOperatingHistoryStart c)] $ \(stream,configured)->do
    origin<-maybe (fail "missing fixture origin") pure configured
    old<-readCheckpoint l stream
    commitScan l (ScanBatch stream origin old origin 100 [] [ChainEvent origin "reference" "100" (object ["delta" .= ("0"::Text)])])

custodyContract :: Config -> (Integer,Integer,Integer) -> [(Text,Text)] -> PaymentTransport
custodyContract c (nativeUnits,wrapped,sol) heads=PaymentTransport native call Nothing (pure ())
  (const $ expectationFailure "custody reconciliation requested a backup")
 where
  native _ method _=case method of
    "getbalances"->pure $ object ["mine" .= object ["trusted" .= nativeNumber (amt nativeUnits)
      ,"untrusted_pending" .= (0::Int),"immature" .= (0::Int)]
      ,"lastprocessedblock" .= object ["hash" .= custodyNativeTip,"height" .= (20000::Int)]]
    "getblockhash"->pure (toJSON custodyNativeTip)
    "listsinceblock"->pure $ object ["lastblock" .= custodyNativeTip,"transactions" .= ([]::[Value]),"removed" .= ([]::[Value])]
    _->expectationFailure ("unexpected custody native RPC: "<>T.unpack method) >> pure Null
  call method params=case (method,params) of
    ("getMultipleAccounts",[_,options])->do
      fieldValue "commitment" options `shouldReturn` ("finalized"::Text)
      let token=setPath ["data","parsed","info","tokenAmount","amount"] (toJSON $ T.pack $ show wrapped) (tokenContract c $ custodyOwner c)
      pure $ object ["context" .= object ["slot" .= (102::Int)],"value" .= [token,systemContract sol]]
    ("getSignaturesForAddress",[String address,options])->do
      fieldValue "minContextSlot" options `shouldReturn` (102::Int)
      fieldValue "limit" options `shouldReturn` (1::Int)
      let stream=if address==custodyAta c then "Solana" else "SolanaOperating"
          origin=if stream=="Solana" then solanaHistoryStart c else solanaOperatingHistoryStart c
      signature<-maybe (fail "missing fixture history") pure (case lookup stream heads of Just h->Just h; Nothing->origin)
      pure $ toJSON [object ["signature" .= signature,"slot" .= (if Just signature==origin then 100::Int else 101)
        ,"confirmationStatus" .= ("finalized"::Text),"err" .= Null]]
    ("getTransaction",_)->pure Null
    _->expectationFailure ("unexpected custody Solana RPC: "<>T.unpack method) >> pure Null

addCodecRent :: SolanaSigned -> Integer -> Value -> IO Value
addCodecRent _ 0 proof=pure proof
addCodecRent signed rent proof=do
  keys<-fieldValue "transaction" proof >>= fieldValue "message" >>= fieldValue "accountKeys"
  destination<-maybe (fail "codec destination missing") pure (elemIndex (replyDestination $ signedSolanaReply signed) keys)
  meta<-fieldValue "meta" proof
  before<-fieldValue "preBalances" meta :: IO [Integer]
  after<-fieldValue "postBalances" meta :: IO [Integer]
  let pre=[if i==destination then n-rent else n | (i,n)<-zip [0::Int ..] before]
      post=[if i==0 then n-rent else n | (i,n)<-zip [0::Int ..] after]
  pure $ setPath ["meta","preBalances"] (toJSON pre) $ setPath ["meta","postBalances"] (toJSON post) proof

freshScans :: Ledger -> Int64 -> IO ()
freshScans ledger now=do
  forM_ ["Native","Solana","SolanaOperating"] $ \chain -> do
    previous<-readCheckpoint ledger chain
    commitScan ledger (ScanBatch chain "fixture-scan-origin" previous "fixture-scan-tip" now [] [])
  -- Provisioning-only offline fixtures assume a successful custody check.
  -- Reconciliation itself is exercised separately with explicit RPC contracts.
  ledgerAction ledger $ \db -> execute db "UPDATE custody_check SET checked_revision=revision,checked_at=?,last_error=NULL" (Only now)

withProvisioning :: (Ledger -> Config -> OrderTransport -> IORef Int -> IO a) -> IO a
withProvisioning action=withFunded $ \l c -> do
  freshScans l 100
  (transport,count)<-provisioningTransport c
  action l c transport count

-- In-memory RPC contracts exercise sequencing, never chain acceptance. Runtime
-- construction uses the configured real node and both real admission adapters.
provisioningTransport :: Config -> IO (OrderTransport,IORef Int)
provisioningTransport c=do
  count<-newIORef (0::Int)
  addresses<-newIORef ([]::[(Text,Text)])
  let native wallet method params=do
        wallet `shouldBe` True
        case (method,params) of
          ("getwalletinfo",[]) -> pure $ object ["walletname" .= nativeWallet c,"descriptors" .= True
            ,"private_keys_enabled" .= True,"external_signer" .= False,"scanning" .= False]
          ("getaddressesbylabel",[String allocationLabel]) -> do
            entries<-readIORef addresses
            let found=[address | (l,address)<-entries,l==allocationLabel]
            if null found then reject "rpc_error_-11" else pure $ object
              [fromString (T.unpack address) .= object ["purpose" .= ("receive"::Text)] | address<-found]
          ("getnewaddress",[String allocationLabel,String "bech32"]) -> do
            n<-atomicModifyIORef' count (\old->(old+1,old+1))
            let address="fixture-receive-"<>T.pack(show n)
            atomicModifyIORef' addresses (\old->((allocationLabel,address):old,()))
            pure (toJSON address)
          ("getaddressinfo",[String address]) -> do
            entries<-readIORef addresses
            let labels=[allocationLabel | (allocationLabel,a)<-entries,a==address]
            pure $ object ["address" .= address,"labels" .= labels,"ismine" .= True,"solvable" .= True
              ,"ischange" .= False,"scriptPubKey" .= ("0014"<>T.replicate 40 "1")]
          _ -> expectationFailure ("unexpected provisioning RPC: "<>T.unpack method) >> pure Null
  pure (OrderTransport (pure 100) (const $ pure ()) (pure ()) native (const $ pure ()),count)

-- Generated by the pinned SDK test, with public deterministic codec keys.
-- These values are offline contract inputs, not a private validator or funding.
withSolanaAdmission :: (Config -> OrderRequest -> SolanaRPC -> (HelperRequest -> IO HelperReply) -> IO a) -> IO a
withSolanaAdmission action=do
  value<-BS.readFile "test/fixtures/admission-unsigned.json" >>= either fail pure . eitherDecodeStrict'
  deployment<-fieldValue "deploymentId" value
  token<-fieldValue "mint" value
  custody<-fieldValue "custodyOwner" value
  wallet<-fieldValue "wallet" value
  hash<-fieldValue "blockhash" value
  payout<-fieldValue "payout" value
  deposit<-fieldValue "deposit" value
  let c=(cfg "/unused-admission-test"){deploymentId=deployment,mint=token,custodyOwner=custody,custodyAta=replySource payout
        ,maxSolAccountRent=amt 2100000}
      request=OrderRequest NativeToWrapped (amt 4) wallet "fixture-native-refund" Nothing "fixture-admission"
      helper r=do
        helperAmount r `shouldBe` amt 3
        helperReference r `shouldBe` "quote-check"
        helperBlockhash r `shouldBe` hash
        (helperOwner r,helperRecipient r) `shouldBe` (if helperPayout r then (custody,wallet) else (wallet,custody))
        pure (if helperPayout r then payout else deposit)
      call method params=case (method,params) of
        ("getLatestBlockhash",_) -> pure $ contextContract $ object ["blockhash" .= hash,"lastValidBlockHeight" .= (1000::Int)]
        ("getBlockHeight",_) -> pure (Number 900)
        ("getMultipleAccounts",[addresses,options]) -> do
          addresses `shouldBe` toJSON [wallet,replyDestination payout,custodyAta c,custody]
          fieldValue "minContextSlot" options `shouldReturn` (100::Int)
          pure $ contextContract $ toJSON [systemContract 1000000,tokenContract c wallet,tokenContract c custody,systemContract 10000000]
        ("getFeeForMessage",[message,options]) -> do
          message `shouldSatisfy` (`elem` map (toJSON . replyMessage) [payout,deposit])
          fieldValue "minContextSlot" options `shouldReturn` (100::Int)
          pure $ contextContract $ Number 5000
        ("getMinimumBalanceForRentExemption",[Number 165,_]) -> pure (Number 1488440)
        ("simulateTransaction",[transaction,options]) -> do
          transaction `shouldSatisfy` (`elem` map (toJSON . replyTransaction) [payout,deposit])
          fieldValue "sigVerify" options `shouldReturn` False
          fieldValue "replaceRecentBlockhash" options `shouldReturn` False
          fieldValue "minContextSlot" options `shouldReturn` (100::Int)
          pure $ contextContract $ object ["err" .= Null]
        _ -> expectationFailure ("unexpected quote RPC: "<>T.unpack method) >> pure Null
  action c request call helper

redemptionAdmission :: OrderRequest -> OrderRequest
redemptionAdmission request=request{direction=WrappedToNative,input=amt 3,sourceOwner=Just $ recipient request
  ,refund=recipient request,recipient="fixture-native-recipient"}

changeAdmissionAccount :: SolanaRPC -> Int -> (Value -> Value) -> SolanaRPC
changeAdmissionAccount call index change method params=do
  result<-call method params
  if method/="getMultipleAccounts" then pure result else do
    accounts<-fieldValue "value" result :: IO [Value]
    pure $ setPath ["value"] (toJSON [if i==index then change a else a | (i,a)<-zip [0..] accounts]) result

systemContract :: Integer -> Value
systemContract lamports=object ["owner" .= ("11111111111111111111111111111111"::Text),"executable" .= False,"data" .= ["","base64"::Text],"lamports" .= lamports]
tokenContract :: Config -> Text -> Value
tokenContract c owner=object ["owner" .= tokenProgram,"executable" .= False,"data" .= object
  ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::Text),"info" .= object
    ["mint" .= mint c,"owner" .= owner,"state" .= ("initialized"::Text),"isNative" .= False
    ,"tokenAmount" .= object ["amount" .= ("100000000000"::Text),"decimals" .= (8::Int)]]]]]
solanaContract :: Config -> SolanaPlan -> Value -> SolanaRPC
solanaContract c plan destination method _=case method of
  "getLatestBlockhash" -> pure $ contextContract $ object ["blockhash" .= recentHash (solPlanRecent plan),"lastValidBlockHeight" .= (1000::Int)]
  "getBlockHeight" -> pure (Number 900)
  "getFeeForMessage" -> pure (contextContract $ Number 5000)
  "getMultipleAccounts" -> pure $ contextContract $ toJSON [tokenContract c (custodyOwner c),destination,systemContract 10000000]
  "getMinimumBalanceForRentExemption" -> pure (Number 1488440)
  "simulateTransaction" -> pure $ contextContract $ object ["err" .= Null]
  _ -> expectationFailure ("unexpected RPC in offline contract test: "<>T.unpack method) >> pure Null

withSolanaLedger :: (Ledger -> Config -> SolanaPlan -> HelperReply -> IO a) -> IO a
withSolanaLedger action=withDir $ \dir -> do
  (old,plan,reply)<-solanaFixture
  let c=old{dbPath=dir</>"private/ledger.sqlite"}
  withLedger (dbPath c) (fingerprint c) $ \l -> do
    fundAllocation l "fixture-tokens" Wrapped "float" (amt 10000)
    fundAllocation l "fixture-operating" Sol "operating" (amt 3000000)
    fundAllocation l "fixture-native-operating" Native "operating" (amt 10000)
    resumeAfterChecks l
    action l c plan reply
fundSolanaOrder :: Ledger -> Config -> SolanaPlan -> IO (OrderView,Obligation)
fundSolanaOrder l c plan=do
  o<-createOrder l c 100 cap req{input=amt 4,recipient=solPlanRecipient plan}
  bindInstruction l (orderId o) "fixture-address"
  let did="native:"<>T.replicate 64 "a"<>":0"
  observeDeposit l (Deposit did (Just $ orderId o) Native (amt 4) (T.replicate 64 "b") 1 True 100) "cursor"
  promoteDeposit l 110 did `shouldReturn` True
  obligations<-readyObligations l
  case obligations of [ob]->pure(o,ob); _->fail "expected one three-unit obligation"

-- Adapt only the terminal memo in the official SDK fixture. This known public
-- key is strictly for offline tests and must never be funded on any network.
codecReply :: Config -> HelperRequest -> HelperReply -> IO HelperReply
codecReply c request old=do
  body<-either fail pure (B64.decode $ TE.encodeUtf8 $ replyMessage old)
  let memo=helperMemo c request
      memoBytes=TE.encodeUtf8 memo
      oldMemo=TE.encodeUtf8 (replyMemo old)
  BS.length memoBytes `shouldSatisfy` (<128)
  BS.drop (BS.length body-BS.length oldMemo) body `shouldBe` oldMemo
  key<-case Ed.secretKey (BS.replicate 32 1) of CryptoPassed k->pure k; CryptoFailed _->fail "invalid test key"
  let message=BS.take (BS.length body-BS.length oldMemo-1) body<>BS.singleton (fromIntegral $ BS.length memoBytes)<>memoBytes
      signature=BA.convert (Ed.sign key (Ed.toPublic key) message)::BS.ByteString
  pure old{replyMemo=memo,replyMessage=TE.decodeUtf8 $ B64.encode message
    ,replySignature=Just $ base58 signature,replyTransaction=TE.decodeUtf8 $ B64.encode (BS.singleton 1<>signature<>message)}

capturedCustodyAccount :: IO (Config,Value)
capturedCustodyAccount=do
  captured<-BS.readFile "test/fixtures/solana-devnet-accounts.json" >>= either fail pure . eitherDecodeStrict'
  accounts<-fieldValue "accounts" captured >>= fieldValue "value" :: IO [Value]
  account<-case accounts of _:a:_->pure a; _->fail "missing captured custody"
  pure(cfg "/unused-real-account-parser-test",account)
setPath :: [Key] -> Value -> Value -> Value
setPath [] replacement _=replacement
setPath (key:rest) replacement (Object fields)=Object $ KM.insert key (setPath rest replacement $ maybe Null id $ KM.lookup key fields) fields
setPath _ _ _=error "missing test fixture field"

capturedSolanaPayment :: String -> IO (Config,SolanaSigned,Value,SolanaOutcome)
capturedSolanaPayment kind=do
  fixtureValue<-BS.readFile ("test/fixtures/solana-devnet-"<>kind<>"-payment.json") >>= either fail pure . eitherDecodeStrict'
  signed<-fieldValue "signed" fixtureValue
  proof<-fieldValue "transaction" fixtureValue
  outcome<-fieldValue "outcome" fixtureValue
  let c=(cfg "/unused-real-payment-parser-test"){deploymentId="l2l-devnet-local",nativeWallet="ecx-bridge-test"
        ,custodyAta="CKXz4AWgfRjw5YK17P64TgXuaci2QKAD7J1vZ9X2mNvT",maxSolFee=amt 10000}
  pure(c,signed,proof,outcome)

-- Entirely offline execution tests. Only the SDK's published deterministic
-- codec key is used; these fixtures are never sent to or counted as a network.
withSendFixture :: (Ledger -> Config -> Obligation -> Attempt -> PaymentTransport -> IO a) -> IO a
withSendFixture action=withSolanaLedger $ \l c plan reply -> do
  (_,ob)<-fundSolanaOrder l c plan
  _<-prepareSolanaWith (solanaContract c plan Null) (\r -> codecReply c r reply) c l ob
  [attempt]<-pendingAttempts l
  let sol method _=case method of
        "getTransaction"->pure Null
        "getSignatureStatuses"->pure (contextContract $ toJSON [Null])
        "getBlockHeight"->pure (Number 900)
        "sendTransaction"->pure (toJSON $ attemptId attempt)
        _->expectationFailure ("unexpected RPC: "<>T.unpack method) >> pure Null
      transport=PaymentTransport (sourceNativeContract 1) sol Nothing (pure ())
        (const $ expectationFailure "unexpected backup callback")
  action l c ob attempt transport

expiryConfig :: Config -> Config
expiryConfig c=c{solanaHistoryStart=Just $ base58 (BS.replicate 64 2),solanaOperatingHistoryStart=Just $ base58 (BS.replicate 64 3)}

recordExpiryOrigins :: Ledger -> Config -> IO ()
recordExpiryOrigins l c=forM_ [("Solana",solanaHistoryStart c),("SolanaOperating",solanaOperatingHistoryStart c)] $ \(chain,maybeAnchor)->do
  anchor<-maybe (fail "missing fixture origin") pure maybeAnchor
  commitScan l (ScanBatch chain anchor Nothing anchor 100 [] [])

expiryContract :: Config -> SolanaRPC
expiryContract c method params=case method of
  "getGenesisHash"->pure (toJSON $ solanaGenesis $ profile c)
  "getBlockHeight"->pure (Number 1100)
  "getSlot"->pure (Number 100)
  "isBlockhashValid"->pure (contextContract $ Bool False)
  "getTransaction"->pure Null
  "getSignatureStatuses"->pure (contextContract $ toJSON [Null])
  "getSignaturesForAddress"->do
    address<-case params of String a:_->pure a; _->fail "missing history address"
    origin<-maybe (fail "missing fixture origin") pure (if address==custodyAta c then solanaHistoryStart c else solanaOperatingHistoryStart c)
    pure $ toJSON [object ["signature" .= origin,"slot" .= (90::Int),"err" .= Null,"confirmationStatus" .= ("finalized"::Text)]]
  _->expectationFailure ("unexpected expiry RPC: "<>T.unpack method) >> pure Null

sourceNativeContract :: Int -> NativeRPC
sourceNativeContract depth _ method _=do
  let txid=T.replicate 64 "a"
      anchor=T.replicate 64 "b"
      script="0014"<>T.replicate 40 "1"
  case method of
    "gettransaction"->pure $ object ["txid" .= txid,"confirmations" .= depth,"blockhash" .= anchor
      ,"decoded" .= object ["txid" .= txid,"vout" .= [object ["n" .= (0::Int),"value" .= nativeNumber (amt 4),"scriptPubKey" .= object ["hex" .= script]]]]]
    "getaddressinfo"->pure $ object ["ismine" .= True,"scriptPubKey" .= script]
    "getblockheader"->pure $ object ["hash" .= anchor,"height" .= (123::Int),"confirmations" .= depth]
    "getblockhash"->pure (toJSON anchor)
    _->expectationFailure ("unexpected source RPC: "<>T.unpack method) >> pure Null

codecSettlementProof :: Config -> SolanaSigned -> Bool -> IO Value
codecSettlementProof c signed success=do
  let reply=signedSolanaReply signed
      plan=signedSolanaPlan signed
  Transaction _ (Message required signedReadonly readonly keys blockhash instructions) _ <-
    either (fail . T.unpack) pure (validateHelperReply c (solanaPayoutRequest c plan) reply)
  let addresses=map base58 keys
  src<-maybe (fail "missing codec source") pure (elemIndex (replySource reply) addresses)
  dst<-maybe (fail "missing codec destination") pure (elemIndex (replyDestination reply) addresses)
  let token i owner n=object ["accountIndex" .= i,"mint" .= mint c,"owner" .= owner
        ,"uiTokenAmount" .= object ["amount" .= T.pack(show (n::Int)),"decimals" .= (8::Int)]]
      balances=[if i==0 then 3000000 else 1488440::Int | i<-[0..length keys-1]]
      afterBalances=[if i==0 then n-5000 else n | (i,n)<-zip [0::Int ..] balances]
      tokens source destination=[token src (custodyOwner c) source,token dst (solPlanRecipient plan) destination]
  pure $ object ["slot" .= (101::Int),"version" .= ("legacy"::Text)
    ,"transaction" .= object ["signatures" .= [maybe "" id $ replySignature reply],"message" .= object
      ["header" .= object ["numRequiredSignatures" .= required,"numReadonlySignedAccounts" .= signedReadonly,"numReadonlyUnsignedAccounts" .= readonly]
      ,"accountKeys" .= addresses,"recentBlockhash" .= base58 blockhash
      ,"instructions" .= [object ["programIdIndex" .= p,"accounts" .= as,"data" .= base58 dat] | Instruction p as dat<-instructions]]]
    ,"meta" .= object ["err" .= (if success then Null else String "offline-fixture-failure"),"fee" .= (5000::Int)
      ,"preBalances" .= balances,"postBalances" .= afterBalances
      ,"preTokenBalances" .= tokens 10 0,"postTokenBalances" .= (if success then tokens 7 3 else tokens 10 0)]]

withDepositFixture :: (Ledger -> Config -> OrderView -> RecentBlockhash -> HelperReply -> SolanaRPC -> IO a) -> IO a
withDepositFixture action=withDir $ \dir -> do
  fixtureValue<-BS.readFile "test/fixtures/unsigned-three-units.json" >>= either fail pure . eitherDecodeStrict'
  owner<-fieldValue "owner" fixtureValue
  target<-fieldValue "recipient" fixtureValue
  token<-fieldValue "mint" fixtureValue
  hash<-fieldValue "blockhash" fixtureValue
  reply<-fieldValue "reply" fixtureValue
  let c=(cfg dir){deploymentId="codec-fixture",mint=token,custodyOwner=target,custodyAta=replyDestination reply}
      recent=RecentBlockhash hash 1000 100
      depositRequest=OrderRequest WrappedToNative (amt 3) "offline-native-recipient" owner (Just owner) "offline-deposit"
  withLedger (dbPath c) (fingerprint c) $ \l -> do
    fundAllocation l "fixture-native-float" Native "float" (amt 10000)
    fundAllocation l "fixture-sol-fees" Sol "operating" (amt 3000000)
    fundAllocation l "fixture-native-fees" Native "operating" (amt 10000)
    resumeAfterChecks l
    created<-createOrder l c 100 cap depositRequest
    bindInstruction l (orderId created) (solanaDepositMemo c $ orderId created)
    freshScans l 100
    _<-issueInstruction l c 100 cap (orderId created)
    order<-readOrder l cap (orderId created)
    let call method _=case method of
          "getLatestBlockhash"->pure $ contextContract $ object ["blockhash" .= hash,"lastValidBlockHeight" .= (1000::Int)]
          "getBlockHeight"->pure (Number 900)
          "getMultipleAccounts"->pure $ contextContract $ toJSON [tokenContract c owner,tokenContract c target,systemContract 1000000]
          "getFeeForMessage"->pure $ contextContract $ Number 5000
          _->expectationFailure ("unexpected deposit RPC: "<>T.unpack method) >> pure Null
    action l c order recent reply call

unsignedDepositReply :: Config -> HelperRequest -> HelperReply -> IO HelperReply
unsignedDepositReply c requested old=do
  body<-either fail pure (B64.decode $ TE.encodeUtf8 $ replyMessage old)
  Transaction _ (Message _ _ _ keys _ _) _<-either (fail . T.unpack) pure (decodeTransaction $ replyTransaction old)
  hash<-either (fail . T.unpack) pure (publicKey $ helperBlockhash requested)
  let memo=helperMemo c requested
      memoBytes=TE.encodeUtf8 memo
      oldMemo=TE.encodeUtf8 (replyMemo old)
      hashOffset=4+32*length keys
      freshHash=BS.take hashOffset body<>hash<>BS.drop (hashOffset+32) body
      message=BS.take (BS.length freshHash-BS.length oldMemo-1) freshHash<>BS.singleton (fromIntegral $ BS.length memoBytes)<>memoBytes
  BS.length memoBytes `shouldSatisfy` (<128)
  BS.drop (BS.length body-BS.length oldMemo) body `shouldBe` oldMemo
  pure old{replyMemo=memo,replyMessage=TE.decodeUtf8 $ B64.encode message,replySignature=Nothing
    ,replyTransaction=TE.decodeUtf8 $ B64.encode (BS.singleton 1<>BS.replicate 64 0<>message)}
