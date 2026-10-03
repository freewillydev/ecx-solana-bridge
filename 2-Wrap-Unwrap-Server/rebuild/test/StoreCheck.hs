{-# LANGUAGE GADTs, ScopedTypeVariables #-}
module Main (main) where
import Bridge.Identity (capabilityHash,payInstruction)
import qualified Bridge.Wire as W
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Data.Profunctor.Product (p8,p10)
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),CostLimits(..),PolicySnapshot(..))
import Bridge.Store
import qualified Bridge.Store.Schema as S
import Control.Exception
import Data.Int (Int64)
import Data.List (sort)
import Data.IORef
import Test.QuickCheck (quickCheckWithResult,stdArgs,maxSuccess,forAll,chooseInteger,ioProperty,isSuccess)
import Control.Monad (unless,void,when,forM_)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import System.Environment (getEnv)

main :: IO ()
main = do
  database <- getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user <- getEnv "USER"
  readRole <- getEnv "ECX_REBUILD_CONTRACT_READER"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      readerSettings=settings {PG.connectUser=readRole}
      policy=PaymentTerms (PolicySnapshot 2 "finalized" "contract") (CostLimits (money 10) (money 10) (money 10))
      limits=OrderLimits (money 2) (money 1000) 100 100 100 (money 100000) (money 100000)
      store terms config=StorePolicy terms config "contract" True
      key=T.replicate 64 "a"
      reserve=ReserveFees 100 key Native (money 100) "recipient" "test owned revenue"
      check ok=unless ok (fail "store contract failed")
  bracket (PG.connect settings) PG.close $ \fixtures -> do
    fixture fixtures Initialize
    withReader readerSettings "contract" True $ \reader -> do
      expectStore "unsafe_read_database_role" (withReader settings "contract" True $ const $ pure ())
      expectStore "ledger_profile_or_schema_mismatch" (withReader readerSettings "wrong" True $ const $ pure ())
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        expectStore "worker_already_running" (withWriter settings (store policy limits) (const $ pure ()) $ const $ pure ())
        initial <- evalRead reader ReadBalances
        first <- evalWrite writer reserve
        replay <- evalWrite writer reserve
        check (first==replay && withdrawalSequence first==1)
        booked <- evalRead reader ReadBalances
        check (M.lookup (Native,Earned) booked==Just 900 && M.lookup (Native,FeePending) booked==Just 100)
        expectStore "fee_withdrawal_conflict" (evalWrite writer $ ReserveFees 100 key Native (money 101) "recipient" "test owned revenue")
        expectStore "custody_not_reconciled" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "b") Native (money 100) "recipient" "test owned revenue")
        fixture fixtures RefreshCustody
        expectStore "insufficient_earned_fees" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "b") Native (money 1000) "recipient" "test owned revenue")
        cancelled <- evalWrite writer (CancelFees key "cancel")
        replayCancelled <- evalWrite writer (CancelFees key "cancel")
        check (cancelled==replayCancelled && withdrawalCancellation cancelled==Just("cancel",2))
        restored <- evalRead reader ReadBalances
        check (M.filter (/=0) restored==M.filter (/=0) initial)
        expectStore "fee_withdrawal_cancellation_conflict" (evalWrite writer (CancelFees key "changed"))
        resumed <- evalWrite writer reserve
        check (withdrawalCancellation resumed==Just("cancel",2))
        counter <- newIORef (0::Int)
        result <- quickCheckWithResult stdArgs {maxSuccess=25} $ forAll (chooseInteger (1,1000)) $ \n -> ioProperty $ do
          index <- atomicModifyIORef' counter (\i->(i+1,i+1))
          let identifier=T.justifyRight 64 '0' (T.pack $ show index)
          fixture fixtures RefreshCustody
          before <- evalRead reader ReadBalances
          reserved <- evalWrite writer (ReserveFees 100 identifier Native (money n) "recipient" "property")
          afterReserve <- evalRead reader ReadBalances
          _ <- evalWrite writer (CancelFees identifier "property cancel")
          afterCancel <- evalRead reader ReadBalances
          pure (units(paymentAmount $ withdrawalPayment reserved)==fromInteger n &&
            M.findWithDefault 0 (Native,Earned) afterReserve==1000-n &&
            M.findWithDefault 0 (Native,FeePending) afterReserve==n &&
            M.filter (/=0) before==M.filter (/=0) afterCancel)
        check (isSuccess result)
      -- A failed durable checkpoint rolls back money and permanently fences the
      -- writer. Reader checks use separate SELECT-only credentials throughout.
      fixture fixtures RefreshCustody
      beforeFailure <- evalRead reader ReadState
      let failCheckpoint n=when (n>ledgerSequence beforeFailure) (ioError $ userError "injected checkpoint failure")
      withWriter settings (store policy limits) failCheckpoint $ \writer -> do
        failure <- try (evalWrite writer $ ReserveFees 100 (T.replicate 64 "c") Native (money 100) "recipient" "test rollback") :: IO (Either IOException WithdrawalView)
        check (case failure of Left _->True; Right _->False)
        expectStore "ledger_connection_fenced" (evalWrite writer (Pause "must fail"))
      rolledBack <- evalRead reader (ReadWithdrawal $ T.replicate 64 "c")
      state <- evalRead reader ReadState
      check (rolledBack==Nothing && ledgerSequence state==ledgerSequence beforeFailure)
      fixture fixtures SeedOrders
      let auth="Bearer "<>T.replicate 64 "0"
      hidden <- evalRead reader (ReadOrder auth "hidden")
      check (W.depositInstruction hidden==Nothing && units(net $ W.quote hidden)==93)
      expectStore "order_not_found" (evalRead reader $ ReadOrder ("Bearer "<>T.replicate 64 "1") "hidden")
      expectStore "authorization_required" (evalRead reader $ ReadOrder "" "hidden")
      expectStore "invalid_capability" (evalRead reader $ ReadOrder "Bearer invalid" "hidden")
      expectStore "backup_pending" (evalRead reader $ ReadOrder auth "visible")
      expectStore "saved_order_terms_mismatch" (evalRead reader $ ReadOrder auth "mismatch")
      expectStore "corrupt_ledger_json" (evalRead reader $ ReadOrder auth "corrupt")
      fixture fixtures CoverBackup
      visible <- evalRead reader (ReadOrder auth "visible")
      check (W.depositInstruction visible==Just "instruction-visible" && W.status visible=="AwaitingDeposit")
      fixture fixtures SeedReview
      reviewed <- evalRead reader (ReadOrder auth "visible")
      check (W.status reviewed=="NeedsReview")
      fixture fixtures SeedIntake
      let newRequest=W.OrderRequest NativeToWrapped (money 100) "recipient" "refund" Nothing "new-wrap"
          create request=CreateOrder 100 auth request
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        expectStore "intake_paused" (evalWrite writer $ create newRequest)
        fixture fixtures ReadyIntake
        before <- fixture fixtures OrderSnapshot
        identifier <- evalWrite writer (create newRequest)
        replay <- evalWrite writer (create newRequest)
        after <- fixture fixtures OrderSnapshot
        check (identifier==replay && zipWith (-) after before==[1,1,1,2])
        view <- evalRead reader (ReadOrder auth identifier)
        check (W.request view==newRequest && gross(W.quote view)==money 100 && fee(W.quote view)==money 1 && net(W.quote view)==money 99 && W.status view=="Provisioning" && W.depositInstruction view==Nothing && W.deadline view==200)
        expectStore "idempotency_conflict" (evalWrite writer $ create newRequest {W.input=money 101})
        -- Each rejection must leave orders, inventory holds, saved cost limits
        -- and operating reservations exactly unchanged.
        let rejected expected request=do
              prior <- fixture fixtures OrderSnapshot
              expectStore expected (evalWrite writer $ create request)
              following <- fixture fixtures OrderSnapshot
              check (prior==following)
        fixture fixtures StaleCustody
        rejected "custody_not_reconciled" newRequest {W.idempotencyKey="stale"}
        fixture fixtures ReadyIntake
        rejected "amount_outside_limits" newRequest {W.idempotencyKey="small",W.input=money 1}
        rejected "invalid_connection_free_order" newRequest {W.idempotencyKey="connected",W.sourceOwner=Just "owner"}
        rejected "insufficient_inventory" newRequest {W.idempotencyKey="large",W.input=money 1000}
        let unwrap=newRequest {W.idempotencyKey="new-unwrap",W.direction=WrappedToNative,W.refund="",W.input=money 201}
        other <- evalWrite writer (create unwrap)
        fixture fixtures (CheckHolds identifier NativeToWrapped 99) >>= check
        fixture fixtures (CheckHolds other WrappedToNative 198) >>= check
        otherView <- evalRead reader (ReadOrder auth other)
        check (fee(W.quote otherView)==money 3 && net(W.quote otherView)==money 198)
        fixture fixtures ReadyIntake
        expectStore "scanners_not_fresh" (evalWrite writer $ CreateOrder 161 auth newRequest {W.idempotencyKey="old-scan"})
      let failedAdmission config terms expected=withWriter settings (store terms config) (const $ pure ()) $ \writer -> do
            fixture fixtures ReadyIntake
            before <- fixture fixtures OrderSnapshot
            expectStore expected (evalWrite writer $ create newRequest {W.idempotencyKey="reject"})
            after <- fixture fixtures OrderSnapshot
            check (before==after)
      failedAdmission limits {maximumQueued=1} policy "queue_full"
      failedAdmission limits {nativeDaily=money 1} policy "operating_daily_limit"
      failedAdmission limits policy {paymentLimits=CostLimits (money 1000) (money 10) (money 10)} "insufficient_fee_budget"
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        fixture fixtures ReadyIntake
        native <- evalWrite writer (create newRequest {W.idempotencyKey="provision-native"})
        solana <- evalWrite writer (create newRequest {W.idempotencyKey="provision-solana",W.direction=WrappedToNative,W.refund=""})
        late <- evalWrite writer (create newRequest {W.idempotencyKey="provision-late"})
        claim <- evalWrite writer (ClaimNative 100 auth native)
        retryClaim <- evalWrite writer (ClaimNative 100 auth native)
        check (mayAllocate claim && not(mayAllocate retryClaim) && allocationLabel claim==allocationLabel retryClaim)
        lateClaim <- evalWrite writer (ClaimNative 100 auth late)
        let address="tb1q9vl0cpvddncs78537mrpxawydzsgkz7k5hgj7w"
        nativeSequence <- evalWrite writer (RecordNative auth native (allocationLabel claim) address)
        replaySequence <- evalWrite writer (RecordNative auth native (allocationLabel claim) address)
        check (nativeSequence==replaySequence)
        expectStore "instruction_is_immutable" (evalWrite writer $ RecordNative auth native (allocationLabel claim) "different-address")
        expectStore "invalid_native_allocation_result" (evalWrite writer $ RecordNative auth native "wrong-label" address)
        expectStore "invalid_solana_provisioning_order" (evalWrite writer $ BindSolana 100 auth native)
        solanaSequence <- evalWrite writer (BindSolana 100 auth solana)
        solanaReplay <- evalWrite writer (BindSolana 100 auth solana)
        check (solanaSequence==solanaReplay)
        beforeExposure <- evalRead reader (ReadOrder auth native)
        check (W.depositInstruction beforeExposure==Nothing)
        expectStore "backup_pending" (evalWrite writer $ IssueInstruction 100 auth native)
        let cover=do
              stateNow <- evalRead reader ReadState
              evalWrite writer (AcknowledgeBackup "contract" (ledgerSequence stateNow) (T.replicate 64 "0"))
        stateNow <- evalRead reader ReadState
        expectStore "invalid_backup_coverage" (evalWrite writer $ AcknowledgeBackup "contract" (ledgerSequence stateNow+1) (T.replicate 64 "0"))
        expectStore "ledger_profile_or_schema_mismatch" (evalWrite writer $ AcknowledgeBackup "wrong" 0 (T.replicate 64 "0"))
        cover
        expectStore "invalid_backup_coverage" (evalWrite writer $ AcknowledgeBackup "contract" 0 (T.replicate 64 "0"))
        nativeView <- evalWrite writer (IssueInstruction 100 auth native)
        solanaView <- evalWrite writer (IssueInstruction 100 auth solana)
        check (W.depositInstruction nativeView==Just address && Right (W.depositInstruction solanaView)==(Just <$> payInstruction solana))
        fixture fixtures (ProtectHolds solana)
        evalWrite writer (ExpireQuotes 301)
        lateSequence <- evalWrite writer (RecordNative auth late (allocationLabel lateClaim) "late-native-address-fixture")
        check (lateSequence>solanaSequence)
        cover
        lateView <- evalRead reader (ReadOrder auth late)
        check (W.status lateView=="ExpiredUnfunded" && W.depositInstruction lateView==Nothing)
        expectStore "scanners_not_fresh" (evalWrite writer $ IssueInstruction 301 auth late)
        fixture fixtures ReadyIntake
        expectStore "deposit_window_closed" (evalWrite writer $ IssueInstruction 100 auth late)
        historical <- evalWrite writer (IssueInstruction 301 auth native)
        check (W.status historical=="ExpiredUnfunded" && W.depositInstruction historical==Just address)
        fixture fixtures (CheckPhases native "released") >>= check
        fixture fixtures (CheckPhases solana "obligation") >>= check
        evalWrite writer (ExpireQuotes 301)
        fixture fixtures (CheckPhases solana "obligation") >>= check
      fixture fixtures LargeBalances
      huge <- evalRead reader ReadBalances
      check (M.lookup (Wrapped,Float) huge==Just (1000+2*toInteger(maxBound::Int64)))
  putStrLn "PASS: PostgreSQL role isolation, profile binding, exclusive writer, replay, conflicts, custody freshness, earned funds, cancellation, checkpoint rollback/fencing, authorized saved orders, historical terms, backup gating and review overlay"

