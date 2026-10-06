-- Pure payment facts and decisions. These values carry no database, clock,
-- network or signing authority; the closed Store operation must read them afresh.
module Bridge.Lifecycle
  ( PaymentStatus(..), PaymentView(..), PreparedPayment(..), RecordedAttempt(..)
  , SettlementOutcome(..), SettlementFacts(..), SettlementDecision(..), SettlementEffects(..)
  , CustomerResolution(..), decideSettlement, checkSettlementEvidence, outcomeState, outcomeRecord, outcomeCosts
  , IntakeFacts(..), FeeBudget(..), PreparationHistory(..), PriorFeeHold(..)
  , PreparationAdmission(..), PreparationFacts(..), PreparationDecision(..), decidePreparation, checkPreparationInput
  , SendFacts(..), QueueDecision(..), decideQueue, decideSend, checkSendPayment
  , checkIntake, checkScans, checkCustody, checkFeeBudget
  , OrderLimits(..), OrderAdmissionFacts(..), OrderAdmission(..), quoteOrder, decideOrder
  , orderCostReservations, shouldExpireQuote
  , AllocationClaim(..), InstructionFacts(..), InstructionChange(..)
  , decideNativeClaim, checkNativeAllocation, checkSolanaBinding, decideInstruction, decideInstructionIssue
  , PromotionFacts(..), decidePromotion, checkPromotionHolds, savedCostLimits
  , RefundFacts(..), checkRefundSource, refundableWork, decideRefund
  , OperatorFacts(..), checkOperator, checkReason, WithdrawalView(..), WithdrawalWork(..)
  , withdrawalInput, decideWithdrawal, decideWithdrawalCancellation
  , TreasuryFacts(..), treasurySplit, decideTreasury, decideTreasurySpend
  , CustomerKind(..), CustomerPayment(..), projectCustomer, compactCustomerPayments, parsePaymentStatus
  ) where

