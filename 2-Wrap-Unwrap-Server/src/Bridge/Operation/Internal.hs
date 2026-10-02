{-# LANGUAGE DataKinds,GADTs,KindSignatures,MultiParamTypeClasses,FunctionalDependencies,FlexibleInstances #-}
module Bridge.Operation.Internal where

import Bridge.API (PublicConfiguration, PaymentInstruction)
import Bridge.Types
import Bridge.Ledger.Model (LossCapital)
import Data.Aeson (Value)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Int (Int64)

data Severity = Safe | Critical
class Operation (s :: Severity) (op :: Type -> Type) | op -> s where
  command :: op a -> DSL s a

data SafeOperation a where
  VerifyReadRole :: SafeOperation ()
  DatabaseIdentity :: Text -> SafeOperation Value
  PublicConfig :: SafeOperation PublicConfiguration
  PaymentInstructions :: Text -> Text -> SafeOperation PaymentInstruction
  OrderStatus :: Text -> Text -> SafeOperation OrderView
  Readiness :: SafeOperation Availability
  Audit :: SafeOperation Value
  Scanners :: SafeOperation Value

data CustomerOperation a where
  CreateOrder :: Text -> OrderRequest -> CustomerOperation OrderView

data OperatorOperation a where
  Pause :: Text -> OperatorOperation Availability
  CancelPreparation :: Text -> Int -> Text -> OperatorOperation Value
  Resume :: OperatorOperation Availability
  ApproveSolanaRetry :: Text -> Text -> OperatorOperation Value
  ApproveCoveredSource :: Text -> Int64 -> Text -> OperatorOperation Value
  RebroadcastNative :: Text -> Int64 -> Text -> OperatorOperation Value
  ApproveSourceRecovery :: Text -> Int64 -> Text -> OperatorOperation Value
  PrepareNativeReplacement :: Text -> Amount -> Text -> OperatorOperation Value
  SignNativeReplacement :: Int64 -> OperatorOperation Value
  CancelNativeReplacement :: Int64 -> Text -> OperatorOperation Value
  SendNativeReplacement :: Int64 -> OperatorOperation Value
  CoverSourceLoss :: Text -> Int64 -> LossCapital -> Text -> OperatorOperation Value
  AllocateTreasury :: Text -> [(Text,Amount)] -> Text -> OperatorOperation Value
  ClassifyTreasurySpend :: Text -> Text -> Text -> OperatorOperation Value
  RefundDeposit :: Text -> OperatorOperation Value

data WorkerOperation a where
  ScanAndReconcile :: WorkerOperation Value
  StartPayments :: WorkerOperation ()
  AdvancePayments :: WorkerOperation ()

-- Only the dedicated signer server can interpret this vocabulary.
data SigningOperation a where
  DraftReplacement :: Text -> Text -> Amount -> SigningOperation Value
  SignPrepared :: Text -> Text -> Int -> SigningOperation Value
  SignReplacement :: Text -> Int64 -> SigningOperation Value

data DSL (s :: Severity) a where
  SigningDSL :: SigningOperation a -> DSL 'Critical a
  SafeDSL :: SafeOperation a -> DSL 'Safe a
  CustomerDSL :: CustomerOperation a -> DSL 'Critical a
  OperatorDSL :: OperatorOperation a -> DSL 'Critical a
  WorkerDSL :: WorkerOperation a -> DSL 'Critical a
instance Operation 'Critical SigningOperation where command = SigningDSL
instance Operation 'Safe SafeOperation where command = SafeDSL
instance Operation 'Critical CustomerOperation where command = CustomerDSL
instance Operation 'Critical OperatorOperation where command = OperatorDSL
instance Operation 'Critical WorkerOperation where command = WorkerDSL

data Request (s :: Severity) a where
  Request :: Operation s op => op a -> Request s a
resolve :: Request s a -> DSL s a
resolve (Request operation) = command operation

data Plan a where
  SigningPlan :: Request 'Critical a -> Plan a
  SafePlan :: Request 'Safe a -> Plan a
  CustomerPlan :: Request 'Critical a -> Plan a
  OperatorPlan :: Request 'Critical a -> Plan a
  WorkerPlan :: Request 'Critical a -> Plan a

safe :: SafeOperation a -> Plan a
safe operation = SafePlan (Request operation)
customer :: CustomerOperation a -> Plan a
customer operation = CustomerPlan (Request operation)
operator :: OperatorOperation a -> Plan a
operator operation = OperatorPlan (Request operation)
worker :: WorkerOperation a -> Plan a
worker operation = WorkerPlan (Request operation)

signing :: SigningOperation a -> Plan a
signing operation = SigningPlan (Request operation)
