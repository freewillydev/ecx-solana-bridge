-- Customer handlers can construct only these closed operations.
module Bridge.Operation
  ( Plan, SafeOperation(PublicConfig,PaymentInstructions,OrderStatus)
  , CustomerOperation(..), safe, customer ) where
import Bridge.Operation.Internal
