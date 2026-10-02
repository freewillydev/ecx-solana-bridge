{-# LANGUAGE DataKinds,TypeOperators,DeriveGeneric,DeriveAnyClass #-}
module Bridge.Postgres.Server (customerServer,adminServer,operatorAPI) where
import Bridge.API
import Bridge.Ledger.Model (LossCapital)
import Bridge.Types (Availability,Amount)
import Data.Aeson (FromJSON)
import qualified Data.Aeson
import Data.Text (Text)
import Data.Int (Int64)
import GHC.Generics (Generic)
import Bridge.Operation
import qualified Data.Text as T
import Servant

-- Pure endpoint results retain the existential Operation dictionary. Runtime
-- calls its command method to obtain the DSL, then selects the evaluator.
customerServer :: ServerT CustomerAPI Plan
customerServer = safe PublicConfig
  :<|> (\header request->customer(CreateOrder header request))
  :<|> (\oid header->safe(OrderStatus header oid))
  :<|> (\oid header->safe(PaymentInstructions header oid))
  :<|> (\oid header hint->customer(DepositHint header oid (signature hint)))
  :<|> safe Health
  :<|> safe ReadyEndpoint

data TreasuryRequest = TreasuryRequest { treasuryReceipt :: Text, treasurySplit :: [(Text,Amount)], ownershipAttestation :: Text } deriving (Generic,FromJSON)
data TreasurySpendRequest = TreasurySpendRequest { observationStream :: Text, observedTransaction :: Text, spendOwnershipAttestation :: Text } deriving (Generic,FromJSON)
data RefundRequest = RefundRequest { depositId :: Text } deriving (Generic,FromJSON)
data RetryRequest = RetryRequest { transaction :: Text, reason :: Text } deriving (Generic,FromJSON)
data CancelRequest = CancelRequest { intent :: Text, generation :: Int, cancellationReason :: Text } deriving (Generic,FromJSON)
data SourceRecoveryRequest = SourceRecoveryRequest { obligation :: Text, restorationSequence :: Int64, approvalReason :: Text } deriving (Generic,FromJSON)
data CoveredSourceRequest = CoveredSourceRequest { coveredObligation :: Text, coveredLossSequence :: Int64, coveredApprovalReason :: Text } deriving (Generic,FromJSON)
data NativeRebroadcastRequest = NativeRebroadcastRequest { rebroadcastTransaction :: Text, rebroadcastRecoverySequence :: Int64, rebroadcastReason :: Text } deriving (Generic,FromJSON)
data ReplacementDraftRequest = ReplacementDraftRequest { parentTransaction :: Text, replacementFee :: Amount, replacementReason :: Text } deriving (Generic,FromJSON)
data ReplacementRequest = ReplacementRequest { draftSequence :: Int64 } deriving (Generic,FromJSON)
data ReplacementCancelRequest = ReplacementCancelRequest { cancelledDraftSequence :: Int64, replacementCancellationReason :: Text } deriving (Generic,FromJSON)
data LossCoverRequest = LossCoverRequest { lossDeposit :: Text, lossRecoverySequence :: Int64, lossCapital :: LossCapital, lossReason :: Text } deriving (Generic,FromJSON)
type OperatorAPI = AdminAPI :<|> "refund" :> ReqBody '[JSON] RefundRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "retry-solana" :> ReqBody '[JSON] RetryRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "cancel-preparation" :> ReqBody '[JSON] CancelRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "approve-source-recovery" :> ReqBody '[JSON] SourceRecoveryRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "approve-covered-source" :> ReqBody '[JSON] CoveredSourceRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "rebroadcast-native" :> ReqBody '[JSON] NativeRebroadcastRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "prepare-native-replacement" :> ReqBody '[JSON] ReplacementDraftRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "sign-native-replacement" :> ReqBody '[JSON] ReplacementRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "cancel-native-replacement" :> ReqBody '[JSON] ReplacementCancelRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "send-native-replacement" :> ReqBody '[JSON] ReplacementRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "cover-source-loss" :> ReqBody '[JSON] LossCoverRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "allocate-treasury" :> ReqBody '[JSON] TreasuryRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "classify-treasury-spend" :> ReqBody '[JSON] TreasurySpendRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "resume" :> Post '[JSON] Availability
operatorAPI :: Proxy OperatorAPI
operatorAPI = Proxy
adminServer :: ServerT OperatorAPI Plan
adminServer = (safe Readiness
  :<|> (\request->operator(Pause(T.take 120 $ pauseReason request)))
  :<|> safe Audit
  :<|> safe Scanners)
  :<|> (\request->operator(RefundDeposit(depositId request)))
  :<|> (\request->operator(ApproveSolanaRetry(transaction request)(reason request)))
  :<|> (\request->operator(CancelPreparation(intent request)(generation request)(cancellationReason request)))
  :<|> (\request->operator(ApproveSourceRecovery(obligation request)(restorationSequence request)(approvalReason request)))
  :<|> (\request->operator(ApproveCoveredSource(coveredObligation request)(coveredLossSequence request)(coveredApprovalReason request)))
  :<|> (\request->operator(RebroadcastNative(rebroadcastTransaction request)(rebroadcastRecoverySequence request)(rebroadcastReason request)))
  :<|> (\request->operator(PrepareNativeReplacement(parentTransaction request)(replacementFee request)(replacementReason request)))
  :<|> (\request->operator(SignNativeReplacement(draftSequence request)))
  :<|> (\request->operator(CancelNativeReplacement(cancelledDraftSequence request)(replacementCancellationReason request)))
  :<|> (\request->operator(SendNativeReplacement(draftSequence request)))
  :<|> (\request->operator(CoverSourceLoss(lossDeposit request)(lossRecoverySequence request)(lossCapital request)(lossReason request)))
  :<|> (\request->operator(AllocateTreasury(treasuryReceipt request)(treasurySplit request)(ownershipAttestation request)))
  :<|> (\request->operator(ClassifyTreasurySpend(observationStream request)(observedTransaction request)(spendOwnershipAttestation request)))
  :<|> operator Resume
