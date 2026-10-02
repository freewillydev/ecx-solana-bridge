module Bridge.Payment (PreparationStore(..), prepareNativeWithSigner, prepareSolanaWithSigner, payoutReference) where

import Bridge.Config
import Bridge.Ledger.Model
import Bridge.NativePayment
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Types
import Control.Exception (onException)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import Data.Int (Int64)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

class PreparationStore ledger where
  preparationPause :: ledger -> Text -> IO ()
  preparationReadiness :: ledger -> IO Availability
  preparationOrderPolicy :: ledger -> Text -> IO PolicySnapshot
  preparationCostLimits :: ledger -> Text -> IO CostLimits
  preparationAttempts :: ledger -> IO [Attempt]
  preparationPending :: ledger -> IO [Preparation]
  preparationBegin :: ledger -> Config -> Obligation -> Text -> Int64 -> Text -> IO ()
  preparationActive :: ledger -> Text -> IO Int
  preparationStoreDraft :: ledger -> Text -> Text -> Int -> IO ()
  preparationStoreAttempt :: ledger -> Obligation -> Text -> Text -> Text -> Text -> Int64 -> Maybe Text -> Int -> IO ()

json :: ToJSON a => a -> Text
json = TE.decodeUtf8 . LBS.toStrict . encode
stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8

-- No broadcast occurs here. The separate first-send decision must still
-- recheck source/freshness, journal BroadcastIntent and satisfy backup coverage.
prepareNativeWithSigner :: PreparationStore ledger => NativeRPC
  -> (Text -> Int -> NativePlan -> NativeDraft -> IO NativeSigned) -> Config -> ledger -> Obligation -> IO Text
prepareNativeWithSigner call signer c ledger obligation = prepare `onException` preparationPause ledger "native_preparation_requires_review"
 where
  prepare = do
    require (obligationAsset obligation=="Native") "wrong_destination_chain"
    quantity <- either reject pure (amount $ toInteger $ obligationAmount obligation)
    policy <- preparationOrderPolicy ledger (obligationOrder obligation)
    require (deploymentFingerprint policy==fingerprint c) "payment_profile_mismatch"
    attempts <- filter ((==obligationId obligation) . attemptIntent) <$> preparationAttempts ledger
    case attempts of
      [attempt] -> do
        signed <- stored (attemptPolicy attempt)
        validateSaved quantity policy (signedNativePlan signed)
        require (attemptChain attempt=="Native" && attemptBytes attempt==signedNativeBytes signed
          && attemptId attempt==nativeTxid (signedNativeTransaction signed)) "invalid_saved_payment"
        either reject pure (validateNativeTx (signedNativePlan signed) (signedNativePrevouts signed) (signedNativeFee signed) (signedNativeTransaction signed))
        pure (attemptId attempt)
      [] -> do
        state <- preparationReadiness ledger
        require (available state) "payouts_paused"
        preparations <- filter ((==obligationId obligation) . obligationId . preparationObligation) <$> preparationPending ledger
        (plan,savedDraft,generation) <- case preparations of
          [] -> do
            limits <- preparationCostLimits ledger (obligationOrder obligation)
            plan <- newNativePlan call (profile c) (nativeDepth policy) (savedNativeFee limits) (obligationRecipient obligation) quantity
            preparationBegin ledger c obligation "Native" (units $ planFeeLimit plan) (json plan)
            g <- preparationActive ledger (obligationId obligation)
            pure (plan,Nothing,g)
          [p] -> do
            plan <- stored (preparationPolicy p)
            require (preparationObligation p==obligation && preparationChain p=="Native" && preparationFeeLimit p==units (planFeeLimit plan)) "invalid_saved_payment"
            pure (plan,preparationDraft p,preparationGeneration p)
          _ -> reject "duplicate_preparation"
        validateSaved quantity policy plan
        preparationActive ledger (obligationId obligation) >>= \g ->
          require (g==generation) "preparation_generation_changed"
        draft <- case savedDraft of
          Just value -> stored value
          Nothing -> do
            -- No wallet lock can be orphaned by losing the funding response.
            -- signNativeDraft locks the recorded inputs after storeDraft commits.
            value <- fundNativeDraftWith False call plan
            preparationStoreDraft ledger (obligationId obligation) (json value) generation
            pure value
        signed <- signer (obligationId obligation) generation plan draft
        require (signedNativePlan signed==plan && sameNativeTemplate (draftTransaction draft) (signedNativeTransaction signed)
          && signedNativeFee signed==draftFee draft && sameNativePrevouts (signedNativePrevouts signed) (draftPrevouts draft)) "native_signed_template_changed"
        either reject pure (validateNativeTx plan (signedNativePrevouts signed) (signedNativeFee signed) (signedNativeTransaction signed))
        let txid=nativeTxid (signedNativeTransaction signed)
            points=map nativeOutpoint (nativeInputs $ signedNativeTransaction signed)
        first <- case points of point:_ -> pure point; [] -> reject "native_input_mismatch"
        preparationStoreAttempt ledger obligation "Native" txid (signedNativeBytes signed) (json signed)
          (units $ planFeeLimit plan) (Just $ outpointTxid first<>":"<>T.pack (show $ outpointVout first)) generation
        pure txid
      _ -> reject "multiple_initial_native_attempts"
  validateSaved quantity policy plan = require
    (planProfile plan==profile c && planRecipient plan==obligationRecipient obligation && planAmount plan==quantity
      && planDepth plan==nativeDepth policy && units (planFeeLimit plan)>0)
    "saved_native_policy_mismatch"

