{-# LANGUAGE DataKinds, TypeOperators #-}
module Bridge.API (CustomerAPI, customerAPI, PublicConfiguration(..), PaymentInstruction(..)) where
import Bridge.Types (OrderRequest, OrderView, Amount, Availability)
import Bridge.Config (Profile, InterfaceConfig)
import Data.Aeson
import Data.Char (toLower)
import Data.Map.Strict (Map)
import GHC.Generics (Generic)
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

-- Result records are wire data. They never contain a DSL or execution authority.
data PublicConfiguration = PublicConfiguration
  { pubProfile :: !Profile, pubSolanaCluster :: !Text, pubLinks :: !InterfaceConfig
  , pubDeployment :: !Text, pubMint :: !Text, pubCustodyOwner :: !Text
  , pubDecimals :: !Int, pubMinInput :: !Amount, pubMaxInput :: !Amount
  , pubFeesBps :: !(Map Text Int), pubIntakeEnabled :: !Bool
  , pubImplementationReady :: !Bool, pubAvailability :: !Availability
  } deriving (Eq, Show, Generic)

publicJSON :: Options
publicJSON = defaultOptions { fieldLabelModifier = \field -> case drop 3 field of
  first:rest -> toLower first:rest
  [] -> [] }
instance ToJSON PublicConfiguration where toJSON = genericToJSON publicJSON
instance FromJSON PublicConfiguration where parseJSON = genericParseJSON publicJSON

data PaymentInstruction = PaymentInstruction
  { uri :: !Text, reference :: !Text, mint :: !Text
  , amount :: !Amount, refundPolicy :: !Text
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)
