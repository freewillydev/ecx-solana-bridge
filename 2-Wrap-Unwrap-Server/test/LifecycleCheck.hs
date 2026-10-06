-- Independent accounting oracle for lifecycle extraction. Expected values never
-- call Domain.settlement. PostgreSQL contracts cover durable commits; this model
-- compares the extracted decisions with independent accounting and old histories.
module LifecycleCheck (checks) where

import Bridge.Domain hiding (fee)
import Bridge.Lifecycle
import qualified Bridge.Wire as W
import Bridge.Wire (PaymentTerms(..),CostLimits(..),PolicySnapshot(..),SignedAttempt(..),PaymentCosts(..))
import Control.Monad (foldM)
import Data.Int (Int64)
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified Data.Text as T
import Test.QuickCheck

data FundingCase = Convert Direction Integer Integer | Return Asset Integer | Revenue Asset Integer
  deriving (Eq,Show)
data History = History [FundingCase] [Int] deriving Show
type Balances = M.Map (Asset,Account) Integer

checks :: IO [Result]
checks = sequence
  [ check "lifecycle accounting agrees with an independent funding model" $
      forAllShrink fundingCases shrinkFunding $ \funding ->
        aggregate (settlement $ outgoing 0 funding) === expected funding
  , check "bounded delivery histories preserve principal identity and protected accounts" $
      forAllShrink histories shrinkHistory $ \history ->
        let actual=good $ decisions history; wanted=model history
        in conjoin [actual===wanted, actual===baseline history, property $ all (==0)
             [M.findWithDefault 0 (asset,account) actual | asset<-[Native,Wrapped,Sol],account<-[Backing,Liquidity,SourceDeficit]]]
  , check "model rejects deliberately duplicated principal" $ expectFailure $ once $
      let funding=Convert NativeToWrapped 100 1; history=History [funding] [0,0]
      in aggregate (concatMap (const $ settlement $ outgoing 0 funding) [0::Int,0]) === model history
  , check "model rejects deliberately altered fee accounting" $ expectFailure $ once $
      let funding=Convert WrappedToNative 100 1
      in M.adjust (+1) (Wrapped,Earned) (aggregate $ settlement $ outgoing 0 funding) === expected funding
  , check "settlement snapshot preserves funding and separates verified network costs" $
      forAllShrink fundingCases shrinkFunding $ \funding -> forAll (chooseInt (0,7)) $ \generation ->
        let facts=snapshot 0 funding
            queued=(settlementCurrent facts) {recordedGeneration=generation}
            current=facts {settlementCurrent=queued}
            outcome=successful current
            effect=case good (decideSettlement queued current outcome) of ApplySettlement x->x; _->error "new settlement replayed"
            expectedCustomer=case funding of
              Convert{}->Just(CustomerResolution "order-payment-0" False "Paid")
              Return{}->Just(CustomerResolution "order-payment-0" True "Refunded")
              Revenue{}->Nothing
        in conjoin [aggregate(settlementPrincipal effect)===expected funding
             ,settlementOutcome effect===outcome,settlementCustomer effect===expectedCustomer
             ,property $ all ((/=Operating).postingAccount) (settlementPrincipal effect)]
  , check "finalized Solana failure books only its exact fee and replay requires it" $
      forAll (chooseInteger (1,10)) $ \fee ->
        let facts=snapshot 0 (Convert NativeToWrapped 100 1); queued=settlementCurrent facts
            outcome=Failed (money fee) "failure-proof"
            effect=case good(decideSettlement queued facts outcome) of ApplySettlement x->x; _->error "new failure replayed"
            repeated=finished facts outcome
        in conjoin [settlementPrincipal effect===[],outcomeCosts outcome===PaymentCosts (money fee) (money 0)
             ,settlementCustomer effect===Just(CustomerResolution "order-payment-0" False "NeedsReview")
             ,decideSettlement queued repeated outcome===Right SettlementReplay
             ,decideSettlement queued repeated {settlementFailedCharge=Just(fee+1)} outcome===Left "failure_evidence_conflict"]
  , check "settlement refuses changed identity generation bytes proof and missing authority" $ once $ property refusalCases
  , check "preparation through queue and settlement preserves exact saved payment" $
      forAllShrink fundingCases shrinkFunding $ \funding ->
        let facts=initialPreparation funding
            prepared=created $ good $ decidePreparation (money 10) "{}" facts
            queued=sendFacts funding prepared
            unsigned=queued {sendAttempt=(sendAttempt queued) {recordedState="signed",recordedSequence=Nothing}}
            replay=facts {preparationPayment=preparedView prepared
              ,preparationHistory=LivePreparation (recordedChain $ sendAttempt queued) prepared,preparationAdmission=Nothing}
        in conjoin
          [ savedPayment(preparedView prepared)===savedPayment(preparationPayment facts)
          , decidePreparation (money 10) "{}" replay===Right(ReusePreparation prepared)
          , decidePreparation (money 10) "{\"changed\":true}" replay===Left "preparation_conflict"
          , decideQueue unsigned===Right CreateQueue
          , decideQueue queued===Right(ReuseQueue 5)
          , decideSend unsigned===Left "broadcast_intent_required"
          , decideSend queued {sendBackupSequence=4}===Left "backup_pending"
          , decideSend queued===Right(sendAttempt queued)
          , decideSend queued {sendReviewSequence=6}===Left "backup_pending"
          , decideSend queued {sendReviewSequence=6,sendBackupSequence=6}===Right(sendAttempt queued)
          , decisions (History [funding] [0,0,0])===Right(expected funding) ]
  , check "authorized retry replaces only its own prior fee hold" $
      forAllShrink fundingCases shrinkFunding $ \funding -> forAll (chooseInt (1,7)) $ \generation ->
      forAll arbitrary $ \expired ->
        let original=initialPreparation funding; admission=admitted original
            chain=recordedChain(settlementCurrent $ snapshot 0 funding)
            currency=if chain=="Native" then Native else Sol
            facts=original {preparationHistory=RetiredPreparation chain (Just generation)
              ,preparationAdmission=Just admission {priorPreparationFee=Just(PriorFeeHold currency (money 10) expired expired)
                ,customerOperatingHold=Nothing,preparationBudget=FeeBudget 1000 (if expired then 0 else 10) 0 (money 1000)}}
            result=created $ good $ decidePreparation (money 10) "{}" facts
        in conjoin [preparedGeneration result===generation,preparedFee result===money 10
             ,savedPayment(preparedView result)===savedPayment(preparationPayment original)
             ,decidePreparation (money 10) "{}" facts {preparationHistory=RetiredPreparation chain Nothing}===Left "preparation_retry_not_authorized"
             ,decidePreparation (money 10) "{}" facts {preparationHistory=RetiredPreparation chain (Just 8)}===Left "preparation_generation_limit"]
  , check "preparation rejects invalid plans missing holds and shared budget exhaustion" $ once preparationRefusals
  , check "queue and send reject changed generation stale readiness and replacement selection" $ once sendRefusals
  , check "readiness uses the exact sixty-second boundary without extending time" $
      forAll (chooseInteger (0,toInteger(maxBound::Int64)-61)) $ \time ->
        let now=fromInteger time
            facts=readyIntake {intakeTime=now,intakeScans=Just((now,"n"),(now,"t"),(now,"s")),intakeCustody=Just(3,3,now)}
        in conjoin [checkIntake facts===Right (),checkIntake facts {intakeTime=now+60}===Right ()
             ,checkIntake facts {intakeTime=now+61}===Left "scanners_not_fresh"
             ,checkIntake facts {intakeCustody=Just(4,3,now)}===Left "custody_not_reconciled"]
  , check "new admission uses ceiling one percent and retains both alternate cost holds" $
      forAll (chooseInteger (2,100000000)) $ \n -> forAll (elements [NativeToWrapped,WrappedToNative]) $ \direction ->
        let request=customerRequest direction n
            admitted=good $ decideOrder customerLimits customerCosts request customerAdmission
            charged=1+(n-1) `div` 100
            expectedCosts=if direction==NativeToWrapped then [("refund",Native,money 10),("conversion",Sol,money 20)]
              else [("conversion",Native,money 10),("refund",Sol,money 20)]
        in conjoin [net(admittedQuote admitted)===money(n-charged),admittedDeadline admitted===200,admittedGrace admitted===300
             ,admittedCosts admitted===expectedCosts
             ,decideOrder customerLimits customerCosts request customerAdmission {availableFloat=n-charged-1}===Left "insufficient_inventory"
             ,decideOrder customerLimits customerCosts request customerAdmission {nativeOrderBudget=FeeBudget 9 0 0 (money 1000000000)}===Left "insufficient_fee_budget"]
  , check "native allocation retries never allocate twice or extend immutable instructions" $ once $
      let fresh=InstructionFacts NativeToWrapped "Provisioning" 200 Nothing Nothing 0
          saved=fresh {instructionStatus="AwaitingDeposit",savedInstruction=Just "owned-address",savedInstructionSequence=Just 4}
      in conjoin [decideNativeClaim "label" Nothing fresh (Just readyIntake)===Right(AllocationClaim "label" True)
           ,decideNativeClaim "label" (Just "label") fresh Nothing===Right(AllocationClaim "label" False)
           ,decideNativeClaim "other" (Just "label") fresh Nothing===Left "allocation_label_mismatch"
           ,decideInstruction saved "other-address"===Left "instruction_is_immutable"
           ,decideInstructionIssue True 3 saved Nothing===Left "backup_pending"
           ,decideInstructionIssue True 4 saved (Just(readyIntake,["quote"],["quote","quote"]))===Right True
           ,decideInstructionIssue True 4 saved {instructionIssued=1} Nothing===Right False
           ,decideInstructionIssue True 4 saved (Just(readyIntake {intakeTime=201},["quote"],["quote","quote"]))===Left "scanners_not_fresh"]
  , check "promotion preserves historical terms and refuses changed late additional or lost sources" $
      forAll (chooseInteger (2,100000000)) $ \n -> forAll (chooseInteger (0,n-1)) $ \charge ->
      forAll (elements [NativeToWrapped,WrappedToNative]) $ \direction ->
        let facts=customerPromotion direction n charge
            order=promotionOrder facts; receipt=promotionReceipt facts
            approved=case good(decidePromotion "fixture" 300 facts) of Just p->p; Nothing->error "promotion rejected"
            changed=receipt {W.depositAmount=money(n+1)}
        in conjoin [paymentAmount approved===money(n-charge),paymentRecipient approved===W.recipient(W.request order)
             ,decidePromotion "fixture" 301 facts===Right Nothing
             ,decidePromotion "fixture" 100 facts {promotionReceipt=changed}===Right Nothing
             ,decidePromotion "fixture" 100 facts {promotionReceipt=receipt {W.depositEligible=False}}===Right Nothing
             ,decidePromotion "fixture" 100 facts {conversionExists=True}===Right Nothing
             ,decidePromotion "other" 100 facts===Left "saved_order_terms_mismatch"]
  , check "mixed conversion refunds and earned withdrawals retain full principal and separate costs" $
      forAll (chooseInteger (2,1000000)) $ \n -> forAll (chooseInteger (1,1000)) $ \extra ->
      forAll (elements [NativeToWrapped,WrappedToNative]) $ \direction ->
        let order=promotionOrder $ customerPromotion direction n 1
            asset=sourceAsset direction; feeAsset=if asset==Native then Native else Sol
            allowance=if asset==Native then 10 else 20
            receipt=W.Deposit "extra" (Just "order") asset (money extra) "anchor" 2 True 110
            work=[("convert:order","original","paid")]
            facts=RefundFacts False work "verified-owner" [(T.pack(show feeAsset),allowance,"released")]
              (Just $ FeeBudget 1000 0 0 $ money 1000)
            refunded=good $ decideRefund (W.request order) receipt customerCosts facts
            withdrawn=good $ withdrawalInput (money 1000) 100 (T.replicate 64 "a") asset (money 1) "owner" "earned"
            histories=History [Convert direction n 1,Return asset extra,Revenue asset 1] [0,1,1,2,0]
        in conjoin [paymentAmount refunded===money extra,paymentAsset refunded===asset
             ,aggregate(settlement refunded)===expected(Return asset extra)
             ,decisions histories===Right(model histories)
             ,decideRefund (W.request order) receipt customerCosts facts {refundUnresolved=True}===Left "refund_would_race_payment"
             ,decideRefund (W.request order) receipt customerCosts facts {refundObligations=[("already","extra","paid")]}===Left "principal_already_resolved"
             ,decideRefund (W.request order) receipt customerCosts facts {refundBudget=Just(FeeBudget 1000 990 0 $ money 1000)}
                ===(if allowance>10 then Left "insufficient_fee_budget" else Right refunded)
             ,decideWithdrawal withdrawn (PaymentTerms (W.policy order) customerCosts) "earned" Nothing (Just(readyOperator,0))===Left "insufficient_earned_fees"]
  , check "expiry cannot free a received deposit or extend grace on clock rollback" $
      forAll (chooseInteger (0,toInteger(maxBound::Int64)-1)) $ \time ->
        let grace=fromInteger time in conjoin
          [shouldExpireQuote grace grace False===Right False,shouldExpireQuote (grace+1) grace False===Right True
          ,shouldExpireQuote (grace+1) grace True===Right False,shouldExpireQuote 0 grace False===Right False]
  , check "earned cancellation requires unsigned cleanup and exact replay reason" $ once $
      let outgoing=good $ withdrawalInput (money 1000) 100 (T.replicate 64 "a") Native (money 10) "owner" "earned"
          terms=PaymentTerms (PolicySnapshot 2 "finalized" "fixture") customerCosts
          saved=WithdrawalView outgoing terms "earned" 3 Nothing
      in conjoin [decideWithdrawal outgoing terms "earned" (Just saved) Nothing===Right False
           ,decideWithdrawal outgoing terms "changed" (Just saved) Nothing===Left "fee_withdrawal_conflict"
           ,decideWithdrawalCancellation "cancel" saved (WithdrawalWork False True)===Left "fee_withdrawal_payment_exists"
           ,decideWithdrawalCancellation "cancel" saved (WithdrawalWork True False)===Left "pause_before_operator_action"
           ,decideWithdrawalCancellation "cancel" saved (WithdrawalWork True True)===Right True
           ,decideWithdrawalCancellation "cancel" saved {withdrawalCancellation=Just("cancel",4)} UnpreparedWithdrawal===Right False]
  , check "treasury splits conserve an unbound receipt and never spend protected balances" $
      forAll (chooseInteger (1,1000000)) $ \n ->
        let receipt=W.Deposit "native:receipt:0" Nothing Native (money(n+2)) "anchor" 2 True 100
            facts=TreasuryFacts readyOperator receipt False False
            entries=good $ decideTreasury (PolicySnapshot 2 "finalized" "fixture") [("float",money n),("operating",money 2)] facts
            spent=good $ decideTreasurySpend (Native,money(n+1),money 1) n 1
        in conjoin [aggregate entries===M.fromList [((Native,Unallocated),negate(n+2)),((Native,Float),n),((Native,Operating),2)]
             ,sum(map postingDelta entries)===0,sum(map postingDelta spent)===0
             ,decideTreasurySpend (Native,money(n+1),money 1) (n-1) 1===Left "treasury_spend_exceeds_free_allocation"
             ,decideTreasury (PolicySnapshot 2 "finalized" "fixture") [("float",money(n+2))] facts {treasuryLinked=True}===Left "receipt_has_customer_obligation"
             ,property $ all ((`notElem` [Principal,Backing,Liquidity,Earned]).postingAccount) spent]
  ]
 where
  check name test=putStrLn name >> quickCheckWithResult stdArgs {maxSuccess=300} test

