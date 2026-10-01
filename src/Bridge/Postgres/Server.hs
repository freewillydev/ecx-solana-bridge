{-# LANGUAGE DataKinds,TypeOperators,DeriveGeneric,DeriveAnyClass #-}
module Bridge.Postgres.Server (customerServer,adminServer,operatorAPI) where
import Bridge.API
import Bridge.Types (Availability)
import Data.Aeson (FromJSON)
import qualified Data.Aeson
import Data.Text (Text)
import Data.Int (Int64)
import GHC.Generics (Generic)
import Bridge.Operation
import qualified Data.Text as T
import Servant

customerServer :: ServerT CustomerAPI Plan
customerServer = safe PublicConfig
  :<|> (\header request->customer(CreateOrder header request))
  :<|> (\oid header->safe(OrderStatus header oid))
  :<|> (\oid header->safe(PaymentInstructions header oid))
  :<|> (\oid header hint->customer(DepositHint header oid (signature hint)))
  :<|> safe Health
  :<|> safe ReadyEndpoint

data RefundRequest = RefundRequest { depositId :: Text } deriving (Generic,FromJSON)
data RetryRequest = RetryRequest { transaction :: Text, reason :: Text } deriving (Generic,FromJSON)
data CancelRequest = CancelRequest { intent :: Text, generation :: Int, cancellationReason :: Text } deriving (Generic,FromJSON)
data SourceRecoveryRequest = SourceRecoveryRequest { obligation :: Text, restorationSequence :: Int64, approvalReason :: Text } deriving (Generic,FromJSON)
type OperatorAPI = AdminAPI :<|> "refund" :> ReqBody '[JSON] RefundRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "retry-solana" :> ReqBody '[JSON] RetryRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "cancel-preparation" :> ReqBody '[JSON] CancelRequest :> Post '[JSON] Data.Aeson.Value
  :<|> "approve-source-recovery" :> ReqBody '[JSON] SourceRecoveryRequest :> Post '[JSON] Data.Aeson.Value
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
  :<|> operator Resume
