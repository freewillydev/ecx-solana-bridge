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
  , scanAssets, scanFacts, checkScanBatch, checkScan, ObservationFacts(..), checkObservation, observationNeedsReview
  , CleanupPhase(..), CancellationFacts(..), CancellationDecision(..), decideCancellation
  , ExpiryFacts(..), decideSolanaExpiry, RetryFacts(..), decideSolanaRetry
  , checkReplacementParent, checkReplacementDraft, checkReplacementSigning
  , NativeSettlementCheck(..), NativeWinnerFacts(..), NativeWinnerEffect(..), decideNativeWinner, decideNativeReview
  , SourceEffect(..), decideSourceCheck, sourceReturnPostings, LossCoverFacts(..), decideLossCover
  , SourceApprovalFacts(..), checkSourceApprovalSource, decideSourceApproval, RebroadcastFacts(..), checkRebroadcast
  , GenerationEnd(..), successorGeneration
  ) where

import Bridge.Domain hiding (fee)
import Bridge.Wire (PaymentTerms(..),CostLimits(..),SignedAttempt(..),PaymentCosts(..))
import qualified Bridge.Wire as W
import Control.Monad (unless,forM_)
import Data.Aeson (Value(Null),eitherDecodeStrict',encode,object,(.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
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

-- Observations can retain evidence and require review, never authorize payment.
-- The cursor, original scan anchor and all evidence commit in one transaction.
scanAssets :: [(Text,Asset)]
scanAssets=[("Native",Native),("Solana",Wrapped),("SolanaOperating",Sol)]
scanFacts :: [(Text,Maybe Int64,Maybe Text,Text)] -> Maybe ((Int64,Text),(Int64,Text),(Int64,Text))
scanFacts [("Native",Just n,Nothing,a),("Solana",Just t,Nothing,b),("SolanaOperating",Just s,Nothing,c)] = Just((n,a),(t,b),(s,c))
scanFacts _ = Nothing

checkScanBatch :: W.ScanBatch -> Either Text ()
checkScanBatch batch = do
  ensure (W.scanChain batch `elem` map fst scanAssets && W.scanTime batch>=0
    && length(W.scanDeposits batch)<=1000 && length(W.scanEvents batch)<=1000) "invalid_scan_batch"
  ensure (all (\anchor->not(T.null anchor) && T.length anchor<=128) [W.scanOrigin batch,W.scanNext batch]) "invalid_scan_anchor"
  ensure (all (\d->Just(W.depositAsset d)==lookup (W.scanChain batch) scanAssets) (W.scanDeposits batch)) "scan_asset_mismatch"
checkScan :: W.ScanBatch -> Maybe Text -> [Text] -> Either Text ()
checkScan batch previous origins = do
  checkScanBatch batch
  ensure (previous==W.scanPrevious batch) "stale_scan_cursor"
  case origins of
    []->pure ()
    [saved]->ensure (saved==W.scanOrigin batch) "scan_origin_mismatch"
    _->Left "duplicate_scan_origin"

data ObservationFacts = ObservationFacts
  { observationAttempts :: [(Text,Maybe Int64,Maybe Text)], observationFormerWinners :: [Text]
  , observationTreasury :: [(Text,Text)] } deriving (Eq,Show)
checkObservation :: Text -> W.ChainEvent -> Either Text Text
checkObservation chain event = do
  let identifier=W.chainEventId event; anchor=W.chainEventAnchor event; kind=W.chainEventKind event; proof=W.chainEventEvidence event
      encoded=TE.decodeUtf8 . BL.toStrict . encode
      evidence=encoded $ object ["chain" .= chain,"id" .= identifier,"anchor" .= anchor,"kind" .= kind,"proof" .= proof]
  ensure (not(T.null identifier) && T.length identifier<=128 && T.length anchor<=128) "invalid_observation_identity"
  ensure (kind `elem` ["incoming","unmatched_incoming","outgoing","failed","reference","unsupported","unclassified","awaiting_verifier","disputed"]) "invalid_observation_kind"
  ensure (T.length evidence<=8192) "observation_evidence_too_large"
  pure evidence
observationNeedsReview :: Text -> W.ChainEvent -> ObservationFacts -> Bool
observationNeedsReview chain event facts =
  kind `elem` ["unsupported","unclassified","disputed"] || kind=="outgoing" && not known && not approved
 where
  kind=W.chainEventKind event
  known=any (\(state,sequenceNo,observed)->state `elem` ["broadcast_intent","settled","failed"] ||
    state=="review" && chain=="Native" && maybe False (>0) sequenceNo
      && maybe False (`elem` observationFormerWinners facts) observed) (observationAttempts facts)
  approved=case W.economicOutflow chain (W.chainEventEvidence event) of
    Right economic->observationTreasury facts==[(W.chainEventAnchor event,TE.decodeUtf8 $ BL.toStrict $ encode economic)]
    Left _->False

data CleanupPhase = BeginCleanup | FinishCleanup deriving (Eq,Show)
data CancellationFacts = CancellationFacts
  { cancellationOperator :: OperatorFacts, cancellationPrevious :: Maybe (Text,Text,Bool)
  , cancellationUnsigned :: Maybe PreparedPayment, cancellationSourceEligible :: Bool } deriving (Eq,Show)
data CancellationDecision = KeepCancellation | RequestCancellation | CompleteCancellation Bool deriving (Eq,Show)

-- Only the closed reader can supply current unsigned work. Begin requires fresh
-- custody; finish instead requires the exact saved cleanup to have returned.
-- Its caller performs cleanup between commits; an unknown result never finishes.
decideCancellation :: CleanupPhase -> PreparedPayment -> Text -> Text -> CancellationFacts -> Either Text CancellationDecision
decideCancellation phase expected reason cleanup facts = do
  let operator=cancellationOperator facts
      current=ensure (cancellationUnsigned facts==Just expected) "preparation_cancellation_not_expected"
  ensure (preparedGeneration expected>=0 && preparedGeneration expected<8) "invalid_preparation_generation"
  ensure (operatorPaused operator) "pause_before_operator_action"
  case cancellationPrevious facts of
    Just(old,plan,done)->do
      ensure (old==reason && plan==cleanup) "preparation_cancellation_conflict"
      if phase==BeginCleanup || done then pure KeepCancellation else do
        current
        pure $ CompleteCancellation (cancellationSourceEligible facts && preparedGeneration expected<7)
    Nothing->do
      ensure (phase==BeginCleanup) "preparation_cancellation_not_expected"
      checkOperator "pause_before_operator_action" operator
      current
      pure RequestCancellation

data ExpiryFacts = ExpiryFacts
  { expiryCurrent :: RecordedAttempt, expiryPreparation :: PreparedPayment
  , expiryUnretiredAttempts :: [Text] } deriving (Eq,Show)
-- The chain verifier must establish complete finalized absence first. This
-- transition retires only that generation, preserves bytes and grants no retry.
decideSolanaExpiry :: RecordedAttempt -> Text -> Maybe Text -> Maybe ExpiryFacts -> Either Text Bool
decideSolanaExpiry expected proof previous facts = do
  ensure (recordedChain expected=="Solana" && recordedState expected `elem` ["signed","broadcast_intent"]) "invalid_solana_expiry"
  case previous of
    Just old->ensure (old==proof) "expiry_evidence_conflict" >> pure False
    Nothing->do
      saved<-maybe (Left "expiry_attempt_changed") Right facts
      let prepared=expiryPreparation saved
      ensure (expiryCurrent saved==expected && preparedGeneration prepared==recordedGeneration expected
        && paymentId(savedPayment $ preparedView prepared)==recordedPayment expected
        && expiryUnretiredAttempts saved==[signedId $ recordedSigned expected]) "expiry_attempt_changed"
      pure True

data RetryFacts = RetryFacts
  { retryOperator :: OperatorFacts, retryCurrent :: RecordedAttempt, retryExpiry :: Maybe Text
  , retryHistory :: [(Int64,Maybe Text,Int64,Int64)], retryPayment :: PaymentView
  , retrySourceEligible :: Bool } deriving (Eq,Show)
-- Approval is distinct from observing expiry. A new generation still goes
-- through ordinary preparation, current source, budget, backup and signing gates.
decideSolanaRetry :: RecordedAttempt -> Text -> Maybe Text -> Maybe RetryFacts -> Either Text Bool
decideSolanaRetry expected reason previous facts = case previous of
  Just old->ensure (old==reason) "retry_approval_conflict" >> pure False
  Nothing->do
    saved<-maybe (Left "solana_retry_not_expected") Right facts
    checkOperator "pause_before_operator_action" (retryOperator saved)
    let generation=recordedGeneration expected; rows=retryHistory saved; view=retryPayment saved
    ensure (retryCurrent saved==expected && recordedChain expected=="Solana" && recordedState expected=="review"
      && retryExpiry saved/=Nothing && not(null rows)
      && maximum(map (\(g,_,_,_)->g) rows)==fromIntegral generation
      && (fromIntegral generation,Just(signedId $ recordedSigned expected),0,1) `elem` rows && generation>=0 && generation<7
      && savedStatus view==PaymentReview && paymentId(savedPayment view)==recordedPayment expected) "solana_retry_not_expected"
    ensure (retrySourceEligible saved) "source_not_eligible"
    pure True

-- Protocol validation of family inputs/outputs/fees remains in NativePayment.
-- These checks bind that verified family to the current durable payment.
checkReplacementParent :: RecordedAttempt -> [RecordedAttempt] -> Either Text ()
checkReplacementParent parent family = do
  ensure (recordedChain parent=="Native" && recordedState parent=="broadcast_intent"
    && maybe False (>0) (recordedSequence parent)) "native_replacement_not_expected"
  ensure (case reverse family of current:_->current==parent; _->False) "native_replacement_not_current"
checkReplacementDraft :: OperatorFacts -> RecordedAttempt -> [RecordedAttempt] -> Int -> Either Text ()
checkReplacementDraft operator parent family drafts = do
  ensure (operatorPaused operator) "pause_before_operator_action"
  checkReplacementParent parent family
  ensure (length family<8) "native_replacement_not_current"
  ensure (drafts>=0 && drafts<7) "native_replacement_draft_limit"
  checkCustody (operatorTime operator) (operatorCustody operator)
checkReplacementSigning :: PreparedPayment -> RecordedAttempt -> [RecordedAttempt] -> Bool -> (Text,Text) -> Either Text ()
checkReplacementSigning prepared parent family eligible (expectedHash,currentHash) = do
  checkReplacementParent parent family
  ensure (recordedPayment parent==paymentId(savedPayment $ preparedView prepared)
    && recordedGeneration parent==preparedGeneration prepared && recordedFee parent==preparedFee prepared
    && savedStatus(preparedView prepared)==PaymentPaying) "native_replacement_not_expected"
  ensure eligible "source_not_eligible"
  ensure (currentHash==expectedHash) "native_replacement_work_changed"

data NativeSettlementCheck = NativeConfirming | NativeUnavailable Text
  | NativeReconfirmed PaymentCosts Text
  | NativeWinnerChanged [RecordedAttempt] Text PaymentCosts Text deriving (Eq,Show)
data NativeWinnerFacts = NativeWinnerFacts
  { formerWinner :: RecordedAttempt, verifiedFamily :: [RecordedAttempt], formerCosts :: PaymentCosts } deriving (Eq,Show)
data NativeWinnerEffect = NativeWinnerEffect
  { changedWinner :: RecordedAttempt, changedObservation :: Text
  , changedFee :: Integer, winnerPostings :: [Posting] } deriving (Eq,Show)

-- The original principal event is never an output of a winner change. The
-- chain adapter verifies the actual winner/fee; this decision only adjusts costs.
decideNativeWinner :: [RecordedAttempt] -> Text -> PaymentCosts -> Text -> NativeWinnerFacts -> Either Text NativeWinnerEffect
decideNativeWinner expected winnerId costs proof facts = do
  let old=formerWinner facts; family=verifiedFamily facts
  ensure (family==expected && winnerId/=signedId(recordedSigned old) && old `elem` family) "native_replacement_family_changed"
  winner<-case [a | a<-family,signedId(recordedSigned a)==winnerId] of
    [a]->Right a; _->Left "native_family_winner_missing"
  ensure (recordedState winner `elem` ["broadcast_intent","review"] && maybe False (>0) (recordedSequence winner)) "unrecorded_broadcast_observed"
  let saved=outcomeRecord (Succeeded costs proof)
      delta=toInteger(units $ networkFee costs)-toInteger(units $ networkFee $ formerCosts facts)
  ensure (recordedChain old=="Native" && recordedState old=="settled" && recordedChain winner=="Native"
    && recordedPayment winner==recordedPayment old && units(accountRent costs)==0
    && units(accountRent $ formerCosts facts)==0 && units(networkFee costs)>0 && networkFee costs<=recordedFee winner
    && units(networkFee $ formerCosts facts)>0 && networkFee(formerCosts facts)<=recordedFee old && T.length saved<=32768
    && delta/=0 && abs delta<=toInteger(maxBound::Int64)) "invalid_native_settlement"
  pure $ NativeWinnerEffect winner saved delta [Posting Native Operating (negate delta),Posting Native External delta]

decideNativeReview :: NativeSettlementCheck -> Text -> [(Text,Text)] -> Either Text (Maybe (Text,Text))
decideNativeReview result previous old = do
  (state,saved)<-case result of
    NativeConfirming->Right("confirming",object ["reason" .= ("native_confirmation_policy_pending"::Text)])
    NativeUnavailable reason->do
      ensure (not(T.null reason) && T.length reason<=160) "invalid_native_recovery_reason"
      pure ("unavailable",object ["reason" .= reason])
    NativeReconfirmed costs proof->Right("reconfirmed",object ["costs" .= costs,"proof" .= proof])
    NativeWinnerChanged{}->Left "invalid_native_settlement"
  let encoded=TE.decodeUtf8 $ BL.toStrict $ encode saved
      base (A.Object fields)=A.Object $ foldr KM.delete fields ["rebroadcastRecovery","operatorReason","rebroadcastProof"]
      base other=other
  ensure (T.length encoded<=32768) "invalid_payment_record"
  unchanged<-case old of
    [(status,raw)] | status==state->do
      value<-either (const $ Left "corrupt_ledger_json") Right (eitherDecodeStrict' $ TE.encodeUtf8 raw)
      pure (base value==saved)
    []->pure (state=="reconfirmed" && previous==encoded)
    [_]->pure False
    _->Left "duplicate_native_recovery_state"
  pure $ if unchanged then Nothing else Just(state,encoded)

data SourceEffect = SourceEffect
  { sourceState :: Text, sourceLoss :: Int64, sourceCheckEvidence :: Text
  , sourceLossDelta :: Integer, sourcePostings :: [Posting] } deriving (Eq,Show)
decideSourceCheck :: W.Deposit -> Bool -> Maybe (Text,Int64,Text) -> W.SourceCheck -> Either Text (Maybe SourceEffect)
decideSourceCheck source allocated old result = do
  let eligible=W.depositEligible source; asset=W.depositAsset source
      previousLoss=maybe 0 (\(_,n,_)->n) old
  (state,loss,proof)<-case result of
    W.SourcePending p->ensure (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure("pending",0,p)
    W.SourceMissing p->ensure (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure("missing",units $ W.depositAmount source,p)
    W.SourceRestored p->ensure eligible "source_recovery_scan_not_current" >> pure("restored",0,p)
    W.SourceUnavailable p->pure("unavailable",previousLoss,p)
  let evidence=TE.decodeUtf8 $ BL.toStrict $ encode proof
      ordinary=old==Nothing && not allocated && state=="pending"
      unchanged=maybe False (\(s,n,p)->s==state && n==loss && (state/="unavailable" || p==evidence)) old
      delta=toInteger loss-toInteger previousLoss
  ensure (proof/=Null && T.length evidence<=16384) "invalid_source_recovery_evidence"
  pure $ if ordinary || unchanged then Nothing else Just $ SourceEffect state loss evidence delta
    (if delta==0 then [] else [Posting asset SourceDeficit (negate delta),Posting asset External delta])

sourceReturnPostings :: Asset -> Integer -> (Int64,Int64,Int64) -> Either Text [Posting]
sourceReturnPostings asset returned (quantity,capital,earned) = do
  ensure (toInteger quantity==returned && toInteger capital+toInteger earned==returned) "source_loss_return_mismatch"
  pure [Posting asset Float (toInteger capital),Posting asset Earned (toInteger earned),Posting asset SourceDeficit (negate returned)]

data LossCoverFacts = LossCoverFacts
  { lossCurrent :: W.Deposit, lossLatest :: Maybe (Int64,Int64), lossAlreadyCovered :: Bool
  , lossCustody :: Maybe (Int64,Int64,Int64), lossFreeFloat :: Integer, lossEarned :: Integer } deriving (Eq,Show)
decideLossCover :: W.Deposit -> Int64 -> Int64 -> Amount -> Amount -> LossCoverFacts -> Either Text [Posting]
decideLossCover source recovery now capital earned facts = do
  let quantity=units(W.depositAmount source); fromFloat=toInteger(units capital); fromEarned=toInteger(units earned)
  ensure (W.depositAsset source==Native && not(W.depositEligible source) && lossCurrent facts==source
    && lossLatest facts==Just(quantity,recovery)) "source_loss_not_proven"
  ensure (fromFloat+fromEarned==toInteger quantity) "source_loss_allocation_mismatch"
  ensure (not $ lossAlreadyCovered facts) "source_loss_already_covered"
  ensure (case lossCustody facts of Just(current,checked,at)->current==checked && freshAt now at; _->False) "source_loss_custody_not_current"
  ensure (lossFreeFloat facts>=fromFloat && lossEarned facts>=fromEarned) "insufficient_loss_capital"
  pure [Posting Native Float (-fromFloat),Posting Native Earned (-fromEarned),Posting Native SourceDeficit (toInteger quantity)]

data SourceApprovalFacts = SourceApprovalFacts
  { approvalStatus :: PaymentStatus, approvalSource :: W.Deposit
  , approvalLatest :: Maybe (Text,Int64,Int64), approvalCover :: Maybe Int64
  , approvalReview :: Maybe (Text,Int64,Text), approvalWorkHash :: Text, approvalCleanupPending :: Bool } deriving (Eq,Show)
decideSourceApproval :: Bool -> Int64 -> SourceApprovalFacts -> Either Text (Text,Int64)
decideSourceApproval covered restoration facts = do
  checkSourceApprovalSource covered restoration (approvalStatus facts) (approvalSource facts) (approvalLatest facts)
  ensure (not covered || maybe False (>0) (approvalCover facts)) "source_loss_not_covered"
  (previous,loss,expected)<-case approvalReview facts of
    Just row@(state,_,_) | state `elem` ["ready","paying"]->Right row
    _->Left "source_review_context_missing"
  ensure (expected==approvalWorkHash facts) "source_review_work_changed"
  ensure (not $ approvalCleanupPending facts) "preparation_cancellation_pending"
  pure (previous,loss)
checkSourceApprovalSource :: Bool -> Int64 -> PaymentStatus -> W.Deposit -> Maybe (Text,Int64,Int64) -> Either Text ()
checkSourceApprovalSource covered restoration status source latest =
  ensure (status==PaymentReview && case latest of
    Just(phase,shortfall,n)->n==restoration && if covered
      then W.depositAsset source==Native && not(W.depositEligible source) && phase=="missing" && shortfall==units(W.depositAmount source)
      else W.depositEligible source && phase=="restored" && shortfall==0
    _->False) "source_approval_not_expected"

data RebroadcastFacts = RebroadcastFacts
  { rebroadcastPaused :: Bool, rebroadcastPayment :: PaymentView, rebroadcastSourceEligible :: Bool
  , rebroadcastFamily :: [RecordedAttempt], rebroadcastReview :: (Text,Text,Text) } deriving (Eq,Show)
checkRebroadcast :: RecordedAttempt -> RebroadcastFacts -> Either Text ()
checkRebroadcast saved facts = do
  ensure (rebroadcastPaused facts) "pause_before_operator_action"
  ensure (recordedChain saved=="Native" && recordedState saved=="settled" && maybe False (>0) (recordedSequence saved)
    && savedStatus(rebroadcastPayment facts)==PaymentPaid
    && paymentId(savedPayment $ rebroadcastPayment facts)==recordedPayment saved) "native_rebroadcast_payment_changed"
  ensure (rebroadcastSourceEligible facts) "source_not_eligible"
  ensure (saved `elem` rebroadcastFamily facts) "native_replacement_family_changed"
  let (previous,status,reason)=rebroadcastReview facts
  ensure (recordedObservation saved==Just previous && (status=="confirming" && reason=="native_confirmation_policy_pending"
    || status=="unavailable" && reason=="native_settled_payment_unseen")) "native_rebroadcast_not_missing"

-- Cleanup and expiry remain distinct evidence. Releasing earned-fee reserves
-- permits only completed wholly unsigned cleanup; preparation may also accept
-- the independently proved and approved expiry of exactly one saved attempt.
data GenerationEnd = OpenGeneration | UnsignedCleanup Bool | SolanaRetired Text Bool Bool deriving (Eq,Show)
successorGeneration :: Bool -> [(Int64,GenerationEnd)] -> [(Text,Int64)] -> Maybe Int
successorGeneration includeExpired rows attempts
  | null rows || length rows>8 || map fst rows/=[0..fromIntegral(length rows)-1] = Nothing
  | all permitted rows && all (\(_,g)->g>=0 && g<fromIntegral(length rows)) attempts = Just(length rows)
  | otherwise = Nothing
 where
  permitted (generation,ending)=case ending of
    UnsignedCleanup done->done && all ((/=generation).snd) attempts
    SolanaRetired txid expired approved->includeExpired && expired && approved
      && filter ((==generation).snd) attempts==[(txid,generation)]
    OpenGeneration->False