fundingCases :: Gen FundingCase
fundingCases = do
  n<-frequency [(8,chooseInteger (2,100000000)),(1,pure 2),(1,pure $ toInteger(maxBound::Int64))]
  oneof
    [ Convert <$> elements [NativeToWrapped,WrappedToNative] <*> pure n <*> chooseInteger (0,n-1)
    , Return <$> elements [Native,Wrapped] <*> pure n
    , Revenue <$> elements [Native,Wrapped] <*> pure n ]

shrinkFunding :: FundingCase -> [FundingCase]
shrinkFunding (Convert direction n f) =
  [Convert direction smaller (min f $ smaller-1) | smaller<-shrink n,smaller>=2]
  <>[Convert direction n smaller | smaller<-shrink f,smaller>=0,smaller<n]
shrinkFunding (Return asset n) = [Return asset smaller | smaller<-shrink n,smaller>0]
shrinkFunding (Revenue asset n) = [Revenue asset smaller | smaller<-shrink n,smaller>0]

histories :: Gen History
histories = do
  count<-chooseInt (1,6)
  payments<-vectorOf count fundingCases
  lengthOfTrace<-chooseInt (0,24)
  deliveries<-vectorOf lengthOfTrace (chooseInt (0,count-1))
  -- Include every payment and at least one exact redelivery. Shrinking below
  -- can isolate the minimal delivery while keeping all indices well formed.
  pure $ History payments (take 24 deliveries<>[0..count-1]<>[0])