-- The memo identifies the durable obligation, including refunds. Hashing keeps
-- internal separators out of the helper's deliberately narrow identifier type.
payoutReference :: Config -> Obligation -> Text
payoutReference c obligation = digest $ TE.encodeUtf8
  ("ecx-payout-v1:"<>fingerprint c<>":"<>obligationId obligation)

prepareSolanaWithSigner :: PreparationStore ledger => SolanaRPC
  -> (Text -> Int -> SolanaPlan -> IO SolanaSigned) -> Config -> ledger -> Obligation -> IO Text
prepareSolanaWithSigner call signer c ledger obligation = prepare `onException` preparationPause ledger "solana_preparation_requires_review"
 where
  prepare = do
    require (obligationAsset obligation=="Wrapped") "wrong_destination_chain"
    quantity <- either reject pure (amount $ toInteger $ obligationAmount obligation)
    policy <- preparationOrderPolicy ledger (obligationOrder obligation)
    require (deploymentFingerprint policy==fingerprint c && solanaCommitment policy=="finalized") "payment_profile_mismatch"
    attempts <- filter ((==obligationId obligation) . attemptIntent) <$> preparationAttempts ledger
    case attempts of
      [attempt] -> do
        signed <- stored (attemptPolicy attempt)
        let plan=signedSolanaPlan signed
            reply=signedSolanaReply signed
        validateSaved quantity plan
        limit <- either reject pure (solanaOperatingLimit plan)
        _ <- either reject pure (validateHelperReply c (solanaPayoutRequest c plan) reply)
        require (attemptChain attempt=="Solana" && attemptBytes attempt==replyTransaction reply
          && Just (attemptId attempt)==replySignature reply && attemptFeeLimit attempt==units limit
          && units (signedSolanaFeeEstimate signed)>0 && signedSolanaFeeEstimate signed<=solPlanFeeLimit plan
          && signedSolanaRentEstimate signed<=solPlanRentLimit plan) "invalid_saved_payment"
        pure (attemptId attempt)
      [] -> do
        state <- preparationReadiness ledger
        require (available state) "payouts_paused"
        preparations <- filter ((==obligationId obligation) . obligationId . preparationObligation) <$> preparationPending ledger
        (plan,savedDraft,generation) <- case preparations of
          [] -> do
            limits <- preparationCostLimits ledger (obligationOrder obligation)
            recent <- getRecentBlockhash call
            let plan=SolanaPlan (fingerprint c) (obligationRecipient obligation) quantity
                  (payoutReference c obligation) recent (savedSolanaFee limits) (savedSolanaRent limits)
            limit <- either reject pure (solanaOperatingLimit plan)
            preparationBegin ledger c obligation "Solana" (units limit) (json plan)
            g <- preparationActive ledger (obligationId obligation)
            pure (plan,Nothing,g)
          [p] -> do
            plan <- stored (preparationPolicy p)
            limit <- either reject pure (solanaOperatingLimit plan)
            require (preparationObligation p==obligation && preparationChain p=="Solana"
              && preparationFeeLimit p==units limit) "invalid_saved_payment"
            pure (plan,preparationDraft p,preparationGeneration p)
          _ -> reject "duplicate_preparation"
        validateSaved quantity plan
        preparationActive ledger (obligationId obligation) >>= \g ->
          require (g==generation) "preparation_generation_changed"
        let request=solanaPayoutRequest c plan
        case savedDraft of
          Nothing -> preparationStoreDraft ledger (obligationId obligation) (json request) generation
          Just value -> stored value >>= \old -> require (old==request) "saved_solana_request_mismatch"
        -- The immutable order/preparation supplies these ceilings. Current
        -- aggregate daily caps were checked by beginPreparation above.
        signed <- signer (obligationId obligation) generation plan
        require (signedSolanaPlan signed==plan && units(signedSolanaFeeEstimate signed)>0
          && signedSolanaFeeEstimate signed<=solPlanFeeLimit plan && signedSolanaRentEstimate signed<=solPlanRentLimit plan) "invalid_saved_payment"
        _ <- either reject pure (validateHelperReply c request $ signedSolanaReply signed)
        let reply=signedSolanaReply signed
        signature <- maybe (reject "helper_signature_missing") pure (replySignature reply)
        limit <- either reject pure (solanaOperatingLimit plan)
        preparationStoreAttempt ledger obligation "Solana" signature (replyTransaction reply) (json signed) (units limit) Nothing generation
        pure signature
      _ -> reject "multiple_initial_solana_attempts"
  validateSaved quantity plan = require
    (solPlanFingerprint plan==fingerprint c && solPlanRecipient plan==obligationRecipient obligation
      && solPlanAmount plan==quantity && solPlanReference plan==payoutReference c obligation
      && units (solPlanFeeLimit plan)>0
      && recentSlot (solPlanRecent plan)>=0 && recentLastValidHeight (solPlanRecent plan)>0)
    "saved_solana_policy_mismatch"
