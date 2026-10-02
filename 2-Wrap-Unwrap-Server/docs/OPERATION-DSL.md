# Severity-indexed operations and evaluation boundaries

Accepted architecture change, 2026-10-01. This is the implementation contract for
refactoring the existing bridge, alongside PostgreSQL/Opaleye, connection-free
payments and 100 basis points in both directions. The PostgreSQL runtime now resolves actual Servant routes into this DSL. The
local paying deployment has completed its controlled PostgreSQL cutover. Safe
connections can use a separate SELECT-only role; full component isolation and
remaining operator/recovery workflows still require completion and audit.

## Source reviewed

The user supplied the complete 118-line Main.hs on 2026-10-02 from
`/Users/lukekensik/Downloads/Main.hs`. Its exact, unmodified reference copy is
[`reference/Main.hs`](reference/Main.hs), SHA-256 `f1d0777a8d2fddd62881aa5d85f518884c9d4efb451480f1520a677ab2319ea2`.
It comes from “Add interactive environment prompts”, thread
`01a0f3e8-cade-75d3-aef2-58257f30cc21`; the previously recorded remote path was
`/home/jack/haskell/secureServer/scripts/server.hs`. The supplied file is now the
architectural reference. It is not a production module or a claim of compilation.

Preserve its intent: severity-indexed operations, typeclass-constrained GADT input,
explicit command construction, separate interpreters and small visible operation
vocabularies. Review its exact definitions when changing the bridge DSL. Adapt the
sketch rather than copying its unfinished signatures: the safe evaluator currently
accepts critical input and maps WrapEcx to SafeWrap; RequiredOperation is polymorphic
in severity; runSafe has no instance implementation. Those shapes must not become
a production route around the authority boundary.

Comments about a weekly 10% supply limit and multisig coordination are design notes
to reconcile with agreed scope, not implemented guarantees or automatic authority
to expand the project. Its restore goal requires the durable ledger and signed
attempt journal as well as the original key/configuration material.

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

statusHandler :: Request 'Safe Bool
statusHandler = Request ReadStatus

paymentPlan :: Request 'Critical ()
paymentPlan = Request AdvancePayment
```

Use a single-step algebra initially. Do not introduce a free monad, generic
`LiftIO`, arbitrary SQL, callbacks containing IO, or an unrestricted MonadIO
instance. Existing domain workflows compose the audited primitive steps inside
the critical interpreter. If composition becomes necessary later, its severity
must be the maximum of every constituent operation; safe code cannot downgrade a
critical operation. Existentially hiding severity itself would lose the boundary.

Database access belongs to the implementations of specific closed DSL operations.
The safe evaluator opens its read-only transaction internally and interprets only
SafeOperation constructors; it accepts no query or connection callback. Handlers
receive neither the connection nor an Opaleye Select/Insert/Update capability.
The obsolete prototype status-server DSL has been removed; Runtime implements
the operational interpreter. Startup reader validation is the private safe operation
VerifyReadRole. Its Opaleye catalog implementation rejects elevated roles, schema
creation, table/column writes and sequence use, including inherited grants. Fixed
PostgreSQL privilege bindings use the pinned Opaleye expression AST because the
public API lacks these built-ins; no function name or SQL expression is accepted
from callers. The check covers public-schema relations; read-only transactions
remain an independent enforcement layer. PostgreSQL documents the current-user and
inherited-privilege semantics in its [system information functions](https://www.postgresql.org/docs/16/functions-info.html).
Database diagnostics now enter through the private DatabaseIdentity safe operation;
its fixed Opaleye catalog queries run in the same read-only interpreter. Worker and
installation ownership use fixed Opaleye advisory-lock expressions. Production
Haskell no longer uses handwritten query/execute calls. Remaining writable-store
exports and maintenance paths still need consolidation under this boundary;
legacy tests and external maintenance scripts remain separate refactoring work.

## Classification and authority

Safe means unable to change economic authority, authorize a payment, sign,
broadcast, alter reserves, approve evidence, or weaken a safety gate. It does not
mean every ordinary write belongs in the safe interpreter.

| Operation | Severity and permitted caller |
| --- | --- |
| Public configuration, health, quote calculation | Safe; customer |
| Authorized order view and payment instructions | Safe; customer, ownership checked |
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

Each Servant route returns a **packaged existential operation**, not an evaluated
result or an already elaborated DSL. `Request s a` hides the operation type and
retains its `Operation s op` dictionary. The endpoint response type `a` and request
severity `s` remain visible. At the runtime boundary, `resolve (Request op)` calls
the class method `command op` to produce `DSL s a`; the matching evaluator then
executes it. This is the production counterpart of Main.hs's DoThing class.

The customer server uses `ServerT CustomerAPI Plan`, hoisted into `Handler`.
Local operator commands package the same existential plans without an HTTP server. The abstract `Plan a` contains a severity-indexed Request
inside a safe/customer/operator/worker envelope. Public smart constructors accept
only their concrete operation vocabulary; they package the operation without
calling `resolve`. The `bridge-types` private Cabal library owns the grammar,
instances and existential constructors. The `customer-api` private library compiles
only `api/Bridge/API.hs`, depends on the customer planning interface, and hides
`Bridge.Operation.Internal` through Cabal's module mixin. `Bridge.Operation`
exports only customer-safe reads and order creation, not operator/worker commands.
The API component has no dependency on the runtime, Opaleye, a PostgreSQL driver,
RPC adapters, a signing implementation or Servant ClientM. Thus importing those
implementations or constructing an internal DSL directly fails at compilation.

The private `bridge-runtime` library depends on the types and customer API and
owns evaluation and transports. Executables and financial tests explicitly depend
on this internal library; downstream packages cannot import it. The small
`ecx-build-assets` support package retains the SDK/browser Cabal hooks, because
Cabal 3.16 does not support Hooks together with internal libraries. Root Cabal
commands build the whole graph; this adds no running service or manual build step.

The HTTP/API process serves the DSL-backed CustomerAPI directly, alongside
HTML/CSS and the Haskell interface compiled with GHC’s JavaScript backend. `Web.runPublic` receives that WAI
application; it no longer generates a Servant client or forwards HTTP requests.
Operator HTTP routes are removed. A local CLI sends a bounded named command over
a mode-0600 Unix socket; it packages the same existential Plan and uses Runtime’s
single critical dispatcher. It cannot serialize arbitrary DSL or SQL.

The revised custody boundary is a dedicated Haskell signer process. All signer
communication must originate inside the critical evaluator's closed workflows;
the generated Servant ClientM implementation and connection capability must be private to that evaluator.
Safe operations and HTTP handlers cannot obtain or call them. The signer accepts
only named, durable signing decisions, checks them independently, and never sends
transactions. Native RPC credentials must also be split so the HTTP process cannot
bypass this service using walletprocesspsbt or another signing/key-export method.
Solana SDK Rust remains only through Haskell FFI inside the signer. `Bridge.Operator` now defines only the three private signing Servant routes.
Its handlers return `Request 'Critical a`, the constrained existential dictionary,
and the hoist resolves each request into `SigningDSL` before calling the dedicated
signer evaluator under one serialization gate. It binds HTTPS only on
127.0.0.1 at signerPort. A 256-bit shared token authenticates the worker using
Servant BasicAuth; signerAuthFile is a root/service-owned regular file, mode 0600
or 0640 for a dedicated worker/signer group. Its directory rejects group/world
writes. The worker trusts only signerAuthFile.pem, with normal certificate and
hostname validation; signerAuthFile.key is signer-only, mode 0600. TLS prevents a
fake local listener from collecting the authentication token. No proxy, redirect,
automatic retry or unbounded response is permitted. All three generated ClientM
calls are private to Runtime's critical evaluator, sharing the exact server API. `Bridge.Signer` owns keys and independent
saved-decision checks. Existing pause/refund/recovery commands remain in
`Bridge.Control` with their unchanged private CLI protocol and main critical dispatcher.
The closed critical-only client and signer decision checks are implemented;
deployment isolation and end-to-end acceptance remain current work.