shrinkHistory :: History -> [History]
shrinkHistory (History payments deliveries) =
  [History payments fewer | fewer<-shrinkList (const []) deliveries]
  <>[History (before<>(smaller:after)) deliveries
     | index<-[0..length payments-1],(before,current:after)<-[splitAt index payments]
     ,smaller<-shrinkFunding current]

outgoing :: Int -> FundingCase -> Payment
outgoing index funding = good $ do
  source<-case funding of
    Convert direction n f -> historicalQuote (money n) (money f) >>= conversion order receipt direction
    Return asset n -> refund order receipt asset (money n)
    Revenue asset n -> earnedFees order asset (money n)
  payment key source "unchanged-recipient"
 where
  key="payment-"<>T.pack(show index); order="order-"<>key; receipt="receipt-"<>key

-- Only this adapter uses production accounting. Deduplication here is the
-- baseline Store contract, not a new production implementation of replay.
baseline :: History -> Balances
baseline (History payments deliveries) = aggregate $
  concat [settlement(outgoing index $ payments!!index) | index<-nub deliveries]

-- Unlike the baseline adapter, the new adapter delegates replay/authorization to
-- decideSettlement. Updating the in-memory facts models only a committed result;
-- actual all-or-nothing persistence is tested against PostgreSQL, not assumed here.
decisions :: History -> Either T.Text Balances
decisions (History payments deliveries) = snd <$> foldM step (initial,M.empty) deliveries
 where
  initial=M.fromList [(index,snapshot index funding) | (index,funding)<-zip [0..] payments]
  step (states,balances) index = do
    let facts=states M.! index; queued=settlementCurrent(initial M.! index); outcome=successful facts
    decision<-decideSettlement queued facts outcome
    case decision of
      SettlementReplay->pure (states,balances)
      ApplySettlement effects->pure (M.insert index (finished facts outcome) states,
        normalize $ M.unionWith (+) balances (aggregate $ settlementPrincipal effects))

