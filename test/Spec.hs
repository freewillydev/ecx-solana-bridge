{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import Bridge.Types
import Bridge.Config
import qualified Bridge.Postgres.Maintenance as Maintenance
import Bridge.Ledger
import Bridge.Reconciliation
import Bridge.Recovery
import Bridge.Reorg
import Bridge.Budget
import Bridge.SolanaMessage
import qualified Bridge.SolanaPay as Pay
import Bridge.SolanaDeposit
import Bridge.Solana (inspectTokenAccount)
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as Key
import Bridge.Native (nativeAmount,nativeNumber,validateNativeRecipientWith)
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Payment (prepareNativeWith,prepareSolanaWith,payoutReference)
import Bridge.Settlement
import Bridge.Deposit
import Bridge.Admission
import Bridge.Order
import Bridge.RPC
import Bridge.API
import Bridge.Worker
import Bridge.Backup
import Bridge.Observer
import Control.Concurrent (threadDelay,newEmptyMVar,putMVar,takeMVar)
import Control.Concurrent.Async (mapConcurrently,withAsync,cancel)
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
import System.Posix.Files (getFileStatus,fileMode,setFileMode)
import System.Timeout (timeout)
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
withFunded action=withDir $ \dir -> withFundedAt dir action
withFundedAt :: FilePath -> (Ledger -> Config -> IO a) -> IO a
withFundedAt dir action=let c=cfg dir in withLedger (dbPath c) (fingerprint c) $ \l -> do
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
  generation <- activePreparationGeneration l (obligationId ob)
  storeAttempt l ob chain txid bytes policy limit point generation

fixtureJson :: ToJSON a => a -> Text
fixtureJson=TE.decodeUtf8 . LBS.toStrict . encode

recoveryOutcomes :: Value -> IO [Text]
recoveryOutcomes result=fieldValue "attempts" result >>= mapM (fieldValue "outcome")

-- Ledger-only cancellation fixture; chain cleanup is tested separately below.
cancelFixture :: Ledger -> Preparation -> IO ()
cancelFixture l p=do
  pause l "offline-cancellation"
  freshScans l 100
  beginPreparationCancellation l p 100 "offline cancellation" (object ["offline" .= True])
  finishPreparationCancellation l p

nativeFixture :: IO (NativePlan,[NativePrevout],Amount,NativeTx)
nativeFixture = do
  value <- BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  plan <- fieldValue "plan" value
  previous <- fieldValue "previous" value
  fee <- fieldValue "fee" value
  decoded <- fieldValue "decoded" value >>= either (fail . T.unpack) pure . decodeNativeTx
  pure (plan,previous,fee,decoded)

nativeSignedFixture :: IO NativeSigned
nativeSignedFixture=do
  value<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  (plan,previous,fee,tx)<-nativeFixture
  raw<-fieldValue "raw" value
  pure (NativeSigned raw tx plan previous fee)

-- A real unsigned PSBT/decoded template, with modeled pending wallet state.
-- The captured input payment is actually confirmed; these are offline RPC
-- contracts, never evidence that a replacement was broadcast on Signet.
withNativeReplacementContract :: (Config -> NativeSigned -> NativeDraft -> NativeRPC -> IORef [(Text,[Value])] -> IO a) -> IO a
withNativeReplacementContract action=do
  original<-nativeSignedFixture
  captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  replacement<-BS.readFile "test/fixtures/native-signet-replacement-draft.json" >>= either fail pure . eitherDecodeStrict'
  oldDecoded<-fieldValue "decoded" captured :: IO Value
  newDecoded<-fieldValue "decoded" replacement :: IO Value
  draft<-fieldValue "draft" replacement
  created<-fieldValue "createdPsbt" replacement :: IO Text
  calls<-newIORef []
  let c=cfg "offline-native-replacement"
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
            ,"fee" .= scientific (negate $ toInteger $ units $ signedNativeFee original) (-8),"confirmations" .= (0::Int)
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
            points `shouldBe` toJSON (map nativeOutpoint $ nativeInputs tx)
            pure $ toJSON [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"spendingtxid" .= nativeTxid tx]
              | point<-map nativeOutpoint $ nativeInputs tx]
          ("listlockunspent",[])->pure $ toJSON $ map nativeOutpoint $ nativeInputs tx
          ("createpsbt",[inputs,outputs,locktime,Bool False])->do
            inputs `shouldBe` toJSON [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"sequence" .= nativeSequence input]
              | input<-nativeInputs tx,let point=nativeOutpoint input]
            locktime `shouldBe` toJSON (nativeLocktime tx)
            outputs `shouldBe` toJSON [object [Key.fromText (if nativeOutputScript o==planRecipientScript plan then planRecipient plan else planChange plan)
              .= nativeNumber (nativeOutputAmount o)] | o<-nativeOutputs $ draftTransaction draft]
            pure $ toJSON created
          ("walletprocesspsbt",[psbt,Bool False,String "ALL",Bool False,Bool False])->do
            psbt `shouldBe` toJSON created
            pure $ object ["psbt" .= draftPsbt draft,"complete" .= False]
          ("decodepsbt",[psbt]) | psbt==toJSON (draftPsbt draft)->pure newDecoded
          _->reject $ "unexpected_replacement_rpc:"<>method
  action c original draft call calls

withNativeLockRecovery :: (Ledger -> Config -> Preparation -> IORef [Outpoint] -> IORef [Text] -> PaymentTransport -> IO a) -> IO a
withNativeLockRecovery action=withDir $ \dir->withNativeLockRecoveryAt True dir action

-- Only local SQLite reopening and captured public bytes; these RPCs do not
-- contact a chain. The ordinary worker supplies the real native transport.
withNativeLockRecoveryAt :: Bool -> FilePath -> (Ledger -> Config -> Preparation -> IORef [Outpoint] -> IORef [Text] -> PaymentTransport -> IO a) -> IO a
withNativeLockRecoveryAt draft dir action=withNativeCancellationDraft draft dir $ \l c p locks original->do
  signed<-nativeSignedFixture
  captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  decoded<-fieldValue "decoded" captured :: IO Value
  previous<-case signedNativePrevouts signed of [v]->pure v; _->fail "expected captured prevout"
  calls<-newIORef []
  let tx=signedNativeTransaction signed
      wanted=map nativeOutpoint $ nativeInputs tx
      call wallet method params=do
        modifyIORef' calls (<>[method])
        case (method,params) of
          ("getwalletinfo",[]) -> pure $ object ["walletname" .= nativeWallet c,"descriptors" .= True,"scanning" .= False]
          ("gettxout",[txid,index,Bool True]) -> do
            (txid,index) `shouldBe` (toJSON $ outpointTxid $ prevout previous,toJSON $ outpointVout $ prevout previous)
            pure $ object ["value" .= nativeNumber (prevoutAmount previous),"confirmations" .= (1000::Int)
              ,"coinbase" .= prevoutCoinbase previous,"scriptPubKey" .= object ["hex" .= prevoutScript previous,"address" .= ("offline-lock-prevout"::Text)]]
          ("getaddressinfo",[String "offline-lock-prevout"]) -> pure $ object ["ismine" .= True,"scriptPubKey" .= prevoutScript previous]
          ("lockunspent",[Bool False,value]) -> do
            points<-parseValue parseJSON value
            points `shouldSatisfy` (not . null)
            points `shouldSatisfy` all (`elem` wanted)
            modifyIORef' locks (<>points)
            pure (Bool True)
          ("decoderawtransaction",_) -> pure decoded
          ("gettransaction",txid:_) | txid==toJSON (nativeTxid tx) -> reject "rpc_error_-5"
          ("getmempoolentry",_) -> reject "rpc_error_-5"
          (forbidden,_) | forbidden `elem` ["walletprocesspsbt","finalizepsbt","walletcreatefundedpsbt","sendrawtransaction"] ->
            expectationFailure "lock recovery touched funding, signer or broadcast" >> pure Null
          _->paymentNative original wallet method params
  action l c p locks calls original{paymentNative=call}

saveNativeFixtureAttempt :: Ledger -> Preparation -> IO Attempt
saveNativeFixtureAttempt l p=do
  signed<-nativeSignedFixture
  point<-case nativeInputs (signedNativeTransaction signed) of first:_->pure $ nativeOutpoint first; _->fail "missing captured input"
  storeAttempt l (preparationObligation p) "Native" (nativeTxid $ signedNativeTransaction signed)
    (signedNativeBytes signed) (fixtureJson signed) (units $ planFeeLimit $ signedNativePlan signed)
    (Just $ outpointTxid point<>":"<>T.pack(show $ outpointVout point)) (preparationGeneration p)
  [attempt]<-pendingAttempts l
  pure attempt

-- This cancellation fixture starts paused. Model the earlier authorized send
-- decision in this isolated database, then restore the crash/recovery pause.
markNativeFixtureBroadcast :: Ledger -> Attempt -> IO ()
markNativeFixtureBroadcast l attempt=do
  ledgerAction l $ \db->execute_ db "UPDATE deployment SET paused=0"
  _<-markBroadcastIntent l (attemptId attempt)
  pause l "offline-native-restart"

-- Ledger-only fault setup: inject a competing callback record. The second
-- record is deliberately not a signed transaction, and no adapter may send it.
-- This tests the accounting boundary before family creation is enabled.
withCompetingNativeAt :: FilePath -> (Ledger -> Config -> Text -> Text -> IO a) -> IO a
withCompetingNativeAt dir action=withNativeLockRecoveryAt True dir $ \l c p _ _ _->do
  original<-saveNativeFixtureAttempt l p
  markNativeFixtureBroadcast l original
  let other="offline-competing-native-callback"
  ledgerAction l $ \db->execute db "INSERT INTO attempts(txid,intent_id,signed_bytes,policy_json,fee_limit,state,critical_sequence,preparation_generation) SELECT ?,intent_id,'offline-not-signed','offline-ledger-only',fee_limit,state,critical_sequence,preparation_generation FROM attempts WHERE txid=?" (other,attemptId original)
  action l c (attemptId original) other

withReplacementDraftAt :: FilePath -> (Ledger -> Config -> Attempt -> NativeDraft -> PaymentTransport -> IO a) -> IO a
withReplacementDraftAt dir action=withNativeReplacementContract $ \_ original draft replacementRpc _->
  withNativeLockRecoveryAt True dir $ \l c p _ _ sourceTransport->do
    initial<-saveNativeFixtureAttempt l p
    markNativeFixtureBroadcast l initial
    [parent]<-pendingAttempts l
    let txid=attemptId parent
        cost=toInteger $ units $ signedNativeFee original
        custody=custodyContract c (1200000-100000-cost,1000000,100000) []
        native wallet method params=case (method,params) of
          ("gettransaction",wanted:_) | wanted/=toJSON txid->paymentNative sourceTransport wallet method params
          ("getaddressinfo",[String "fixture-address"])->paymentNative sourceTransport wallet method params
          ("getblockheader",_)->paymentNative sourceTransport wallet method params
          ("getblockhash",[Number 123])->paymentNative sourceTransport wallet method params
          ("getbalances",_)->paymentNative custody wallet method params >>= pure . setPath ["lastprocessedblock","height"] (toJSON (16010::Int))
          ("listsinceblock",_)->paymentNative custody wallet method params
          ("getmempoolentry",_)->pure $ object ["vsize" .= (141::Int)]
          _->replacementRpc wallet method params
    previous<-readCheckpoint l "Native"
    commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 []
      [ChainEvent txid "outgoing" "unconfirmed" (object ["confirmations" .= (0::Int),"walletNetUnits" .= ("-100000"::Text),"feeUnits" .= signedNativeFee original])])
    action l c parent draft custody{paymentNative=native}

-- The second member uses the captured unsigned replacement TEMPLATE with an
-- explicit non-sendable byte stub. RPC responses below model outcomes only;
-- these tests are not cryptographic/signing or live replacement acceptance.
replacementFixtureSigned :: NativeSigned -> NativeDraft -> NativeSigned
replacementFixtureSigned original draft=original{signedNativeBytes="00",signedNativeTransaction=draftTransaction draft
  ,signedNativePrevouts=draftPrevouts draft,signedNativeFee=draftFee draft}

withReplacementSignerAt :: FilePath -> (Ledger -> Config -> Attempt -> NativeDraft -> Int64 -> PaymentTransport -> IORef [(Text,[Value])] -> IO a) -> IO a
withReplacementSignerAt dir action=withReplacementDraftAt dir $ \l c parent draft originalTransport->do
  captured<-BS.readFile "test/fixtures/native-signet-replacement-draft.json" >>= either fail pure . eitherDecodeStrict'
  decoded<-fieldValue "decoded" captured >>= fieldValue "tx" :: IO Value
  result<-prepareNativeReplacementWith (pure 100) originalTransport c l (attemptId parent) (draftFee draft) "offline signing decision"
  sequenceNo<-fieldValue "draftSequence" result
  calls<-newIORef []
  let native wallet method params=do
        modifyIORef' calls (<>[(method,params)])
        case (method,params) of
          ("walletprocesspsbt",[psbt,Bool True,String "ALL",Bool True])->do
            psbt `shouldBe` toJSON (draftPsbt draft)
            pure $ object ["complete" .= True,"psbt" .= ("offline-signed-psbt"::Text)]
          ("finalizepsbt",[String "offline-signed-psbt",Bool True])->pure $ object ["complete" .= True,"hex" .= ("00"::Text)]
          ("decoderawtransaction",[String "00"])->pure decoded
          ("testmempoolaccept",[raw])->do
            raw `shouldBe` toJSON ["00"::Text]
            pure $ toJSON [object ["txid" .= nativeTxid (draftTransaction draft),"allowed" .= True
              ,"fees" .= object ["base" .= nativeNumber (draftFee draft)]]]
          _->paymentNative originalTransport wallet method params
  action l c parent draft sequenceNo originalTransport{paymentNative=native} calls

withNativeFamilyAt :: FilePath -> (Ledger -> Config -> [Attempt] -> [NativeSigned] -> IORef (Maybe (Int,Int)) -> PaymentTransport -> IORef [(Text,[Value])] -> IO a) -> IO a
withNativeFamilyAt dir action=withReplacementDraftAt dir $ \l c parent draft originalTransport->do
  original<-nativeSignedFixture
  old<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  oldDecoded<-fieldValue "decoded" old :: IO Value
  replacement<-BS.readFile "test/fixtures/native-signet-replacement-draft.json" >>= either fail pure . eitherDecodeStrict'
  newDecoded<-fieldValue "decoded" replacement >>= fieldValue "tx"
  result<-prepareNativeReplacementWith (pure 100) originalTransport c l (attemptId parent) (draftFee draft) "offline family decision"
  sequenceNo<-fieldValue "draftSequence" result
  _<-reconcileCustodyWith (pure 100) originalTransport c l
  let newer=replacementFixtureSigned original draft
  member<-recordNativeReplacementMember l c sequenceNo [parent] newer 100
  markNativeFixtureBroadcast l member
  attempts<-pendingAttempts l
  let signed=[original,newer]
      txid s=nativeTxid $ signedNativeTransaction s
      position=object ["hash" .= custodyNativeTip,"height" .= (16010::Int)]
      points=map nativeOutpoint $ nativeInputs $ signedNativeTransaction original
  mode<-newIORef $ Just (1,0)
  calls<-newIORef []
  locks<-newIORef ([]::[Outpoint])
  let native wallet method params=do
        modifyIORef' calls (<>[(method,params)])
        selected<-readIORef mode
        let active=case selected of Just (i,n)->Just (signed!!i,n); Nothing->Nothing
            quantity=case active of Just (s,_)->1200000-100000-toInteger (units $ signedNativeFee s); Nothing->1200000
            balance=custodyContract c (quantity,1000000,100000) []
            winnerAnchor=case active of Just (_,1)->custodyNativeTip; _->T.replicate 64 "d"
        case (method,params) of
          ("decoderawtransaction",[raw]) | raw==toJSON (signedNativeBytes newer)->pure newDecoded
          ("gettransaction",[wanted,Bool False,Bool True]) | wanted `elem` map (toJSON.txid) signed->do
            let (s,decoded)=if wanted==toJSON (txid original) then (original,oldDecoded) else (newer,newDecoded)
                depth=case active of Just (winner,n) | txid winner==txid s->n; Just (_,n) | n>0->negate n; _->0
                conflicts=case active of Just (winner,n) | n>0 && txid winner/=txid s->[txid winner]; _->[]
                mempool=case active of Just (winner,0) | txid winner/=txid s->[txid winner]; _->[]
            pure $ object $ ["txid" .= txid s,"hex" .= signedNativeBytes s,"decoded" .= decoded
              ,"fee" .= scientific (negate $ toInteger $ units $ signedNativeFee s) (-8),"confirmations" .= depth
              ,"walletconflicts" .= conflicts,"mempoolconflicts" .= mempool,"lastprocessedblock" .= position]
              <>["blockhash" .= winnerAnchor | depth>0]
          ("gettxspendingprevout",[_])->pure $ toJSON [object $ ["txid" .= outpointTxid p,"vout" .= outpointVout p]
            <>case active of Just (s,0)->["spendingtxid" .= txid s]; _->[] | p<-points]
          ("gettxout",[tx,index,Bool includeMempool])->case active of
            Just (_,n) | n>0 || includeMempool->pure Null
            _->paymentNative originalTransport wallet method [tx,index,Bool False]
          ("getmempoolentry",[wanted])->case active of
            Just (s,0) | wanted==toJSON (txid s)->pure $ object ["vsize" .= (141::Int)]
            _->reject "rpc_error_-5"
          ("getblockheader",[anchor]) | anchor==toJSON winnerAnchor->case active of
            Just (_,n) | n>0->pure $ object ["hash" .= winnerAnchor,"height" .= (16011-n),"confirmations" .= n]
            _->reject "unexpected_family_block"
          ("getblockhash",[height]) | Just (_,n)<-active,n>0,height==toJSON (16011-n)->pure $ toJSON winnerAnchor
          ("getbalances",[])->paymentNative balance wallet method params >>= pure . setPath ["lastprocessedblock","height"] (toJSON (16010::Int))
          ("listlockunspent",[])->toJSON <$> readIORef locks
          ("lockunspent",[Bool False,value])->do
            requested<-parseValue parseJSON value
            requested `shouldSatisfy` (not . null)
            requested `shouldSatisfy` all (`elem` points)
            modifyIORef' locks (<>requested)
            pure (Bool True)
          _->paymentNative originalTransport wallet method params
      transport=originalTransport{paymentNative=native}
  scanFamilyFixture l c signed (Just (1,0))
  writeIORef calls []
  action l c attempts signed mode transport calls

scanFamilyFixture :: Ledger -> Config -> [NativeSigned] -> Maybe (Int,Int) -> IO ()
scanFamilyFixture l c members position=do
  previous<-readCheckpoint l "Native"
  let events=[let depth=case position of Just (winner,n) | winner==i->n; Just (_,n) | n>0->negate n; _->0
                  anchor=if depth<=0 then "unconfirmed" else if depth==1 then custodyNativeTip else T.replicate 64 "d"
              in ChainEvent (nativeTxid $ signedNativeTransaction s) "outgoing" anchor
                (object ["confirmations" .= depth,"walletNetUnits" .= ("-100000"::Text),"feeUnits" .= signedNativeFee s])
             | (i,s)<-zip [0..] members]
  commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 [] events)

-- Captured native transaction, local financial fixture, and explicit RPC
-- responses. No alternate chain is selected or contacted by these tests.
withNativeSettlementAt :: FilePath -> (Ledger -> Config -> Attempt -> NativeSigned -> IORef (Maybe Value) -> IORef Text -> PaymentTransport -> IO a) -> IO a
withNativeSettlementAt dir action=withNativeLockRecoveryAt True dir $ \l c p _ _ original->do
  signed<-nativeSignedFixture
  captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  decoded<-fieldValue "decoded" captured :: IO Value
  attempt<-saveNativeFixtureAttempt l p
  markNativeFixtureBroadcast l attempt
  let txid=attemptId attempt
      depth=planDepth $ signedNativePlan signed
      proof=nativeSettlementProof txid custodyNativeTip depth
  recordSettlement l txid (PaymentCosts (signedNativeFee signed) (amt 0)) proof
  [settled]<-ledgerAction l (\db->query db "SELECT a.txid,a.intent_id,i.chain,a.signed_bytes,a.policy_json,a.fee_limit,a.state,a.critical_sequence FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE a.txid=?" (Only txid))
  setNativeSettlementHistory l c txid custodyNativeTip 2
  wallet<-newIORef $ Just $ object ["txid" .= txid,"hex" .= signedNativeBytes signed,"decoded" .= decoded
    ,"fee" .= scientific (negate $ toInteger $ units $ signedNativeFee signed) (-8)
    ,"walletconflicts" .= ([]::[Text]),"confirmations" .= (2::Int),"blockhash" .= custodyNativeTip]
  active<-newIORef custodyNativeTip
  let call selected method params=case (method,params) of
        ("gettransaction",wanted:_) | wanted==toJSON txid->readIORef wallet >>= maybe (reject "rpc_error_-5") pure
        ("getblockheader",[String anchor])->do
          actual<-readIORef active
          pure $ object ["hash" .= anchor,"height" .= (100::Int),"confirmations" .= (if actual==anchor then 2::Int else -1)]
        ("getblockhash",[Number 100])->toJSON <$> readIORef active
        _->paymentNative original selected method params
  action l c settled signed wallet active original{paymentNative=call}

nativeSettlementProof :: Text -> Text -> Int -> Text
nativeSettlementProof txid anchor depth=fixtureJson $ object
  ["txid" .= txid,"blockhash" .= anchor,"height" .= (100::Int),"requiredDepth" .= depth]

setNativeSettlementHistory :: Ledger -> Config -> Text -> Text -> Int -> IO ()
setNativeSettlementHistory l c txid anchor depth=do
  previous<-readCheckpoint l "Native"
  commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 []
    [ChainEvent txid "outgoing" anchor (object ["confirmations" .= depth])])

nativeSettlementPrevious :: Ledger -> Attempt -> IO Text
nativeSettlementPrevious l a=do
  [Only proof]<-ledgerAction l (\db->query db "SELECT observation_json FROM attempts WHERE txid=?" (Only $ attemptId a))
  pure proof

nativeSettlementStates :: Value -> IO [Text]
nativeSettlementStates value=fieldValue "payments" value >>= mapM (fieldValue "state")

-- Real receipt bytes/identity with deliberately changed RPC responses below.
-- Only the production adapter uses a network; these are offline contracts.
withNativeSource :: (Ledger -> Config -> Deposit -> IORef (Maybe Value) -> PaymentTransport -> IO a) -> IO a
withNativeSource action=withDir $ \dir->withNativeSourceAt True dir action

