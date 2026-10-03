# Replacement bridge

Baseline: `ba31b28`. This package is a replacement under construction, not a
second deployed bridge. Root Cabal builds it alongside the baseline. Its executable has been tested against disposable state; it has not been
activated against existing custody. Its storage contracts use a
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
grammar and has no database, runtime or signer dependency. The grammar also contains signer, worker and operator status/pause/resume operations;
remaining recovery operations must be added with their concrete workflows.

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

## Running the development executable

From the repository root, Cabal builds the native application plus the existing
SDK FFI and GHC JavaScript assets through `ecx-build-assets`:

```sh
cabal build ecx-bridge-rebuild:exe:ecx-bridge-rebuild -j1
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- check-config CONFIG
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- observe CONFIG
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- serve CONFIG
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- signer CONFIG KEYFILE
```

`CONFIG` is a reviewed deployment configuration, not the test fixture. Supply
local `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and optional `PGPASSWORD` through
the service environment; public modes also require a distinct SELECT-only
`PGREADUSER` and optional `PGREADPASSWORD`. Signer mode uses its own SELECT-only
`PGUSER`, native signing credential and private custody key. `ECX_INTERFACE_CONFIG`
and `ECX_ASSETS` are optional overrides; assets default to Cabal-generated output.
The existing schema-19 ledger and matching initialized host fence are prerequisites.
`serve` enables the customer/payment mode but still starts paused and currently has
no rebuilt resume command. `observe` refuses customer creation and outgoing sends.
Neither command is public-release or canonical-custody approval.

The process contract uses the existing disposable-database runner with
`ECX_REBUILD_SERVER_ONLY=1` and `ECX_REBUILD_EXECUTABLE` set to the freshly built
application. Invoke the runner through `cabal run` so Cabal supplies its fixture
data directory (direct binary invocation requires `ecx_bridge_rebuild_datadir`).
It creates and removes its own configuration, child process and host fence; it
must never target the custody ledger. The shared PG server remains running.

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
setup on `/tmp/ecx-pg-seam:29436`. Apply baseline PostgreSQL migrations 001–005,
then the Cabal-packaged `rebuild/migrations/001.sql` through `003.sql` (schema 21). It refuses an unprefixed database. Fixtures and
assertions use Opaleye; schema/role provisioning is separate DDL. Checks cover role
and profile refusal, exclusive writer ownership, exact replay/conflicts, custody
freshness, insufficient earned revenue, cancellation and checkpoint rollback/fencing,
plus 25 randomized reserve/cancel cycles. The fixture checkpoint is deliberately
in-memory/no-op except during failure injection; this is not host-fence acceptance.

Size comparison (physical lines, including comments/blanks): the six equivalent
full table mappings for deployment, events, postings, audit, fee withdrawals and
cancellations occupy 89 declaration lines in the baseline schema versus 34 here,
in one schema file in each version. Repeated per-column type parameters and
read/write aliases are removed; mapped columns are retained. This is a table-mapping comparison, not a whole-storage reduction claim.

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
native loss detection is now wired through the closed worker operation (see below);
covered-payment approval and funded loss acceptance remain unfinished.

Atomic scan commits now preserve receipts, immutable origins/evidence, cursors and
health in one transaction. Cursor comparison refuses stale batches; duplicate
receipts cannot credit twice. Eligibility loss captures the suspended work hash
before review. Outgoing classification distinguishes a signed attempt from a
persisted broadcast intent; treasury approval must match both anchor and economic
effect. Changed evidence reopens sticky review. Failed scans preserve their cursor
and last successful scan time.

Scan functions are 213→187 lines; suspended-work hashing is 36→48 lines. Combined:
249→235 lines across two baseline files versus one existing Store file, excluding
shared helpers, schema and dispatcher. Explicit projected/ordered Opaleye queries
replace broad row reads in the hash calculation while preserving its saved preimage.
Schema and wire definitions add 42 lines each; no production file is added. These
scoped counts are not a whole-repository reduction while the baseline is retained.

The PostgreSQL contract passes receipt/cursor rollback, replay, immutable binding,
source suspension/restoration, hash goldens, signed/broadcast classification and
changed treasury evidence across all three streams. The full QuickCheck/protocol
suite passes, including bounded canonical economic parsing. Treasury authorization
is fixture-seeded; populated replacement/cancellation hash and former-winner cases
still need workflow acceptance. These are storage/protocol checks, not funded scans.

Native wallet observation is now a read-only adapter returning a complete scan
batch. It validates actual chain/wallet identity, wallet tip and scan origin,
re-reads canonical gettransaction evidence across removed/re-added history, checks
owned output scripts and exact amounts, and binds receipts to saved order depth.
Duplicate receipt identities and insufficient historical scan depth are refused.
Its clock/cursor and instruction lookup are explicit inputs; it cannot commit rows.
Two closed store reads supply instruction binding and maximum historical depth;
the latter selects distinct policies rather than every duplicate policy row.

Observer functions are 94→98 lines, plus 17→17 for the two store reads: 111→115
across two production files in each version. The new dedicated native-observation
module is 114 lines including imports/comments; the old functions shared the mixed
chain Observer module. This is separation of evidence gathering from persistence,
not a size reduction. Existing tests gain captured-output RPC contracts for reorg
overlap, historical depth, unbound receipts, negative confirmations, identity,
origin, script/amount and duplicate-output refusals. Full QuickCheck/protocol and
disposable PostgreSQL suites pass; closed lookup reads are verified in PostgreSQL.
No live wallet was scanned, and no funds were sent.

Solana token and fee-payer observation now return the same atomic scan batch.
They retain anchored history, pending verifier rechecks, legacy memo/Pay binding,
historical refund owner, independent proof comparison and actual token/SOL effects.
Unsupported/disputed evidence is quarantined; missing evidence cannot become an
eligible bound receipt. Operating history must include the zero opening balance.
Shared RPC encoders stay in Solana; identity checks use explicit primary/verifier
read capabilities and refuse a missing configured verifier. Closed Opaleye reads
select pending verification with SQL ordering/limit and match at most two reference
orders, rejecting ambiguity without loading all matching records.

The two Solana scan functions and cursor guard total 116→119 lines; their two store
lookup functions are 22→18. Combined: 138→137 across two production files in each
version, excluding imports and dispatch. The dedicated SolanaObservation module is
138 lines. Shared adapter extraction adds 11 lines in Solana. A 50-line Observer
workflow now constructs the real adapters, gathers/commits each stream, records
failures and promotes candidates through closed store operations. It replaces the
previous observer's intertwined adapter/store setup, but is not a total-module
reduction claim while construction retains the baseline.

Full QuickCheck/protocol checks pass captured memo effects, offline Pay rewrites,
independent verification agreement/unavailability/dispute, pending work outside the
current history window, missing/unsupported transactions and captured SOL costs.
PostgreSQL contracts pass reference matching/bounds and pending-proof clearing.
The workflow builds through root Cabal; it has not yet run against live nodes or
been connected to the final critical runtime. No live custody state was changed.

## Payment and signer checkpoint

One checked PaymentView represents conversion, refund or earned-fee funding with
immutable saved terms. Initial preparation shares order operating-budget rules,
persists a generation-bound plan/draft and excludes concurrent work per chain.
The 36-line schema-19 migration binds intents to exactly one obligation or earned
withdrawal, preserves existing attempt bytes, excludes the baseline worker and
pauses the deployment. It has only been applied to disposable databases.

The common payment workflow prepares unsigned work and validates signer replies.
Native returned bytes are independently decoded against the saved draft; Solana
messages, signatures and derived payment references are checked locally. The signer
accepts only deployment/payment/generation identifiers through its critical-only
existential DSL operation, uses read-only Opaleye authorization, serializes signing
and rereads the exact decision before releasing a typed SignedAttempt. The worker
independently validates every returned field before immutable, replay-safe storage.

SigningTransport provides loopback HTTPS, protected auth/certificate/key files,
Servant BasicAuth, 16-request concurrency and 4096-byte input bounds. Critical owns
the private ClientM with pinned trust, no proxy/redirect/retry, a 60-second timeout
and a 512-KiB response bound. Uncertain signing outcomes retain the preparation and
pause. Existing recorded attempts are verified without another signer request.
The executable wires signer and public-worker modes separately; successful
offline worker-to-signer TLS/SDK integration now passes (see below); funded and
separate-OS-user signing acceptance remains pending.

Closed MarkBroadcast and AuthorizeSend operations require current intake/custody,
saved paying work, source eligibility and the current native replacement member.
Pending replacement drafts block sending. Broadcast intent saves a critical
sequence; identical replay preserves it. Send authorization requires applicable
backup coverage, including recorded source-restoration approvals. Covered-source
spending remains unported and refuses; it is not silently treated as eligible.

SettlePayment binds the exact saved attempt, actual costs and proof, allows only a
recorded broadcast intent, checks the live fee hold and excludes another winner.
It uses the Domain funding accounting for customer and earned funds alike, then
atomically resolves the intent and releases appropriate holds. FailSolana books
only the proven network fee and retains principal/inventory for recovery. Identical
outcomes are idempotent; changed evidence/costs/bytes refuse. Paused operation may
record proven effects. These store operations do not verify chain finality or send
transactions themselves. ReconcilePayment now obtains evidence through the real
adapters under the critical gate: native bytes/fee/wallet conflict checks followed
by canonical block/depth checks, or finalized Solana message/balance-effect checks.
It verifies deployment identity and the saved attempt before applying a result.
Unseen/waiting effects leave accounting unchanged; unavailable or conflicting
proofs pause processing. Terminal paid/failed records return without RPC. This is
pending-attempt reconciliation, not post-settlement reorg/winner recovery.

PaymentSource now binds a focused chain read to the immutable customer request,
policy, instruction and saved receipt. Native checks cover exact outpoint/value,
owned script, wallet conflicts and canonical confirmation depth; Solana checks
legacy memo or Pay reference, exact value/slot and any configured independent
provider. A closed snapshot-checked refresh preserves receipt identity, first-seen
time, balances and scanner cursors. Unchanged snapshots avoid unnecessary writes;
changed eligibility uses the same suspension logic as scanning. Earned funding has
no synthetic source receipt. Signing, queueing and submission use this common check.

QueuePayment records broadcast intent and returns its sequence for backup.
BroadcastPayment independently revalidates the saved attempt, checks for already
observed effects, refreshes its source, checks native mempool acceptance or the
Solana validity window, and authorizes the exact saved record after backup coverage.
Only then does it call the real chain's send method, once, and check the returned
identifier. Submission does not settle. An exception retains durable work and
pauses; there is no automatic send retry or transaction spanning backup/RPC.
These branches compile but still need positive integrated submission acceptance.
Source changes that invalidate custody require recertification before sending;
full runtime scheduling and that recertification remain to be connected.


Current evidence:

- Cabal QuickCheck passes protocol vectors, independent native decoding, Solana
  signature/reference and typed reply mutations, and existential handler checks.
  The SDK workflow vector uses a public test seed, never funded or broadcast.
  Focused source checks cover native ownership/depth/canonicality and both Solana
  deposit forms, including independent-provider disagreement and changed amounts.
  Captured Signet/Devnet outcomes exercise the actual observer functions, including
  missing versus unavailable, insufficient depth, conflicting/noncanonical native
  effects, finalized commitment, missing finalized evidence and fee-only failed
  Solana effects (the latter are labelled offline mutations of captured proofs).
- Actual WAI/Servant checks cover auth, typed replies, refusals, malformed/oversized
  bodies, cross-site requests, absent broadcast route and evaluator call counts.
  Credential tests cover modes, parent permissions, symlinks, token format and port.
  Signer startup now requires a protected standard Solana keypair whose seed,
  public half and configured custody owner agree. Key and transport credentials
  share the permission validator. Offline checks use a public all-zero seed vector
  and reject changed seeds/owners/public halves, invalid bytes, oversized files,
  symlinks and group-readable private keys. PostgreSQL signer-refusal contracts
  still pass after startup validation; no custody key or funds are used.
- Disposable PostgreSQL contracts pass signing/broadcast gates, exact saved bytes,
  restart reads, replay and source refusal. Settlement checks verify a 7% historical
  conversion, earned withdrawal without customer debit, finalized-failure fee-only
  accounting, changed-evidence/cost refusal and no duplicate postings. Proofs/bytes
  in database fixtures are labelled offline data, not real-chain acceptance. Source
  refresh tests verify snapshot/immutable-binding refusal and unchanged money/cursor;
  earned withdrawals return no customer source.
- Only operation-origin policy refusals permit connection reuse after rollback.
  IO and typed checkpoint failures fence the writer. `withFencedWriter` now holds
  the host lock for the complete writer lifetime and fsyncs its monotonic sequence
  before commit. The real filesystem/PostgreSQL contract preserves an advanced
  watermark across an injected rollback and refuses the stale ledger on restart;
  balances remain unchanged. Filesystem contracts cover competing processes,
  same-process ownership, permissions, symlinks, identity, reinitialization and
  retirement. This does not revoke copied keys on another host.

Custody storage now has closed revision/snapshot/evidence reads and a revision-bound
report write. It reuses the aggregated balance read and scanner freshness check,
checks source/native recovery and terminal-payment evidence, and includes bounded
pending attempts. PostgreSQL acceptance covers origins, scan freshness, review
refusal, report validation, revision mismatch, failure pause, no implicit resume,
and unchanged balances/revision. The critical worker now evaluates `ReconcileCustody` with configured origins and
actual chain transports. Inspection checks native balance/history/canonical-block
consistency, finalized Solana accounts/history, optional independent-provider
agreement, a 60-second deadline and the unchanged ledger revision. Pending effects
must match verified saved bytes and both scanner evidence and actual transaction
effects. Offline RPC contracts over PostgreSQL cover matching/mismatched balances,
history advancement, changed native views, provider disagreement, timeout and a
revision changed during inspection. This is not live-chain acceptance.

Native replacement families explicitly refuse custody certification until the
winner-proof recovery port is complete; they must never be summed as independent
payments. Positive pending-transfer custody and funded Signet/Devnet acceptance,
source-loss diagnostic dispatch, and integration with the complete scheduler are
still required.

Worker `ObserveChains` and `PrepareOutgoing` now share the existing critical gate
with custody/sign/queue/send/reconciliation. Preparation checks read-only intake
before any RPC and refreshes its customer source before saving a plan. A paused
preparation is verified to refuse without reaching the network. `withRuntime` now
resolves both customer writes and worker requests through one critical dispatch
under that gate. The separate safe evaluator receives only the SELECT-only reader
and public configuration. Observation-only mode refuses customer creation and
worker preparation/signing/queue/send before taking the gate.

`RunWorkerCycle` now composes observation, quote expiry, pending-attempt recovery,
custody certification and payment progression under that same gate. Scan and
individual attempt policy errors are retained while the remaining attempts are
checked. A failed cycle stays paused; successful custody certification never
resumes a deployment. Paying cycles refresh invalidated custody checks and require
recorded backup coverage before signing/sending. Existing unsigned preparations
and exact signed bytes are reused. New work is limited to one candidate per chain,
prioritizing unfinished intents and excluding cancelled/settled withdrawals in
PostgreSQL; earned-fee payments use the same progression as customer obligations.

The 15-second worker loop dispatches only that closed operation. Policy failures
back off; asynchronous shutdown and database failures escape to the future server
lifetime owner. Tests verify queue selection across reservation, cancellation,
preparation, signing, settlement and failure, plus a real PostgreSQL runtime cycle
with unavailable RPC retaining balances/pending work and recording all three scan
failures. QuickCheck verifies loop backoff and cancellation. Positive funded cycles,
replacement-family lock recovery, recovery-family parity and explicit resume remain
unfinished. The executable now owns HTTP and the worker together through
structured concurrency; either terminating cancels its sibling.

Native lock reconstruction now runs before chain scanning, independently of Solana
availability, through `RecoverNativeLocks`. The closed store read binds the native
intent, active generation, pending cancellation and at most eight saved attempts.
Recovery shares native plan/PSBT validation with signing. It restores only still-owned
saved inputs; undrafted/cancelling work and already-confirmed/mempool spends only
verify existing locks. Unknown locks are never cleared. Changed inputs, unrecorded
broadcasts and unsupported replacement families refuse recovery and retain pause.
A snapshot-bound closed audit write records restorations without changing balances
or financial sequence. Captured Signet protocol checks cover idempotency, earned
funding, cancellation, confirmed/mempool/unseen outcomes and changed PSBT/prevouts;
PostgreSQL checks cover native work selection, audit binding and unchanged money.
These do not replace actual daemon-restart or replacement-family acceptance.
The implementation stays in Payment: 135 → 199 lines in that existing file, plus
41 Store lines, 8 runtime lines, 6 adapter lines and one grammar constructor; no new
production file. Baseline lock recovery occupied 71 lines plus shared helpers and
included family handling still pending here, so this is not an equivalent reduction.

Customer admission now has the baseline native dust/fee funding preview and Solana
account/fee/rent/unsigned-simulation preflight. Its adapter, fingerprint, depth and
fee settings must agree with the saved ledger policy. Captured native vectors and
offline unsigned Solana message contracts verify preview behavior, no signing or
sending, absent native funding, signed-preview refusal and simulation failure.
The customer order workflow now invokes admission for new orders only, commits
provisioning claims/instructions, requests backup and verifies recorded coverage
before exposure. Closed `FindOrder` and `ReadProvisioning` reads preserve the
capability/request binding and hide unissued instructions from ordinary reads.
PostgreSQL workflow tests cover backup callbacks without acknowledgment, replay
while paused without repeat admission/identity calls, changed-request refusal,
capability isolation and recovery after a lost native allocation reply with only
one address allocation. These are offline RPC contracts, not funded acceptance.
`customerApplication` hoists the four pure Servant handlers into this runtime.
Safe Solana Pay instructions check the order, backup visibility, deadline and
intake in one database snapshot. WAI tests verify all four endpoint results,
missing authorization, malformed/oversized bodies, cross-site rejection and removed
routes. An actual PostgreSQL-backed HTTP order read and runtime replay pass without
network access; observation-only restrictions and configuration mismatch also pass.
Signer and customer HTTP share one bounded-body/concurrency/no-cache middleware.
Deployment configuration now derives adapter, observer, ledger, signer-policy and
public settings from one validated record. The financial fingerprint matches the
baseline executable and captured Devnet identity exactly; obsolete socket fields,
missing history anchors, incompatible limits and unsafe public URLs are rejected.
These are offline configuration checks, not live history-completeness proof.
The root-Cabal executable now wires this runtime to HTTP, the worker loop and the
existing GHC-JavaScript browser build. `serve` and `observe` bind loopback, require
separate database reader credentials and hold the durable host fence. Startup
remains paused; there is no automatic resume or ledger/fence initialization.
The separate `signer` mode checks its SELECT-only role and custody key before
serving the authenticated HTTPS API. Public startup currently refuses canonical
profiles and backup-required deployments until recovery integration is complete.

Actual child-process acceptance on disposable PostgreSQL verifies browser HTML,
CSS and generated JavaScript delivery, observation-only configuration, removed
operator HTTP routes, unchanged balances, paused unavailable-RPC startup and host
lock release after process termination. WAI tests cover fixed asset paths,
missing-asset refusal, traversal/hidden-file rejection and browser security headers.
This is executable/startup acceptance, not a funded bridge or browser-wallet test.

## Signed Solana expiry and retry checkpoint

Unseen signed Solana payments now enter expiry recovery through the same critical
reconciliation path. An expired wall-clock timeout or missing RPC status is not
proof. Each configured provider must report the expected genesis, finalized height
past the saved validity limit, a current finalized slot, an invalid blockhash,
absent transaction/status, and both complete account histories through the immutable
token/operating origins. Failed history entries count as observations too. Canonical
mode requires the independent provider. History traversal retains the bounded
scanner contract; missing/truncated/oversized histories fail closed.

Verified expiry atomically preserves the signed bytes, retires that preparation,
releases only unused operating capacity and leaves customer principal/inventory (or
earned principal) untouched in review. Retired attempts leave the executable queue;
their original policy, draft and allowance remain readable for revalidation even
when later generations use a different fee hold.

The private command `{"operation":"retry-solana","transaction":"SIGNATURE","reason":"reviewed expiry"}`
uses the operator existential and critical evaluator. It requires pause, revalidates
the exact signed attempt, refreshes its source, repeats complete expiry proof and
custody reconciliation, and records immutable approval for the latest retired
generation. It does not sign, send or resume. The existing preparation engine then
re-reserves operating capacity and creates the next bounded generation after resume.
Mixed histories of approved expiry and unsigned cancellation are supported; another
recorded, unexpired attempt blocks retry. Customer conversion/refund and earned
payments share this engine. Earned-reservation release remains restricted to wholly
unsigned cancellation history; proved expiry permits retry, not that release command.

Verified locally: provider disagreement, non-expiry, stale context/height, valid
blockhash, incomplete histories, observed failed signatures and observed transactions
all reject expiry. PostgreSQL contracts verify exact-attempt binding, immutable bytes,
no balance movement, replay/conflict handling, explicit latest-generation approval,
old-callback isolation, mixed histories, fresh preparation and earned-payment retry.
The executable rejects private retry commands in observation mode. Funded expiry,
wallet interaction and restart acceptance on real networks remain release work.

Scoped counts: expiry-proof function **43 baseline lines → 41 rebuild lines**,
using the same bounded history collector. Existing observation module **95 → 140**,
critical runtime **352 → 380**, control **106 → 109** lines, all still one file each.
Store grows **150 net lines**, including shared retry-history checks and customer
status updates; schema projections add seven lines. **No new files or migration**.
These additions complete another recovery path; they are not a whole-repository
size reduction or a claim of release readiness.

## Unsigned cancellation and retry checkpoint

The private command is `{"operation":"cancel-preparation","payment":"PAYMENT_ID","generation":0,"reason":"maintenance"}`.
It resolves through the operator existential and the single critical evaluator.
Cancellation requires pause, source verification, fresh custody, the exact current
generation and no recorded signature in that generation. Its cleanup plan comes
from the saved economic policy and draft, never operator-supplied outpoints.
Native PSBT/template/fee validation is shared with signing; Solana policy/request
validation is also shared and permits an unsigned expired blockhash to be discarded.

The ledger first saves the immutable cleanup/reason with a critical sequence.
Native cleanup unlocks only listed saved inputs, refuses foreign locks and never
sends Core an empty unlock list. A lost reply leaves cancellation pending; retry
rechecks current locks and the same saved plan. Completion records a second durable
sequence and resolves the intent while retaining principal, inventory and its fee
hold. A pending cancellation blocks draft/signature mutation in both application
checks and database triggers. Completed old-generation callbacks cannot change new work.

The existing preparation engine can reuse a completed, wholly unsigned cancellation,
with fresh budgeting and a new generation, without creating another payment engine.
The worker selects these retries as eligible work. After eight generations it leaves
the payment in review; it does not leave an unpayable item silently Ready. Earned
payments use the same path and may instead release their reserved revenue after
completed cancellation. Signed Solana expiry uses the separate proof/approval path above; native replacement
is still unfinished.

`migrations/002.sql` advances rebuild schema 19 to 20. Its 29-line forward migration
retains the old records and changes the fee-release trigger to accept only paused,
resolved, fully cancelled unsigned work with released fee capacity. It still rejects
pending preparations or any recorded attempt. Migrations require the worker stopped;
this migration has run only against disposable databases, not existing custody.

Cabal/QuickCheck checks cover saved Native/Solana cleanup, absent drafts, invalid
policy, lost unlock replies and foreign/empty locks. PostgreSQL checks cover journal
and sequence invariants, pending/replayed/conflicting cancellation, signed refusal,
all eight generations, stale completion, held fees, earned retry/release and the
independent SQL refusal of premature earned release. Runtime observation mode
rejects cancellation. Actual funded interrupted-cancellation/restart acceptance remains.

Scoped counts: native unlock **9 baseline lines → 8 rebuild lines** (excluding shared
lock validation). Existing `Payment.hs` **199 → 222**, `Critical.hs` **326 → 352**, and
`Control.hs` **103 → 106** lines, each still one file. Store grows **149 net lines**
for cancellation, earned resolution and retry eligibility; schema projections add
four lines. **No new Haskell production file**; the sole new file is the forward
migration. This adds missing behavior rather than claiming a whole-feature reduction.

## Refund authorization checkpoint

The private command `{"operation":"refund","deposit":"DEPOSIT_ID"}` resolves
through the operator existential and critical evaluator to one atomic Opaleye
operation. It returns a typed `RefundAuthorization`, not unstructured JSON.
The command cannot supply a destination or amount. New authorization requires
paused service, fresh custody, an eligible receipt and preserved cost policy.
Native refunds use the saved customer refund address; connection-free Solana
refunds require the verified owner and matching reference from current receipt
evidence. Historical owner-bound orders retain their original policy.

Unresolved payment work blocks refunds, settled principal cannot be refunded
again, and another unpaid obligation on the same order must finish first. An
unstarted conversion may be cancelled atomically into a full-principal refund.
Refund authorization never signs, broadcasts or posts a principal debit: it creates
the ordinary `Refund` payment for the shared engine and advances the critical
sequence. Replays return the saved result without another reservation or sequence.
The engine retains source rechecks, backup coverage and actual-effect settlement.

Quote expiry or a completed conversion can release the original refund operating
allowance. Authorization restores it only after the shared operating-capital and
daily-budget checks; it cannot silently reuse a spent allowance. Conversion holds
are released while refund holds remain protected. Additional deposits after a
completed conversion preserve that order's Paid status and original payout.

PostgreSQL contracts cover partial native refunds, replay/sequence/balance invariants,
conversion cancellation, unresolved-payment and already-settled refusal, expired
allowance restoration, Solana verified-owner binding, missing/mismatched proof
rejection and observation-only runtime refusal. The executable control check also
rejects a caller-supplied refund recipient. These are disposable ledger tests;
funded refund signing/submission remains part of real-chain acceptance.

Scoped size: authorization **72 baseline lines → 93 rebuild lines**, inside an
existing storage module on both sides. The extra checks cover pause/freshness,
durable sequencing and re-reserving expired operating budgets. Integration adds
one grammar constructor, a five-line result record, one parser branch and three
runtime lines; **no new production file or refund-specific payout engine**.
This checkpoint increases source size to complete required behavior; it is not
presented as a reduction or a claim of perfect security.

## Operator capital coverage

The private operator DSL now accepts:

```json
{"operation":"cover-source-loss","deposit":"native:<txid>:<vout>","recovery":123,"float":"30","earned":"20","reason":"cover the verified 50-unit loss"}
```

New coverage requires pause and a fresh native missing-source proof. A separate
read-only custody inspection includes proved deficits without certifying ordinary
readiness. Its balances must match, its native block/height must match the source
proof, and its ledger revision and timestamp must still be current at commit.
The receipt snapshot and latest missing recovery sequence must also remain exact.
The operator's two nonnegative contributions must cover the entire receipt;
only free native float and earned fees can be used. Active inventory reservations
and earned withdrawal reservations remain protected. Principal, operating budgets,
backing and LP allocations are unavailable to this command.

The immutable cover, fenced sequence and balanced deficit/capital posting commit
atomically. Exact replay changes nothing; changed contributions or reason conflict.
The source remains ineligible and the service stays paused. Coverage itself grants
no signing, sending or payment-resumption authority. If the physical source
returns, the existing recovery journal returns the saved capital split exactly
once. Covered-payment approval and the corresponding send-source authorization
remain the next implementation step; this command alone cannot resume a payment.

The coverage-write function is **57 lines versus 66** in retained `Source.hs`,
excluding shared helper functions on both sides. Store adds 76 total lines for
closed operations/read/replay/write, plus three schema projection lines. There
are **no new files or migrations**. The read-only loss custody wrapper reuses the
normal inspection path. The old test-only cover insertion was removed: PostgreSQL
contracts now perform actual coverage, including conflict/replay, stale revision/
time, mismatched block, partial coverage, protected earned reservations and exact
capital return. Build, QuickCheck and executable operator checks pass. Funded loss
coverage and clean-host recovery are still acceptance gates.

## Native source-loss inspection

The worker now runs a bounded native source-recovery pass after scanning and before
custody reconciliation, including while paused and during explicit resume. Closed
Opaleye reads select at most 1,000 ineligible/recovering native receipts and load
their saved order binding and scanner evidence. No caller supplies a query or RPC
method. The shared native inspector verifies network/wallet context, exact owned
outpoint/amount, immutable customer instruction/policy, scanner depth/anchor and
current canonical wallet position. A missing source requires negative wallet
confirmations, the explicit mempool-not-found response and an absent UTXO. A
timeout or unsupported response is not loss. A second identical wallet transaction
read detects an inconsistent view. Confirmed return and still-pending sources use
the same inspector, with coinbase maturity handling for unbound receipts.

Results use the existing append-only recovery operation and balanced deficit/
return journals. Unavailable observations preserve the existing loss and hold the
service for review. The pass visits the other candidates before propagating a
recording failure. It neither approves recovery nor signs/sends. Capital coverage is now implemented; covered-source approval remains unfinished.
This inspection supplies the chain proof for both.

Build, QuickCheck, PostgreSQL and executable checks pass. Captured-output/offline
RPC tests cover missing/restored/pending outcomes, unknown mempool results, a live
mempool entry, an unspent output, stale scanner state and a changed transaction
view. Database contracts cover candidate selection/evidence reads and the existing
loss/return persistence. Live reorg/loss recovery remains unverified.
The inspector is **73 lines versus 75** in retained `Reorg.hs`; identity checking
now belongs to the caller and ledger reads to closed Store operations. The whole
PaymentSource module grows **67 → 147** lines, Store adds 33 and runtime adds 16,
plus one grammar line; there are **no new files or migrations**. This is recovery
integration, not a whole-repo reduction. Existing native script/transaction-ID
validators are reused rather than copied.

## Restored-source approval

The private operator DSL now accepts:

```json
{"operation":"approve-source-recovery","payment":"<obligation ID>","restoration":123,"reason":"reviewed restored deposit"}
```

This approves an existing restoration sequence, not a caller-supplied source proof.
The runtime requires pause, checks the expected restoration, rechecks the actual
source, reconciles pending payments and custody, then records approval. The final
Opaleye transaction repeats the latest-restoration and exact suspended-work checks.
The source must be eligible and its latest recovery must say restored with zero
shortfall. The obligation must still be under review. The recorded suspension
must follow any previous approval, name this obligation exactly once and retain
its unchanged work hash. Pending preparation cancellation prevents approval.

The approval preserves the prior `ready` or `paying` state and records custody,
loss/restoration sequences, reason, work hash and a new fenced critical sequence.
It changes no money and does not sign, send or resume. Exact replay is idempotent;
changed reasons conflict. Replaying an old approval during a newer suspension
cannot revive the payment. Covered/permanently lost sources cannot use this
restoration command; their separate payment-approval workflow remains unfinished.

Build, QuickCheck, disposable PostgreSQL and executable operator checks pass.
Contracts cover pause/freshness, stale restoration, changed payment history,
immutable replay, preserved balances, repeated loss/return and observation-only
refusal. Funded recovery and prepared/signed-payment recovery acceptance remain
open. This checkpoint adds 101 net storage/schema lines, 15 runtime lines and
four grammar/control lines, with no new files or migrations. The executable test
now explicitly terminates and waits for its child before checking fence release;
this fixes a cleanup race exposed by the threaded test runner. The retained baseline combines restored and covered
approval; comparing its complete function size to this restored-only subset would
misstate parity. Existing work hashing, source checks, custody and backup barriers
are reused rather than introducing another recovery engine.

## HTTPS worker/signer integration

The existing `rebuild-store-check` executable has an opt-in TLS contract:

```sh
ECX_REBUILD_TLS_ONLY=1 ECX_REBUILD_TEST_SDK=/absolute/path/libecx_solana_sdk.dylib \
  cabal run ecx-bridge-rebuild:rebuild-store-check --offline