snapshot :: Int -> FundingCase -> SettlementFacts
snapshot index funding = SettlementFacts queued view (Just(currency,money 10)) Nothing Nothing
 where
  p=outgoing index funding; native=paymentAsset p==Native; currency=if native then Native else Sol
  view=PaymentView p (PaymentTerms (PolicySnapshot 2 "finalized" "fixture") (CostLimits (money 10) (money 10) (money 10))) PaymentPaying
  queued=RecordedAttempt (paymentId p) (if native then "Native" else "Solana") 0 (money 10) "broadcast_intent" (Just 5) Nothing
    (SignedAttempt ("transaction-"<>T.pack(show index)) "exact-saved-bytes" "exact-saved-policy" Nothing)

successful :: SettlementFacts -> SettlementOutcome
successful facts = Succeeded (PaymentCosts (money 1) (money $ if recordedChain(settlementCurrent facts)=="Native" then 0 else 2)) "finality-proof"

finished :: SettlementFacts -> SettlementOutcome -> SettlementFacts
finished facts outcome = facts
  { settlementCurrent=queued {recordedState=outcomeState outcome,recordedObservation=Just $ outcomeRecord outcome}
  , settlementPayment=(settlementPayment facts) {savedStatus=if paid then PaymentPaid else PaymentReview}
  , settlementHold=Nothing,settlementPriorWinner=if paid then Just(signedId $ recordedSigned queued) else Nothing
  , settlementFailedCharge=case outcome of Failed cost _->Just(toInteger $ units cost); _->Nothing }
 where queued=settlementCurrent facts; paid=case outcome of Succeeded{}->True; Failed{}->False

