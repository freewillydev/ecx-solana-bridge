{-# LANGUAGE DataKinds, FunctionalDependencies, RoleAnnotations #-}
-- Grammar only. Neither requests nor DSL values contain executable IO.
module Bridge.Operation.Internal where

import Bridge.Wire
import Data.Kind (Type)
import Data.Text (Text)
import Data.Int (Int64)

data Severity = Safe | Critical
data Caller = Customer | Signer | Worker

-- Caller and severity belong to the operation, not to the caller's choice.
class Operation (caller :: Caller) (severity :: Severity) (op :: Type -> Type)
    | op -> caller severity where
  command :: op a -> DSL caller severity a

data CustomerRead a where
  PublicConfig :: CustomerRead PublicConfiguration
  OrderStatus :: Text -> Text -> CustomerRead OrderView
  PaymentInstructions :: Text -> Text -> CustomerRead PaymentInstruction

data CustomerWrite a where
  CreateOrder :: Text -> OrderRequest -> CustomerWrite OrderView

-- Initial signing is tied to a durable decision, never caller-supplied bytes.
data SigningOperation a where
  SignPrepared :: Text -> Text -> Int -> SigningOperation SignedAttempt

data WorkerOperation a where
  ObserveChains :: WorkerOperation ()
  PrepareOutgoing :: Text -> WorkerOperation ()
  ReconcileCustody :: WorkerOperation ()
  SignPreparedPayment :: Text -> WorkerOperation Text
  ReconcilePayment :: Text -> WorkerOperation ()
  QueuePayment :: Text -> WorkerOperation Int64
  BroadcastPayment :: Text -> WorkerOperation ()

data DSL (caller :: Caller) (severity :: Severity) a where
  WorkerDSL :: WorkerOperation a -> DSL 'Worker 'Critical a
  SigningDSL :: SigningOperation a -> DSL 'Signer 'Critical a
  ReadCustomer :: CustomerRead a -> DSL 'Customer 'Safe a
  WriteCustomer :: CustomerWrite a -> DSL 'Customer 'Critical a

instance Operation 'Worker 'Critical WorkerOperation where command = WorkerDSL
instance Operation 'Signer 'Critical SigningOperation where command = SigningDSL
instance Operation 'Customer 'Safe CustomerRead where command = ReadCustomer
instance Operation 'Customer 'Critical CustomerWrite where command = WriteCustomer

data Request (caller :: Caller) (severity :: Severity) a where
  Request :: Operation caller severity op => op a -> Request caller severity a

type role Request nominal nominal nominal
resolve :: Request caller severity a -> DSL caller severity a
resolve (Request op) = command op

-- Retain caller identity through dispatch; a critical customer operation cannot
-- be substituted with a critical operator or signer operation as grammar grows.
data Plan (caller :: Caller) a where
  SafePlan :: Request caller 'Safe a -> Plan caller a
  CriticalPlan :: Request caller 'Critical a -> Plan caller a

type role Plan nominal nominal
safe :: CustomerRead a -> Plan 'Customer a
safe = SafePlan . Request
customer :: CustomerWrite a -> Plan 'Customer a
customer = CriticalPlan . Request
