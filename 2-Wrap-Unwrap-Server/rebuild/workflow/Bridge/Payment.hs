-- Preparation never signs or broadcasts. Only the critical interpreter owns
-- signer transport; both ends use the same saved-plan checks below.
module Bridge.Payment
  ( SigningPlan(..), SigningReply(..), prepareUnsigned, resolveSigningPlan
  , verifySigningReply, verifySignedAttempt, payoutReference ) where
import Bridge.Domain
import Bridge.Error
import Bridge.Identity (digest)
import Bridge.NativePayment
import Bridge.SolanaPayment
import qualified Bridge.SolanaHelper as H
import Bridge.Store
import Bridge.Wire (Profile,PaymentTerms(..),CostLimits(..),PolicySnapshot(..))
import Control.Exception (onException)
import Data.Aeson (FromJSON,ToJSON,encode,eitherDecodeStrict',toJSON)
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data SigningPlan = NativeAuthorization NativePlan NativeDraft | SolanaAuthorization SolanaPlan H.HelperRequest
  deriving (Eq,Show)
data SigningReply = NativeReply NativeSigned | SolanaReply SolanaSigned deriving (Eq,Show)
payoutReference :: Text -> Text -> Text
payoutReference identity identifier=digest (TE.encodeUtf8 $ "ecx-payout-v1:"<>identity<>":"<>identifier)

prepareUnsigned :: IO Int64 -> NativeRPC -> SolanaRPC -> Profile -> H.SolanaPolicy -> Reader -> Writer -> Text -> IO PreparedPayment
prepareUnsigned clock native solana profile config reader writer identifier = prepare `onException` evalWrite writer (Pause "preparation_requires_review")
 where
  prepare = do
    (view,existing,attempts) <- evalRead reader (ReadPaymentWork identifier)
    require (null attempts) "payment_already_signed"
    require (savedStatus view `elem` [PaymentReady,PaymentPaying]) "payment_not_ready"
    let outgoing=savedPayment view; PaymentTerms policy costs=savedTerms view
        identity=H.fingerprint config
    require (deploymentFingerprint policy==identity) "payment_profile_mismatch"
    prepared <- case existing of
      Just saved -> pure saved
      Nothing -> do
        (allowance,plan) <- case paymentAsset outgoing of
          Native -> do
            value <- newNativePlan native profile (nativeDepth policy) (savedNativeFee costs) (paymentRecipient outgoing) (paymentAmount outgoing)
            pure (planFeeLimit value,encodeSaved value)
          Wrapped -> do
            recent <- getRecentBlockhash solana
            let value=SolanaPlan identity (paymentRecipient outgoing) (paymentAmount outgoing)
                  (payoutReference identity identifier) recent (savedSolanaFee costs) (savedSolanaRent costs)
            allowance <- either reject pure (solanaOperatingLimit value)
            pure (allowance,encodeSaved value)
          Sol -> reject "invalid_payout_asset"
        now <- clock
        evalWrite writer (PreparePayment now identifier allowance plan)
    case preparedDraft prepared of
      Just _ -> pure ()
      Nothing -> do
        draft <- if paymentAsset outgoing==Native then do
          plan <- decodeSaved (preparedPolicy prepared)
          -- No input locks until the signer has checked this durable draft.
          encodeSaved <$> fundNativeDraft native plan
         else do
          plan <- decodeSaved (preparedPolicy prepared)
          pure $ encodeSaved $ solanaPayoutRequest config plan
        evalWrite writer (SaveDraft identifier (preparedGeneration prepared) draft)
    saved <- evalRead reader (ReadPreparation identifier)
    _ <- resolveSigningPlan profile config saved
    pure saved

resolveSigningPlan :: Profile -> H.SolanaPolicy -> PreparedPayment -> IO SigningPlan
resolveSigningPlan profile config prepared = do
  let view=preparedView prepared; outgoing=savedPayment view
      PaymentTerms policy costs=savedTerms view
  require (deploymentFingerprint policy==H.fingerprint config) "payment_profile_mismatch"
  draft <- maybe (reject "preparation_draft_required") pure (preparedDraft prepared)
  case paymentAsset outgoing of
    Native -> do
      plan <- decodeSaved (preparedPolicy prepared)
      value <- decodeSaved draft
      require (planProfile plan==profile && planDepth plan==nativeDepth policy && planAmount plan==paymentAmount outgoing
        && planRecipient plan==paymentRecipient outgoing && units(planFeeLimit plan)>0
        && planFeeLimit plan==preparedFee prepared && planFeeLimit plan<=savedNativeFee costs) "saved_native_policy_mismatch"
      either reject pure (validateNativeTx plan (draftPrevouts value) (draftFee value) (draftTransaction value))
      pure (NativeAuthorization plan value)
    Wrapped -> do
      plan <- decodeSaved (preparedPolicy prepared)
      request <- decodeSaved draft
      allowance <- either reject pure (solanaOperatingLimit plan)
      require (solPlanFingerprint plan==H.fingerprint config && solanaCommitment policy=="finalized"
        && solPlanRecipient plan==paymentRecipient outgoing && solPlanAmount plan==paymentAmount outgoing
        && solPlanReference plan==payoutReference (H.fingerprint config) (paymentId outgoing)
        && allowance==preparedFee prepared && units(solPlanFeeLimit plan)>0
        && solPlanFeeLimit plan<=savedSolanaFee costs && solPlanRentLimit plan<=savedSolanaRent costs
        && recentSlot(solPlanRecent plan)>=0 && recentLastValidHeight(solPlanRecent plan)>0
        && request==solanaPayoutRequest config plan) "saved_solana_policy_mismatch"
      either reject pure (H.validateHelperRequest config request)
      pure (SolanaAuthorization plan request)
    Sol -> reject "invalid_payout_asset"

verifySigningReply :: NativeRPC -> Profile -> H.SolanaPolicy -> PreparedPayment -> SigningReply -> IO SignedAttempt
verifySigningReply native profile config prepared reply = do
  authorization <- resolveSigningPlan profile config prepared
  case (authorization,reply) of
    (NativeAuthorization plan draft,NativeReply signed) -> do
      require (not(T.null $ signedNativeBytes signed) && T.length(signedNativeBytes signed)<=200000) "invalid_signed_bytes"
      require (signedNativePlan signed==plan && sameNativeTemplate (draftTransaction draft) (signedNativeTransaction signed)
        && signedNativeFee signed==draftFee draft && sameNativePrevouts (signedNativePrevouts signed) (draftPrevouts draft)) "native_signed_template_changed"
      decoded <- native False "decoderawtransaction" [toJSON $ signedNativeBytes signed] >>= either reject pure . decodeNativeTx
      require (decoded==signedNativeTransaction signed) "native_signed_bytes_mismatch"
      either reject pure (validateNativeTx plan (signedNativePrevouts signed) (signedNativeFee signed) decoded)
      point <- case nativeInputs decoded of input:_->pure(nativeOutpoint input); _->reject "native_input_mismatch"
      pure (SignedAttempt (nativeTxid decoded) (signedNativeBytes signed) (encodeSaved signed) (Just $ outpointTxid point<>":"<>T.pack(show $ outpointVout point)))
    (SolanaAuthorization plan request,SolanaReply signed) -> do
      require (signedSolanaPlan signed==plan && units(signedSolanaFeeEstimate signed)>0
        && signedSolanaFeeEstimate signed<=solPlanFeeLimit plan && signedSolanaRentEstimate signed<=solPlanRentLimit plan) "invalid_saved_payment"
      let value=signedSolanaReply signed
      _ <- either reject pure (H.validateHelperReply config request value)
      signature <- maybe (reject "helper_signature_missing") pure (H.replySignature value)
      pure (SignedAttempt signature (H.replyTransaction value) (encodeSaved signed) Nothing)
    _ -> reject "signer_reply_chain_mismatch"

-- An HTTP reply is untrusted even if its accompanying proof parses. Reconstruct
-- the exact record from independently checked bytes and compare every field.
verifySignedAttempt :: NativeRPC -> Profile -> H.SolanaPolicy -> PreparedPayment -> SignedAttempt -> IO ()
verifySignedAttempt native profile config prepared actual = do
  reply <- case paymentAsset (savedPayment $ preparedView prepared) of
    Native -> NativeReply <$> decodeSaved (signedPolicy actual)
    Wrapped -> SolanaReply <$> decodeSaved (signedPolicy actual)
    Sol -> reject "invalid_payout_asset"
  expected <- verifySigningReply native profile config prepared reply
  require (actual==expected) "signer_attempt_mismatch"

encodeSaved :: ToJSON a => a -> Text
encodeSaved=TE.decodeUtf8 . BL.toStrict . encode
decodeSaved :: FromJSON a => Text -> IO a
decodeSaved=either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8
