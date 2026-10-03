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

Saved-order reads now verify bearer capabilities using the exact baseline digest,
load historical terms without repricing, check request/quote/profile consistency,
hide unissued instructions and enforce configured backup coverage. Recovery
projections retain the original native/source/accounted-loss rules. The PostgreSQL
runner checks wrong/missing capabilities, hidden/uncovered instructions, saved
7% historical fees, corrupt/mismatched terms and explicit obligation review.
Native/source recovery overlays still need dedicated fixture coverage as their
write paths are ported; this is not live reorg acceptance.

For the saved-order read/visibility/recovery queries plus the orders table mapping,
the baseline has 101 lines across two files; the replacement has 83 across two
files (excluding imports, dispatcher branches and capability hashing in both).
The query now fetches the authorized order once; accounted-loss reads are restricted
to that order's affected receipts. The orders mapping alone is 38 to 17 lines with
all 14 columns preserved. Capability hashing is a separate 18-line pure module,
extracted from the prior scattered helpers; no new authentication scheme is used.
The earlier 367-line storage count describes the fee checkpoint, not the current
expanded storage total.

Atomic order creation is now implemented as a closed write operation returning
only an order ID. It checks capability/idempotency, request shape, amount/queue
limits, pause/scanner/custody readiness and available payout inventory. It saves
immutable 1% terms, inventory holds and both conversion/refund operating allowances
in one transaction. The existing monotonic operating clock, payment/order holds
and daily cost budgets are retained. Chain address preflight and instruction
provisioning must still run through their separate workflow before exposure.

The PostgreSQL contract now checks both directions and upward rounding, exact
inventory and operating holds, identical replay, changed-request rejection, stale
custody/scans, pause, queue/input limits, insufficient inventory/operating funds and
daily budgets. Rejected requests leave no added orders, holds or cost reservations.
Balance reads use Opaleye numeric aggregation in PostgreSQL and checked exact
Integer decoding; a contract verifies totals beyond Int64 without loading the
entire postings history into the process.

Order-admission/budget functions occupy 144 lines across two baseline files versus
125 across one replacement file, counting the named creation/readiness/inventory/
cost-budget functions and their balance/freshness helpers, excluding shared
transaction/authentication plumbing and schema declarations. The seven equivalent
full table mappings for reservations, checkpoints, scan health, operating clock,
operating costs, saved order costs and operating reservations are 116 to 18 lines
in one schema file each; the additional fee-reservation read projection is three
lines. These are piece-level comparisons, not whole-application totals.

Guarded instruction storage is implemented: one-time native allocation claims,
immutable native results, order-derived Solana Pay references, first exposure after
backup/readiness/reservation checks, and quote expiry. Native replies arriving after
expiry can be recorded without reopening the window. Previously issued instructions
remain historical data, while quote expiry releases only provisional holds.
`StorePolicy` binds immutable execution terms, admission limits, the native allocation
label namespace and backup requirement at writer construction.

The PostgreSQL runner checks allocation replay, wrong label/direction, immutable
instruction replay, backup pending/forward/regression/profile rejection, both
instruction types, late replies, historical exposure and preservation of obligation
holds on repeated expiry. A pure vector checks the exact existing Solana Pay
order-to-reference encoding. Native address strings in storage fixtures are not
node validation or network acceptance: the real adapter must validate ownership,
solvability and address type before recording an RPC result.

For claim/record/bind/issue/expiry/backup-acknowledgment storage functions, the
baseline is 146 lines across two files versus 127 across one replacement file,
including the new private authorization/allocation/save/audit helpers and excluding
shared transaction, identity and schema code. The native allocation mapping keeps
all three existing columns. Both chains share immutable instruction recording;
Solana binding no longer accepts a caller-chosen reference. This reduces duplicate
update paths without discarding the late-native-reply recovery rule.

The private chain component now contains the existing HTTP JSON-RPC transport,
native identity/wallet/address-allocation checks and Solana identity/token-account
checks, with chain-specific settings independent of the old application Config.
The retired Unix HTTP transport and application-wide PaymentTransport record are
not carried over. Native credentials are read with a 4,097-byte bound before the
4,096-byte limit check. Native amounts reject extreme exponent overflow; negative
Retry-After values fail closed. Mutation/unknown-method retries remain forbidden.
Solana public-key decoding has a length bound before Base58 work.

QuickCheck/protocol contracts cover exact native amounts, response bounds, bounded
read retries, mutation non-retry, native endpoint/wallet/checkpoint constraints,
L2L identity refusals, one-time allocation recovery, Solana endpoint independence
and token program/mint/owner/layout/delegate/close-authority rejection. The new
transport also returned the expected genesis from the real public Solana Devnet
endpoint. That is a live read-only transport check, not funded wallet or mint/custody
acceptance. The PostgreSQL contract passed after the shared error-type extraction.

Production counts: RPC 103 to 83 lines (one file each); native 128 to 151 (one file
each); Solana 82 to 108 (one file each). The chain files grow because settings and
validation move out of the old application-wide Config. An 11-line shared error
module replaces the replacement store's local exception definition and supports
both components. These are literal module counts, not a like-for-like total
reduction claim; the principal gain is clear dependencies and retained protocol
checks, with targeted input/retry hardening.

Native payment preparation/validation/signing is extracted into the private chain
component. It retains independently checked owned prevouts, exact recipient/change,
fee totals/ceiling, chain replay fields, saved-PSBT comparison, lock recovery and
post-signing/mempool checks. Preparation always requests no input locks; durable
workflow orchestration must save the draft before signing restores them. The shared
unchecked signing helper is private. Saved records now also reject malformed
transaction IDs/outpoints/scripts, zero outputs, excessive confirmation policy and
empty/oversized PSBTs before signing.

