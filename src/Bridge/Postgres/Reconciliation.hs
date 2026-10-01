{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Postgres.Reconciliation (reconcileCustodyWith) where

import Bridge.Config
import Bridge.Reconciliation (reconcileCustodyRecordWith)
import Bridge.Settlement (PaymentTransport)
import Bridge.Postgres.PaymentStore
import Bridge.Postgres.Ledger
import qualified Bridge.Postgres.Custody as C
import Data.Aeson (Value)
import Data.Int (Int64)

reconcileCustodyWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> IO Value
reconcileCustodyWith clock transport cfg ledger =
  reconcileCustodyRecordWith (C.recordCheck ledger) clock transport cfg (Store ledger)
