# Auditable financial-core refactor: design and execution plan

Status: **in progress; 112/120 steps verified (A–I, J105–109, J111, J116–117)**. This replaces the
completed implementation checklist, not its evidence. Execution baseline source is
`3d4970b3e502de9d4c9a89803610df3802e3e322` (implementation `bc9713c`). The funded
pilot stays on `548c509`. See [RELEASE-REVIEW.md](RELEASE-REVIEW.md) for the actual
acceptance record and open release gates. Do not relabel old tests as evidence
for new code.

This document is the implementation contract for this refactor. Its purpose
is to make decisions explicit now, minimize interacting changes and leave working,
reviewable code after each checkpoint. It cannot guarantee bug-free software or
perfect security. Passing gates, retained financial evidence and independent
review are required, especially before valuable-fund operation.

## 1. Objective, boundaries and execution rules

The objective is fewer independently mutable financial facts, explicit authority,
smaller comprehensible decisions and preserved functionality. A smaller source
count is desirable only when the full audit burden also decreases. Approximately
9,000 application/schema lines is an experimental budget; 7,000–8,000 is a stretch,
not a promise. A 4,000-line financial core would not include all adapters,
administration, configuration and interface code. Count those separately, not as
savings. The current corrected application/schema baseline is 14,843 physical
lines, including comments/blanks, excluding 216 embedded Rust test lines.

Preserve these requirements:

- Three product directories; one Servant worker/server and a dedicated signer.
- Connection-free wrapping/unwrapping, four customer HTTP endpoints, QR/payment
  links, saved-order recovery, refunds, explorer/trading/support links.
- New quotes charge 1% in each direction; historical quotes retain saved terms.
  Network fees/rent never silently reduce the quoted customer payout.
- Real L2L Signet/Solana Devnet and ECX betanet/Solana Mainnet profiles. No new
  simulated network offered as a substitute for acceptance.
- Servant handlers return `Plan 'Customer` containing existential requests;
  `Operation.command` resolves the typed DSL before evaluation. Preserve caller,
  severity, functional dependencies, associated contexts and unique signer results.
- Separate safe/critical evaluators, the sole critical dispatch call site, signer
  Servant HTTPS/authentication, independent durable-decision validation, protected
  credentials and process/RPC privileges.
- PostgreSQL and Opaleye for all application reads/writes, diagnostics, role checks,
  data migration and test fixtures, inside specific closed DSL operations.
  Connections/transaction control and schema DDL are infrastructure.
- Haskell, GHC JavaScript browser, HTML/CSS and existing bounded Rust SDK FFI;
  root-Cabal build, private configure/start and token/offline-key workflows.
- Token mint authority and pool administration remain outside bridge custody.
  Preserve implemented CLI operations; do not add multisig, unattended compounding
  or LP locking merely because they appear in historical notes.
- Append-only accounting/evidence, exact signed bytes, bounded budgets, complete
  recovery behavior, independent Mainnet verification and required backup coverage.

Read `AGENTS.md`, [ARCHITECTURE.md](ARCHITECTURE.md) and the full unmodified
[reference/Main.hs](reference/Main.hs) before architecture changes, including after
context loss. The reference is a sketch, not authority to reintroduce its incomplete
types. ARCHITECTURE documents the intended corrected boundaries.

Use the existing checkout and caches; one compiler job, at most one temporary
build/test VM at a time. Do not start new daemons or funded transactions to test
pure changes. Stop task-owned unused processes. Preserve user edits, shared
services, wallets, snapshots and credentials. Do not delete shared caches to force
recompilation. No parallel agent work unless the user explicitly requests it.

Commit/push passing checkpoints to the active refactor branch; do not force-push,
publish a release, migrate funded custody or resume the funded pilot under this
plan alone. No public or valuable-fund activation is implied by a passing local
checkpoint. Ask only for genuinely missing external inputs/authorization; batch
those requests while completing independent work.

For every checkpoint, record here or in RELEASE-REVIEW: source commit, changed
responsibility, invariant IDs, exact commands/results, limitations, total lines
and files added/removed including helpers and compatibility, and next step. Keep
one plan and one evidence record. No report, test executable or architecture file
per small change.

## 2. Chosen architecture

### D01. Pure decisions, closed persistence, explicit external effects

Keep the existing process/DSL shape. Introduce a pure lifecycle implementation
inside the existing core library, initially `src/Bridge/Lifecycle.hs`:

    Servant / local operator / worker
        -> existential Request -> Operation.command -> closed DSL
        -> safe or gated critical evaluator
        -> specific Store operation
        -> bounded typed snapshot -> pure decision -> atomic writes

Chain IO supplies observations, not authorization. Signing and broadcasting remain
explicit critical workflow steps outside database transactions. No generic action
list, generic patch endpoint, arbitrary IO/SQL instruction, free-form signer,
universal workflow framework or new broker is introduced.

Pure code imports Domain/Wire and ordinary data libraries; never Store, RPC,
filesystem, clocks or secret access. Retain current public wire formats while
changing internals. Add a private store module only if splitting persistence gives
a real boundary; do not create parallel packages or a second server.

Use a few operation-specific functions, for example `decidePreparation`,
`decideSettlement`, `decideCancellation` and `decideSourceRecovery`. Their input is
an operation-specific bounded snapshot and typed evidence. Their output is refusal
or a narrow result for that operation. Do not introduce a giant universal Snapshot,
a JSON transition program or an exported `CommitDecision` callback.

A decision is data, not a transferable capability. Store loads current rows and
recomputes the decision inside its existing locked transaction. Other processes
cannot submit an arbitrary decision object to have it persisted. Preview code can
use the same pure function, but preview success is not an execution authorization.

### D02. Separate economic lifecycle from chain evidence

Use these distinct concepts; never merge them merely to reduce tables:

| Concept | Owns | Does not own |
| --- | --- | --- |
| Order | Immutable customer request/quote/policy, capability, deadlines, deposit instruction and admission decision | Payment execution or settlement truth |
| Receipt | Exact incoming identity/amount, association and source evidence/eligibility | Permission to invent a payout or spend all wallet balance |
| Payment | Immutable funding identity and one economic lifecycle | Complete protocol transaction history |
| Preparation | Generation, exact policy/draft, fee allowance and retirement/cancellation decisions | Proof that a send succeeded |
| Attempt | Exact signed bytes/ID, generation, broadcast authorization and observed transaction outcome | Authority to pay principal twice |
| Journal | Immutable balanced principal/fee/cost/deficit movements | Chain finality or user authorization |
| Reservation | Which capital is held, for what purpose, amount, and release/transfer state | A second payment-status machine |
| Recovery evidence | Source loss/return, expiry, replacement family, changed winner and explicit approvals | A blanket bypass of normal checks |

One order can have multiple receipts and refunds. One payment can have multiple
attempts. A fee withdrawal has explicit earned-fee funding, not a fabricated order.
Payment progress and source eligibility are independent dimensions. A previously
settled native payment can enter evidence review; this does not undo the fact that
principal was booked or authorize another ordinary payment.

The typed economic phase is conceptually:

    Ready | Active Generation | Settled AttemptId | Cancelled

`NeedsReview` is a separate derived execution restriction with typed reasons,
not a phase that overwrites whether funds were already paid. Drafting/signed/queued
progress comes from preparation/attempt facts, not another independently mutable
payment phase. Do not erase historical attempts when the economic phase changes.

### D03. Target persisted ownership: conservative schema 22

First integrate all new decisions over schema 21. Only then perform one planned
schema-22 migration. Do not invent a new event-store architecture or rebuild the
whole schema. Retain deposits, postings, explicit reservations, preparations,
attempts, source/replacement evidence and their necessary constraints.

Use the existing `intents` relation as the authoritative payment-root relation;
its Haskell projection may be named PaymentRow. Extend it to exist from payment
creation, including ready customer obligations and earned-fee withdrawals. Preserve
all existing IDs and funding foreign keys. Replace `resolved` with these columns:

| Column | Meaning / constraint |
| --- | --- |
| `deposit_id` | Present exactly for customer funding; immutable composite FK with `obligation_id` binds its existing receipt; partial uniqueness excludes cancelled roots |
| `phase` | Closed values `ready`, `active`, `settled`, `cancelled` |
| `active_generation` | Nonnegative bounded generation only when active; references that payment's preparation |
| `settled_txid` | Present only when settled; references an attempt belonging to this payment |
| `settlement_event_id` | The original principal-settlement event, unique; set once and retained across winner changes |

Keep existing `id`, exactly-one `obligation_id`/`withdrawal_id`, chain and native
common-input identity. Funding remains immutable. Do not duplicate amount,
recipient and policy from their current immutable funding owners just to avoid
a join. All payment-root rows are created atomically with their funding record.

