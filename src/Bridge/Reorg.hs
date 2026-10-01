{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Reorg (reconcileNativeSettlements,reconcileNativeSettlementsWith) where

import Bridge.Config
import Bridge.Ledger
import Bridge.Native (nativeIdentity)
import Bridge.RPC
import Bridge.Settlement
import Bridge.Types
import Control.Exception (IOException,catch,try)
import Control.Monad (when)
import Data.Aeson
import Data.Text (Text)
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)

-- Recheck previously settled native bytes when their recorded finality changed.
-- No source funds, reservation, fee, signature or intent is created or released.
reconcileNativeSettlements :: Manager -> Config -> Ledger -> IO Value
reconcileNativeSettlements manager c=reconcileNativeSettlementsWith
  (realPaymentTransport manager c (const $ reject "unexpected_reorg_backup"))
    {paymentIdentity=nativeIdentity manager c >> pure ()} c

reconcileNativeSettlementsWith :: PaymentTransport -> Config -> Ledger -> IO Value
reconcileNativeSettlementsWith transport c ledger=do
  candidates <- nativeSettlementCandidates ledger
  when (length candidates>1000) $ pause ledger "native_settlement_recovery_backlog"
  require (length candidates<=1000) "native_settlement_recovery_backlog"
  reports <- mapM reconcile candidates
  pure $ object ["payments" .= reports,"signedOrSent" .= False,"monetaryPostings" .= False]
 where
  reconcile attempt=do
    old <- ledgerAction ledger $ \db->query db "SELECT observation_json FROM attempts WHERE txid=?" (Only $ attemptId attempt) :: IO [Only Text]
    previous <- case old of [Only saved]->pure saved; _->reject "native_settlement_missing"
    checked <- try (inspect attempt `catch` (\(_::IOException)->reject "native_recovery_io_unavailable")) :: IO (Either BridgeError NativeSettlementCheck)
    let result=either (\(BridgeError code)->NativeSettlementUnavailable code) id checked
    committed <- try (recordNativeSettlementCheck ledger attempt previous result) :: IO (Either BridgeError ())
    case committed of
      Left (BridgeError code)->do
        pending <- try (recordNativeSettlementCheck ledger attempt previous (NativeSettlementUnavailable code)) :: IO (Either BridgeError ())
        case pending of
          Right ()->pure $ report attempt "requires_review" (Just code)
          Left (BridgeError changed)->do
            pause ledger ("native_settlement_recovery:"<>changed)
            pure $ report attempt "requires_review" (Just changed)
      Right ()->pure $ case result of
        NativeSettlementConfirming->report attempt "confirming" Nothing
        NativeSettlementUnavailable code->report attempt "requires_review" (Just code)
        NativeSettlementReconfirmed _ _->report attempt "reconfirmed" Nothing
  inspect attempt=do
    paymentIdentity transport
    wallet <- paymentNative transport True "getwalletinfo" []
    name <- fieldValue "walletname" wallet
    descriptors <- fieldValue "descriptors" wallet
    scanning <- fieldValue "scanning" wallet :: IO Value
    require (name==nativeWallet c && descriptors && scanning==Bool False) "native_wallet_not_ready"
    (_,saved) <- readSavedPayment transport c ledger attempt
    payment <- case saved of NativePayment value->pure value; _->reject "wrong_destination_chain"
    observeNativePayment (paymentNative transport) payment >>= \case
      PaymentConfirmed costs proof->pure $ NativeSettlementReconfirmed costs proof
      PaymentWaiting->pure NativeSettlementConfirming
      PaymentUnseen->pure $ NativeSettlementUnavailable "native_settled_payment_unseen"
      PaymentFailed _ _->reject "unexpected_native_payment_failure"
  report attempt state failure=object ["transaction" .= attemptId attempt,"state" .= (state::Text),"error" .= (failure::Maybe Text)]
