{-# LANGUAGE DataKinds, GADTs, FunctionalDependencies, KindSignatures #-}
-- CLI requests retain their result and severity while hiding the operation type.
module Pool.Operation (Severity(..),Operation(..),Request(..),DSL,resolve,runSafe,runCritical) where
import Data.Kind (Type)
import qualified Pool as Pool
import qualified Pool.Position as Position
import qualified Pool.Liquidity as Liquidity
import qualified Pool.Signing as Signing

data Severity = Safe | Critical
class Operation (s :: Severity) (op :: Type -> Type) | op -> s where
  command :: op a -> DSL s a

data Request (s :: Severity) a where
  Request :: Operation s op => op a -> Request s a

data DSL (s :: Severity) a where
  SubmissionRead :: Signing.Safe a -> DSL 'Safe a
  PoolRead :: Pool.Safe a -> DSL 'Safe a
  PositionRead :: Position.Safe a -> DSL 'Safe a
  LiquidityRead :: Liquidity.Safe a -> DSL 'Safe a
  SignedAction :: Signing.Critical a -> DSL 'Critical a

instance Operation 'Safe Signing.Safe where command = SubmissionRead
instance Operation 'Safe Pool.Safe where command = PoolRead
instance Operation 'Safe Position.Safe where command = PositionRead
instance Operation 'Safe Liquidity.Safe where command = LiquidityRead
instance Operation 'Critical Signing.Critical where command = SignedAction

resolve :: Request s a -> DSL s a
resolve (Request operation) = command operation

runSafe :: Request 'Safe a -> IO a
runSafe request = evalSafe (resolve request)

runCritical :: Request 'Critical a -> IO a
runCritical request = evalCritical (resolve request)

evalSafe :: DSL 'Safe a -> IO a
evalSafe (SubmissionRead operation) = Signing.evalSafe operation
evalSafe (PoolRead operation) = Pool.evalSafe operation
evalSafe (PositionRead operation) = Position.evalSafe operation
evalSafe (LiquidityRead operation) = Liquidity.evalSafe operation

evalCritical :: DSL 'Critical a -> IO a
evalCritical (SignedAction operation) = Signing.evalCritical operation