G71's concrete schema inventory found that removing obligation status also removes
the partial receipt-allocation index. Retain that guarantee declaratively: add the
immutable receipt reference above, constrained by `(obligation_id,deposit_id)` to
the obligation's existing identity, and a unique `deposit_id` index for noncancelled
roots. Earned funding has neither customer field. This constrained reference avoids
custom cross-table locking/uniqueness code and cannot independently change funding.

Preserve one active payment per destination chain using a partial unique index on
`chain WHERE phase='active'`. The old `resolved=0` partial index must be replaced
because ready roots now exist before preparation. An active generation must belong
to the same payment (composite FK/constraint). A settled transaction and settlement
event must be demonstrably bound to that payment. Keep append-only principal
postings and once-only event identity enforcement independent of the mutable winner
pointer. A native winner change updates only the verified winner/cost history;
it cannot replace or replay the original principal-settlement event.

Retire `obligations.status`; execution is read from the root plus recovery facts.
Replace `orders.status` with a narrow `admission_state` retaining only the existing
pre-payment meanings: `Provisioning`, `AwaitingDeposit`, `ExpiredUnfunded`,
`NeedsReview`. Customer payment progress is projected from payments, not written
back into the order. Remove `orders.payout_tx` after deriving it from the relevant
conversion or refund payment. A paid conversion's link takes precedence over an
additional refund. Preserve recovery review overlays, including after settlement.

Keep `attempts.state`, preparation cancellation/retirement, deposit eligibility
and reservation phases: they describe different facts. Do not remove them as
"duplicate state". Preserve all currently supported source-loss/cover/return,
replacement, cancellation and treasury decision records. Their code can share
mechanics without merging distinct evidence into one untyped recovery table.

Customer display projection has explicit precedence: applicable unresolved review;
otherwise successful conversion; otherwise the relevant refund outcome; otherwise
active/ready payment progress; otherwise recorded admission/expiry. Preserve the
baseline's treatment of additional receipts and applicable source reviews using
comparison tests. Multiple refunds are not an excuse to choose an arbitrary row;
use the existing documented identity/ordering rule, or refuse an ambiguous legacy
projection for explicit repair. The projection never authorizes signing.

`RepairCompletedOrder` remains an operator command for compatibility. It validates
historical economic facts; on the new derived projection it is an idempotent
verification/no-op, not a way to set arbitrary status or payout identity.

The exact DDL syntax and adaptor names are implementation details. These ownership,
phase, index and compatibility decisions are fixed. If real historical data cannot
map unambiguously, stop migration and report it; do not invent a new design silently
or throw away history to make it fit. New schema version is 22 only if still unused
when implementation starts; otherwise allocate the next unused version explicitly.

### D04. Snapshot, decision and commit contracts

Snapshots carry payment/funding identity, immutable terms, active generation,
relevant attempts and approvals, available allocations/holds, readiness facts and
subject-specific evidence versions. Bound lists using existing work/family/history
limits. Do not load all orders or replay the entire journal per request.

Use explicit typed inputs; do not pass `Value` or loosely typed maps through pure
financial logic where the shape is known. Decode protocol JSON at its boundary.
Retain exact original signed/archived bytes where byte identity matters. Typed
values are not proof of freshness, authenticity or correct construction by another
process; validate at every trust boundary.

Decision outputs are specific, such as preparation reuse/create, settlement replay/
apply, cancellation begin/finish and retry refusal/approval. Include explicit
postings/hold changes required by that decision. Their constructors alone do not
grant IO authority. Store's closed operation verifies the expected subject and
current state and selects the only permitted writes.

Refusals are stable typed categories mapped to existing external error codes.
Distinguish policy refusal, stale/retryable observation, unavailable infrastructure,
corrupt state and uncertain external effect. Unknown outcomes retain work and
liabilities; no blanket retry handler catches them and sends again.

### D05. Transactions and concurrency

Retain the existing single writer, process critical gate, database advisory lock,
filesystem fence and deployment-row lock. Make write isolation explicitly
READ COMMITTED with the deployment row locked before financial reads; all runtime
financial writers must obey that protocol. Read-only views/signing snapshots use
REPEATABLE READ READ ONLY. Keep the signer and worker's roles separate.

This is intentionally not a switch to optimistic per-payment concurrency or a
blanket SERIALIZABLE/retry framework. The global lock protects shared funds and
budgets; a payment revision alone does not. Acquire any additional row locks in a
stable order after deployment locking. Keep transactions short, with no RPC,
signer calls or remote upload inside them. Preserve the existing necessary local
fence synchronization before commit; it is part of crash safety, not network IO.

Use existing critical sequence, custody revision, scan anchors and exact subject
versions; do not add a conflicting parallel global revision system. Critical
sequences need not increment once for every low-level write; preserve the current
financial authorization/backup semantics. Checking a whole-deployment sequence for
every signer read can falsely invalidate an otherwise unchanged subject; compare
the complete relevant authorization state and readiness dependencies instead.

Rows affected, foreign keys and unique constraints are checked. Idempotent requests
verify that saved terms/evidence match; `ON CONFLICT DO NOTHING` does not establish
semantic equality. A failed database transaction rolls back. Preserve connection
fencing on unexpected/uncertain failures. Do not add transparent transaction retries
around actions that touch the filesystem fence or external systems.

Explicit locks are cooperative, not protection against a malicious database owner.
The documented trust model includes reviewed service roles and trusted operator/
DB administration. The signer reduces authority but is not protection against every
compromise of the host, keys or privileged ledger administrator.

### D06. External-effect ordering and restart behavior

Keep the existing durable payment protocol, in this order:

1. Commit exact funded preparation and budget/holds.
2. Obtain required checkpoint coverage; refresh readiness after slow work.
3. Ask the signer for the saved preparation ID/generation, not arbitrary bytes.
4. Signer independently reads, validates, signs under its gate and rechecks.
5. Worker validates the result and commits exact signed bytes and identity.
6. Commit broadcast intent and its sequence; obtain required backup coverage.
7. Recheck current authorization and chain validity, then submit those saved bytes.
8. Observe actual confirmed/finalized effects; atomically book settlement/costs.

No external queue, distributed transaction or promise of cross-chain atomicity.
The attempt/broadcast-intent records already serve as a bounded durable outbox.
No generic outbox worker is permitted to broadcast messages that bypass critical
execution checks. Both chains remain separately verified.

| Interruption | Required recovery behavior |
| --- | --- |
| Before preparation commit | No signing/send; safely repeat the request |
| After preparation, before signing | Reuse exact saved preparation after current checks |
| Signer reply lost | No send authority from the lost reply; follow existing saved-decision checks, never invent a different plan |
| Signed bytes saved, before queue | Retain bytes; require current authorization/coverage before queue |
| Queue commit or send acknowledgment uncertain | Inspect durable records and chain; never infer nonexecution from timeout |
| Send succeeded, before settlement | Observe retained attempt and book its effects once |
| Source/winner changes after settlement | Preserve principal history; apply explicit recovery/cost rules |
| Process loss during cleanup or backup | Retain pending state, verify actual completion, keep intake paused when required |

### D07. Security checks that sharing must not remove

Keep exact native inputs/prevouts, replay policy, recipient/change/fee checks and
family overlap handling. Keep Solana account roles, instructions, signatures,
nonce, mint/ATA, finality and independent-provider requirements. An SDK encoder
must not be the sole oracle validating its own output.

Keep the worker's validation of signer replies and the signer's validation of
saved authorization even if both call the same pure implementation. Keep unique
`Result severity op` constructors and strict response decoding. Reflection checks
constraint types; it is not cryptographic authentication. Gate ownership and process
separation cannot be replaced by a typeclass.

Retain full custody-backup restore verification, minimum sequence, encrypted native
wallet/unlock binding and old-signer exclusion. Keys alone cannot recover obligations
or uncertain sends. A same-Mac backup exercise is not physical disaster independence.

Use a small shared protected-file implementation only for matching contracts.
Represent differing owner/permission/replace rules explicitly; no permissive generic
file-access configuration. Preserve opened-descriptor checks, no-follow behavior,
bounded reads, exclusive publication, fsync, lock-inode lifetime and echo restoration.
Never log secrets, customer capabilities, authenticated URLs or raw configuration.

Keep bounded API/RPC/history/queue limits, safe DOM text handling, private setup,
TLS and authentication. Do not broaden parser acceptance or remove database
constraints to meet a line target. Keep dependencies pinned and required notices.

### D08. Migration and compatibility strategy

Logic extraction uses schema 21 first, one operation at a time. Schema-22 migration
is a later isolated checkpoint after all pure decisions pass. No deployed dual
writer, live shadow sending or runtime old/new switch. Temporary comparison code
runs only against isolated copies and is removed after acceptance.