refusalCases :: Bool
refusalCases = and
  [ reject "settlement_attempt_changed" queued {recordedGeneration=1} facts outcome
  , reject "settlement_attempt_changed" queued {recordedState="signed"} facts outcome
  , reject "settlement_attempt_changed" queued {recordedSequence=Nothing} facts outcome
  , reject "settlement_attempt_changed" queued {recordedSigned=(recordedSigned queued) {signedBytes="other"}} facts outcome
  , reject "settlement_attempt_changed" queued facts {settlementPayment=settlementPayment(snapshot 1 funding)} outcome
  , reject "settlement_not_expected" queued facts {settlementPayment=(settlementPayment facts) {savedStatus=PaymentReady}} outcome
  , reject "payment_intent_not_settleable" queued facts {settlementHold=Nothing} outcome
  , reject "payment_intent_not_settleable" queued facts {settlementHold=Just(Native,money 10)} outcome
  , reject "payment_intent_not_settleable" queued facts {settlementHold=Just(Sol,money 9)} outcome
  , reject "payment_already_settled" queued facts {settlementPriorWinner=Just "other-winner"} outcome
  , reject "settlement_fee_or_evidence_invalid" queued facts (Succeeded (PaymentCosts (money 0) (money 0)) "proof")
  , reject "settlement_fee_or_evidence_invalid" queued facts (Succeeded (PaymentCosts (money 9) (money 2)) "proof")
  , reject "settlement_fee_or_evidence_invalid" queued facts (Succeeded (PaymentCosts (money 1) (money 0)) "")
  , reject "settlement_fee_or_evidence_invalid" queued facts (Succeeded (PaymentCosts (money 1) (money 0)) $ T.replicate 32769 "x")
  , reject "settlement_evidence_conflict" queued (finished facts outcome) (Succeeded (outcomeCosts outcome) "changed")
  , reject "settlement_evidence_conflict" queued (finished facts outcome) (Succeeded (PaymentCosts (money 2) (money 2)) "finality-proof")
  , reject "settlement_fee_or_evidence_invalid" nativeQueued nativeFacts (Succeeded (PaymentCosts (money 1) (money 1)) "proof")
  , reject "invalid_failure_evidence" nativeQueued nativeFacts (Failed (money 1) "proof")
  , reject "invalid_failure_evidence" queued facts (Failed (money 0) "proof")
  , reject "invalid_failure_evidence" queued facts (Failed (money 11) "proof")
  , decideSettlement queued (facts {settlementPayment=(settlementPayment facts) {savedStatus=PaymentReview}}) outcome
      ==decideSettlement queued facts outcome
  ]
 where
  funding=Convert NativeToWrapped 100 1
  facts=snapshot 0 funding; queued=settlementCurrent facts; outcome=successful facts
  nativeFacts=snapshot 0 (Return Native 100); nativeQueued=settlementCurrent nativeFacts
  reject code original current observed=decideSettlement original current observed==Left code

