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