Keep historical migrations 001–008 unchanged. For schema 22, use new reviewed DDL
for structure, and a specific closed Opaleye migration operation for row conversion,
comparisons and activation metadata. Do not add raw SQL application/DML escape paths.
Fresh installs and upgrades use the same schema contract, including migration tests.

Quiesce worker and signer, claim the existing migration/worker lock and retain a
consistent encrypted snapshot. Make migration staging distinguishable from active
schema. Create/backfill/verify target columns and records; only then atomically
activate schema 22, remove dependent obsolete columns/constraints and install new
ones. If data size requires batches, stage them with durable progress and an
idempotent resume; no runtime service accepts a staging schema. Activation must
be atomic and refuses incomplete verification.

Mapping rules: keep original funding/payment/attempt IDs, policy bytes, capabilities,
quote terms, exact signed bytes, generations and evidence. Create missing ready
payment roots for existing obligations/withdrawals without creating new economic
postings. Derive active generation from verified unretired preparation; settled
winner from retained settlement and winner-change evidence; cancellation from its
explicit records. A legacy `review` status is not arbitrarily mapped to `ready`:
recover its restriction from existing evidence or preserve a typed migration-review
record tied to the original row/digest. Such records are immutable and remain
fail-closed until an existing authorized recovery action supplies matching proof.
No generic clear-review action or successful-state fabrication.

Verify all balances, liabilities, allocations, holds, budgets, roots, orders,
attempts, approvals, evidence, cursors, sequence and backup boundaries. Verify
customer projections against equivalent original facts. Require original accounting
event linkage for historical settlement; if it cannot be uniquely proven, refuse
migration of that ledger for explicit investigation.

An old backup/schema may be inspected and migrated in staging, never made payable
by lowering a fence. Rollback before any new effects may use the preserved snapshot
under the existing recovery contract. After newer commits/signatures/sends, use
forward recovery retaining the latest data; merely switching binaries is unsafe.

### D09. Testing and audit design

Use existing Cabal QuickCheck suites and actual PostgreSQL contracts. Add a small
independent property model, not a second implementation of every rule. Generate
legal operation sequences and invalid inputs separately. Check balanced postings,
protected funds, immutable terms, once-only principal, stale callback refusal,
capability separation and bounded resources.

Compare old/new decisions on identical snapshots and evidence before removing the
old path. Old code is a regression reference, not an infallible specification.
A demonstrated old defect needs a separate invariant-based test and an explicit
behavior correction. Never normalize away bytes, destinations, amounts, generation,
critical ordering or evidence identity to make a comparison pass.

Use failure injection at durable boundaries and deterministic concurrent schedules
with bounded synchronization. Actual process-kill/restart and real database cases
complement exception tests. Preserve a minimized reproducer and seed for failures.
Tests must shrink state-machine traces to valid meaningful counterexamples, not
turn every failure into rejected malformed input.

Maintain one traceability table in ARCHITECTURE: requirement/invariant -> owning
facts -> operation/check -> durable writes -> external effect -> test/evidence.
Use negative mutations for representative critical checks. The bounded TLA+ signer
model remains supplemental; do not claim it proves the Haskell implementation,
cryptography, OS isolation or all unbounded states.

### D10. Exact economic transitions and review semantics

`Ready` means economically unpaid with no active preparation; it does **not**
mean eligible to execute. `canPrepare` additionally checks all source/review,
prior-generation, budget, readiness, pause and backup requirements. A finalized
failed attempt stays blocked if the existing protocol offers no authorized retry.
Do not add a new recovery capability while extracting these rules.

| Operation | Economic transition | Required distinct facts/effects |
| --- | --- | --- |
| Promote receipt / request earned-fee withdrawal | No root -> Ready | Immutable funding root, correct holds, unique funding identity |
| Prepare initial/approved next generation | Ready -> Active(g) | Current source/readiness, allowed predecessor, exact plan and sufficient costs |
| Save draft / retain signed reply | Active(g) -> Active(g) | Exact generation/policy/bytes and signer result; no principal posting |
| Queue/send retained bytes | Active(g) -> Active(g) | Durable queue sequence/coverage and fresh final authorization; send acknowledgment is not settlement |
| Observe successful payment | Active(g) -> Settled(tx) | Exact verified outcome, once-only balanced principal/cost event, appropriate releases |
| Repeat identical settlement | Settled(tx) -> same | Matching subject/evidence; no repeated accounting |
| Observe finalized Solana failure | Active(g) -> Ready with restriction | Book verified failed fees only, retain liability/attempt and forbid unsupported retry |
| Prove Solana nonexecution/expiry | Active(g) -> Ready with restriction | Retire only proved generation, release only permitted cost hold, preserve exact bytes |
| Approve permitted retry | Ready with restriction -> Ready eligible only if all checks pass | Immutable approval bound to expired attempt; preparation is a separate operation |
| Begin unsigned cancellation | Active(g) -> same, cleanup pending | Exact unsigned work/owned inputs; no premature release |
| Complete unsigned cancellation | Active(g) -> Ready, possibly restricted | Proven cleanup, retired generation, retained obligations; retry needs current source and generation allowance |
| Cancel earned-fee request | Ready -> Cancelled | Only permitted wholly unsigned history; release the original earned reservation once |
| Create refund | New independent Ready payment | Verified receipt ownership and refund funding; original conversion status is preserved |
| Source loss/return/cover/approval | Phase unchanged | Explicit deficit/return/coverage accounting and current-work-bound review restriction |
| Native draft/sign replacement | Active(g) -> same | Retained family, same economic recipient/amount, bounded added fee |
| Revalidate/reorg settled native payment | Settled(tx) -> same, possibly restricted | Updated evidence; never erase principal booking |
| Verify different native winner | Settled(old) -> Settled(new) | Same economic family, retained original settlement event, verified cost adjustment only |
| Rebroadcast approved native bytes | Phase unchanged | Exact retained bytes and explicit proof/coverage; no new signing authority |

Unlisted or impossible phase transitions refuse. Read-only status operations never
change phase. Administrative treasury/source accounting has its own explicit
balanced events and does not masquerade as a customer payment transition.

Use a closed `ReviewReason` vocabulary covering the actual cases: unresolved source
or winner, cancellation cleanup pending, missing/contradictory observation,
expiry awaiting approval, failed attempt without approved successor, generation
limit and retained incomplete legacy policy. A restriction is removed only when
the corresponding existing proof-based operation makes its predicate false.
No `clearReview`, set-status endpoint or generic override is added.

Where an old review flag is not reproducible from retained evidence, migration
must not silently discard it. The supported compatibility record is immutable and
bound to deployment, subject kind/ID, source schema/row digest, saved-work digest
and a closed reason. Normal commands cannot write these records. Only the migration
operation can import them; normal recovery may treat one as resolved only when its
existing typed proof contract establishes resolution of that exact saved work.
An unclassified/contradictory legacy state blocks activation pending investigation.
Do not create a permissive review-approval mechanism to finish migration.

### D11. Required scenario matrix

Retain these named scenarios in the existing tests/evidence map. Some combine
several properties; do not create one executable or giant fixture per row.

| Scenario | Assertions beyond a successful response |
| --- | --- |
| S01 Normal native -> wrapped and wrapped -> native | Exact receipt/payout, saved 1% terms, costs separate, journal/custody agree |
| S02 Partial/late/additional/ambiguous receipts | Liability retained, no unintended conversion, verified-owner refund, original payout link intact |
| S03 Idempotent request and repeated callback | Same identity/terms reused; changed input conflicts; no extra holds or postings |
| S04 Crash at every D06 boundary | Exact bytes retained, no blind new plan/send, deterministic restart decision |
| S05 Shared-capital races | Two different payments cannot reserve/spend the same available capital or budget |
| S06 Stale evidence during slow RPC/sign/backup | Refusal or bounded refresh; no extended validity window or queue bypass |
| S07 Solana expiry/failure/retry | Nonexecution distinct from unknown/failure; approved successor only; failed costs booked once |
| S08 Native replacement/reorg/winner change | Exact allowed family, principal once, verified cost changes, no false spend normalization |
| S09 Source loss/cover/return | No use of protected funds, explicit deficit, original split restored once |
| S10 Unsigned cancellation and earned withdrawal | Owned cleanup, foreign locks unchanged, exact permitted reservation release |
| S11 Signer/API/DB isolation | Auth/result/role separation; safe cannot write; signer cannot broadcast; worker cannot read keys |
| S12 Backup/restore/migration | Exact file/ledger identity, sequence/fence and unfinished work; no old-signer concurrency |
| S13 Offline token/nonce and pool operations | Exact intent/keys/limits, safe private files and replay/refusal behavior |
| S14 Configure/browser/install/restart | Private defaults/source refs, derived statuses, saved-order recovery, paused boot |
| S15 Malformed input and bounded workload | No overflow, unbounded allocation/replay, secret leakage or unsafe fallback |

