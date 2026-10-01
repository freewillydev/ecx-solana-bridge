module Bridge.Payment (prepareNativePayment, prepareNativeWith) where

import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment
import Bridge.Types
import Control.Exception (onException)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)

json :: ToJSON a => a -> Text
json = TE.decodeUtf8 . LBS.toStrict . encode
stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8

-- No broadcast occurs here. The separate first-send decision must still
-- recheck source/freshness, journal BroadcastIntent and satisfy backup coverage.
prepareNativePayment :: Manager -> Config -> Ledger -> Obligation -> IO Text
prepareNativePayment manager c ledger obligation = do
  _ <- nativeIdentity manager c
  prepareNativeWith (nativeCall manager c) c ledger obligation

prepareNativeWith :: NativeRPC -> Config -> Ledger -> Obligation -> IO Text
prepareNativeWith call c ledger obligation = prepare `onException` pause ledger "native_preparation_requires_review"
 where
  prepare = do
    require (obligationAsset obligation=="Native") "wrong_destination_chain"
    quantity <- either reject pure (amount $ toInteger $ obligationAmount obligation)
    policies <- ledgerAction ledger $ \db -> query db "SELECT policy_json FROM orders WHERE id=?" (Only $ obligationOrder obligation) :: IO [Only Text]
    policy <- case policies of [Only value] -> stored value; _ -> reject "order_not_found"
    require (deploymentFingerprint policy==fingerprint c) "payment_profile_mismatch"
    attempts <- filter ((==obligationId obligation) . attemptIntent) <$> pendingAttempts ledger
    case attempts of
      [attempt] -> do
        signed <- stored (attemptPolicy attempt)
        validateSaved quantity policy (signedNativePlan signed)
        require (attemptChain attempt=="Native" && attemptBytes attempt==signedNativeBytes signed
          && attemptId attempt==nativeTxid (signedNativeTransaction signed)) "invalid_saved_payment"
        either reject pure (validateNativeTx (signedNativePlan signed) (signedNativePrevouts signed) (signedNativeFee signed) (signedNativeTransaction signed))
        pure (attemptId attempt)
      [] -> do
        state <- readiness ledger
        require (available state) "payouts_paused"
        preparations <- filter ((==obligationId obligation) . obligationId . preparationObligation) <$> pendingPreparations ledger
        (plan,savedDraft) <- case preparations of
          [] -> do
            plan <- newNativePlan call (profile c) (nativeDepth policy) (maxNativeFee c) (obligationRecipient obligation) quantity
            beginPreparation ledger obligation "Native" (units $ planFeeLimit plan) (json plan)
            pure (plan,Nothing)
          [p] -> do
            plan <- stored (preparationPolicy p)
            require (preparationObligation p==obligation && preparationChain p=="Native" && preparationFeeLimit p==units (planFeeLimit plan)) "invalid_saved_payment"
            pure (plan,preparationDraft p)
          _ -> reject "duplicate_preparation"
        validateSaved quantity policy plan
        draft <- case savedDraft of
          Just value -> stored value
          Nothing -> do
            value <- fundNativeDraft call plan
            storeDraft ledger (obligationId obligation) (json value)
            pure value
        signed <- signNativeDraft call plan draft
        let txid=nativeTxid (signedNativeTransaction signed)
            points=map nativeOutpoint (nativeInputs $ signedNativeTransaction signed)
        first <- case points of point:_ -> pure point; [] -> reject "native_input_mismatch"
        storeAttempt ledger obligation "Native" txid (signedNativeBytes signed) (json signed)
          (units $ planFeeLimit plan) (Just $ outpointTxid first<>":"<>T.pack (show $ outpointVout first))
        pure txid
      _ -> reject "multiple_initial_native_attempts"
  validateSaved quantity policy plan = require
    (planProfile plan==profile c && planRecipient plan==obligationRecipient obligation && planAmount plan==quantity
      && planDepth plan==nativeDepth policy && planFeeLimit plan<=maxNativeFee c)
    "saved_native_policy_mismatch"
