{-# LANGUAGE CPP, DataKinds, TypeApplications #-}
-- Compile normally for the positive control; each BAD_* macro must fail.
module CapabilityCompile where
import Bridge.Operation.Internal
import Control.Operation
import Data.Coerce (coerce)
import Data.Proxy (Proxy(..))

valid :: Stage '[CompileOperation 'Customer 'Safe ()]
valid = Stage (\value -> compileOperation value `seq` Right value)

#ifdef BAD_COMPILE
hiddenCompile :: Stage '[]
hiddenCompile = Stage (\value -> compileOperation value `seq` Right value)
#endif
#ifdef BAD_WIDEN
widen :: Pipeline (PreparationCaps 'Customer 'Safe ()) '[] (PreparationCaps 'Customer 'Safe ())
widen = Restrict (Proxy @(PreparationCaps 'Customer 'Safe ()))
#endif
#ifdef BAD_CALLER
wrongCaller :: Pending 'Customer 'Critical a -> Pending 'Signer 'Critical a
wrongCaller = id
#endif
#ifdef BAD_SEVERITY
wrongSeverity :: Pending 'Customer 'Safe a -> Pending 'Customer 'Critical a
wrongSeverity = id
#endif
#ifdef BAD_RESULT
wrongResult :: Pending 'Signer 'Critical PreparedResult -> Pending 'Signer 'Critical ReplacementResult
wrongResult = id
#endif

#ifdef BAD_COERCE
coerceCaller :: Pending 'Customer 'Critical a -> Pending 'Signer 'Critical a
coerceCaller = coerce
#endif