Attach each scenario to existing/new pure, real-PostgreSQL, process or real-chain
evidence as appropriate. Missing real-chain evidence cannot be closed by running
its fixture version more times. Keep minimized seeds and actual command/source
identity so another agent or reviewer can reproduce failures.

## 3. Invariant vocabulary

| ID | Contract |
| --- | --- |
| I01 | Exact network/deployment/mint/wallet identity |
| I02 | Integer amounts and immutable saved terms/destinations; fees/rent separate |
| I03 | Balanced append-only financial events; no duplicate principal/cost posting |
| I04 | Receipt ownership/use, protected capital, allocations and holds |
| I05 | Once-only economic settlement across attempts/replacements |
| I06 | Durable exact bytes and authorization; no blind retry on uncertainty |
| I07 | Current subject/version/evidence/readiness at each critical boundary |
| I08 | Closed caller/severity/result identity, signer and OS/RPC privileges |
| I09 | Backup, monotonic sequence, lock/fence and old-signer exclusion |
| I10 | Bounded fees/rent/budgets/deadlines/generations and clock behavior |
| I11 | Atomic scan/cursor/evidence and actual custody reconciliation |
| I12 | Full cancellation/source loss/return/reorg/winner recovery semantics |
| I13 | Protected files, secret handling, exclusive durable publication |
| I14 | Customer, operator, token/pool, browser and setup compatibility |
| I15 | Bounded memory/requests/history/work and fail-closed error behavior |

## 4. Source map and progress

Paths are relative to `2-Wrap-Unwrap-Server` unless marked otherwise.

| Responsibility | Files |
| --- | --- |
| Pure amounts/funding/accounting/customer projection | `src/Bridge/Domain.hs`, `Lifecycle.hs` |
| Wire records | `src/Bridge/Wire.hs` |
| Existentials/GADTs/contexts | `src/Bridge/Operation/Internal.hs`, `Operation.hs` |
| Customer API | `api/Bridge/API.hs` |
| Ground instances/gated signing | `workflow/Bridge/Critical.hs` |
| Admission/order/preparation | `workflow/Bridge/Admission.hs`, `Order.hs`, `Payment.hs` |
| Opaleye and durable decisions | `runtime/Bridge/Store.hs`, `Store/Schema.hs`, `Store/Catalog.hs` |
| Observation/custody | `workflow/Bridge/Observer.hs`, `Reconciliation.hs` |
| Protocols | `chain/Bridge/Native*.hs`, `Solana*.hs`, `PaymentObservation.hs`, `PaymentSource.hs`, `RPC.hs` |
| Keys/transport/recovery | `workflow/Bridge/Credentials.hs`, `Signer.hs`, `Recovery.hs`, `runtime/Bridge/Fence.hs`, `Store/Backup.hs` |
| Startup/control/UI | `app/Main.hs`, `Configure.hs`, `workflow/Bridge/Control.hs`, `Config.hs`, `Web.hs`, `web/` |
| Token/pool administration | `../1-Make-Wrapped-ECX/`, `../3-Create-CPMM-Pool/`, shared `chain/Bridge/Admin*.hs` |
| Tests | `test/Main.hs`, `StoreCheck.hs`, existing `*Check.hs`, `test/formal/` |

The executor updates this table after verified checkpoints; not merely after edits.

| Checkpoint | Steps | State | Evidence commit / next action |
| --- | --- | --- | --- |
| A. Baseline and contracts | 1–12 | Complete | `4b8fa31`; baseline `3d4970b`, inventory and reproducible commands recorded |
| B. Concrete types and regression harness | 13–24 | Complete | `a18b04b`; pure facts/accounting model, bridge and baseline TLS pass |
| C. Complete payment slice | 25–36 | Complete | `a4aa94f`; pure decisions, 2,100 generated cases, real-PG settlement comparisons |
| D. Existing-schema integration | 37–46 | Complete | `62a9c77`; preparation/send/settlement, explicit isolation, fault/race/HTTPS/role checks |
| E. Customer funding/accounting | 47–56 | Complete | `01eb253`, `99b2657`; pure decisions and derived customer display, 4,500 generated cases, 27 real-PG history comparisons, rollback/restoration pass |
| F. Recovery/reconciliation | 57–70 | Complete | `fb38ddb`, `2f35af4`; 7,800 generated cases, native/source decisions, shared generation checks, real-PG/HTTPS/process/fence/encrypted-custody restoration pass |
| G. Schema 22 and migration | 71–84 | Complete | `249a4a4`; authoritative runtime, owner initialization and private legacy restoration; 16 roots/12 exact attempts/83 postings preserved, old/new customer/work-hash comparisons, interruption/rollback, actual PostgreSQL/Servant/HTTPS/fence and encrypted restore contracts pass; funded pilot unchanged |
| H. Protocol/file simplification | 85–94 | Complete | `abee44a`, `4f8c9e1`; shared bounded protocol/stream mechanics, fixed file policies and opened-descriptor checks; all three suites and actual PostgreSQL/HTTPS/fence/encrypted native/custody restore contracts pass. Net H: −52 application lines / +1 file |
| I. Administration/UI/setup | 95–104 | Complete | `5fce544`; retained shared administration mechanics and projected browser state, unified setup credential validation; complete build/suites, actual GHC-JavaScript UI, mutated bundle refusal, fresh setup and both-profile server processes pass; +2 application lines, no new files |
| J. Consolidated review/release candidate | 105–120 | 105–109, 111, 116–117 complete | `222b133`; invariant/mutation/type/formal checks and consolidated local acceptance. At `3ed3619`, canonical snapshots 60/76 migrated in isolated paused copies. Current audit guide and measured cost report complete; source-size target was not met. Linux candidate freezes implementation at `3174822`; J110, J112–115 and J118–120 remain |

The numbered steps below implement the design above. They are not permission to
reconsider every design choice while coding. Change the design only for a concrete
contradiction, measured failure or demonstrated simplification, documenting the
reason and affected invariants before dependent implementation.

## 5. Detailed implementation steps

### A. Baseline and contracts

1. **Confirm repository state.** Record branch, HEAD, remote HEAD and working
   changes. Preserve user edits. Use an existing suitable refactor branch, or
   create a named branch from the reviewed baseline. Do not duplicate the checkout
   or create a second application. Exit: known starting state and no accidental
   changes to the funded runtime.

2. **Read the authority path.** Read the full reference, current architecture,
   Domain, API, Operation/Internal and relevant Critical instances. Trace one
   customer order and one signer request separately. Identify concrete resources
   available at each evaluator and where serialization occurs.

3. **Inventory customer/worker/signer behavior.** Enumerate the four public routes,
   closed worker leaves and four signer leaves from source. Record payload/result
   contracts, rejection conditions and callers. Include safe reads, paused behavior
   and the critical dispatch site, not just successful transfers.

4. **Inventory operator/token/pool behavior.** Enumerate all CLI/control leaves,
   recovery, treasury, fees, setup, offline mint/nonce and liquidity commands.
   Map each to an implementation/test. Undocumented does not mean unused. Historical
   ideas not implemented today do not become new scope.

5. **Record compatibility contracts.** List exact HTTP JSON, capabilities,
   configuration, command syntax/defaults, saved transaction/snapshot formats,
   schemas and public statuses. Record error category/retryability and whether a
   failure pauses intake. Keep this in the existing architecture/review files.

6. **Capture consistent counts.** Count application/schema including replacement
   helpers and migration code, tests separately including embedded Rust tests,
   and tooling/docs/notices separately. Count files and dependencies too. Retain
   the baseline 14,843 application/schema figure with its counting definition.

7. **Prepare bounded tooling.** Confirm installed native GHC 9.14.1 and Cabal
   3.16.1.0, the separate existing GHC-JS toolchain, caches and free space. Use one
   build job. Do not update dependency locks, install toolchains or start VMs when
   the existing setup suffices.

8. **Verify the baseline once.** Run bridge/token/pool suites and the relevant
   disposable PostgreSQL contracts. Preserve exact command/output/source records.
   Investigate pre-existing failures separately from proposed changes. Reuse
   unchanged funded evidence without claiming a new funded test.

9. **Prepare representative histories.** Reuse sanitized fixtures for unpaid,
   paid, prepared, signed, queued, uncertain, failed, cancelled, expired, replacement
   and recovery-pending work. Keep deterministic fixture keys out of real networks.
   Never copy production credentials/capabilities into committed test data.