withNativeSourceAt :: Bool -> FilePath -> (Ledger -> Config -> Deposit -> IORef (Maybe Value) -> PaymentTransport -> IO a) -> IO a
withNativeSourceAt initiallyEligible dir action=withFundedAt dir $ \l c->do
  captured<-BS.readFile "test/fixtures/native-signet-source.json" >>= either fail pure . eitherDecodeStrict'
  original<-fieldValue "transaction" captured
  ownership<-fieldValue "ownership" captured
  txid<-fieldValue "txid" original
  [detail]<-fieldValue "details" original :: IO [Value]
  address<-fieldValue "address" detail
  index<-fieldValue "vout" detail :: IO Int
  quantity<-fieldValue "amount" detail >>= either reject pure . nativeAmount
  anchor<-fieldValue "blockhash" original
  depth<-fieldValue "confirmations" original :: IO Int
  position<-fieldValue "lastprocessedblock" original
  nodeHeight<-fieldValue "height" position :: IO Int64
  nodeBlock<-fieldValue "hash" position
  o<-createOrder l c 100 cap req{input=quantity}
  bindInstruction l (orderId o) address
  let source=Deposit ("native:"<>txid<>":"<>T.pack(show index)) (Just $ orderId o) Native quantity anchor depth initiallyEligible 100
      value=if initiallyEligible then original else setPath ["confirmations"] (Number 0) $ setPath ["blockhash"] Null original
      firstSource=if initiallyEligible then source else source{depositAnchor="unconfirmed",depositConfirmations=0}
  wallet<-newIORef (Just value)
  writeSourceHistory l c firstSource value
  let unavailable method=expectationFailure ("unexpected source-recovery RPC: "<>T.unpack method) >> pure Null
      call selected method params=case (method,params) of
        ("getwalletinfo",[])->pure $ object ["walletname" .= nativeWallet c,"descriptors" .= True,"scanning" .= False,"lastprocessedblock" .= position]
        ("gettransaction",[wanted,Bool False,Bool True])->do
          selected `shouldBe` True
          wanted `shouldBe` toJSON txid
          readIORef wallet >>= maybe (reject "rpc_error_-5") pure
        ("getaddressinfo",[wanted])->do
          wanted `shouldBe` toJSON address
          pure ownership
        ("getblockheader",[String block])->pure $ object ["hash" .= block,"confirmations" .= (100::Int)
          ,"height" .= (if block==nodeBlock then nodeHeight else nodeHeight-fromIntegral depth+1)]
        ("getblockhash",[height])->pure $ toJSON $ if height==toJSON nodeHeight then nodeBlock else anchor
        ("getmempoolentry",[wanted])->do
          wanted `shouldBe` toJSON txid
          current<-readIORef wallet >>= maybe (reject "rpc_error_-5") pure
          confirmations<-fieldValue "confirmations" current :: IO Int
          if confirmations==0 then pure (object ["vsize" .= (141::Int)]) else reject "rpc_error_-5"
        ("gettxout",[wanted,n,Bool True])->do
          wanted `shouldBe` toJSON txid
          n `shouldBe` toJSON index
          pure Null
        _->unavailable method
      transport=PaymentTransport call (\method _->unavailable method) Nothing (pure ())
        (const $ expectationFailure "source recovery requested a backup/send decision")
  action l c firstSource wallet transport

writeSourceHistory :: Ledger -> Config -> Deposit -> Value -> IO ()
writeSourceHistory l c source value=do
  txid<-fieldValue "txid" value
  depth<-fieldValue "confirmations" value :: IO Int
  previous<-readCheckpoint l "Native"
  commitScan l $ ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 [source]
    [ChainEvent txid "incoming" (depositAnchor source) (object ["confirmations" .= depth])]

changeSource :: Ledger -> Config -> Deposit -> IORef (Maybe Value) -> Int -> IO Deposit
changeSource l c original wallet depth=do
  current<-readIORef wallet >>= maybe (fail "restore the captured wallet value first") pure
  let anchor=if depth>0 then depositAnchor original else "unconfirmed"
      source=original{depositConfirmations=max 0 depth,depositEligible=depth>=nativeConfirmations c,depositAnchor=anchor}
      value=setPath ["confirmations"] (toJSON depth) $ setPath ["blockhash"] (if depth>0 then String anchor else Null)
        $ setPath ["walletconflicts"] (toJSON [T.replicate 64 "f" | depth<0]) current
  writeIORef wallet (Just value)
  writeSourceHistory l c source value
  pure source

sourceStates :: Value -> IO [Text]
sourceStates value=fieldValue "sources" value >>= mapM (fieldValue "state")

sourceBalance :: Ledger -> Text -> IO Integer
sourceBalance l account=ledgerAction l $ \db->fold db "SELECT delta FROM postings WHERE asset='Native' AND account=?" (Only account) 0
  (\acc (Only n::Only Int64)->pure $ acc+toInteger n)

sourceObligation :: Ledger -> Deposit -> IO Obligation
sourceObligation l source=do
  promoteDeposit l 110 (depositId source) `shouldReturn` True
  [ob]<-readyObligations l
  pure ob

sourceAttempt :: Ledger -> Config -> Obligation -> IO ()
sourceAttempt l c ob=testAttempt l c ob "Solana" "offline-source-payout" "offline-source-signed-bytes" "offline-ledger-policy" 5000 Nothing

sourceRestoration :: Ledger -> Deposit -> IO Int64
sourceRestoration l source=do
  rows<-ledgerAction l $ \db->query db "SELECT critical_sequence FROM source_recovery_state WHERE deposit_id=? AND state='restored'" (Only $ depositId source)
  case rows of [Only n]->pure n; _->fail "fixture source not restored"

-- Ledger-only approval tests model a successful custody check explicitly.
-- The coordinator tests below run the actual reconciliation against RPC fixtures.
assumeSourceApprovalCustody :: Ledger -> IO ()
assumeSourceApprovalCustody l=ledgerAction l $ \db->execute_ db "UPDATE custody_check SET checked_revision=revision,checked_at=100,last_error=NULL,report_json='{\"offlineFixture\":true}'"

sourceLossEvidence :: Ledger -> Config -> Deposit -> PaymentTransport -> IO (Int64,Value)
sourceLossEvidence l c source transport=do
  _<-reconcileNativeSourcesWith transport c l
  [Only sequenceNo]<-ledgerAction l $ \db->query db "SELECT critical_sequence FROM source_recovery_state WHERE deposit_id=? AND state='missing'" (Only $ depositId source)
  proof<-inspectNativeSourceWith transport c l source >>= \case SourceMissing p->pure p; _->fail "fixture source not missing"
  pure(sequenceNo,proof)

-- Only the ledger contract tests use this modeled check. The coordinator tests
-- below use the actual custody algorithm with explicit RPC response fixtures.
lossCustodyFixture :: Ledger -> Value -> IO Value
lossCustodyFixture l sourceProof=do
  [Only revision]<-ledgerAction l (\db->query_ db "SELECT revision FROM custody_check" :: IO [Only Int64])
  block<-fieldValue "nodeBlock" sourceProof :: IO Text
  height<-fieldValue "nodeHeight" sourceProof :: IO Int64
  pure $ object ["revision" .= revision,"checkedAt" .= (100::Int),"report" .= object
    ["matches" .= True,"nativeBlock" .= block,"nativeHeight" .= height,"offlineFixture" .= True]]

lossCustodyTransport :: Ledger -> Config -> IORef (Maybe Value) -> PaymentTransport -> Integer -> IO PaymentTransport
lossCustodyTransport l c wallet sourceTransport nativeUnits=do
  setupCustodyScans l c
  value<-readIORef wallet >>= maybe (fail "fixture wallet missing") pure
  position<-fieldValue "lastprocessedblock" value
  block<-fieldValue "hash" position
  previous<-readCheckpoint l "Native"
  commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous block 100 [] [])
  let custody=custodyContract c (nativeUnits,1000000,100000) []
      native selected method params=case method of
        "getbalances"->setPath ["lastprocessedblock"] position <$> paymentNative custody selected method params
        "listsinceblock"->setPath ["lastblock"] (String block) <$> paymentNative custody selected method params
        _->paymentNative sourceTransport selected method params
  pure custody{paymentNative=native}

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

withNativeCancellation :: (Ledger -> Config -> Preparation -> IORef [Outpoint] -> PaymentTransport -> IO a) -> IO a
withNativeCancellation action=withDir $ \dir -> withNativeCancellationAt dir action
withNativeCancellationAt :: FilePath -> (Ledger -> Config -> Preparation -> IORef [Outpoint] -> PaymentTransport -> IO a) -> IO a
withNativeCancellationAt=withNativeCancellationDraft True
withNativeCancellationDraft :: Bool -> FilePath -> (Ledger -> Config -> Preparation -> IORef [Outpoint] -> PaymentTransport -> IO a) -> IO a
withNativeCancellationDraft saveDraft dir action=withFundedAt dir $ \l original -> do
  let c=expiryConfig original
      did="native:"<>T.replicate 64 "a"<>":0"
  (plan,previous,fee,tx)<-nativeFixture
  captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  decoded<-fieldValue "decoded" captured :: IO Value
  o<-createOrder l c 100 cap req{refund=planRecipient plan}
  bindInstruction l (orderId o) "fixture-address"
  observeDeposit l (Deposit did (Just $ orderId o) Native (amt 100000) (T.replicate 64 "b") 1 True 100) "cursor"
  ob<-createRefund l did
  beginPreparation l c ob "Native" (units $ planFeeLimit plan) (fixtureJson plan)
  when saveDraft $ storeDraft l (obligationId ob) (fixtureJson $ NativeDraft "offline-psbt" tx previous fee) 0
  [p]<-pendingPreparations l
  setupCustodyScans l c
  pause l "offline-unsigned-interruption"
  let wanted=map nativeOutpoint $ nativeInputs tx
  locks<-newIORef (if saveDraft then wanted else [])
  let base=custodyContract c (1200000,1000000,100000) []
      native wallet method params=case (method,params) of
        ("gettransaction",_) -> do
          source<-sourceNativeContract 1 wallet method params
          pure $ setPath ["decoded","vout"] (toJSON [object ["n" .= (0::Int),"value" .= nativeNumber (amt 100000)
            ,"scriptPubKey" .= object ["hex" .= ("0014"<>T.replicate 40 "1")]]]) source
        ("getaddressinfo",_) -> sourceNativeContract 1 wallet method params
        ("getblockheader",_) -> sourceNativeContract 1 wallet method params
        ("getblockhash",[height]) | height==toJSON (123::Int) -> sourceNativeContract 1 wallet method params
        ("decodepsbt",[String "offline-psbt"]) -> pure $ object ["tx" .= decoded,"fee" .= nativeNumber fee]
        ("listlockunspent",[]) -> toJSON <$> readIORef locks
        ("lockunspent",[Bool True,value]) -> do
          wallet `shouldBe` True
          points<-parseValue parseJSON value :: IO [Outpoint]
          points `shouldSatisfy` (not . null)
          points `shouldSatisfy` all (`elem` wanted)
          readIORef locks `shouldReturn` points
          preparationCancellation l (obligationId ob) 0 >>= (`shouldSatisfy` maybe False (\(_,_,done)->not done))
          writeIORef locks []
          pure (Bool True)
        _ -> paymentNative base wallet method params
  action l c p locks base{paymentNative=native}

