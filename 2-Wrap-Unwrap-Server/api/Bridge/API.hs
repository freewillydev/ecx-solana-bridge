{-# LANGUAGE DataKinds, TypeOperators #-}
module Bridge.API (CustomerAPI, customerAPI, customerServer, PublicConfiguration(..), PaymentInstruction(..)) where
import Bridge.Types (OrderRequest, OrderView)
import Bridge.Model (PublicConfiguration(..), PaymentInstruction(..))
import Bridge.Operation (Plan, SafeOperation(PublicConfig,OrderStatus,PaymentInstructions), CustomerOperation(CreateOrder), safe, customer)
import Data.Text (Text)
import Servant

type Auth = Header' '[Required,Strict] "Authorization" Text
type CustomerAPI =
       "api" :> "v1" :> "config" :> Get '[JSON] PublicConfiguration
  :<|> "api" :> "v1" :> "orders" :> Auth :> ReqBody '[JSON] OrderRequest :> Post '[JSON] OrderView
  :<|> "api" :> "v1" :> "orders" :> Capture "id" Text :> Auth :> Get '[JSON] OrderView
  :<|> "api" :> "v1" :> "orders" :> Capture "id" Text :> "transaction" :> Auth :> Post '[JSON] PaymentInstruction

customerAPI :: Proxy CustomerAPI
customerAPI = Proxy

-- Each endpoint returns an existential operation dictionary. Runtime resolves
-- it into the severity-indexed DSL at the evaluator boundary.
customerServer :: ServerT CustomerAPI Plan
customerServer = safe PublicConfig
  :<|> (\header request -> customer (CreateOrder header request))
  :<|> (\oid header -> safe (OrderStatus header oid))
  :<|> (\oid header -> safe (PaymentInstructions header oid))