10. **Map I01–I15 to enforcement.** For each invariant identify pure rule, database
    constraint, process boundary and evidence/test. The map must include known
    gaps, not just green checks. Bound this inventory to actual product operations.

11. **Mark durable interruption points.** Use D06 to identify before/after allocation,
    preparation, backup acknowledgment, signing reply, byte persistence, queue,
    broadcast and settlement. State exactly what survives and what the next run
    may do. Include host fence advancement before an uncertain commit.

12. **Close A.** Commit the baseline/contract map and reproducible commands.
    No runtime changes yet. Gate: complete operation inventory, understood baseline,
    protected custody and no unclassified compatibility surface.

### B. Concrete types and regression harness

13. **Write the fact-owner table for current fields.** Map each existing status,
    flag, reference and evidence field to D02/D03. Identify redundant economic
    state separately from necessary attempt/reservation/source state. Explicitly
    include `orders.status`, `payout_tx`, `obligations.status`, `intents.resolved`.

14. **Specify the domain records.** Define names/fields for PaymentFacts,
    PreparationFacts, AttemptFacts, FundingContext and operation-specific evidence
    using existing Amount/Funding/Payment/Policy types. Keep lists bounded and
    avoid another set of DTOs that duplicates every wire record.

15. **Specify state validity.** Enumerate allowed combinations of economic phase,
    generation, winner and review restriction. Ready has no active generation;
    Active has exactly one belonging preparation; Settled has a belonging winner
    and original settlement event. Review may coexist with a settled payment.

16. **Specify all transition inputs/results.** For each leaf list actor, state,
    evidence, terms, holdings, permitted postings and idempotency/refusal. Use
    narrow result types, not a general list of arbitrary database mutations.
    Check coverage against the inventory from A.

17. **Specify stable comparison identity.** Bind ID, generation, immutable terms,
    subject state, relevant source/approval and readiness dependencies. Preserve
    actual observation anchors. Do not equate a digest alone with authorization
    or compare unrelated changing global data that causes spurious refusal.

18. **Specify error mapping.** Define internal refusal categories and their existing
    HTTP/CLI codes. Pin distinctions between conflicts, unavailable evidence,
    stale observations, corruption and uncertain external outcome. Do not use a
    successful default for unknown enum/legacy values.

19. **Create the pure module skeleton.** Add Lifecycle to the core Cabal component
    and relevant test components only. It must not import Store, network, filesystem,
    clock or signing resources. Keep existing public API/CLI/JSON unchanged and
    avoid dragging runtime types into the browser build.

20. **Create state generators.** Add generators/shrinkers in the existing tests
    for valid bounded snapshots and action sequences. Generate invalid states
    deliberately in separate properties. Minimized failures must remain meaningful
    traces, not simply malformed inputs rejected at parsing.

21. **Create a small independent reference model.** Model balances, protected
    holds, immutable terms and principal-paid identities. It must not call the
    production transition/accounting function to obtain expected results. Prefer
    a small model over copying the entire application into tests.

22. **Set up old/new comparison.** Use isolated old/new state or the same sanitized
    evidence. Compare decisions, postings, holds, identities and refusal semantics.
    Do not compare two live paying engines. Document permitted normalization of
    nondeterminism; financial values/bytes/order of effects are never normalized away.

23. **Write boundary regressions before extraction.** Pin duplicate settlement,
    extra-refund payout-link behavior, stale generation, missing backup, changed
    decision during signing and native readiness refresh. These are known important
    cases, not an invitation to add speculative features.

24. **Close B.** Typecheck the skeleton/model and verify that representative wrong
    expected balances/transitions fail the tests. Gate: concrete types/results,
    all operations covered, no new authority, reproducible comparison harness.
    No schema or signer-protocol changes yet.

### C. Complete pure payment slice

25. **Choose the fixed slice.** An already funded payment from preparation through
    settlement, for both chains and conversion/refund/earned-fee funding. Keep
    existing protocol encoders, evidence parsers and schema 21. This bounds the
    experiment without excluding failure/retry behavior.

26. **Extract settlement first.** Move the decision from `settlePayment`,
    `failSolana`, `settlementContext` and `resolvePayment` into pure checks/results.
    Keep persistence and protocol inspection in their current places. Record
    each removed condition and its new owner so no validation silently disappears.

27. **Separate financial effects.** Specify principal movement, earned fee,
    network/rent costs, hold release and display result separately. Repeated exact
    settlement is idempotent; contradictory evidence conflicts. Verified failed
    Solana execution may charge fees without paying principal.

28. **Extract preparation.** Preserve explicit funding, budget, source authorization,
    same-plan reuse, generation limit and immutable terms. An existing differing
    plan conflicts. A new generation requires an existing approved recovery basis,
    never merely an expired deadline or RPC timeout.

29. **Extract broadcast authorization.** Preserve signed-byte identity, saved queue
    sequence, backup coverage, source/custody/readiness and policy bounds. Keep
    chain-specific final validity checks outside the pure decision immediately
    before send, with no premature authority from a successful preview.

30. **Check property invariants.** Run generated legal traces covering I02–I07 and
    I10. Verify balanced events, protected funds, unchanged recipient/amount,
    retained attempts and one principal settlement. Exercise low/high/overflow
    amounts and time boundaries, not only nominal values.

31. **Check refusal behavior.** Wrong profile, payment, generation, destination,
    amount, evidence, budget or coverage must refuse with no financial effects.
    Test stale observations and missing or duplicate records. Keep corruption
    distinguishable from ordinary waiting.

32. **Check redelivery and ordering.** Re-deliver identical events and deliver old
    callbacks after newer preparation. Simulate observation before send acknowledgment
    and restart between each durable boundary. Assert no blind resignation,
    duplicated principal or mutation of a different generation.

33. **Compare against baseline.** Run the bounded slice over identical histories.
    Investigate every difference. Preserve correct behavior; a genuine old bug
    needs a separate invariant-based regression and clearly recorded fix, not
    permission to change arbitrary semantics during refactoring.

34. **Review comprehensibility.** Follow each decision without reading IO helpers.
    Inputs, checks and effects must be visible. Reject a generic framework that
    requires reconstructing behavior across dictionaries/configuration to understand
    a simple payment. Keep explicit chain distinctions.

35. **Measure total replacement cost.** Include Lifecycle types, adapters, helpers
    and compatibility, not just the lines removed from Store. Record duplicated
    facts removed and remaining. Generated or moved source still counts toward
    the audit surface.

36. **Close C: expansion gate.** Proceed only when the full slice preserves behavior,
    demonstrates stronger/easier invariant reasoning and passes its property and
    comparison checks. If not, revise or abandon that abstraction and keep useful
    local improvements. Do not promise the 7k target from a partial happy path.

### D. Integrate over the existing schema

37. **Replace settlement decision ownership in Store.** The existing closed
    operation loads current typed state, calls the pure decision and applies
    schema-21 writes atomically. Remove its old duplicate decision implementation.
    Keep the public Store constructor and external results compatible.

38. **Integrate preparation and send authorization.** Use the same pattern.
    Preserve affected-row checks, locking, fence, sequence advancement and original
    plan/draft/attempt serialization. No new arbitrary decision/patch entry point.

39. **Make transaction assumptions explicit.** Confirm runtime READ COMMITTED,
    deployment lock before reads, single writer claim and READ ONLY snapshots.
    Preserve rollback/fenced-connection behavior. Do not add automatic retries
    around an uncertain commit or local fence advancement.

40. **Test real database failure atomicity.** Inject constraint/commit-path failures
    in disposable PostgreSQL; inspect through closed Opaleye checks that no partial
    postings or holds remain. Include an unexpected error that fences the writer
    and a policy refusal whose successful rollback permits continued use.

41. **Test shared-resource races.** Two requests for one order; two different
    payments competing for the same float/budget; recovery competing with normal
    settlement. Use barriers and bounded waits on real connections. The test must
    establish database protection, not merely pass because one application MVar ran them serially.

42. **Keep critical entry unchanged.** Wire through existing Operation methods.
    Review exact critical dispatch call sites and signer client construction,
    module exports and Cabal dependencies. A handler cannot import runtime signing
    authority through a newly exposed convenience module.

43. **Test signer revalidation.** Wrong identity/generation, changed decision while
    signing, unauthenticated request, wrong result constructor and malformed bytes
    must fail. Preserve local gate coverage across read/sign/recheck and worker
    validation of returned signed effects.

44. **Test process privileges and assembled flow.** Use actual Servant HTTPS,
    disposable ledger and current fixtures. Verify safe-role writes denied,
    worker custody/unlock reads denied, signer database writes/broadcast denied,
    paused startup and restart after saved preparation/queue.

45. **Remove temporary runtime comparison plumbing.** Keep small regression inputs
    and the independent model. Retain old implementation in Git history, not an
    environment flag. Migration-only comparison code may remain isolated and
    non-paying until G finishes.

