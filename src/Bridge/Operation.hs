-- HTTP handlers see only the closed customer/operator constructors. They cannot
-- construct a worker command, a raw DSL node or an arbitrary IO evaluation.
module Bridge.Operation
  ( Plan, SafeOperation(..), CustomerOperation(..), OperatorOperation(..)
  , safe, customer, operator ) where
import Bridge.Operation.Internal