This piece is 257 production lines in one file versus 243 in one baseline file.
The increase includes explicit exports and validation; no size reduction is claimed.
Its 143-line QuickCheck/protocol module uses one unchanged captured public L2L
Signet fixture, distributed through Cabal. Tests cover successful offline
preparation/signing, refusal before signing when current input evidence changes,
post-signing template/fee rejection, corrupt saved drafts, output/fee mutations,
coinbase maturity, replay policy and idempotent lock recovery. The complete rebuild
pure/protocol suite passes. Offline fixture replay is not a new funded chain test.

Solana message validation, the bounded SDK FFI and payment preparation/outcome
verification are now extracted into the private chain component. A small public
payment policy replaces the old application-wide Config; SDK library and signer
key paths are explicit invocation inputs. Signed and unsigned SDK calls share
encoding/invocation/reply validation, while the unsigned entry point supplies no
key path. Bounded public-key parsing is shared with Identity. Transaction/message
base64 text is size-checked before decoding; the Haskell validator still checks the
exact instructions, account flags, message, mint, amount, memo and Ed25519 signature.

The three production files total 477 lines versus 465 previously: message
115→117, helper/FFI 149→154, payment 201→206. Added policy declarations, explicit
exports and bounds outweigh removed duplicate invocation/key parsing. This is a
boundary improvement, not a total size reduction. The 144-line QuickCheck/protocol
module reuses four unchanged fixtures. It checks signed/unsigned SDK vectors,
signature/amount mutation, unsigned simulation, rent top-ups, fee/rent/context/hash
limits and captured finalized Devnet outcomes for both new and existing ATAs.
The complete rebuild suite passes. A separate root-Cabal REPL smoke check invoked
the cached actual SDK dylib through the new FFI: preview message and deterministic
signature matched the exact public codec-key fixture. The temporary public test-key
file was removed and the REPL exited. This is offline SDK execution, not new funded
Devnet acceptance or a new clean-build SDK test.

Deposit proof validation is consolidated: one module supports historical memo
orders and connection-free Solana Pay, classifies token/SOL custody effects, and
checks historical owners and exact balance changes. Shared account parsing now
rejects duplicate/malformed keys for every proof path. Instruction count/account
lists and order-reference decoding are bounded. Unmatched receipts still expose
their custody effect without granting payout authority. Existing order-to-reference
encoding is unchanged. Anchored, bounded signature pagination is extracted into
the existing Solana adapter; provider gaps/repeated pages cannot advance a cursor.

The baseline deposit/Pay modules total 338 lines in two files versus 297 lines in
one replacement file, plus three added lines in the existing Identity module.
History definitions retain the original 32 lines, moved from Observer into Solana
with their imports/exports. QuickCheck covers the captured Devnet memo deposit,
Solana Pay and loaded-account JSON rewrites, historical ownership/amount/memo,
malformed instructions/accounts, exact URI amounts, bounded pagination and captured
SOL fee/rent effects. Pay/v0 rewrites are offline parser contracts, not captured
wallet flows. The complete rebuild suite passes; no funded transaction was sent.

Closed store operations now select promotion candidates and promote an observed
receipt into one conversion obligation. SQL orders/limits candidate selection
instead of loading/sorting the full history. Promotion checks saved deployment,
quote, amount/asset, native depth, timing and pending state; it verifies exact payout
inventory plus both saved operating allowances before atomically allocating the
receipt, transferring holds and recording the immutable net/recipient. It neither
moves money nor signs. Duplicate/late/partial receipts retain their liabilities;
replays, including restart, cannot produce another conversion. Reviewed/expired
orders cannot be reopened by this operation.

The disposable PostgreSQL contract passes both directions, duplicate receipts,
confirmation/timing refusals, unknown/unconfirmed receipts, missing-allowance
rollback, unchanged balances, historical 7% terms and restart replay. Row fixtures
use Opaleye; no live ledger was changed. Promotion/candidate functions are 52→83
lines; the corresponding full deposit/obligation definitions are 57→27, preserving
all 18 columns. Combined: 109→110 lines across two existing production files,
excluding shared dispatch/transaction code. Extra checks account for the larger
functions; compact named records remove generated schema repetition. Review
projections and test fixtures now reuse those mappings.

Source-check persistence is implemented behind a closed write operation. It
compares the complete saved receipt snapshot and, for conclusive checks, the current
unreviewed native observation hash. It records pending/missing/restored/unavailable
states without treating provider failure as proven loss. A proven deficit and its
reversal are balanced and replay-safe; restoration returns any still-active loss
cover's exact float/earned split once. Every changed recovery stays paused. The
latest recovery is selected with a SQL limit and cover returns use the existing
active-cover view instead of loading/filtering all cover history.

Source persistence/evidence/return functions total 100→82 lines across one file
each, including the new closed write branch and excluding shared helpers/schema.
The existing private schema and wire modules gain fixed projections and typed
receipt/check records; no new production file is added. PostgreSQL acceptance
covers ordinary pending, missing-value replay, unavailable evidence preserving a
known deficit, stale receipts/proof hashes, invalid evidence, restoration and exact
covered-capital return/replay. All row fixtures use Opaleye. The test cover is seeded;
operator cover authorization and actual native loss detection are not claimed done.

Connecting those adapters to the high-level safe/critical runtime, actual host fence,
dedicated signer and durable payment execution remains unfinished. Native observation,
atomic scan commits, suspended-work/approval binding, operator loss-cover authorization,
observer orchestration, broader recovery and SDK build integration also remain.
Passing these checks is not end-to-end payment, migration or real-chain acceptance.