readyIntake :: IntakeFacts
readyIntake = IntakeFacts 100 False (Just((100,"native"),(100,"tokens"),(100,"sol"))) (Just(1,1,100))

initialPreparation :: FundingCase -> PreparationFacts
initialPreparation funding = PreparationFacts view InitialPreparation (Just admission)
 where
  view=(settlementPayment $ snapshot 0 funding) {savedStatus=PaymentReady}
  revenue=case funding of Revenue{}->True; _->False
  held=if revenue then 0 else 20
  admission=PreparationAdmission readyIntake False True Nothing (if revenue then Nothing else Just $ money held)
    (toInteger $ units $ paymentAmount $ savedPayment view) (FeeBudget 1000 held 0 (money 1000))

admitted :: PreparationFacts -> PreparationAdmission
admitted facts=case preparationAdmission facts of Just admission->admission; Nothing->error "fixture admission missing"
created :: PreparationDecision -> PreparedPayment
created (CreatePreparation prepared)=prepared
created ReusePreparation{}=error "new preparation unexpectedly reused"

sendFacts :: FundingCase -> PreparedPayment -> SendFacts
sendFacts funding prepared = SendFacts readyIntake prepared queued True
  (Just(signedId $ recordedSigned queued,False)) 0 True 5
 where queued=settlementCurrent $ snapshot 0 funding

