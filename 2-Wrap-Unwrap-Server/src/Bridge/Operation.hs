-- Only this facade is visible to the customer API Cabal component.
module Bridge.Operation
  ( Caller(Customer), Plan, CustomerOperations, CustomerRead(..), CustomerWrite(..), safe, customer ) where
import Bridge.Operation.Internal
