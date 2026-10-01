{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import Bridge.Types
import Bridge.Config
import Bridge.Ledger
import Bridge.SolanaMessage
import Bridge.SolanaDeposit
import qualified Data.Aeson.KeyMap as KM
import Bridge.Native (nativeAmount)
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
import qualified Data.ByteString.Base64 as B64
import Data.Int (Int64)
import Data.IORef
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
cfg dir = Config L2LSignetDevnet "unit-fixture" "http://127.0.0.1:29432" (dir</>"cookie") "fixture-wallet" 16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47" "https://api.devnet.solana.com" Nothing "Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM" "RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX" "11111111111111111111111111111111" (dir</>"private/ledger.sqlite") (dir</>"customer/api.sock") (dir</>"admin/api.sock") "/usr/bin/false" (dir</>"helper.json") (amt 2) (amt 1000000000000) 100 300 600 1 (amt 1000) (amt 1000) False Nothing
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
    it "retains exact bytes across restart and starts paused" $ withDir $ \dir -> do
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        fundAllocation l "float" Wrapped "float" (amt 1000000)
        fundAllocation l "sol-fees" Sol "operating" (amt 10000)
        resumeAfterChecks l
        (_,ob)<-fundOrder l c
        storeAttempt l ob "Solana" "fixture-signature" "fixture-exact-bytes" "{}" 5000 Nothing
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
      storeAttempt l ob "Solana" "fixture-signature" "bytes" "{}" 100001 Nothing `shouldThrow` isError "insufficient_fee_budget"
      pendingAttempts l `shouldReturn` []
    it "requires correct chain and database-bound obligation" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      storeAttempt l ob "Native" "tx" "bytes" "{}" 1 Nothing `shouldThrow` isError "wrong_destination_chain"
      storeAttempt l ob{obligationRecipient="attacker"} "Solana" "tx" "bytes" "{}" 1 Nothing `shouldThrow` isError "obligation_mismatch"
    it "keeps earned fees out of available source float and settles once" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      storeAttempt l ob "Solana" "fixture-signature" "bytes" "{}" 5000 Nothing
      _<-markBroadcastIntent l "fixture-signature"
      recordSettlement l "fixture-signature" 5000 "fixture-finalized-proof"
      recordSettlement l "fixture-signature" 5000 "fixture-finalized-proof"
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1099800
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 900200
      pendingAttempts l `shouldReturn` []
    it "cannot authorize a first send after loss of source eligibility" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      storeAttempt l ob "Solana" "tx" "bytes" "{}" 5000 Nothing
      observeDeposit l (Deposit "fixture-tx:0" (Just $ orderId o) Native (input req) "reorg" 0 False 100) "reorg-cursor"
      markBroadcastIntent l "tx" `shouldThrow` isError "attempt_not_sendable"
      length <$> pendingAttempts l `shouldReturn` 1
  describe "refund principal and failed transaction fees" $ do
    it "refunds a confirmed partial deposit without consuming payout float" $ withFunded $ \l c -> do
      o<-createOrder l c 100 cap req
      observeDeposit l (Deposit "partial:0" (Just $ orderId o) Native (amt 1000) "anchor" 1 True 100) "cursor"
      ob<-createRefund l "partial:0"
      obligationRecipient ob `shouldBe` refund req
      storeAttempt l ob "Native" "refund-tx" "fixture-refund-bytes" "{}" 100 Nothing
      _<-markBroadcastIntent l "refund-tx"
      recordSettlement l "refund-tx" 100 "fixture-refund-proof"
      ledgerAction l (\db->freeInventory db Native) `shouldReturn` 1000000
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
      status <$> readOrder l cap (orderId o) `shouldReturn` "Refunded"
    it "will not refund a signed or possibly broadcast conversion" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      storeAttempt l ob "Solana" "tx" "signed-bytes" "{}" 5000 Nothing
      createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
      _<-markBroadcastIntent l "tx"
      createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
    it "charges a failed Solana transaction fee and preserves full refundable principal" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      storeAttempt l ob "Solana" "failed-tx" "bytes" "{}" 5000 Nothing
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
