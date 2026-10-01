{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import Bridge.Types
import Bridge.Config
import Bridge.Ledger
import Bridge.SolanaMessage
import Bridge.SolanaDeposit
import Bridge.Solana (inspectTokenAccount)
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import qualified Data.Aeson.KeyMap as KM
import Bridge.Native (nativeAmount,nativeNumber)
import Bridge.NativePayment
import Bridge.Payment (prepareNativeWith,prepareSolanaWith)
import Bridge.RPC
import Bridge.API
import Bridge.Worker
import Bridge.Backup
import Bridge.Observer
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently,withAsync)
import Control.Exception (bracket,try,SomeException)
import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Base64 as B64
import Data.Int (Int64)
import Data.IORef
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
cfg dir = Config L2LSignetDevnet "unit-fixture" "http://127.0.0.1:29432" (dir</>"cookie") "fixture-wallet" 16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47" "https://api.devnet.solana.com" Nothing "Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM" "RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX" "11111111111111111111111111111111" (dir</>"private/ledger.sqlite") (dir</>"customer/api.sock") (dir</>"admin/api.sock") "/usr/bin/false" (dir</>"helper.json") (amt 2) (amt 1000000000000) 100 300 600 1 (amt 1000) (amt 1000) False Nothing (amt 2100000) Nothing
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
testAttempt :: Ledger -> Obligation -> Text -> Text -> Text -> Text -> Int64 -> Maybe Text -> IO ()
testAttempt l ob chain txid bytes policy limit point = do
  beginPreparation l ob chain limit "{\"fixture\":true}"
  storeAttempt l ob chain txid bytes policy limit point