main :: IO ()
main=hspec $ do
  describe "operator configuration boundaries" $ do
    it "refuses mainnet trading links on a Devnet deployment" $ withDir $ \dir->do
      let links=(defaultInterface L2LSignetDevnet){jupiterUrl=Just "https://jup.ag/swap/SOL-token"}
      validateInterface (cfg dir) links `shouldThrow` isError "trading_links_require_mainnet"
    it "refuses script URLs, credential-bearing URLs and malformed explorer prefixes" $ withDir $ \dir->do
      let c=cfg dir; links=defaultInterface L2LSignetDevnet
      forM_ ["javascript:alert(1)","https://user:secret@example.com/support"] $ \url->
        validateInterface c links{supportUrl=Just url} `shouldThrow` isError "invalid_support_url"
      validateInterface c links{nativeExplorerBase=Just "https://example.com/tx/?key="} `shouldThrow` isError "invalid_native_explorer"
    it "validates a custody keypair against its derived public key without signing" $ withDir $ \dir->do
      case Ed.secretKey (BS.replicate 32 7) of
        CryptoFailed _->expectationFailure "fixture secret rejected"
        CryptoPassed secret->do
          let public=BA.convert(Ed.toPublic secret)::BS.ByteString
              filename=dir</>"signer.json"
              c=(cfg dir){custodyOwner=base58 public}
              writeKey bytes=LBS.writeFile filename (encode $ BS.unpack bytes) >> setFileMode filename 0o600
          writeKey (BS.replicate 32 7<>public)
          Maintenance.verifySigner c filename
          writeKey (BS.replicate 32 8<>public)
          Maintenance.verifySigner c filename `shouldThrow` isError "signer_mismatch"
          writeKey (BS.replicate 32 7<>public)
          setFileMode filename 0o644
          Maintenance.verifySigner c filename `shouldThrow` isError "unsafe_signer_permissions"
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
    it "rolls back a failed database action as one financial decision" $ withDir $ \dir->do
      originalAudit<-withFundedAt dir $ \l _->do
        before<-auditExport l
        result<-try (ledgerAction l $ \db -> do
          execute_ db "INSERT INTO events(id,description) VALUES('rollback','test')"
          execute_ db "INSERT INTO postings(event_id,asset,account,delta) VALUES('rollback','Native','float',NULL)") :: IO (Either SQLError ())
        either (Just . sqlError) (const Nothing) result `shouldBe` Just ErrorConstraint
        auditExport l `shouldThrow` isError "ledger_requires_reopen"
        pure before
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l->auditExport l `shouldReturn` originalAudit
  describe "SQLite transaction failure boundaries (local database, no chain IO)" $ do
    it "rolls back an interrupted request and releases the writer without publishing its checkpoint" $ withFunded $ \l _->do
      original<-auditExport l
      sequenceBefore<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
      custodyBefore<-custodyHealth l
      reached<-newEmptyMVar
      hold<-newEmptyMVar
      withAsync (ledgerAction l $ \db->do
        execute_ db "INSERT INTO events(id,description) VALUES('interrupted','offline cancellation')"
        execute_ db "INSERT INTO postings(event_id,asset,account,delta) VALUES('interrupted','Native','float',1),('interrupted','Native','external',-1)"
        _<-criticalSequence db
        checkpoint db "Native" "uncommitted-offline-cursor"
        putMVar reached ()
        takeMVar hold :: IO ()) $ \request->do
          timeout 1000000 (takeMVar reached) `shouldReturn` Just ()
          cancel request
      auditExport l `shouldReturn` original
      custodyHealth l `shouldReturn` custodyBefore
      readCheckpoint l "Native" `shouldReturn` Nothing
      ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` sequenceBefore
    it "fences a failed COMMIT, rolls it back, and reopens with the original balances and sequence" $ withDir $ \dir->do
      (original,sequenceBefore)<-withFundedAt dir $ \l _->do
        before<-auditExport l
        previous<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
        bodyCompleted<-newIORef False
        result<-try (ledgerAction l $ \db->do
          execute_ db "PRAGMA defer_foreign_keys=ON"
          execute_ db "INSERT INTO postings(event_id,asset,account,delta) VALUES('missing-offline-event','Native','float',1)"
          _<-criticalSequence db
          writeIORef bodyCompleted True) :: IO (Either SQLError ())
        readIORef bodyCompleted `shouldReturn` True
        either (Just . sqlError) (const Nothing) result `shouldBe` Just ErrorConstraint
        auditExport l `shouldThrow` isError "ledger_requires_reopen"
        pure (before,previous)
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` original
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` sequenceBefore
        ledgerAction l (\db->query_ db "PRAGMA foreign_key_check" :: IO [(Text,Int64,Text,Int)]) `shouldReturn` []
        available <$> readiness l `shouldReturn` False
    it "retains the original SQLITE_FULL error and fences writes when the private file reaches its page limit" $ withDir $ \dir->do
      (original,sequenceBefore)<-withFundedAt dir $ \l _->do
        before<-auditExport l
        previous<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
        ledgerAction l $ \db->do
          [Only pages]<-query_ db "PRAGMA page_count" :: IO [Only Int]
          limit<-query_ db (fromString $ "PRAGMA max_page_count="<>show pages) :: IO [Only Int]
          limit `shouldBe` [Only pages]
        -- This bounded SQLite capacity error does not fill the host disk and
        -- is not claimed as a filesystem/power-loss acceptance test.
        result<-try (ledgerAction l $ \db->do
          _<-criticalSequence db
          execute_ db "INSERT INTO audit(action,detail) VALUES('offline-capacity-failure',zeroblob(4194304))") :: IO (Either SQLError ())
        either (Just . sqlError) (const Nothing) result `shouldBe` Just ErrorFull
        ledgerAction l (const $ pure ()) `shouldThrow` isError "ledger_requires_reopen"
        pure (before,previous)
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` original
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` sequenceBefore
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM audit WHERE action='offline-capacity-failure'" :: IO [Only Int]) `shouldReturn` [Only 0]
        available <$> readiness l `shouldReturn` False
    it "cannot authorize a send after the broadcast-intent write fails, and preserves the exact signed attempt" $ withDir $ \dir->do
      (original,attempts,sequenceBefore)<-withFundedAt dir $ \l c->do
        (_,ob)<-fundOrder l c
        testAttempt l c ob "Solana" "offline-write-failure" "original-bytes" "{}" 10000 Nothing
        before<-auditExport l
        saved<-pendingAttempts l
        previous<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
        ledgerAction l $ \db->execute_ db "CREATE TEMP TRIGGER injected_intent_failure BEFORE UPDATE OF state ON attempts WHEN NEW.state='broadcast_intent' BEGIN SELECT RAISE(ABORT,'offline injected database failure'); END"
        markBroadcastIntent l "offline-write-failure" `shouldThrow` (\e->sqlError e==ErrorConstraint)
        authorizeRecordedSend l False "offline-write-failure" `shouldThrow` isError "ledger_requires_reopen"
        pure (before,saved,previous)
      let c=cfg dir
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` original
        pendingAttempts l `shouldReturn` attempts
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` sequenceBefore
        ledgerAction l (\db->query_ db "SELECT released FROM fee_reservations" :: IO [Only Bool]) `shouldReturn` [Only False]
        available <$> readiness l `shouldReturn` False
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
  describe "unsigned cancellation ledger invariants (offline fixtures)" $ do
    it "retains principal, inventory, policy, draft and fees, and excludes late callbacks" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      storeDraft l (obligationId ob) "fixture-draft" 0
      [p]<-pendingPreparations l
      balance<-ledgerAction l (\db->query_ db "SELECT event_id,asset,account,delta FROM postings ORDER BY id" :: IO [(Text,Text,Text,Int64)])
      free<-ledgerAction l (\db->freeInventory db Wrapped)
      fees<-ledgerAction l (\db->freeOperating db "Sol")
      let cleanup=object ["offline" .= True]
      beginPreparationCancellation l p 100 "operator cancel" cleanup `shouldThrow` isError "pause_before_operator_action"
      pause l "operator-action"
      beginPreparationCancellation l p 100 "operator cancel" cleanup `shouldThrow` isError "custody_not_reconciled"
      freshScans l 100
      beginPreparationCancellation l p 100 "operator cancel" cleanup
      beginPreparationCancellation l p 100 "operator cancel" cleanup
      beginPreparationCancellation l p 100 "changed reason" cleanup `shouldThrow` isError "preparation_cancellation_conflict"
      storeDraft l (obligationId ob) "fixture-draft" 0 `shouldThrow` isError "preparation_cancellation_pending"
      storeAttempt l ob "Solana" "late-signature" "late-bytes" "{}" 5000 Nothing 0 `shouldThrow` isError "preparation_cancellation_pending"
      createRefund l (obligationDeposit ob) `shouldThrow` isError "refund_would_race_payment"
      finishPreparationCancellation l p
      critical<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
      finishPreparationCancellation l p
      ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` critical
      available <$> readiness l `shouldReturn` False
      pendingPreparations l `shouldReturn` []
      pendingAttempts l `shouldReturn` []
      readyObligations l `shouldReturn` [ob]
      status <$> readOrder l cap (orderId o) `shouldReturn` "Ready"
      ledgerAction l (\db->query_ db "SELECT event_id,asset,account,delta FROM postings ORDER BY id" :: IO [(Text,Text,Text,Int64)]) `shouldReturn` balance
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` free
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` fees
      ledgerAction l (\db->query_ db "SELECT policy_json,draft_json,cancelled FROM preparations" :: IO [(Text,Text,Bool)])
        `shouldReturn` [("fixture-policy","fixture-draft",True)]
      ledgerAction l (\db->query_ db "SELECT phase FROM reservations" :: IO [Only Text]) `shouldReturn` [Only "obligation"]
    it "atomically transfers the retained fee hold into a new generation and rejects stale replies" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      [p]<-pendingPreparations l
      cancelFixture l p
      fees<-ledgerAction l (\db->freeOperating db "Sol")
      resumeAfterChecks l
      beginPreparation l c{maxSolDailyCost=amt 1} ob "Solana" 5000 "new-policy" `shouldThrow` isError "operating_daily_limit"
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` fees
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(5000,False)]
      beginPreparation l c ob "Solana" 5000 "new-policy"
      activePreparationGeneration l (obligationId ob) `shouldReturn` 1
      storeDraft l (obligationId ob) "old-draft" 0 `shouldThrow` isError "preparation_generation_changed"
      storeAttempt l ob "Solana" "old-signature" "old-bytes" "{}" 5000 Nothing 0 `shouldThrow` isError "preparation_generation_changed"
      storeDraft l (obligationId ob) "new-draft" 1
      [next]<-pendingPreparations l
      storeAttempt l ob "Solana" "new-signature" "new-bytes" "{}" 5000 Nothing 1
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` fees
      [attempt]<-pendingAttempts l
      recordSolanaExpiry l attempt "offline expiry proof"
      ledgerAction l (\db->query_ db "SELECT generation,cancelled,retired_txid FROM preparations ORDER BY generation" :: IO [(Int,Bool,Maybe Text)])
        `shouldReturn` [(0,True,Nothing),(1,False,Just "new-signature")]
      pause l "operator-action"
      freshScans l 100
      beginPreparationCancellation l next 100 "cancel expired signature" (object ["offline" .= True])
        `shouldThrow` isError "preparation_cancellation_not_expected"
    it "releases the unused conversion fee once when a cancelled conversion becomes a full refund" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      [p]<-pendingPreparations l
      cancelFixture l p
      refundOb<-createRefund l (obligationDeposit ob)
      createRefund l (obligationDeposit ob) `shouldReturn` refundOb
      obligationAmount refundOb `shouldBe` units (input req)
      ledgerAction l (\db->freeOperating db "Sol") `shouldReturn` 100000
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 1000000
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(5000,True)]
      resumeAfterChecks l
      beginPreparation l c ob "Solana" 5000 "revived" `shouldThrow` isError "obligation_not_ready"
      beginPreparation l c refundOb "Native" 1000 "refund-policy"
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` 99000
    it "cannot cancel any generation with a signed, broadcast or settled attempt" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      [p]<-pendingPreparations l
      storeAttempt l ob "Solana" "recorded" "bytes" "{}" 5000 Nothing 0
      let refuse=do
            pause l "operator-action"
            freshScans l 100
            beginPreparationCancellation l p 100 "cancel signed" (object ["offline" .= True])
              `shouldThrow` isError "preparation_cancellation_not_expected"
      refuse
      ledgerAction l $ \db->execute_ db "UPDATE deployment SET paused=0"
      _<-markBroadcastIntent l "recorded"
      refuse
      recordSettlement l "recorded" (PaymentCosts (amt 1) (amt 0)) "offline settlement"
      refuse
      preparationCancellation l (obligationId ob) 0 `shouldReturn` Nothing
    it "keeps a source that loses eligibility during cleanup in review" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      [p]<-pendingPreparations l
      pause l "operator-action"
      freshScans l 100
      beginPreparationCancellation l p 100 "cancel" (object ["offline" .= True])
      refreshDeposit l (Deposit (obligationDeposit ob) (Just $ orderId o) Native (input req) "fixture-anchor" 0 False 100)
      finishPreparationCancellation l p
      readyObligations l `shouldReturn` []
      status <$> readOrder l cap (orderId o) `shouldReturn` "NeedsReview"
      ledgerAction l (\db->freeInventory db Wrapped) `shouldReturn` 900200
    it "keeps an abandoned conversion cancelled when its refund source loses eligibility" $ withFunded $ \l c -> do
      (o,ob)<-fundOrder l c
      beginPreparation l c ob "Solana" 5000 "fixture-policy"
      [p]<-pendingPreparations l
      cancelFixture l p
      refundOb<-createRefund l (obligationDeposit ob)
      refreshDeposit l (Deposit (obligationDeposit ob) (Just $ orderId o) Native (input req) "fixture-anchor" 0 False 100)
      ledgerAction l (\db->query_ db "SELECT kind,status FROM obligations ORDER BY kind" :: IO [(Text,Text)])
        `shouldReturn` [("conversion","cancelled"),("refund","review")]
      ledgerAction l (\db->query_ db "SELECT eligible FROM deposits" :: IO [Only Bool]) `shouldReturn` [Only False]
      readyObligations l `shouldReturn` []
      available <$> readiness l `shouldReturn` False
      beginPreparation l c refundOb "Native" 1000 "refund-policy" `shouldThrow` isError "payouts_paused"
    it "bounds repeated cancellation generations instead of growing an unbounded retry chain" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      forM_ [0..7::Int] $ \g->do
        beginPreparation l c ob "Solana" 5000 "fixture-policy"
        [p]<-pendingPreparations l
        preparationGeneration p `shouldBe` g
        cancelFixture l p
        resumeAfterChecks l
      beginPreparation l c ob "Solana" 5000 "fixture-policy" `shouldThrow` isError "preparation_retry_not_authorized"
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM preparations" :: IO [Only Int]) `shouldReturn` [Only 8]
  describe "unsigned preparation recovery (offline RPC contracts)" $ do
    it "requires no locks when funding was interrupted before a draft could be saved" $ withDir $ \dir ->
      withNativeCancellationDraft False dir $ \l c p locks transport -> do
        let intent=obligationId (preparationObligation p)
        writeIORef locks [Outpoint (T.replicate 64 "f") 0]
        cancelPreparationWith (pure 100) transport c l intent 0 "lost funding response" `shouldThrow` isError "native_preparation_locks_require_review"
        map preparationDraft <$> pendingPreparations l `shouldReturn` [Nothing]
        -- Simulate the daemon restarting and losing its memory-only locks.
        writeIORef locks []
        _<-cancelPreparationWith (pure 100) transport c l intent 0 "lost funding response"
        pendingPreparations l `shouldReturn` []
    it "journals exact native cleanup, unlocks only saved inputs and does not sign or send" $ withNativeCancellation $ \l c p locks transport -> do
      let intent=obligationId (preparationObligation p)
      before<-ledgerAction l (\db->query_ db "SELECT event_id,asset,account,delta FROM postings ORDER BY id" :: IO [(Text,Text,Text,Int64)])
      result<-cancelPreparationWith (pure 100) transport c l intent 0 "abandoned unsigned payment"
      fieldValue "signedOrSent" result `shouldReturn` False
      readIORef locks `shouldReturn` []
      pendingPreparations l `shouldReturn` []
      pendingAttempts l `shouldReturn` []
      ledgerAction l (\db->query_ db "SELECT event_id,asset,account,delta FROM postings ORDER BY id" :: IO [(Text,Text,Text,Int64)]) `shouldReturn` before
      available <$> readiness l `shouldReturn` False
      let noIO=transport{paymentIdentity=expectationFailure "completed cancellation repeated chain IO"}
      cancelPreparationWith (pure 100) noIO c l intent 0 "abandoned unsigned payment" `shouldReturn` result
      cancelPreparationWith (pure 100) noIO c l intent 0 "different reason" `shouldThrow` isError "preparation_cancellation_conflict"
      resumeAfterChecks l
      beginPreparation l c (preparationObligation p) "Native" (preparationFeeLimit p) (preparationPolicy p)
      pause l "operator-action"
      cancelPreparationWith (pure 100) noIO c l intent 0 "abandoned unsigned payment" `shouldReturn` result
      map preparationGeneration <$> pendingPreparations l `shouldReturn` [1]
    it "keeps a lost unlock response pending and completes on reopen without blanket unlocking" $ withDir $ \dir -> do
      -- The reopened ledger and the RPC wallet state are independent fixtures.
      saved<-newIORef Nothing
      withNativeCancellationAt dir $ \l c p locks transport -> do
        let intent=obligationId (preparationObligation p)
            lost wallet method params=do
              result<-paymentNative transport wallet method params
              if method=="lockunspent" then reject "offline_lost_unlock_response" else pure result
        cancelPreparationWith (pure 100) transport{paymentNative=lost} c l intent 0 "retry cleanup"
          `shouldThrow` isError "offline_lost_unlock_response"
        readIORef locks `shouldReturn` []
        preparationCancellation l intent 0 >>= (`shouldSatisfy` maybe False (\(_,_,done)->not done))
        map preparationGeneration <$> pendingPreparations l `shouldReturn` [0]
        createRefund l (obligationDeposit $ preparationObligation p) `shouldReturn` preparationObligation p
        readyObligations l `shouldReturn` []
        writeIORef saved (Just (c,p,locks,transport))
      Just (c,p,locks,transport)<-readIORef saved
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        setupCustodyScans l c
        let noUnlock wallet method params=if method=="lockunspent" then expectationFailure "empty unlock would clear all locks" >> pure Null
              else paymentNative transport wallet method params
        _<-cancelPreparationWith (pure 100) transport{paymentNative=noUnlock} c l (obligationId $ preparationObligation p) 0 "retry cleanup"
        readIORef locks `shouldReturn` []
        pendingPreparations l `shouldReturn` []
        available <$> readiness l `shouldReturn` False
    it "refuses foreign locks and preserves the unfinished cleanup request" $ withNativeCancellation $ \l c p locks transport -> do
      let unknown=Outpoint (T.replicate 64 "f") 3
          intent=obligationId (preparationObligation p)
      modifyIORef' locks (<>[unknown])
      before<-readIORef locks
      cancelPreparationWith (pure 100) transport c l intent 0 "cancel known inputs" `shouldThrow` isError "native_preparation_locks_require_review"
      readIORef locks `shouldReturn` before
      preparationCancellation l intent 0 >>= (`shouldSatisfy` maybe False (\(_,_,done)->not done))
      ledgerAction l (\db->query_ db "SELECT resolved FROM intents" :: IO [Only Bool]) `shouldReturn` [Only False]
    it "does not cancel after a failed, stale or raced custody check" $ withNativeCancellation $ \l c p locks transport -> do
      before<-readIORef locks
      let intent=obligationId (preparationObligation p)
          changed wallet method params=do
            result<-paymentNative transport wallet method params
            pure $ if method=="getbalances" then setPath ["mine","trusted"] (toJSON $ nativeNumber $ amt 1) result else result
      cancelPreparationWith (pure 100) transport{paymentNative=changed} c l intent 0 "unsafe cleanup"
        `shouldThrow` isError "custody_not_reconciled"
      readIORef locks `shouldReturn` before
      preparationCancellation l intent 0 `shouldReturn` Nothing
      cancelPreparationWith (pure 161) transport c l intent 0 "unsafe cleanup"
        `shouldThrow` isError "custody_not_reconciled"
      readIORef locks `shouldReturn` before
      let raced wallet method params=do
            result<-paymentNative transport wallet method params
            when (method=="decodepsbt") $ fundAllocation l "concurrent-custody-change" Native "float" (amt 1)
            pure result
      cancelPreparationWith (pure 100) transport{paymentNative=raced} c l intent 0 "unsafe cleanup"
        `shouldThrow` isError "custody_not_reconciled"
      readIORef locks `shouldReturn` before
      preparationCancellation l intent 0 `shouldReturn` Nothing
    it "rejects a changed saved PSBT before any wallet unlock" $ withNativeCancellation $ \l c p locks transport -> do
      before<-readIORef locks
      let changed wallet method params=do
            result<-paymentNative transport wallet method params
            pure $ if method=="decodepsbt" then setPath ["tx","locktime"] (toJSON (1::Int)) result else result
      cancelPreparationWith (pure 100) transport{paymentNative=changed} c l (obligationId $ preparationObligation p) 0 "changed draft"
        `shouldThrow` isError "native_psbt_changed"
      readIORef locks `shouldReturn` before
      preparationCancellation l (obligationId $ preparationObligation p) 0 `shouldReturn` Nothing
    it "cancels an unsigned Solana request without a signer, a replacement or a signed-expiry proof" $ withSolanaLedger $ \l original plan _ -> do
      let c=expiryConfig original
      (_,ob)<-fundSolanaOrder l c plan
      let savedPlan=plan{solPlanReference=payoutReference c ob}
          limit=units $ either (error . T.unpack) id (solanaOperatingLimit savedPlan)
      beginPreparation l c ob "Solana" limit (fixtureJson savedPlan)
      storeDraft l (obligationId ob) (fixtureJson $ solanaPayoutRequest c savedPlan) 0
      setupCustodyScans l c
      pause l "unsigned-blockhash-expired"
      let base=custodyContract c (10004,10000,3000000) []
          native wallet method params=if method `elem` ["gettransaction","getaddressinfo","getblockheader"] || method=="getblockhash" && params==[toJSON (123::Int)]
            then sourceNativeContract 1 wallet method params else paymentNative base wallet method params
          transport=base{paymentNative=native}
      _<-cancelPreparationWith (pure 100) transport c l (obligationId ob) 0 "discard expired unsigned request"
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM solana_expiries" :: IO [Only Int]) `shouldReturn` [Only 0]
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(limit,False)]
      pendingAttempts l `shouldReturn` []
      readyObligations l `shouldReturn` [ob]
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
        storeDraft l (obligationId ob) "fixture-unsigned-draft" 0
        storeDraft l (obligationId ob) "fixture-unsigned-draft" 0
        storeDraft l (obligationId ob) "different-draft" 0 `shouldThrow` isError "preparation_draft_conflict"
      withLedger (dbPath c) (fingerprint c) $ \l -> do
        map preparationDraft <$> pendingPreparations l `shouldReturn` [Just "fixture-unsigned-draft"]
        pendingAttempts l `shouldReturn` []
        available <$> readiness l `shouldReturn` False
        resumeAfterChecks l `shouldThrow` isError "unresolved_intents_require_review"
        createRefund l "fixture-tx:0" `shouldThrow` isError "refund_would_race_payment"
    it "cannot store signed bytes without a prior durable preparation" $ withFunded $ \l c -> do
      (_,ob)<-fundOrder l c
      storeAttempt l ob "Solana" "signature" "bytes" "{}" 5000 Nothing 0 `shouldThrow` isError "payment_not_prepared"
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
  describe "durable native replacement drafts (offline recovery contracts)" $ do
    it "records the exact unsigned decision without changing money, holds or the old attempt" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      before<-auditExport l
      result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "operator fee increase"
      sequenceNo<-fieldValue "draftSequence" result :: IO Int64
      fieldValue "signedOrSent" result `shouldReturn` False
      fieldValue "cancelled" result `shouldReturn` False
      nativeReplacementDecision l (attemptId parent) (draftFee draft) "operator fee increase" `shouldReturn` Just (sequenceNo,False)
      ledgerAction l (\db->query_ db "SELECT draft_json FROM native_replacement_drafts" :: IO [Only Text]) `shouldReturn` [Only $ fixtureJson draft]
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,False)]
      pendingAttempts l `shouldReturn` [parent]
      auditExport l `shouldReturn` before
      available <$> readiness l `shouldReturn` False
      createRefund l ("native:"<>T.replicate 64 "a"<>":0") >>= \ob->obligationId ob `shouldBe` attemptIntent parent
    it "replays the same draft after reopening without another RPC or critical record" $ withDir $ \dir->do
      (c,parent,draft,transport,sequenceNo,saved)<-withReplacementDraftAt dir $ \l c parent draft transport->do
        result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "reviewed increase"
        sequenceNo<-fieldValue "draftSequence" result :: IO Int64
        snapshot<-auditExport l
        pure(c,parent,draft,transport,sequenceNo,snapshot)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        result<-prepareNativeReplacementWith (pure 999) transport{paymentIdentity=expectationFailure "replay contacted a chain"} c l (attemptId parent) (draftFee draft) "reviewed increase"
        fieldValue "draftSequence" result `shouldReturn` sequenceNo
        auditExport l `shouldReturn` saved
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_replacement_drafts" :: IO [Only Int]) `shouldReturn` [Only 1]
    it "cancels only the unsigned draft and permits a new explicit decision with the same original hold" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "first decision"
      sequenceNo<-fieldValue "draftSequence" result :: IO Int64
      before<-auditExport l
      recordNativeReplacementCancellation l sequenceNo "withdraw unsigned decision"
      recordNativeReplacementCancellation l sequenceNo "withdraw unsigned decision"
      recordNativeReplacementCancellation l sequenceNo "different cancellation" `shouldThrow` isError "native_replacement_cancellation_conflict"
      replay<-prepareNativeReplacementWith (pure 100) transport{paymentIdentity=expectationFailure "cancelled replay contacted a chain"} c l (attemptId parent) (draftFee draft) "first decision"
      fieldValue "cancelled" replay `shouldReturn` True
      next<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "new explicit decision"
      nextSequence<-fieldValue "draftSequence" next :: IO Int64
      nextSequence `shouldSatisfy` (>sequenceNo)
      pendingAttempts l `shouldReturn` [parent]
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,False)]
      auditExport l `shouldReturn` before
    it "refuses a competing active decision and changed replay bytes" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      _<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "first decision"
      before<-auditExport l
      recordNativeReplacementDraft l c parent draft "competing decision" 100 `shouldThrow` isError "native_replacement_draft_pending"
      recordNativeReplacementDraft l c parent draft{draftPsbt="changed offline template"} "first decision" 100 `shouldThrow` isError "native_replacement_draft_conflict"
      auditExport l `shouldReturn` before
    it "requires pause, current custody, and the unchanged parent broadcast decision" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft _->do
      ledgerAction l $ \db->execute_ db "UPDATE deployment SET paused=0"
      recordNativeReplacementDraft l c parent draft "review" 100 `shouldThrow` isError "pause_before_operator_action"
      pause l "operator review"
      recordNativeReplacementDraft l c parent draft "review" 100 `shouldThrow` isError "custody_not_reconciled"
      assumeSourceApprovalCustody l
      recordNativeReplacementDraft l c parent{attemptSequence=Just 999} draft "review" 100 `shouldThrow` isError "native_replacement_parent_changed"
      recordNativeReplacementDraft l c parent draft "review" 161 `shouldThrow` isError "custody_not_reconciled"
    it "does not save a draft when the source loses eligibility" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      let original=paymentNative transport
          changed wallet method params=do
            value<-original wallet method params
            pure $ case (method,params) of
              ("gettransaction",wanted:_) | wanted/=toJSON (attemptId parent)->setPath ["confirmations"] (toJSON (0::Int)) value
              _->value
      prepareNativeReplacementWith (pure 100) transport{paymentNative=changed} c l (attemptId parent) (draftFee draft) "review"
        `shouldThrow` isError "source_not_eligible"
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_replacement_drafts" :: IO [Only Int]) `shouldReturn` [Only 0]
      pendingAttempts l `shouldReturn` [parent]
    it "retains the original payment when a settlement callback arrives during drafting" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      let original=paymentNative transport
          changed wallet method params=do
            value<-original wallet method params
            when (method=="decodepsbt") $ recordSettlement l (attemptId parent) (PaymentCosts (amt 282) (amt 0))
              (nativeSettlementProof (attemptId parent) custodyNativeTip 1)
            pure value
      prepareNativeReplacementWith (pure 100) transport{paymentNative=changed} c l (attemptId parent) (draftFee draft) "review"
        `shouldThrow` isError "native_replacement_not_expected"
      ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only $ attemptId parent]
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_replacement_drafts" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "includes replacement cancellation in the work suspended by a source loss" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "review"
      sequenceNo<-fieldValue "draftSequence" result :: IO Int64
      [Only oid]<-ledgerAction l (\db->query db "SELECT order_id FROM obligations WHERE id=?" (Only $ attemptIntent parent) :: IO [Only Text])
      let txid=T.replicate 64 "a"
          source=Deposit ("native:"<>txid<>":0") (Just oid) Native (amt 100000) (T.replicate 64 "b") 1 True 100
      observeDeposit l source{depositAnchor="unconfirmed",depositConfirmations=0,depositEligible=False} custodyNativeTip
      recordNativeReplacementCancellation l sequenceNo "withdraw while source is reviewed"
      previous<-readCheckpoint l "Native"
      commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 [source]
        [ChainEvent txid "incoming" (depositAnchor source) (object ["confirmations" .= (1::Int)])])
      [Only proofHash]<-ledgerAction l (\db->query db "SELECT evidence_hash FROM chain_events WHERE chain='Native' AND event_id=?" (Only txid) :: IO [Only Text])
      recordSourceCheck l source (SourceRestored $ object ["observationHash" .= proofHash])
      restored<-sourceRestoration l source
      assumeSourceApprovalCustody l
      recordSourceRecoveryApproval l (attemptIntent parent) restored 100 "restore suspended work" `shouldThrow` isError "source_review_work_changed"
    it "bounds repeated cancelled decisions without multiplying the fee hold" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft _->do
      forM_ [1..7::Int] $ \n->do
        assumeSourceApprovalCustody l
        sequenceNo<-recordNativeReplacementDraft l c parent draft (T.pack $ show n) 100
        recordNativeReplacementCancellation l sequenceNo "cancel unsigned draft"
      assumeSourceApprovalCustody l
      recordNativeReplacementDraft l c parent draft "eighth decision" 100 `shouldThrow` isError "native_replacement_draft_limit"
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,False)]
    it "rolls back draft insertion and critical sequence on database failure" $ withDir $ \dir->do
      (c,parent,before,sequenceNo)<-withReplacementDraftAt dir $ \l c parent draft _->do
        assumeSourceApprovalCustody l
        before<-auditExport l
        [Only sequenceNo]<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER fail_draft_audit BEFORE INSERT ON audit WHEN NEW.action='native_replacement_drafted' BEGIN SELECT RAISE(ABORT,'offline_draft_failure'); END"
        recordNativeReplacementDraft l c parent draft "review" 100 `shouldThrow` (\err->sqlError err==ErrorConstraint)
        pure(c,parent,before,sequenceNo)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` before
        pendingAttempts l `shouldReturn` [parent]
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_replacement_drafts" :: IO [Only Int]) `shouldReturn` [Only 0]
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` [Only sequenceNo]
    it "makes the draft immutable and keeps it after a failed cancellation" $ withDir $ \dir->do
      (c,parent,draft,sequenceNo)<-withReplacementDraftAt dir $ \l c parent draft transport->do
        result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "review"
        sequenceNo<-fieldValue "draftSequence" result :: IO Int64
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER fail_cancel_audit BEFORE INSERT ON audit WHEN NEW.action='native_replacement_cancelled' BEGIN SELECT RAISE(ABORT,'offline_cancel_failure'); END"
        recordNativeReplacementCancellation l sequenceNo "cancel" `shouldThrow` (\err->sqlError err==ErrorConstraint)
        pure(c,parent,draft,sequenceNo)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        nativeReplacementDecision l (attemptId parent) (draftFee draft) "review" `shouldReturn` Just (sequenceNo,False)
        ledgerAction l (\db->execute_ db "DELETE FROM native_replacement_drafts") `shouldThrow` (\err->sqlError err==ErrorConstraint)
  describe "native payment families (offline lineage and RPC contracts)" $ do
    it "retains immutable lineage and one maximum fee hold; a signed draft cannot be cancelled" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members _ _ _->do
      let original=attempts!!0; newer=attempts!!1
      nativeFamilyAttempts l (attemptIntent original) `shouldReturn` attempts
      [Only sequenceNo]<-ledgerAction l (\db->query_ db "SELECT draft_sequence FROM native_replacement_members" :: IO [Only Int64])
      nativeReplacementMember l sequenceNo `shouldReturn` Just newer
      before<-auditExport l
      recordNativeReplacementMember l c sequenceNo [original] (members!!1) 999 `shouldReturn` newer
      recordNativeReplacementMember l c sequenceNo [original] (members!!1){signedNativeBytes="01"} 100
        `shouldThrow` isError "native_replacement_signature_conflict"
      recordNativeReplacementCancellation l sequenceNo "too late" `shouldThrow` isError "native_replacement_already_signed"
      nativeReplacementParent l c (attemptId original) `shouldThrow` isError "native_replacement_not_current"
      ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,False)]
      auditExport l `shouldReturn` before
    forM_ [0,1] $ \winner->it ("settles member "<>show winner<>" once, including after reopening") $ withDir $ \dir->do
      (c,saved,txid,transport)<-withNativeFamilyAt dir $ \l c attempts members mode transport calls->do
        writeIORef mode $ Just (winner,1)
        scanFamilyFixture l c members (Just (winner,1))
        result<-reconcilePaymentsWith transport c l
        recoveryOutcomes result `shouldReturn` ["settled"]
        let txid=attemptId $ attempts!!winner
            cost=units $ signedNativeFee $ members!!winner
        (fieldValue "attempts" result >>= mapM (fieldValue "transaction")) `shouldReturn` [txid]
        pendingAttempts l `shouldReturn` []
        ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only txid]
        ledgerAction l (\db->query_ db "SELECT delta FROM postings WHERE account='operating' AND delta<0" :: IO [Only Int64]) `shouldReturn` [Only $ negate cost]
        ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,True)]
        custody<-reconcileCustodyWith (pure 100) transport c l
        fieldValue "lastError" custody `shouldReturn` (Nothing::Maybe Text)
        readIORef calls >>= \xs->map fst xs `shouldSatisfy` all (`notElem` ["walletprocesspsbt","sendrawtransaction","createpsbt"])
        saved<-auditExport l
        pure(c,saved,txid,transport)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        (reconcilePaymentsWith transport c l >>= recoveryOutcomes) `shouldReturn` []
        auditExport l `shouldReturn` saved
        ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only txid]
    forM_ [0,1] $ \active->it ("normalizes only the mempool effect of member "<>show active) $ withDir $ \dir->withNativeFamilyAt dir $ \l c _ members mode transport _->do
      writeIORef mode $ Just (active,0)
      scanFamilyFixture l c members (Just (active,0))
      before<-auditExport l
      result<-reconcileCustodyWith (pure 100) transport c l
      fieldValue "lastError" result `shouldReturn` (Nothing::Maybe Text)
      effects<-fieldValue "report" result >>= fieldValue "inFlightEffects" :: IO [Value]
      length effects `shouldBe` 1
      mapM (fieldValue "transaction") effects `shouldReturn` [nativeTxid $ signedNativeTransaction $ members!!active]
      locks<-reconcileNativeLocksWith transport c l
      fieldValue "state" locks `shouldReturn` ("spent_by_recorded_family"::Text)
      fieldValue "restoredInputs" locks `shouldReturn` (0::Int)
      auditExport l `shouldReturn` before
    it "retains evicted family bytes and restores one shared lock set without any outgoing effect" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport calls->do
      writeIORef mode Nothing
      scanFamilyFixture l c members Nothing
      before<-auditExport l
      result<-reconcileCustodyWith (pure 100) transport c l
      fieldValue "lastError" result `shouldReturn` (Nothing::Maybe Text)
      (fieldValue "report" result >>= fieldValue "inFlightEffects") `shouldReturn` ([]::[Value])
      first<-reconcileNativeLocksWith transport c l
      second<-reconcileNativeLocksWith transport c l
      fieldValue "restoredInputs" first `shouldReturn` (1::Int)
      fieldValue "restoredInputs" second `shouldReturn` (0::Int)
      pendingAttempts l `shouldReturn` attempts
      auditExport l `shouldReturn` before
      readIORef calls >>= \xs->length (filter ((=="lockunspent").fst) xs) `shouldBe` 1
    it "keeps all funds when a signed-only member is observed on chain" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts _ _ transport _->do
      ledgerAction l $ \db->execute db "UPDATE attempts SET state='signed' WHERE txid=?" (Only $ attemptId $ attempts!!1)
      before<-auditExport l
      report<-reconcilePaymentsWith transport c l
      failures<-fieldValue "attempts" report >>= mapM (fieldValue "error") :: IO [Maybe Text]
      failures `shouldBe` [Just "unrecorded_broadcast_observed"]
      auditExport l `shouldReturn` before
    forM_ ["walletconflicts","mempoolconflicts"] $ \key->it ("rejects an unrelated "<>T.unpack key<>" member") $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts _ _ transport _->do
      let original=paymentNative transport
          altered wallet method params=do
            value<-original wallet method params
            pure $ case (method,params) of
              ("gettransaction",wanted:_) | wanted==toJSON (attemptId $ attempts!!0)->setPath [Key.fromText key] (toJSON [T.replicate 64 "f"]) value
              _->value
      before<-auditExport l
      result<-reconcileCustodyWith (pure 100) transport{paymentNative=altered} c l
      fieldValue "lastError" result `shouldReturn` Just ("native_family_unknown_conflict"::Text)
      auditExport l `shouldReturn` before
    it "rejects a spender outside the immutable family" $ withDir $ \dir->withNativeFamilyAt dir $ \l c _ _ _ transport _->do
      let original=paymentNative transport
          altered wallet method params=do
            value<-original wallet method params
            if method=="gettxspendingprevout" then do
              points<-parseValue parseJSON value :: IO [Value]
              pure $ toJSON $ map (setPath ["spendingtxid"] $ toJSON $ T.replicate 64 "f") points
             else pure value
      result<-reconcileCustodyWith (pure 100) transport{paymentNative=altered} c l
      fieldValue "lastError" result `shouldReturn` Just ("native_family_unknown_spender"::Text)
    it "cannot infer an absent family effect when its inputs are spent on an unknown chain payment" $ withDir $ \dir->withNativeFamilyAt dir $ \l c _ _ mode transport _->do
      writeIORef mode Nothing
      let original=paymentNative transport
          unavailable wallet method params=if method=="gettxout" then pure Null else original wallet method params
      result<-reconcileCustodyWith (pure 100) transport{paymentNative=unavailable} c l
      fieldValue "lastError" result `shouldReturn` Just ("native_input_unavailable"::Text)
    it "refuses contradictory proof that both shared-input members confirmed" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      let original=paymentNative transport
          altered wallet method params=do
            value<-original wallet method params
            pure $ case (method,params) of
              ("gettransaction",wanted:_) | wanted==toJSON (attemptId $ attempts!!0)->
                setPath ["blockhash"] (toJSON custodyNativeTip) $ setPath ["confirmations"] (toJSON (1::Int)) value
              _->value
      before<-auditExport l
      report<-reconcilePaymentsWith transport{paymentNative=altered} c l
      (fieldValue "attempts" report >>= mapM (fieldValue "error")) `shouldReturn` [Just ("native_family_multiple_winners"::Text)]
      auditExport l `shouldReturn` before
    it "discards a family view that changes between its two observations" $ withDir $ \dir->withNativeFamilyAt dir $ \l c _ _ mode transport _->do
      walletReads<-newIORef (0::Int)
      let original=paymentNative transport
          altered wallet method params=do
            value<-original wallet method params
            when (method=="getwalletinfo") $ do
              modifyIORef' walletReads (+1)
              n<-readIORef walletReads
              when (n==2) $ writeIORef mode $ Just (0,0)
            pure value
      before<-auditExport l
      report<-reconcilePaymentsWith transport{paymentNative=altered} c l
      (fieldValue "attempts" report >>= mapM (fieldValue "error")) `shouldReturn` [Just ("native_family_view_changed"::Text)]
      auditExport l `shouldReturn` before
    it "requires backup of the newest BroadcastIntent and prevents sending an older member" $ withDir $ \dir->withNativeFamilyAt dir $ \l _ attempts _ _ _ _->do
      let original=attempts!!0; newer=attempts!!1
      ledgerAction l $ \db->execute_ db "UPDATE deployment SET paused=0"
      markBroadcastIntent l (attemptId original) `shouldThrow` isError "native_replacement_not_current"
      authorizeRecordedSend l False (attemptId original) `shouldThrow` isError "native_replacement_not_current"
      sequenceNo<-markBroadcastIntent l (attemptId newer)
      authorizeRecordedSend l True (attemptId newer) `shouldThrow` isError "backup_pending"
      acknowledgeBackup l sequenceNo "offline family snapshot"
      authorizeRecordedSend l True (attemptId newer) `shouldReturn` newer
    forM_ [("cancelled","native_replacement_not_unsigned"),("changed hold","native_replacement_work_changed")]
      $ \(condition,code)->it ("rejects a signature callback after "<>T.unpack condition<>" work") $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
        original<-nativeSignedFixture
        result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "late callback test"
        sequenceNo<-fieldValue "draftSequence" result
        if condition=="cancelled" then recordNativeReplacementCancellation l sequenceNo "withdraw unsigned decision"
          else ledgerAction l $ \db->execute_ db "UPDATE fee_reservations SET amount=amount+1"
        assumeSourceApprovalCustody l
        before<-auditExport l
        recordNativeReplacementMember l c sequenceNo [parent] (replacementFixtureSigned original draft) 100 `shouldThrow` isError code
        pendingAttempts l `shouldReturn` [parent]
        auditExport l `shouldReturn` before
    it "rolls back the member, signed bytes and sequence if its critical audit write fails" $ withDir $ \dir->do
      (c,parent,before,sequenceNo)<-withReplacementDraftAt dir $ \l c parent draft transport->do
        original<-nativeSignedFixture
        result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "failure test"
        draftSequence<-fieldValue "draftSequence" result
        assumeSourceApprovalCustody l
        before<-auditExport l
        [Only sequenceNo]<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER fail_member_audit BEFORE INSERT ON audit WHEN NEW.action='native_replacement_signed' BEGIN SELECT RAISE(ABORT,'offline_member_failure'); END"
        recordNativeReplacementMember l c draftSequence [parent] (replacementFixtureSigned original draft) 100 `shouldThrow` (\err->sqlError err==ErrorConstraint)
        pure(c,parent,before,sequenceNo)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        pendingAttempts l `shouldReturn` [parent]
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_replacement_members" :: IO [Only Int]) `shouldReturn` [Only 0]
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` [Only sequenceNo]
    it "blocks a new send while an unsigned replacement decision is outstanding" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "unsigned send fence"
      sequenceNo<-fieldValue "draftSequence" result
      markBroadcastIntent l (attemptId parent) `shouldThrow` isError "native_replacement_draft_pending"
      recordNativeReplacementCancellation l sequenceNo "keep original payment"
      markBroadcastIntent l (attemptId parent) `shouldReturn` maybe 0 id (attemptSequence parent)
    it "does not accept a plausible sibling with no durable operator lineage" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      original<-nativeSignedFixture
      let sibling=replacementFixtureSigned original draft
          txid=nativeTxid $ signedNativeTransaction sibling
      ledgerAction l $ \db->execute db "INSERT INTO attempts(txid,intent_id,signed_bytes,policy_json,fee_limit,state,critical_sequence,preparation_generation) SELECT ?,intent_id,?,?,fee_limit,state,critical_sequence,preparation_generation FROM attempts WHERE txid=?"
        (txid,signedNativeBytes sibling,fixtureJson sibling,attemptId parent)
      attempts<-pendingAttempts l
      before<-auditExport l
      readSavedNativeFamily transport c l attempts `shouldThrow` isError "native_replacement_lineage_missing"
      auditExport l `shouldReturn` before
    it "retains review when a losing wallet record lacks its alleged confirmed winner" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      let original=paymentNative transport
          missing wallet method params=case (method,params) of
            ("gettransaction",wanted:_) | wanted==toJSON (attemptId $ attempts!!1)->reject "rpc_error_-5"
            _->original wallet method params
      before<-auditExport l
      report<-reconcilePaymentsWith transport{paymentNative=missing} c l
      (fieldValue "attempts" report >>= mapM (fieldValue "error")) `shouldReturn` [Just ("native_family_conflict_not_proven"::Text)]
      auditExport l `shouldReturn` before
    it "retains the booked winner through finality loss and reconfirms it without changing money" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      (reconcilePaymentsWith transport c l >>= recoveryOutcomes) `shouldReturn` ["settled"]
      before<-auditExport l
      writeIORef mode $ Just (1,0)
      scanFamilyFixture l c members (Just (1,0))
      confirming<-reconcileNativeSettlementsWith transport c l
      (fieldValue "payments" confirming >>= mapM (fieldValue "state")) `shouldReturn` ["confirming"::Text]
      result<-reconcileCustodyWith (pure 100) transport c l
      fieldValue "lastError" result `shouldReturn` Just ("native_settlement_requires_review"::Text)
      pendingAttempts l `shouldReturn` []
      ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only $ attemptId $ attempts!!1]
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      restored<-reconcileNativeSettlementsWith transport c l
      (fieldValue "payments" restored >>= mapM (fieldValue "state")) `shouldReturn` ["reconfirmed"::Text]
      auditExport l `shouldReturn` before
    it "refuses signing context when the original common input binding is missing" $ withDir $ \dir->withReplacementDraftAt dir $ \l c parent draft transport->do
      ledgerAction l $ \db->execute_ db "UPDATE intents SET common_input=NULL"
      result<-prepareNativeReplacementWith (pure 100) transport c l (attemptId parent) (draftFee draft) "invalid common input"
      sequenceNo<-fieldValue "draftSequence" result
      nativeReplacementSigningContext l c sequenceNo `shouldThrow` isError "native_replacement_common_input_changed"
    it "keeps a subsequently observed unrecorded sibling quarantined in an older ledger" $ withDir $ \dir->withReplacementDraftAt dir $ \l c _ draft _->do
      previous<-readCheckpoint l "Native"
      let txid=nativeTxid $ draftTransaction draft
      commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 []
        [ChainEvent txid "outgoing" custodyNativeTip (object ["confirmations" .= (1::Int),"walletNetUnits" .= ("-100000"::Text),"feeUnits" .= draftFee draft])])
      ledgerAction l (\db->query db "SELECT needs_review FROM chain_events WHERE event_id=?" (Only txid) :: IO [Only Bool]) `shouldReturn` [Only True]
      length <$> pendingAttempts l `shouldReturn` 1
      available <$> readiness l `shouldReturn` False
  describe "native winner changes (offline reorg accounting)" $ do
    forM_ [0,1] $ \first->it ("transfers member "<>show first<>" through repeated winner changes and restart without rebooking principal") $ withDir $ \dir->do
      (c,transport,saved,finalTx)<-withNativeFamilyAt dir $ \l c attempts members mode transport calls->do
        let other=1-first
            tx i=attemptId $ attempts!!i
            fee i=units $ signedNativeFee $ members!!i
            delta=fee other-fee first
        writeIORef mode $ Just (first,1)
        scanFamilyFixture l c members (Just (first,1))
        (reconcilePaymentsWith transport c l >>= recoveryOutcomes) `shouldReturn` ["settled"]
        principal<-ledgerAction l (\db->query_ db "SELECT asset,account,delta FROM postings WHERE event_id LIKE 'settlement:%' ORDER BY id" :: IO [(Text,Text,Int64)])
        forM_ [other,first,other] $ \winner->do
          writeIORef mode $ Just (winner,1)
          scanFamilyFixture l c members (Just (winner,1))
          result<-reconcileNativeSettlementsWith transport c l
          nativeSettlementStates result `shouldReturn` ["winner_changed"]
          fieldValue "monetaryPostings" result `shouldReturn` True
          (fieldValue "payments" result >>= mapM (fieldValue "transaction")) `shouldReturn` [tx winner]
          ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only $ tx winner]
          ledgerAction l (\db->query_ db "SELECT payout_tx FROM orders" :: IO [Only Text]) `shouldReturn` [Only $ tx winner]
          ledgerAction l (\db->query_ db "SELECT asset,account,delta FROM postings WHERE event_id LIKE 'settlement:%' ORDER BY id" :: IO [(Text,Text,Int64)]) `shouldReturn` principal
          pendingAttempts l `shouldReturn` []
          ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,True)]
          custody<-reconcileCustodyWith (pure 100) transport c l
          fieldValue "lastError" custody `shouldReturn` (Nothing::Maybe Text)
          readiness l `shouldReturn` Availability False "native_winner_changed"
          before<-auditExport l
          (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` []
          auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT fee_delta FROM native_winner_changes ORDER BY critical_sequence" :: IO [Only Int64]) `shouldReturn` map Only [delta,negate delta,delta]
        ledgerAction l (\db->operatingTime db >>= operatingSpent db "Native") `shouldReturn` toInteger (fee first+2*max delta 0+max (negate delta) 0)
        ledgerAction l (\db->query_ db "SELECT COALESCE(SUM(delta),0) FROM postings WHERE asset='Native' AND account='operating' AND (event_id LIKE 'network-fee:%' OR event_id LIKE 'native-winner-fee:%')" :: IO [Only Int64]) `shouldReturn` [Only $ negate $ fee other]
        recordSettlement l (tx first) (PaymentCosts (signedNativeFee $ members!!first) (amt 0)) "late original callback" `shouldThrow` isError "settlement_not_expected"
        readIORef calls >>= \xs->map fst xs `shouldSatisfy` all (`notElem` ["walletprocesspsbt","sendrawtransaction","createpsbt"])
        saved<-auditExport l
        pure(c,transport,saved,tx other)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` []
        auditExport l `shouldReturn` saved
        ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only finalTx]
    it "supersedes old finality reviews and opens a fresh review if the new winner later disappears" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      forM_ [1,0] $ \winner->do
        writeIORef mode Nothing
        scanFamilyFixture l c members Nothing
        (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` ["requires_review"]
        writeIORef mode $ Just (winner,1)
        scanFamilyFixture l c members (Just (winner,1))
        (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` ["winner_changed"]
        ledgerAction l (\db->query_ db "SELECT txid FROM native_payment_recovery_state WHERE state<>'reconfirmed'" :: IO [Only Text]) `shouldReturn` []
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_payment_recoveries" :: IO [Only Int]) `shouldReturn` [Only 2]
      writeIORef mode Nothing
      scanFamilyFixture l c members Nothing
      (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` ["requires_review"]
      ledgerAction l (\db->query_ db "SELECT txid FROM native_payment_recovery_state WHERE state<>'reconfirmed'" :: IO [Only Text]) `shouldReturn` [Only $ attemptId $ attempts!!0]
      resumeAfterChecks l `shouldThrow` isError "native_settlement_requires_review"
    forM_ ["depth","block","fee","amount","missing"] $ \change->it ("retains the old settlement when the new winner's durable scan has changed "<>T.unpack change) $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      before<-auditExport l
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      let txid=attemptId $ attempts!!1
          anchor=if change=="block" then "unconfirmed" else custodyNativeTip
          evidence=object ["confirmations" .= (if change=="depth" then 0::Int else 1)
            ,"walletNetUnits" .= (if change=="amount" then "-99999" else "-100000"::Text)
            ,"feeUnits" .= (if change=="fee" then amt 999 else signedNativeFee $ members!!1)]
      if change=="missing" then ledgerAction l (\db->execute db "DELETE FROM chain_events WHERE chain='Native' AND event_id=?" (Only txid))
        else do
          previous<-readCheckpoint l "Native"
          commitScan l (ScanBatch "Native" (nativeCheckpointHash c) previous custodyNativeTip 100 [] [ChainEvent txid "outgoing" anchor evidence])
      result<-reconcileNativeSettlementsWith transport c l
      (fieldValue "payments" result >>= mapM (fieldValue "error")) `shouldReturn` [Just ("native_recovery_scan_not_current"::Text)]
      fieldValue "monetaryPostings" result `shouldReturn` False
      auditExport l `shouldReturn` before
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_winner_changes" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "cannot treat an arbitrary reviewed member as an earlier settled winner" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      ledgerAction l $ \db->execute db "UPDATE attempts SET state='review' WHERE txid=?" (Only $ attemptId $ attempts!!1)
      before<-auditExport l
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      result<-reconcileNativeSettlementsWith transport c l
      (fieldValue "payments" result >>= mapM (fieldValue "error")) `shouldReturn` [Just ("native_family_review_not_a_previous_winner"::Text)]
      auditExport l `shouldReturn` before
    it "preserves a primary conversion link when an additional refund changes winner" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      ledgerAction l $ \db->execute_ db "UPDATE orders SET status='Paid',payout_tx='offline-primary-conversion'"
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` ["winner_changed"]
      [Only oid]<-ledgerAction l (\db->query db "SELECT order_id FROM obligations WHERE id=?" (Only $ attemptIntent $ attempts!!0))
      customer<-readOrder l cap oid
      status customer `shouldBe` "Paid"
      payoutTx customer `shouldBe` Just "offline-primary-conversion"
    forM_ ["postings","audit"] $ \failure->it ("rolls back all winner changes after a "<>T.unpack failure<>" failure and recovers once after restart") $ withDir $ \dir->do
      (c,transport,before,oldWinner,sequenceNo)<-withNativeFamilyAt dir $ \l c attempts members mode transport _->do
        writeIORef mode $ Just (0,1)
        scanFamilyFixture l c members (Just (0,1))
        _<-reconcilePaymentsWith transport c l
        before<-auditExport l
        [Only sequenceNo]<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
        writeIORef mode $ Just (1,1)
        scanFamilyFixture l c members (Just (1,1))
        ledgerAction l $ \db->execute_ db $ if failure=="postings"
          then "CREATE TRIGGER refuse_winner_change BEFORE INSERT ON postings WHEN NEW.event_id LIKE 'native-winner-fee:%' BEGIN SELECT RAISE(ABORT,'offline_winner_failure'); END"
          else "CREATE TRIGGER refuse_winner_change BEFORE INSERT ON audit WHEN NEW.action='native_winner_changed' BEGIN SELECT RAISE(ABORT,'offline_winner_failure'); END"
        reconcileNativeSettlementsWith transport c l `shouldThrow` (\err->sqlError err==ErrorConstraint)
        pure(c,transport,before,attemptId $ attempts!!0,sequenceNo)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only oldWinner]
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_winner_changes" :: IO [Only Int]) `shouldReturn` [Only 0]
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` [Only sequenceNo]
        ledgerAction l $ \db->execute_ db "DROP TRIGGER refuse_winner_change"
        (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` ["winner_changed"]
        saved<-auditExport l
        (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` []
        auditExport l `shouldReturn` saved
        ledgerAction l (\db->execute_ db "DELETE FROM native_winner_changes") `shouldThrow` (\err->sqlError err==ErrorConstraint)
    it "fences changed cost, policy, family and concurrent stale callbacks" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      family<-nativeFamilyAttempts l (attemptIntent $ attempts!!0)
      let old=family!!0
          winner=attemptId $ family!!1
          cost=PaymentCosts (signedNativeFee $ members!!1) (amt 0)
          proof=nativeSettlementProof winner custodyNativeTip 1
      previous<-nativeSettlementPrevious l old
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      before<-auditExport l
      recordNativeSettlementCheck l old previous (NativeSettlementReplaced family winner cost{networkFee=amt 999} proof) `shouldThrow` isError "native_recovery_cost_changed"
      recordNativeSettlementCheck l old previous (NativeSettlementReplaced family winner cost{accountRent=amt 1} proof) `shouldThrow` isError "native_recovery_cost_changed"
      recordNativeSettlementCheck l old previous (NativeSettlementReplaced family winner cost (nativeSettlementProof winner custodyNativeTip 2)) `shouldThrow` isError "native_recovery_policy_changed"
      recordNativeSettlementCheck l old previous (NativeSettlementReplaced (drop 1 family) winner cost proof) `shouldThrow` isError "native_replacement_family_changed"
      auditExport l `shouldReturn` before
      results<-mapConcurrently (\_->try (recordNativeSettlementCheck l old previous $ NativeSettlementReplaced family winner cost proof) :: IO (Either BridgeError ())) [0,1::Int]
      length [() | Right ()<-results] `shouldBe` 1
      [code | Left (BridgeError code)<-results] `shouldBe` ["native_settlement_changed"]
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_winner_changes" :: IO [Only Int]) `shouldReturn` [Only 1]
    it "keeps an independent source review after the destination winner changes" $ withDir $ \dir->withNativeFamilyAt dir $ \l c attempts members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      [(did,sourceOrder,n,anchor,depth,eligible,seen)]<-ledgerAction l (\db->query_ db "SELECT id,order_id,amount,anchor,confirmations,eligible,first_seen FROM deposits WHERE allocated=1" :: IO [(Text,Maybe Text,Int64,Text,Int,Bool,Int64)])
      let source=Deposit did sourceOrder Native (amt $ toInteger n) anchor depth eligible seen
      recordSourceCheck l source (SourceUnavailable $ object ["reason" .= ("offline source history unavailable"::Text)])
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` ["winner_changed"]
      [Only oid]<-ledgerAction l (\db->query db "SELECT order_id FROM obligations WHERE id=?" (Only $ attemptIntent $ attempts!!0))
      status <$> readOrder l cap oid `shouldReturn` "NeedsReview"
      resumeAfterChecks l `shouldThrow` isError "source_recovery_requires_review"
      ledgerAction l (\db->query_ db "SELECT state FROM source_recovery_state" :: IO [Only Text]) `shouldReturn` [Only "unavailable"]
    it "books a proved higher fee after operating capital was exhausted and blocks resume" $ withDir $ \dir->withNativeFamilyAt dir $ \l c _ members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      ledgerAction l $ \db->do
        allocation<-freeOperating db "Native"
        execute_ db "INSERT INTO events(id,description) VALUES('offline-reallocation','offline operating capital exhaustion')"
        execute db "INSERT INTO postings(event_id,asset,account,delta) VALUES('offline-reallocation','Native','operating',?)" (Only $ fromInteger $ negate allocation::Only Int64)
        execute db "INSERT INTO postings(event_id,asset,account,delta) VALUES('offline-reallocation','Native','float',?)" (Only $ fromInteger allocation::Only Int64)
      writeIORef mode $ Just (1,1)
      scanFamilyFixture l c members (Just (1,1))
      (reconcileNativeSettlementsWith transport c l >>= nativeSettlementStates) `shouldReturn` ["winner_changed"]
      ledgerAction l (\db->freeOperating db "Native") `shouldReturn` (-100)
      custody<-reconcileCustodyWith (pure 100) transport c l
      fieldValue "lastError" custody `shouldReturn` (Nothing::Maybe Text)
      resumeAfterChecks l `shouldThrow` isError "operating_allocation_requires_funding"
      available <$> readiness l `shouldReturn` False
    it "cannot change the booked fee for an unconfirmed or unavailable competing member" $ withDir $ \dir->withNativeFamilyAt dir $ \l c _ members mode transport _->do
      writeIORef mode $ Just (0,1)
      scanFamilyFixture l c members (Just (0,1))
      _<-reconcilePaymentsWith transport c l
      before<-auditExport l
      forM_ [(Just (1,0),"confirming"),(Nothing,"requires_review")] $ \(position,state)->do
        writeIORef mode position
        scanFamilyFixture l c members position
        result<-reconcileNativeSettlementsWith transport c l
        nativeSettlementStates result `shouldReturn` [state]
        fieldValue "monetaryPostings" result `shouldReturn` False
        auditExport l `shouldReturn` before
        pendingAttempts l `shouldReturn` []
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_winner_changes" :: IO [Only Int]) `shouldReturn` [Only 0]
  describe "native replacement signing (offline daemon contracts)" $ do
    forM_ [("recipient owned","bridge_owned_destination"),("change missing","native_input_or_change_not_owned")
      ,("recipient script","native_output_ownership_changed"),("change script","native_output_ownership_changed")]
      $ \(changed,code)->it ("refuses "<>T.unpack changed<>" before invoking the signer") $ withDir $ \dir->withReplacementSignerAt dir $ \l c parent _ sequenceNo transport calls->do
        originalPayment<-nativeSignedFixture
        let plan=signedNativePlan originalPayment
            original=paymentNative transport
            altered wallet method params=do
              value<-original wallet method params
              pure $ case (method,params) of
                ("getaddressinfo",[address]) | address==toJSON (planRecipient plan) && changed=="recipient owned"->setPath ["ismine"] (Bool True) value
                ("getaddressinfo",[address]) | address==toJSON (planChange plan) && changed=="change missing"->setPath ["ismine"] (Bool False) value
                ("getaddressinfo",[address]) | address==toJSON (planRecipient plan) && changed=="recipient script"
                  || address==toJSON (planChange plan) && changed=="change script"->setPath ["scriptPubKey"] (toJSON $ "0014"<>T.replicate 40 "f") value
                _->value
        before<-auditExport l
        signNativeReplacementWith (pure 100) transport{paymentNative=altered} c l sequenceNo `shouldThrow` isError code
        nativeReplacementMember l sequenceNo `shouldReturn` Nothing
        pendingAttempts l `shouldReturn` [parent]
        auditExport l `shouldReturn` before
        readIORef calls >>= \requests->map fst requests `shouldSatisfy` all (`notElem` ["walletprocesspsbt","finalizepsbt","sendrawtransaction"])
    it "signs the saved template once, persists it before any broadcast decision and reuses it on replay" $ withDir $ \dir->withReplacementSignerAt dir $ \l c parent draft sequenceNo transport calls->do
      before<-auditExport l
      member<-signNativeReplacementWith (pure 100) transport c l sequenceNo
      attemptId member `shouldBe` nativeTxid (draftTransaction draft)
      attemptState member `shouldBe` "signed"
      attemptBytes member `shouldBe` "00"
      attemptSequence member `shouldBe` Nothing
      nativeFamilyAttempts l (attemptIntent parent) `shouldReturn` [parent,member]
      nativeReplacementMember l sequenceNo `shouldReturn` Just member
      signNativeReplacementWith (pure 100) transport{paymentIdentity=expectationFailure "replay contacted chain"} c l sequenceNo `shouldReturn` member
      auditExport l `shouldReturn` before
      requests<-readIORef calls
      length (filter ((=="walletprocesspsbt").fst) requests) `shouldBe` 1
      map fst requests `shouldSatisfy` all (`notElem` ["sendrawtransaction","getrawchangeaddress","walletcreatefundedpsbt"])
      let methods=map fst requests
      (elemIndex "walletprocesspsbt" methods,elemIndex "testmempoolaccept" methods) `shouldSatisfy` \case
        (Just signed,Just checked)->signed<checked; _->False
    forM_ ["rejected","lost reply"] $ \failure->it ("keeps the original when the signer is "<>T.unpack failure) $ withDir $ \dir->withReplacementSignerAt dir $ \l c parent _ sequenceNo transport calls->do
      let original=paymentNative transport
          altered wallet method params
            | failure=="lost reply" && method=="walletprocesspsbt"=reject "offline_lost_signer_reply"
            | failure=="rejected" && method=="testmempoolaccept"=do
                result<-original wallet method params
                values<-parseValue parseJSON result :: IO [Value]
                pure $ toJSON $ map (setPath ["allowed"] $ Bool False) values
            | otherwise=original wallet method params
      before<-auditExport l
      signNativeReplacementWith (pure 100) transport{paymentNative=altered} c l sequenceNo
        `shouldThrow` isError (if failure=="rejected" then "native_transaction_not_accepted" else "offline_lost_signer_reply")
      nativeReplacementMember l sequenceNo `shouldReturn` Nothing
      pendingAttempts l `shouldReturn` [parent]
      auditExport l `shouldReturn` before
      readIORef calls >>= \requests->map fst requests `shouldSatisfy` all (/="sendrawtransaction")
    it "cannot persist a late signature after cancellation while the signer is running" $ withDir $ \dir->withReplacementSignerAt dir $ \l c parent _ sequenceNo transport _->do
      let original=paymentNative transport
          altered wallet method params=do
            result<-original wallet method params
            when (method=="walletprocesspsbt") $ recordNativeReplacementCancellation l sequenceNo "cancel concurrent signing"
            pure result
      before<-auditExport l
      signNativeReplacementWith (pure 100) transport{paymentNative=altered} c l sequenceNo `shouldThrow` isError "native_replacement_not_unsigned"
      nativeReplacementMember l sequenceNo `shouldReturn` Nothing
      pendingAttempts l `shouldReturn` [parent]
      auditExport l `shouldReturn` before
    it "rechecks the bound source after signing and retains all funds if it lost eligibility" $ withDir $ \dir->withReplacementSignerAt dir $ \l c parent _ sequenceNo transport _->do
      signed<-newIORef False
      let original=paymentNative transport
          altered wallet method params=do
            result<-original wallet method params
            when (method=="finalizepsbt") $ writeIORef signed True
            done<-readIORef signed
            pure $ case (method,params) of
              ("gettransaction",wanted:_) | done && wanted/=toJSON (attemptId parent)->setPath ["confirmations"] (toJSON (0::Int)) result
              _->result
      before<-auditExport l
      signNativeReplacementWith (pure 100) transport{paymentNative=altered} c l sequenceNo `shouldThrow` isError "source_not_eligible"
      nativeReplacementMember l sequenceNo `shouldReturn` Nothing
      pendingAttempts l `shouldReturn` [parent]
      after<-auditExport l
      forM_ ["balances","events"] $ \key->do
        saved<-fieldValue key before :: IO Value
        fieldValue key after `shouldReturn` saved
      ledgerAction l (\db->query db "SELECT status FROM obligations WHERE id=?" (Only $ attemptIntent parent) :: IO [Only Text]) `shouldReturn` [Only "review"]
  describe "one economic settlement per intent (offline competing callbacks)" $ do
    forM_ [False,True] $ \newer->it ("books only the "<>(if newer then "newer" else "older")<>" winner and preserves it across restart") $ withDir $ \dir->do
      (c,winner,loser,cost,proof,snapshot)<-withCompetingNativeAt dir $ \l c original other->do
        let winner=if newer then other else original
            loser=if newer then original else other
            cost=PaymentCosts (amt $ if newer then 382 else 282) (amt 0)
            proof="offline-confirmed:"<>winner
        before<-auditExport l
        ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,False)]
        recordSettlement l winner cost proof
        saved<-auditExport l
        saved `shouldNotBe` before
        recordSettlement l loser (PaymentCosts (amt 400) (amt 0)) "contradictory offline callback" `shouldThrow` isError "payment_intent_not_settleable"
        recordSettlement l winner cost proof
        auditExport l `shouldReturn` saved
        pendingAttempts l `shouldReturn` []
        ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only winner]
        ledgerAction l (\db->query_ db "SELECT payout_tx FROM orders" :: IO [Only Text]) `shouldReturn` [Only winner]
        ledgerAction l (\db->query db "SELECT delta FROM postings WHERE event_id=? AND account='operating'" (Only $ "network-fee:"<>winner) :: IO [Only Int64]) `shouldReturn` [Only $ negate $ units $ networkFee cost]
        pure(c,winner,loser,cost,proof,saved)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        recordSettlement l loser (PaymentCosts (amt 400) (amt 0)) "late offline callback" `shouldThrow` isError "payment_intent_not_settleable"
        recordSettlement l winner cost proof
        auditExport l `shouldReturn` snapshot
    it "serializes concurrent confirmations into exactly one payout and one network cost" $ withDir $ \dir->withCompetingNativeAt dir $ \l _ original other->do
      outcomes<-mapConcurrently (\txid->try (recordSettlement l txid (PaymentCosts (amt 300) (amt 0)) ("offline:"<>txid)) :: IO (Either BridgeError ())) [original,other]
      length [() | Right ()<-outcomes] `shouldBe` 1
      [code | Left (BridgeError code)<-outcomes] `shouldBe` ["payment_intent_not_settleable"]
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM events WHERE id LIKE 'settlement:%'" :: IO [Only Int]) `shouldReturn` [Only 1]
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM events WHERE id LIKE 'network-fee:%'" :: IO [Only Int]) `shouldReturn` [Only 1]
    forM_ [("released fee hold","UPDATE fee_reservations SET released=1")
          ,("wrong fee asset","UPDATE fee_reservations SET asset='Sol'")
          ,("resolved intent","UPDATE intents SET resolved=1")
          ,("cancelled obligation","UPDATE obligations SET status='cancelled'")] $ \(caseName,sql)->
      it ("refuses a callback with a "<>caseName) $ withDir $ \dir->withCompetingNativeAt dir $ \l _ original _->do
        ledgerAction l $ \db->execute_ db sql
        before<-auditExport l
        recordSettlement l original (PaymentCosts (amt 282) (amt 0)) "offline proof" `shouldThrow` isError "payment_intent_not_settleable"
        auditExport l `shouldReturn` before
    it "cannot pay a second member after accidental reopening of the paid intent" $ withDir $ \dir->withCompetingNativeAt dir $ \l _ original other->do
      recordSettlement l original (PaymentCosts (amt 282) (amt 0)) "offline original proof"
      ledgerAction l $ \db->do
        execute_ db "UPDATE intents SET resolved=0"
        execute_ db "UPDATE obligations SET status='paying'"
        execute_ db "UPDATE fee_reservations SET released=0"
      before<-auditExport l
      recordSettlement l other (PaymentCosts (amt 382) (amt 0)) "offline duplicate" `shouldThrow` isError "payment_intent_not_settleable"
      auditExport l `shouldReturn` before
    it "enforces the unique winner in SQLite and preserves the earlier result after reopening" $ withDir $ \dir->do
      (c,winner,saved)<-withCompetingNativeAt dir $ \l c original other->do
        recordSettlement l original (PaymentCosts (amt 282) (amt 0)) "offline original proof"
        snapshot<-auditExport l
        ledgerAction l (\db->execute db "UPDATE attempts SET state='settled' WHERE txid=?" (Only other))
          `shouldThrow` (\err->sqlError err==ErrorConstraint)
        readiness l `shouldThrow` isError "ledger_requires_reopen"
        pure(c,original,snapshot)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` saved
        ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only winner]
    it "rolls back money and winner selection together if recording the winner fails" $ withDir $ \dir->do
      (c,other,saved)<-withCompetingNativeAt dir $ \l c original other->do
        before<-auditExport l
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER fail_winner BEFORE UPDATE OF state ON attempts WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'offline_winner_failure'); END"
        recordSettlement l original (PaymentCosts (amt 282) (amt 0)) "offline original proof" `shouldThrow` (\err->sqlError err==ErrorConstraint)
        pure(c,other,before)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` saved
        ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` [(1000,False)]
        ledgerAction l $ \db->execute_ db "DROP TRIGGER fail_winner"
        recordSettlement l other (PaymentCosts (amt 382) (amt 0)) "offline verified later callback"
        ledgerAction l (\db->query_ db "SELECT txid FROM attempts WHERE state='settled'" :: IO [Only Text]) `shouldReturn` [Only other]
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
    it "allocates a finalized SOL operating receipt once across reopening" $ withDir $ \dir -> do
      let c=cfg dir; sig=base58 (BS.replicate 64 7); did="sol-operating:"<>sig
          receipt=Deposit did Nothing Sol (amt 10000) "100" 1 True 100
          event=ChainEvent sig "unmatched_incoming" "100" (object ["delta" .= ("10000"::Text),"failed" .= False])
      withLedger (dbPath c) (fingerprint c) $ \l->do
        observeDeposit l receipt "origin"
        allocateSolOperatingReceipt l sig (amt 10000) `shouldThrow` isError "verified_operating_receipt_required"
        commitScan l (ScanBatch "SolanaOperating" "origin" (Just "origin") sig 100 [] [event])
        allocateSolOperatingReceipt l sig (amt 9999) `shouldThrow` isError "verified_operating_receipt_required"
        allocateSolOperatingReceipt l sig (amt 10000)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        allocateSolOperatingReceipt l sig (amt 10000)
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64]) `shouldReturn` [Only 1]
        ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings WHERE asset='Sol' AND account='operating'" :: IO [Only Int64]) `shouldReturn` [Only 10000]
        ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings WHERE asset='Sol' AND account<>'external'" :: IO [Only Int64]) `shouldReturn` [Only 10000]
    forM_ [Native,Wrapped] $ \asset->it ("refuses "<>show asset<>" principal as operating SOL") $ withDir $ \dir->do
      let c=cfg dir; sig=base58 (BS.replicate 64 7)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        observeDeposit l (Deposit ("sol-operating:"<>sig) Nothing asset (amt 10000) "100" 1 True 100) "cursor"
        let event=ChainEvent sig "unmatched_incoming" "100" (object ["delta" .= ("10000"::Text),"failed" .= False])
        commitScan l (ScanBatch "SolanaOperating" "origin" Nothing sig 100 [] [event])
        allocateSolOperatingReceipt l sig (amt 10000) `shouldThrow` isError "verified_operating_receipt_required"
    it "refuses an operating receipt whose scanner evidence requires review" $ withDir $ \dir->do
      let c=cfg dir; sig=base58 (BS.replicate 64 7)
      withLedger (dbPath c) (fingerprint c) $ \l->do
        let receipt=Deposit ("sol-operating:"<>sig) Nothing Sol (amt 10000) "100" 1 True 100
            event=ChainEvent sig "unclassified" "100" (object ["delta" .= ("10000"::Text),"failed" .= False])
        commitScan l (ScanBatch "SolanaOperating" "origin" Nothing sig 100 [receipt] [event])
        allocateSolOperatingReceipt l sig (amt 10000) `shouldThrow` isError "verified_operating_receipt_required"
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
      available <$> readiness l `shouldReturn` True
      checkCustodyFresh l 100 `shouldThrow` isError "custody_not_reconciled"
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
      available <$> readiness l `shouldReturn` True
      checkIntakeReady l 100 `shouldThrow` isError "custody_not_reconciled"
      clean<-reconcileCustodyWith (pure 100) transport c l
      fieldValue "lastError" clean `shouldReturn` (Nothing::Maybe Text)
      checkIntakeReady l 100
      pause l "operator_pause"
      _<-reconcileCustodyWith (pure 100) transport c l
      readiness l `shouldReturn` Availability False "operator_pause"
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
    it "stores the draft before locking/signing and reuses a recorded attempt (RPC contract test)" $ withFunded $ \l c -> do
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
                fieldValue "lockUnspents" options `shouldReturn` False
                fieldValue "minconf" options `shouldReturn` planDepth plan
                pure $ object ["psbt" .= ("rpc-contract-psbt"::Text),"fee" .= nativeNumber fee,"changepos" .= (0::Int)]
              ("decodepsbt",_) -> pure $ object ["tx" .= (decoded::Value),"fee" .= nativeNumber fee]
              ("gettxout",_) -> pure $ object ["value" .= nativeNumber (prevoutAmount previousOutput),"confirmations" .= (1000::Int),"coinbase" .= False,"scriptPubKey" .= object ["hex" .= prevoutScript previousOutput,"address" .= ("rpc-contract-source"::Text)]]
              ("lockunspent",[Bool False,points]) -> do
                saved<-pendingPreparations l
                length saved `shouldBe` 1
                map preparationDraft saved `shouldSatisfy` all (/=Nothing)
                points `shouldBe` toJSON (map nativeOutpoint $ nativeInputs tx)
                writeIORef locks (map nativeOutpoint $ nativeInputs tx)
                pure (Bool True)
              ("walletprocesspsbt",_) -> do
                saved<-pendingPreparations l
                length saved `shouldBe` 1
                map preparationDraft saved `shouldSatisfy` all (/=Nothing)
                readIORef locks `shouldReturn` map nativeOutpoint (nativeInputs tx)
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
      -- Losing funding cannot orphan an advisory lock. The unresolved ledger
      -- intent still prevents another payment/refund without explicit recovery.
      beginPreparation l c ob "Native" 1000 (TE.decodeUtf8 $ LBS.toStrict $ encode plan)
      let lost _ method params=case (method,params) of
            ("listlockunspent",[]) -> pure (toJSON ([]::[Outpoint]))
            ("walletcreatefundedpsbt",[_,_,_,options,_]) -> do
              fieldValue "lockUnspents" options `shouldReturn` False
              reject "simulated_lost_funding_reply"
            _ -> expectationFailure "unexpected signing or wallet mutation" >> pure Null
      prepareNativeWith lost c l ob `shouldThrow` isError "simulated_lost_funding_reply"
      map preparationDraft <$> pendingPreparations l `shouldReturn` [Nothing]
      available <$> readiness l `shouldReturn` False
      pendingAttempts l `shouldReturn` []
      prepareNativeWith call c l ob `shouldThrow` isError "payouts_paused"
  describe "native lock recovery (offline RPC and SQLite restart contracts)" $ do
    it "reconstructs exact unsigned inputs after reopening, once, without changing funds or signing" $ withDir $ \dir->do
      restartFixture<-newIORef Nothing
      withNativeLockRecoveryAt True dir $ \l c p locks calls transport->do
        before<-auditExport l
        held<-readIORef locks
        writeIORef locks [] -- model daemon loss of advisory locks
        writeIORef restartFixture (Just (c,p,locks,calls,transport,before,held))
      Just (c,p,locks,calls,transport,before,held)<-readIORef restartFixture
      withLedger (dbPath c) (fingerprint c) $ \l->do
        first<-reconcileNativeLocksWith transport c l
        fieldValue "state" first `shouldReturn` ("locked"::Text)
        fieldValue "restoredInputs" first `shouldReturn` (1::Int)
        fieldValue "signedOrSent" first `shouldReturn` False
        readIORef locks `shouldReturn` held
        pendingPreparations l `shouldReturn` [p]
        pendingAttempts l `shouldReturn` []
        auditExport l `shouldReturn` before
        second<-reconcileNativeLocksWith transport c l
        fieldValue "restoredInputs" second `shouldReturn` (0::Int)
        length . filter (=="lockunspent") <$> readIORef calls `shouldReturn` 1
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM audit WHERE action='native_locks_restored'" :: IO [Only Int]) `shouldReturn` [Only 1]
        available <$> readiness l `shouldReturn` False
    forM_ [False,True] $ \broadcast->
      it ("preserves unseen native signed bytes and restores their inputs: broadcast="<>show broadcast) $ withNativeLockRecovery $ \l c p locks _ transport->do
        attempt<-saveNativeFixtureAttempt l p
        when broadcast $ markNativeFixtureBroadcast l attempt
        before<-pendingAttempts l
        financial<-auditExport l
        writeIORef locks []
        result<-reconcileNativeLocksWith transport c l
        fieldValue "state" result `shouldReturn` ("locked"::Text)
        fieldValue "restoredInputs" result `shouldReturn` (1::Int)
        pendingAttempts l `shouldReturn` before
        auditExport l `shouldReturn` financial
        ledgerAction l (\db->query_ db "SELECT released FROM fee_reservations" :: IO [Only Bool]) `shouldReturn` [Only False]
    it "does not relock a generation whose recorded cancellation has a lost cleanup reply" $ withNativeLockRecovery $ \l c p locks calls transport->do
      let lost wallet method params=do
            answer<-paymentNative transport wallet method params
            if method=="lockunspent" then reject "offline_lost_unlock_response" else pure answer
      cancelPreparationWith (pure 100) transport{paymentNative=lost} c l (obligationId $ preparationObligation p) 0 "cancel interrupted native"
        `shouldThrow` isError "offline_lost_unlock_response"
      readIORef locks `shouldReturn` []
      writeIORef calls []
      result<-reconcileNativeLocksWith transport c l
      fieldValue "state" result `shouldReturn` ("cancellation_pending"::Text)
      readIORef calls >>= (`shouldSatisfy` all (`notElem` ["lockunspent","gettxout"]))
      readIORef locks `shouldReturn` []
      pendingPreparations l `shouldReturn` [p]
      ledgerAction l (\db->query_ db "SELECT completed FROM preparation_cancellations" :: IO [Only Bool]) `shouldReturn` [Only False]
    it "protects native inputs during source review without resolving or releasing the obligation" $ withNativeLockRecovery $ \l c p locks _ transport->do
      let ob=preparationObligation p
      refreshDeposit l (Deposit (obligationDeposit ob) (Just $ obligationOrder ob) Native (amt 100000) "unconfirmed" 0 False 100)
      financial<-auditExport l
      writeIORef locks []
      result<-reconcileNativeLocksWith transport c l
      fieldValue "state" result `shouldReturn` ("locked"::Text)
      auditExport l `shouldReturn` financial
      available <$> readiness l `shouldReturn` False
      ledgerAction l (\db->query_ db "SELECT eligible FROM deposits" :: IO [Only Bool]) `shouldReturn` [Only False]
    forM_ ["mempool","confirmed","evicted"] $ \stage->
      it ("reconciles a recorded native spend without creating another transaction: "<>stage) $ withNativeLockRecovery $ \l c p locks calls transport->do
        signed<-nativeSignedFixture
        captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
        decoded<-fieldValue "decoded" captured :: IO Value
        attempt<-saveNativeFixtureAttempt l p
        markNativeFixtureBroadcast l attempt
        before<-pendingAttempts l
        writeIORef locks []
        let call wallet method params=case method of
              "gettransaction"->pure $ object ["txid" .= attemptId attempt,"hex" .= signedNativeBytes signed,"decoded" .= decoded
                ,"fee" .= scientific (negate $ toInteger $ units $ signedNativeFee signed) (-8),"walletconflicts" .= ([]::[Text])
                ,"confirmations" .= (if stage=="confirmed" then 2::Int else 0),"blockhash" .= custodyNativeTip]
              "getmempoolentry" | stage=="mempool"->pure $ object ["vsize" .= (141::Int)]
              "getblockheader"->pure $ object ["hash" .= custodyNativeTip,"height" .= (100::Int),"confirmations" .= (2::Int)]
              "getblockhash"->pure $ toJSON custodyNativeTip
              _->paymentNative transport wallet method params
        result<-reconcileNativeLocksWith transport{paymentNative=call} c l
        fieldValue "state" result `shouldReturn` (if stage=="evicted" then "locked" else "spent_by_recorded_payment"::Text)
        fieldValue "restoredInputs" result `shouldReturn` (if stage=="evicted" then 1::Int else 0)
        pendingAttempts l `shouldReturn` before
        when (stage/="evicted") $ readIORef calls >>= (`shouldSatisfy` all (`notElem` ["gettxout","lockunspent"]))
        available <$> readiness l `shouldReturn` False
    it "refuses an observed signed-only transaction before treating its inputs as spent" $ withNativeLockRecovery $ \l c p locks calls transport->do
      signed<-nativeSignedFixture
      captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
      decoded<-fieldValue "decoded" captured :: IO Value
      attempt<-saveNativeFixtureAttempt l p
      writeIORef locks []
      let call wallet method params=if method=="gettransaction" then pure $ object
            ["txid" .= attemptId attempt,"hex" .= signedNativeBytes signed,"decoded" .= decoded
            ,"fee" .= scientific (negate $ toInteger $ units $ signedNativeFee signed) (-8)
            ,"walletconflicts" .= ([]::[Text]),"confirmations" .= (0::Int)]
            else paymentNative transport wallet method params
      result<-reconcileNativeLocksWith transport{paymentNative=call} c l
      fieldValue "error" result `shouldReturn` ("unrecorded_broadcast_observed"::Text)
      readIORef locks `shouldReturn` []
      readIORef calls >>= (`shouldSatisfy` all (`notElem` ["gettxout","lockunspent"]))
      pendingAttempts l `shouldReturn` [attempt]
    it "never unlocks or replaces unknown wallet locks" $ withNativeLockRecovery $ \l c p locks calls transport->do
      let unknown=Outpoint (T.replicate 64 "f") 3
      modifyIORef' locks (<>[unknown])
      before<-readIORef locks
      result<-reconcileNativeLocksWith transport c l
      fieldValue "error" result `shouldReturn` ("native_preparation_locks_require_review"::Text)
      readIORef locks `shouldReturn` before
      readIORef calls >>= (`shouldSatisfy` notElem "lockunspent")
      pendingPreparations l `shouldReturn` [p]
      available <$> readiness l `shouldReturn` False
    it "refuses unavailable, changed or insufficiently confirmed inputs before any lock mutation" $
      forM_ (["missing","changed","unconfirmed","not-owned"]::[Text]) $ \kind->withNativeLockRecovery $ \l c p locks calls transport->do
        writeIORef locks []
        let call wallet method params=do
              value<-paymentNative transport wallet method params
              pure $ case (method,kind) of
                ("gettxout","missing")->Null
                ("gettxout","changed")->setPath ["value"] (nativeNumber $ amt 1) value
                ("gettxout","unconfirmed")->setPath ["confirmations"] (Number 0) value
                ("getaddressinfo","not-owned")->setPath ["ismine"] (Bool False) value
                _->value
        result<-reconcileNativeLocksWith transport{paymentNative=call} c l
        fieldValue "state" result `shouldReturn` ("requires_review"::Text)
        readIORef calls >>= (`shouldSatisfy` notElem "lockunspent")
        readIORef locks `shouldReturn` []
        pendingPreparations l `shouldReturn` [p]
    it "reconciles a lost lock response without repeating it or releasing any funds" $ withNativeLockRecovery $ \l c _ locks calls transport->do
      financial<-auditExport l
      writeIORef locks []
      let lost wallet method params=do
            answer<-paymentNative transport wallet method params
            if method=="lockunspent" then reject "rpc_transport_unknown_outcome" else pure answer
      result<-reconcileNativeLocksWith transport{paymentNative=lost} c l
      fieldValue "error" result `shouldReturn` ("rpc_transport_unknown_outcome"::Text)
      readIORef locks >>= (`shouldSatisfy` not . null)
      retry<-reconcileNativeLocksWith transport c l
      fieldValue "state" retry `shouldReturn` ("locked"::Text)
      fieldValue "restoredInputs" retry `shouldReturn` (0::Int)
      length . filter (=="lockunspent") <$> readIORef calls `shouldReturn` 1
      auditExport l `shouldReturn` financial
      available <$> readiness l `shouldReturn` False
    it "does not sign when a success reply is contradicted by the wallet's actual locks" $ withNativeLockRecovery $ \l _ p locks calls transport->do
      writeIORef locks []
      plan<-either fail pure $ eitherDecodeStrict' $ TE.encodeUtf8 $ preparationPolicy p
      draft<-maybe (fail "missing draft") (either fail pure . eitherDecodeStrict' . TE.encodeUtf8) (preparationDraft p)
      let falseSuccess wallet method params=if method=="lockunspent" then pure (Bool True) else paymentNative transport wallet method params
      signNativeDraft falseSuccess plan draft `shouldThrow` isError "native_input_lock_unverified"
      readIORef calls >>= (`shouldSatisfy` notElem "walletprocesspsbt")
      pendingAttempts l `shouldReturn` []
    it "leaves a draftless preparation intact and refuses any unexplained locks" $ withDir $ \dir->
      withNativeLockRecoveryAt False dir $ \l c p locks calls transport->do
        first<-reconcileNativeLocksWith transport c l
        fieldValue "state" first `shouldReturn` ("awaiting_draft"::Text)
        writeIORef locks [Outpoint (T.replicate 64 "f") 3]
        second<-reconcileNativeLocksWith transport c l
        fieldValue "error" second `shouldReturn` ("native_preparation_locks_require_review"::Text)
        readIORef calls >>= (`shouldSatisfy` all (`notElem` ["lockunspent","gettxout"]))
        pendingPreparations l `shouldReturn` [p]
    it "refuses the wrong wallet before touching its locks" $ withNativeLockRecovery $ \l c _ _ calls transport->do
      let wrong wallet method params=do
            value<-paymentNative transport wallet method params
            pure $ if method=="getwalletinfo" then setPath ["walletname"] (String "different-wallet") value else value
      result<-reconcileNativeLocksWith transport{paymentNative=wrong} c l
      fieldValue "error" result `shouldReturn` ("native_wallet_not_ready"::Text)
      readIORef calls `shouldReturn` ["getwalletinfo"]
  describe "native source recovery (captured receipt, offline RPC and accounting contracts)" $ do
    it "keeps a newly observed mempool receipt pending without opening a recovery incident" $ withDir $ \dir->
      withNativeSourceAt False dir $ \l c _ _ transport->do
        before<-auditExport l
        result<-reconcileNativeSourcesWith transport c l
        sourceStates result `shouldReturn` ["pending"]
        auditExport l `shouldReturn` before
        available <$> readiness l `shouldReturn` True
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_recoveries" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "journals lost eligibility atomically and retains unsigned obligations, principal and holds" $ withNativeSource $ \l c source wallet transport->do
      ob<-sourceObligation l source
      before<-auditExport l
      _<-changeSource l c source wallet 0
      status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
      result<-reconcileNativeSourcesWith transport c l
      sourceStates result `shouldReturn` ["pending"]
      sourceBalance l "principal" `shouldReturn` toInteger (units $ depositAmount source)
      sourceBalance l "source_deficit" `shouldReturn` 0
      afterLoss<-auditExport l
      oldBalances<-fieldValue "balances" before :: IO Value
      oldEvents<-fieldValue "events" before :: IO Value
      fieldValue "balances" afterLoss `shouldReturn` oldBalances
      fieldValue "events" afterLoss `shouldReturn` oldEvents
      ledgerAction l (\db->query_ db "SELECT status FROM obligations" :: IO [Only Text]) `shouldReturn` [Only "review"]
      ledgerAction l (\db->query_ db "SELECT phase FROM reservations" :: IO [Only Text]) `shouldReturn` [Only "obligation"]
      resumeAfterChecks l `shouldThrow` isError "source_reorg_requires_review"
      _<-changeSource l c source wallet 2
      _<-reconcileNativeSourcesWith transport c l
      status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
      resumeAfterChecks l `shouldThrow` isError "obligations_require_review"
      sourceBalance l "source_deficit" `shouldReturn` 0
    forM_ [False,True] $ \broadcast->
      it ("records a proved source deficit without releasing a signed attempt: broadcast="<>show broadcast) $ withNativeSource $ \l c source wallet transport->do
        ob<-sourceObligation l source
        sourceAttempt l c ob
        when broadcast $ markBroadcastIntent l "offline-source-payout" >> pure ()
        attempts<-pendingAttempts l
        holds<-ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)])
        _<-changeSource l c source wallet (-1)
        result<-reconcileNativeSourcesWith transport c l
        sourceStates result `shouldReturn` ["missing"]
        sourceBalance l "source_deficit" `shouldReturn` negate (toInteger $ units $ depositAmount source)
        sourceBalance l "principal" `shouldReturn` toInteger (units $ depositAmount source)
        pendingAttempts l `shouldReturn` attempts
        ledgerAction l (\db->query_ db "SELECT amount,released FROM fee_reservations" :: IO [(Int64,Bool)]) `shouldReturn` holds
        ledgerAction l (\db->query_ db "SELECT phase FROM reservations" :: IO [Only Text]) `shouldReturn` [Only "payment"]
        createRefund l (depositId source) `shouldThrow` isError "refundable_deposit_not_found"
        when broadcast $ authorizeRecordedSend l False "offline-source-payout" `shouldThrow` isError "source_not_eligible"
        proof<-auditExportWithBudget l c >>= fieldValue "sourceRecovery" :: IO [Value]
        mapM (fieldValue "paymentExposure") proof `shouldReturn` [if broadcast then "possibly_sent" else "signed"::Text]
        before<-auditExport l
        _<-reconcileNativeSourcesWith transport c l
        auditExport l `shouldReturn` before
    it "preserves a paid payout through loss, reopening, mempool return and source reconfirmation" $ withDir $ \dir->do
      saved<-withNativeSourceAt True dir $ \l c source wallet transport->do
        ob<-sourceObligation l source
        sourceAttempt l c ob
        _<-markBroadcastIntent l "offline-source-payout"
        recordSettlement l "offline-source-payout" (PaymentCosts (amt 5000) (amt 0)) "offline-verified-outcome"
        _<-changeSource l c source wallet (-2)
        _<-reconcileNativeSourcesWith transport c l
        status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
        sourceBalance l "principal" `shouldReturn` 0
        sourceBalance l "source_deficit" `shouldReturn` (-10000)
        rows<-auditExportWithBudget l c >>= fieldValue "sourceRecovery" :: IO [Value]
        mapM (fieldValue "paymentExposure") rows `shouldReturn` ["paid"::Text]
        before<-auditExport l
        pure(c,source,wallet,transport,ob,before)
      let (c,source,wallet,transport,ob,before)=saved
      withLedger (dbPath c) (fingerprint c) $ \l->do
        _<-reconcileNativeSourcesWith transport c l
        auditExport l `shouldReturn` before
        _<-changeSource l c source wallet 0
        unconfirmed<-reconcileNativeSourcesWith transport c l
        sourceStates unconfirmed `shouldReturn` ["pending"]
        sourceBalance l "source_deficit" `shouldReturn` 0
        status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
        _<-changeSource l c source wallet 2
        restored<-reconcileNativeSourcesWith transport c l
        sourceStates restored `shouldReturn` ["restored"]
        status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "Paid"
        payoutTx <$> readOrder l cap (obligationOrder ob) `shouldReturn` Just "offline-source-payout"
        available <$> readiness l `shouldReturn` False
        ledgerAction l (\db->query_ db "SELECT state,signed_bytes FROM attempts" :: IO [(Text,Text)]) `shouldReturn` [("settled","offline-source-signed-bytes")]
        ledgerAction l (\db->query_ db "SELECT delta FROM postings WHERE account='source_deficit' ORDER BY id" :: IO [Only Int64]) `shouldReturn` [Only (-10000),Only 10000]
        ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings GROUP BY asset" :: IO [Only Int64]) `shouldReturn` replicate 3 (Only 0)
        repeated<-reconcileNativeSourcesWith transport{paymentIdentity=expectationFailure "completed source recovery repeated IO"} c l
        sourceStates repeated `shouldReturn` []
    it "still books a possibly broadcast payout after the source conflict without paying or refunding again" $ withNativeSource $ \l c source wallet transport->do
      ob<-sourceObligation l source
      sourceAttempt l c ob
      _<-markBroadcastIntent l "offline-source-payout"
      _<-changeSource l c source wallet (-1)
      _<-reconcileNativeSourcesWith transport c l
      recordSettlement l "offline-source-payout" (PaymentCosts (amt 5000) (amt 0)) "offline-verified-outcome"
      sourceBalance l "source_deficit" `shouldReturn` (-10000)
      sourceBalance l "principal" `shouldReturn` 0
      status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
      pendingAttempts l `shouldReturn` []
      createRefund l (depositId source) `shouldThrow` isError "refundable_deposit_not_found"
      before<-auditExport l
      recordSettlement l "offline-source-payout" (PaymentCosts (amt 5000) (amt 0)) "offline-verified-outcome"
      auditExport l `shouldReturn` before
    it "keeps an already recorded deficit when later RPC evidence is unavailable" $ withNativeSource $ \l c source wallet transport->do
      _<-sourceObligation l source
      _<-changeSource l c source wallet (-1)
      _<-reconcileNativeSourcesWith transport c l
      before<-auditExport l
      writeIORef wallet Nothing
      result<-reconcileNativeSourcesWith transport c l
      sourceStates result `shouldReturn` ["requires_review"]
      sourceBalance l "source_deficit" `shouldReturn` (-10000)
      auditExport l `shouldReturn` before
    forM_ ["mempool-conflict","unspent-conflict","absent-mempool","missing-wallet","wrong-output","stale-scan","identity-refusal"] $ \fault->
      it ("does not book a deficit on ambiguous or contradictory evidence: "<>fault) $ withNativeSource $ \l c source wallet transport->do
        _<-sourceObligation l source
        _<-changeSource l c source wallet (if fault `elem` ["mempool-conflict","unspent-conflict"] then -1 else 0)
        let base=paymentNative transport
            call selected method params=case (fault,method) of
              ("mempool-conflict","getmempoolentry")->pure (object ["vsize" .= (141::Int)])
              ("unspent-conflict","gettxout")->pure (object ["confirmations" .= (1::Int)])
              ("absent-mempool","getmempoolentry")->reject "rpc_error_-5"
              _->base selected method params
        when (fault=="missing-wallet") $ writeIORef wallet Nothing
        when (fault=="wrong-output") $ modifyIORef' wallet (fmap $ setPath ["details"] (toJSON ([]::[Value])))
        when (fault=="stale-scan") $ modifyIORef' wallet (fmap $ setPath ["confirmations"] (Number (-1)))
        let checked=transport{paymentNative=call,paymentIdentity=if fault=="identity-refusal" then reject "native_checkpoint_mismatch" else pure ()}
        before<-auditExport l
        result<-reconcileNativeSourcesWith checked c l
        sourceStates result `shouldReturn` ["requires_review"]
        sourceBalance l "source_deficit" `shouldReturn` 0
        auditExport l `shouldReturn` before
    it "refuses stale receipt and observation snapshots" $ withNativeSource $ \l c source wallet _->do
      lost<-changeSource l c source wallet 0
      recordSourceCheck l source (SourceUnavailable $ object ["reason" .= ("stale callback"::Text)]) `shouldThrow` isError "source_recovery_changed"
      recordSourceCheck l lost (SourcePending $ object ["observationHash" .= ("stale"::Text)]) `shouldThrow` isError "source_recovery_scan_not_current"
      sourceBalance l "source_deficit" `shouldReturn` 0
    it "rolls back the recovery decision if its financial posting cannot commit" $ withDir $ \dir->do
      saved<-withNativeSourceAt True dir $ \l c source wallet transport->do
        _<-sourceObligation l source
        _<-changeSource l c source wallet (-1)
        before<-auditExport l
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER refuse_source_deficit BEFORE INSERT ON postings WHEN NEW.account='source_deficit' BEGIN SELECT RAISE(ABORT,'offline_write_failure'); END"
        reconcileNativeSourcesWith transport c l `shouldThrow` (\err->sqlError err==ErrorConstraint)
        readiness l `shouldThrow` isError "ledger_requires_reopen"
        pure(c,before)
      let (c,before)=saved
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` before
        sourceBalance l "source_deficit" `shouldReturn` 0
        ledgerAction l (\db->query_ db "SELECT state FROM source_recovery_state" :: IO [Only Text]) `shouldReturn` [Only "unavailable"]
        ledgerAction l (\db->execute_ db "DELETE FROM source_recoveries") `shouldThrow` (\err->sqlError err==ErrorConstraint)
  describe "operator approval of a restored source (offline contracts)" $ do
    forM_ ["ready","unsigned","signed","broadcast"] $ \stage->
      it ("restores only the suspended work, with money and bytes retained: "<>T.unpack stage) $ withNativeSource $ \l c source wallet transport->do
        ob<-sourceObligation l source
        when (stage=="unsigned") $ beginPreparation l c ob "Solana" 5000 "offline-policy"
        when (stage `elem` ["signed","broadcast"]) $ sourceAttempt l c ob
        when (stage=="broadcast") $ markBroadcastIntent l "offline-source-payout" >> pure ()
        _<-changeSource l c source wallet 0
        _<-changeSource l c source wallet 2
        _<-reconcileNativeSourcesWith transport c l
        restored<-sourceRestoration l source
        original<-auditExport l
        attempts<-pendingAttempts l
        preparations<-pendingPreparations l
        holds<-ledgerAction l (\db->query_ db "SELECT asset,amount,phase FROM reservations" :: IO [(Text,Int64,Text)])
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "verified restored source" `shouldThrow` isError "custody_not_reconciled"
        assumeSourceApprovalCustody l
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "verified restored source"
        ledgerAction l (\db->query_ db "SELECT status FROM obligations" :: IO [Only Text]) `shouldReturn` [Only $ if stage=="ready" then "ready" else "paying"]
        updated<-auditExport l
        forM_ ["balances","events"] $ \key->do
          old<-fieldValue key original :: IO Value
          fieldValue key updated `shouldReturn` old
        pendingAttempts l `shouldReturn` attempts
        pendingPreparations l `shouldReturn` preparations
        ledgerAction l (\db->query_ db "SELECT asset,amount,phase FROM reservations" :: IO [(Text,Int64,Text)]) `shouldReturn` holds
        available <$> readiness l `shouldReturn` False
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "verified restored source"
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "changed reason" `shouldThrow` isError "source_approval_conflict"
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_recovery_approvals" :: IO [Only Int]) `shouldReturn` [Only 1]
        when (stage=="broadcast") $ do
          [Only approved]<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM source_recovery_approvals")
          required<-markBroadcastIntent l "offline-source-payout"
          required `shouldBe` approved
          acknowledgeBackup l restored "offline-before-approval"
          authorizeRecordedSend l True "offline-source-payout" `shouldThrow` isError "backup_pending"
          acknowledgeBackup l required "offline-including-approval"
          authorizeRecordedSend l True "offline-source-payout" `shouldThrow` isError "payouts_paused"
    it "refuses an old restoration after another loss and approves unchanged work against the latest restoration only" $ withNativeSource $ \l c source wallet transport->do
      ob<-sourceObligation l source
      _<-changeSource l c source wallet 0
      _<-changeSource l c source wallet 2
      _<-reconcileNativeSourcesWith transport c l
      old<-sourceRestoration l source
      _<-changeSource l c source wallet (-1)
      _<-reconcileNativeSourcesWith transport c l
      recordSourceRecoveryApproval l (obligationId ob) old 100 "review" `shouldThrow` isError "source_approval_not_expected"
      _<-changeSource l c source wallet 2
      _<-reconcileNativeSourcesWith transport c l
      current<-sourceRestoration l source
      current `shouldSatisfy` (>old)
      assumeSourceApprovalCustody l
      recordSourceRecoveryApproval l (obligationId ob) old 100 "review" `shouldThrow` isError "source_approval_not_expected"
      recordSourceRecoveryApproval l (obligationId ob) current 100 "review"
      readyObligations l `shouldReturn` [ob]
      sourceBalance l "source_deficit" `shouldReturn` 0
    forM_ ["draft-callback","expiry","settlement"] $ \change->
      it ("does not revive work changed during source review: "<>T.unpack change) $ withNativeSource $ \l c source wallet transport->do
        ob<-sourceObligation l source
        if change=="draft-callback" then beginPreparation l c ob "Solana" 5000 "offline-policy" else sourceAttempt l c ob
        when (change=="settlement") $ markBroadcastIntent l "offline-source-payout" >> pure ()
        _<-changeSource l c source wallet 0
        case change of
          "draft-callback"->storeDraft l (obligationId ob) "offline-late-draft" 0
          "expiry"->do
            [a]<-pendingAttempts l
            recordSolanaExpiry l a "offline-conclusive-expiry"
          _->recordSettlement l "offline-source-payout" (PaymentCosts (amt 5000) (amt 0)) "offline-finalized-payment"
        _<-changeSource l c source wallet 2
        _<-reconcileNativeSourcesWith transport c l
        restored<-sourceRestoration l source
        assumeSourceApprovalCustody l
        before<-auditExport l
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "review"
          `shouldThrow` isError (if change=="settlement" then "source_approval_not_expected" else "source_review_work_changed")
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_recovery_approvals" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "does not reinterpret an existing failure review as a suspended source obligation" $ withNativeSource $ \l c source wallet transport->do
      ob<-sourceObligation l source
      sourceAttempt l c ob
      _<-markBroadcastIntent l "offline-source-payout"
      recordFailedSolana l "offline-source-payout" 5000 "offline-finalized-failure"
      _<-changeSource l c source wallet 0
      _<-changeSource l c source wallet 2
      _<-reconcileNativeSourcesWith transport c l
      restored<-sourceRestoration l source
      assumeSourceApprovalCustody l
      recordSourceRecoveryApproval l (obligationId ob) restored 100 "review" `shouldThrow` isError "source_review_context_missing"
    it "survives reopening and cannot reuse an old approval to clear a new source review" $ withDir $ \dir->do
      saved<-withNativeSourceAt True dir $ \l c source wallet transport->do
        ob<-sourceObligation l source
        _<-changeSource l c source wallet 0
        _<-changeSource l c source wallet 2
        _<-reconcileNativeSourcesWith transport c l
        restored<-sourceRestoration l source
        assumeSourceApprovalCustody l
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "review"
        pure(c,source,wallet,transport,ob,restored)
      let (c,source,wallet,transport,ob,restored)=saved
      withLedger (dbPath c) (fingerprint c) $ \l->do
        _<-approveSourceRecoveryWith (pure 100) transport{paymentIdentity=expectationFailure "duplicate approval contacted chain"} c l (obligationId ob) restored "review"
        _<-changeSource l c source wallet 0
        _<-changeSource l c source wallet 2
        _<-reconcileNativeSourcesWith transport c l
        current<-sourceRestoration l source
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "review"
        status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
        assumeSourceApprovalCustody l
        recordSourceRecoveryApproval l (obligationId ob) current 100 "second episode"
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_recovery_approvals" :: IO [Only Int]) `shouldReturn` [Only 2]
        ledgerAction l (\db->execute_ db "DELETE FROM source_recovery_approvals") `shouldThrow` (\err->sqlError err==ErrorConstraint)
    it "rolls back approval, sequence and status together when the state write fails" $ withDir $ \dir->do
      saved<-withNativeSourceAt True dir $ \l c source wallet transport->do
        ob<-sourceObligation l source
        _<-changeSource l c source wallet 0
        _<-changeSource l c source wallet 2
        _<-reconcileNativeSourcesWith transport c l
        restored<-sourceRestoration l source
        assumeSourceApprovalCustody l
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER refuse_source_approval BEFORE UPDATE OF status ON obligations BEGIN SELECT RAISE(ABORT,'offline_approval_failure'); END"
        before<-auditExport l
        [Only sequenceNo]<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment")
        recordSourceRecoveryApproval l (obligationId ob) restored 100 "review" `shouldThrow` (\err->sqlError err==ErrorConstraint)
        readiness l `shouldThrow` isError "ledger_requires_reopen"
        pure(c,ob,restored,before,sequenceNo::Int64)
      let (c,ob,restored,before,sequenceNo)=saved
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` before
        sourceRecoveryApproval l (obligationId ob) restored `shouldReturn` Nothing
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment") `shouldReturn` [Only sequenceNo]
    it "refuses a pending unsigned cancellation even when it predates the source loss" $ withNativeSource $ \l c source wallet transport->do
      ob<-sourceObligation l source
      beginPreparation l c ob "Solana" 5000 "offline-policy"
      [preparation]<-pendingPreparations l
      pause l "operator cancellation"
      assumeSourceApprovalCustody l
      beginPreparationCancellation l preparation 100 "cancel this draft" (object ["offlineFixture" .= True])
      _<-changeSource l c source wallet 0
      _<-changeSource l c source wallet 2
      _<-reconcileNativeSourcesWith transport c l
      restored<-sourceRestoration l source
      assumeSourceApprovalCustody l
      recordSourceRecoveryApproval l (obligationId ob) restored 100 "review" `shouldThrow` isError "preparation_cancellation_pending"
    it "does not approve source recovery when the saved outgoing payment needs separate review" $ withNativeSource $ \l c source wallet transport->do
      ob<-sourceObligation l source
      -- The intentionally invalid offline policy makes payment validation fail.
      -- Source approval must not bypass that independent recovery error.
      sourceAttempt l c ob
      _<-changeSource l c source wallet 0
      _<-changeSource l c source wallet 2
      _<-reconcileNativeSourcesWith transport c l
      restored<-sourceRestoration l source
      assumeSourceApprovalCustody l
      approveSourceRecoveryWith (pure 100) transport c l (obligationId ob) restored "review"
        `shouldThrow` isError "source_approval_payment_requires_review"
      sourceRecoveryApproval l (obligationId ob) restored `shouldReturn` Nothing
      status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
    forM_ ["healthy","shortfall","identity"] $ \scenario->
      it ("runs real source/custody validation before operator approval: "<>T.unpack scenario) $ withNativeSource $ \l original source wallet sourceTransport->do
        let c=expiryConfig original
        ob<-sourceObligation l source
        _<-changeSource l c source wallet 0
        _<-changeSource l c source wallet 2
        _<-reconcileNativeSourcesWith sourceTransport c l
        restored<-sourceRestoration l source
        setupCustodyScans l c
        let custody=custodyContract c (if scenario=="shortfall" then 1109999 else 1110000,1000000,100000) []
            native selected method params
              | method `elem` ["getbalances","listsinceblock"] || (method=="getblockhash" && params==[Number 20000])=paymentNative custody selected method params
              | otherwise=paymentNative sourceTransport selected method params
            transport=custody{paymentNative=native,paymentIdentity=if scenario=="identity" then reject "wrong_chain" else pure ()}
            action=approveSourceRecoveryWith (pure 100) transport c l (obligationId ob) restored "checked source and custody"
        if scenario=="healthy" then do
          result<-action
          fieldValue "signedOrSent" result `shouldReturn` False
          readyObligations l `shouldReturn` [ob]
          sourceRecoveryApproval l (obligationId ob) restored `shouldReturn` Just "checked source and custody"
        else action `shouldThrow` isError (if scenario=="identity" then "wrong_chain" else "custody_not_reconciled")
        available <$> readiness l `shouldReturn` False
  describe "operator funding of proved source losses (offline contracts)" $ do
    forM_ ["ready","unsigned","signed","broadcast","paid"] $ \stage->
      it ("covers a deficit with free capital without altering customer work: "<>T.unpack stage) $ withNativeSource $ \l c source wallet transport->do
        fundAllocation l "offline-earned-capital" Native "earned" (amt 10000)
        fundAllocation l "offline-protected-backing" Native "backing" (amt 500000)
        fundAllocation l "offline-protected-lp" Native "lp" (amt 500000)
        ob<-sourceObligation l source
        when (stage=="unsigned") $ beginPreparation l c ob "Solana" 5000 "offline-policy"
        when (stage `elem` ["signed","broadcast","paid"]) $ sourceAttempt l c ob
        when (stage `elem` ["broadcast","paid"]) $ markBroadcastIntent l "offline-source-payout" >> pure ()
        when (stage=="paid") $ recordSettlement l "offline-source-payout" (PaymentCosts (amt 5000) (amt 0)) "offline-finalized-payment"
        lost<-changeSource l c source wallet (-1)
        (loss,proof)<-sourceLossEvidence l c lost transport
        custody<-lossCustodyFixture l proof
        balancesBefore<-mapM (sourceBalance l) ["float","earned","principal","backing","lp","operating"]
        attempts<-pendingAttempts l
        preparations<-pendingPreparations l
        holds<-ledgerAction l (\db->query_ db "SELECT asset,amount,phase FROM reservations" :: IO [(Text,Int64,Text)])
        let capital=LossCapital (amt 6000) (amt 4000)
        recordSourceLossCover l lost loss 100 capital "operator loss allocation" proof custody
        balancesAfter<-mapM (sourceBalance l) ["float","earned","principal","backing","lp","operating"]
        balancesAfter `shouldBe` zipWith (-) balancesBefore [6000,4000,0,0,0,0]
        sourceBalance l "source_deficit" `shouldReturn` 0
        pendingAttempts l `shouldReturn` attempts
        pendingPreparations l `shouldReturn` preparations
        ledgerAction l (\db->query_ db "SELECT asset,amount,phase FROM reservations" :: IO [(Text,Int64,Text)]) `shouldReturn` holds
        ledgerAction l (\db->query_ db "SELECT eligible FROM deposits" :: IO [Only Bool]) `shouldReturn` [Only False]
        status <$> readOrder l cap (obligationOrder ob) `shouldReturn` (if stage=="paid" then "Paid" else "NeedsReview")
        available <$> readiness l `shouldReturn` False
        before<-auditExport l
        recordSourceLossCover l lost loss 100 capital "operator loss allocation" proof custody
        auditExport l `shouldReturn` before
        recordSourceLossCover l lost loss 100 capital "changed reason" proof custody `shouldThrow` isError "source_loss_cover_conflict"
        recordSourceLossCover l lost loss 100 (LossCapital (amt 10000) (amt 0)) "operator loss allocation" proof custody `shouldThrow` isError "source_loss_cover_conflict"
        ledgerAction l (\db->query_ db "SELECT SUM(delta) FROM postings GROUP BY asset" :: IO [Only Int64]) `shouldReturn` replicate 3 (Only 0)
        when (stage=="ready") $ resumeAfterChecks l `shouldThrow` isError "obligations_require_review"
        when (stage=="broadcast") $ authorizeRecordedSend l False "offline-source-payout" `shouldThrow` isError "source_not_eligible"
    it "returns the same split once after source reappearance, preserving a new loss as a separate decision" $ withDir $ \dir->do
      saved<-withNativeSourceAt True dir $ \l c source wallet transport->do
        fundAllocation l "offline-earned-capital" Native "earned" (amt 4000)
        _<-sourceObligation l source
        lost<-changeSource l c source wallet (-1)
        (loss,proof)<-sourceLossEvidence l c lost transport
        custody<-lossCustodyFixture l proof
        recordSourceLossCover l lost loss 100 (LossCapital (amt 6000) (amt 4000)) "cover episode one" proof custody
        pure(c,source,wallet,transport,lost,loss,proof,custody)
      let (c,source,wallet,transport,lost,loss,proof,custody)=saved
      withLedger (dbPath c) (fingerprint c) $ \l->do
        _<-changeSource l c source wallet 0
        _<-reconcileNativeSourcesWith transport c l
        sourceBalance l "float" `shouldReturn` 1000000
        sourceBalance l "earned" `shouldReturn` 4000
        sourceBalance l "source_deficit" `shouldReturn` 0
        before<-auditExport l
        recordSourceLossCover l lost loss 100 (LossCapital (amt 6000) (amt 4000)) "cover episode one" proof custody
        _<-reconcileNativeSourcesWith transport c l
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_loss_returns" :: IO [Only Int]) `shouldReturn` [Only 1]
        repeatedLoss<-changeSource l c source wallet (-2)
        (newLoss,newProof)<-sourceLossEvidence l c repeatedLoss transport
        newLoss `shouldSatisfy` (>loss)
        recordSourceLossCover l lost loss 100 (LossCapital (amt 6000) (amt 4000)) "cover episode one" proof custody
        sourceBalance l "source_deficit" `shouldReturn` (-10000)
        fresh<-lossCustodyFixture l newProof
        recordSourceLossCover l repeatedLoss newLoss 100 (LossCapital (amt 10000) (amt 0)) "cover episode two" newProof fresh
        sourceBalance l "float" `shouldReturn` 990000
        _<-changeSource l c source wallet 2
        _<-reconcileNativeSourcesWith transport c l
        sourceBalance l "float" `shouldReturn` 1000000
        sourceBalance l "earned" `shouldReturn` 4000
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_loss_returns" :: IO [Only Int]) `shouldReturn` [Only 2]
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM active_source_loss_covers" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "does not forgive the cover on RPC failure or cover the same outstanding loss twice" $ withNativeSource $ \l c source wallet transport->do
      _<-sourceObligation l source
      lost<-changeSource l c source wallet (-1)
      (loss,proof)<-sourceLossEvidence l c lost transport
      custody<-lossCustodyFixture l proof
      recordSourceLossCover l lost loss 100 (LossCapital (amt 10000) (amt 0)) "cover" proof custody
      value<-readIORef wallet
      writeIORef wallet Nothing
      _<-reconcileNativeSourcesWith transport c l
      sourceBalance l "source_deficit" `shouldReturn` 0
      sourceBalance l "float" `shouldReturn` 990000
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM accounted_source_losses" :: IO [Only Int]) `shouldReturn` [Only 0]
      resumeAfterChecks l `shouldThrow` isError "source_reorg_requires_review"
      writeIORef wallet value
      (updated,newProof)<-sourceLossEvidence l c lost transport
      updated `shouldSatisfy` (>loss)
      fresh<-lossCustodyFixture l newProof
      recordSourceLossCover l lost updated 100 (LossCapital (amt 10000) (amt 0)) "second allocation" newProof fresh `shouldThrow` isError "source_loss_already_covered"
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_loss_covers" :: IO [Only Int]) `shouldReturn` [Only 1]
    forM_ ["float-held","earned-short","wrong-total","stale-revision","stale-time","wrong-block","wrong-output","stale-observation","available"] $ \fault->
      it ("refuses invalid capital or stale evidence without changing allocations: "<>T.unpack fault) $ withNativeSource $ \l c source wallet transport->do
        when (fault=="float-held") $ do
          _<-createOrder l c 100 cap req{direction=WrappedToNative,input=amt 1006000,recipient="fixture-native-recipient",refund="fixture-solana-owner",sourceOwner=Just "fixture-solana-owner",idempotencyKey="other-native-reservation"}
          pure ()
        _<-sourceObligation l source
        lost<-changeSource l c source wallet (-1)
        (loss,proof)<-sourceLossEvidence l c lost transport
        custody<-lossCustodyFixture l proof
        let capital=if fault=="earned-short" then LossCapital (amt 0) (amt 10000) else LossCapital (amt $ if fault=="wrong-total" then 9999 else 10000) (amt 0)
            sourceProof=case fault of
              "wrong-output"->setPath ["output"] (Number 99) proof
              "stale-observation"->setPath ["observationHash"] (String "stale") proof
              _->proof
            custodyProof=case fault of
              "stale-revision"->setPath ["revision"] (Number 0) custody
              "wrong-block"->setPath ["report","nativeBlock"] (String "other") custody
              _->custody
            expected=case fault of
              "float-held"->"insufficient_loss_capital"
              "earned-short"->"insufficient_loss_capital"
              "wrong-total"->"source_loss_allocation_mismatch"
              "wrong-block"->"source_loss_custody_view_changed"
              "wrong-output"->"source_loss_not_proven"
              "stale-observation"->"source_recovery_scan_not_current"
              "available"->"pause_before_operator_action"
              _->"source_loss_custody_not_current"
        when (fault=="available") $ ledgerAction l $ \db->execute_ db "UPDATE deployment SET paused=0"
        before<-auditExport l
        recordSourceLossCover l lost loss (if fault=="stale-time" then 161 else 100) capital "cover" sourceProof custodyProof `shouldThrow` isError expected
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_loss_covers" :: IO [Only Int]) `shouldReturn` [Only 0]
    forM_ ["healthy","shortfall","unavailable"] $ \scenario->
      it ("requires an actual custody inspection including the recorded loss: "<>T.unpack scenario) $ withNativeSource $ \l original source wallet sourceTransport->do
        let c=expiryConfig original
        _<-sourceObligation l source
        lost<-changeSource l c source wallet (-1)
        (loss,_)<-sourceLossEvidence l c lost sourceTransport
        transport<-lossCustodyTransport l c wallet sourceTransport (if scenario=="shortfall" then 1099999 else 1100000)
        normal<-reconcileCustodyWith (pure 100) transport c l
        fieldValue "lastError" normal `shouldReturn` Just ("source_reorg_requires_review"::Text)
        when (scenario=="unavailable") $ writeIORef wallet Nothing
        let action=coverSourceLossWith (pure 100) transport c l (depositId lost) loss (LossCapital (amt 10000) (amt 0)) "checked loss"
        if scenario=="healthy" then do
          inspection<-inspectSourceLossCustodyWith (pure 100) transport c l
          fieldValue "revision" inspection >>= (\(r::Int64)->r `shouldSatisfy` (>0))
          checkCustodyFresh l 100 `shouldThrow` isError "custody_not_reconciled"
          _<-action
          custody<-reconcileCustodyWith (pure 100) transport c l
          fieldValue "lastError" custody `shouldReturn` (Nothing::Maybe Text)
          (fieldValue "report" custody >>= fieldValue "matches") `shouldReturn` True
          resumeAfterChecks l `shouldThrow` isError "obligations_require_review"
        else action `shouldThrow` isError (if scenario=="shortfall" then "custody_balance_mismatch" else "rpc_error_-5")
        available <$> readiness l `shouldReturn` False
    it "rolls back capital and its decision together if a posting fails, and retains immutable history" $ withDir $ \dir->do
      saved<-withNativeSourceAt True dir $ \l c source wallet transport->do
        _<-sourceObligation l source
        lost<-changeSource l c source wallet (-1)
        (loss,proof)<-sourceLossEvidence l c lost transport
        custody<-lossCustodyFixture l proof
        before<-auditExport l
        [Only sequenceNo]<-ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment" :: IO [Only Int64])
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER refuse_loss_capital BEFORE INSERT ON postings WHEN NEW.account='float' BEGIN SELECT RAISE(ABORT,'offline_loss_funding_failure'); END"
        recordSourceLossCover l lost loss 100 (LossCapital (amt 10000) (amt 0)) "cover" proof custody `shouldThrow` (\err->sqlError err==ErrorConstraint)
        readiness l `shouldThrow` isError "ledger_requires_reopen"
        pure(c,lost,loss,proof,before,sequenceNo)
      let (c,lost,loss,proof,before,sequenceNo)=saved
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` before
        sourceLossCover l (depositId lost) loss `shouldReturn` Nothing
        ledgerAction l (\db->query_ db "SELECT critical_sequence FROM deployment") `shouldReturn` [Only sequenceNo]
        ledgerAction l $ \db->execute_ db "DROP TRIGGER refuse_loss_capital"
        custody<-lossCustodyFixture l proof
        recordSourceLossCover l lost loss 100 (LossCapital (amt 10000) (amt 0)) "cover" proof custody
        ledgerAction l (\db->execute_ db "DELETE FROM source_loss_covers") `shouldThrow` (\err->sqlError err==ErrorConstraint)
    it "retries a failed capital return atomically after reopening without releasing the allocation twice" $ withDir $ \dir->do
      saved<-withNativeSourceAt True dir $ \l c source wallet transport->do
        _<-sourceObligation l source
        lost<-changeSource l c source wallet (-1)
        (loss,proof)<-sourceLossEvidence l c lost transport
        custody<-lossCustodyFixture l proof
        recordSourceLossCover l lost loss 100 (LossCapital (amt 10000) (amt 0)) "cover" proof custody
        _<-changeSource l c source wallet 2
        before<-auditExport l
        ledgerAction l $ \db->execute_ db "CREATE TRIGGER refuse_loss_return BEFORE INSERT ON postings WHEN NEW.account='float' AND NEW.delta>0 BEGIN SELECT RAISE(ABORT,'offline_capital_return_failure'); END"
        reconcileNativeSourcesWith transport c l `shouldThrow` (\err->sqlError err==ErrorConstraint)
        pure(c,transport,before)
      let (c,transport,before)=saved
      withLedger (dbPath c) (fingerprint c) $ \l->do
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM active_source_loss_covers" :: IO [Only Int]) `shouldReturn` [Only 1]
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_loss_returns" :: IO [Only Int]) `shouldReturn` [Only 0]
        ledgerAction l $ \db->execute_ db "DROP TRIGGER refuse_loss_return"
        _<-reconcileNativeSourcesWith transport c l
        sourceBalance l "float" `shouldReturn` 1000000
        sourceBalance l "source_deficit" `shouldReturn` 0
        after<-auditExport l
        _<-reconcileNativeSourcesWith transport c l
        auditExport l `shouldReturn` after
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM source_loss_returns" :: IO [Only Int]) `shouldReturn` [Only 1]
        ledgerAction l (\db->execute_ db "DELETE FROM source_loss_returns") `shouldThrow` (\err->sqlError err==ErrorConstraint)
  describe "native settlement finality recovery (offline RPC contracts)" $ do
    it "shows review for an additional refund while preserving the original conversion link" $ withDir $ \dir->
      withNativeSettlementAt dir $ \l _ a signed _ _ _->do
        [Only oid]<-ledgerAction l (\db->query db "SELECT order_id FROM obligations WHERE id=?" (Only $ attemptIntent a))
        -- Model the retained primary conversion view. The captured native
        -- attempt belongs to this order's separately settled refund obligation.
        ledgerAction l $ \db->execute db "UPDATE orders SET status='Paid',payout_tx='offline-primary-conversion' WHERE id=?" (Only (oid::Text))
        previous<-nativeSettlementPrevious l a
        recordNativeSettlementCheck l a previous NativeSettlementConfirming
        review<-readOrder l cap oid
        status review `shouldBe` "NeedsReview"
        payoutTx review `shouldBe` Just "offline-primary-conversion"
        recordNativeSettlementCheck l a previous (NativeSettlementReconfirmed (PaymentCosts (signedNativeFee signed) (amt 0))
          (nativeSettlementProof (attemptId a) custodyNativeTip (planDepth $ signedNativePlan signed)))
        recovered<-readOrder l cap oid
        status recovered `shouldBe` "Paid"
        payoutTx recovered `shouldBe` Just "offline-primary-conversion"
    it "reopens a lost-finality review and reconfirms the same payment without another financial decision" $ withDir $ \dir->do
      restartState<-withNativeSettlementAt dir $ \l c a signed wallet active transport->do
        before<-auditExport l
        originalProof<-nativeSettlementPrevious l a
        let intent=attemptIntent a
        [Only oid]<-ledgerAction l (\db->query db "SELECT order_id FROM obligations WHERE id=?" (Only intent))
        originalStatus<-status <$> readOrder l cap oid
        noChange<-reconcileNativeSettlementsWith transport{paymentIdentity=expectationFailure "unchanged payment rechecked RPC"} c l
        nativeSettlementStates noChange `shouldReturn` []
        modifyIORef' wallet (fmap $ setPath ["confirmations"] (Number 0))
        setNativeSettlementHistory l c (attemptId a) "unconfirmed" 0
        result<-reconcileNativeSettlementsWith transport c l
        nativeSettlementStates result `shouldReturn` ["confirming"]
        status <$> readOrder l cap oid `shouldReturn` "NeedsReview"
        resumeAfterChecks l `shouldThrow` isError "native_settlement_requires_review"
        custody<-reconcileCustodyWith (pure 100) transport c l
        fieldValue "lastError" custody `shouldReturn` Just ("native_settlement_requires_review"::Text)
        _<-reconcileNativeSettlementsWith transport c l
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_payment_recoveries" :: IO [Only Int]) `shouldReturn` [Only 1]
        auditExport l `shouldReturn` before
        nativeSettlementPrevious l a `shouldReturn` originalProof
        pure (c,a,signed,wallet,active,transport,before,originalProof,oid,originalStatus)
      let (c,a,_,wallet,active,transport,before,originalProof,oid,originalStatus)=restartState
      withLedger (dbPath c) (fingerprint c) $ \l->do
        let newAnchor=T.replicate 64 "e"
        writeIORef active newAnchor
        modifyIORef' wallet (fmap $ setPath ["blockhash"] (String newAnchor) . setPath ["confirmations"] (Number 2))
        setNativeSettlementHistory l c (attemptId a) newAnchor 2
        result<-reconcileNativeSettlementsWith transport c l
        nativeSettlementStates result `shouldReturn` ["reconfirmed"]
        auditExport l `shouldReturn` before
        status <$> readOrder l cap oid `shouldReturn` originalStatus
        available <$> readiness l `shouldReturn` False
        ledgerAction l (\db->query_ db "SELECT state,previous_observation FROM native_payment_recoveries ORDER BY id" :: IO [(Text,Text)])
          `shouldReturn` [("confirming",originalProof),("reconfirmed",originalProof)]
        nativeSettlementPrevious l a >>= (`shouldSatisfy` (/=originalProof))
        pendingAttempts l `shouldReturn` []
        ledgerAction l (\db->query_ db "SELECT COUNT(*),MIN(signed_bytes),MIN(state) FROM attempts" :: IO [(Int,Text,Text)])
          `shouldReturn` [(1,attemptBytes a,"settled")]
        ledgerAction l (\db->query_ db "SELECT resolved FROM intents" :: IO [Only Bool]) `shouldReturn` [Only True]
        ledgerAction l (\db->query_ db "SELECT released FROM fee_reservations" :: IO [Only Bool]) `shouldReturn` [Only True]
        replay<-reconcileNativeSettlementsWith transport{paymentIdentity=expectationFailure "completed recovery repeated RPC"} c l
        nativeSettlementStates replay `shouldReturn` []
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_payment_recoveries" :: IO [Only Int]) `shouldReturn` [Only 2]
    it "records a new confirmed anchor even when the unconfirmed interval was not observed" $ withDir $ \dir->
      withNativeSettlementAt dir $ \l c a _ wallet active transport->do
        before<-auditExport l
        let newAnchor=T.replicate 64 "e"
        writeIORef active newAnchor
        modifyIORef' wallet (fmap $ setPath ["blockhash"] (String newAnchor))
        setNativeSettlementHistory l c (attemptId a) newAnchor 2
        result<-reconcileNativeSettlementsWith transport c l
        nativeSettlementStates result `shouldReturn` ["reconfirmed"]
        auditExport l `shouldReturn` before
        available <$> readiness l `shouldReturn` False
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_payment_recoveries" :: IO [Only Int]) `shouldReturn` [Only 1]
    forM_ ["missing","conflicted","changed-bytes"] $ \scenario->
      it ("keeps a completed payment under review without replacement when "<>scenario) $ withDir $ \dir->
        withNativeSettlementAt dir $ \l c a _ wallet _ transport->do
          before<-auditExport l
          previous<-nativeSettlementPrevious l a
          setNativeSettlementHistory l c (attemptId a) "unconfirmed" 0
          case scenario of
            "missing"->writeIORef wallet Nothing
            "conflicted"->modifyIORef' wallet (fmap $ setPath ["walletconflicts"] (toJSON [T.replicate 64 "f"]))
            _->modifyIORef' wallet (fmap $ setPath ["hex"] (String "00"))
          result<-reconcileNativeSettlementsWith transport c l
          nativeSettlementStates result `shouldReturn` ["requires_review"]
          auditExport l `shouldReturn` before
          nativeSettlementPrevious l a `shouldReturn` previous
          createRefund l "native:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:0"
            >>= \ob->prepareNativeWith (paymentNative transport) c l ob `shouldThrow` isError "payouts_paused"
          pendingAttempts l `shouldReturn` []
          resumeAfterChecks l `shouldThrow` isError "native_settlement_requires_review"
    it "will not replace settlement proof until the durable scanner agrees with the canonical read" $ withDir $ \dir->
      withNativeSettlementAt dir $ \l c a _ wallet active transport->do
        previous<-nativeSettlementPrevious l a
        let newAnchor=T.replicate 64 "e"
        setNativeSettlementHistory l c (attemptId a) "unconfirmed" 0
        writeIORef active newAnchor
        modifyIORef' wallet (fmap $ setPath ["blockhash"] (String newAnchor))
        result<-reconcileNativeSettlementsWith transport c l
        nativeSettlementStates result `shouldReturn` ["requires_review"]
        nativeSettlementPrevious l a `shouldReturn` previous
        ledgerAction l (\db->query_ db "SELECT state FROM native_payment_recoveries" :: IO [Only Text]) `shouldReturn` [Only "unavailable"]
        available <$> readiness l `shouldReturn` False
    it "rejects changed costs or confirmation policy and retains every earlier recovery decision" $ withDir $ \dir->
      withNativeSettlementAt dir $ \l _ a signed _ _ _->do
        previous<-nativeSettlementPrevious l a
        let proof=nativeSettlementProof (attemptId a) custodyNativeTip (planDepth $ signedNativePlan signed)
            costs=PaymentCosts (signedNativeFee signed) (amt 0)
        recordNativeSettlementCheck l a previous (NativeSettlementReconfirmed costs{networkFee=amt 999} proof)
          `shouldThrow` isError "native_recovery_cost_changed"
        recordNativeSettlementCheck l a previous (NativeSettlementReconfirmed costs (nativeSettlementProof (attemptId a) custodyNativeTip 2))
          `shouldThrow` isError "native_recovery_policy_changed"
        recordNativeSettlementCheck l a previous NativeSettlementConfirming
        ledgerAction l (\db->execute_ db "DELETE FROM native_payment_recoveries") `shouldThrow` (\err->sqlError err==ErrorConstraint)
    it "treats missing confirmation metadata as unavailable instead of accepting SQL NULL as a match" $ withDir $ \dir->
      withNativeSettlementAt dir $ \l c a _ _ _ transport->do
        previous<-nativeSettlementPrevious l a
        cursor<-readCheckpoint l "Native"
        commitScan l (ScanBatch "Native" (nativeCheckpointHash c) cursor custodyNativeTip 100 []
          [ChainEvent (attemptId a) "outgoing" custodyNativeTip (object [])])
        result<-reconcileNativeSettlementsWith transport c l
        nativeSettlementStates result `shouldReturn` ["requires_review"]
        nativeSettlementPrevious l a `shouldReturn` previous
        ledgerAction l (\db->query_ db "SELECT state FROM native_payment_recovery_state" :: IO [Only Text]) `shouldReturn` [Only "unavailable"]
    it "refuses a stale attempt snapshot instead of overwriting a newer decision" $ withDir $ \dir->
      withNativeSettlementAt dir $ \l _ a _ _ _ _->do
        before<-auditExport l
        recordNativeSettlementCheck l a "stale observation" NativeSettlementConfirming `shouldThrow` isError "native_settlement_changed"
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM native_payment_recoveries" :: IO [Only Int]) `shouldReturn` [Only 0]
    it "records identity refusal without a signer, backup, send or money movement" $ withDir $ \dir->
      withNativeSettlementAt dir $ \l c a _ _ _ transport->do
        before<-auditExport l
        setNativeSettlementHistory l c (attemptId a) "unconfirmed" 0
        result<-reconcileNativeSettlementsWith transport{paymentIdentity=reject "native_checkpoint_mismatch"} c l
        nativeSettlementStates result `shouldReturn` ["requires_review"]
        auditExport l `shouldReturn` before
        ledgerAction l (\db->query_ db "SELECT state FROM native_payment_recovery_state" :: IO [Only Text]) `shouldReturn` [Only "unavailable"]
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
  describe "paused worker payment recovery (offline RPC contracts)" $ do
    it "never sends unseen signed or broadcast bytes even when the deployment is available" $ forM_ [False,True] $ \broadcast ->
      withSendFixture $ \l c _ attempt transport -> do
        when broadcast $ markBroadcastIntent l (attemptId attempt) >> pure ()
        before<-pendingAttempts l
        financial<-auditExport l
        let call method params=if method=="sendTransaction" then expectationFailure "recovery sent a transaction" >> pure Null
              else paymentSolana transport method params
        result<-reconcilePaymentsWith transport{paymentSolana=call} c l
        recoveryOutcomes result `shouldReturn` ["unseen"]
        fieldValue "signedOrSent" result `shouldReturn` False
        pendingAttempts l `shouldReturn` before
        auditExport l `shouldReturn` financial
        available <$> readiness l `shouldReturn` True
    forM_ [True,False] $ \success ->
      it ("books a finalized outcome once while paused: "<>show success) $ withSendFixture $ \l c ob attempt transport -> do
        _<-markBroadcastIntent l (attemptId attempt)
        signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy attempt)
        proof<-codecSettlementProof c signed success
        pause l "restart-quarantine"
        let call method _=if method=="getTransaction" then pure proof else expectationFailure "unexpected recovery mutation" >> pure Null
        first<-reconcilePaymentsWith transport{paymentSolana=call} c l
        recoveryOutcomes first `shouldReturn` [if success then "settled" else "failed"]
        pendingAttempts l `shouldReturn` []
        pendingPreparations l `shouldReturn` []
        status <$> readOrder l cap (obligationOrder ob) `shouldReturn` (if success then "Paid" else "NeedsReview")
        financial<-auditExport l
        second<-reconcilePaymentsWith transport{paymentIdentity=expectationFailure "terminal payment repeated chain IO"} c l
        recoveryOutcomes second `shouldReturn` []
        auditExport l `shouldReturn` financial
        available <$> readiness l `shouldReturn` False
    it "records an already-paid outcome during source review without reopening payouts" $ withSendFixture $ \l c ob attempt transport -> do
      _<-markBroadcastIntent l (attemptId attempt)
      signed<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ attemptPolicy attempt)
      proof<-codecSettlementProof c signed True
      refreshDeposit l (Deposit (obligationDeposit ob) (Just $ obligationOrder ob) Native (amt 4) (T.replicate 64 "b") 0 False 100)
      result<-reconcilePaymentsWith transport{paymentSolana= \method _ -> if method=="getTransaction" then pure proof else reject "unexpected"} c l
      recoveryOutcomes result `shouldReturn` ["settled"]
      pendingAttempts l `shouldReturn` []
      available <$> readiness l `shouldReturn` False
      ledgerAction l (\db->query_ db "SELECT eligible FROM deposits" :: IO [Only Bool]) `shouldReturn` [Only False]
      createRefund l (obligationDeposit ob) `shouldThrow` isError "refundable_deposit_not_found"
    it "preserves an unseen native attempt and its locks without signing or releasing fees" $ withNativeCancellation $ \l c p locks transport -> do
      captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
      (plan,previous,fee,tx)<-nativeFixture
      decoded<-fieldValue "decoded" captured :: IO Value
      raw<-fieldValue "raw" captured
      let ob=preparationObligation p
          signed=NativeSigned raw tx plan previous fee
          call _ method _=case method of
            "decoderawtransaction" -> pure decoded
            "gettransaction" -> reject "rpc_error_-5"
            _ -> expectationFailure "native recovery touched signer, wallet locks or broadcast" >> pure Null
      storeAttempt l ob "Native" (nativeTxid tx) raw (fixtureJson signed) 1000 Nothing 0
      before<-pendingAttempts l
      held<-readIORef locks
      result<-reconcilePaymentsWith transport{paymentNative=call} c l
      recoveryOutcomes result `shouldReturn` ["unseen"]
      pendingAttempts l `shouldReturn` before
      readIORef locks `shouldReturn` held
      ledgerAction l (\db->query_ db "SELECT released FROM fee_reservations" :: IO [Only Bool]) `shouldReturn` [Only False]
    it "pauses and retains contradictory evidence or an unavailable RPC without duplicate alerts" $ withSendFixture $ \l c _ attempt transport -> do
      let unavailable method params=if method=="getTransaction" then ioError (userError "offline connection lost") else paymentSolana transport method params
      first<-reconcilePaymentsWith transport{paymentSolana=unavailable} c l
      recoveryOutcomes first `shouldReturn` ["requires_review"]
      [failure]<-fieldValue "attempts" first :: IO [Value]
      fieldValue "error" failure `shouldReturn` Just ("payment_observation_io_unavailable"::Text)
      second<-reconcilePaymentsWith transport{paymentSolana=unavailable} c l
      second `shouldBe` first
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM audit WHERE action='pause' AND detail='payment_recovery:payment_observation_io_unavailable'" :: IO [Only Int]) `shouldReturn` [Only 1]
      let premature method params=if method=="getSignatureStatuses" then pure $ contextContract $ toJSON [object ["confirmationStatus" .= ("processed"::Text)]] else paymentSolana transport method params
      third<-reconcilePaymentsWith transport{paymentSolana=premature} c l
      [contradiction]<-fieldValue "attempts" third :: IO [Value]
      fieldValue "error" contradiction `shouldReturn` Just ("unrecorded_broadcast_observed"::Text)
      map attemptBytes <$> pendingAttempts l `shouldReturn` [attemptBytes attempt]
      available <$> readiness l `shouldReturn` False
    it "retires conclusively expired bytes without authorizing a new preparation" $ withSendFixture $ \l c ob attempt transport -> do
      let configured=expiryConfig c
      recordExpiryOrigins l configured
      _<-markBroadcastIntent l (attemptId attempt)
      pause l "restart-quarantine"
      result<-reconcilePaymentsWith transport{paymentSolana=expiryContract configured} configured l
      recoveryOutcomes result `shouldReturn` ["expired"]
      pendingAttempts l `shouldReturn` []
      pendingPreparations l `shouldReturn` []
      readyObligations l `shouldReturn` []
      status <$> readOrder l cap (obligationOrder ob) `shouldReturn` "NeedsReview"
      ledgerAction l (\db->query_ db "SELECT COUNT(*) FROM solana_retry_approvals" :: IO [Only Int]) `shouldReturn` [Only 0]
      ledgerAction l (\db->query_ db "SELECT signed_bytes FROM attempts" :: IO [Only Text]) `shouldReturn` [Only $ attemptBytes attempt]
    it "continues booking the other chain after one attempt requires review" $ withSendFixture $ \l c _ attempt transport -> do
      captured<-BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
      (plan,previous,fee,tx)<-nativeFixture
      decoded<-fieldValue "decoded" captured :: IO Value
      raw<-fieldValue "raw" captured
      fundAllocation l "second-chain-fees" Sol "operating" (amt 3000000)
      fundAllocation l "second-chain-inventory" Wrapped "float" (amt 100000)
      o<-createOrder l c 100 cap req{refund=planRecipient plan,idempotencyKey="second-chain-refund"}
      bindInstruction l (orderId o) "fixture-second-native-address"
      observeDeposit l (Deposit "second-native:0" (Just $ orderId o) Native (amt 100000) "anchor" 1 True 100) "cursor"
      ob<-createRefund l "second-native:0"
      let signed=NativeSigned raw tx plan previous fee
      testAttempt l c ob "Native" (nativeTxid tx) raw (fixtureJson signed) 1000 Nothing
      _<-markBroadcastIntent l (nativeTxid tx)
      let native _ method _=case method of
            "decoderawtransaction" -> pure decoded
            "gettransaction" -> pure $ object ["txid" .= nativeTxid tx,"hex" .= raw,"decoded" .= decoded
              ,"fee" .= Number (negate (fromIntegral $ units fee) / 100000000),"confirmations" .= (2::Int),"walletconflicts" .= ([]::[Text]),"blockhash" .= custodyNativeTip]
            "getblockheader" -> pure $ object ["hash" .= custodyNativeTip,"height" .= (100::Int),"confirmations" .= (2::Int)]
            "getblockhash" -> pure $ toJSON custodyNativeTip
            _ -> expectationFailure "unexpected native recovery RPC" >> pure Null
          sol method params=if method=="getTransaction" then reject "rpc_error_429" else paymentSolana transport method params
      result<-reconcilePaymentsWith transport{paymentNative=native,paymentSolana=sol} c l
      reports<-fieldValue "attempts" result :: IO [Value]
      mapM (fieldValue "error") reports `shouldReturn` [Just ("rpc_error_429"::Text),Nothing]
      recoveryOutcomes result `shouldReturn` ["requires_review","settled"]
      map attemptId <$> pendingAttempts l `shouldReturn` [attemptId attempt]
      status <$> readOrder l cap (orderId o) `shouldReturn` "Refunded"
      available <$> readiness l `shouldReturn` False
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
      resumeAfterChecks l `shouldThrow` isError "obligations_require_review"
      beginPreparation l c ob "Solana" (attemptFeeLimit attempt) "new-policy" `shouldThrow` isError "payouts_paused"
      -- Offline fault injection preserves coverage of the inner guards even
      -- if a caller incorrectly bypasses the stronger resume refusal.
      ledgerAction l $ \db->execute_ db "UPDATE deployment SET paused=0"
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
  describe "native replacement construction (captured public templates and offline pending contracts)" $ do
    it "raises only the fee, preserving every input and the exact customer payment" $ withNativeReplacementContract $ \c original draft call calls->do
      let fee=draftFee draft
          old=signedNativeTransaction original
          new=draftTransaction draft
          customer=NativeOutput (planRecipientScript $ signedNativePlan original) (planAmount $ signedNativePlan original)
      validateNativeFamily [original] `shouldBe` Right ()
      validateNativeReplacementDraft [original] fee draft `shouldBe` Right ()
      units fee-units (signedNativeFee original) `shouldBe` 100
      nativeInputs new `shouldBe` nativeInputs old
      filter (==customer) (nativeOutputs new) `shouldBe` [customer]
      draftNativeReplacementWith call c [original] fee `shouldReturn` draft
      methods<-map fst <$> readIORef calls
      length (filter (=="createpsbt") methods) `shouldBe` 1
      methods `shouldSatisfy` all (`notElem` ["sendrawtransaction","lockunspent","getrawchangeaddress","walletcreatefundedpsbt"])
    it "rejects non-increasing fees, the immutable ceiling and exhausted change" $ withNativeReplacementContract $ \_ original _ _ _->do
      let plan=signedNativePlan original
          old=signedNativeFee original
      forM_ [old,amt $ toInteger (units old)-1,amt $ toInteger (units $ planFeeLimit plan)+1] $ \fee->
        replacementOutputs original fee `shouldBe` Left "native_replacement_fee_bounds"
      let change=sum [toInteger $ units $ nativeOutputAmount o | o<-nativeOutputs $ signedNativeTransaction original,nativeOutputScript o==planChangeScript plan]
          exhausted=amt $ toInteger (units old)+change
          enlarged=original{signedNativePlan=plan{planFeeLimit=exhausted}}
      replacementOutputs enlarged exhausted `shouldBe` Left "native_replacement_change_unavailable"
    it "cannot replace original inputs with fresh inputs even at the same value" $ withNativeReplacementContract $ \_ original draft _ _->do
      let tx=draftTransaction draft
          changed point=point{outpointTxid=nativeTxid tx}
          bad=draft{draftTransaction=tx{nativeInputs=[input{nativeOutpoint=changed $ nativeOutpoint input} | input<-nativeInputs tx]}
            ,draftPrevouts=[p{prevout=changed $ prevout p} | p<-draftPrevouts draft]}
      validateNativeTx (signedNativePlan original) (draftPrevouts bad) (draftFee bad) (draftTransaction bad) `shouldBe` Right ()
      validateNativeReplacementDraft [original] (draftFee draft) bad `shouldBe` Left "native_replacement_draft_changed"
    it "rejects changed replay fields and a changed recipient despite balanced fees" $ withNativeReplacementContract $ \_ original draft _ _->do
      let tx=draftTransaction draft
          plan=signedNativePlan original
          moved=tx{nativeOutputs=[if nativeOutputScript o==planRecipientScript plan then o{nativeOutputScript=planChangeScript plan} else o | o<-nativeOutputs tx]}
          rbf=tx{nativeInputs=[i{nativeSequence=4294967293} | i<-nativeInputs tx]}
      forM_ [tx{nativeLocktime=1},rbf] $ \bad->
        validateNativeReplacementDraft [original] (draftFee draft) draft{draftTransaction=bad} `shouldBe` Left "native_replay_policy_mismatch"
      validateNativeReplacementDraft [original] (draftFee draft) draft{draftTransaction=moved} `shouldBe` Left "native_output_mismatch"
      validateNativeFamily [] `shouldBe` Left "native_replacement_family_bounds"
      validateNativeFamily [original,original] `shouldBe` Left "native_replacement_duplicate_member"
      validateNativeFamily (replicate 9 original) `shouldBe` Left "native_replacement_family_bounds"
    it "accepts an evicted saved payment only while all exact chain inputs remain available" $ withNativeReplacementContract $ \c original draft call _->do
      let unseen wallet method params=case method of
            "gettransaction"->reject "rpc_error_-5"
            "gettxspendingprevout"->pure $ toJSON $ map (toJSON.nativeOutpoint) $ nativeInputs $ signedNativeTransaction original
            _->call wallet method params
      draftNativeReplacementWith unseen c [original] (draftFee draft) `shouldReturn` draft
    forM_ [(1,"confirmed"),(-1,"conflicted")] $ \(depth,caseName)->
      it ("refuses a "<>caseName<>" family member before constructing a PSBT") $ withNativeReplacementContract $ \c original draft call calls->do
        let changed wallet method params=do
              value<-call wallet method params
              pure $ if method=="gettransaction" then setPath ["confirmations"] (toJSON (depth::Int)) value else value
        draftNativeReplacementWith changed c [original] (draftFee draft) `shouldThrow` isError "native_replacement_member_not_pending"
        map fst <$> readIORef calls >>= (`shouldSatisfy` (not . elem "createpsbt"))
    it "refuses a mempool spender outside the saved family" $ withNativeReplacementContract $ \c original draft call _->do
      let changed wallet method params=if method=="gettxspendingprevout" then pure $ toJSON
            [object ["txid" .= outpointTxid point,"vout" .= outpointVout point,"spendingtxid" .= nativeTxid (draftTransaction draft)]
            | point<-map nativeOutpoint $ nativeInputs $ signedNativeTransaction original] else call wallet method params
      draftNativeReplacementWith changed c [original] (draftFee draft) `shouldThrow` isError "native_replacement_unknown_spender"
    it "refuses an input already spent in the active chain" $ withNativeReplacementContract $ \c original draft call _->do
      let changed wallet method params=if method=="gettxout" then pure Null else call wallet method params
      draftNativeReplacementWith changed c [original] (draftFee draft) `shouldThrow` isError "native_replacement_input_spent"
    it "refuses lagging wallet state and a wrong chain checkpoint" $ withNativeReplacementContract $ \c original draft call _->do
      let lagging wallet method params=do
            value<-call wallet method params
            pure $ if method=="getwalletinfo" then setPath ["lastprocessedblock","height"] (toJSON (16009::Int)) value else value
          wrong wallet method params=if method=="getblockhash" then pure (String $ T.replicate 64 "f") else call wallet method params
      draftNativeReplacementWith lagging c [original] (draftFee draft) `shouldThrow` isError "native_replacement_wallet_behind"
      draftNativeReplacementWith wrong c [original] (draftFee draft) `shouldThrow` isError "native_checkpoint_mismatch"
    it "discards a draft if the chain view changes while it is being built" $ withNativeReplacementContract $ \c original draft call _->do
      checks<-newIORef (0::Int)
      let changed wallet method params=do
            value<-call wallet method params
            if method/="getblockchaininfo" then pure value else do
              modifyIORef' checks (+1)
              count<-readIORef checks
              pure $ if count>1 then setPath ["bestblockhash"] (String $ T.replicate 64 "f") value else value
      draftNativeReplacementWith changed c [original] (draftFee draft) `shouldThrow` isError "native_replacement_view_changed"
    it "rejects unexpected signatures and mismatched PSBT fees" $ withNativeReplacementContract $ \c original draft call _->do
      let altered signature wallet method params=do
            value<-call wallet method params
            if method/="decodepsbt" then pure value else if signature then do
              inputs<-fieldValue "inputs" value :: IO [Value]
              pure $ setPath ["inputs"] (toJSON [setPath ["partial_signatures"] (object ["unexpected" .= ("00"::Text)]) input | input<-inputs]) value
             else pure $ setPath ["fee"] (toJSON $ nativeNumber $ amt $ toInteger (units $ draftFee draft)+1) value
      draftNativeReplacementWith (altered True) c [original] (draftFee draft) `shouldThrow` isError "native_replacement_not_unsigned"
      draftNativeReplacementWith (altered False) c [original] (draftFee draft) `shouldThrow` isError "native_replacement_draft_changed"
    it "propagates unavailable RPC evidence without allocating keys or signing" $ withNativeReplacementContract $ \c original draft call calls->do
      let unavailable wallet method params=if method=="gettxout" then reject "rpc_error_-28" else call wallet method params
      draftNativeReplacementWith unavailable c [original] (draftFee draft) `shouldThrow` isError "rpc_error_-28"
      map fst <$> readIORef calls >>= (`shouldSatisfy` (not . elem "walletprocesspsbt"))
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
    it "refuses canonical and backup-dependent deployments in the local test command" $ withDir $ \dir->do
      runTestWorker (cfg dir){profile=CanonicalBeta} `shouldThrow` isError "public_test_profile_required"
      runTestWorker (cfg dir){backupRequired=True} `shouldThrow` isError "public_test_profile_required"
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
          case configResult of
            Right value->fieldValue "intakeEnabled" value `shouldReturn` False
            Left _->expectationFailure "configuration unavailable"
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
    it "reconnects the first GET and POST after worker replacement without replacing the clients" $ withDir $ \dir -> do
      let c=cfg dir
          _ :<|> createCall :<|> _ :<|> _ :<|> _ :<|> healthCall :<|> _ = client customerAPI
      reader <- unixManager (customerSocket c)
      writer <- unixManager (customerSocket c)
      let readEnv=mkClientEnv reader (BaseUrl Http "localhost" 80 "")
          writeEnv=mkClientEnv writer (BaseUrl Http "localhost" 80 "")
      withAsync (runWorkerWith c (const $ pure ())) $ \_ -> do
        awaitFile (customerSocket c) 100
        runClientM healthCall readEnv `shouldReturn` Right (Availability True "process_running")
        runClientM healthCall writeEnv `shouldReturn` Right (Availability True "process_running")
      -- Only fixture sockets are removed. Keeping both client managers alive
      -- across the worker's replacement reproduces the live stale-pool error.
      removeFile (customerSocket c)
      removeFile (adminSocket c)
      withAsync (runWorkerWith c (const $ pure ())) $ \_ -> do
        awaitFile (customerSocket c) 100
        awaitFile (adminSocket c) 100
        runClientM healthCall readEnv `shouldReturn` Right (Availability True "process_running")
        result <- runClientM (createCall "Bearer invalid" req) writeEnv
        result `shouldSatisfy` (\case Left (FailureResponse _ _) -> True; _ -> False)
  describe "historical Solana deposit evidence" $ do
    it "binds a Solana Pay reference to the transfer and historical owner (offline contract)" $ do
      captured <- BS.readFile "test/fixtures/solana-devnet-order-deposit.json" >>= either fail pure . eitherDecodeStrict'
      binding <- fieldValue "binding" captured
      original <- fieldValue "transaction" captured
      tx <- fieldValue "transaction" original
      message <- fieldValue "message" tx
      keys <- fieldValue "accountKeys" message :: IO [Text]
      reference <- either (fail . T.unpack) pure (Pay.payReference $ T.replicate 64 "f")
      index <- maybe (fail "memo program missing") pure (elemIndex "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr" keys)
      instructions <- fieldValue "instructions" message :: IO [Value]
      tokenInstructions <- mapM (\ix->do
        program <- fieldValue "programIdIndex" ix :: IO Int
        accounts <- fieldValue "accounts" ix :: IO [Int]
        pure (keys!!program,case ix of Object fields->Object(KM.insert "accounts" (toJSON $ accounts<>[index]) fields); _->ix)) instructions
      let proof=setPath ["transaction","message","accountKeys"] (toJSON [if i==index then reference else key | (i,key)<-zip [0..] keys]) $
            setPath ["transaction","message","instructions"] (toJSON [ix | (program,ix)<-tokenInstructions,program==tokenProgram]) original
      expected <- Pay.PayBinding <$> fieldValue "signature" binding <*> fieldValue "mint" binding
        <*> fieldValue "custody" binding <*> fieldValue "custodyOwner" binding <*> pure reference
      owner <- fieldValue "owner" binding
      verifiedOwner <$> Pay.verifyPay expected proof `shouldBe` Right owner
      Pay.verifyPay expected{Pay.payOrderReference="11111111111111111111111111111111"} proof `shouldSatisfy` either (const True) (const False)
      Pay.verifyPay expected (setPath ["transaction","message","header","numReadonlyUnsignedAccounts"] (Number 0) proof) `shouldSatisfy` either (const True) (const False)
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