preparationRefusals :: Property
preparationRefusals = conjoin $
  [counterexample (T.unpack code) $ decidePreparation quantity plan facts===Left code
    | (code,quantity,plan,facts)<-
      [("invalid_payment_record",money 10,"",base)
      ,("invalid_payment_record",money 10,"null",base)
      ,("invalid_saved_payment",money 10,"{",base)
      ,("order_fee_limit_exceeded",money 0,"{}",base)
      ,("order_fee_limit_exceeded",money 21,"{}",base)
      ,("payment_not_ready",money 10,"{}",base {preparationPayment=(preparationPayment base) {savedStatus=PaymentReview}})
      ,("preparation_retry_requires_recovery",money 10,"{}",base {preparationHistory=RetiredPreparation "wrong-chain" (Just 1)})]]
  <>[counterexample (T.unpack code) $ decidePreparation (money 10) "{}" base {preparationAdmission=Just changed}===Left code
    | (code,changed)<-
      [("intake_paused",original {preparationIntake=readyIntake {intakePaused=True}})
      ,("scanners_not_fresh",original {preparationIntake=readyIntake {intakeTime=161}})
      ,("destination_payment_unresolved",original {destinationBusy=True})
      ,("source_not_eligible",original {preparationSourceEligible=False})
      ,("operating_reservation_missing",original {customerOperatingHold=Nothing})
      ,("operating_reservation_missing",original {customerOperatingHold=Just $ money 9})
      ,("insufficient_fee_budget",original {preparationBudget=FeeBudget 9 20 0 (money 1000)})
      ,("operating_daily_limit",original {preparationBudget=FeeBudget 1000 20 991 (money 1000)})]]
  <>[decidePreparation (money 10) "{}" earned {preparationAdmission=Just (admitted earned) {pendingEarnedBalance=99}}===Left "earned_reservation_missing"]
 where
  base=initialPreparation (Convert NativeToWrapped 100 1); original=admitted base
  earned=initialPreparation (Revenue Native 100)