46. **Close D.** The ordinary executable uses the new pure decisions over schema
    21; relevant bridge/store/transport checks pass. Commit/push the complete slice
    and record counts. Keep the funded deployment untouched.

### E. Customer funding and accounting

47. **Extract quote/admission decisions.** Preserve exact ceiling fee arithmetic,
    saved historical terms, minimum net, amount/fee/rent bounds, deadline/grace
    and rolling budget semantics. Network admission facts are explicit evidence,
    not IO inside the pure function.

48. **Extract instruction allocation decisions.** Native allocation saves a claim
    before external allocation and recovers the same label/address after a lost
    reply. Preserve ambiguous-allocation refusal. Solana reference remains unique
    and immutable. Neither path exposes instructions before required coverage.

49. **Centralize reservation arithmetic.** Keep principal, conversion/refund
    operating costs and payment fee holds explicit and distinct. Reuse formulas
    without confusing reservation transfer with release. Available wallet balance
    is not available float. Funded/signed work cannot expire like an unpaid quote.

50. **Extract deposit promotion.** Pin exact amount/asset/instruction, deadlines,
    actual source-owner evidence, chain eligibility and existing conversion.
    Partial, additional, late or ambiguous receipts retain liabilities and review/
    refund behavior. Wrong amount is not permission to discard money.

51. **Extract refund authorization.** Retain verified ownership/destination and
    explicit refund funding. Additional refunds cannot erase successful conversion
    links or spend the original receipt again. Use the common payment lifecycle,
    without inventing synthetic deposits/orders.

52. **Extract earned-fee withdrawal/cancellation.** Preserve earned versus protected
    balances, pending-fee reservation, paused operator authority and exact terms.
    Cancellation releases only its original reservation after verified unsigned
    cleanup. Repeated ID with differing input conflicts.

53. **Extract treasury decisions.** Keep finalized eligible unbound receipt,
    ownership attestation, custody match and exact allocation split. Protect
    backing/LP/principal/operating accounts. Unexplained outflows cannot become
    earned income or silently consume customer reserves.

54. **Implement the new customer projection on old facts.** Compare derived status
    and payout identity with schema-21 behavior while its compatibility columns
    still exist. Preserve applicable recovery overlays and paid conversion precedence.
    Presentation must not independently decide financial authority.

55. **Run mixed financial histories.** Generate conversions, multiple receipts,
    refunds, withdrawal, lost sources, time changes and repeated requests. Assert
    event balance, protected funds, unique funding and saved terms. Include actual
    PostgreSQL cases for affected holds and atomic updates.

56. **Close E.** Customer funding/accounting decisions have one pure owner; schema
    21 still works. Delete replaced helpers, update trace map and push. No schema
    change or protocol rewrite is needed to claim this working improvement.

### F. Recovery and reconciliation

57. **Separate observation from permission.** Preserve atomic cursor/evidence/
    receipt commits, immutable history origins and successful-scan timestamps.
    Unavailable RPC cannot advance coverage or authorize a payout. Observe-only
    mode remains incapable of paying.

58. **Centralize readiness dependencies.** Preserve policy, pause, scans, custody
    revision, budget and backup checks. Refresh after slow IO and recheck chain
    validity last. Retain the current freshness window and bounded refresh rules;
    do not increase them to hide a failing test or slow provider.

59. **Extract cancellation transitions.** Save cleanup intent before external
    cleanup; bind exact generation and inputs. Refuse signed work where required,
    retain unknown cleanup as pending, keep foreign locks and never use an empty
    native unlock list to unlock everything.

60. **Extract Solana expiry/retry.** Retain finalized height past validity, invalid
    hash, absent status/transaction and complete anchored histories from required
    providers. Timeout/expired-unseen is not proof. Separate immutable retry
    approval and renewed budget reservation from observation.

61. **Extract native replacement.** Preserve family inputs, sequence/version/
    locktime, recipient/amount, change address and fee ceiling. Only allowed change
    reduction funds replacement fees. Keep all family bytes and refuse conflicting
    drafts, foreign spenders and ambiguous winners.

62. **Extract settlement revalidation/winner change.** A native payment can be
    confirming, unavailable or reconfirmed after original settlement. A newly
    verified winner changes only proved costs/winner history. Never re-post
    principal or erase the original settlement event.

63. **Extract source loss/return/coverage.** Unavailable is not missing. Keep
    deficits, obligations and holds; account for a verified return once. Coverage
    consumes only truly free native float/earned capital. Restore the original
    split once on return, with explicit current-work-bound approvals.

64. **Extract same-bytes rebroadcast.** Preserve paused review, exact saved family,
    current source proof and required coverage. Reuse retained bytes; this action
    cannot grant replacement or arbitrary resign authority.

65. **Share common attempt mechanics.** Only now consolidate generation, predecessor,
    approval, version and cost handling across the explicit cases. Keep their
    evidence constructors/checks distinct. A universal recovery flag or generic
    operator bypass is not an acceptable replacement.

66. **Preserve native accounting corrections.** Retain family overlap checks,
    excluded shared-input treatment, stable wallet/chain anchors, pending-credit
    restrictions, lock ownership and uncertainty handling. These are known real
    protocol conditions, not incidental duplication.

67. **Exercise late/out-of-order events.** Old generation callbacks after retry,
    repeated source returns/covers, observations before acknowledgment, changed
    winner and conflicting providers. Assert stale events cannot authorize new
    work or move principal again.

68. **Exercise bounded failures.** Truncated history, provider rate limits/timeouts,
    wrong chain and moving snapshots retain previous durable coverage and refuse
    appropriately. Deterministic protocol fixtures are valid tests but must not
    be called real L2L alternate-history acceptance.

69. **Batch recovery integration.** Use actual PostgreSQL, saved-byte restart,
    process interruption and local encrypted restic/native-wallet restoration
    for changed paths. Confirm paused restoration and no automatic send. Avoid
    installer rebuilds or new funded tests at this stage.

70. **Close F.** Every inventoried recovery leaf has explicit transition/evidence/
    authority/test coverage. The full financial decision model runs on schema 21.
    Audit clarity and net cost now; reject abstractions that made recovery harder
    before changing storage.

### G. Schema 22 and verified migration

71. **Confirm the schema-22 delta against measured code.** Implement D03, not a
    wholesale schema replacement. List old columns/indexes/triggers/views depending
    on `resolved`, obligation status and order payout/status. Retain other facts.
    If the baseline advanced, reconcile that concrete difference before DDL.

72. **Add typed payment-root projection.** Extend Schema's current intent record
    with economic phase, active generation, settled transaction and original
    settlement event. Parse phase into a closed type; reject invalid combinations.
    Preserve original funding IDs/terms rather than duplicating their contents.

73. **Implement constraints and queues.** Exactly one funding source; active
    generation belongs to this payment; settled winner/event are bound; one active
    destination-chain payment; principal event identity unique/immutable. Update
    work queries for ready roots without treating every ready row as active.

74. **Implement authoritative projections.** Read execution from payment roots,
    attempt detail from attempts and review from explicit evidence. Replace order
    status/payout writes with D03's projection; keep admission state separate.
    Test bounded indexed reads and no full-ledger replay per customer request.

75. **Map every old database guarantee.** Check FK, CHECK, unique/partial index,
    trigger and role privileges, plus empty-ledger initialization, backup/restore
    schema acceptance and table inventories. Replace dependencies before removing old columns.
    Share identical trigger bodies only where contracts match. Do not defer all
    enforcement to Haskell or use a lax generic JSON row.

76. **Write the migration mapping table.** Apply D03/D08/D10 to every source relation/field,
    target and identity/evidence used to infer state. Include ready work without
    old intents, failed/expired generations, cancellations, historical settlements,
    winner changes and unfinished legacy work. No unknown state maps to success.

77. **Implement explicit Opaleye data migration.** New DDL creates staging
    structure; a closed migration operation converts and verifies rows. Keep
    migrations 001–008 unchanged. Use the same migration lock and paused startup
    refusal. A staged schema is not accepted by serve/signer.

78. **Implement atomic activation/resumption.** Quiesce old worker/signer and keep
    an encrypted snapshot. Use one bounded transaction where feasible; otherwise
    private staging with atomic progress and idempotent resume. Activate version
    22 and final constraints together only after all checks pass. No side effects
    or active writer during conversion.

79. **Compare populated financial state.** Through closed Opaleye test operations,
    compare per-asset/account balances, obligations, protected allocations, all
    reservations, budgets, policies, capabilities, deadlines, payment roots,
    generations, original bytes, approvals, evidence, cursors and coverage/fence
    boundaries. Matching a grand total alone is insufficient.

