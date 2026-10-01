{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Recovery
  ( recoverDeployment, reconcileNativeLocks, reconcileNativeLocksWith
  , cancelPreparation, cancelPreparationWith, approveSourceRecovery, approveSourceRecoveryWith ) where

import Bridge.Config
import Bridge.Ledger
import Bridge.Native (nativeAmount,nativeIdentity)
import Bridge.NativePayment
import Bridge.Observer (epochSeconds,observeOnce)
import Bridge.Payment (payoutReference)
import Bridge.Reconciliation
import Bridge.Reorg
import Bridge.RPC
import Bridge.Settlement
import Bridge.SolanaPayment
import Bridge.Types
import Control.Exception (IOException,catch,try)
import Control.Monad (when)
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)

stored :: FromJSON a => Text -> IO a
stored=either (const $ reject "invalid_saved_preparation") pure . eitherDecodeStrict' . TE.encodeUtf8

-- Reconstruct from durable records on every startup/pass. Observing and booking
-- a recorded outcome continue during a pause; this never prepares or broadcasts.
recoverDeployment :: Manager -> Config -> Ledger -> IO Value
recoverDeployment manager c ledger=do
  scans <- observeOnce manager c ledger
  epochSeconds >>= expireQuotes ledger
  sources <- reconcileNativeSources manager c ledger
  nativeSettlements <- reconcileNativeSettlements manager c ledger
  payments <- reconcilePayments manager c ledger
  locks <- reconcileNativeLocks manager c ledger
  custody <- reconcileCustody manager c ledger
  health <- readiness ledger
  pure $ object ["scanners" .= scans,"sources" .= sources,"nativeSettlements" .= nativeSettlements,"payments" .= payments,"nativeLocks" .= locks,"custody" .= custody
    ,"availability" .= health,"signedOrSent" .= False]

-- Explicitly restore only the work suspended by a recovered source. This is
-- neither a replacement approval nor permission to resume or send anything.
approveSourceRecovery :: Manager -> Config -> Ledger -> Text -> Int64 -> Text -> IO Value
approveSourceRecovery manager c ledger intent restoration reason=do
  _ <- recoverDeployment manager c ledger
  approveSourceRecoveryWith epochSeconds
    (realPaymentTransport manager c (const $ reject "unexpected_source_approval_backup")) c ledger intent restoration reason

approveSourceRecoveryWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> Text -> Int64 -> Text -> IO Value
approveSourceRecoveryWith clock transport c ledger intent restoration reason=do
  require (restoration>0 && not (T.null $ T.strip reason) && T.length reason<=512) "invalid_source_approval"
  health <- readiness ledger
  require (not $ available health) "pause_before_operator_action"
  previous <- sourceRecoveryApproval ledger intent restoration
  case previous of
    Just old->require (old==reason) "source_approval_conflict"
    Nothing->do
      ob <- sourceRecoveryObligation ledger intent restoration
      paymentIdentity transport
      recheckSourceWith transport c ledger ob
      -- A saved payment may have finalized or expired since the source was
      -- restored. Reconcile it first; the ledger snapshot then refuses revival.
      payments <- reconcilePaymentsWith transport c ledger
      attempts <- fieldValue "attempts" payments :: IO [Value]
      failures <- mapM (fieldValue "error") attempts :: IO [Maybe Text]
      require (all (==Nothing) failures) "source_approval_payment_requires_review"
      _ <- reconcileCustodyWith clock transport c ledger
      now <- clock
      recordSourceRecoveryApproval ledger intent restoration now reason
  pure $ object ["approvedSourceRecovery" .= intent,"restorationSequence" .= restoration
    ,"paused" .= True,"signedOrSent" .= False]

-- Holding saved native inputs is independent of Solana availability. This may
-- restore advisory locks, but cannot sign, broadcast, unlock or release funds.
reconcileNativeLocks :: Manager -> Config -> Ledger -> IO Value
reconcileNativeLocks manager c=reconcileNativeLocksWith
  (realPaymentTransport manager c (const $ reject "unexpected_lock_recovery_backup"))
    {paymentIdentity=nativeIdentity manager c >> pure ()} c