nativeFixture :: IO (NativePlan,[NativePrevout],Amount,NativeTx)
nativeFixture = do
  value <- BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  plan <- fieldValue "plan" value
  previous <- fieldValue "previous" value
  fee <- fieldValue "fee" value
  decoded <- fieldValue "decoded" value >>= either (fail . T.unpack) pure . decodeNativeTx
  pure (plan,previous,fee,decoded)

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
      beginPreparation l ob "Solana" 5000 "fixture-policy"
      beginPreparation l ob "Solana" 5000 "fixture-policy"
      beginPreparation l ob "Solana" 6000 "fixture-policy" `shouldThrow` isError "preparation_conflict"
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
        [otherOb]->beginPreparation l otherOb "Solana" 5000 "other-policy" `shouldThrow` isError "destination_payment_unresolved"
        _->expectationFailure "expected one remaining ready obligation"
    it "retains an immutable unsigned draft after interruption and restart" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        fundAllocation l "float" Wrapped "float" (amt 1000000)
        fundAllocation l "fees" Sol "operating" (amt 10000)
        resumeAfterChecks l
        (_,ob)<-fundOrder l c
        beginPreparation l ob "Solana" 5000 "fixture-policy"
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
        resumeAfterChecks l
        (_,ob)<-fundOrder l c
        testAttempt l ob "Solana" "fixture-signature" "fixture-exact-bytes" "{}" 5000 Nothing
        _<-markBroadcastIntent l "fixture-signature"
        pure ()
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        available <$> readiness l `shouldReturn` False
        attempts<-pendingAttempts l
        map attemptBytes attempts `shouldBe` ["fixture-exact-bytes"]
        map attemptState attempts `shouldBe` ["broadcast_intent"]
        resumeAfterChecks l `shouldThrow` isError "unresolved_intents_require_review"
    it "cannot commit an intent without operating funds" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l ob "Solana" "fixture-signature" "bytes" "{}" 100001 Nothing `shouldThrow` isError "insufficient_fee_budget"
      pendingAttempts l `shouldReturn` []
    it "requires correct chain and database-bound obligation" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l ob "Native" "tx" "bytes" "{}" 1 Nothing `shouldThrow` isError "wrong_destination_chain"
      testAttempt l ob{obligationRecipient="attacker"} "Solana" "tx" "bytes" "{}" 1 Nothing `shouldThrow` isError "obligation_mismatch"
    it "keeps earned fees out of available source float and settles once" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l ob "Solana" "fixture-signature" "bytes" "{}" 5000 Nothing
      _<-markBroadcastIntent l "fixture-signature"
      recordSettlement l "fixture-signature" 5000 "fixture-finalized-proof"
      recordSettlement l "fixture-signature" 5000 "fixture-finalized-proof"
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1099800
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 900200
      pendingAttempts l `shouldReturn` []
    it "cannot authorize a first send after loss of source eligibility" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      testAttempt l ob "Solana" "tx" "bytes" "{}" 5000 Nothing
      observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId o) Native (input req) "reorg" 0 False 100) "reorg-cursor"
      markBroadcastIntent l "tx" `shouldThrow` isError "attempt_not_sendable"
      length <$> pendingAttempts l `shouldReturn` 1
    it "rechecks backup coverage and source eligibility after a recorded broadcast intent" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      testAttempt l ob "Solana" "tx" "exact-bytes" "{}" 5000 Nothing
      authorizeRecordedSend l True "tx" `shouldThrow` isError "broadcast_intent_required"
      sequenceNumber<-markBroadcastIntent l "tx"
      authorizeRecordedSend l True "tx" `shouldThrow` isError "backup_pending"
      acknowledgeBackup l sequenceNumber "fixture-covered-snapshot"
      attemptBytes <$> authorizeRecordedSend l True "tx" `shouldReturn` "exact-bytes"
      observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId o) Native (input req) "reorg" 0 False 100) "reorg-cursor"
      markBroadcastIntent l "tx" `shouldReturn` sequenceNumber
      authorizeRecordedSend l True "tx" `shouldThrow` isError "source_not_eligible"
      length <$> pendingAttempts l `shouldReturn` 1
  describe "refund principal and failed transaction fees" $ do
    it "refunds a confirmed partial deposit without consuming payout float" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      observeDeposit l (Deposit "partial:0" (Just $ orderId o) Native (amt 1000) "anchor" 1 True 100) "cursor"
      ob<-createRefund l "partial:0"
      obligationRecipient ob `shouldBe` refund req
      testAttempt l ob "Native" "refund-tx" "fixture-refund-bytes" "{}" 100 Nothing
      _<-markBroadcastIntent l "refund-tx"
      recordSettlement l "refund-tx" 100 "fixture-refund-proof"
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1000000
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
      status <$> readOrder l cap (orderId o) `shouldReturn` "Refunded"
    it "will not refund a signed or possibly broadcast conversion" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l ob "Solana" "tx" "signed-bytes" "{}" 5000 Nothing
      createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
      _<-markBroadcastIntent l "tx"
      createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
    it "charges a failed Solana transaction fee and preserves full refundable principal" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l ob "Solana" "failed-tx" "bytes" "{}" 5000 Nothing
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
      testAttempt l ob "Solana" "customer-signature" "bytes" "{}" 5000 Nothing
      pause l "fixture-review"
      commitScan l (ScanBatch "Solana" "origin" Nothing "customer-signature" 100 []
        [ChainEvent "customer-signature" "outgoing" "100" (object ["delta" .= ("-99800"::Text)])])
      recordTreasurySpend l "Solana" "customer-signature" (object ["fixture" .= True])
        `shouldThrow` isError "customer_attempt_cannot_be_treasury_spend"
    it "requires review when signed bytes appear on-chain before a recorded broadcast intent" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      testAttempt l ob "Solana" "premature-signature" "bytes" "{}" 5000 Nothing
      commitScan l (ScanBatch "SolanaOperating" "origin" Nothing "premature-signature" 100 []
        [ChainEvent "premature-signature" "outgoing" "100" (object ["delta" .= ("-5000"::Text),"feeUnits" .= amt 5000])])
      ledgerAction l (\db->query_ db "SELECT needs_review FROM chain_events" :: IO [Only Bool]) `shouldReturn` [Only True]
      available <$> readiness l `shouldReturn` False
    it "preserves reserved operating funds when reconciling a separate operator spend" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      beginPreparation l ob "Solana" 5000 "fixture-policy"
      commitScan l (ScanBatch "SolanaOperating" "origin" Nothing "operator-sig" 100 []
        [ChainEvent "operator-sig" "outgoing" "100" (object ["delta" .= ("-96000"::Text),"feeUnits" .= amt 5000])])
      recordTreasurySpend l "SolanaOperating" "operator-sig" (object ["fixture" .= True])
        `shouldThrow` isError "treasury_spend_exceeds_free_allocation"
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
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        ledgerAction l (\db->query_ db "SELECT schema_version,critical_sequence,backup_sequence FROM deployment" :: IO [(Int,Int64,Int64)]) `shouldReturn` [(schemaVersion,47,46)]
        ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1000
        available <$> readiness l `shouldReturn` False
    it "does not expose canonical instructions before acknowledged coverage" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      bindInstruction l (orderId o) "fixture-address"
      exposeOrder l True cap (orderId o) `shouldThrow` isError "backup_pending"
      acknowledgeBackup l 1 (T.replicate 64 "b")
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
      beginPreparation l ob "Native" 1000 (TE.decodeUtf8 $ LBS.toStrict $ encode plan)
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
    it "reserves fee plus rent and saves the request before signing; retries reuse exact bytes" $ withSolanaLedger $ \l c plan reply -> do
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
      signature<-prepareSolanaWith call helper c l ob
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
    it "does not invoke the helper unless the full operating budget can be reserved" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      (_,plan,_)<-solanaFixture
      let helper _=expectationFailure "signer called without budget" >> reject "unexpected"
      prepareSolanaWith (solanaContract c plan Null) helper c l ob `shouldThrow` isError "insufficient_fee_budget"
      pendingPreparations l `shouldReturn` []
      pendingAttempts l `shouldReturn` []
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
  let c=(cfg "/unused-codec-test"){deploymentId="codec-fixture",mint=token,custodyOwner=owner,custodyAta=replySource reply,maxSolFee=amt 10000}
      plan=SolanaPlan (fingerprint c) target (amt 3) "order-1" (RecentBlockhash hash 1000 100) (maxSolFee c) (maxSolAccountRent c)
  pure(c,plan,reply)

contextContract :: Value -> Value
contextContract value=object ["context" .= object ["slot" .= (100::Int)],"value" .= value]
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
    resumeAfterChecks l
    action l c plan reply
fundSolanaOrder :: Ledger -> Config -> SolanaPlan -> IO (OrderView,Obligation)
fundSolanaOrder l c plan=do
  o<-createOrder l c 100 cap req{input=amt 4,recipient=solPlanRecipient plan}
  bindInstruction l (orderId o) "fixture-address"
  observeDeposit l (Deposit "fixture-four-units:0" (Just $ orderId o) Native (amt 4) "fixture-anchor" 1 True 100) "cursor"
  promoteDeposit l 110 "fixture-four-units:0" `shouldReturn` True
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