Unsigned Solana construction now calls the pinned SDK shared library through
Haskell FFI. Its private, versioned `ecx_solana_prepare_v1` C ABI accepts at most
4096 configuration bytes and 8192 request bytes and writes at most 8192 reply
bytes into caller-owned buffers. No pointer or allocator crosses ownership
boundaries; ordinary failures return fixed codes, and Rust panics are caught
before returning across the ABI. Haskell independently validates the resulting
transaction. The unsigned adapter supplies only public identity fields and a
null signing path, never the private helper configuration. Signed payouts now use the SDK FFI inside the dedicated Haskell signer. The
standalone Rust signing binary is retired. Native RPC credential restrictions,
OS separation and real-chain acceptance of both processes remain pending.
See the [Rust FFI contract](https://doc.rust-lang.org/nomicon/ffi.html) and
[GHC FFI documentation](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/ffi.html).

Servant's `ServerT` requires a type constructor of kind `Type -> Type`; hoisting
requires a natural transformation `forall a. Plan a -> Handler a`. Add
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
Use the dedicated signer process and authenticated loopback boundary. Do not add a second public
service, message broker or general-purpose remotely executable command endpoint.
An in-process worker can use the same dispatcher without inventing another
network protocol.

Private operator control follows the same pattern with a separate closed envelope.
Read authorization and HTTP error mapping happen centrally without adding a
catch-all exception handler that hides unknown financial outcomes.

## Separate interpreters and one critical evaluation site

The current implementation is in `Bridge.Postgres.Runtime`: safe evaluation uses
its own read-only connection, while customer, operator and worker plans pass
through one critical evaluator call under a single workflow gate. The gate covers
RPC calls as well as individual ledger transactions, preventing scanner updates
from interleaving with admission or settlement. Safe reads remain concurrent.
Covered-source approval and native rebroadcast are private local workflows inside
evalCritical, reached by their named operator DSL commands. They use its captured
ledger/transport; callers cannot import these workflows or inject another transport.
The module names below describe the intended capability separation; splitting
the existing runtime into more modules is not required to deliver the product.

`Bridge.Operation` defines the closed grammar, dictionaries and existential
packages. It has no imports of ledger IO, signer modules, chain transports or
Opaleye execution functions.

`Bridge.Evaluate.Safe` owns read-only query execution ; the optional hint inbox has been retired. Its context contains no private keys, writable ledger connection,
wallet-mutation RPC, critical dispatcher or signing capability. Use a PostgreSQL
read-only role/transaction for views. Safe evaluation cannot receive the worker's broad
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
