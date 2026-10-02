{-# LANGUAGE DataKinds,TypeOperators #-}
module Bridge.Postgres.Server (customerServer) where
import Bridge.API
import Bridge.Operation
import Servant

-- Endpoints package an existential Operation dictionary; Runtime resolves it.
customerServer :: ServerT CustomerAPI Plan
customerServer = safe PublicConfig
  :<|> (\header request -> customer (CreateOrder header request))
  :<|> (\oid header -> safe (OrderStatus header oid))
  :<|> (\oid header -> safe (PaymentInstructions header oid))
