# Severity-indexed operations and evaluation boundaries

Accepted architecture change, 2026-10-01. This is the implementation contract for
refactoring the existing bridge, alongside PostgreSQL/Opaleye, connection-free
payments and 100 basis points in both directions. The PostgreSQL runtime now resolves actual Servant routes into this DSL. The
local paying deployment has completed its controlled PostgreSQL cutover. Safe
connections can use a separate SELECT-only role; full component isolation and
remaining operator/recovery workflows still require completion and audit.

## Source reviewed

“Add interactive environment prompts”, thread
`01a0f3e8-cade-75d3-aef2-58257f30cc21`, contains `/home/jack/haskell/secureServer/app/Main.hs`
on the other computer. Reviewed the complete file captured in the thread and the
subsequent successful build/edit output for its `DoThing`, `Input`, `Severity`,
`CriticalOperation`, `SafeOperation` and `DSL` definitions. There is no direct
remote filesystem tool in this session, so this is the recorded version, not a
claim to have fetched any newer unrecorded edits.

Retain the constrained existential/GADT idea and severity indexing. Replace the
identity update methods with operation-to-command elaboration. Remove the
`a -> b` functional dependency: a severity contains many operation types. Keep
`b -> a`, or equivalently use an associated severity family. Do not use an
incoherent instance, unconstrained severity casts, `undefined`, or a generic
`RequiredOperation :: DSL a` escape hatch. A command cannot supply its own IO
implementation or choose its severity at runtime.

## Small typed core

This standalone example specifies the shape, not replacement implementations of
chain adapters. The named request and response records in the bridge remain
concrete domain types; these examples use simple results only to illustrate the
type relationships.

```haskell
{-# LANGUAGE DataKinds, GADTs, KindSignatures, MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies, FlexibleInstances #-}
module OperationShape where

import Data.Kind (Type)

data Severity = Safe | Critical

-- The result type stays visible to Servant. Only the operation type is hidden.
class Operation (s :: Severity) (op :: Type -> Type) | op -> s where
  command :: op a -> DSL s a

data SafeOperation a where
  ReadStatus :: SafeOperation Bool

data CriticalOperation a where
  AdvancePayment :: CriticalOperation ()

data DSL (s :: Severity) a where
  Status :: DSL 'Safe Bool
  Payment :: DSL 'Critical ()

instance Operation 'Safe SafeOperation where
  command ReadStatus = Status

instance Operation 'Critical CriticalOperation where
  command AdvancePayment = Payment

data Request (s :: Severity) a where
  Request :: Operation s op => op a -> Request s a

resolve :: Request s a -> DSL s a
resolve (Request op) = command op

-- Each evaluator is exhaustive for its own severity. In production these
-- contexts are abstract capabilities, constructed only at application startup.
newtype SafeContext = SafeContext Bool
newtype CriticalContext = CriticalContext ()

evalSafe :: SafeContext -> DSL 'Safe a -> IO a
evalSafe (SafeContext status) Status = pure status

evalCritical :: CriticalContext -> DSL 'Critical a -> IO a
evalCritical (CriticalContext ()) Payment = pure ()

statusHandler :: DSL 'Safe Bool
statusHandler = resolve (Request ReadStatus)

paymentPlan :: DSL 'Critical ()
paymentPlan = resolve (Request AdvancePayment)
```

Use a single-step algebra initially. Do not introduce a free monad, generic
`LiftIO`, arbitrary SQL, callbacks containing IO, or an unrestricted MonadIO
instance. Existing domain workflows compose the audited primitive steps inside
the critical interpreter. If composition becomes necessary later, its severity
must be the maximum of every constituent operation; safe code cannot downgrade a
critical operation. Existentially hiding severity itself would lose the boundary.

## Classification and authority

Safe means unable to change economic authority, authorize a payment, sign,
broadcast, alter reserves, approve evidence, or weaken a safety gate. It does not
mean every ordinary write belongs in the safe interpreter.

| Operation | Severity and permitted caller |
| --- | --- |
| Public configuration, health, quote calculation | Safe; customer |
| Authorized order view and payment instructions | Safe; customer, ownership checked |
| Bounded deposit hint | Safe only through a narrow append-only inbox; a hint never becomes chain evidence |
| Create/bind an authoritative order or deposit reference | Critical; customer-origin request restricted to this command |
| Provision native deposit addresses / reserve identities | Critical; native wallet mutation, even without spending |
| Accept chain evidence, allocate funds, reserve fees, settle, compensate a reorg | Critical; worker |
| Construct/journal a payment, sign, persist signed bytes, broadcast/rebroadcast | Critical; worker |
| Cancel, retry, replace, cover loss, approve restored sources, change operating allocations | Critical; authenticated private operator |
| Pause/resume | Critical; changes a safety gate; operator or internal fail-closed path |
| Redacted audit and scanner diagnostics | Safe; private read authorization still required |
| Import, migrate, restore, mint administration | Separate maintenance authority; never a customer operation |

A unsigned customer payment request can be safe only if it reads an already
bound order and does not reserve, mutate a wallet or change the ledger. Classify
its actual implementation, not its name. Solana Pay recipient/reference/mint
binding is established critically once and then read safely.

Severity and caller authorization are independent. `Critical` is not permission
to spend. Use closed customer/operator/worker request constructors and checked
capabilities; never accept a serialized arbitrary DSL command from HTTP. Keep
customer authority, operator authority and validated chain evidence distinct.
Customer order creation must never provide a path to a worker-only payment
command. Constructors for verified evidence and signing authorization remain
private; they are created only after the existing checks.

## Servant boundary

