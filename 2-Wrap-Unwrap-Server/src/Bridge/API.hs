{-# LANGUAGE DataKinds, TypeOperators #-}
module Bridge.API where
import Bridge.Types
import Data.Aeson (Value,FromJSON,ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant

data Hint = Hint { signature :: Text } deriving (Show,Generic,FromJSON,ToJSON)
data PauseRequest = PauseRequest { pauseReason :: Text } deriving (Show,Generic,FromJSON,ToJSON)
type Auth = Header' '[Required,Strict] "Authorization" Text
type CustomerAPI =
       "api" :> "v1" :> "config" :> Get '[JSON] Value
  :<|> "api" :> "v1" :> "orders" :> Auth :> ReqBody '[JSON] OrderRequest :> Post '[JSON] OrderView
  :<|> "api" :> "v1" :> "orders" :> Capture "id" Text :> Auth :> Get '[JSON] OrderView
  :<|> "api" :> "v1" :> "orders" :> Capture "id" Text :> "transaction" :> Auth :> Post '[JSON] Value
  :<|> "api" :> "v1" :> "orders" :> Capture "id" Text :> "observations" :> Auth :> ReqBody '[JSON] Hint :> Post '[JSON] Value
  :<|> "healthz" :> Get '[JSON] Availability
  :<|> "readyz" :> Get '[JSON] Availability
type AdminAPI = "health" :> Get '[JSON] Availability
  :<|> "pause" :> ReqBody '[JSON] PauseRequest :> Post '[JSON] Availability
  :<|> "audit" :> Get '[JSON] Value
  :<|> "scanners" :> Get '[JSON] Value
customerAPI :: Proxy CustomerAPI
customerAPI = Proxy
adminAPI :: Proxy AdminAPI
adminAPI = Proxy
