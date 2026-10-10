{-# LANGUAGE CPP, OverloadedStrings, DataKinds, TypeApplications, FlexibleContexts #-}
-- Compile normally for the positive control; each BAD_* macro must fail.
module CapabilityCompile where
import Bridge.Operation.Internal
import Control.Operation
import Data.Coerce (coerce)
import Data.Proxy (Proxy(..))

valid :: Stage String '[CompileOperation 'Customer 'Safe ()]
valid = Stage (\value -> compileOperation value `seq` Right value)

workerStage :: Stage String '[WorkerOperations]
workerStage = Stage (\value -> queuePayment value "transaction" `seq` Right value)
operatorStage :: Stage String '[OperatorWrite]
operatorStage = Stage (\value -> pauseService value "review" `seq` Right value)

#ifdef BAD_DOMAIN
operatorFromWorker :: Stage String '[WorkerOperations]
operatorFromWorker = Stage (\value -> pauseService value "review" `seq` Right value)
#endif
#ifdef BAD_HIDDEN_WORKER
hiddenWorker :: Stage String '[]
hiddenWorker = Stage (\value -> queuePayment value "transaction" `seq` Right value)
#endif
#ifdef BAD_IO
injectIO :: (Execution 'Worker 'Critical WorkerCommand, WorkerOperations (WorkerCommand 'Critical ()))
         => IO () -> Pending 'Worker 'Critical ()
injectIO action = workerRequest (\_ -> action)
#endif

#ifdef BAD_COMPILE
hiddenCompile :: Stage String '[]
hiddenCompile = Stage (\value -> compileOperation value `seq` Right value)
#endif
#ifdef BAD_WIDEN
widen :: Pipeline String (SomeOperationWith (PreparationCaps 'Customer 'Safe ()) '[])
  (SomeOperationWith (PreparationCaps 'Customer 'Safe ()) (PreparationCaps 'Customer 'Safe ()))
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
