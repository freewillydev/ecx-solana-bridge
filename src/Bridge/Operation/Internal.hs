{-# LANGUAGE DataKinds,GADTs,KindSignatures,MultiParamTypeClasses,FunctionalDependencies,FlexibleInstances #-}
module Bridge.Operation.Internal where

import Bridge.Types
import Data.Aeson (Value)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Int (Int64)

data Severity = Safe | Critical
class Operation (s :: Severity) (op :: Type -> Type) | op -> s where
  command :: op a -> DSL s a

data SafeOperation a where
  PublicConfig :: SafeOperation Value
  PaymentInstructions :: Text -> Text -> SafeOperation Value
  OrderStatus :: Text -> Text -> SafeOperation OrderView
  Health :: SafeOperation Availability
  Readiness :: SafeOperation Availability
  ReadyEndpoint :: SafeOperation Availability
  Audit :: SafeOperation Value
  Scanners :: SafeOperation Value

data CustomerOperation a where
  CreateOrder :: Text -> OrderRequest -> CustomerOperation OrderView
  DepositHint :: Text -> Text -> Text -> CustomerOperation Value

data OperatorOperation a where
  Pause :: Text -> OperatorOperation Availability
  CancelPreparation :: Text -> Int -> Text -> OperatorOperation Value
  Resume :: OperatorOperation Availability
  ApproveSolanaRetry :: Text -> Text -> OperatorOperation Value
  ApproveSourceRecovery :: Text -> Int64 -> Text -> OperatorOperation Value
  RefundDeposit :: Text -> OperatorOperation Value

data WorkerOperation a where
  ScanAndReconcile :: WorkerOperation Value
  StartPayments :: WorkerOperation ()
  AdvancePayments :: WorkerOperation ()

data DSL (s :: Severity) a where
  SafeDSL :: SafeOperation a -> DSL 'Safe a
  CustomerDSL :: CustomerOperation a -> DSL 'Critical a
  OperatorDSL :: OperatorOperation a -> DSL 'Critical a
  WorkerDSL :: WorkerOperation a -> DSL 'Critical a
instance Operation 'Safe SafeOperation where command = SafeDSL
instance Operation 'Critical CustomerOperation where command = CustomerDSL
instance Operation 'Critical OperatorOperation where command = OperatorDSL
instance Operation 'Critical WorkerOperation where command = WorkerDSL

data Request (s :: Severity) a where
  Request :: Operation s op => op a -> Request s a
resolve :: Request s a -> DSL s a
resolve (Request operation) = command operation

data Plan a where
  SafePlan :: DSL 'Safe a -> Plan a
  CustomerPlan :: DSL 'Critical a -> Plan a
  OperatorPlan :: DSL 'Critical a -> Plan a
  WorkerPlan :: DSL 'Critical a -> Plan a

safe :: SafeOperation a -> Plan a
safe operation = SafePlan(resolve(Request operation))
customer :: CustomerOperation a -> Plan a
customer operation = CustomerPlan(resolve(Request operation))
operator :: OperatorOperation a -> Plan a
operator operation = OperatorPlan(resolve(Request operation))
worker :: WorkerOperation a -> Plan a
worker operation = WorkerPlan(resolve(Request operation))