80. **Exercise failed/interrupted migration.** Wrong identity, older sequence,
    malformed terms, ambiguous settlement, conflicting winner and partial progress
    must refuse. Restart before/after activation. Never lower the fence to resume
    an old database. An unprovable legacy mapping is an explicit blocked migration.

81. **Compare behavior after conversion.** On isolated non-paying copies, compare
    customer projections, payment decisions and recovery eligibility with baseline
    facts. Include ready fee withdrawals and extra refunds. Read-only copies have
    no signer/send credentials; never run a shadow broadcaster.

82. **Switch only disposable deployment.** Run the ordinary executable on schema
    22 with actual PostgreSQL and Servant. Verify active-chain exclusion, readiness,
    signer reads, restart and recovery. Confirm read roles retained SELECT only
    and no new role/schema/function privilege can mutate money.

83. **Delete obsolete runtime storage logic.** Remove duplicate economic flags,
    status updates, adapters and runtime fallback paths. Keep old-schema reading
    solely in the closed migration/inspection path where required. Count that
    compatibility honestly; do not put it elsewhere to hide LOC.

84. **Close G.** Gate: populated migration preserves meaning and exact bytes,
    failures recover safely, new-schema normal operation passes and signer
    isolation holds. Record schema/source/comparison evidence and push. The funded
    pilot is still unchanged; do not make its upgrade part of this debugging loop.

### H. Protocol and protected-file simplification

85. **Inventory remaining adapter duplication.** Group transport setup, parse,
    validation and effect code by identical contract. Share mechanics already
    proven equivalent; native UTXO and Solana account/finality rules remain explicit.
    Do not add a universal chain abstraction to save imports.

86. **Consolidate bounded parsers.** Reuse amount/integer/key/encoding/structure
    parsing without broadening accepted fields or formats. QuickCheck oversized,
    malformed and boundary inputs. Keep units explicit and reject overflow before
    narrowing or allocating memory.

87. **Reduce internal representation conversions.** Carry shared typed records;
    encode/decode at persistence/transport boundaries. Preserve current external
    formats or use explicit versions. Decoding in the signer remains independent
    of decoding in the worker; types do not certify another process's input.

88. **Preserve independent bytes/effects validation.** Keep Haskell checks of
    native prevouts/templates and Solana keys/instructions/signatures. SDK-produced
    bytes must satisfy the narrow expected operation. Do not remove one validator
    because the encoder currently returns the desired bytes.

89. **Consolidate RPC setup/retries.** Preserve identity checks, host pacing,
    independent providers, bounded bodies/timeouts and exact read-retry allowlist.
    No automatic wallet-mutation/send retries. Cache only explicitly stable facts;
    do not cache mutable authorization or balance as permanent truth.

90. **Map protected-file policies.** Compare AdminKey, Credentials, Recovery,
    Backup, Fence and configure: owner, mode, max size, symlink/hardlink rules,
    create/replace, durability, process locks. Document differences before sharing
    code. Root-owned service inputs and user-owned outputs are not interchangeable.

91. **Extract narrow file primitives.** Share hashing, bounded descriptor reads
    and publication where policies agree. Preserve opened-descriptor checks,
    no-follow, exclusive writes, parent sync, lock lifetime and cleanup under
    exceptions. No generic exported read-any-file helper with caller-chosen policy.

92. **Consolidate backup format mechanics.** Preserve complete exact-file-set,
    hash, identity, schema/sequence, wallet/encryption and unlock verification.
    Verify restored full bundle after upload as before; manifest-only readback
    does not establish a recoverable custody snapshot.

93. **Run protocol/filesystem failure checks.** Wrong owner, symlink, oversized
    input, publication collision, process death, changed manifest and stale fence
    must fail correctly. Exercise actual encrypted restic/native-wallet contracts
    on disposable state; do not replace them with a success-returning stub.

94. **Close H.** Remove replaced copies and rerun affected chain/admin/recovery
    tests. Count every shared helper; check module/OS authority again. No new
    credentials, larger signing vocabulary or mandatory external service.

### I. Administration, browser and setup

95. **Unify remaining administration bookkeeping.** Extend existing AdminKey/
    AdminStatus reuse for genuinely matching file/status/submission mechanics.
    Keep token/pool closed operation types and distinct validators; no arbitrary
    instruction builder or custody-key sharing.

96. **Preserve token commands.** Exercise configure, key generation/import/entry,
    preparation, check/sign/submit/status/recover, mint/burn, mint/account creation,
    metadata, policy inspection and address operations from the inventory. Keep
    existing syntax, private defaults, fee default and invalid-input re-prompting.

97. **Preserve offline/nonce signing.** Test online preparation, offline intent
    validation/signing with no RPC, USB-transferable record and online submission.
    Changed key/amount/recipient/message/nonce refuses. Consumed nonce must not
    become permission to resign. Hidden terminal input restores echo and never
    leaks the key or overwrites existing output.

98. **Preserve liquidity commands.** Pool/position creation, deposit/withdrawal,
    fee collection, explicit bounded reinvestment, status/quote and recovery
    remain available. Preserve fees/cost/slippage and exact instruction checks;
    keep unattended compounding/LP locking outside this refactor.

99. **Simplify browser state from the projection.** Preserve no-wallet-connect
    flow, QR/payment links, fee preview, copy/open-wallet actions, saved capabilities,
    reload, expiry/refund/errors, explorers/trading/support. Do not move financial
    authorization into browser Haskell or let UI status choose a payout.

100. **Verify browser trust and build.** Use GHC JavaScript, existing assets and
     Cabal hooks. Validate cached manifests against changed inputs. Test missing
     localStorage, failed requests, reload and capability recovery; keep secrets
     out of logs/URLs. No new JS framework or WebAssembly backend.

101. **Consolidate configuration validation.** Reuse rules between prompts/loading
     without dropping startup identity/permission checks. Preserve configure ->
     fields -> start, optional DB setup, private JSON and source-file references.
     Startup never makes an empty ledger stand in for existing custody.

102. **Verify API/CLI/security compatibility.** Same public routes and authorization,
     response fields and failure categories; documented commands/defaults still
     work. Exercise actual public WarpTLS, signer HTTPS, bounded body/admission
     controls and local closed operator path.

103. **Remove unused code based on evidence.** Check Cabal exposure, imports,
     callers, fixture/data-file declarations, dynamic loading and external command
     contracts before deleting. Keep required notices, pins and migration support.
     Remove temporary comparison runtimes/prototypes from production dependencies.

104. **Close I.** Full application works through the sole new implementation;
     command/docs/audit map match it. Build and run complete local suites before
     packaging. Count current application/schema/migration support and explain
     material remaining complexity rather than chasing a quota.

### J. Consolidated review and release candidate

105. **Audit invariants independently of tests.** Read each transition's inputs,
     refusal and writes, then inspect tests. Trace I01–I15 through process/database/
     chain boundaries. Look for correlated errors where implementation and oracle
     share the same faulty calculation or permissive parser.

106. **Use deliberate negative mutations.** In disposable changes, weaken
     representative amount, identity, generation, backup, privilege and once-only
     checks. Verify the suite detects them. Restore source after each mutation;
     no production flag can enable the weakened behavior.

107. **Review authority and formal model.** Verify unique signer outputs/routes,
     operation context and sole dispatch site; inspect exports/dependencies.
     Update relevant finite TLA+ model changes and rerun positive/negative cases
     with bounded memory. State its finite abstraction/refinement limits honestly.

108. **Run consolidated local acceptance.** All three Cabal suites and actual
     PostgreSQL contracts at one source, including migrated histories, concurrency,
     process interruption, encrypted restoration and HTTP/TLS. Inspect all results;
     a subprocess failure must not disappear in an aggregate success report.

109. **Run bounded workload checks.** Exercise representative increasing order/
     history sizes and repeated recovery. Check RAM, query count, history limits
     and RPC demand; no full-journal replay per request. Preserve deterministic
     bounds and fail explicitly rather than weakening evidence checks under load.

110. **Batch real Signet/Devnet acceptance.** Test both directions, changed refund/
     retry/restart paths and actual finalized effects using real configured networks.
     Test the actual customer-wallet flow when approval is available. Fixture and
     tester-client evidence must remain labelled accurately.

111. **Prepare canonical acceptance safely.** Validate canonical config, independent
     RPC, backup and migrated copies without activating custody. A new funded
     pilot cutover needs a final coherent snapshot, paused old worker, exclusion
     of old signing access and applicable explicit authorization/spend bounds.
     Never infer an unlimited new transfer budget from historical tests.

