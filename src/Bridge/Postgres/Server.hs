module Bridge.Postgres.Server (customerServer,adminServer) where
import Bridge.API
import Bridge.Operation
import qualified Data.Text as T
import Servant

customerServer :: ServerT CustomerAPI Plan
customerServer = safe PublicConfig
  :<|> (\header request->customer(CreateOrder header request))
  :<|> (\oid header->safe(OrderStatus header oid))
  :<|> (\oid header->customer(PaymentInstructions header oid))
  :<|> (\oid header hint->customer(DepositHint header oid (signature hint)))
  :<|> safe Health
  :<|> safe ReadyEndpoint

adminServer :: ServerT AdminAPI Plan
adminServer = safe Readiness
  :<|> (\request->operator(Pause(T.take 120 $ pauseReason request)))
  :<|> safe Audit
  :<|> safe Scanners
