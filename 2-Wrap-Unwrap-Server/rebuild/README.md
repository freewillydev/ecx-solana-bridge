# Replacement bridge

Baseline: `ba31b28`. This package is a replacement under construction, not a
second deployed bridge. Root Cabal builds it alongside the baseline. It has no
custody credentials or running bridge process. Its storage contracts use a
disposable PostgreSQL database, never the existing custody database. Existing state
must remain untouched until migration and real-chain acceptance pass.

The required product remains connection-free native/wrapped conversion at 1% both
ways, refunds, earned-fee withdrawal, durable recovery, the four customer routes,
private operator control and dedicated authenticated signer. Development uses real
L2L Signet/Solana Devnet; existing ECX betanet support is retained during cutover.

## Ownership and dependency direction

| Part | Owns | May depend on |
| --- | --- | --- |
| Domain | Exact money, explicit funding, terms, states and accounting decisions | Pure libraries |
| Operations | Operation classes, existential Request, severity/caller DSL | Domain |
| Store | Opaleye schema and atomic implementations of closed operations | Domain |
| Native / Solana | Actual RPC, bounded codecs and effect validation | Domain |
| Workflow | Prepare, journal, sign, save bytes, authorize/send, observe, settle and recover | Domain, Store, adapters |
| Runtime | Safe/critical capabilities, authorization, one critical dispatch, scheduling | Operations, Workflow |
| Signer | Restricted Servant API and independent durable authorization | Operations, read-only Store, adapters |
| Interface | Four Servant handlers and Haskell/GHC-JavaScript browser | Restricted Operations and wire records |

The user's exact `../docs/reference/Main.hs` remains the typeclass/GADT reference.
Handlers return `Plan caller a` containing `Request caller severity a`; the operation dictionary
converts it to the DSL only at the interpreter boundary. Safe and critical
evaluators are separate. Critical signer ClientM access is private. Customers
cannot import the runtime or construct operator authority. The customer API already has a separate Cabal component that hides the internal
grammar and has no database, runtime or signer dependency. Operator, worker and
signer vocabularies will be added with their concrete workflows; the current
grammar implements the four customer operations only.

No generic SQL/IO operation, alternative database, synthetic receipt/order for
withdrawal, or chain stand-in is permitted. Row access is Opaleye inside specific
closed operation implementations. Driver transactions/migration DDL are explicit
infrastructure. Transactions never span RPC/signing/backup. There is one payment
engine; funding determines principal accounting, not a second send implementation.

## Construction and acceptance

1. Pure domain and property checks. Exact monetary parsing is extracted from the
   baseline; funding distinguishes conversion, refund and earned fees from day one.
2. Complete operation grammar and restricted customer handlers. Compile-failure
   checks prove customer code cannot reach critical operator/signer capabilities.
3. Store plus native/Solana adapters. Preserve unique sources, balanced journal,
   immutable quotes/signed bytes, sequence fencing and migration of existing state.
4. Shared payment and recovery workflow, including fee withdrawal. Reuse reviewed
   baseline validators; copy only code required by the actual flow.
5. Runtime, signer and browser; funded wrap/unwrap/refund/withdrawal, reload,
   interruptions and restart on real networks, then actual wallet acceptance.
6. One current operating/review guide and Cabal acceptance runner; coordinated
   replacement/deletion of superseded code after state and behavior equivalence.

Each piece gets focused checks before integration; file-local tests alone cannot
establish authorization, finality or crash safety. No module-count or line-count
quota substitutes for those requirements. Keep one build job and warm caches.
Old installer artifacts do not certify this package. Off-host restoration,
canonical activation and independent review remain explicit wider release gates.

## Current checkpoint

Implemented: checked monetary/funding types, balanced settlement calculations,
validated quote decoding, the existing customer wire format, existential requests
and the four pure Servant handlers. Funding has read-only patterns; money and
quotes have ordinary accessors so record updates cannot bypass validation.
QuickCheck covers money, fees, historical terms and funding accounting; handler
checks inspect actual requests and their DSL conversion. The private storage component now provides closed read operations and atomic
pause/earned-fee reservation/cancellation operations against the existing schema.
It exposes no connection/query callback. It checks read-role privileges and ledger
identity, shares the baseline writer lock, requires a durable checkpoint callback,
and fences unexpected transaction failures. Returned withdrawals include cancellation
state; replay cannot silently reactivate released money.

`rebuild-store-check` is the Cabal-built PostgreSQL contract runner. Supply a fresh
fully migrated `ECX_REBUILD_CONTRACT_DATABASE` with the `ecx_rebuild_contract_`
prefix, `ECX_REBUILD_CONTRACT_READER` with a SELECT-only role, and `USER` for fixture
setup on `/tmp/ecx-pg-seam:29436`. It refuses an unprefixed database. Fixtures and
assertions use Opaleye; schema/role provisioning is separate DDL. Checks cover role
and profile refusal, exclusive writer ownership, exact replay/conflicts, custody
freshness, insufficient earned revenue, cancellation and checkpoint rollback/fencing,
plus 25 randomized reserve/cancel cycles. The fixture checkpoint is deliberately
in-memory/no-op except during failure injection; this is not host-fence acceptance.

Size comparison (physical lines, including comments/blanks): the six equivalent
full table mappings for deployment, events, postings, audit, fee withdrawals and
cancellations occupy 89 declaration lines in the baseline schema versus 34 here,
in one schema file in each version. Repeated per-column type parameters and
read/write aliases are removed; mapped columns are retained. The current storage
slice is 367 production lines in three files plus a 105-line contract runner.
Other baseline storage behavior has not been ported, so those totals are not a
whole-storage reduction claim.

Customer order storage, the high-level safe/critical runtime, actual host fence,
chain adapters, signer and payment execution remain unfinished. Passing these
checks is not payment, migration or real-chain acceptance.
