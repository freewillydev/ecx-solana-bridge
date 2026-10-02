{-# LANGUAGE DataKinds, GADTs, RankNTypes, TypeOperators #-}
-- Private signer HTTP only; no customer, operator-control or broadcast routes.
module Bridge.Operator (runSigningServer, signingApplication) where

import Bridge.Config (Config(signerSocket))
import Bridge.Operation.Internal
import Bridge.Types (Amount, reject)
import Bridge.Web (asHandler, runUnix, securityBoundary)
import Control.Concurrent.MVar (newMVar, withMVar)
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Servant
import System.Directory (createDirectoryIfMissing)
import System.FileLock (withFileLock, SharedExclusive(Exclusive))
import System.FilePath (takeDirectory)

type SigningAPI = "sign-preparation" :> ReqBody '[JSON] (Text, Text, Int) :> Post '[JSON] Value
  :<|> "draft-replacement" :> ReqBody '[JSON] (Text, Text, Amount) :> Post '[JSON] Value
  :<|> "sign-replacement" :> ReqBody '[JSON] (Text, Int64) :> Post '[JSON] Value

-- Handlers package the operation dictionary; they cannot sign or access keys.
server :: ServerT SigningAPI (Request 'Critical)
server = (\(identity, intent, generation) -> Request (SignPrepared identity intent generation))
  :<|> (\(identity, parent, fee) -> Request (DraftReplacement identity parent fee))
  :<|> (\(identity, sequenceNo) -> Request (SignReplacement identity sequenceNo))

signingApplication :: (forall a. SigningOperation a -> IO a) -> IO Application
signingApplication evaluate = do
  gate <- newMVar ()
  let interpret :: forall a. Request 'Critical a -> Handler a
      interpret request = asHandler $ withMVar gate $ \_ -> case resolve request of
        SigningDSL operation -> evaluate operation
        _ -> reject "signer_command_required"
      api = Proxy :: Proxy SigningAPI
  securityBoundary (serve api (hoistServer api interpret server))

-- Unix permissions supply private worker access; this never binds a TCP port.
runSigningServer :: Config -> (forall a. SigningOperation a -> IO a) -> IO ()
runSigningServer cfg evaluate = do
  application <- signingApplication evaluate
  createDirectoryIfMissing True (takeDirectory $ signerSocket cfg)
  withFileLock (signerSocket cfg <> ".lock") Exclusive $ \_ ->
    runUnix (signerSocket cfg) 0o660 application
