{-# LANGUAGE GADTs, ScopedTypeVariables #-}
module Main (main) where
import Bridge.Identity (capabilityHash,payInstruction,digest)
import qualified Bridge.Wire as W
import Data.Aeson (encode,object,(.=),toJSON,Value(..),eitherDecodeStrict')
import Data.Profunctor.Product (p5,p6,p8,p9)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),CostLimits(..),PolicySnapshot(..))
import Bridge.Store
import Bridge.Signer
import Bridge.Critical
import Bridge.Order
import Bridge.Error (reject)
import Bridge.Observer (ObserverSettings(..))
import Bridge.Reconciliation (inspectCustodyWith,nativeBalance)
import Bridge.RPC (fieldValue)
import Bridge.SigningTransport (SigningEndpoint(..))
import Bridge.Operation.Internal (Request(..),SigningOperation(..),WorkerOperation(..))
import qualified Bridge.Native as N
import qualified Bridge.Solana as Solana
import qualified Bridge.SolanaHelper as H
import Network.HTTP.Client (newManager,closeManager,defaultManagerSettings,managerModifyRequest)
import qualified Bridge.Store.Schema as S
import Control.Exception
import Data.Int (Int64)
import Data.List (sort)
import Data.IORef
import GHC.Stack (HasCallStack,callStack,prettyCallStack)
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
      check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "store contract failed\n"<>prettyCallStack callStack)
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
        feeView<-evalRead reader (ReadPayment $ "fee:"<>key)
        check (savedPayment feeView==withdrawalPayment first && savedTerms feeView==policy && savedStatus feeView==PaymentReady)
        expectStore "payment_not_found" (evalRead reader $ ReadPayment "absent")
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
        cancelledView<-evalRead reader (ReadPayment $ "fee:"<>key)
        check (savedStatus cancelledView==PaymentCancelled)
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
      -- A checkpoint can use the same error type as policy refusal. Its origin,
      -- not just its type, must determine whether the writer is fenced.
      withWriter settings (store policy limits)
        (\n->when (n>ledgerSequence beforeFailure) $ throwIO $ BridgeError "checkpoint_rejected") $ \writer -> do
          expectStore "checkpoint_rejected" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "c") Native (money 100) "recipient" "test typed checkpoint failure")
          expectStore "ledger_connection_fenced" (evalWrite writer $ Pause "must stay fenced")
      rolledBackAgain<-evalRead reader (ReadWithdrawal $ T.replicate 64 "c")
      check (rolledBackAgain==Nothing)
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
      let origins=[("Native","scan-origin"),("Solana","sol-origin"),("SolanaOperating","opening-signature")]
      expectStore "custody_scan_origin_mismatch" (evalRead reader $ ReadCustodySnapshot 100 origins False)
      fixture fixtures SeedCustodyHeads
      snapshot<-evalRead reader (ReadCustodySnapshot 100 origins False)
      check (custodyTotals snapshot==M.fromList [(Native,2100),(Wrapped,1000),(Sol,100)]
        && custodySlot snapshot==42 && null(custodyPending snapshot))
      expectStore "scanners_not_fresh" (evalRead reader $ ReadCustodySnapshot 161 origins False)
      expectStore "scanners_not_fresh" (evalRead reader $ ReadCustodySnapshot 99 origins False)
      expectStore "custody_scan_origin_mismatch" (evalRead reader $ ReadCustodySnapshot 100 (drop 1 origins) False)
      known<-evalRead reader (HasCustodyEvent "Solana" (T.replicate 64 "1"))
      unknown<-evalRead reader (HasCustodyEvent "Native" (T.replicate 64 "1"))
      check (known && not unknown)
      evidence<-evalRead reader (ReadCustodyEvent "SolanaOperating" (T.replicate 64 "1"))
      check (evidence==("reference","42",object []))
      expectStore "custody_history_not_current" (evalRead reader $ ReadCustodyEvent "Native" (T.replicate 64 "1"))
      fixture fixtures (CustodyHeadReview 1)
      expectStore "chain_observations_require_review" (evalRead reader $ ReadCustodySnapshot 100 origins False)
      expectStore "custody_history_not_current" (evalRead reader $ ReadCustodyEvent "Solana" (T.replicate 64 "1"))
      fixture fixtures (CustodyHeadReview 0)
      custodyContract fixtures reader
      let newRequest=W.OrderRequest NativeToWrapped (money 100) "recipient" "refund" Nothing "new-wrap"
          create request=CreateOrder 100 auth request
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        revision<-evalRead reader ReadCustodyRevision
        let good=Just(object ["matches" .= True])
        check (revision>custodyRevision snapshot)
        expectStore "custody_ledger_changed" (evalWrite writer $ RecordCustody (custodyRevision snapshot) 100 Nothing good)
        beforeCustody<-evalRead reader ReadBalances
        expectStore "custody_ledger_changed" (evalWrite writer $ RecordCustody (revision+1) 100 Nothing good)
        expectStore "invalid_custody_report" (evalWrite writer $ RecordCustody revision 100 Nothing Nothing)
        expectStore "invalid_custody_report" (evalWrite writer $ RecordCustody revision 100 Nothing (Just $ object ["matches" .= False]))
        evalWrite writer (RecordCustody revision 100 Nothing good)
        certified<-fixture fixtures ReadCustodyCheck
        check (certified==(Just revision,Just 100,Nothing))
        evalRead reader ReadState >>= check . ledgerPaused
        fixture fixtures ReadyIntake
        evalWrite writer (RecordCustody revision 100 (Just "custody_native_history_advanced") Nothing)
        evalRead reader ReadState >>= check . not . ledgerPaused
        evalWrite writer (RecordCustody revision 100 (Just "balance_mismatch") (Just $ object ["matches" .= False]))
        evalRead reader ReadState >>= check . ledgerPaused
        evalWrite writer (RecordCustody revision 100 Nothing good)
        evalRead reader ReadState >>= check . ledgerPaused
        afterCustody<-evalRead reader ReadBalances
        afterRevision<-evalRead reader ReadCustodyRevision
        check (beforeCustody==afterCustody && afterRevision==revision)
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
        let reference=either (error . T.unpack) id (payInstruction solana)
            bare=T.drop (T.length "solana-pay:") reference
        matched<-evalRead reader (LookupReferences [bare,"unused-key"])
        missing<-evalRead reader (LookupReferences [])
        expectStore "too_many_reference_keys" (evalRead reader $ LookupReferences $ replicate 257 bare)
        check (fmap (\(identifier,_,_,ref)->(identifier,ref)) matched==Just(solana,bare) && missing==Nothing)
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
      fixture fixtures PromotionFunds
      (promoted,failedPayment) <- withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        let make name direction=do
              fixture fixtures ReadyIntake
              oid<-evalWrite writer (create newRequest {W.idempotencyKey=name,W.input=money 10,W.direction=direction,W.refund=if direction==NativeToWrapped then "refund" else ""})
              if direction==NativeToWrapped then do
                claim<-evalWrite writer (ClaimNative 100 auth oid)
                _<-evalWrite writer (RecordNative auth oid (allocationLabel claim) ("fixture-address-"<>name))
                pure ()
              else evalWrite writer (BindSolana 100 auth oid) >> pure ()
              pure oid
            seed did oid asset quantity depth eligible seen=fixture fixtures (SeedReceipt did (Just oid) asset quantity depth eligible seen)
        native<-make "promote-native" NativeToWrapped
        seed "promote-source" native Native 10 2 True 100
        candidates<-evalRead reader PromotionCandidates
        check ("promote-source" `elem` candidates)
        before<-evalRead reader ReadBalances
        first<-evalWrite writer (PromoteDeposit 100 "promote-source")
        replay<-evalWrite writer (PromoteDeposit 100 "promote-source")
        after<-evalRead reader ReadBalances
        check (first && not replay && before==after)
        fixture fixtures (CheckPromotion native "promote-source" Wrapped 9 "Ready") >>= check
        conversionView<-evalRead reader (ReadPayment $ "convert:"<>native)
        check (paymentAmount(savedPayment conversionView)==money 9 && savedStatus conversionView==PaymentReady)
        bound<-evalRead reader (ReadPaymentSource $ "convert:"<>native)
        source<-maybe (fail "missing payment source") (pure . W.sourceDeposit) bound
        cursorBeforeRefresh<-evalRead reader (ReadCheckpoint "Native")
        expectStore "source_binding_changed" (evalWrite writer $ RefreshPaymentSource source source {W.depositAmount=money 11})
        evalWrite writer (RefreshPaymentSource source source {W.depositConfirmations=3})
        expectStore "source_binding_changed" (evalWrite writer $ RefreshPaymentSource source source)
        evalRead reader ReadBalances >>= check . (==after)
        evalRead reader (ReadCheckpoint "Native") >>= check . (==cursorBeforeRefresh)
        fixture fixtures (CheckPhases native "obligation") >>= check
        candidatesAfter<-evalRead reader PromotionCandidates
        check ("promote-source" `notElem` candidatesAfter)
        -- A second exact receipt remains a protected liability, never a second conversion.
        seed "extra-source" native Native 10 2 True 100
        extra<-evalWrite writer (PromoteDeposit 100 "extra-source")
        check (not extra)
        fixture fixtures (CheckPromotion native "promote-source" Wrapped 9 "NeedsReview") >>= check
        forM_ [("wrong-amount",9,2,100,100),("shallow",10,1,100,100),
               ("late-seen",10,2,201,201),("late-confirmed",10,2,100,301)] $ \(name,n,depth,seen,now)->do
          oid<-make name NativeToWrapped
          seed name oid Native n depth True seen
          result<-evalWrite writer (PromoteDeposit now name)
          check (not result)
          view<-evalRead reader (ReadOrder auth oid)
          check (W.status view=="NeedsReview")
          fixture fixtures (CheckPhases oid "quote") >>= check
        waiting<-make "unconfirmed" NativeToWrapped
        seed "unconfirmed" waiting Native 10 0 False 100
        evalWrite writer (PromoteDeposit 100 "unconfirmed") >>= check . not
        waitView<-evalRead reader (ReadOrder auth waiting)
        check (W.status waitView=="AwaitingDeposit")
        unwrap<-make "promote-unwrap" WrappedToNative
        seed "wrapped-source" unwrap Wrapped 10 1 True 100
        evalWrite writer (PromoteDeposit 100 "wrapped-source") >>= check
        fixture fixtures (CheckPromotion unwrap "wrapped-source" Native 9 "Ready") >>= check
        fixture fixtures (CheckPhases unwrap "obligation") >>= check
        missing<-make "missing-allowance" NativeToWrapped
        seed "missing-allowance" missing Native 10 2 True 100
        fixture fixtures (OperatingPhase missing "released")
        expectStore "operating_reservation_not_provisional" (evalWrite writer $ PromoteDeposit 100 "missing-allowance")
        pending<-evalRead reader PromotionCandidates
        check ("missing-allowance" `elem` pending)
        pendingView<-evalRead reader (ReadOrder auth missing)
        check (W.status pendingView=="AwaitingDeposit")
        fixture fixtures (OperatingPhase missing "quote")
        evalWrite writer (PromoteDeposit 100 "missing-allowance") >>= check
        fixture fixtures (CheckPromotion missing "missing-allowance" Wrapped 9 "Ready") >>= check
        let historical="historical-promotion"
        fixture fixtures (HistoricalHolds historical)
        seed "historical-fee" historical Native 100 2 True 100
        evalWrite writer (PromoteDeposit 100 "historical-fee") >>= check
        fixture fixtures (CheckPromotion historical "historical-fee" Wrapped 93 "Ready") >>= check
        historicalView<-evalRead reader (ReadPayment $ "convert:"<>historical)
        check (paymentAmount(savedPayment historicalView)==money 93)
        fixture fixtures ReadyIntake
        let intent="convert:"<>historical
        (readyWork,noPreparation,noAttempts)<-evalRead reader (ReadPaymentWork intent)
        check (savedStatus readyWork==PaymentReady && noPreparation==Nothing && null noAttempts)
        prepared<-evalWrite writer (PreparePayment 100 intent (money 10) "{}")
        sequenceBefore<-evalRead reader ReadState
        replayPrepared<-evalWrite writer (PreparePayment 100 intent (money 10) "{}")
        sequenceAfter<-evalRead reader ReadState
        check (prepared==replayPrepared && ledgerSequence sequenceBefore==ledgerSequence sequenceAfter && savedStatus(preparedView prepared)==PaymentPaying)
        expectStore "preparation_conflict" (evalWrite writer $ PreparePayment 100 intent (money 9) "{}")
        expectStore "order_fee_limit_exceeded" (evalWrite writer $ PreparePayment 100 intent (money 21) "{}")
        fixture fixtures ReadyIntake
        expectStore "destination_payment_unresolved" (evalWrite writer $ PreparePayment 100 ("convert:"<>missing) (money 10) "{}")
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        expectStore "payment_not_prepared" (evalRead reader $ ReadSigningDecision 100 intent 0)
        evalWrite writer (SaveDraft intent 0 "{\"draft\":1}")
        savedDraft<-evalRead reader (ReadPreparation intent)
        (activeWork,activePreparation,unsignedHistory)<-evalRead reader (ReadPaymentWork intent)
        check (activeWork==preparedView savedDraft && activePreparation==Just savedDraft && null unsignedHistory)
        draftSequence<-evalRead reader ReadState
        evalWrite writer (SaveDraft intent 0 "{\"draft\":1}")
        replaySequence<-evalRead reader ReadState
        check (preparedDraft savedDraft==Just "{\"draft\":1}" && ledgerSequence draftSequence==ledgerSequence replaySequence)
        expectStore "preparation_draft_conflict" (evalWrite writer $ SaveDraft intent 0 "{\"draft\":2}")
        expectStore "preparation_generation_changed" (evalWrite writer $ SaveDraft intent 1 "{}")
        expectStore "signing_backup_required" (evalRead reader $ ReadSigningDecision 100 intent 0)
        -- Exercise the real signer evaluator's refusal path; the manager forbids
        -- network access, so no identity RPC or signing can hide behind the test.
        let publicKey=T.replicate 32 "1"
            native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused/credential" "ecx-bridge-test"
              16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
            solana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing publicKey publicKey publicKey
            signing=SignerSettings native solana (H.SolanaPolicy "contract" "contract" publicKey publicKey publicKey (money 10) (money 10))
              "/unused/sdk" "/unused/key"
        bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> fail "unauthorized signer reached network"}) closeManager $ \manager -> do
          withSigner manager reader signing $ \interpret -> do
            expectStore "signer_profile_mismatch" (interpret $ Request $ SignPrepared "other" intent 0)
            expectStore "invalid_signing_decision" (interpret $ Request $ SignPrepared "contract" intent 8)
            expectStore "signing_backup_required" (interpret $ Request $ SignPrepared "contract" intent 0)
          withPaymentWorker manager (ObserverSettings native solana 2 "sol-origin" "opening-signature") (signingPolicy signing) (SigningEndpoint 9443 "/unused/auth") reader writer $ \interpret -> do
            expectStore "invalid_saved_payment" (interpret $ Request $ SignPreparedPayment intent)
            expectStore "intake_paused" (interpret $ Request $ PrepareOutgoing intent)
          pausedAfterRefusal<-evalRead reader ReadState
          check (ledgerPaused pausedAfterRefusal)
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        decision<-evalRead reader (ReadSigningDecision 100 intent 0)
        check (decision==savedDraft)
        expectStore "preparation_generation_changed" (evalRead reader $ ReadSigningDecision 100 intent 1)
        let signed=SignedAttempt "fixture-signed-solana" "exact-fixture-bytes" "{\"signed\":true}" Nothing
        expectStore "preparation_changed" (evalWrite writer $ RecordAttempt decision {preparedPolicy="{\"changed\":true}"} signed)
        expectStore "attempt_common_input_mismatch" (evalWrite writer $ RecordAttempt decision signed {commonInput=Just "unexpected:0"})
        fixture fixtures (SourceEligibility "historical-fee" False)
        fixture fixtures ReadyIntake
        expectStore "source_not_eligible" (evalRead reader $ ReadSigningDecision 100 intent 0)
        expectStore "source_not_eligible" (evalWrite writer $ RecordAttempt decision signed)
        fixture fixtures (SourceEligibility "historical-fee" True)
        beforeSignature<-evalRead reader ReadBalances
        recorded<-evalWrite writer (RecordAttempt decision signed)
        firstSequence<-evalRead reader ReadState
        repeated<-evalWrite writer (RecordAttempt decision signed)
        secondSequence<-evalRead reader ReadState
        afterSignature<-evalRead reader ReadBalances
        check (recorded==repeated && recordedSigned recorded==signed && recordedState recorded=="signed" &&
          recordedSequence recorded==Nothing && ledgerSequence firstSequence==ledgerSequence secondSequence && beforeSignature==afterSignature)
        expectStore "attempt_identity_conflict" (evalWrite writer $ RecordAttempt decision signed {signedBytes="different"})
        expectStore "attempt_already_recorded" (evalWrite writer $ RecordAttempt decision signed {signedId="another-signature"})
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        expectStore "attempt_already_recorded" (evalRead reader $ ReadSigningDecision 100 intent 0)
        fixture fixtures (ImmutableAttempt "fixture-signed-solana") >>= check
        let withdrawalKey=T.replicate 64 "d"
        evalWrite writer (Pause "reserve earned")
        fixture fixtures RefreshCustody
        _<-evalWrite writer (ReserveFees 100 withdrawalKey Native (money 10) "owner-address" "test earned payment")
        fixture fixtures ReadyIntake
        earnedPrepared<-evalWrite writer (PreparePayment 100 ("fee:"<>withdrawalKey) (money 5) "{}")
        check (paymentAsset(savedPayment $ preparedView earnedPrepared)==Native && savedStatus(preparedView earnedPrepared)==PaymentPaying)
        evalRead reader (ReadPaymentSource $ "fee:"<>withdrawalKey) >>= check . (==Nothing)
        expectStore "fee_withdrawal_payment_exists" (evalWrite writer $ CancelFees withdrawalKey "must retain")
        fixture fixtures (CheckFundingBinding ("fee:"<>withdrawalKey) withdrawalKey) >>= check
        evalWrite writer (SaveDraft ("fee:"<>withdrawalKey) 0 "{\"nativeDraft\":true}")
        earnedDraft<-evalRead reader (ReadPreparation $ "fee:"<>withdrawalKey)
        let nativeSigned=SignedAttempt (T.replicate 64 "f") "native-fixture-bytes" "{\"nativeSigned\":true}" (Just "fixture-prevout:0")
        nativeRecorded<-evalWrite writer (RecordAttempt earnedDraft nativeSigned)
        check (recordedChain nativeRecorded=="Native" && recordedSigned nativeRecorded==nativeSigned && recordedState nativeRecorded=="signed")
        let nativeTx=signedId nativeSigned; nativeCosts=W.PaymentCosts (money 3) (money 0)
        expectStore "settlement_attempt_changed" (evalWrite writer $ SettlePayment nativeRecorded nativeCosts "offline-finalized-proof")
        fixture fixtures ReadyIntake
        expectStore "broadcast_intent_required" (evalWrite writer $ AuthorizeSend 100 nativeTx)
        broadcastSequence<-evalWrite writer (MarkBroadcast 100 nativeTx)
        fixture fixtures ReadyIntake
        repeatedSequence<-evalWrite writer (MarkBroadcast 100 nativeTx)
        check (broadcastSequence==repeatedSequence)
        expectStore "backup_pending" (evalWrite writer $ AuthorizeSend 100 nativeTx)
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        authorized<-evalWrite writer (AuthorizeSend 100 nativeTx)
        check (recordedSigned authorized==nativeSigned && recordedSequence authorized==Just broadcastSequence)
        beforeSettlement<-evalRead reader ReadBalances
        expectStore "settlement_fee_or_evidence_invalid" (evalWrite writer $ SettlePayment authorized (W.PaymentCosts (money 3) (money 1)) "offline-finalized-proof")
        expectStore "settlement_attempt_changed" (evalWrite writer $ SettlePayment authorized {recordedSigned=nativeSigned {signedBytes="changed"}} nativeCosts "offline-finalized-proof")
        evalWrite writer (SettlePayment authorized nativeCosts "offline-finalized-proof")
        afterSettlement<-evalRead reader ReadBalances
        let change account=M.findWithDefault 0 (Native,account) afterSettlement-M.findWithDefault 0 (Native,account) beforeSettlement
        check (change FeePending==(-10) && change Operating==(-3) && change External==13 && change Principal==0 && change Float==0 && change Earned==0)
        evalWrite writer (SettlePayment authorized nativeCosts "offline-finalized-proof")
        evalRead reader ReadBalances >>= check . (==afterSettlement)
        expectStore "settlement_evidence_conflict" (evalWrite writer $ SettlePayment authorized nativeCosts "changed-proof")
        completed<-evalRead reader (ReadPayment $ "fee:"<>withdrawalKey)
        check (savedStatus completed==PaymentPaid)
        bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> fail "terminal payment must not call RPC"}) closeManager $ \manager ->
          withPaymentWorker manager (ObserverSettings native solana 2 "sol-origin" "opening-signature") (signingPolicy signing) (SigningEndpoint 9443 "/unused/auth") reader writer $ \interpret ->
            interpret (Request $ ReconcilePayment nativeTx)
        evalRead reader ReadBalances >>= check . (==afterSettlement)
        fixture fixtures (SeedReceipt "unknown-source" Nothing Native 10 2 True 100)
        evalWrite writer (PromoteDeposit 100 "unknown-source") >>= check . not
        expectStore "deposit_not_found" (evalWrite writer $ PromoteDeposit 100 "missing")
        expectStore "invalid_promotion_time" (evalWrite writer $ PromoteDeposit (-1) "promote-source")
        pure ("promote-source",missing)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        evalWrite writer (PromoteDeposit 100 promoted) >>= check . not
        (_,restartedPreparation,restartedHistory)<-evalRead reader (ReadPaymentWork "convert:historical-promotion")
        check (restartedPreparation/=Nothing && restartedHistory==["fixture-signed-solana"])
        persisted<-evalRead reader (ReadAttempt "fixture-signed-solana")
        check (signedBytes(recordedSigned persisted)=="exact-fixture-bytes" && recordedState persisted=="signed")
        fixture fixtures ReadyIntake
        fixture fixtures (SourceEligibility "historical-fee" False)
        fixture fixtures ReadyIntake
        expectStore "source_not_eligible" (evalWrite writer $ MarkBroadcast 100 "fixture-signed-solana")
        fixture fixtures (SourceEligibility "historical-fee" True)
        fixture fixtures ReadyIntake
        _<-evalWrite writer (MarkBroadcast 100 "fixture-signed-solana")
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        authorized<-evalWrite writer (AuthorizeSend 100 "fixture-signed-solana")
        beforeSettlement<-evalRead reader ReadBalances
        evalWrite writer (SettlePayment authorized (W.PaymentCosts (money 3) (money 2)) "offline-conversion-proof")
        afterSettlement<-evalRead reader ReadBalances
        let change asset account=M.findWithDefault 0 (asset,account) afterSettlement-M.findWithDefault 0 (asset,account) beforeSettlement
        check (change Native Principal==(-100) && change Native Float==93 && change Native Earned==7
          && change Wrapped Float==(-93) && change Wrapped External==93 && change Sol Operating==(-5) && change Sol External==5)
        completed<-evalRead reader (ReadPayment "convert:historical-promotion")
        check (savedStatus completed==PaymentPaid)
        fixture fixtures ReadyIntake
        _<-evalWrite writer (PreparePayment 100 ("convert:"<>failedPayment) (money 10) "{}")
        evalWrite writer (SaveDraft ("convert:"<>failedPayment) 0 "{}")
        failedDraft<-evalRead reader (ReadPreparation ("convert:"<>failedPayment))
        _<-evalWrite writer (RecordAttempt failedDraft $ SignedAttempt "fixture-failed-solana" "failure-fixture-bytes" "{}" Nothing)
        fixture fixtures ReadyIntake
        _<-evalWrite writer (MarkBroadcast 100 "fixture-failed-solana")
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        failedAttempt<-evalWrite writer (AuthorizeSend 100 "fixture-failed-solana")
        beforeFailure<-evalRead reader ReadBalances
        evalWrite writer (FailSolana failedAttempt (money 2) "offline-failure-proof")
        afterFailure<-evalRead reader ReadBalances
        let expected=M.insertWith (+) (Sol,External) 2 $ M.insertWith (+) (Sol,Operating) (-2) beforeFailure
        check (afterFailure==expected)
        evalWrite writer (FailSolana failedAttempt (money 2) "offline-failure-proof")
        evalRead reader ReadBalances >>= check . (==afterFailure)
        expectStore "failure_evidence_conflict" (evalWrite writer $ FailSolana failedAttempt (money 3) "offline-failure-proof")
        failedView<-evalRead reader (ReadPayment ("convert:"<>failedPayment))
        check (savedStatus failedView==PaymentReview)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        let tx=T.replicate 64 "d"; did="native:"<>tx<>":0"; hash=T.replicate 64 "e"
            proof=object ["observationHash" .= hash]
            record decision=do snapshot<-evalRead reader (ReadSource did); evalWrite writer (RecordSourceCheck snapshot decision)
        fixture fixtures (SeedReceipt did Nothing Native 50 0 False 100)
        fixture fixtures (SeedSourceEvidence tx hash)
        (savedHash,_)<-evalRead reader (ReadSourceEvidence tx)
        check (savedHash==hash)
        before<-evalRead reader ReadBalances
        initial<-evalRead reader ReadState
        record (W.SourcePending proof)
        ordinary<-evalRead reader ReadState
        check (ledgerSequence ordinary==ledgerSequence initial)
        snapshot<-evalRead reader (ReadSource did)
        expectStore "source_recovery_changed" (evalWrite writer $ RecordSourceCheck snapshot {W.depositAmount=money 49} $ W.SourceMissing proof)
        expectStore "source_recovery_scan_not_current" (record $ W.SourceMissing $ object ["observationHash" .= ("wrong"::T.Text)])
        fixture fixtures ReadyIntake
        record (W.SourceMissing proof)
        missing<-evalRead reader ReadBalances
        missingState<-evalRead reader ReadState
        check (M.findWithDefault 0 (Native,SourceDeficit) missing == M.findWithDefault 0 (Native,SourceDeficit) before-50 && ledgerPaused missingState)
        record (W.SourceMissing proof)
        replay<-evalRead reader ReadState
        check (ledgerSequence replay==ledgerSequence missingState)
        record (W.SourceUnavailable $ object ["reason" .= ("offline"::T.Text)])
        unavailable<-evalRead reader ReadBalances
        check (missing==unavailable)
        unavailableState<-evalRead reader ReadState
        record (W.SourceUnavailable $ object ["reason" .= ("offline"::T.Text)])
        repeated<-evalRead reader ReadState
        check (ledgerSequence repeated==ledgerSequence unavailableState)
        expectStore "invalid_source_recovery_evidence" (record $ W.SourceUnavailable Null)
        expectStore "invalid_source_recovery_evidence" (record $ W.SourceUnavailable $ object ["reason" .= T.replicate 17000 "a"])
        expectStore "source_recovery_scan_not_current" (record $ W.SourceRestored proof)
        fixture fixtures (SourceEligibility did True)
        expectStore "source_recovery_changed" (evalWrite writer $ RecordSourceCheck snapshot $ W.SourceRestored proof)
        record (W.SourceRestored proof)
        restored<-evalRead reader ReadBalances
        check (M.filter (/=0) before==M.filter (/=0) restored)
        restoredState<-evalRead reader ReadState
        record (W.SourceRestored proof)
        restoredReplay<-evalRead reader ReadState
        check (ledgerPaused restoredReplay && ledgerSequence restoredReplay==ledgerSequence restoredState)
        -- A covered loss returns the exact saved capital split only once.
        fixture fixtures (SourceEligibility did False)
        record (W.SourceMissing proof)
        fixture fixtures (CoverSource did)
        fixture fixtures (SourceEligibility did True)
        record (W.SourceRestored proof)
        returned<-evalRead reader ReadBalances
        check (M.filter (/=0) before==M.filter (/=0) returned)
        record (W.SourceRestored proof)
        returnedAgain<-evalRead reader ReadBalances
        check (returnedAgain==returned)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        fixture fixtures ReadyIntake
        oid<-evalWrite writer (create newRequest {W.idempotencyKey="scanned-order",W.input=money 10})
        claim<-evalWrite writer (ClaimNative 100 auth oid)
        _<-evalWrite writer (RecordNative auth oid (allocationLabel claim) "scan-address-fixture")
        binding<-evalRead reader (LookupInstruction "scan-address-fixture")
        absentBinding<-evalRead reader (LookupInstruction "unused-address")
        historicalDepth<-evalRead reader (MaximumNativeDepth 1)
        check (fmap (\(boundOrder,_,saved)->(boundOrder,W.nativeDepth saved)) binding==Just(oid,2) && absentBinding==Nothing && historicalDepth>=2)
        let tx=T.replicate 64 "b"; did="native:"<>tx<>":0"
            receipt=W.Deposit did (Just oid) Native (money 10) "block-1" 2 True 100
            event=W.ChainEvent tx "incoming" "block-1" (object ["receipt" .= did])
            batch previous next deposits events=W.ScanBatch "Native" "scan-origin" previous next 100 deposits events
            commit b=evalWrite writer (CommitScan b)
        previous<-evalRead reader (ReadCheckpoint "Native")
        before<-evalRead reader ReadBalances
        commit (batch previous "scan-1" [receipt] [event])
        observed<-evalRead reader ReadBalances
        check (M.findWithDefault 0 (Native,Principal) observed==M.findWithDefault 0 (Native,Principal) before+10)
        commit (batch (Just "scan-1") "scan-1" [receipt {W.depositSeenAt=999}] [event])
        replay<-evalRead reader ReadBalances
        saved<-evalRead reader (ReadSource did)
        check (observed==replay && W.depositSeenAt saved==100)
        expectStore "stale_scan_cursor" (commit $ batch previous "stale" [] [])
        expectStore "scan_origin_mismatch" (commit $ (batch (Just "scan-1") "wrong-origin" [] []) {W.scanOrigin="other"})
        expectStore "conflicting_deposit_evidence" (commit $ batch (Just "scan-1") "conflict" [receipt {W.depositAmount=money 11}] [])
        let provisional=receipt {W.depositId="native:rollback:0"}
        expectStore "invalid_observation_kind" (commit $ batch (Just "scan-1") "rollback" [provisional] [event {W.chainEventKind="invalid"}])
        expectStore "source_deposit_missing" (evalRead reader $ ReadSource "native:rollback:0")
        afterFailure<-evalRead reader ReadBalances
        cursor<-evalRead reader (ReadCheckpoint "Native")
        check (afterFailure==observed && cursor==Just "scan-1")
        evalWrite writer (PromoteDeposit 100 did) >>= check
        workHash<-evalRead reader (ReadSourceWorkHash $ "convert:"<>oid)
        let obligation=("convert:"<>oid,oid,did,"conversion"::T.Text,"Wrapped"::T.Text,9::Int64,"recipient"::T.Text)
            expectedHash=digest $ BL.toStrict $ encode (toJSON [obligation]:replicate 5 (toJSON ([]::[Value])))
        check (workHash==expectedHash)
        commit (batch (Just "scan-1") "scan-2" [receipt {W.depositEligible=False,W.depositConfirmations=0,W.depositAnchor="unconfirmed"}] [event {W.chainEventAnchor="unconfirmed"}])
        fixture fixtures (CheckSuspended oid did workHash) >>= check
        lossState<-evalRead reader ReadState
        check (ledgerPaused lossState && ledgerReason lossState=="source_reorg_review")
        unchanged<-evalRead reader ReadBalances
        check (unchanged==observed)
        evalWrite writer (ScanFailed "Native" 101 "provider_down")
        health<-fixture fixtures (ReadScanHealth "Native")
        cursorAfterFailure<-evalRead reader (ReadCheckpoint "Native")
        check (health==(Just 100,Just "provider_down",101) && cursorAfterFailure==Just "scan-2")
        evalWrite writer (ScanFailed "Native" 102 "provider_down")
        commit (batch (Just "scan-2") "scan-3" [] [])
        recoveredHealth<-fixture fixtures (ReadScanHealth "Native")
        check (recoveredHealth==(Just 100,Nothing,100))
        -- A signature alone cannot explain an outflow; a recorded send intent can.
        fixture fixtures (SeedScanAttempts oid)
        hashWithAttempts<-evalRead reader (ReadSourceWorkHash $ "refund:"<>oid)
        refundView<-evalRead reader (ReadPayment $ "refund:"<>oid)
        check (paymentAmount(savedPayment refundView)==money 10 && paymentAsset(savedPayment refundView)==Native)
        let attemptRows=[("saved-intent"::T.Text,"broadcast_intent"::T.Text,0::Int64,Just(1::Int64),Nothing::Maybe T.Text),
              ("saved-signed","signed",0,Nothing,Nothing)]
            expectedWithAttempts=digest $ BL.toStrict $ encode
              [toJSON [("refund:"<>oid,oid,did,"refund"::T.Text,"Native"::T.Text,10::Int64,"refund"::T.Text)],toJSON [("Native"::T.Text,False,Nothing::Maybe T.Text)],
               toJSON [(0::Int64,"{}"::T.Text,Just("{}"::T.Text),Nothing::Maybe T.Text,False)],
               toJSON attemptRows,toJSON ([]::[Value]),toJSON ([]::[Value])]
        check (hashWithAttempts/=workHash && hashWithAttempts==expectedWithAttempts)
        fixture fixtures ReadyIntake
        commit (batch (Just "scan-3") "scan-4" [] [W.ChainEvent "saved-signed" "outgoing" "anchor" (object [])])
        signedReview<-fixture fixtures (ReadEventReview "Native" "saved-signed")
        check (signedReview==1)
        fixture fixtures ReadyIntake
        commit (batch (Just "scan-4") "scan-5" [] [W.ChainEvent "saved-intent" "outgoing" "anchor" (object [])])
        knownReview<-fixture fixtures (ReadEventReview "Native" "saved-intent")
        knownState<-evalRead reader ReadState
        check (knownReview==0 && not(ledgerPaused knownState))
        let spend=W.ChainEvent "operator-spend" "outgoing" "anchor" (object ["walletNetUnits" .= ("-25"::T.Text),"feeUnits" .= money 1])
        commit (batch (Just "scan-5") "scan-6" [] [spend])
        fixture fixtures (ApproveScanSpend spend)
        fixture fixtures ReadyIntake
        commit (batch (Just "scan-6") "scan-7" [] [spend])
        approved<-fixture fixtures (ReadEventReview "Native" "operator-spend")
        approvedState<-evalRead reader ReadState
        check (approved==0 && not(ledgerPaused approvedState))
        commit (batch (Just "scan-7") "scan-8" [] [spend {W.chainEventAnchor="changed"}])
        disputed<-fixture fixtures (ReadEventReview "Native" "operator-spend")
        check (disputed==1)
        commit (batch (Just "scan-8") "scan-9" [] [spend])
        sticky<-fixture fixtures (ReadEventReview "Native" "operator-spend")
        check (sticky==1)
        wrapped<-evalRead reader (ReadSource "wrapped-source")
        solCursor<-evalRead reader (ReadCheckpoint "Solana")
        let solBatch prior next deposit=W.ScanBatch "Solana" "sol-origin" prior next 110 [deposit] []
        expectStore "scan_asset_mismatch" (commit $ solBatch solCursor "wrong-asset" receipt)
        let waiting=W.ChainEvent "waiting-proof" "awaiting_verifier" "slot" (object [])
        commit ((solBatch solCursor "sol-1" wrapped {W.depositEligible=False}) {W.scanEvents=[waiting]})
        pending<-evalRead reader PendingVerification
        check (pending==["waiting-proof"])
        fixture fixtures (LatestSourceState "wrapped-source") >>= check . (=="unavailable")
        commit ((solBatch (Just "sol-1") "sol-2" wrapped) {W.scanEvents=[waiting {W.chainEventKind="incoming"}]})
        cleared<-evalRead reader PendingVerification
        check (null cleared)
        fixture fixtures (LatestSourceState "wrapped-source") >>= check . (=="restored")
        case W.depositOrder wrapped of
          Just order->do view<-evalRead reader (ReadOrder auth order); check (W.status view=="NeedsReview")
          Nothing->fail "bound receipt required"
        fixture fixtures ResetOperatingScan
        beforeSol<-evalRead reader ReadBalances
        let funding=W.Deposit "sol-operating:fixture" Nothing Sol (money 3) "slot" 1 True 110
        commit (W.ScanBatch "SolanaOperating" "opening-signature" Nothing "opening-signature" 110 [funding] [])
        afterSol<-evalRead reader ReadBalances
        check (M.findWithDefault 0 (Sol,Unallocated) afterSol==M.findWithDefault 0 (Sol,Unallocated) beforeSol+3)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer->do
        fixture fixtures OrderWorkflowFunds
        orderWorkflowContract fixtures reader writer
      beforeLarge<-evalRead reader ReadBalances
      fixture fixtures LargeBalances
      huge <- evalRead reader ReadBalances
      check (M.lookup (Wrapped,Float) huge==Just (M.findWithDefault 0 (Wrapped,Float) beforeLarge+2*toInteger(maxBound::Int64)))
  putStrLn "PASS: PostgreSQL role isolation, profile binding, exclusive writer, replay, conflicts, custody freshness, earned funds, cancellation, checkpoint rollback/fencing, authorized saved orders, historical terms, backup gating and review overlay"

