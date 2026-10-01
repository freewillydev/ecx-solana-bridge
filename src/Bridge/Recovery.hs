module Bridge.Recovery (recoverDeployment, cancelPreparation, cancelPreparationWith) where

import Bridge.Config
import Bridge.Ledger
import Bridge.Native (nativeAmount)
import Bridge.NativePayment
import Bridge.Observer (epochSeconds,observeOnce)
import Bridge.Payment (payoutReference)
import Bridge.Reconciliation
import Bridge.RPC
import Bridge.Settlement
import Bridge.SolanaPayment
import Bridge.Types
import Control.Monad (when)
import Data.Aeson
import Data.Int (Int64)
import Data.List (nub)
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
  payments <- reconcilePayments manager c ledger
  custody <- reconcileCustody manager c ledger
  health <- readiness ledger
  pure $ object ["scanners" .= scans,"payments" .= payments,"custody" .= custody
    ,"availability" .= health,"signedOrSent" .= False]

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
cleanupPlan :: NativeRPC -> Config -> Ledger -> Preparation -> IO Value
cleanupPlan call c ledger p=do
  let ob=preparationObligation p
  policies <- ledgerAction ledger $ \db -> query db "SELECT policy_json FROM orders WHERE id=?" (Only $ obligationOrder ob) :: IO [Only Text]
  policy <- case policies of [Only text]->stored text; _->reject "order_not_found"
  require (deploymentFingerprint policy==fingerprint c && solanaCommitment policy=="finalized") "payment_profile_mismatch"
  quantity <- either reject pure (amount $ toInteger $ obligationAmount ob)
  points <- case preparationChain p of
    "Native" -> do
      plan <- stored (preparationPolicy p)
      require (obligationAsset ob=="Native" && planProfile plan==profile c && planRecipient plan==obligationRecipient ob
        && planAmount plan==quantity && planDepth plan==nativeDepth policy
        && units (planFeeLimit plan)>0 && units (planFeeLimit plan)==preparationFeeLimit p) "saved_native_policy_mismatch"
      case preparationDraft p of
        Nothing -> pure []
        Just text -> do
          draft <- stored text
          either reject pure (validateNativeTx plan (draftPrevouts draft) (draftFee draft) (draftTransaction draft))
          decoded <- call False "decodepsbt" [toJSON $ draftPsbt draft]
          tx <- fieldValue "tx" decoded >>= either reject pure . decodeNativeTx
          fee <- fieldValue "fee" decoded >>= either reject pure . nativeAmount
          require (sameNativeTemplate tx (draftTransaction draft) && fee==draftFee draft) "native_psbt_changed"
          pure (map nativeOutpoint $ nativeInputs tx)
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
  locked <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
  require (length locked<=100 && length locked==length (nub locked) && all (`elem` expected) locked) "native_preparation_locks_require_review"
  -- Core interprets an empty unlock list as ALL inputs. Never make that call.
  when (not $ null locked) $ do
    ok <- call True "lockunspent" [Bool True,toJSON locked] >>= parseValue parseJSON
    require ok "native_input_unlock_failed"
  after <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
  require (null after) "native_preparation_locks_require_review"