Each Servant route resolves its operation to a **DSL value**, and only the
central interpreter evaluates that value. The existential `Request s a` carries
the typeclass dictionary during planning; `resolve` elaborates it into `DSL s a`
before evaluation. The endpoint response type `a` remains visible throughout.
The interpreter does not receive arbitrary operations or invoke handler IO.

Use `ServerT CustomerAPI CustomerDSL` as the unevaluated server and hoist once
into `Handler`. `CustomerDSL` is the closed, result-indexed customer language:
safe commands plus the explicitly permitted create-order command. It cannot
wrap an arbitrary critical command. Resolve typed operation packages to this
language in the route, then lower its commands to the severity-indexed safe or
critical DSL only at the interpreter boundary. The admin language is separate.

Servant's `ServerT` requires a type constructor of kind `Type -> Type`; hoisting
requires a natural transformation `forall a. CustomerDSL a -> Handler a`. Add
only the pure/applicative/monadic structure actually required by the installed
Servant API and handler composition. Do not gain convenience by implementing
`MonadIO`. Validation/authentication may be typed DSL steps; malformed inputs
may produce a typed rejection. Both are evaluated at the interpreter boundary.
Critical authorization must be rechecked when evaluated, rather than trusted
because a route constructed a command earlier.

Hoist this server once to `Handler`:

1. Safe requests go through the safe evaluator.
2. Critical customer requests go through the private worker dispatch boundary.
3. The worker checks caller authority, fresh readiness and saved terms, evaluates
   the allowed command and returns its typed result or structured error.

Preserve synchronous create-order responses; routing internally to the worker
must not silently change the public API into a new asynchronous order protocol.
Use the existing private process/socket boundary. Do not add a second public
service, message broker or general-purpose remotely executable command endpoint.
An in-process worker can use the same dispatcher without inventing another
network protocol.

The admin server follows the same pattern with a separate closed envelope.
Read authorization and HTTP error mapping happen centrally without adding a
catch-all exception handler that hides unknown financial outcomes.

## Separate interpreters and one critical evaluation site

The current implementation is in `Bridge.Postgres.Runtime`: safe evaluation uses
its own read-only connection, while customer, operator and worker plans pass
through one critical evaluator call under a single workflow gate. The gate covers
RPC calls as well as individual ledger transactions, preventing scanner updates
from interleaving with admission or settlement. Safe reads remain concurrent.
The module names below describe the intended capability separation; splitting
the existing runtime into more modules is not required to deliver the product.

`Bridge.Operation` defines the closed grammar, dictionaries and existential
packages. It has no imports of ledger IO, signer modules, chain transports or
Opaleye execution functions.

`Bridge.Evaluate.Safe` owns read-only query execution and the tightly restricted
hint inbox. Its context contains no private keys, writable ledger connection,
wallet-mutation RPC, critical dispatcher or signing capability. Use a PostgreSQL
read-only role/transaction for views, with a separately restricted hint-inbox
writer if hints are retained. Safe evaluation cannot receive the worker's broad
`Config`, `Ledger`, `Manager` or an arbitrary RPC callback.

`Bridge.Evaluate.Critical` owns the write transaction and delegates to the
existing checked order, observation, settlement and recovery workflows. It alone
obtains ledger write and signer capabilities. Its context constructor and raw
interpreter stay internal to the worker component.

`Bridge.Dispatch` contains **one production call site** of `evalCritical`.
Customer dispatch, operator dispatch and worker scheduling all submit to it with
their distinct checked authority. The source scan must count both ordinary and
point-free uses, aliases and re-exports; merely renaming other direct financial
IO calls is not consolidation. Tests may evaluate dedicated test contexts.

A typeclass alone is not an access-control system: exposed constructors,
arbitrary instances, broad IO capabilities or public underlying financial
functions would bypass it. Keep grammar and instances closed inside an internal
component; expose only safe planners to the HTTP component. Move low-level
financial functions out of the public library API. Use Cabal internal libraries
or equivalent enforced module boundaries, plus negative compilation checks and
an import-boundary check. No `unsafeCoerce`, overlapping authorization instances
or broad capability fields.

Do not hold an SQL transaction open across chain RPC, signing or a backup.
Preserve the existing journal protocol: commit preparation/intent, prove required
backup, sign within saved bounds, persist exact bytes, prove backup before send,
then observe and settle independently. Recheck revision/source/readiness at each
relevant transaction. A failed commit or uncertain send remains fenced and
reconciled; the DSL must not automatically retry a financial operation.

## Integration order and completion checks

1. Inventory every financial IO entry point in Worker, Order, Observer,
   Settlement, Recovery, Payment and both adapters. Classify its effects and
   required caller capability before wrapping it.
2. Introduce the small closed grammar and typeclasses. Compile valid safe and
   critical requests; require compilation failure for critical-to-safe evaluation,
   hidden authority construction and a customer payout request.
3. Establish Opaleye read/write capabilities and transaction boundaries alongside
   the PostgreSQL migration. Keep old funded SQLite state untouched until the
   verified import/cutover is ready.
4. Convert safe HTTP views first, then authoritative order creation through the
   restricted dispatcher. Keep response shapes and ownership checks intact.
5. Route observation, settlement, recovery and private CLI mutations through the
   one critical evaluator. Remove exposed bypasses; verify the component import
   graph and call-site count.
6. Apply 1% to new orders in both directions, retaining saved terms for existing
   orders. Establish connection-free payment bindings critically; expose their
   QR/URI instructions through safe reads.
7. Run existing financial contracts plus meaningful boundary tests: unauthorized
   operations, repeated requests, concurrency, failed commits, unknown send
   outcomes, replay and preserved backup gates. Then run the approved real
   Signet/Devnet integration and installer checks.

Completion requires real handlers/workflows using these boundaries, not merely
compiling this example. The types constrain what application code can express;
they do not prove chain finality, correct accounting, wallet security or perfect
security of the server.
