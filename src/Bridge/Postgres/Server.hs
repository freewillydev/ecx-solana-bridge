{-# LANGUAGE DataKinds,TypeOperators,DeriveGeneric,DeriveAnyClass #-}
module Bridge.Postgres.Server (customerServer,adminServer,operatorAPI) where
import Bridge.API
import Data.Aeson (FromJSON)
import qualified Data.Aeson
import Data.Text (Text)
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
type OperatorAPI = AdminAPI :<|> "refund" :> ReqBody '[JSON] RefundRequest :> Post '[JSON] Data.Aeson.Value
operatorAPI :: Proxy OperatorAPI
operatorAPI = Proxy
adminServer :: ServerT OperatorAPI Plan
adminServer = (safe Readiness
  :<|> (\request->operator(Pause(T.take 120 $ pauseReason request)))
  :<|> safe Audit
  :<|> safe Scanners)
  :<|> (\request->operator(RefundDeposit(depositId request)))
