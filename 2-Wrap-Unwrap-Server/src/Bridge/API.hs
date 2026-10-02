{-# LANGUAGE DataKinds, TypeOperators #-}
module Bridge.API (CustomerAPI, customerAPI, PublicConfiguration(..), PaymentInstruction(..)) where
import Bridge.Types (OrderRequest, OrderView)
import Bridge.Model (PublicConfiguration(..), PaymentInstruction(..))
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