sendRefusals :: Property
sendRefusals = conjoin
  [counterexample (T.unpack code) $ decideSend changed===Left code | (code,changed)<-
    [("intake_paused",base {sendIntake=readyIntake {intakePaused=True}})
    ,("scanners_not_fresh",base {sendIntake=readyIntake {intakeScans=Nothing}})
    ,("custody_not_reconciled",base {sendIntake=readyIntake {intakeCustody=Just(2,1,100)}})
    ,("payment_not_sendable",base {sendAttempt=(sendAttempt base) {recordedGeneration=1}})
    ,("source_not_eligible",base {sendSourceEligible=False})
    ,("native_replacement_not_current",base {sendNativeSelection=Just("old",False)})
    ,("native_replacement_draft_pending",base {sendNativeSelection=Just("transaction-0",True)})
    ,("broadcast_intent_required",base {sendAttempt=(sendAttempt base) {recordedSequence=Nothing}})]]
 where
  funding=Return Native 100
  prepared=created $ good $ decidePreparation (money 10) "{}" (initialPreparation funding)
  base=sendFacts funding prepared

-- The model owns its paid set and independently calculates account changes.
model :: History -> Balances
model (History payments deliveries) = snd $ foldl step (Set.empty,M.empty) deliveries
 where
  step prior@(paid,balances) index
    | Set.member index paid = prior
    | otherwise = (Set.insert index paid,normalize $ M.unionWith (+) balances (expected $ payments!!index))

expected :: FundingCase -> Balances
expected funding = normalize $ M.fromListWith (+) $ case funding of
  Convert direction n f ->
    let (source,destination)=case direction of NativeToWrapped->(Native,Wrapped); WrappedToNative->(Wrapped,Native)
    in [((source,Principal),-n),((source,Float),n-f),((source,Earned),f)
       ,((destination,Float),f-n),((destination,External),n-f)]
  Return asset n -> [((asset,Principal),-n),((asset,External),n)]
  Revenue asset n -> [((asset,FeePending),-n),((asset,External),n)]

aggregate :: [Posting] -> Balances
aggregate = normalize . M.fromListWith (+) . map (\p->((postingAsset p,postingAccount p),postingDelta p))
normalize :: Balances -> Balances
normalize = M.filter (/=0)
money :: Integer -> Amount
money = good . amount
good :: Show e => Either e a -> a
good = either (error . show) id


customerCosts :: CostLimits
customerCosts=CostLimits (money 10) (money 10) (money 10)
customerLimits :: OrderLimits
customerLimits=OrderLimits (money 2) (money 100000000) 100 100 100 (money 1000000000) (money 1000000000)
customerAdmission :: OrderAdmissionFacts
customerAdmission=OrderAdmissionFacts readyIntake 0 100000000 budget budget
 where budget=FeeBudget 1000000000 0 0 (money 1000000000)
readyOperator :: OperatorFacts
readyOperator=OperatorFacts 100 True (Just(1,1,100))
customerRequest :: Direction -> Integer -> W.OrderRequest
customerRequest direction n=W.OrderRequest direction (money n) "recipient" (if direction==NativeToWrapped then "refund" else "") Nothing "key"
customerPromotion :: Direction -> Integer -> Integer -> PromotionFacts
customerPromotion direction n charge=PromotionFacts order receipt 300 False
 where
  order=W.OrderView "order" (customerRequest direction n) (good $ historicalQuote (money n) (money charge))
    "AwaitingDeposit" 200 (Just "instruction") Nothing (PolicySnapshot 2 "finalized" "fixture")
  receipt=W.Deposit "original" (Just "order") (sourceAsset direction) (money n) "anchor" 2 True 100