money :: Integer -> Amount
money = either (error . T.unpack) id . amount
expectStore :: HasCallStack => T.Text -> IO a -> IO ()
expectStore expected action = do
  result <- try action
  case result of
    Left (BridgeError actual) | expected==actual -> pure ()
    Left err -> fail ("expected "<>T.unpack expected<>", unexpected rejection: "<>show err<>"\n"<>prettyCallStack callStack)
    Right _ -> fail ("expected rejection: "<>T.unpack expected<>"\n"<>prettyCallStack callStack)

-- Fixture operations are closed and use Opaleye. They exist only in this test
-- component; no arbitrary SQL or connection callback is available to handlers.
data Fixture a where
  OrderWorkflowFunds :: Fixture ()
  CustodyHeadReview :: Int64 -> Fixture ()
  SeedCustodyHeads :: Fixture ()
  ReadCustodyCheck :: Fixture (Maybe Int64,Maybe Int64,Maybe T.Text)
  ImmutableAttempt :: T.Text -> Fixture Bool
  CheckFundingBinding :: T.Text -> T.Text -> Fixture Bool
  ResetOperatingScan :: Fixture ()
  LatestSourceState :: T.Text -> Fixture T.Text
  ReadScanHealth :: T.Text -> Fixture (Maybe Int64,Maybe T.Text,Int64)
  ReadEventReview :: T.Text -> T.Text -> Fixture Int64
  CheckSuspended :: T.Text -> T.Text -> T.Text -> Fixture Bool
  SeedScanAttempts :: T.Text -> Fixture ()
  ApproveScanSpend :: W.ChainEvent -> Fixture ()
  SeedSourceEvidence :: T.Text -> T.Text -> Fixture ()
  SourceEligibility :: T.Text -> Bool -> Fixture ()
  CoverSource :: T.Text -> Fixture ()
  OperatingPhase :: T.Text -> T.Text -> Fixture ()
  HistoricalHolds :: T.Text -> Fixture ()
  PromotionFunds :: Fixture ()
  SeedReceipt :: T.Text -> Maybe T.Text -> Asset -> Int64 -> Int64 -> Bool -> Int64 -> Fixture ()
  CheckPromotion :: T.Text -> T.Text -> Asset -> Int64 -> T.Text -> Fixture Bool
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
  void $ O.runInsert c O.Insert {O.iTable=S.deployment,O.iRows=[S.Deployment (O.sqlInt8 1) (O.sqlInt8 19) (O.sqlStrictText "contract") (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "test")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
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
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.deposits,O.iRows=[S.Deposit (text "review-deposit") (O.toNullable $ text "visible") (text "Native") (num 100) (text "anchor") (num 100) (num 2) (num 1) (num 1) (text "observed")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.obligations,O.iRows=[S.Obligation (text "review-obligation") (text "visible") (text "review-deposit") (text "conversion") (text "Wrapped") (num 93) (text "recipient") (text "review")],O.iReturning=O.rCount,O.iOnConflict=Nothing}

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

fixture c PromotionFunds = PG.withTransaction c $ do
  let text=O.sqlStrictText
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "promotion-funds",text "test operating budget")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text "promotion-funds",text asset,text account,O.sqlInt8 n)|asset<-["Native","Sol"],(account,n)<-[("external",-10000),("operating",10000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (SeedReceipt did oid asset quantity depth eligible seen) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      account=maybe "unallocated" (const "principal") oid
  void $ O.runInsert c O.Insert {O.iTable=S.deposits,
    O.iRows=[S.Deposit (text did) (maybe O.null (O.toNullable . text) oid) (text $ T.pack $ show asset)
      (num quantity) (text "fixture-anchor") (num seen) (num depth) (num $ if eligible then 1 else 0) (num 0) (text "observed")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text $ "deposit:"<>did,text "fixture observed value")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text $ "deposit:"<>did,text $ T.pack $ show asset,text target,num n)| (target,n)<-[(account,quantity),("external",negate quantity)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (CheckPromotion oid did asset quantity status) = do
  obligations<-O.runSelect c $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationOrder row O..== O.sqlStrictText oid)
    pure row
    :: IO [S.Obligation]
  deposits<-O.runSelect c $ do
    row<-O.selectTable S.deposits
    O.where_ (S.depositId row O..== O.sqlStrictText did)
    pure (S.depositAllocated row)
    :: IO [Int64]
  orders<-O.runSelect c $ do
    row<-O.selectTable S.orders
    O.where_ (S.orderId row O..== O.sqlStrictText oid)
    pure (S.status row)
    :: IO [T.Text]
  pure (obligations==[S.Obligation ("convert:"<>oid) oid did "conversion" (T.pack $ show asset) quantity "recipient" "ready"] && deposits==[1] && orders==[status])

fixture c (OperatingPhase oid phase) = void $ O.runUpdate c O.Update {O.uTable=S.operatingReservations,
  O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText phase),
  O.uWhere= \(key,_,_,_,_)->key O..== O.sqlStrictText oid,O.uReturning=O.rCount}
fixture c (HistoricalHolds oid) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      raw value=TE.decodeUtf8 (BL.toStrict $ encode value)
      cap=either (error . T.unpack) id (capabilityHash $ T.replicate 64 "0")
      request=W.OrderRequest NativeToWrapped (money 100) "recipient" "refund" Nothing oid
      saved=either (error . T.unpack) id (historicalQuote (money 100) (money 7))
  void $ O.runInsert c O.Insert {O.iTable=S.orders,
    O.iRows=[S.Order (text oid) (text cap) (text oid) (text "fixture") (text $ raw request) (text $ raw saved)
      (text $ raw $ W.PolicySnapshot 2 "finalized" "contract") (text "AwaitingDeposit") (num 200) (num 300)
      (O.toNullable $ text "historical-native-fixture") (O.toNullable $ num 0) O.null (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.reservations,O.iRows=[(text oid,text "Wrapped",num 93,text "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.orderCosts,O.iRows=[(text oid,num 10,num 10,num 10)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.operatingReservations,
    O.iRows=[(text oid,text kind,text asset,num n,text "quote") | (kind,asset,n)<-[("conversion","Sol",20),("refund","Native",10)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}

fixture c (SeedSourceEvidence tx hash) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      heads=O.table "chain_events" $ p8 (O.requiredTableField "chain",O.requiredTableField "event_id",O.requiredTableField "kind",O.requiredTableField "anchor",O.requiredTableField "evidence_hash",O.requiredTableField "first_seen",O.requiredTableField "last_seen",O.requiredTableField "needs_review")
  void $ O.runInsert c O.Insert {O.iTable=S.observationEvidence,O.iRows=[(text hash,text "Native",text tx,text "{}")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=heads,O.iRows=[(text "Native",text tx,text "unmatched_incoming",text "fixture-anchor",text hash,num 100,num 100,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (SourceEligibility did eligible) = void $ O.runUpdate c O.Update {O.uTable=S.deposits,
  O.uUpdateWith= \r->r {S.depositEligible=O.sqlInt8 $ if eligible then 1 else 0},
  O.uWhere= \r->S.depositId r O..== O.sqlStrictText did,O.uReturning=O.rCount}
fixture c (CoverSource did) = PG.withTransaction c $ do
  recovery<-O.runSelect c $ O.limit 1 $ O.orderBy (O.desc id) $ do
    (_,deposit,_,_,_,n)<-O.selectTable S.sourceChecks
    O.where_ (deposit O..== O.sqlStrictText did)
    pure n
    :: IO [Int64]
  sequences<-O.runUpdate c O.Update {O.uTable=S.deployment,
    O.uUpdateWith= \r->r {S.criticalSequence=S.criticalSequence r+1},O.uWhere=const(O.sqlBool True),O.uReturning=O.rReturning S.criticalSequence}
  (loss,n)<-case (recovery,sequences) of ([r],[s])->pure(r,s); _->fail "missing cover fixture state"
  let text=O.sqlStrictText; num=O.sqlInt8
      covers=O.table "source_loss_covers" $ p8 (O.requiredTableField "critical_sequence",O.requiredTableField "deposit_id",O.requiredTableField "recovery_sequence",O.requiredTableField "amount",O.requiredTableField "float_amount",O.requiredTableField "earned_amount",O.requiredTableField "reason",O.requiredTableField "proof_json")
      event="cover-fixture:"<>T.pack(show n)
  void $ O.runInsert c O.Insert {O.iTable=covers,O.iRows=[(num n,text did,num loss,num 50,num 30,num 20,text "test cover",text "{}")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text event,text "test loss cover")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text event,text "Native",text account,num delta) | (account,delta)<-[("float",-30),("earned",-20),("source_deficit",50)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}

fixture c (ReadScanHealth chain) = do
  rows<-O.runSelect c $ do
    (key,success,failure,at)<-O.selectTable S.scanHealth
    O.where_ (key O..== O.sqlStrictText chain)
    pure (success,failure,at)
  case rows of [row]->pure row; _->fail "missing scan health"
fixture c (ReadEventReview chain identifier) = do
  rows<-O.runSelect c $ do
    row<-O.selectTable S.chainEvents
    O.where_ (S.eventChain row O..== O.sqlStrictText chain O..&& S.eventId row O..== O.sqlStrictText identifier)
    pure (S.eventReview row)
  case rows of [row]->pure row; _->fail "missing chain event"
fixture c (CheckSuspended oid did hash) = do
  obligations<-O.runSelect c $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationOrder row O..== O.sqlStrictText oid)
    pure (S.obligationStatus row)
    :: IO [T.Text]
  proofs<-O.runSelect c $ do
    (_,key,state,_,proof,_)<-O.selectTable S.sourceChecks
    O.where_ (key O..== O.sqlStrictText did)
    pure (state,proof)
    :: IO [(T.Text,T.Text)]
  let expected=object ["reason" .= ("source_eligibility_lost"::T.Text),"previousAnchor" .= ("block-1"::T.Text),
        "anchor" .= ("unconfirmed"::T.Text),"reviewedObligations" .= [object ["intent" .= ("convert:"<>oid),"previousStatus" .= ("ready"::T.Text),"workHash" .= hash]]]
  pure (obligations==["review"] && case proofs of [("unavailable",raw)]->eitherDecodeStrict' (TE.encodeUtf8 raw)==Right expected; _->False)
fixture c (SeedScanAttempts oid) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8; intent="refund:"<>oid
      intents=O.table "intents" $ p5 (O.requiredTableField "id",O.requiredTableField "obligation_id",O.requiredTableField "chain",O.requiredTableField "common_input",O.requiredTableField "resolved")
      preparations=O.table "preparations" $ p6 (O.requiredTableField "intent_id",O.requiredTableField "generation",O.requiredTableField "policy_json",O.requiredTableField "draft_json",O.requiredTableField "retired_txid",O.requiredTableField "cancelled")
      attempts=O.table "attempts" $ p9 (O.requiredTableField "txid",O.requiredTableField "intent_id",O.requiredTableField "signed_bytes",O.requiredTableField "policy_json",O.requiredTableField "fee_limit",O.requiredTableField "state",O.requiredTableField "critical_sequence",O.requiredTableField "observation_json",O.requiredTableField "preparation_generation")
  sources<-O.runSelect c $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationId row O..== text ("convert:"<>oid))
    pure (S.obligationDeposit row)
  source<-case sources of [did]->pure did; _->fail "missing scan source"
  void $ O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text "cancelled"},
    O.uWhere= \r->S.obligationId r O..== text ("convert:"<>oid),O.uReturning=O.rCount}
  void $ O.runInsert c O.Insert {O.iTable=S.obligations,
    O.iRows=[S.Obligation (text intent) (text oid) (text source) (text "refund") (text "Native") (num 10) (text "refund") (text "review")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=intents,O.iRows=[(text intent,text intent,text "Native",O.null,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=preparations,O.iRows=[(text intent,num 0,text "{}",O.toNullable $ text "{}",O.null,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=attempts,
    O.iRows=[(text tx,text intent,text "fixture-bytes",text "{}",num 1,text state,sequenceNo,O.null,num 0) |
      (tx,state,sequenceNo)<-[("saved-signed","signed",O.null),("saved-intent","broadcast_intent",O.toNullable $ num 1)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (ApproveScanSpend event) = PG.withTransaction c $ do
  let text=O.sqlStrictText
      spends=O.table "treasury_spends" $ p6 (O.requiredTableField "chain",O.requiredTableField "event_id",O.requiredTableField "anchor",O.requiredTableField "economic_json",O.requiredTableField "proof_json",O.requiredTableField "critical_sequence")
  economic<-either (fail . T.unpack) pure (W.economicOutflow "Native" $ W.chainEventEvidence event)
  void $ O.runInsert c O.Insert {O.iTable=spends,O.iRows=[(text "Native",text $ W.chainEventId event,text $ W.chainEventAnchor event,text $ TE.decodeUtf8 $ BL.toStrict $ encode economic,text "{}",O.sqlInt8 1)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runUpdate c O.Update {O.uTable=S.chainEvents,O.uUpdateWith= \r->r {S.eventReview=O.sqlInt8 0},
    O.uWhere= \r->S.eventChain r O..== text "Native" O..&& S.eventId r O..== text (W.chainEventId event),O.uReturning=O.rCount}

fixture c ResetOperatingScan = void $ O.runDelete c O.Delete {O.dTable=S.checkpoints,
  O.dWhere= \(chain,_)->chain O..== O.sqlStrictText "SolanaOperating",O.dReturning=O.rCount}
fixture c (LatestSourceState did) = do
  rows<-O.runSelect c $ fmap snd $ O.limit 1 $ O.orderBy (O.desc fst) $ do
    (key,source,state,_,_,_)<-O.selectTable S.sourceChecks
    O.where_ (source O..== O.sqlStrictText did)
    pure (key,state)
  case rows of [state]->pure state; _->fail "missing source recovery"

fixture c (CheckFundingBinding identifier withdrawal) = do
  rows<-O.runSelect c $ do
    row<-O.selectTable S.intents
    O.where_ (S.intentId row O..== O.sqlStrictText identifier)
    pure (S.intentObligation row,S.intentWithdrawal row)
    :: IO [(Maybe T.Text,Maybe T.Text)]
  changed<-try (O.runUpdate c O.Update {O.uTable=S.intents,O.uUpdateWith= \r->r {S.intentChain=O.sqlStrictText "Solana"},O.uWhere= \r->S.intentId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}) :: IO (Either PG.SqlError Int64)
  pure (rows==[(Nothing,Just withdrawal)] && case changed of Left err->PG.sqlState err=="23514"; _->False)

fixture c (ImmutableAttempt identifier) = do
  result<-try (O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptBytes=O.sqlStrictText "modified"},
    O.uWhere= \r->S.attemptId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}) :: IO (Either PG.SqlError Int64)
  pure $ case result of Left err->PG.sqlState err=="23514"; _->False

fixture c SeedCustodyHeads = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.scanOrigins,O.iRows=[(text chain,text origin) |
    (chain,origin)<-[("Native","scan-origin"),("Solana","sol-origin"),("SolanaOperating","opening-signature")]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  forM_ ["Solana","SolanaOperating"] $ \chain->do
    void $ O.runUpdate c O.Update {O.uTable=S.checkpoints,O.uUpdateWith= \(key,_)->(key,text $ T.replicate 64 "1"),O.uWhere= \(key,_)->key O..== text chain,O.uReturning=O.rCount}
    let proof=text $ TE.decodeUtf8 $ BL.toStrict $ encode $ object ["proof" .= object []]
    void $ O.runInsert c O.Insert {O.iTable=S.observationEvidence,O.iRows=[(text chain,text chain,text (T.replicate 64 "1"),proof)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    void $ O.runInsert c O.Insert {O.iTable=S.chainEvents,O.iRows=[S.ChainEvent (text chain) (text $ T.replicate 64 "1") (text "reference") (text "42") (text chain) (num 100) (num 100) (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c ReadCustodyCheck = do
  rows<-O.runSelect c $ fmap (\(_,_,revision,at,problem)->(revision,at,problem)) (O.selectTable S.custody)
  case rows of [row]->pure row; _->fail "missing custody check"

fixture c (CustodyHeadReview flag) = void $ O.runUpdate c O.Update {O.uTable=S.chainEvents,
  O.uUpdateWith= \r->r {S.eventReview=O.sqlInt8 flag},O.uWhere= \r->S.eventChain r O..== O.sqlStrictText "Solana"
    O..&& S.eventId r O..== O.sqlStrictText (T.replicate 64 "1"),O.uReturning=O.rCount}

fixture c OrderWorkflowFunds = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "workflow-funds",text "offline order workflow funds")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=[(Nothing,text "workflow-funds",text asset,text account,num quantity) |
    (asset,account,quantity)<-[("Native","external",-20000),("Native","float",10000),("Native","operating",10000),
      ("Wrapped","external",-10000),("Wrapped","float",10000),("Sol","external",-10000),("Sol","operating",10000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runUpdate c O.Update {O.uTable=S.scanHealth,O.uUpdateWith= \(chain,_,_,_)->(chain,O.toNullable $ num 110,O.null,num 110),O.uWhere=const $ O.sqlBool True,O.uReturning=O.rCount}
  void $ O.runUpdate c O.Update {O.uTable=S.deployment,O.uUpdateWith= \r->r {S.paused=num 0},O.uWhere=const $ O.sqlBool True,O.uReturning=O.rCount}
  fixture c RefreshCustody

-- Offline RPC contracts over an actual PostgreSQL snapshot. No live-chain claim.
custodyContract :: PG.Connection -> Reader -> IO ()
custodyContract fixtures reader = do
  let key=T.replicate 32 "1"; signature=T.replicate 64 "1"; block=T.replicate 64 "a"
      config=H.SolanaPolicy "contract" "contract" key key key (money 10) (money 10)
      native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused" "test" 1 "scan-origin"
      solana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing key key key
      settings=ObserverSettings native solana 2 "sol-origin" "opening-signature"
      balance=object ["mine" .= object ["trusted" .= (0.000021::Double),"untrusted_pending" .= (0::Int),"immature" .= (0::Int)],
        "lastprocessedblock" .= object ["hash" .= block,"height" .= (100::Int)]]
      nativeCall wallet method params=case (wallet,method,params) of
        (True,"getbalances",[])->pure balance
        (True,"listsinceblock",[String "fixture-anchor",Number 2,Bool False,Bool True])->pure $ object
          ["lastblock" .= ("fixture-anchor"::T.Text),"transactions" .= ([]::[Value]),"removed" .= ([]::[Value])]
        (False,"getblockhash",[Number 100])->pure $ String block
        _->fail "unexpected custody native RPC"
      token n=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object
        ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::T.Text),"info" .= object
          ["mint" .= key,"owner" .= key,"state" .= ("initialized"::T.Text),"isNative" .= False,
           "tokenAmount" .= object ["amount" .= T.pack(show (n::Int)),"decimals" .= (8::Int)]]]]]
      owner=object ["owner" .= key,"executable" .= False,"data" .= ["","base64"::T.Text],"lamports" .= (100::Int)]
      solCall n headSignature method params=case (method,params) of
        ("getMultipleAccounts",[addresses,options])->do
          minimumSlot<-fieldValue "minContextSlot" options :: IO Int
          commitment<-fieldValue "commitment" options :: IO T.Text
          unless (addresses==toJSON [key,key] && minimumSlot==42 && commitment=="finalized") (fail "incorrect custody account request")
          pure $ object ["context" .= object ["slot" .= (42::Int)],"value" .= [token n,owner]]
        ("getSignaturesForAddress",[String address,options])->do
          limit<-fieldValue "limit" options :: IO Int
          minimumSlot<-fieldValue "minContextSlot" options :: IO Int
          unless (address==key && limit==1 && minimumSlot==42) (fail "incorrect custody history request")
          pure $ toJSON [object ["signature" .= headSignature,"slot" .= (42::Int),"err" .= Null,"confirmationStatus" .= ("finalized"::T.Text)]]
        _->fail "unexpected custody Solana RPC"
      inspect clock identity ncall scall verifier cfg=inspectCustodyWith clock identity ncall scall verifier cfg config reader False
      good=solCall 1000 signature
  identities<-newIORef (0::Int)
  (_,at,matches,_)<-inspect (pure 100) (modifyIORef' identities (+1)) nativeCall good Nothing settings
  count<-readIORef identities
  unless (at==100 && matches && count==1) (fail "custody inspection failed")
  (_,_,mismatch,_)<-inspect (pure 100) (pure ()) nativeCall (solCall 999 signature) Nothing settings
  when mismatch (fail "custody accepted unequal balances")
  expectStore "custody_solana_history_advanced" (inspect (pure 100) (pure ()) nativeCall (solCall 1000 $ T.replicate 63 "1"<>"2") Nothing settings)
  expectStore "custody_verifier_disagreement" (inspect (pure 100) (pure ()) nativeCall good (Just $ solCall 999 signature)
    settings {solanaSettings=solana {Solana.solanaVerifierRpc=Just "https://independent.example"}})
  let advanced wallet method params=if method=="listsinceblock" then pure $ object ["lastblock" .= ("advanced"::T.Text)] else nativeCall wallet method params
  expectStore "custody_native_history_advanced" (inspect (pure 100) (pure ()) advanced good Nothing settings)
  samples<-newIORef (0::Int)
  let unstable wallet method params=if method=="getbalances" then do
        count<-atomicModifyIORef' samples (\n->(n+1,n))
        if count==0 then pure balance else pure $ object
          ["mine" .= object ["trusted" .= (0.000022::Double),"untrusted_pending" .= (0::Int),"immature" .= (0::Int)],
           "lastprocessedblock" .= object ["hash" .= block,"height" .= (100::Int)]]
       else nativeCall wallet method params
  expectStore "custody_native_view_changed" (inspect (pure 100) (pure ()) unstable good Nothing settings)
  times<-newIORef [100,161::Int64]
  let clock=atomicModifyIORef' times (\xs->case xs of t:rest->(rest,t); []->([],161))
  expectStore "custody_check_timed_out" (inspect clock (pure ()) nativeCall good Nothing settings)
  let changed wallet method params=do
        value<-nativeCall wallet method params
        when (method=="getblockhash") (fixture fixtures $ CustodyHeadReview 0)
        pure value
  expectStore "custody_ledger_changed" (inspect (pure 100) (pure ()) changed good Nothing settings)
  expectStore "native_reused_balance_requires_review" (nativeBalance $ \_ _ _->pure $ object
    ["mine" .= object ["trusted" .= (0::Int),"untrusted_pending" .= (0::Int),"immature" .= (0::Int),"used" .= (1::Int)]])

orderWorkflowContract :: PG.Connection -> Reader -> Writer -> IO ()
orderWorkflowContract fixtures reader writer = do
  admissions<-newIORef (0::Int); identities<-newIORef (0::Int); allocations<-newIORef (0::Int)
  label<-newIORef Nothing; loseReply<-newIORef True
  let native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused" "workflow" 1 (T.replicate 64 "0")
      header="Bearer "<>T.replicate 64 "e"
      unwrap=W.OrderRequest WrappedToNative (money 10) "native-recipient" "" Nothing "workflow-unwrap"
      call _ method params=case (method,params) of
        ("getwalletinfo",[])->pure $ object ["walletname" .= ("workflow"::T.Text),"descriptors" .= True,
          "scanning" .= False,"private_keys_enabled" .= True,"external_signer" .= False]
        ("getaddressesbylabel",[String requested])->do
          saved<-readIORef label
          if saved==Just requested then pure $ object ["offline-order-address" .= object ["purpose" .= ("receive"::T.Text)]] else reject "rpc_error_-11"
        ("getnewaddress",[String requested,String "bech32"])->do
          modifyIORef' allocations (+1)
          writeIORef label (Just requested)
          lose<-atomicModifyIORef' loseReply (\old->(False,old))
          if lose then reject "rpc_transport_unknown_outcome" else pure $ String "offline-order-address"
        ("getaddressinfo",[String address])->do
          saved<-readIORef label
          pure $ object ["address" .= address,"ismine" .= True,"solvable" .= True,"ischange" .= False,
            "labels" .= maybe [] pure saved,"scriptPubKey" .= ("0014"<>T.replicate 40 "a")]
        _->fail "unexpected provisioning RPC"
      backup n=evalWrite writer (AcknowledgeBackup "contract" n $ T.replicate 64 "d")
      transport=OrderTransport (pure 110) (const $ modifyIORef' admissions (+1)) (modifyIORef' identities (+1)) call backup
      create=createCustomerOrderWith transport native True reader writer header
      check ok=unless ok (fail "customer workflow contract failed")
  expectStore "invalid_idempotency_key" (create unwrap {W.idempotencyKey=""})
  missing<-evalRead reader (FindOrder header unwrap)
  check (missing==Nothing)
  -- Returning from a backup callback cannot itself authorize exposure.
  expectStore "backup_pending" (createCustomerOrderWith transport {orderBackup=const $ pure ()} native True reader writer header unwrap)
  Just oid<-evalRead reader (FindOrder header unwrap)
  hidden<-evalRead reader (ReadOrder header oid)
  check (W.depositInstruction hidden==Nothing)
  issued<-create unwrap
  check (W.orderId issued==oid && W.status issued=="AwaitingDeposit" && W.depositInstruction issued/=Nothing)
  counts<- (,) <$> readIORef admissions <*> readIORef identities
  fixture fixtures (CustodyHeadReview 0)
  evalWrite writer (Pause "test replay while paused")
  replay<-create unwrap
  afterCounts<-(,) <$> readIORef admissions <*> readIORef identities
  check (replay==issued && counts==afterCounts && fst counts==1)
  expectStore "idempotency_conflict" (create unwrap {W.input=money 11})
  expectStore "order_not_found" (evalRead reader $ ReadProvisioning ("Bearer "<>T.replicate 64 "f") oid)
  fixture fixtures ReadyIntake
  let wrapping=unwrap {W.direction=NativeToWrapped,W.recipient="solana-recipient",W.refund="native-refund",W.idempotencyKey="workflow-wrap"}
  expectStore "rpc_transport_unknown_outcome" (create wrapping)
  Just wrapId<-evalRead reader (FindOrder header wrapping)
  recovered<-create wrapping
  allocated<-readIORef allocations
  check (W.orderId recovered==wrapId && W.depositInstruction recovered==Just "offline-order-address" && allocated==1)
  _<-create wrapping
  readIORef allocations >>= check . (==1)