```

Like its other modes, supply `ECX_REBUILD_CONTRACT_DATABASE` and
`ECX_REBUILD_CONTRACT_READER` for a disposable, migrated PostgreSQL database
(prefixed `ecx_rebuild_contract_`), using the existing local test PostgreSQL port.
It requires `openssl` for temporary certificates. Direct binary execution also
needs `ecx_bridge_rebuild_datadir` pointing at this directory; Cabal run supplies it.
It never connects to a live chain. The Solana HTTP responses are explicit offline
protocol fixtures; the public seed is the existing unfunded SDK test vector.

This contract runs the production critical evaluator, its private generated
Servant HTTPS client, the production signer server/evaluator with a SELECT-only
reader, and the actual Solana SDK FFI. The SDK-generated signature/bytes must match
the preserved fixture exactly. Incorrect authentication and an untrusted TLS
certificate both fail before signer chain calls and leave no recorded attempt.
After valid signing, the worker independently validates and persists the exact
reply; balances do not change. Removing its credential file then replaying the
same payment succeeds without further RPC/signing. No broadcast method is allowed
by the fixture server. Temporary listeners, keys and certificates are scoped to
the test lifetime. The contract executable uses one threaded RTS capability.

Build, TLS/SDK contract and the standard PostgreSQL contracts pass. This closes
the previously untested successful HTTPS integration, not deployed process
isolation: both evaluators run in separate threads of one test process. Separate
OS users/native RPC restrictions, real chain responses, lost-reply recovery and
funded end-to-end payments remain acceptance requirements.
No production source changed and no files or Haskell dependencies were added. The existing
contract file grows by 128 net lines, plus one Cabal runtime-options line. This
adds integration evidence, not a source-size reduction or full release acceptance.

## Observed treasury spending

The private operator command is:

```json
{"operation":"classify-spend","chain":"Native","transaction":"<observed transaction>","reason":"I attest this was an operator treasury spend"}
```

Supported streams are `Native`, `Solana` (wrapped tokens) and `SolanaOperating`
(SOL). It returns the recorded critical sequence. It never signs or submits a
transaction. While paused, an operator may classify a scanner-recorded outgoing
effect with immutable ownership attestation. Amounts/fees come exclusively from
saved chain evidence. Any recorded bridge attempt, including earned withdrawals
and expired signatures, is excluded. Native principal outflow consumes free float
and its network fee consumes operating allocation; token outflow consumes free
float, and SOL outflow consumes operating allocation. Customer inventory holds
and both order/payment fee holds remain protected. Principal, backing, LP and
unallocated receipts are not sources of spendable capital.

The balanced journal, immutable approval and sequence commit atomically. Only the
matching event's review flag is cleared; no global review reset or automatic
resume occurs. Exact replay makes no additional posting and preserves custody
revision. A changed anchor, economic effect or attestation conflicts, retaining
review. Unlike new funding allocation, this operation cannot require a successful
prior custody reconciliation: the unexplained outgoing effect is what must first
be booked. Reconciliation and explicit resume still follow it.

The function is **60 lines versus 57** in retained `Postgres/Treasury.hs`, with
shared typed evidence and balance helpers excluded on both sides. This is a small
increase, not a reduction; it adds an affected-row check and uses the rebuild's
closed operation boundary. There are **zero new files or migrations**. PostgreSQL
contracts verify native/token/SOL postings, pause, replay/revision stability,
changed-anchor/ownership rejection, missing evidence, customer/earned-attempt
exclusion and protection of active inventory/operating reservations. Cabal build,
QuickCheck and executable operator checks pass. Real-chain operator spending and
custody reconciliation remain acceptance work. The executable smoke test passed
on rerun after one startup timeout with no server error output; its cause has not
been established, so that first-run startup behavior remains an acceptance concern.

## Verified treasury allocation

The private operator DSL accepts:

```json
{"operation":"allocate-treasury","deposit":"<observed receipt ID>","split":[["float","700"],["operating","300"]],"reason":"I attest these are operator-owned funds"}
```

The result is the durable decision sequence. New allocation requires paused
operation and a fresh custody reconciliation from the worker. It takes only an
eligible, unallocated, unbound receipt with current matching chain evidence and
no customer obligation. Native receipts must meet configured confirmation depth.
Native evidence must contain exactly one matching unbound receipt; token/SOL
balance changes must equal the saved amount, and failed SOL effects are refused.
The ownership attestation is immutable. It asserts ownership, not arbitrary money:
positive, unique splits must equal the observed receipt exactly. Only `float`,
`operating`, `backing` and `lp` are allowed; SOL can fund only `operating`.
A balanced journal entry, allocation proof, receipt state and fenced sequence
commit together. Exact replay, including reordered splits, returns the original
sequence without changing money or requiring another custody check. Changed
splits/attestation conflict. No allocation command signs or sends coins.

The allocation function is **70 lines versus 83** in retained `Postgres/Treasury.hs`
(signature through last statement, excluding imports/shared helpers on both sides).
It reuses current evidence decoding and ledger helpers, adds the explicit native
depth check and verifies affected row counts. Integration adds 15 lines outside
that function, with **zero new files or migrations**. The retained baseline is
still present until migration and real-chain parity; this is not a repo-wide cut.
Disposable PostgreSQL contracts exercise all three assets, protected accounts,
exact replay, conflict, pause/freshness, amount mismatch, failed SOL, mismatched
anchors, reviewed evidence, shallow/ineligible receipts and customer-fund refusal.
Cabal/QuickCheck and actual operator transport checks pass. These fixtures do not
prove funded-chain acceptance. Observed treasury-spend classification is implemented below the same closed
operator boundary; real-chain treasury acceptance remains outstanding.

## Earned-fee operator integration

The private operator interface now accepts:

```json
{"operation":"withdraw-fees","id":"<64 lowercase hexadecimal characters>","asset":"Native","amount":"10000","recipient":"<destination>","reason":"operator revenue withdrawal"}
{"operation":"cancel-fees","id":"<same identifier>","reason":"cancel unsigned withdrawal"}
```

Both return the durable `fee:<id>` payment identifier. `asset` is `Native` or
`Wrapped`; amounts are integer base-unit strings. These commands do not sign or
send immediately. New reservations require paused operation, actual chain identity
and destination/payout preflight, fresh custody, available earned revenue and
immutable terms. Solana withdrawals preview the exact requested amount, without
applying a second wrapping fee. Customer quotes and withdrawals share that preview.
Exact reservation replay checks saved terms without requiring another RPC call;
a cancelled identifier remains cancelled. Changed terms conflict. Cancellation
requires pause and the existing ledger rules: no signed or uncertain payout may
release its reservation. Completed unsigned preparation cancellation is supported.
After explicit resume, the existing worker handles preparation, signing, backup
gates, submission and settlement through the same payment engine as customer work.
Observation-only mode rejects both commands before reaching the network or writer.

This checkpoint adds no files, database operations or migrations. Physical module
counts: Admission **86 → 90**, Critical **380 → 409**, Control **109 → 115**,
plus three grammar/import lines. These are integration additions, not a size
reduction. Sharing the exact-amount preview avoids a second Solana validation path;
closed operator constructors retain the single authorized critical dispatch.
Cabal build/QuickCheck, disposable PostgreSQL replay/conflict/cancellation contracts
and executable operator transport checks pass. Captured/offline preview tests are
not proof of a funded withdrawal; live two-process withdrawal acceptance remains.
Observed operator-spend classification is now implemented; live treasury acceptance remains outstanding.

## Private operator checkpoint

`cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- operator CONFIG`
reads one bounded JSON command from stdin. Supported commands are
`{"operation":"status"}`, `{"operation":"pause","reason":"maintenance"}`,
`{"operation":"resume"}` and the refund command described above. Unknown operations and fields are refused. The local
control socket is `operator.sock` inside the host-fence directory: owner-only
permissions are required, and unsafe pre-existing paths are never removed.
This is operator control; signer communication remains authenticated Servant HTTPS.

The parsed command hides its concrete result in `ControlPlan`, retains `ToJSON`,
and carries `Plan Operator a`. Only the evaluated result is serialized. Status
uses the SELECT-only evaluator; pause/resume enter the same critical gate as all
worker effects. Observation mode permits status/pause but refuses resume before
network or ledger mutation. No customer route grants operator authority.

Resume requires explicit native RPC signing/export denial, a recovery pass, refreshed
pending sources and a fresh custody check. One Opaleye transaction then compares the
exact pending attempts, rejects unresolved unsigned intents, reviewed obligations,
missing historical cost policy, per-asset source deficits and insufficient operating
allocations, and only then unpauses with an audit entry. Custody review checks are
reused rather than copied. The shared recovery pass does not swallow errors for
explicit resume; only the background scheduler may defer a custody check.

Verified locally: Cabal/QuickCheck protocol tests (including each of the thirteen
forbidden native methods), PostgreSQL positive resume and refusal/rollback for
stale scans, legacy costs and reviewed obligations, safe operator reads, observation
mode rejection, actual executable CLI/status/pause, unknown-field and permission
refusal, unchanged balances and temporary process/fence cleanup. The HTTP startup
check allows twenty seconds for local startup instead of five and includes the
child log on timeout. These disposable-state checks do not prove funded-chain resume.

Scoped counts: private transport **105 lines / 1 baseline file → 102 / 1 rebuild
file**, excluding the old shared listener. At that checkpoint the transport handled three commands;
the baseline handles more, so this is not equivalent feature parity. It adds strict
field parsing and owner/type/mode checks directly. Runtime **302 → 323 lines / one
file**, executable **79 → 87 / one file**, and Store **+57 net lines** for atomic
resume plus shared operating holds. The grammar and wire records gain operator
capabilities/status; no second financial evaluator or recovery module was added.
Smaller source is not a security certification; positive funded resume, pending-family
recovery and full operator-command parity still require acceptance.

Scoped physical-line comparisons (not whole-product reduction claims):

| Piece | Baseline | Rebuild | Scope limit |
| --- | ---: | ---: | --- |
| Deployment configuration | 133 / 1 file | 136 / 1 file | Adds six typed settings builders and required history anchors; baseline identity preserved |
| Executable startup/CLI | 91 / 1 file, plus baseline Runtime startup | 87 / 1 file | HTTP/worker/control lifetime and signer wired; backup/init and other operator command parity unfinished |
| Web boundary | 84 / 1 file | 71 / 1 file (previous checkpoint 53) | Shared customer/signer limits and fixed browser assets; no customer Unix listener |
| Host fence | 132 / 1 file | 128 / 1 file + 7-line Store constructor | Same durable protocol; explicit directory replaces environment lookup |
| Customer order workflow | 78 / 1 file | 63 / 1 file | Closed reads replace raw row/ledger access; funded HTTP acceptance pending |
| Admission/previews | 106 / 1 file | 86-line module + 20 lines in existing native adapter | Same total; customer runtime wired, funded acceptance pending |
| Custody chain workflow | 202 / 1 file | 188 / 1 file | Replacement-family and source-loss wrapper parity pending; not equivalent full-feature reduction |
| Custody snapshot function | 79 / existing custody file | 71 / existing Store file | Reuses freshness/balance helpers; live acceptance pending |
| Custody report persistence | 15 / existing custody file | 24 / existing Store file | Adds time/report validation; no claim of size reduction |
| Signer module | 144 / 1 file | 117 / 1 file | Now includes startup key validation and shared file permissions; replacement parity pending |
| Signer transport | 103 / 1 file plus shared web boundary | 69 / 1 file + shared 71-line Web module | Shared module also serves customer API; initial signer route only |
| Customer/worker runtime | Part of broader Runtime | 460 / 1 file (previous checkpoint 444) | Adds operator capital coverage; single critical dispatch retained |
| Focused source validation | 63-line mixed validation/storage/recovery function | 147-line module including native loss inspector | Covered-source approval remains unfinished; larger functional scope |
| Payment observation functions | 72 / broader Settlement file | 72 / 95-line dedicated file | Same protocol checks, narrower module |
| Broadcast/settlement store functions | 119 / 1 file | 143 / existing Store file | Adds earned funding, exact attempt binding and freshness gates |

This worker checkpoint adds 62 lines to the existing runtime and 55 to Store, plus
one grammar constructor, with no new production files. It adds missing integration;
it is not a size reduction or full parity with the baseline recovery scheduler.

The key verifier is 15 lines versus the baseline's 16-line verification function,
excluding comments/imports and shared permission checks. It now runs inside
`withSigner`, before handing out the evaluator, rather than relying on a separate
maintenance command. Signer plus transport grew from the previous 159 to 186 lines
across the same two files to add this startup check; moving permissions is not
counted as a feature reduction.

Custody storage adds five schema-projection lines and no production files. The
snapshot comparison excludes shared helpers, grammar, evidence/revision reads and
tests on both sides; it is not a whole-feature line comparison. Indexed evidence
reads avoid loading the complete evidence table; aggregate balances avoid loading
all journal rows. Terminal attempts are still checked individually, so long-history
performance remains to be measured. Source eligibility checking is shared with signing.

Still required: funded TLS worker/signer integration and deployed OS/native-RPC
authority separation; remaining private recovery commands and funded resume/browser-wallet acceptance;
integrated positive submission/reconciliation and funded Solana expiry/retry acceptance;
native replacement/winner changes and covered-source approvals generalized to earned
funding; complete custody acceptance and Haskell backup/restore integration; actual populated-ledger migration and funded
Signet/Devnet flows. Supported-wallet signing, off-host restore, canonical activation
and independent review remain release gates. Retain the baseline until parity and
real-chain acceptance permit deletion. Key seeds alone do not restore ledger history.

Startup integration finding: the retained baseline remote-backup adapter still
invokes a Python uploader. It cannot be adopted as the final Haskell rebuild;
replace that operational path before claiming complete backup/restore support.
The executable uses the host-fenced writer, but does not initialize a database,
initialize/adopt a fence or provide remote backup. Guarded private resume is now
wired; real-chain acceptance of that workflow remains outstanding.

## Covered-source approval checkpoint

Private command `{"operation":"approve-covered-source","payment":"convert:ORDER",
"recovery":123,"reason":"reviewed covered loss"}` records a distinct paused
operator decision. It obtains its own native missing-source proof, reconciles pending
attempts and custody, and atomically verifies the latest full loss, active full cover,
unchanged suspended-work hash and previous state. The proof must match the scanned
outpoint and the custody report's native block/height. Exact replay changes nothing;
restoration and coverage approvals cannot be substituted for each other.

Covered-source execution now uses the shared payment engine as described below.
Approval itself neither resumes nor sends nor marks the source eligible.

Scoped changes from the preceding rebuild checkpoint: Store **2,613 → 2,640 lines**,
critical runtime **460 → 478**, control **127 → 130**, operation grammar **96 → 97**;
**four existing production files, no new files or schema**. Tests **2,081 → 2,122**
in the existing PostgreSQL contract file. This is required integration, not a net
size reduction. Both approval kinds share one work-history check and atomic writer;
capital coverage and approval share one source/custody proof verifier. No new
query escape hatch or critical evaluator is introduced.

Validation: root Cabal build, QuickCheck/protocol suite and disposable PostgreSQL
contracts. Contracts exercise missing cover, stale custody, mismatched observation
and block, changed payment work, approval-kind confusion, conflicting replay,
unchanged money, retained pause and source ineligibility. These are local contracts,
not funded-chain or deployed signer-isolation acceptance.

## Covered-source payment checkpoint

One closed source-authorization check is shared by preparation, signing-decision
reads, signed-attempt recording, send authorization and unsigned-cancellation retry.
It accepts physical eligibility or an active full native cover, a currently accounted
missing-source loss, unreviewed incoming chain evidence and an approval for that exact
obligation/cover. A returned cover or unavailable source evidence cannot authorize
payment. No source eligibility flag is fabricated. Worker preparation/sign/send paths
repeat the complete native missing-source proof against the current scanner snapshot;
the dedicated signer independently reads the same durable authorization before and
after signing. This does not give the signer a write or broadcast capability.

Disposable PostgreSQL acceptance now takes an approved covered order through actual
ledger preparation, signing authorization, exact attempt recording, broadcast intent,
send authorization and balanced settlement. Transaction bytes/effects are explicit
offline fixtures, not live signatures/broadcasts. Tests prove unavailable evidence
blocks signing, attempt recording and sending; re-proving the same covered loss permits
continuation; settlement replay changes no money; source return repays the original
capital; the old cover cannot authorize a later loss.

Scoped counts versus the prior checkpoint: Store **2,640 → 2,675 lines**, critical
runtime **478 → 484**: **+41 production lines across two existing files**. The shared
contract file grows **2,122 → 2,170**. No new files, schema, services or evaluators.
This adds missing behavior through one predicate instead of copying a separate
covered-payment engine. Root Cabal build, QuickCheck and PostgreSQL contracts pass.
Funded-chain execution and native replacement families still require further
work/acceptance; these checks do not close release gates.

## Covered retry and native-family rules

Covered-source authorization checks backing independently of payment execution state.
Each closed payment operation still enforces its own state, so verified Solana expiry
can enter operator review without losing a valid capital cover. Retry still requires
an explicit paused approval, current source proof, fresh custody and verified expiry;
review alone cannot prepare or send. The PostgreSQL contract now exercises a covered
payment through expiry, refused unapproved retry, refused retry with unavailable source
evidence, approved retry, unsigned cancellation, another generation and settlement.
Saved payout terms remain identical. This fixes the duplicate state restriction with
**no net production-line increase** in Store (**2,675 → 2,675**); the existing contract
grows **2,170 → 2,201** lines. No new operation, table or file is needed.

Native replacement's pure rules are now in the existing native adapter. The baseline's
**48-line** `replacementOutputs`/family/draft validation block is retained unchanged,
plus its exports/imports: adapter **293 → 343 lines**, one existing file. This is a
validated extraction, not a claim of algorithmic improvement or whole-feature reduction.
Keeping the rules beside the shared transaction validator avoids another module and
keeps the immutable-input/payout/fee constraints visible together. QuickCheck checks
bounded increasing fees, unchanged recipient, conservation of value, duplicate/oversized
families and input/output/replay-policy mutations against the captured Signet template;
test module **269 → 299** lines. Synthetic mutations are not valid newly signed chain
transactions. Native replacement RPC drafting, signing, durable decisions, family
observation and winner recovery remain to be integrated before this feature is usable.

Validation: Cabal executable/contract build, QuickCheck suite and the full disposable
PostgreSQL contract passed. No existing custody state was migrated or chain transaction
submitted by these tests. The baseline remains required until parity and live acceptance.

## Native replacement adapter checkpoint

The existing native adapter now supplies unsigned replacement construction, exact-draft
signing and a shared family reader. The reader independently verifies saved bytes,
wallet/node synchronization, canonical winners, mempool spenders, confirmed owned
prevouts and two consistent chain views. Drafting refuses confirmed winners and only
builds the validated higher-fee template; signing rechecks the draft and family before
and after the existing template signer. Neither adapter broadcasts. The returned
family view retains the tip position, so callers can detect a change across construction
even when every member is absent from wallet history.

The corresponding baseline adapter functions occupy **228 physical lines**; their
rebuild versions occupy **176**, excluding imports/exports and the previously extracted
pure rules on both sides. Shared inspection replaces the separate drafting inspector.
Existing `NativePayment.hs` grows **343 → 523 lines** including imports/exports;
**no new production file**. Existing test module **299 → 432**, with **one copied
captured PSBT fixture**. The fixture's provenance explicitly records unsigned construction
from an already-confirmed public Signet input; it is not a live replacement proof.

Root Cabal build and QuickCheck pass. Offline contracts reproduce the captured PSBT,
exercise absent/pending families, simulated signing response effects, refusal of a
confirmed winner, foreign spenders and signature-bearing PSBTs, and discard construction
when the tip changes. The simulated signing reply is not a newly verified real signature.
Durable replacement decisions, signer routes, worker/family settlement and winner-change
recovery remain integration work; funded replacement/reorg acceptance remains a gate.

## Durable native replacement decisions

Closed Opaleye operations now read a bounded native family, find/replay an immutable
draft decision, save a draft and cancel unsigned replacement work. Family reads validate
the saved payment, generation, fee ceiling, exact bytes/policy, common input, increasing
fees and draft/member lineage. Saving requires pause, fresh custody, the current
broadcast parent, unchanged payment/source authorization and no pending draft. A draft
blocks ordinary sends. Cancellation preserves the decision and money; the parent
becomes sendable only after backup covers the cancellation sequence. Replay cannot
reactivate a cancelled draft or rewrite its bytes/reason.

Schema **21** adds forward migration `003.sql`, preserving the existing tables while
updating the replacement-binding trigger for the shared customer/earned funding engine.
It retains live native fee reservations, parent broadcast/sequence binding and one
pending draft, and checks either customer source eligibility/approved cover or a valid
uncancelled native earned withdrawal. Existing custody databases have not been migrated.
The private store component reuses the chain component's pure native validators; its
closed operations gain no caller-supplied RPC, query or IO capability.

Verification uses actual disposable PostgreSQL and synthetic ledger transactions:
family binding, paused creation, exact replay, changed-byte conflicts, competing drafts,
blocked sends, immutable cancellation, backup-before-resend and unchanged balances,
then ordinary settlement of the original. Pure chain fixtures remain separately tested.
The scenario runs before the scan fixture that intentionally leaves an incomplete intent.
No concurrency guard was weakened to accommodate test setup.

This completes persistence/cancellation primitives, not the operator replacement flow.
Dedicated signer routes, durable replacement signatures, worker integration, family
settlement and winner/reconfirmation recovery remain pending. No replacement signature
or broadcast is enabled by these new Store operations alone.

Scoped size: Store **2,675 → 2,840**, schema projections **272 → 279**, existing
PostgreSQL contract **2,201 → 2,263**; one **37-line forward migration**, no new
Haskell modules or executables. This adds missing behavior rather than reducing total
lines. It reuses the payment/source checks and native validators instead of adding
another customer-only replacement engine. Root Cabal build, QuickCheck and migrated
PostgreSQL contracts pass; populated migration and live replacement remain unverified.
