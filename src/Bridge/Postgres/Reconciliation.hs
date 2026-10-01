{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Postgres.Reconciliation (reconcileCustodyWith) where

import Bridge.Config
import Bridge.Types
import Bridge.Reconciliation (CustodyStore(..),inspectCustodyWith)
import Bridge.Settlement (PaymentTransport)
import Bridge.Postgres.PaymentStore
import Bridge.Postgres.Ledger
import qualified Bridge.Postgres.Custody as C
import Control.Exception (IOException,catch,try)
import Data.Aeson (Value,object,(.=))
import Data.Int (Int64)

reconcileCustodyWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> IO Value
reconcileCustodyWith clock transport cfg ledger = do
  let store=Store ledger
  expected <- custodyRevision store
  result <- try (inspectCustodyWith clock transport cfg store False `catch` (\(_::IOException)->reject "custody_rpc_unavailable")) :: IO (Either BridgeError (Int64,Int64,Bool,Value))
  case result of
    Right (revision,at,matches,report)->do
      C.recordCheck ledger revision at (if matches then Nothing else Just "custody_balance_mismatch") (Just report)
      pure (object ["matches" .= matches,"revision" .= revision,"report" .= report])
    Left (BridgeError code)->do
      at <- clock
      C.recordCheck ledger expected at (Just code) Nothing
      pure (object ["matches" .= False,"error" .= code])
