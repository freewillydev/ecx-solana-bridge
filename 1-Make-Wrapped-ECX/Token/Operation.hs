{-# LANGUAGE DataKinds, GADTs, FunctionalDependencies, KindSignatures #-}
-- Administration requests cannot change their severity or result type at dispatch.
module Token.Operation (Severity(..),Operation(..),Request(..),DSL,resolve,runSafe,runCritical) where
import Data.Kind (Type)
import qualified Token
import qualified Token.Network as Network
import qualified Token.Signing as Signing

data Severity = Safe | Critical
class Operation (s :: Severity) (op :: Type -> Type) | op -> s where
  command :: op a -> DSL s a

data Request (s :: Severity) a where
  Request :: Operation s op => op a -> Request s a

data DSL (s :: Severity) a where
  Prepare :: Token.Safe a -> DSL 'Safe a
  Inspect :: Network.Safe a -> DSL 'Safe a
  Sign :: Signing.Critical a -> DSL 'Critical a
  Submit :: Network.Critical a -> DSL 'Critical a

instance Operation 'Safe Token.Safe where command = Prepare
instance Operation 'Safe Network.Safe where command = Inspect
instance Operation 'Critical Signing.Critical where command = Sign
instance Operation 'Critical Network.Critical where command = Submit

resolve :: Request s a -> DSL s a
resolve (Request operation) = command operation

runSafe :: Request 'Safe a -> IO a
runSafe request = evalSafe (resolve request)

runCritical :: Request 'Critical a -> IO a
runCritical request = evalCritical (resolve request)

evalSafe :: DSL 'Safe a -> IO a
evalSafe (Prepare operation) = Token.evalSafe operation
evalSafe (Inspect operation) = Network.evalSafe operation

evalCritical :: DSL 'Critical a -> IO a
evalCritical (Sign operation) = Signing.evalCritical operation
evalCritical (Submit operation) = Network.evalCritical operation