money :: Integer -> Amount
money = either (error . T.unpack) id . amount
expectStore :: T.Text -> IO a -> IO ()
expectStore expected action = do
  result <- try action
  case result of
    Left (StoreError actual) | expected==actual -> pure ()
    Left err -> fail ("unexpected rejection: "<>show err)
    Right _ -> fail ("expected rejection: "<>T.unpack expected)

-- Fixture operations are closed and use Opaleye. They exist only in this test
-- component; no arbitrary SQL or connection callback is available to handlers.
data Fixture a where
  Initialize :: Fixture ()
  RefreshCustody :: Fixture ()
  SeedOrders :: Fixture ()
  CoverBackup :: Fixture ()
  SeedReview :: Fixture ()
  SeedIntake :: Fixture ()
  ReadyIntake :: Fixture ()
  OrderSnapshot :: Fixture [Int]
  StaleCustody :: Fixture ()
  LargeBalances :: Fixture ()
  CheckHolds :: T.Text -> Direction -> Int64 -> Fixture Bool
  ProtectHolds :: T.Text -> Fixture ()
  CheckPhases :: T.Text -> T.Text -> Fixture Bool
fixture :: PG.Connection -> Fixture a -> IO a
fixture c Initialize = PG.withTransaction c $ do
  void $ O.runInsert c O.Insert {O.iTable=S.deployment,O.iRows=[S.Deployment (O.sqlInt8 1) (O.sqlInt8 18) (O.sqlStrictText "contract") (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "test")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.custody,O.iRows=[(O.sqlInt8 1,O.sqlInt8 0,O.null,O.null,O.null)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(O.sqlStrictText "fixture",O.sqlStrictText "contract balances")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=[(Nothing,O.sqlStrictText "fixture",O.sqlStrictText "Native",O.sqlStrictText account,O.sqlInt8 delta)| (account,delta)<-[("external",-1000),("earned",1000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  fixture c RefreshCustody
fixture c RefreshCustody = do
  n <- O.runUpdate c O.Update {O.uTable=S.custody,O.uUpdateWith= \(key,revision,_,_,_)->(key,revision,O.toNullable revision,O.toNullable $ O.sqlInt8 100,O.null),O.uWhere= \(key,_,_,_,_)->key O..== O.sqlInt8 1,O.uReturning=O.rCount}
  unless (n==1) (fail "custody fixture missing")

fixture c SeedOrders = PG.withTransaction c $ do
  sequences <- O.runSelect c (fmap S.criticalSequence $ O.selectTable S.deployment)
  sequenceNumber <- case sequences of [n]->pure n; _->fail "fixture deployment missing"
  let cap=either (error . T.unpack) id (capabilityHash $ T.replicate 64 "0")
      raw value=TE.decodeUtf8 (BL.toStrict $ encode value)
      request=W.OrderRequest NativeToWrapped (money 100) "recipient" "refund" Nothing "placeholder"
      savedQuote=either (error . T.unpack) id (historicalQuote (money 100) (money 7))
  forM_ ["hidden","visible","mismatch","corrupt"] $ \identifier -> do
    let policy=W.PolicySnapshot 2 "finalized" (if identifier=="mismatch" then "wrong" else "contract")
        row=S.Order (O.sqlStrictText identifier) (O.sqlStrictText cap) (O.sqlStrictText identifier)
          (O.sqlStrictText "fixture") (O.sqlStrictText $ raw request {W.idempotencyKey=identifier})
          (O.sqlStrictText $ if identifier=="corrupt" then "{}" else raw savedQuote) (O.sqlStrictText $ raw policy)
          (O.sqlStrictText "AwaitingDeposit") (O.sqlInt8 200) (O.sqlInt8 300)
          (O.toNullable $ O.sqlStrictText $ "instruction-"<>identifier) (O.toNullable $ O.sqlInt8 sequenceNumber)
          O.null (O.sqlInt8 $ if identifier=="visible" then 1 else 0)
    void $ O.runInsert c O.Insert {O.iTable=S.orders,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c CoverBackup = void $ O.runUpdate c O.Update {O.uTable=S.deployment,
  O.uUpdateWith= \r->r {S.backupSequence=S.criticalSequence r},O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
fixture c SeedReview = PG.withTransaction c $ do
  let deposits=O.table "deposits" $ p10
        (O.requiredTableField "id",O.requiredTableField "order_id",O.requiredTableField "asset",O.requiredTableField "amount",O.requiredTableField "anchor",O.requiredTableField "first_seen",O.requiredTableField "confirmations",O.requiredTableField "eligible",O.requiredTableField "allocated",O.requiredTableField "state")
      obligations=O.table "obligations" $ p8
        (O.requiredTableField "id",O.requiredTableField "order_id",O.requiredTableField "deposit_id",O.requiredTableField "kind",O.requiredTableField "asset",O.requiredTableField "amount",O.requiredTableField "recipient",O.requiredTableField "status")
      text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=deposits,O.iRows=[(text "review-deposit",O.toNullable $ text "visible",text "Native",num 100,text "anchor",num 100,num 2,num 1,num 1,text "observed")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=obligations,O.iRows=[(text "review-obligation",text "visible",text "review-deposit",text "conversion",text "Wrapped",num 93,text "recipient",text "review")],O.iReturning=O.rCount,O.iOnConflict=Nothing}

fixture c SeedIntake = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "intake-capital",text "test inventory and operating funds")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text "intake-capital",text asset,text account,num n)| (asset,account,n)<-
      [("Native","external",-1100),("Native","float",1000),("Native","operating",100),
       ("Wrapped","external",-1000),("Wrapped","float",1000),("Sol","external",-100),("Sol","operating",100)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.operatingClock,O.iRows=[(num 1,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.scanHealth,O.iRows=[(text chain,O.toNullable $ num 100,O.null,num 100)|chain<-["Native","Solana","SolanaOperating"]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.checkpoints,O.iRows=[(text chain,text "fixture-anchor")|chain<-["Native","Solana","SolanaOperating"]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c ReadyIntake = PG.withTransaction c $ do
  void $ O.runUpdate c O.Update {O.uTable=S.deployment,O.uUpdateWith= \r->r {S.paused=O.sqlInt8 0},O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
  fixture c RefreshCustody
fixture c OrderSnapshot = do
  orders <- O.runSelect c (fmap S.orderId $ O.selectTable S.orders) :: IO [T.Text]
  holds <- O.runSelect c (fmap (\(key,_,_,_)->key) $ O.selectTable S.reservations) :: IO [T.Text]
  costs <- O.runSelect c (fmap (\(key,_,_,_)->key) $ O.selectTable S.orderCosts) :: IO [T.Text]
  allowances <- O.runSelect c (fmap (\(key,_,_,_,_)->key) $ O.selectTable S.operatingReservations) :: IO [T.Text]
  pure (map length [orders,holds,costs,allowances])

fixture c StaleCustody = void $ O.runUpdate c O.Update {O.uTable=S.custody,
  O.uUpdateWith= \(key,revision,checked,_,problem)->(key,revision,checked,O.toNullable $ O.sqlInt8 39,problem),
  O.uWhere= \(key,_,_,_,_)->key O..== O.sqlInt8 1,O.uReturning=O.rCount}
fixture c (CheckHolds identifier direction quantity) = do
  inventory <- O.runSelect c $ do
    (key,asset,n,phase) <- O.selectTable S.reservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure (asset,n,phase)
    :: IO [(T.Text,Int64,T.Text)]
  costs <- O.runSelect c $ do
    (key,kind,asset,n,phase) <- O.selectTable S.operatingReservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure (kind,asset,n,phase)
    :: IO [(T.Text,T.Text,Int64,T.Text)]
  let nativeKind=if direction==WrappedToNative then "conversion" else "refund"
      solanaKind=if direction==NativeToWrapped then "conversion" else "refund"
  pure (inventory==[(T.pack $ show $ destinationAsset direction,quantity,"quote")] &&
    sort costs==sort [(nativeKind,"Native",10,"quote"),(solanaKind,"Sol",20,"quote")])

fixture c LargeBalances = PG.withTransaction c $ do
  let text=O.sqlStrictText
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "large-balances",text "exact aggregation past Int64")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text "large-balances",text "Wrapped",text account,O.sqlInt8 n)| (account,n)<-
      [("external",negate maxBound),("float",maxBound),("external",negate maxBound),("float",maxBound)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}

fixture c (ProtectHolds identifier) = PG.withTransaction c $ do
  void $ O.runUpdate c O.Update {O.uTable=S.reservations,
    O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlStrictText "obligation"),
    O.uWhere= \(key,_,_,_)->key O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
  void $ O.runUpdate c O.Update {O.uTable=S.operatingReservations,
    O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText "obligation"),
    O.uWhere= \(key,_,_,_,_)->key O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
fixture c (CheckPhases identifier expected) = do
  inventory <- O.runSelect c $ do
    (key,_,_,phase) <- O.selectTable S.reservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure phase
    :: IO [T.Text]
  operating <- O.runSelect c $ do
    (key,_,_,_,phase) <- O.selectTable S.operatingReservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure phase
    :: IO [T.Text]
  pure (inventory==[expected] && operating==[expected,expected])
