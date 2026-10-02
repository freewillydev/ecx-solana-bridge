{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Recovery
  ( reconcileNativeLocksWith
  , cancelPreparationWith, approveSourceRecoveryWith
  , coverSourceLossWith, prepareNativeReplacementUsing
  , signNativeReplacementUsing ) where

import qualified Bridge.Postgres.Custody as PgCustody
import qualified Bridge.Postgres.Ledger as PgLedger
import qualified Bridge.Postgres.LossCover as PgLossCover
import qualified Bridge.Postgres.Settlement as PgSettlement
import qualified Bridge.Postgres.Preparation as PgPreparation
import qualified Bridge.Postgres.Replacement as PgReplacement
import qualified Bridge.Postgres.Source as PgSource
import Bridge.Config
import Bridge.Ledger.Model
import Bridge.Native (nativeAmount,nativeWalletInfoWith)
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Payment (payoutReference)
import Bridge.Reconciliation
import Bridge.Reorg
import Bridge.RPC
import Bridge.Settlement
import Bridge.SolanaPayment
import Bridge.Types
import Bridge.Postgres.Ledger (Ledger)
import Control.Exception (IOException,catch,try)
import Control.Monad (when)
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

stored :: FromJSON a => Text -> IO a
stored=decodeRecord "invalid_saved_preparation"

-- Reconstruct from durable records on every startup/pass. Observing and booking
-- a recorded outcome continue during a pause; this never prepares or broadcasts.
approveSourceRecoveryWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> Text -> Int64 -> Text -> IO Value
approveSourceRecoveryWith clock transport c ledger intent restoration reason=do
  require (restoration>0 && not (T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
  health <- PgLedger.readiness ledger
  require (not $ available health) "pause_before_operator_action"
  previous <- PgSource.recoveryApproval ledger intent restoration
  case previous of
    Just old->require (old==reason) "source_approval_conflict"
    Nothing->do
      ob <- PgSource.recoveryObligation ledger intent restoration
      paymentIdentity transport
      recheckSourceWith transport c ledger ob
      -- A saved payment may have finalized or expired since the source was
      -- restored. Reconcile it first; the ledger snapshot then refuses revival.
      failures <- reconcilePaymentsWith transport c ledger
      require (null failures) "source_approval_payment_requires_review"
      _ <- reconcileCustodyWith clock transport c ledger
      now <- clock
      PgSource.recoveryRecord ledger intent restoration now reason
  pure $ object ["approvedSourceRecovery" .= intent,"restorationSequence" .= restoration
    ,"paused" .= True,"signedOrSent" .= False]

prepareNativeReplacementUsing :: IO Int64 -> PaymentTransport
  -> (Text -> [NativeSigned] -> Amount -> IO NativeDraft) -> Config -> Ledger -> Text -> Amount -> Text -> IO Value
prepareNativeReplacementUsing clock transport drafter c ledger parent fee reason=do
  require (units fee>0 && not (T.null $ T.strip reason) && T.length reason<=512) "invalid_native_replacement_draft"
  health <- PgLedger.readiness ledger
  require (not $ available health) "pause_before_operator_action"
  previous <- PgReplacement.decision ledger parent fee reason
  (sequenceNo,cancelled) <- case previous of
    Just saved->pure saved
    Nothing->do
      expected <- PgReplacement.parent ledger c parent
      paymentIdentity transport
      (ob,payment) <- readSavedPayment transport c ledger expected
      signed <- case payment of NativePayment s->pure s; _->reject "wrong_destination_chain"
      attempts <- PgReplacement.readFamily ledger (attemptIntent expected)
      family <- if attempts==[expected] then pure [signed] else do
        (members,_) <- readSavedNativeFamily transport c ledger attempts
        pure (map snd members)
      recheckSourceWith transport c ledger ob
      draft <- drafter parent family fee
      either reject pure (validateNativeReplacementDraft family fee draft)
      -- The original can confirm during drafting. Reconcile it and reject a
      -- stale parent before committing an operator decision for new work.
      failures <- reconcilePaymentsWith transport c ledger
      require (null failures) "native_replacement_payment_requires_review"
      recheckSourceWith transport c ledger ob
      _ <- reconcileCustodyWith clock transport c ledger
      now <- clock
      sequenceNo <- PgReplacement.recordDraft ledger c expected draft reason now
      pure(sequenceNo,False)
  pure $ object ["parentTransaction" .= parent,"draftSequence" .= sequenceNo,"fee" .= fee
    ,"cancelled" .= cancelled,"paused" .= True,"signedOrSent" .= False]

-- Signing is an explicit paused operator call, never a worker task. Saved
-- members advance only through the ordinary durable send/observation engine.
signNativeReplacementUsing :: IO Int64 -> PaymentTransport
  -> (Int64 -> [NativeSigned] -> NativeDraft -> IO NativeSigned) -> Config -> Ledger -> Int64 -> IO Attempt
signNativeReplacementUsing clock transport signer c ledger sequenceNo=do
  previous <- PgReplacement.member ledger sequenceNo
  case previous of
    Just member->pure member
    Nothing->do
      (expected,draft) <- PgReplacement.signingContext ledger c sequenceNo
      paymentIdentity transport
      (members,_) <- readSavedNativeFamily transport c ledger expected
      (ob,_) <- readSavedPayment transport c ledger (last expected)
      recheckSourceWith transport c ledger ob
      reconcile
      _ <- PgReplacement.signingContext ledger c sequenceNo
      signed <- signer sequenceNo (map snd members) draft
      recheckSourceWith transport c ledger ob
      reconcile
      now <- clock
      PgReplacement.recordMember ledger c sequenceNo expected signed now
 where
  reconcile=do
    failures <- reconcilePaymentsWith transport c ledger
    require (null failures) "native_replacement_payment_requires_review"
    _ <- reconcileCustodyWith clock transport c ledger
    now <- clock
    PgCustody.checkFresh ledger now

coverSourceLossWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> Text -> Int64 -> LossCapital -> Text -> IO Value
coverSourceLossWith clock transport c ledger did recovery capital reason=do
  require (recovery>0 && not (T.null $ T.strip reason) && T.length reason<=512) "invalid_source_loss_cover"
  health <- PgLedger.readiness ledger
  require (not $ available health) "pause_before_operator_action"
  old <- PgLossCover.decision ledger did recovery
  case old of
    Just previous->require (previous==(capital,reason)) "source_loss_cover_conflict"
    Nothing->do
      candidates <- PgSource.candidates ledger
      require (length candidates<=1000) "source_recovery_backlog"
      source <- case filter ((==did).depositId) candidates of [s]->pure s; _->reject "source_loss_not_proven"
      sourceProof <- inspectNativeSourceWith transport c ledger source >>= \case
        SourceMissing proof->pure proof
        _->reject "source_loss_not_proven"
      -- This separate inspection includes proved deficits but cannot make
      -- ordinary custody readiness pass before the actual capital allocation.
      custodyReport <- inspectSourceLossCustodyWith clock transport c ledger
      now <- clock
      PgLossCover.record ledger source recovery now capital reason sourceProof custodyReport
  pure $ object ["coveredSourceLoss" .= did,"recoverySequence" .= recovery,"capital" .= capital
    ,"paused" .= True,"signedOrSent" .= False]

-- Holding saved native inputs is independent of Solana availability. This may
-- restore advisory locks, but cannot sign, broadcast, unlock or release funds.
reconcileNativeLocksWith :: PaymentTransport -> Config -> Ledger -> IO Value
reconcileNativeLocksWith transport c ledger=do
  result <- try (work `catch` (\(_::IOException)->reject "native_lock_recovery_io_unavailable")) :: IO (Either BridgeError Value)
  case result of
    Right value->pure value
    Left (BridgeError code)->do
      let reason="native_lock_recovery:"<>code
      health <- PgLedger.readiness ledger
      when (health/=Availability False reason) $ PgLedger.pause ledger reason
      pure $ object ["state" .= ("requires_review"::Text),"error" .= code,"signedOrSent" .= False]
 where
  call=paymentNative transport
  work=do
    paymentIdentity transport
    _ <- nativeWalletInfoWith call c
    preparations <- filter ((=="Native").preparationChain) <$> PgPreparation.pending ledger
    attempts <- filter ((=="Native").attemptChain) <$> PgSettlement.pendingAttempts ledger
    case (preparations,attempts) of
      ([],[])->verifyOnly "idle" []
      ([p],[])->do
        policy <- preparationPolicyFor c ledger p
        (plan,draft) <- readNativePreparation call c p policy
        cancelling <- PgPreparation.readCancellation ledger (obligationId $ preparationObligation p) (preparationGeneration p)
        let subject=obligationId (preparationObligation p)<>"@"<>T.pack(show $ preparationGeneration p)
        case draft of
          Nothing->verifyOnly (if cancelling==Nothing then "awaiting_draft" else "cancellation_pending") []
          Just saved | cancelling/=Nothing->verifyOnly "cancellation_pending" (map nativeOutpoint $ nativeInputs $ draftTransaction saved)
          Just saved->restore subject plan (draftTransaction saved) (draftPrevouts saved)
      ([],[a])->do
        (_,payment) <- readSavedPayment transport c ledger a
        signed <- case payment of NativePayment s->pure s; _->reject "wrong_destination_chain"
        spent <- recordedNativeSpend a signed
        if spent then verifyOnly "spent_by_recorded_payment" (map nativeOutpoint $ nativeInputs $ signedNativeTransaction signed)
          else restore (attemptId a) (signedNativePlan signed) (signedNativeTransaction signed) (signedNativePrevouts signed)
      ([],family) | length family>1->do
        _ <- either reject pure (paymentAttemptGroups family)
        (members,view) <- readSavedNativeFamily transport c ledger family
        (first,signed) <- case members of m:_->pure m; _->reject "native_lock_recovery_bounds"
        let points=map nativeOutpoint $ nativeInputs $ signedNativeTransaction signed
        case familyActive view of
          Just _->verifyOnly "spent_by_recorded_family" points
          Nothing->restore (attemptId first) (signedNativePlan signed) (signedNativeTransaction signed) (signedNativePrevouts signed)
      _->reject "native_lock_recovery_bounds"
  verifyOnly state points=do
    locked <- ownedNativeLocks call points
    pure $ report state (length locked) 0
  restore subject plan tx previous=do
    current <- readNativePrevouts call (planDepth plan) (nativeInputs tx)
    require (sameNativePrevouts current previous) "native_previous_output_changed"
    restored <- restoreNativeInputLocks call (map nativeOutpoint $ nativeInputs tx)
    when (restored>0) $ PgPreparation.nativeLockAudit ledger subject
    pure $ report "locked" (length $ nativeInputs tx) restored
  recordedNativeSpend attempt signed=do
    found <- readNativePayment call signed
    case found of
      Nothing->pure False
      Just (depth,value)->do
        require (attemptState attempt=="broadcast_intent") "unrecorded_broadcast_observed"
        if depth>0 then do
          anchor <- fieldValue "blockhash" value
          _ <- activeNativeBlock call anchor 1
          pure True
        else do
          mempool <- try (call False "getmempoolentry" [toJSON $ attemptId attempt]) :: IO (Either BridgeError Value)
          case mempool of
            Left (BridgeError "rpc_error_-5")->pure False
            Left (BridgeError code)->reject code
            Right entry->do
              size <- fieldValue "vsize" entry :: IO Int
              require (size>0) "native_mempool_evidence_invalid"
              pure True
  report state owned restored=object ["state" .= (state::Text),"ownedInputs" .= (owned::Int)
    ,"restoredInputs" .= (restored::Int),"error" .= (Nothing::Maybe Text),"signedOrSent" .= False]

-- Private operator action under the exclusive ledger lock. This cannot sign,
-- send, release customer principal, or resume the deployment.
cancelPreparationWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> Text -> Int -> Text -> IO Value
cancelPreparationWith clock transport c ledger intent generation reason=do
  require (generation>=0 && generation<8 && not (T.null $ T.strip reason) && T.length reason<=512) "invalid_preparation_cancellation"
  state <- PgLedger.readiness ledger
  require (not $ available state) "pause_before_operator_action"
  old <- PgPreparation.readCancellation ledger intent generation
  case old of
    Just (previous,_,_) -> require (previous==reason) "preparation_cancellation_conflict"
    Nothing -> pure ()
  case old of
    Just (_,_,True) -> pure result
    _ -> do
      rows <- filter (\p -> obligationId (preparationObligation p)==intent && preparationGeneration p==generation) <$> PgPreparation.pending ledger
      preparation <- case rows of [p]->pure p; _->reject "preparation_cancellation_not_expected"
      paymentIdentity transport
      recheckSourceWith transport c ledger (preparationObligation preparation)
      _ <- reconcileCustodyWith clock transport c ledger
      expected <- cleanupPlan (paymentNative transport) c ledger preparation
      -- Even a retry must match the same immutable policy/draft and pass the
      -- current custody check; a lost response is never evidence of cleanup.
      case old of
        Just (_,encoded,False) -> stored encoded >>= \saved -> require (saved==expected) "preparation_cancellation_conflict"
        _ -> pure ()
      now <- clock
      PgCustody.checkFresh ledger now
      PgPreparation.beginCancellation ledger preparation now reason expected
      when (preparationChain preparation=="Native") $ do
        inputs <- fieldValue "nativeInputs" expected
        cleanupLocks (paymentNative transport) inputs
      PgPreparation.finishCancellation ledger preparation
      pure result
 where
  result=object ["cancelledPreparation" .= intent,"generation" .= generation,"paused" .= True
    ,"principalAndInventoryRetained" .= True,"signedOrSent" .= False]

-- Reconstruct cleanup from the saved economic policy, not from caller-supplied
-- outpoints. A stale Solana blockhash is harmless here: no signed attempt exists.
preparationPolicyFor :: Config -> Ledger -> Preparation -> IO PolicySnapshot
preparationPolicyFor c ledger p=do
  let ob=preparationObligation p
  policy <- PgPreparation.orderPolicy ledger (obligationOrder ob)
  require (deploymentFingerprint policy==fingerprint c && solanaCommitment policy=="finalized") "payment_profile_mismatch"
  pure policy

readNativePreparation :: NativeRPC -> Config -> Preparation -> PolicySnapshot -> IO (NativePlan,Maybe NativeDraft)
readNativePreparation call c p policy=do
  let ob=preparationObligation p
  quantity <- either reject pure (amount $ toInteger $ obligationAmount ob)
  plan <- stored (preparationPolicy p)
  require (preparationChain p=="Native" && obligationAsset ob=="Native" && planProfile plan==profile c
    && planRecipient plan==obligationRecipient ob && planAmount plan==quantity && planDepth plan==nativeDepth policy
    && units (planFeeLimit plan)>0 && units (planFeeLimit plan)==preparationFeeLimit p) "saved_native_policy_mismatch"
  draft <- mapM (\text->do
    saved <- stored text
    either reject pure (validateNativeTx plan (draftPrevouts saved) (draftFee saved) (draftTransaction saved))
    decoded <- call False "decodepsbt" [toJSON $ draftPsbt saved]
    tx <- fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
    fee <- fieldValue "fee" decoded >>= either reject pure . nativeAmount
    require (sameNativeTemplate tx (draftTransaction saved) && fee==draftFee saved) "native_psbt_changed"
    pure saved) (preparationDraft p)
  pure (plan,draft)

cleanupPlan :: NativeRPC -> Config -> Ledger -> Preparation -> IO Value
cleanupPlan call c ledger p=do
  let ob=preparationObligation p
  policy <- preparationPolicyFor c ledger p
  quantity <- either reject pure (amount $ toInteger $ obligationAmount ob)
  points <- case preparationChain p of
    "Native" -> do
      (_,draft) <- readNativePreparation call c p policy
      pure $ maybe [] (map nativeOutpoint . nativeInputs . draftTransaction) draft
    "Solana" -> do
      plan <- stored (preparationPolicy p)
      limit <- either reject pure (solanaOperatingLimit plan)
      require (obligationAsset ob=="Wrapped" && solPlanFingerprint plan==fingerprint c
        && solPlanRecipient plan==obligationRecipient ob && solPlanAmount plan==quantity
        && solPlanReference plan==payoutReference c ob && units limit==preparationFeeLimit p
        && units (solPlanFeeLimit plan)>0 && recentSlot (solPlanRecent plan)>=0
        && recentLastValidHeight (solPlanRecent plan)>0) "saved_solana_policy_mismatch"
      case preparationDraft p of
        Nothing -> pure ()
        Just text -> stored text >>= \request -> require (request==solanaPayoutRequest c plan) "saved_solana_request_mismatch"
      pure []
    _ -> reject "wrong_destination_chain"
  pure $ object ["chain" .= preparationChain p,"nativeInputs" .= points
    ,"draftHash" .= fmap (digest . TE.encodeUtf8) (preparationDraft p)]

cleanupLocks :: NativeRPC -> [Outpoint] -> IO ()
cleanupLocks call expected=do
  locked <- ownedNativeLocks call expected
  -- Core interprets an empty unlock list as ALL inputs. Never make that call.
  when (not $ null locked) $ do
    ok <- call True "lockunspent" [Bool True,toJSON locked] >>= parseValue parseJSON
    require ok "native_input_unlock_failed"
  after <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
  require (null after) "native_preparation_locks_require_review"