import Bridge.Domain hiding (fee)
import Bridge.Wire (PaymentTerms(..),CostLimits(..),SignedAttempt(..),PaymentCosts(..))
import qualified Bridge.Wire as W
import Control.Monad (unless,forM_)
import Data.Aeson (Value(Null),eitherDecodeStrict',encode,object,(.=))
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.List (sort,sortOn,nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- Schema-21 projection retained during extraction. Review can hide economic
-- progress here; schema 22 will separate phase from its execution restrictions.
data PaymentStatus = PaymentReady | PaymentPaying | PaymentPaid | PaymentReview | PaymentCancelled deriving (Eq,Show)
parsePaymentStatus :: Text -> Either Text PaymentStatus
parsePaymentStatus state=case state of
  "ready"->Right PaymentReady; "paying"->Right PaymentPaying; "paid"->Right PaymentPaid
  "review"->Right PaymentReview; "cancelled"->Right PaymentCancelled
  _->Left "unknown_payment_status"
data PaymentView = PaymentView
  { savedPayment :: Payment, savedTerms :: PaymentTerms, savedStatus :: PaymentStatus } deriving (Eq,Show)
data PreparedPayment = PreparedPayment
  { preparedView :: PaymentView, preparedGeneration :: Int, preparedPolicy :: Text
  , preparedDraft :: Maybe Text, preparedFee :: Amount } deriving (Eq,Show)
data RecordedAttempt = RecordedAttempt
  { recordedPayment :: Text, recordedChain :: Text, recordedGeneration :: Int
  , recordedFee :: Amount, recordedState :: Text, recordedSequence :: Maybe Int64
  , recordedObservation :: Maybe Text, recordedSigned :: SignedAttempt } deriving (Eq,Show)

-- Evidence has already passed the chain-specific verifier. Its typed shape alone
-- does not prove finality: Store must also reload the exact current saved attempt.
data SettlementOutcome = Succeeded PaymentCosts Text | Failed Amount Text deriving (Eq,Show)
data SettlementFacts = SettlementFacts
  { settlementCurrent :: RecordedAttempt, settlementPayment :: PaymentView
  , settlementHold :: Maybe (Asset,Amount), settlementPriorWinner :: Maybe Text
  , settlementFailedCharge :: Maybe Integer } deriving (Eq,Show)

data CustomerResolution = CustomerResolution
  { resolutionOrder :: Text, preservePaidOrder :: Bool, resolutionStatus :: Text }
  deriving (Eq,Show)
data SettlementEffects = SettlementEffects
  { settlementOutcome :: SettlementOutcome, settlementPrincipal :: [Posting]
  , settlementCustomer :: Maybe CustomerResolution } deriving (Eq,Show)
data SettlementDecision = SettlementReplay | ApplySettlement SettlementEffects deriving (Eq,Show)

outcomeState :: SettlementOutcome -> Text
outcomeState Succeeded{} = "settled"
outcomeState Failed{} = "failed"
outcomeRecord :: SettlementOutcome -> Text
outcomeRecord (Succeeded costs proof) = TE.decodeUtf8 $ BL.toStrict $ encode $ object ["costs" .= costs,"proof" .= proof]
outcomeRecord (Failed _ proof) = proof
outcomeCosts :: SettlementOutcome -> PaymentCosts
outcomeCosts (Succeeded costs _) = costs
outcomeCosts (Failed cost _) = PaymentCosts cost zero
 where zero=either (error . T.unpack) id (amount 0)

-- Replay checks the exact evidence but intentionally does not require a still
-- live fee hold: successful application has already released it. A new outcome
-- requires the live hold and no previous principal winner, even while paused or
-- under source review. Source loss cannot erase an observed outgoing payment.
decideSettlement :: RecordedAttempt -> SettlementFacts -> SettlementOutcome -> Either Text SettlementDecision
decideSettlement expected facts outcome = do
  checkSettlementEvidence expected outcome
  let current=settlementCurrent facts; view=settlementPayment facts
      state=outcomeState outcome; proof=outcomeRecord outcome
      paid=case outcome of Succeeded{}->True; Failed{}->False
  ensure (recordedState expected=="broadcast_intent" && recordedSequence expected/=Nothing
    && paymentId(savedPayment view)==recordedPayment current
    && recordedChain current==(if paymentAsset(savedPayment view)==Native then "Native" else "Solana")
    && current {recordedState=recordedState expected,recordedObservation=recordedObservation expected}==expected)
    "settlement_attempt_changed"
  if recordedState current==state then do
    ensure (recordedObservation current==Just proof) "settlement_evidence_conflict"
    unless paid $ ensure (settlementFailedCharge facts==Just(toInteger $ units $ networkFee $ outcomeCosts outcome)) "failure_evidence_conflict"
    pure SettlementReplay
  else do
    ensure (current==expected && savedStatus view `elem` [PaymentPaying,PaymentReview]) "settlement_not_expected"
    let currency=if recordedChain current=="Native" then Native else Sol
    ensure (case settlementHold facts of Just(asset,n)->asset==currency && n>=recordedFee current; _->False)
      "payment_intent_not_settleable"
    ensure (settlementPriorWinner facts==Nothing) "payment_already_settled"
    let outgoing=savedPayment view
        customer=case paymentFunding outgoing of
          Conversion order _ _ _ -> Just $ CustomerResolution order False (if paid then "Paid" else "NeedsReview")
          Refund order _ _ _ -> Just $ CustomerResolution order True (if paid then "Refunded" else "NeedsReview")
          EarnedFees{} -> Nothing
    pure $ ApplySettlement $ SettlementEffects outcome (if paid then settlement outgoing else []) customer

-- Store checks this before loading the subject, retaining the existing refusal
-- order for malformed evidence. decideSettlement repeats the same pure check;
-- passing it alone is never permission to commit any financial effect.
checkSettlementEvidence :: RecordedAttempt -> SettlementOutcome -> Either Text ()
checkSettlementEvidence expected outcome = case outcome of
  Succeeded costs proof -> ensure (validProof proof && units(networkFee costs)>0
    && toInteger(units $ networkFee costs)+toInteger(units $ accountRent costs)<=toInteger(units $ recordedFee expected)
    && (recordedChain expected=="Solana" || units(accountRent costs)==0)) "settlement_fee_or_evidence_invalid"
  Failed cost proof -> ensure (recordedChain expected=="Solana" && validProof proof
    && units cost>0 && cost<=recordedFee expected) "invalid_failure_evidence"
 where validProof proof=not(T.null proof) && T.length proof<=32768

ensure :: Bool -> Text -> Either Text ()
ensure condition code=unless condition (Left code)

-- Readers bind these observations to the deployment in the same transaction.
-- Missing, duplicate or errored scan rows become Nothing; each pair is time/anchor.
-- Custody is current revision / checked revision / checked time, only if error-free.
data IntakeFacts = IntakeFacts
  { intakeTime :: Int64, intakePaused :: Bool
  , intakeScans :: Maybe ((Int64,Text),(Int64,Text),(Int64,Text))
  , intakeCustody :: Maybe (Int64,Int64,Int64) } deriving (Eq,Show)

checkIntake :: IntakeFacts -> Either Text ()
checkIntake facts = do
  let now=intakeTime facts
  ensure (now>=0) "invalid_order_time"
  ensure (not $ intakePaused facts) "intake_paused"
  checkScans now (intakeScans facts)
  checkCustody now (intakeCustody facts)

freshAt :: Int64 -> Int64 -> Bool
freshAt now at=at>=0 && at<=now && toInteger now-toInteger at<=60
checkScans :: Int64 -> Maybe ((Int64,Text),(Int64,Text),(Int64,Text)) -> Either Text ()
checkScans now scans=ensure (case scans of
    Just(a,b,c)->all (\(at,anchor)->freshAt now at && not(T.null anchor)) [a,b,c]
    Nothing->False) "scanners_not_fresh"
checkCustody :: Int64 -> Maybe (Int64,Int64,Int64) -> Either Text ()
checkCustody now custody=ensure (case custody of Just(revision,checked,at)->revision==checked && freshAt now at; _->False)
    "custody_not_reconciled"

-- Integer totals come from the journal/holds at the durable operating clock.
-- Preparation subtracts only holds it will transfer/release in this transaction.
data FeeBudget = FeeBudget
  { operatingBalance :: Integer, operatingHeld :: Integer
  , operatingSpent :: Integer, operatingDaily :: Amount } deriving (Eq,Show)

checkFeeBudget :: Amount -> FeeBudget -> Either Text ()
checkFeeBudget quantity budget = do
  let needed=toInteger(units quantity); held=operatingHeld budget
  ensure (held>=0) "operating_reservation_missing"
  ensure (operatingBalance budget-held>=needed) "insufficient_fee_budget"
  ensure (operatingSpent budget+held+needed<=toInteger(units $ operatingDaily budget)) "operating_daily_limit"

data PreparationHistory = InitialPreparation | LivePreparation Text PreparedPayment
  | RetiredPreparation Text (Maybe Int) deriving (Eq,Show)
data PriorFeeHold = PriorFeeHold
  { priorFeeAsset :: Asset, priorFeeAmount :: Amount
  , priorFeeReleased :: Bool, priorPreparationExpired :: Bool } deriving (Eq,Show)
data PreparationAdmission = PreparationAdmission
  { preparationIntake :: IntakeFacts, destinationBusy :: Bool, preparationSourceEligible :: Bool
  , priorPreparationFee :: Maybe PriorFeeHold, customerOperatingHold :: Maybe Amount
  , pendingEarnedBalance :: Integer, preparationBudget :: FeeBudget } deriving (Eq,Show)
data PreparationFacts = PreparationFacts
  { preparationPayment :: PaymentView, preparationHistory :: PreparationHistory
  , preparationAdmission :: Maybe PreparationAdmission } deriving (Eq,Show)
data PreparationDecision = ReusePreparation PreparedPayment | CreatePreparation PreparedPayment deriving (Eq,Show)

decidePreparation :: Amount -> Text -> PreparationFacts -> Either Text PreparationDecision
decidePreparation allowance plan facts = do
  checkPreparationInput allowance plan view
  case preparationHistory facts of
    LivePreparation savedChain saved -> do
      ensure (preparedPolicy saved==plan && preparedFee saved==allowance && savedChain==chain
        && preparedView saved==view) "preparation_conflict"
      pure $ ReusePreparation saved
    InitialPreparation->create 0 False
    RetiredPreparation savedChain next->do
      ensure (savedChain==chain) "preparation_retry_requires_recovery"
      generation<-maybe (Left "preparation_retry_not_authorized") Right next
      ensure (generation>0) "preparation_retry_not_authorized"
      create generation True
 where
  view=preparationPayment facts; outgoing=savedPayment view; funding=paymentFunding outgoing
  native=paymentAsset outgoing==Native; chain=if native then "Native" else "Solana"
  currency=if native then Native else Sol
  value=toInteger . units
  checkSource EarnedFees{} _=Right ()
  checkSource _ admitted=ensure (preparationSourceEligible admitted) "source_not_eligible"
  create generation retry = do
    ensure (generation<8) "preparation_generation_limit"
    admitted<-maybe (Left "preparation_admission_missing") Right (preparationAdmission facts)
    checkIntake (preparationIntake admitted)
    ensure (savedStatus view==PaymentReady) "payment_not_ready"
    ensure (not $ destinationBusy admitted) "destination_payment_unresolved"
    released<-if not retry then pure 0 else do
      checkSource funding admitted
      previous<-maybe (Left "preparation_fee_hold_missing") Right (priorPreparationFee admitted)
      ensure (priorFeeAsset previous==currency && units(priorFeeAmount previous)>0
        && priorFeeReleased previous==priorPreparationExpired previous) "preparation_fee_hold_missing"
      pure $ if priorFeeReleased previous then 0 else value(priorFeeAmount previous)
    transferred<-case funding of
      EarnedFees _ _ quantity -> do
        ensure (pendingEarnedBalance admitted>=value quantity) "earned_reservation_missing"
        pure 0
      _ | not retry -> do
        checkSource funding admitted
        quantity<-maybe (Left "operating_reservation_missing") Right (customerOperatingHold admitted)
        ensure (quantity>=allowance) "operating_reservation_missing"
        pure $ value quantity
      _->pure 0
    let budget=preparationBudget admitted; held=operatingHeld budget-released-transferred
    checkFeeBudget allowance budget {operatingHeld=held}
    pure $ CreatePreparation $ PreparedPayment view {savedStatus=PaymentPaying} generation plan Nothing allowance

-- Also used before Store reads the remaining snapshot, preserving input-refusal
-- precedence without another implementation of the monetary limits.
checkPreparationInput :: Amount -> Text -> PaymentView -> Either Text ()
checkPreparationInput allowance plan view = do
  ensure (not(T.null plan) && T.length plan<=16384) "invalid_payment_record"
  decoded<-either (const $ Left "invalid_saved_payment") Right (eitherDecodeStrict' $ TE.encodeUtf8 plan)
  ensure (decoded/=Null) "invalid_payment_record"
  let costs=paymentLimits $ savedTerms view; value=toInteger . units
      bound=if paymentAsset(savedPayment view)==Native then value(savedNativeFee costs)
        else value(savedSolanaFee costs)+value(savedSolanaRent costs)
  ensure (units allowance>0 && value allowance<=bound) "order_fee_limit_exceeded"

-- Native family selection is the latest saved member and whether an unfinished
-- replacement draft exists. Only the native adapter/closed reader derives it.
data SendFacts = SendFacts
  { sendIntake :: IntakeFacts, sendPreparation :: PreparedPayment, sendAttempt :: RecordedAttempt
  , sendSourceEligible :: Bool, sendNativeSelection :: Maybe (Text,Bool)
  , sendReviewSequence :: Int64, sendBackupRequired :: Bool, sendBackupSequence :: Int64 }
  deriving (Eq,Show)
data QueueDecision = ReuseQueue Int64 | CreateQueue deriving (Eq,Show)

sendContext :: SendFacts -> Either Text RecordedAttempt
sendContext facts = do
  checkIntake (sendIntake facts)
  checkSendPayment (sendPreparation facts) (sendAttempt facts) (sendSourceEligible facts) (sendNativeSelection facts)

-- Shared with paused native replacement drafting, which is not intake or send
-- permission and has its own custody/approval checks in the closed operation.
checkSendPayment :: PreparedPayment -> RecordedAttempt -> Bool -> Maybe (Text,Bool) -> Either Text RecordedAttempt
checkSendPayment prepared saved sourceEligible nativeSelection = do
  let view=preparedView prepared; outgoing=savedPayment view
  ensure (savedStatus view==PaymentPaying && recordedPayment saved==paymentId outgoing
    && recordedChain saved==(if paymentAsset outgoing==Native then "Native" else "Solana")
    && recordedGeneration saved==preparedGeneration prepared && recordedFee saved==preparedFee prepared) "payment_not_sendable"
  case paymentFunding outgoing of EarnedFees{}->pure (); _->ensure sourceEligible "source_not_eligible"
  if recordedChain saved=="Native" then do
    (latest,pending)<-maybe (Left "native_replacement_not_current") Right nativeSelection
    ensure (latest==signedId(recordedSigned saved)) "native_replacement_not_current"
    ensure (not pending) "native_replacement_draft_pending"
  else pure ()
  pure saved

decideQueue :: SendFacts -> Either Text QueueDecision
decideQueue facts = do
  saved<-sendContext facts
  case (recordedState saved,recordedSequence saved) of
    ("broadcast_intent",Just sequenceNo)->pure $ ReuseQueue (max sequenceNo $ sendReviewSequence facts)
    ("signed",Nothing)->pure CreateQueue
    _->Left "attempt_not_sendable"

-- No network effect: immediately before sending, the caller must still perform
-- the chain's fresh acceptance/blockhash check and submit these exact saved bytes.
decideSend :: SendFacts -> Either Text RecordedAttempt
decideSend facts = do
  saved<-sendContext facts
  ensure (recordedState saved=="broadcast_intent") "broadcast_intent_required"
  original<-maybe (Left "broadcast_intent_required") Right (recordedSequence saved)
  ensure (not(sendBackupRequired facts) || sendBackupSequence facts>=max original (sendReviewSequence facts)) "backup_pending"
  pure saved

-- Customer admission owns new terms only. An existing capability/idempotency
-- match bypasses this decision and retains its original quote and deadlines.
data OrderLimits = OrderLimits
  { orderMinimum :: Amount, orderMaximum :: Amount, quoteSeconds :: Int64
  , graceSeconds :: Int64, maximumQueued :: Int, nativeDaily :: Amount, solanaDaily :: Amount }
  deriving (Eq,Show)
data OrderAdmissionFacts = OrderAdmissionFacts
  { orderIntake :: IntakeFacts, queuedOrders :: Int, availableFloat :: Integer
  , nativeOrderBudget :: FeeBudget, solanaOrderBudget :: FeeBudget } deriving (Eq,Show)
data OrderAdmission = OrderAdmission
  { admittedQuote :: Quote, admittedDeadline :: Int64, admittedGrace :: Int64
  , admittedCosts :: [(Text,Asset,Amount)] } deriving (Eq,Show)

quoteOrder :: OrderLimits -> W.OrderRequest -> Either Text Quote
quoteOrder limits request = do
  ensure (W.input request>=orderMinimum limits && W.input request<=orderMaximum limits) "amount_outside_limits"
  ensure (W.sourceOwner request==Nothing && (W.direction request/=WrappedToNative || T.null(W.refund request))) "invalid_connection_free_order"
  let address t=not(T.null t) && T.length t<=128 && not(T.any (<= ' ') t)
  ensure (address(W.recipient request) && (W.direction request/=NativeToWrapped || address(W.refund request))) "invalid_destination"
  quote (W.input request)

-- The two alternate payment costs protect conversion and full refund separately.
-- This is not principal inventory or the fee hold for a prepared payment.
orderCostReservations :: Direction -> CostLimits -> Either Text [(Text,Asset,Amount)]
orderCostReservations direction costs = do
  total<-amount (toInteger(units $ W.savedSolanaFee costs)+toInteger(units $ W.savedSolanaRent costs))
  let wrapping=direction==NativeToWrapped
  pure [(if wrapping then "refund" else "conversion",Native,W.savedNativeFee costs)
       ,(if wrapping then "conversion" else "refund",Sol,total)]

shouldExpireQuote :: Int64 -> Int64 -> Bool -> Either Text Bool
shouldExpireQuote now grace hasReceipt = do
  ensure (now>=0) "invalid_order_time"
  pure (now>grace && not hasReceipt)

decideOrder :: OrderLimits -> CostLimits -> W.OrderRequest -> OrderAdmissionFacts -> Either Text OrderAdmission
decideOrder limits costs request facts = do
  checkIntake (orderIntake facts)
  quoted<-quoteOrder limits request
  ensure (queuedOrders facts<maximumQueued limits) "queue_full"
  ensure (availableFloat facts>=toInteger(units $ net quoted)) "insufficient_inventory"
  let now=intakeTime $ orderIntake facts
      deadline=toInteger now+toInteger(quoteSeconds limits); grace=deadline+toInteger(graceSeconds limits)
  ensure (now>=0 && grace<=toInteger(maxBound::Int64)) "invalid_order_time"
  allocations<-orderCostReservations (W.direction request) costs
  forM_ allocations $ \(_,asset,n)->checkFeeBudget n (if asset==Native then nativeOrderBudget facts else solanaOrderBudget facts)
  pure $ OrderAdmission quoted (fromInteger deadline) (fromInteger grace) allocations

data AllocationClaim = AllocationClaim { allocationLabel :: Text, mayAllocate :: Bool }
  deriving (Eq,Show)
data InstructionFacts = InstructionFacts
  { instructionDirection :: Direction, instructionStatus :: Text, instructionDeadline :: Int64
  , savedInstruction :: Maybe Text, savedInstructionSequence :: Maybe Int64, instructionIssued :: Int64 }
  deriving (Eq,Show)
data InstructionChange = KeepInstruction Int64 | SaveInstruction deriving (Eq,Show)

-- Reusing a claim never permits another allocation, even after its deadline.
-- Only the closed operation may save a new claim before the external RPC call.
decideNativeClaim :: Text -> Maybe Text -> InstructionFacts -> Maybe IntakeFacts -> Either Text AllocationClaim
decideNativeClaim label previous facts readiness = do
  ensure (instructionDirection facts==NativeToWrapped && savedInstruction facts==Nothing) "invalid_native_provisioning_order"
  case previous of
    Just saved->ensure (saved==label) "allocation_label_mismatch" >> pure (AllocationClaim label False)
    Nothing->checkProvisioning facts readiness >> pure (AllocationClaim label True)

checkNativeAllocation :: Maybe Text -> Text -> Text -> InstructionFacts -> Either Text ()
checkNativeAllocation previous label address facts =
  ensure (previous==Just label && instructionDirection facts==NativeToWrapped && not(T.null address)
    && T.length address<=128 && not(T.any (<= ' ') address)) "invalid_native_allocation_result"

checkSolanaBinding :: InstructionFacts -> Maybe IntakeFacts -> Either Text ()
checkSolanaBinding facts readiness = do
  ensure (instructionDirection facts==WrappedToNative) "invalid_solana_provisioning_order"
  unless (savedInstruction facts/=Nothing) (checkProvisioning facts readiness)

checkProvisioning :: InstructionFacts -> Maybe IntakeFacts -> Either Text ()
checkProvisioning facts readiness = do
  intake<-maybe (Left "deposit_window_closed") Right readiness
  checkIntake intake
  ensure (instructionStatus facts=="Provisioning" && intakeTime intake<=instructionDeadline facts) "deposit_window_closed"

decideInstruction :: InstructionFacts -> Text -> Either Text InstructionChange
decideInstruction facts instruction = case (savedInstruction facts,savedInstructionSequence facts) of
  (Just old,Just n)->ensure (old==instruction && n>0) "instruction_is_immutable" >> pure (KeepInstruction n)
  (Nothing,Nothing)->ensure (instructionStatus facts `elem` ["Provisioning","ExpiredUnfunded"])
    "order_no_longer_provisioning" >> pure SaveInstruction
  _->Left "invalid_instruction_state"

-- Instructions may be allocated before exposure, but coverage must be durable
-- before returning them. Previously issued instructions retain their saved terms.
decideInstructionIssue :: Bool -> Int64 -> InstructionFacts -> Maybe (IntakeFacts,[Text],[Text]) -> Either Text Bool
decideInstructionIssue backed coverage facts admission = do
  sequenceNo<-maybe (Left "instruction_not_recorded") Right (savedInstructionSequence facts)
  ensure (sequenceNo>0 && savedInstruction facts/=Nothing && instructionIssued facts `elem` [0,1]) "invalid_instruction_state"
  ensure (not backed || coverage>=sequenceNo) "backup_pending"
  if instructionIssued facts==1 then pure False else do
    (intake,principal,costs)<-maybe (Left "quote_reservations_unavailable") Right admission
    checkIntake intake
    ensure (instructionStatus facts=="AwaitingDeposit" && intakeTime intake<=instructionDeadline facts) "deposit_window_closed"
    ensure (principal==["quote"] && costs==["quote","quote"]) "quote_reservations_unavailable"
    pure True

-- Allocation/eligibility are checked before this snapshot is loaded. A receipt
-- that cannot convert remains a liability; Nothing requests review, not disposal.
data PromotionFacts = PromotionFacts
  { promotionOrder :: W.OrderView, promotionReceipt :: W.Deposit
  , promotionGrace :: Int64, conversionExists :: Bool } deriving (Eq,Show)

decidePromotion :: Text -> Int64 -> PromotionFacts -> Either Text (Maybe Payment)
decidePromotion identity now facts = do
  ensure (now>=0) "invalid_promotion_time"
  let order=promotionOrder facts; request=W.request order; quoted=W.quote order
      receipt=promotionReceipt facts; policy=W.policy order; direction=W.direction request
  ensure (W.input request==gross quoted && W.deploymentFingerprint policy==identity) "saved_order_terms_mismatch"
  let exact=W.depositOrder receipt==Just(W.orderId order) && W.depositAmount receipt==gross quoted && W.depositAsset receipt==sourceAsset direction
      eligible=W.depositEligible receipt && (W.depositAsset receipt/=Native || W.depositConfirmations receipt>=W.nativeDepth policy)
      timely=W.depositSeenAt receipt>=0 && W.depositSeenAt receipt<=W.deadline order && now<=promotionGrace facts
      pending=W.status order `elem` ["Provisioning","AwaitingDeposit"] && W.depositInstruction order/=Nothing
  if not (exact && eligible && timely && pending && not(conversionExists facts)) then pure Nothing else
    Just <$> (conversion (W.orderId order) (W.depositId receipt) direction quoted >>= \funding->
      payment ("convert:"<>W.orderId order) funding (W.recipient request))

-- Persisted integer decoding and the alternate-cost formula are shared by
-- promotion and refund. No current configuration can reprice these saved costs.
savedCostLimits :: Int64 -> Int64 -> Int64 -> Either Text CostLimits
savedCostLimits native sol rent = do
  ensure (native>0 && sol>0 && rent>=0) "invalid_order_cost_policy"
  CostLimits <$> amount(toInteger native) <*> amount(toInteger sol) <*> amount(toInteger rent)

checkPromotionHolds :: W.OrderView -> CostLimits -> [(Text,Int64,Text)] -> [(Text,Text,Int64,Text)] -> Either Text ()
checkPromotionHolds order costs principal operating = do
  let direction=W.direction(W.request order)
  ensure (principal==[(T.pack(show $ destinationAsset direction),units(net $ W.quote order),"quote")]) "reservation_not_provisional"
  expected<-orderCostReservations direction costs
  ensure (sort operating==sort [(purpose,T.pack(show asset),units n,"quote") | (purpose,asset,n)<-expected]) "operating_reservation_not_provisional"

data RefundFacts = RefundFacts
  { refundUnresolved :: Bool, refundObligations :: [(Text,Text,Text)]
  , refundDestination :: Text, refundHold :: [(Text,Int64,Text)]
  , refundBudget :: Maybe FeeBudget } deriving (Eq,Show)

checkRefundSource :: Text -> W.OrderRequest -> W.PolicySnapshot -> W.Deposit -> Either Text ()
checkRefundSource identity request policy receipt = do
  ensure (W.deploymentFingerprint policy==identity && W.depositAsset receipt==sourceAsset(W.direction request)) "unsupported_refund_asset"
  ensure (W.depositEligible receipt && (W.depositAsset receipt/=Native || W.depositConfirmations receipt>=W.nativeDepth policy)) "source_not_eligible"

-- No payment may still be able to execute. An already-paid conversion from a
-- different receipt is retained; the same receipt can never fund another payout.
refundableWork :: Text -> Bool -> [(Text,Text,Text)] -> Either Text [Text]
refundableWork receipt unresolved obligations = do
  ensure (not unresolved) "refund_would_race_payment"
  ensure (all (\(_,source,state)->source==receipt || state=="paid") obligations) "other_obligation_must_resolve_before_refund"
  let active=[(key,state) | (key,source,state)<-obligations,source==receipt]
  ensure (length active<=1 && all ((`elem` ["ready","review"]).snd) active) "principal_already_resolved"
  pure (map fst active)

decideRefund :: W.OrderRequest -> W.Deposit -> CostLimits -> RefundFacts -> Either Text Payment
decideRefund request receipt costs facts = do
  _<-refundableWork (W.depositId receipt) (refundUnresolved facts) (refundObligations facts)
  allocations<-orderCostReservations (W.direction request) costs
  (asset,allowance)<-case [(a,n) | ("refund",a,n)<-allocations] of [one]->Right one; _->Left "invalid_order_cost_policy"
  phase<-case refundHold facts of
    [(a,n,p)] | a==T.pack(show asset) && n==units allowance->Right p
    _->Left "operating_reservation_missing"
  unless (phase `elem` ["quote","obligation"]) $ do
    ensure (phase `elem` ["released","transferred"]) "invalid_reservation_phase"
    budget<-maybe (Left "operating_reservation_missing") Right (refundBudget facts)
    checkFeeBudget allowance budget
  let destination=refundDestination facts
  ensure (not(T.null destination) && T.length destination<=128) "invalid_destination"
  order<-maybe (Left "refundable_deposit_not_found") Right (W.depositOrder receipt)
  funding<-refund order (W.depositId receipt) (W.depositAsset receipt) (W.depositAmount receipt)
  payment ("refund:"<>W.depositId receipt) funding destination

data OperatorFacts = OperatorFacts
  { operatorTime :: Int64, operatorPaused :: Bool, operatorCustody :: Maybe (Int64,Int64,Int64) }
  deriving (Eq,Show)
checkOperator :: Text -> OperatorFacts -> Either Text ()
checkOperator code facts = do
  ensure (operatorPaused facts) code
  checkCustody (operatorTime facts) (operatorCustody facts)
checkReason :: Text -> Either Text ()
checkReason reason=ensure (not(T.null $ T.strip reason) && T.length reason<=512) "invalid_reason"

data WithdrawalView = WithdrawalView
  { withdrawalPayment :: Payment, withdrawalTerms :: PaymentTerms, withdrawalReason :: Text
  , withdrawalSequence :: Int64, withdrawalCancellation :: Maybe (Text,Int64) } deriving (Eq,Show)
data WithdrawalWork = UnpreparedWithdrawal | WithdrawalWork
  { unsignedCancellation :: Bool, withdrawalPaused :: Bool } deriving (Eq,Show)

withdrawalInput :: Amount -> Int64 -> Text -> Asset -> Amount -> Text -> Text -> Either Text Payment
withdrawalInput maximumAmount now key currency n destination reason = do
  checkReason reason
  ensure (now>=0 && T.length key==64 && T.all (`elem` ("0123456789abcdef"::String)) key && n<=maximumAmount) "invalid_fee_withdrawal"
  earnedFees key currency n >>= \funding->payment ("fee:"<>key) funding destination

decideWithdrawal :: Payment -> PaymentTerms -> Text -> Maybe WithdrawalView -> Maybe (OperatorFacts,Integer) -> Either Text Bool
decideWithdrawal outgoing terms reason previous admission = case previous of
  Just saved->do
    ensure (withdrawalPayment saved==outgoing && withdrawalTerms saved==terms && withdrawalReason saved==reason) "fee_withdrawal_conflict"
    pure False
  Nothing->do
    (operator,earned)<-maybe (Left "insufficient_earned_fees") Right admission
    checkOperator "fee_withdrawal_requires_pause" operator
    ensure (earned>=toInteger(units $ paymentAmount outgoing)) "insufficient_earned_fees"
    pure True

decideWithdrawalCancellation :: Text -> WithdrawalView -> WithdrawalWork -> Either Text Bool
decideWithdrawalCancellation reason saved work = do
  checkReason reason
  case withdrawalCancellation saved of
    Just (old,_)->ensure (old==reason) "fee_withdrawal_cancellation_conflict" >> pure False
    Nothing->do
      case work of
        UnpreparedWithdrawal->pure ()
        WithdrawalWork cleaned paused->do
          ensure cleaned "fee_withdrawal_payment_exists"
          ensure paused "pause_before_operator_action"
      pure True

data TreasuryFacts = TreasuryFacts
  { treasuryOperator :: OperatorFacts, treasuryReceipt :: W.Deposit
  , treasuryAllocated :: Bool, treasuryLinked :: Bool } deriving (Eq,Show)

treasurySplit :: [(Text,Amount)] -> Either Text [(Account,Amount)]
treasurySplit split = do
  let entries=sortOn fst split; names=map fst entries
      accounts=[("float",Float),("backing",Backing),("operating",Operating),("lp",Liquidity)]
  ensure (not(null entries) && length entries<=4 && length(nub names)==length names
    && all (`elem` map fst accounts) names && all ((>0).units.snd) entries) "invalid_treasury_allocation"
  traverse (\(name,n)->maybe (Left "invalid_treasury_allocation") (Right . (,n)) $ lookup name accounts) entries

decideTreasury :: W.PolicySnapshot -> [(Text,Amount)] -> TreasuryFacts -> Either Text [Posting]
decideTreasury policy split facts = do
  allocations<-treasurySplit split
  checkOperator "treasury_allocation_requires_pause" (treasuryOperator facts)
  let receipt=treasuryReceipt facts; currency=W.depositAsset receipt; quantity=toInteger(units $ W.depositAmount receipt)
  ensure (W.depositOrder receipt==Nothing && W.depositEligible receipt && not(treasuryAllocated facts)) "receipt_not_available_for_treasury"
  ensure (currency/=Native || W.depositConfirmations receipt>=W.nativeDepth policy) "treasury_receipt_underconfirmed"
  ensure (sum(map (toInteger.units.snd) allocations)==quantity) "treasury_allocation_amount_mismatch"
  ensure (currency/=Sol || map fst allocations==[Operating]) "sol_reserved_for_operating"
  ensure (not $ treasuryLinked facts) "receipt_has_customer_obligation"
  pure (Posting currency Unallocated (-quantity):[Posting currency account (toInteger $ units n) | (account,n)<-allocations])

-- Free allocations exclude all live customer/fee holds before this decision.
-- Backing, LP, principal and earned balances are never candidates for these costs.
decideTreasurySpend :: (Asset,Amount,Amount) -> Integer -> Integer -> Either Text [Posting]
decideTreasurySpend (currency,outflow,fee) freeFloat freeOperating = do
  let total=toInteger(units outflow); charge=toInteger(units fee)
      costs=case currency of Native->[(Float,total-charge),(Operating,charge)]; Wrapped->[(Float,total)]; Sol->[(Operating,total)]
  forM_ costs $ \(account,cost)->ensure (cost>=0 && (if account==Float then freeFloat else freeOperating)>=cost) "treasury_spend_exceeds_free_allocation"
  pure ([Posting currency account (-cost) | (account,cost)<-costs]<>[Posting currency External total])

data CustomerKind = CustomerConversion | CustomerRefund deriving (Eq,Show)
data CustomerPayment = CustomerPayment
  { customerReceipt :: Text, customerKind :: CustomerKind, customerState :: PaymentStatus
  , customerWork :: Maybe Bool, customerSettlement :: Maybe (Text,Int64) } deriving (Eq,Show)

-- Nothing/Just False/Just True describes no active preparation, unsigned work,
-- or retained signed work. A settlement binds the current winner to the original
-- principal event's posting ordinal. Winner replacement never changes that order.
-- These display facts grant no payment/signing authority.
projectCustomer :: Text -> Bool -> [CustomerPayment] -> Either Text (Text,Maybe Text)
projectCustomer admission recoveryReview payments = do
  ensure (admission `elem` ["Provisioning","AwaitingDeposit","ExpiredUnfunded","NeedsReview","Ready","Preparing","Paying","Refunding","Refunded","Paid"])
    "unknown_order_status"
  ensure (length [() | p<-payments,customerKind p==CustomerConversion]<=1) "ambiguous_customer_payments"
  forM_ payments $ \p->do
    let settled=customerSettlement p/=Nothing; active=customerWork p/=Nothing
    ensure (settled==(customerState p==PaymentPaid) && (not settled || not active)
      && (customerState p/=PaymentPaying || active)
      && (customerState p `notElem` [PaymentReady,PaymentCancelled] || not active)) "customer_payment_state_inconsistent"
    forM_ (customerSettlement p) $ \(tx,n)->ensure (not(T.null tx) && n>0) "customer_settlement_missing"
  let paid=[(customerKind p,tx,n) | p<-payments,Just(tx,n)<-[customerSettlement p]]
      conversions=[tx | (CustomerConversion,tx,_)<-paid]
      refunds=sortOn (negate . snd) [(tx,n) | (CustomerRefund,tx,n)<-paid]
      ordinals=[n | (_,_,n)<-paid]
      unfinished=[p | p<-payments,customerState p `notElem` [PaymentPaid,PaymentCancelled]]
      review=recoveryReview || admission=="NeedsReview" || any ((==PaymentReview).customerState) payments
  ensure (length(nub ordinals)==length ordinals && length unfinished<=1) "ambiguous_customer_payments"
  let payout=case conversions of tx:_->Just tx; []->case refunds of (tx,_):_->Just tx; []->Nothing
  status<-if review then Right "NeedsReview" else case conversions of
    [_]->Right "Paid"
    _->case unfinished of
      [p]->case customerWork p of
        Just signed->Right (if signed then "Paying" else "Preparing")
        Nothing->Right (if customerKind p==CustomerRefund then "Refunding" else "Ready")
      [] | not(null refunds)->Right "Refunded"
         | admission `elem` ["Provisioning","AwaitingDeposit","ExpiredUnfunded"]->Right admission
         | otherwise->Left "customer_payment_state_inconsistent"
      _->Left "ambiguous_customer_payments"
  pure (status,payout)

-- Keep a bounded display summary while Store walks immutable, ordered pages.
-- Each principal ordinal belongs to one payment through its unique attempt/event
-- binding. Completed older refunds and cancelled refund work cannot change the
-- displayed winner; retained conversions and unfinished work must stay explicit.
compactCustomerPayments :: [CustomerPayment] -> Either Text [CustomerPayment]
compactCustomerPayments payments = do
  _<-projectCustomer "AwaitingDeposit" False payments
  let refunds=[p | p<-payments,customerKind p==CustomerRefund,customerState p==PaymentPaid]
      retained=[p | p<-payments,customerKind p==CustomerConversion || customerState p `notElem` [PaymentPaid,PaymentCancelled]]
  pure (retained<>take 1 (sortOn (negate . maybe 0 snd . customerSettlement) refunds))