112. **Complete externally enabled recovery checks.** Actual L2L conflict/reorg
     histories and physically independent funded restore need the stated resources.
     Preserve minimum sequence, reconcile and resume explicitly. Missing external
     inputs block those checks, not independent steps 113–117; record and batch
     the requests rather than pausing all work or fabricating acceptance.

113. **Freeze source for packaging.** After local substantive acceptance, record
     exact commit, schema, toolchain/locks, browser inputs and open issues. Build
     Linux ARM64 and x86-64 sequentially once. Reuse caches; token and pool remain
     root-Cabal buildable. Do not package every preceding small checkpoint.

114. **Batch final installation checks.** Fresh configure/start with no database,
     upgrade/repeat install, private state preservation, restart without source
     keys, cold boot, HTTPS/port 443 and signer isolation on both architectures.
     Explicitly document required OS runtime libraries; do not claim none exist.

115. **Verify release contents.** Check signatures, source/payload/browser manifests,
     migration files, notices and dependency hashes against frozen source. An
     acceptance signing key is not public release trust. Rebuild only when an
     artifact input changed, not after evidence-only documentation edits.

116. **Finish the concise audit guide.** Keep one source/authority diagram,
     authoritative-fact table, transition map and invariant/test index. A reviewer
     must trace request -> authorization -> decision -> commit -> exact effect ->
     observation -> accounting without reading chat history. Remove stale prose.

117. **Report measured results.** Like-for-like lines/files/dependencies, removed
     duplicated facts, passing checks and remaining risks. Include migration and
     helper cost. Explain concrete improvements and tradeoffs; never assert a
     smaller piece is better in every way or that tests prove perfect security.

118. **Obtain independent security/distribution review.** Supply frozen source,
     assumptions, dependency findings, migration/recovery evidence and known limits.
     AI self-review cannot close this gate. Fix demonstrated findings in scoped
     patches with relevant revalidation rather than restarting the architecture.

119. **Finalize external operation/activation.** Batch wallet approval, independent
     backup/clean host, L2L alternate history, RPC capacity, host/domain/TLS renewal,
     support/alerts, issuer/reserve policy and operator-owned release signing.
     Public release and valuable-fund activation require actual operator approval.

120. **Close honestly and clean up.** Commit/push code/evidence, verify remote HEAD
     and working tree. Stop task-owned unused VMs/processes while preserving shared
     services/custody. Mark local refactor implementation complete only when its
     required checks pass; list external release gates separately and do not call
     public production approved while they remain open.

## 6. Commands, checkpoint gates and recovery of development work

Run from the repository root with the already installed pinned native toolchain.
Use existing caches and the separate GHC JavaScript 9.12.2 setup. Do not change the
native freeze to work around the wrong selected GHC.

```sh
# A shell with the pinned tools; installation is a separate prerequisite if missing.
ghcup run --ghc 9.14.1 --cabal 3.16.1.0 -- bash
ghc --numeric-version
cabal --numeric-version

# Smallest relevant native core build, then bridge properties/contracts.
cabal build ecx-bridge:lib:ecx-bridge -j1 --offline
cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct

# Shared administration or protocol changes.
cabal test ecx-token:token-test ecx-pool:pool-test -j1 --offline --test-show-details=direct

# Assembled checkpoints, not every helper edit.
cabal build all -j1 --offline
cabal test all -j1 --offline --test-show-details=direct
```

`--offline` assumes dependencies are cached. Inspect existing Cabal target names
if disambiguation is needed; do not alter dependency pins to fix target selection.
[LOCAL-DEVELOPMENT.md](LOCAL-DEVELOPMENT.md) contains prerequisites, SDK/browser
cache handling, fixture paths and the mode table for actual PostgreSQL contracts.

`ecx-store-check` mutates its database and some modes use fault DDL. Before each
mode, inspect `test/StoreCheck.hs` and its documented environment. In particular,
`ECX_REBUILD_CONTRACT_DATABASE` must name an explicitly disposable migrated
`ecx_rebuild_contract_*` database, and `ECX_REBUILD_CONTRACT_READER` its restricted
reader. Set the documented host/port. Run via root Cabal for packaged fixtures.
Never point it at funded custody or copy production credentials into a command.
All application/test data access remains in closed Opaleye operations.

Run the bounded TLA+ check only with the retained reviewed tools and applicable
model changes, one worker and bounded JVM heap, as documented in LOCAL-DEVELOPMENT.
Do not install another formal stack or describe TLC exploration as an unbounded
proof. Compile/type checks complement this model; they do not establish OS safety.

### Per-checkpoint completion card

Use one short entry in RELEASE-REVIEW, with links to private evidence when needed:

- Checkpoint/steps and exact tested implementation commit.
- Changed responsibility and preserved public behavior.
- Invariant IDs and concrete new/retained checks.
- Exact commands, success/failure, seed/minimized trace where applicable.
- All replacement files/lines versus old responsibility, including helper/migration cost.
- Remaining external limits and next checkpoint.

Do not claim success if only a source edit, compilation or mock test passed. Pure
logic needs invariant/property checks; writes need real transaction checks; process
boundaries need actual transport/privilege checks; chain acceptance needs real chains.
Use compile-time negative examples for authority where practical, but do not retain
intentionally broken source in normal Cabal builds.

### Efficient dependency order

A -> B -> C -> D -> E -> F -> G -> H -> I -> J is deliberate:

- Freeze protocols/schema while extracting decisions: easier to locate regressions.
- Integrate a complete working payment before expanding the abstraction.
- Cover recovery before storage redesign: the schema must represent actual hard cases.
- Change the schema once, after the business semantics have an independent model.
- Consolidate protocol/file/admin helpers after the financial model is stable.
- Batch real network, browser, Linux, package and installation work near the end.

Pure changes run targeted pure checks. Changed persistence runs PostgreSQL checks.
Changed authority runs transport/role tests. Shared changes broaden the relevant
suite. Full builds and package rebuilds are checkpoint work, not repeated reactions
to every small edit. If expensive work is running, inspect independent documentation
or source without changing its inputs. Do not leave several compilers/VMs running.

### Mandatory stop conditions

Stop dependent work on unexplained accounting/obligation differences, changed
saved terms/bytes, duplicated settlement, lost refund/recovery cases, stale-evidence
acceptance, new generic authority, relaxed role/file rules, migration ambiguity
or unbounded memory/history. Reduce the failing trace and diagnose it. Do not
weaken tests, widen fees/freshness limits or add an operator override to obtain green.

If an abstraction increases the number of places a reviewer must inspect, revise
or reject it. A helper needs a real shared contract and callers. Avoid a framework
for hypothetical future behavior. Line-count manipulation, code golf, import
aggregation or moving code outside the counted tree does not satisfy this plan.

Document external blockers and continue independent work where dependencies allow.
Do not repeatedly probe exhausted providers or rebuild identical source while
waiting. Batch required human actions. Human signing and independent security review
cannot be replaced with an agent's assertion that the implementation looks correct.

### Security assumptions and primary guidance

This is a custodial hot-wallet service, not a trustless or perfectly secure bridge.
The operator, host/root administration, release trust, native node and configured
RPC/backup assumptions remain material. Limits, isolation and revalidation reduce
risk; they do not make stolen keys or privileged host compromise harmless.

The explicit transaction/locking contract follows the distinctions documented in
[PostgreSQL 16 transaction isolation](https://www.postgresql.org/docs/16/transaction-iso.html)
and [explicit locking](https://www.postgresql.org/docs/16/explicit-locking.html).
A transaction alone is not a substitute for a defined concurrency protocol.
Changing isolation later requires revisiting retries, locks and external effects.

Binding authorization to exact transaction details and checking it at execution
is consistent with [OWASP Transaction Authorization guidance](https://cheatsheetseries.owasp.org/cheatsheets/Transaction_Authorization_Cheat_Sheet.html).
The bridge's actual mechanisms remain the specified DSL, durable decision,
independent signer validation and chain-effect verification; citing a checklist
is not proof they work.

Threat assumptions, reviewable changes, automated verification, release integrity
and vulnerability handling follow the development direction of
[NIST SP 800-218 SSDF](https://csrc.nist.gov/pubs/sp/800/218/final).
These are supporting sources, not certification or a claim of complete standards
compliance. Preserve current dependency findings and require independent review
before closing the public release gate.

### Final definition of done

The implementation is complete when the inventoried product behavior remains,
all financial facts have clear owners, each fund movement has a traceable
permission/accounting/recovery path, relevant checks pass, migration is verified
and obsolete implementation is removed. Publish measured improvements and limits.
A clear, verified 10,000-line system is preferable to an opaque 7,000-line one.

Public release is a separate decision: actual customer-wallet approval,
physically independent recovery, real L2L exceptional histories, production
arrangements, independent security/distribution review and operator-controlled
release signing/activation remain required as recorded in RELEASE-REVIEW.
