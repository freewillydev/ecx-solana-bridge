module Bridge.Postgres.NativeRebroadcast (rebroadcastWith) where

import Bridge.Config
import Bridge.Types
import Bridge.Ledger (Attempt(..))
import Bridge.NativeReplacement (NativeFamilyView(..))
import Bridge.Settlement
import Bridge.RPC (fieldValue,parseValue)
import Bridge.Postgres.Ledger (Ledger,pause,readiness)
import Bridge.Postgres.PaymentStore (Store(..))
import qualified Bridge.Postgres.NativeRecovery as Recovery
import Control.Exception (onException)
import Control.Monad (when)
import Data.Aeson (Value,object,(.=),toJSON,parseJSON)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- Explicit repair of the original native payment, including after a lost send
-- reply. Never create a signature, release principal or resume payment intake.
-- All family members share the original inputs; the chain adapter validates
-- current wallet/tip, saved outputs/fees, and every actual previous output.
rebroadcastWith :: PaymentTransport -> Config -> Ledger -> Text -> Int64 -> Text -> IO Value
rebroadcastWith transport cfg ledger txid anchor reason = work `onException` pause ledger "native_rebroadcast_requires_review"
 where
  store=Store ledger
  work=do
    require (anchor>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_native_rebroadcast_approval"
    state <- readiness ledger
    require (not $ available state) "pause_before_operator_action"
    previous <- Recovery.rebroadcastDecision ledger txid anchor reason
    candidates <- Recovery.candidates ledger
    require (length candidates<=1000) "native_settlement_recovery_backlog"
    attempt <- case filter ((==txid).attemptId) candidates of
      [saved]->pure saved
      _->reject "native_rebroadcast_payment_not_in_review"
    paymentIdentity transport
    (ob,_) <- readSavedPayment transport cfg store attempt
    family <- paymentNativeFamily store (attemptIntent attempt)
    view <- missing family
    recheckSourceWith transport cfg store ob
    block <- paymentNative transport False "getblockchaininfo" [] >>= fieldValue "bestblockhash" :: IO Text
    let proof=object["transaction" .= txid,"bytesHash" .= digest(TE.encodeUtf8 $ attemptBytes attempt),
          "nodeBlock" .= block,"family" .= map attemptId family,
          "noActiveFamilyPayment" .= (familyActive view==Nothing)]
    approved <- case previous of
      Just sequenceNo->pure sequenceNo
      Nothing->Recovery.recordRebroadcast ledger attempt family anchor reason proof
    when (backupRequired cfg) $ paymentBackup transport approved
    -- Upload can take time. Repeat actual identity, source and input/tip proofs
    -- immediately before the short ledger authorization and exact-byte send.
    paymentIdentity transport
    recheckSourceWith transport cfg store ob
    _ <- missing family
    Recovery.authorizeRebroadcast ledger (backupRequired cfg) attempt family approved
    actual <- paymentNative transport True "sendrawtransaction" [toJSON $ attemptBytes attempt] >>= parseValue parseJSON
    require (actual==txid) "native_broadcast_identity_mismatch"
    pure(object["transaction" .= txid,"approvalSequence" .= approved,
      "outcome" .= ("rebroadcast"::Text),"paused" .= True,"newSignature" .= False,
      "newPrincipalPosting" .= False])
  missing family=do
    (_,view) <- readSavedNativeFamily transport cfg store family
    require (familyActive view==Nothing) "native_rebroadcast_payment_not_missing"
    pure view