reconcileNativeLocksWith :: PaymentTransport -> Config -> Ledger -> IO Value
reconcileNativeLocksWith transport c ledger=do
  result <- try (work `catch` (\(_::IOException)->reject "native_lock_recovery_io_unavailable")) :: IO (Either BridgeError Value)
  case result of
    Right value->pure value
    Left (BridgeError code)->do
      let reason="native_lock_recovery:"<>code
      health <- readiness ledger
      when (health/=Availability False reason) $ pause ledger reason
      pure $ object ["state" .= ("requires_review"::Text),"error" .= code,"signedOrSent" .= False]
 where
  call=paymentNative transport
  work=do
    paymentIdentity transport
    wallet <- call True "getwalletinfo" []
    name <- fieldValue "walletname" wallet
    descriptors <- fieldValue "descriptors" wallet
    scanning <- fieldValue "scanning" wallet :: IO Value
    require (name==nativeWallet c && descriptors && scanning==Bool False) "native_wallet_not_ready"
    preparations <- filter ((=="Native").preparationChain) <$> pendingPreparations ledger
    attempts <- filter ((=="Native").attemptChain) <$> pendingAttempts ledger
    case (preparations,attempts) of
      ([],[])->verifyOnly "idle" []
      ([p],[])->do
        policy <- preparationPolicyFor c ledger p
        (plan,draft) <- readNativePreparation call c p policy
        cancelling <- preparationCancellation ledger (obligationId $ preparationObligation p) (preparationGeneration p)
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
      _->reject "native_lock_recovery_bounds"
  verifyOnly state points=do
    locked <- ownedNativeLocks call points
    pure $ report state (length locked) 0
  restore subject plan tx previous=do
    current <- readNativePrevouts call (planDepth plan) (nativeInputs tx)
    require (sameNativePrevouts current previous) "native_previous_output_changed"
    restored <- restoreNativeInputLocks call (map nativeOutpoint $ nativeInputs tx)
    when (restored>0) $ ledgerAction ledger $ \db->execute db "INSERT INTO audit(action,detail) VALUES('native_locks_restored',?)" (Only subject)
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
cancelPreparation :: Manager -> Config -> Ledger -> Text -> Int -> Text -> IO Value
cancelPreparation manager c ledger intent generation reason=do
  _ <- observeOnce manager c ledger
  cancelPreparationWith epochSeconds
    (realPaymentTransport manager c (const $ reject "unexpected_cancellation_backup")) c ledger intent generation reason

cancelPreparationWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> Text -> Int -> Text -> IO Value
cancelPreparationWith clock transport c ledger intent generation reason=do
  require (generation>=0 && generation<8 && not (T.null $ T.strip reason) && T.length reason<=512) "invalid_preparation_cancellation"
  state <- readiness ledger
  require (not $ available state) "pause_before_operator_action"
  old <- preparationCancellation ledger intent generation
  case old of
    Just (previous,_,_) -> require (previous==reason) "preparation_cancellation_conflict"
    Nothing -> pure ()
  case old of
    Just (_,_,True) -> pure result
    _ -> do
      rows <- filter (\p -> obligationId (preparationObligation p)==intent && preparationGeneration p==generation) <$> pendingPreparations ledger
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
      checkCustodyFresh ledger now
      beginPreparationCancellation ledger preparation now reason expected
      when (preparationChain preparation=="Native") $ do
        inputs <- fieldValue "nativeInputs" expected
        cleanupLocks (paymentNative transport) inputs
      finishPreparationCancellation ledger preparation
      pure result
 where
  result=object ["cancelledPreparation" .= intent,"generation" .= generation,"paused" .= True
    ,"principalAndInventoryRetained" .= True,"signedOrSent" .= False]

-- Reconstruct cleanup from the saved economic policy, not from caller-supplied
-- outpoints. A stale Solana blockhash is harmless here: no signed attempt exists.
preparationPolicyFor :: Config -> Ledger -> Preparation -> IO PolicySnapshot
preparationPolicyFor c ledger p=do
  let ob=preparationObligation p
  policies <- ledgerAction ledger $ \db -> query db "SELECT policy_json FROM orders WHERE id=?" (Only $ obligationOrder ob) :: IO [Only Text]
  policy <- case policies of [Only text]->stored text; _->reject "order_not_found"
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
