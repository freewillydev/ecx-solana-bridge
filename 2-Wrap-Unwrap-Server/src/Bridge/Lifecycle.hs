-- Pure payment facts and decisions. These values carry no database, clock,
-- network or signing authority; the closed Store operation must read them afresh.
module Bridge.Lifecycle
  ( PaymentStatus(..), PaymentView(..), PreparedPayment(..), RecordedAttempt(..)
  , SettlementOutcome(..), SettlementFacts(..), SettlementDecision(..), SettlementEffects(..)
  , CustomerResolution(..), decideSettlement, outcomeState, outcomeRecord, outcomeCosts
  , IntakeFacts(..), FeeBudget(..), PreparationHistory(..), PriorFeeHold(..)
  , PreparationAdmission(..), PreparationFacts(..), PreparationDecision(..), decidePreparation
  , SendFacts(..), QueueDecision(..), decideQueue, decideSend, checkIntake
  ) where

import Bridge.Domain hiding (fee)
import Bridge.Wire (PaymentTerms(..),CostLimits(..),SignedAttempt(..),PaymentCosts(..))
import Control.Monad (unless)
import Data.Aeson (Value(Null),eitherDecodeStrict',encode,object,(.=))
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- Schema-21 projection retained during extraction. Review can hide economic
-- progress here; schema 22 will separate phase from its execution restrictions.
data PaymentStatus = PaymentReady | PaymentPaying | PaymentPaid | PaymentReview | PaymentCancelled deriving (Eq,Show)
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
  let current=settlementCurrent facts; view=settlementPayment facts
      state=outcomeState outcome; proof=outcomeRecord outcome
      costs=outcomeCosts outcome
      fee=networkFee costs; rent=accountRent costs
      validProof text=not(T.null text) && T.length text<=32768
      paid=case outcome of Succeeded{}->True; Failed{}->False
  case outcome of
    Succeeded _ evidence -> ensure (validProof evidence && units fee>0
      && toInteger(units fee)+toInteger(units rent)<=toInteger(units $ recordedFee expected)
      && (recordedChain expected=="Solana" || units rent==0)) "settlement_fee_or_evidence_invalid"
    Failed _ evidence -> ensure (recordedChain expected=="Solana" && validProof evidence
      && units fee>0 && fee<=recordedFee expected) "invalid_failure_evidence"
  ensure (recordedState expected=="broadcast_intent" && recordedSequence expected/=Nothing
    && paymentId(savedPayment view)==recordedPayment current
    && recordedChain current==(if paymentAsset(savedPayment view)==Native then "Native" else "Solana")
    && current {recordedState=recordedState expected,recordedObservation=recordedObservation expected}==expected)
    "settlement_attempt_changed"
  if recordedState current==state then do
    ensure (recordedObservation current==Just proof) "settlement_evidence_conflict"
    unless paid $ ensure (settlementFailedCharge facts==Just(toInteger $ units fee)) "failure_evidence_conflict"
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
      fresh at=at>=0 && at<=now && toInteger now-toInteger at<=60
  ensure (now>=0) "invalid_order_time"
  ensure (not $ intakePaused facts) "intake_paused"
  ensure (case intakeScans facts of
    Just(a,b,c)->all (\(at,anchor)->fresh at && not(T.null anchor)) [a,b,c]
    Nothing->False) "scanners_not_fresh"
  ensure (case intakeCustody facts of Just(revision,checked,at)->revision==checked && fresh at; _->False)
    "custody_not_reconciled"

-- Integer totals come from the journal/holds at the durable operating clock.
-- Preparation subtracts only holds it will transfer/release in this transaction.
data FeeBudget = FeeBudget
  { operatingBalance :: Integer, operatingHeld :: Integer
  , operatingSpent :: Integer, operatingDaily :: Amount } deriving (Eq,Show)
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
  ensure (not(T.null plan) && T.length plan<=16384) "invalid_payment_record"
  decoded<-either (const $ Left "invalid_saved_payment") Right (eitherDecodeStrict' $ TE.encodeUtf8 plan)
  ensure (decoded/=Null) "invalid_payment_record"
  ensure (needed>0 && needed<=bound) "order_fee_limit_exceeded"
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
  currency=if native then Native else Sol; costs=paymentLimits $ savedTerms view
  bound=if native then value(savedNativeFee costs) else value(savedSolanaFee costs)+value(savedSolanaRent costs)
  needed=value allowance
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
    ensure (held>=0) "operating_reservation_missing"
    ensure (operatingBalance budget-held>=needed) "insufficient_fee_budget"
    ensure (operatingSpent budget+held+needed<=value(operatingDaily budget)) "operating_daily_limit"
    pure $ CreatePreparation $ PreparedPayment view {savedStatus=PaymentPaying} generation plan Nothing allowance

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
  let prepared=sendPreparation facts; view=preparedView prepared; saved=sendAttempt facts
      outgoing=savedPayment view
  ensure (savedStatus view==PaymentPaying && recordedPayment saved==paymentId outgoing
    && recordedChain saved==(if paymentAsset outgoing==Native then "Native" else "Solana")
    && recordedGeneration saved==preparedGeneration prepared && recordedFee saved==preparedFee prepared) "payment_not_sendable"
  case paymentFunding outgoing of EarnedFees{}->pure (); _->ensure (sendSourceEligible facts) "source_not_eligible"
  if recordedChain saved=="Native" then do
    (latest,pending)<-maybe (Left "native_replacement_not_current") Right (sendNativeSelection facts)
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
