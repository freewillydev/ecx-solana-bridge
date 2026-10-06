# Release review

The bridge has completed funded development tests and a canonical betanet/Solana
Mainnet round trip. It is ready for source review, **not public-release approval**.
The [previous nine-step internal completion plan](https://github.com/freewillydev/ecx-solana-bridge/blob/6fa7334/2-Wrap-Unwrap-Server/docs/IMPLEMENTATION-PLAN.md) is complete.
The [auditable-core refactor plan](IMPLEMENTATION-PLAN.md) is in progress;
its implementation and acceptance are not complete. Passing an older candidate's
tests does not certify later source or packages.

## Financial-core refactor execution

Current checkpoint: **90/120 (A–G, H85–90)**. The chronological records below distinguish
the verified source and scope of each stage. Protected-file consolidation is next; the
funded deployment has not been upgraded by this refactor.

**12/120: checkpoint A complete, 2026-10-05.** Started from clean local/remote
`master` at `3d4970b3e502de9d4c9a89803610df3802e3e322`; created branch
`codex/auditable-financial-core` in the existing checkout. No funded runtime,
configuration, wallet, dependency lock or application source changed in A.
ARCHITECTURE now inventories customer/worker/signer/operator/token/pool contracts,
formats, failure behavior, I01–I15 enforcement, fixture coverage and interruption
points. All later acceptance must name its actual new source.

Baseline physical counts use `git ls-files`, counting split lines including
comments/blanks. Application/schema means `.hs/.rs/.sql/.html/.css` outside
`test`, `docs`, `build`; fixtures/formal files count as tests; notices have their
own category. Embedded Rust tests are reassigned, not hidden:

| Category at `3d4970b` | Files | Lines |
| --- | ---: | ---: |
| Application/schema | 65 | 14,843 (15,059 physical minus 216 embedded tests) |
| Tests/fixtures/formal | 22 + embedded part of 1 application file | 9,265 |
| Documentation | 17 | 7,403 |
| Tooling/configuration/locks | 30 | 3,316 |
| Third-party notices/provenance | 19 | 52,479 |

Runtime is 5 files/4,341 lines; workflow 12/2,327; pure source 6/601;
chain 14/2,800. Native/browser freezes contain 191/76 pinned package entries;
Cargo.lock has 150 package records (overlaps are not unique dependency counts).
Installed GHC 9.14.1, Cabal 3.16.1.0 and GHC JavaScript 9.12.2 were confirmed.
Reused existing native, browser and SDK caches; one build job, no VM started.

Commands, from repository root, with the existing project cache paths in
`CARGO_HOME`, `CARGO_TARGET_DIR`, `ECX_BROWSER_BUILD_DIR`:

```sh
cabal test ecx-bridge:bridge-test ecx-token:token-test ecx-pool:pool-test -j1 --offline --test-show-details=direct
ECX_REBUILD_CONTRACT_DATABASE=ecx_rebuild_contract_core_a_20261005 \
ECX_REBUILD_CONTRACT_READER=ecx_core_reader_20261005 \
  cabal run ecx-store-check -j1 --offline
```

Both commands exited 0. All three suites passed, including the Rust SDK checks.
The PostgreSQL database was newly created on `/tmp/ecx-pg-seam:29436`, with
migrations 001–008 applied in order and a new nonprivileged SELECT-only reader
(schema USAGE, tables/sequences SELECT, no schema CREATE). Application fixture
data was created only by StoreCheck's closed Opaleye operations. The default
contract passed ledger/role/concurrency/replay/failure/cancellation/refund/source/
replacement/custody checks and actual encrypted restic archive download/restore.
No real-chain transaction was sent. Dedicated TLS/fence/native modes are not
claimed from this default run.

Local logs: `/tmp/ecx-financial-core-baseline-tests.log`,
`/tmp/ecx-financial-core-baseline-store.log`,
`/tmp/ecx-financial-core-baseline-schema.log`. The first suite attempt lacked the
existing `CARGO_HOME` override and failed only offline SDK dependency lookup;
the corrected complete run passed without source or dependency changes. Store's
intentional interrupted-connection/rollback fixtures emit diagnostics before their
passing result. Evidence remains bounded to these fixtures and the retained funded
version above; external release gaps remain open.

Checkpoint A adds documentation only; the application/test counts are unchanged.
### Checkpoint B — 24/120

Moved the four existing payment fact records from Store into the 23-line pure
`Lifecycle.hs`, retaining Store's reexports and all field/constructor identities.
ARCHITECTURE specifies current fact ownership, target validity, operation-specific
inputs/effects, comparison identity and unchanged refusal mapping. No new runtime
decision, schema, JSON or signer authority exists yet.

Added `LifecycleCheck` to the existing Cabal suite: independent account formulas,
paid-identity model, bounded histories and meaningful shrinkers. It passed 600
generated checks and both deliberately wrong accounting/replay mutations failed
as expected. Its baseline adapter is explicitly not proof of a new replay engine;
the real PostgreSQL replay tests remain the durable baseline oracle for C.

`cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct` exited
0 with the same cache environment as A; log
`/tmp/ecx-financial-core-types-tests.log`. Existing warnings remain in unchanged
code; no warnings were introduced in Lifecycle or its model. Before changing the
fact declarations, the existing `ecx-store-check` binary also passed the dedicated
HTTPS mode (`ECX_REBUILD_TLS_ONLY=1`) on a second fresh schema-21 database,
`ecx_rebuild_contract_core_b_tls_20261005`, same restricted reader and the SDK path
from Cabal's generated `Bridge.SDKBuild`. Log:
`/tmp/ecx-financial-core-baseline-tls.log`. This verifies serialized signing,
authentication/certificate rotation, refusal after a changed custody snapshot,
gate recovery and exact saved replies using offline RPC fixtures; no chain send.

Piece size: four facts were 10 lines embedded in Store; now 23 lines in one pure
file plus one Store import, **net +14 application lines / +1 file**. This checkpoint
isolates facts for pure review; it does not claim line savings yet. Application
total is 66 files/14,857 lines; test total is 23 files plus embedded Rust tests,
9,378 lines (**+113**). Next: extract settlement, preparation and queue/send
decisions using these facts on unchanged schema 21, removing their old rules.

### Checkpoint C — 36/120

Implemented the bounded pure payment slice in `Lifecycle.hs`: funded preparation,
queue/send authorization and successful/failed settlement, for both chains and
all three funding types. The ordinary Store still runs the baseline implementation
until D. No schema, protocol, critical entry, chain send or funded runtime changed.
ARCHITECTURE maps the old conditions to their pure owners and the remaining IO
boundaries. This separation makes the rules readable without tracing queries or
RPC calls; it deliberately does not replace independent chain validation.

The bridge suite passed with **2,100 generated lifecycle cases**, fixed refusal
vectors and two expected negative mutations. Coverage includes exact redelivery,
original accounting comparison, historical fee terms, maximum amounts, generation
0–7, approved successor holds, finalized failure costs, source review, wrong
identity/generation/bytes, missing or wrong holds, insufficient/daily budgets,
native replacement selection, missing/changed backup coverage and 60/61-second
readiness boundaries. The new modules compile without added warnings.

The default PostgreSQL suite then passed on fresh
`ecx_rebuild_contract_core_c_20261005` with 15 differential settlement/failure calls
against the still-unchanged actual Store writer. Pure and old decisions agreed on
success/refusal/replay, exact fee behavior and retained history; existing refund,
source/replacement, restart, role and encrypted archive tests also passed. Commands
were the same one-job bridge-test and ecx-store-check invocations as A/B with the C
database. Logs: `/tmp/ecx-financial-core-slice-tests.log` and
`/tmp/ecx-financial-core-slice-store.log`. A final test-local variable rename only
removes a shadowing warning; no behavior was changed by that cleanup.

Slice size before integration: Lifecycle grew from 23 to **239 lines**; its model
from 111 to **312**; the temporary PostgreSQL comparison adds **61** test lines.
No new files in C. Application/schema total is **66 files / 15,073 lines**; tests
are **23 files plus embedded Rust / 9,640 lines**. These are additions while the
old implementation remains, not claimed savings. D removes the duplicate Store
decisions and temporary comparison adapter, then measures the total replacement.
The expansion gate is met for this bounded slice; broader recovery and schema
work remain unverified, and no overall line-count target is guaranteed.

### Checkpoint D — 46/120

Settlement landed in `3fb3753`; this checkpoint completes preparation and queue/
send integration over unchanged schema 21. Store loads fresh facts under its
existing deployment lock and applies the pure decision. Removed the duplicate
settlement/preparation/send rules and temporary comparison adapter. Exact plans,
drafts, signed bytes, generation/replay identity, event IDs, historical terms and
paid-conversion link precedence remain. Required single-row writes are checked;
no generic commit/query endpoint or new critical entry was added. READ COMMITTED /
READ WRITE is now explicit; safe/signing snapshots remain READ ONLY / REPEATABLE
READ. I02–I10, I12 and I14 were the principal regression boundaries.

Verified, with one build job and the existing caches:

- `cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline`
- `cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct`
- `cabal run ecx-store-check -j1 --offline` in default, `ECX_REBUILD_TLS_ONLY=1`
  and `ECX_REBUILD_SERVER_ONLY=1 ECX_REBUILD_CANONICAL=1` modes. Each used a fresh
  schema-21 database on `/tmp/ecx-pg-seam:29436`, the same restricted reader as A,
  and `ECX_REBUILD_CONTRACT_DATABASE=ecx_rebuild_contract_core_d_{all,tls,server}_20261005`.
  TLS used Cabal's generated SDK dylib through `ECX_REBUILD_TEST_SDK`; server mode
  used the current `exe:ecx-bridge` path through `ECX_REBUILD_EXECUTABLE`.

All exited 0. The bridge suite includes 2,100 generated lifecycle cases and
negative mutations. PostgreSQL includes preparation and settlement constraint
failure, queue failure at commit, exact rollback of financial records/holds/cost
clock/postings, writer fencing, successful policy rollback/reuse, actual SELECT-only
write denial (`42501`), competing-budget/recovery interleavings on separate
connections, concurrent same-order replay, restart/recovery and encrypted archive
restoration. The advisory-lock check rejects a second writer: the independent
fixture connection tests the database row-lock boundary without sharing its MVar.
This is bounded concurrency evidence, not a universal schedule proof.

Actual Servant HTTPS verifies auth/certificate refusal and rotation, wrong
identity/generation, changed-during-signing refusal, serialization, recovery and
exact SDK output. Existing bridge codec tests reject wrong result constructors
and malformed bytes. The assembled canonical-profile executable verifies HTTP
assets, paused unavailable-chain startup, unchanged balances and fence/process
cleanup. These are offline protocol/process fixtures, not new network acceptance.
The sole `evalCritical` call and signer `ClientM` construction remain in Critical;
customer component imports/exports and the signer's no-writer/no-broadcast API
were rechecked. The reference Main.hs hash is unchanged.

A short Ubuntu check used actual disposable service UIDs and systemd confinement
matching the installer's directory/file ownership and sandbox properties. Positive
own-file access passed; worker reads of custody/native-unlock/TLS keys and signer
writes to worker state were denied. It used public fixture material, not custody
secrets, and did not redeploy a bridge. The test UIDs/files were removed and the VM
stopped. No funded process, configuration, wallet or network transaction changed.

Logs: `/tmp/ecx-financial-core-integrate-all-build.log`,
`/tmp/ecx-financial-core-d-contract-build.log`,
`/tmp/ecx-financial-core-d-combined-tests.log`,
`/tmp/ecx-financial-core-d-{store,tls,server,os}.log`. An early added Native test
fixture supplied plain text where the existing recovery query expects a JSON
proof; it was corrected to the established fixture format and the complete run
passed. No production proof format was changed. Concurrent commits `e207c60` and
`78ee184` updated configure/start; their source was preserved and the combined
bridge suite/executable was verified before closing D.

Size: D adds **64 application lines, zero application files** relative to C,
including the seven-line reduction in settlement. Lifecycle is now 268 lines;
Store is 3,432. The replaced mixed IO rules now have one pure decision owner, but
separate readers/types currently cost more lines. No overall size saving is claimed.
The comparison adapter was removed; targeted fault/role/race tests give a net
**+52 test lines**. Including the concurrent setup change (+27 application/+6 test
lines), totals are **66 application/schema files / 15,164 lines** and **23 test
files plus embedded Rust / 9,698 lines**. Next is E47–56: customer funding/accounting
and projection, still on schema 21. Removing duplicate persistent state remains G;
current tests do not certify that future migration or public release.

### Customer funding and accounting — 53/120

Steps E47–53 are verified over schema 21, on top of `62a9c77`. This checkpoint
moves customer admission, instruction allocation/exposure, promotion, refund,
earned withdrawal/cancellation and treasury arithmetic into specific pure
`Lifecycle` decisions. Store still loads current facts and applies results inside
its closed Opaleye operations under the deployment lock. No DSL route, signer
capability, schema, wire format or real-chain policy changed.

Shared `quoteOrder` removes the separate preview/admission rules. Historical
capability/idempotency replay bypasses new pricing and retains its deadlines.
The alternate conversion/refund cost formula is shared by admission, promotion
and refund. Refund re-reservation now checks the state before mutation and
subtracts only holds this transaction will release. Ownership/reference evidence,
paused operator authority and full-principal refund funding remain mandatory.
Treasury postings can use only verified unbound receipts or free float/operating
allocations; the closed Store operation still verifies the exact custody proof.

One protective correction was demonstrated during this extraction: quote expiry
previously released provisional holds even when a partial/late/shallow receipt
was present. It now releases them only when no receipt was observed. PostgreSQL
regressions verify the received liability's holds remain provisional until handled;
existing unpaid expiry and funded/prepared hold tests also pass. This deliberately
retains capacity for review/refund rather than making it available to a new order.

Verification (I02–I04, I06–I10, I13–I14):

- `cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline`: pass, with existing caches and one job.
- `cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct`: pass.
  Lifecycle now has 3,600 generated cases, fixed refusal/replay groups and two
  deliberate negative accounting mutations. The 1,500 new generated cases cover
  ceiling fees, exact historical promotion, changed/lost/extra receipts, complete
  refunds, earned funding, time rollback, treasury conservation and protected funds.
- `cabal run ecx-bridge:exe:ecx-store-check -j1 --offline`: pass against freshly
  migrated disposable `ecx_rebuild_contract_core_e_20261005` and its SELECT-only
  role. Admission/refund/treasury, historical terms, holds, rollback/fencing,
  source/native/Solana recovery, original payout-link precedence and actual restic
  archive restoration all passed. This uses fixture chain evidence, not a new
  funded network acceptance. The first run exposed changed treasury refusal
  precedence; the original refusal was restored before the successful fresh run.

Logs: `/tmp/ecx-financial-core-e-{build,tests,store,schema}.log`. No VM, funded
runtime or chain transaction was started. The exact reference `Main.hs` hash is
unchanged. No application SQL escape, generic evaluator or second payment path
was added.

| Changed source | Before | After | Difference |
| --- | ---: | ---: | ---: |
| `src/Bridge/Lifecycle.hs` | 268 | 532 | +264 |
| `runtime/Bridge/Store.hs` | 3,432 | 3,405 | -27 |
| `workflow/Bridge/Admission.hs` | 90 | 89 | -1 |
| Application total for this piece | 3,790 | 4,026 | **+236, zero new files** |
| Existing lifecycle/Store tests | 4,583 | 4,686 | **+103, zero new files** |

Repository totals are **66 application/schema files / 15,400 lines**, **23 test
files plus embedded Rust / 9,801 lines**, and unchanged **31 tooling files /
3,362 lines**. This is a verified decision-boundary improvement, not yet a net
size reduction or security certification. E54 (derived customer status/payout),
E55 (its integrated mixed-history comparison) and E56 (whole-checkpoint closure)
remain. The schema/state reduction and remaining release gates are still open.

### Customer projection and checkpoint E complete — 56/120

Steps E54–56 are verified on top of `01eb253`. `projectCustomer` now owns public
payment progress and payout precedence. The closed Opaleye reader supplies original
settlement order, the current winner and active work. Paid conversion links survive
extra refunds; successive refunds retain the previous link until the next settlement.
Applicable source/native review remains visible. Admission/sticky review still uses
schema-21 status; compatibility columns remain written until G. No schema or signing
authority changed, and funded custody stayed on its prior source.

Verification (I02–I07, I09–I10, I13–I14), with the same cache environment and one job:

- `cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline`: pass.
- `cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct`: pass.
  Lifecycle has 4,500 generated cases, fixed groups and two expected mutation failures.
  The new 900 generated cases cover row-order-independent projection, successive
  refunds and paged summaries of up to 1,010 refund records retaining at most three
  display facts. This last boundary is a pure property, not a thousand-row PG test.
- `cabal run ecx-bridge:exe:ecx-store-check -j1 --offline`: pass on freshly migrated
  disposable `ecx_rebuild_contract_core_e_projection_20261005` and its SELECT-only
  role. The projection matched 17 histories before settlement and 27 after recovery,
  without financial mutation. Stale compatibility links, changed native winners,
  reverse-ordered refund IDs, in-flight status and exact replay all passed.
  Injected promotion/refund failures restored every financial row/hold and fenced
  the writer. Existing preparation/queue/settlement faults, budget/recovery races,
  role isolation and encrypted restic download/restoration also passed.

An added refund fixture initially followed an intentionally unresolved native scan
fixture and correctly refused `destination_payment_unresolved`. Moving that fixture
before the unresolved work fixed test ordering without changing the production guard.
The fresh full run passed. Logs: `/tmp/ecx-financial-core-e-projection-{build,tests,store,schema}.log`.
No new VM or real-chain send; protocol evidence here is deterministic test data.

| E54–56 source | Before | After | Difference |
| --- | ---: | ---: | ---: |
| `src/Bridge/Lifecycle.hs` | 532 | 589 | +57 |
| `runtime/Bridge/Store.hs` | 3,405 | 3,465 | +60 |
| Application piece | 3,937 | 4,054 | **+117, zero new files** |
| Existing lifecycle/Store tests | 4,686 | 4,848 | **+162, zero new files** |

All of E costs **+353 application / +265 test lines**, with no new files. Repository
totals are **66 application/schema files / 15,517 lines**, **23 test files plus
embedded Rust / 9,963 lines**, and **31 tooling files / 3,362 lines**. This adds an
explicit decision/projection boundary; it is not yet the planned net code reduction.
The old settlement/preparation/admission helper implementations are removed; schema-21
compatibility writes remain intentionally until G. Next is F57–70 recovery extraction,
then the schema/state consolidation. Security review and final release gates remain.

### Observation, cancellation and Solana recovery — 60/120

F57–60 are verified on top of `99b2657`. Scan-envelope/cursor/origin checks,
observation encoding/classification, unsigned cancellation and Solana expiry/retry
decisions now live in `Lifecycle`. Their closed Store operations still load facts
and apply writes under the existing lock. Readiness was already centralized by
C/D; this batch moved the named-stream projection beside those pure checks and
retained the existing two-refresh workflow, sixty-second window and final live
chain check. No new evaluator, role, protocol, schema or funded process was added.

Verification (I04–I09, I13–I14), one job and existing cache environment:

- `cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline`: pass after correcting a Payment/Funding projection caught by the compiler.
- `cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct`: pass.
  Lifecycle has **5,700 generated cases**, fixed groups and two expected mutation
  failures. New cases cover scan bounds/cursor/origin, unavailable/duplicate/future
  coverage, signed-but-unqueued observations, exact cleanup and late replay,
  current-generation expiry and separate retry/source/authority requirements.
- Default `cabal run ecx-bridge:exe:ecx-store-check -j1 --offline`: pass on disposable
  `ecx_rebuild_contract_core_f_observation_20261005`, including actual atomic scan
  rollback, preserved cursor/success on failure, eight cancellation generations,
  interleaved expiry/cancellation/retry, old callbacks after newer work, protected
  balances, exact saved bytes and encrypted restic restore. Customer-history
  comparisons remained 17/27 with no financial mutation.
- The same executable with `ECX_REBUILD_TLS_ONLY=1` and Cabal's SDK library on
  `ecx_rebuild_contract_core_f_tls_20261005`: pass. Actual worker/signer HTTPS,
  authentication/certificate refusal and rotation, concurrent request serialization,
  stale-custody second-read refusal/gate recovery, replay and pending recovery all
  passed. Chain responses were offline fixtures; no Mainnet/Devnet send occurred.

Logs: `/tmp/ecx-financial-core-f-observation-{build,tests,store,tls,schema}.log`.
The sole `evalCritical` call and the reference Main.hs hash remain unchanged.
Existing warning output remains; this checkpoint is not a warning-free build or an
independent security assessment.

| F57–60 source | Before | After | Difference |
| --- | ---: | ---: | ---: |
| `src/Bridge/Lifecycle.hs` | 589 | 705 | +116 |
| `runtime/Bridge/Store.hs` | 3,465 | 3,444 | -21 |
| Application piece | 4,054 | 4,149 | **+95, zero new files** |
| `test/LifecycleCheck.hs` | 456 | 528 | **+72, zero new files** |

Totals: **66 application/schema files / 15,612 lines**, **23 test files plus
embedded Rust / 10,035 lines**, **31 tooling files / 3,362 lines**. The extraction
still has a net line cost; removing redundant persisted state remains G. Next:
F61–64 native replacement, settled-winner/source recovery and same-byte rebroadcast,
followed by the shared mechanics/failure/recovery batch in F65–70. No completion
or security guarantee is inferred from these passing local checks.

### Native/source recovery and checkpoint F complete — 70/120

F61–70 are verified on top of `fb38ddb030fa4cd1cb70d606ed26017fd119b1b9`.
Replacement authorization, settled observation/winner changes, source loss/return,
loss coverage/approval and same-byte rebroadcast now have explicit pure decisions.
Store loads current facts and applies their narrow results under its existing lock.
Shared generation handling retains separate unsigned-cleanup and proved/approved
expiry evidence; the reader detects overflow with at most nine preparation rows.
Native transaction validation, wallet accounting corrections and live finality/
source checks remain intact. Schema 21, wire formats, critical dispatch and the
funded deployment are unchanged. I03–I13 and I15 are the main regression boundaries.

Verification used one build job and the existing cache environment:

- `cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline`: pass.
- `cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct`: pass,
  including **7,800 generated lifecycle cases**, fixed refusals and two expected
  mutation failures. New cases cover exact replacement work/family, reversible
  fee-only winner changes, native-review idempotence, missing/unavailable/returned
  sources, original capital split, stale approvals, timeout refusal and successor
  histories. Existing native tests retain shared-input exclusion, stable wallet
  anchors, pending-credit restrictions, foreign locks and unknown cleanup.
- `cabal run ecx-bridge:exe:ecx-store-check -j1 --offline`: five sequential modes
  passed on fresh `ecx_rebuild_contract_core_f_native_{store,tls,server,fence,custody}_20261005`
  databases with migrations 001–008 and the restricted
  `ecx_core_reader_native_20261005` role. Default mode covers atomic rollback,
  exact bytes, all cancellation generations/late callbacks, source coverage and
  repeated return, native winner changes, budget/recovery interleavings, 17/27
  customer-history comparisons and complete encrypted restic restoration.
  `ECX_REBUILD_TLS_ONLY=1` covers actual signer HTTPS, second-read refusal,
  serialization and gate recovery; `ECX_REBUILD_SERVER_ONLY=1 ECX_REBUILD_CANONICAL=1`
  covers executable HTTP and paused unavailable-chain startup;
  `ECX_REBUILD_FENCE_ONLY=1` covers uncertain commits and stale restart refusal.
  These modes used Cabal's current executable/SDK paths in
  `ECX_REBUILD_EXECUTABLE`/`ECX_REBUILD_TEST_SDK`.
- The final mode used `ECX_REBUILD_NATIVE_RECOVERY_ONLY=1`,
  `ECX_REBUILD_ENCRYPTED_NATIVE_ONLY=1`, `ECX_REBUILD_CUSTODY_ONLY=1` and the existing
  real L2L Signet node on port 29432. A newly created unfunded encrypted wallet
  was restored in separate executable processes with a relocated manifest.
  Descriptor state, labels, next address and private-key signing matched; complete
  custody export/encrypted upload/download/paused ledger restoration passed.
  The random test wallets were removed. Existing wallets/funds were untouched.

Logs: `/tmp/ecx-financial-core-f-native-{build,tests,schema,store,tls,server,fence,custody}.log`.
The disposable databases/role were removed; no build/test process or new VM remains.
The reference hash and sole `evalCritical` dispatch are unchanged. No funded send,
real alternate-chain history, physically independent backup or independent security
audit is claimed from this batch. Existing compiler warnings remain.

| F61–70 source | Before | After | Difference |
| --- | ---: | ---: | ---: |
| `src/Bridge/Lifecycle.hs` | 705 | 876 | +171 |
| `runtime/Bridge/Store.hs` | 3,444 | 3,404 | -40 |
| Application piece | 4,149 | 4,280 | **+131, zero new files** |
| `test/LifecycleCheck.hs` | 528 | 643 | **+115, zero new files** |

Totals: **66 application/schema files / 15,743 lines**, **23 test files plus
embedded Rust / 10,150 lines**, **31 tooling files / 3,362 lines**. All of F adds
226 application and 187 test lines. The benefit is explicit separately reviewable
decisions and fewer mixed query/decision blocks; this is not a net size reduction
or a claim of perfect security. G must remove duplicated persisted lifecycle
state and its writes while retaining every financial guarantee and migration.

### Schema dependency map and typed root — 72/120

G71–72 are verified on top of `2f35af4627b5dbae0c06bb9297c4ca527c538fc4`.
The architecture now maps every current status/resolved-dependent trigger, index,
reader, hash, initialization and recovery boundary before conversion. It records
the source-to-target cases, including cancelled conversions superseded by refunds,
ready work with no old intent and changed winners retaining their original event.
The existing installer migration glob was identified as an activation hazard:
new staged DDL must not be added to it without the closed migration path.

`PaymentPhase` encodes economic ownership separately from review and accepts only
valid ready/active/settled/cancelled column combinations. It bounds generation 0–7,
requires both settled identities and retains the original principal event when the
winner changes. Schema's typed `PaymentRoot` targets the extended existing intents
relation. The source remains on schema 21; these types do not install any columns,
grant a migration capability or change a current payment decision.

One measured design refinement preserves receipt uniqueness with less custom code:
an immutable root receipt reference is constrained to the obligation's existing
receipt by a composite FK, permitting a partial unique index on noncancelled roots.
This replaces the old obligation-status index without a cross-table concurrency
trigger or a second mutable cancellation flag. Its DDL/runtime integration belongs
to G73 onward and has not yet been exercised.

`cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline`
and `cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct`
passed with the existing caches. Lifecycle now has **8,100 generated cases** plus
fixed refusal/mutation checks. New cases cover phase round trips, preserving the
original event with a different winner, absent/mixed fields, invalid generation,
unknown review phase and malformed/oversized event identity. A final incremental
build after adding the constrained receipt projection also passed; pure phase code
and test source were unchanged. Logs:
`/tmp/ecx-financial-core-g-phase-{build,tests,build-final}.log`.

This piece adds **41 application lines and 17 test lines, zero files**. Totals:
**66 application/schema files / 15,784 lines**, **23 test files plus embedded Rust /
10,167 lines**, unchanged tooling. No database, process, network, dependency,
installed schema or funded state was changed. The new PostgreSQL constraints,
complete migration/comparison and deletion of old projections/writes remain open.

### Payment-root constraints and closed conversion — 75/120

G73, G76 and G77 are verified on top of `7caef4da4751a3b502f99fe0742ebb6e273ade8a`.
The source-to-target inventory now has an executable closed Opaleye converter and
real PostgreSQL constraints. They are proven before changing paying-runtime writers,
so old behavior remains available as a regression oracle. G74–75 and G78–84 remain
open; this checkpoint is not schema-22 runtime or funded-migration acceptance.

Private `Store.Migration` implements only `MigratePaymentRoots`: it verifies a
protected schema-21 archive, identity, minimum sequence, paused deployment and
exclusive worker lock, then converts bounded pages inside one transaction. Fixed
DDL stages version 2200, finalizes constraints and drops obsolete status columns;
Opaleye performs all data access and atomic version-22 activation. Every backfilled
root is checked explicitly because newly installed triggers cannot validate past
writes. Activation leaves intake paused without advancing or adopting a host fence.
The installer names migrations 001–008 explicitly to prevent accidental execution
of staged 009 DDL. Serve/signer still refuse schema 22 at this checkpoint.

The new root owns phase, active generation, settled winner and original settlement
event. Constraints bind each to immutable funding and exact preparation/attempt/
journal facts; protect receipt allocation and one active destination-chain payment;
and reject economic rewind, unproved winner changes and principal replay. Bounded
ready/active queries and review projection are private pure query definitions,
with no connection/evaluator or handler-accessible callback. Source review stays
separate from economic phase. The populated test exposed a necessary distinction:
completed unsigned cleanup can retain a fee hold for a later retry, including at
the generation limit. Conversion preserves that hold; it does not release money
merely to make a ready phase satisfy an oversimplified constraint.

The disposable schema-21-to-22 contract preserves **16 roots, 12 exact attempts
and 83 postings**, including conversions, ordered refunds, earned withdrawals,
finalized failures, expiry/approved successors, unsigned cancellation/exhaustion,
native replacements/winner changes and source review. It compares immutable
customer terms/capabilities, funding, holds/budgets, all signed bytes, accounting,
evidence, scans and custody records. Wrong identity, stale archive, active worker
and unexplained review refuse without changes. A migration child killed during an
actual PostgreSQL lock wait rolls back; an injected failure at final activation
also restores old columns and records. Negative constraints reject forged winner/
event, chain mutation, invalid phase, duplicate active chain/receipt, changed
obligation recipient and root deletion. The schema-21 reader refuses version 22.

Verification (one compiler job, existing GHC/SDK/browser caches):

- `cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline`: passed.
- Existing `ecx-store-check`, with `ECX_REBUILD_PAYMENT_ROOTS_ONLY=1` against the
  disposable `ecx_rebuild_contract_g_roots_20261006`: passed.
- Default `ecx-store-check` against a separate disposable schema-21 database:
  passed, including generated decisions, financial rollback/concurrency, 27
  customer projections and real encrypted restic readback/restoration.
- `cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct`:
  passed, including 8,100 generated lifecycle cases and executable/SDK contracts.
  An earlier direct binary invocation lacked Cabal's executable PATH and the SDK
  cache environment; the documented Cabal invocation passed without a source fix.

Logs: `/tmp/ecx-financial-core-g-root-{build,contract,regression,tests-final}.log`.
The converter's protected local archive check is not independent encrypted custody
restoration. Full migration orchestration, old-signer exclusion, postconversion
work-hash/runtime comparison, initialization and schema-22 restore still need
G74–75/G78–84. No network transfer, funded deployment, dependency or shared service
was changed; task databases/roles are disposable.

Like-for-like application/schema count is **66 files / 15,784 lines -> 70 files /
16,384 lines**: **+4 files / +600 lines**, including both DDL files and migration
support. Tests remain **23 files plus embedded Rust**, **10,167 -> 10,449 lines**
(**+282**, no new test executable/file). This piece improves durable enforcement
and migration evidence; it is not a size reduction. G74/G83 remove the obsolete
runtime status writes and compatibility machinery after the new path is verified.

### Authoritative runtime and checkpoint G complete — 84/120

Implementation `249a4a4491b9bc823455900ca68e3658ea63734c` completes G74–75 and
G78–84 on top of `e684f9b`. Runtime accepts only schema 22. Payment roots own
economic phase, active generation and current winner, while retaining the original
principal event. Orders retain admission only; customer progress/link and queues
are derived. The old status/payout/resolved projections exist only in private
migration support and its comparison tests. No alternate paying runtime remains.

Fresh owner initialization applies fixed 009 staging/activation atomically after
001–008, checks identity/worker exclusion and refuses financial residue. The
installer invokes that closed operation with only the public fingerprint, retaining
worker DML and signer SELECT-only privileges. Verified schema-21 archive restoration
converts only a new private database, preserves financial rows and work hashes,
invalidates readiness and leaves intake paused. It does not adopt a fence or start
a signer. Manifest/schema disagreement refuses.

The clean retained schema-21 fixture contains **16 roots, 12 signed attempts and
83 postings**. Its clone passes exact retained-record, customer/status/payout,
queue and source/replacement work-hash comparisons. Tests cover reviewed settled
orders, earned funding, extra refunds, failed/expired generations, native winner
changes and cancellation. Wrong identity, stale/sequence-mismatched archive,
malformed terms, ambiguous settlement, unexplained review and active worker refuse.
SIGKILL during a real PostgreSQL lock wait and failure in final DDL both roll back
conversion; constraints reject inconsistent or rewound payment facts.

Runtime regression covers I02–I12 and I14–I15: exact replay and atomic financial
writes, independent-connection races, role checks, admission/backup/readiness,
uncertain-commit fencing, restored full financial history and failed-stage cleanup.
Real local encrypted restic upload/download/readback/restoration passes without
claiming remote backup coverage. Ordinary executable startup and both profile
signer processes pass actual Servant HTTPS/auth/certificate rotation, serialization,
second-read refusal, exact SDK bytes, durable replay and pending-payment recovery.
The profile RPC fixtures are offline; these tests are not new funded transfers or
independent-host/OS-user acceptance.

Verification used one compiler job and existing caches, from the repository root:

```sh
cabal build ecx-bridge:exe:ecx-store-check ecx-bridge:exe:ecx-bridge ecx-bridge:test:bridge-test -j1 --offline
cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct
sh -n 2-Wrap-Unwrap-Server/install/install
git diff --check
```

All passed; bridge-test includes 8,100 generated lifecycle cases and existing
protocol/API/SDK checks. The built `ecx-store-check` passed each mode below using
`ECX_REBUILD_CONTRACT_READER=ecx_g_switch_reader_20261006`, PostgreSQL at
`/tmp/ecx-pg-seam:29436`, the built bridge executable/SDK and package data directory
as documented in LOCAL-DEVELOPMENT. Each database name below has the prefix
`ecx_rebuild_contract_g_` and suffix `_20261006`; each log has prefix
`/tmp/ecx-financial-core-g-switch-` and suffix `.log`.

| Mode | Disposable database | Log |
| --- | --- | --- |
| Default financial/roles/restic contract | `current` | `regression` |
| `ECX_REBUILD_PAYMENT_ROOTS_ONLY=1` | `switch_roots` (clone of preserved `legacy_roots`) | `migration` |
| Setup and residual-state modes | `setup`, `residue` | `setup`, `residue` |
| Ordinary server process | `server` | `server` |
| Devnet signer HTTPS | `tls` | `tls` |
| Canonical-profile signer HTTPS | `canonical_tls` | `canonical-tls` |
| Host fence/restart | `fence` | `fence` |

Build/property logs are `build-final` and `cabal-test` under the same prefix.
Development checks caught an empty Opaleye aggregate returning no row, obsolete
fixture settlement/fee-hold assumptions, and a display shortcut that hid retained
admission review. The final implementation handles an empty queue as zero, uses
real closed settlement facts in fixtures and preserves stored review. Source
ineligibility retains its specific refusal before generic payment-state errors;
no custody or signing gate was weakened to pass a fixture. The final full affected
contracts above passed after these fixes.

Measured against `e684f9b`, application/schema remains **70 files**,
**16,384 -> 16,389 lines (+5)**. Store is **3,408 -> 3,296 (-112)**;
Schema **319 -> 300 (-19)**; Projection **102 -> 142 (+40)**; private Migration
**251 -> 344 (+93)**. Those four total **4,080 -> 4,082 (+2)**; the owner CLI adds
three lines. Tests remain **23 files plus embedded Rust**, **10,449 -> 10,605
(+156)**. Tooling/configuration/locks remain **31 files**, **3,363 -> 3,366 (+3)**.
No application or test file was added. Compatibility is included in these counts;
this checkpoint reduces duplicate state and live Store code, not total source size.

The original reference Main.hs hash is unchanged. No funded database, wallet,
network transfer, shared service or dependency pin changed. Linux installation,
independent backup/restore and external security review remain later release gates.
Next: H85–94, sharing equivalent protocol/file mechanics while preserving distinct
chain checks and filesystem policies.

### Shared protocol mechanics and file-policy inventory — 90/120

Implementation `abee44a368893a6068569544f7f4695e1095cea1` completes H85–89;
ARCHITECTURE records the H90 ownership/mode/bound/publication/lock inventory.
Canonical unsigned parsing checks length/syntax before Integer conversion and
retains signed-ledger, SPL u64 and liquidity u128 bounds. Shared base64 decoding
checks encoded length before allocation, then decoded size. Invalid pool prices
outside u128 and oversized account encodings now refuse earlier; no supported
operation or wire format broadens. Native scientific amounts stay separate.

One classic SPL JSON parser returns owner/balance/mint facts for both token
administration and custody, with custody retaining exact identity and signed-ledger
range checks. The unused generic account-info export/repeated JSON extraction is
removed. Existing pure native/nonce/metadata/pool/transaction validators retain
their distinct layouts and complete byte/effect checks; each worker/signer boundary
still validates its own input. SDK output is not treated as authorization.

RPC shares HTTPS/genesis session setup and normalized hostname identity. Each
operation retains its network/error categories; each administration session closes.
The paced manager, bounded bodies/timeouts, independent providers, explicit read
retry allowlist, mutation/send nonretry behavior and unknown-outcome refusal are
unchanged. No mutable authorization fact or balance is cached.

Verification used the existing caches and one job:

```sh
cabal test ecx-bridge:bridge-test ecx-token:token-test ecx-pool:pool-test -j1 --offline --test-show-details=direct
cabal test ecx-bridge:bridge-test ecx-pool:pool-test -j1 --offline --test-show-details=direct
git diff --check
```

Token passed the first invocation. The initial pool CLI transport assertion failed
without a diagnostic; both direct canary-URL CLI refusals returned the expected
sanitized error, and the second invocation passed pool and bridge. Only the test
diagnostic changed between invocations; no production gate was relaxed. The cause
of the initial assertion is unestablished, so it is not represented as a fixed
product defect. The assertion now reports its synthetic canary result if it recurs.
Logs: `/tmp/ecx-financial-core-h-protocol-tests.log` and
`/tmp/ecx-financial-core-h-protocol-retest.log`.

New QuickCheck cases cover canonical/oversized integers, distinct amount ranges,
typed SPL facts, exact base64 round trips and transport/provider alias refusals.
Existing native/Solana/token/pool byte mutations, effects, signature validation,
SDK, offline signing, CLI, HTTPS, pacing/retry and 8,100 lifecycle cases pass.
Scope: I01–I02, I06–I08, I10, I14–I15; local protocols and executable contracts,
not new live-chain or independent-host acceptance.

All shared helpers counted, the changed production piece remains **13 files**,
**2,726 -> 2,649 lines (-77)**. Whole application/schema remains **70 files**,
**16,389 -> 16,312 (-77)**; tests remain **23 files plus embedded Rust**,
**10,605 -> 10,642 (+37)**. No new source/test file or dependency. The largest
reduction is Token.Network **418 -> 354 (-64)**. H90 identifies pathname-only
file authorization that H91 will replace with checks on the opened descriptor;
different credential/archive/fence policies must not be merged to reduce lines.

## Source and evidence boundaries

| Version | Verified scope | Not established by that evidence |
| --- | --- | --- |
| `54c2bfd` | Funded canonical wrap/unwrap, exact finalized bytes, reconciliation; same-host in-flight Solana recovery | New public TLS, later token changes, independent-host recovery |
| `509f617` | Ubuntu ARM64/x86-64 signed test packages, clean installation, repeat upgrade preserving custody/configuration, installed public HTTPS and paused intake | Public-domain renewal, funded clean-host restore, public release signing |
| `ba5c0f1` | Consolidated macOS/x86-64 suites and PostgreSQL/recovery/HTTPS contracts; durable offline token minting: macOS and Ubuntu ARM64/x86-64 token suites; real Devnet delayed signing/submission and refusal checks below | Independent release gates below |

Detailed historical transaction IDs, source hashes, snapshots, test scope and
private evidence locations remain in the immutable
[pre-consolidation record](https://github.com/freewillydev/ecx-solana-bridge/blob/ba5c0f1/2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md).
Resolved RPC, freshness, unpaid-payout and installer blockers in that history are
**not current blockers**. There is no new funded Mainnet retry to perform merely
to reproduce the already settled round trip.

## Completed acceptance retained

| Area | Evidence | Limit |
| --- | --- | --- |
| Customer conversions | Real L2L Signet/Solana Devnet conversions with immutable 1% fees; canonical Mainnet round trip | Deposits used tester clients; actual customer-wallet approval remains open |
| Refunds/revenue | Verified-owner refunds, additional-deposit refund preserving the original payout, native/wrapped earned-fee withdrawal, replay/restart | Scoped funded cases, not all possible chain histories |
| PostgreSQL ledger | Schema 18 → 21 migration; 24 projections, exact attempts and financial history compared; QuickCheck and real PostgreSQL transaction/fencing/concurrency contracts | Synthetic source-loss/winner-change evidence is not a real-chain reorg |
| Browser | GHC-JavaScript forms, fee previews, paused intake, saved-order reload, payout links and error behavior | No completed real Solana Pay wallet signing flow |
| Recovery | Native replacement/rebroadcast and same-host in-flight restoration; Solana in-flight restoration; encrypted native-wallet restoration | Physically independent funded disaster recovery remains open |
| Native source changes | Real Signet confirmation rollback/return observed by the paused worker without duplicated settlement | No confirmed double spend, permanent source loss or alternate winning payout |
| Isolation | Separate service identities, read-only signer database role, denied custody/native key access, native unlock/sign/backup RPC restrictions, service-account SSH denials | Independent whole-system security review remains open |
| TLS and admission | Real WarpTLS HTTPS, plaintext/body rejection, private-key checks, bounded concurrency and atomic global request/order limits | Not network-level DDoS protection or production load/renewal evidence |
| Signer model | Two-request TLA+ model: 54,289 states, unique output/path/dispatch invariants and negative mutations | Not a TLAPS/unbounded proof or automatic Haskell refinement |
| Token administration | Devnet mint/account creation, mint/burn, metadata, exact replay, expiry and finalized-failure recovery | Issuer approval and canonical backing remain external |
| Liquidity | Devnet pool/position creation, deposit/withdrawal, nonzero collection, explicit fee-bounded reinvestment and failure recovery | No unattended compounding or LP-lock claim |
| Trading | Real Mainnet SOL→USDC→canonical wrapped ECX acquisition via Orca; two-provider effects checked | No guarantee of ongoing routes, liquidity or reserve backing |
| Installation | Both Linux architectures: authenticated installation/upgrade, cold boot and isolation on recorded candidates; unfunded native/HTTPS-backup integration | Final-source packaging and funded independent restoration remain separate |

### Canonical funded checkpoint

On `54c2bfd`, 3,000 wrapped base units paid 2,970 native units; 1,000 native units
then paid 990 wrapped units. Fees were 30 and 10 units respectively, with network
costs booked separately. Alchemy and the independent verifier returned identical
finalized Solana payout bytes at slot 453424255:
`569aQRwy8WE9KcMpL2DD8XiANbxquwakX864JEfKnKSFPg5KssVg41TDsh9cpcBg8QQrBh12HgQXA3U9ZfyfL2Xy`.
All three custody assets reconciled without differences; sequence/backup coverage
was 55. Restoration of its pre-broadcast snapshot recovered the settled payout
from the real chain without another signature or payment. Backup storage still
shares this physical Mac.

### Retained package identities

The exact `509f617` test-signed packages passed installed HTTPS/upgrade checks:

| Architecture | SHA-256 |
| --- | --- |
| ARM64 | `5b89ceaeda28a4d52a32a10daf62f27351f4e218877d28e8207cf90a35d3a072` |
| x86-64 | `5a3dec48318d8226eb564807d73dff15cc7ba562a88c17e19bb367ae426decc4` |

They include the reviewed restic build and all 40 payload-manifest entries,
including the nested browser manifest. The acceptance signing key is not a public
release trust key. Private artifacts/evidence are in
`installer-acceptance-20261004/candidate-509f617/` under the retained secrets directory.
Do not label them as containing later token changes.

## Interactive setup release candidate (2026-10-05)

Source `bc9713c` adds interactive `ecx-bridge configure`/`start`, source-file
references instead of copied setup secrets, and offline `ecx-token enter-key`.
The latter uses a real terminal with echo disabled, shares existing key validation,
restores echo on rejection and refuses piped input or output overwrite. Real-PTY
token acceptance passed on macOS and Ubuntu ARM64/x86-64; the full token/bridge
suites passed on both Ubuntu architectures.
The customer API, financial workflows, ledger, chain adapters, migrations and SDK
sources are unchanged from the funded `548c509` runtime; no new funded transfer is
claimed for these setup packages.

| Architecture | Package SHA-256 |
| --- | --- |
| ARM64 | `56ae772b86d04b58c8a3c675c07ed4d98859a9c87fbec94b0d3dc8a483c5fbe1` |
| x86-64 | `f17dc72aa42707c6833093566c6af9c8582af59c5a8bb36d4b1804e5d067e103` |

Both artifacts have 40 verified manifest entries, matching frozen installer,
migrations, nested browser manifest and retained notices. Each current Linux plan
matches all 188 non-local notice records and 159 dependency source hashes. ELF
architectures/loaders were checked, with no embedded RPATH/RUNPATH; restic matches
the reviewed architecture-specific pin. The format-2 indexes use the retained
**acceptance-only** signing key, not a public release authorization key.

ARM64 and x86-64 clean Ubuntu acceptance started without PostgreSQL or bridge services.
`configure` produced exactly five private JSON files and no key-file copies.
`start` installed PostgreSQL, restricted roles, migrations and the two services,
then refused readiness with chain access deliberately disabled. HTTPS, plaintext
refusal, signer authentication, key isolation, port 443 capabilities, source-file-
independent restart, repeat upgrade preservation, fresh-over-existing refusal and
cold boot passed on both architectures. Service accounts were denied SSH access.
No funded wallets were used. The bootstrap executable needs Ubuntu runtime
libraries (including `libpq5`); these were installed before running `configure`.
This is not evidence that an executable can launch on an OS lacking its libraries.

Private evidence is in `installer-acceptance-20261004/candidate-bc9713c/` and
`candidate-bc9713c-x86/`. These packages do not install the separate token/pool
administration executables; build those through Cabal. The funded pilot stays on
its previously verified runtime. External release gates below remain open.

## Final review artifacts

Both Ubuntu 24.04 packages were built from clean commit `548c509`, which adds only
review documentation to implementation freeze `ba5c0f1`:

| Architecture | SHA-256 |
| --- | --- |
| ARM64 | `2e6c05ad00f1205ff818039fe564dfb5ebe22b5a35ca6b514b4805a48b943265` |
| x86-64 | `dfafeb10f5b0a4fec20e87446168f1a9352ede64efde225027e1bd0ec71a1adf` |

For each artifact, all 40 payload-manifest entries matched, with no unlisted payload
files, links or traversal paths. The nested browser manifest matched its actual
source files and generated assets. Migrations, installer and notices matched the
frozen checkout; restic matched the reviewed architecture-specific pin. Both Linux
plans matched all 188 non-local notice records and 159 distinct source hashes.
ELF architecture, loader and direct dependencies were inspected: no RPATH/RUNPATH;
system libraries remain dynamically supplied by Ubuntu, not copied into the bundle.
The actual compiled SDK was exercised by that architecture's token suite.

The format-2 release index was signed with the retained **acceptance-only key**;
`release-auth verify` passed for both artifacts. This verifies artifact integrity
and the test signer, not public-release authorization. Final payload inspection
and authentication are new; clean/repeat installation and cold-boot evidence remain
bound to the earlier candidates above. The installer/browser source is unchanged;
the funded ARM64 upgrade and recovery checks below extend that evidence.

Artifacts, index and `final-artifact-review.json` are in private
`installer-acceptance-20261004/candidate-548c509/`. Build/install/upgrade commands are
in [INSTALL.md](INSTALL.md); paused restoration and old-signer exclusion are in
[OPERATIONS.md](OPERATIONS.md). The installer bundles the bridge, SDK, browser and
backup client. Token/pool administration remains separately Cabal-built using its
own README; no mint authority is installed into the custody server. All temporary
build VMs were stopped after verification. Later evidence-only documentation commits
do not require rebuilding these immutable artifacts.

## Frozen ARM64 funded deployment (2026-10-05)

The existing funded VM was upgraded to the `548c509` artifact above (implementation
`ba5c0f1`). Its installed bridge SHA-256 is
`2d2dd1f9772ac2284d4a1d75ebda764a0b215562f5a68813c2d70b74f983f757`.
All payload hashes and unchanged schema-21 migrations matched. A stopped-ledger
backup and the previous runtime were retained; configuration, custody keys and
fence were preserved. Saved paid orders remained readable. Paused intake,
unauthenticated signer rejection and worker denial of signer-key access passed.

The existing betanet node had a corrupt undo file. An APFS clone of the retained
September 25 node snapshot caught up through normal network validation, then
passed `verifychain 4 144`. The original node and snapshot were retained. Removing
only regenerable Cargo intermediates recovered approximately 13 GiB; no wallets,
source or backup archives were deleted. The recovered node uses the existing
wallet directory, a 550 MiB prune target and bounded memory. Its fallback fee is
1 base unit/vbyte; the bridge's 500-unit native transaction cap is unchanged.
The signer's persistent, restricted RPC credential survives node restarts;
`sendrawtransaction` remains forbidden for that credential.

The new wrapped-to-native order paid 2,970 native base units from 3,000 wrapped
units (30-unit bridge fee; 141-unit native network fee). Native payout:
`9ba36852f5a4bbc9c189a1db2e2a18d0b66b01d12de106c5cecfe9345883df5a`.
Restarting the worker, signer and native node while this payout was unconfirmed
retained that exact generation-0 attempt, which subsequently confirmed in block
971186 without a replacement payout.

The encrypted sequence-60 custody snapshot was downloaded, integrity-checked and
restored into a separate PostgreSQL database using the frozen runtime. It retained
the same in-flight attempt and restored paused. A requested minimum sequence of
61 was rejected. No restored signer or fence was activated; the staging database
and temporary plaintext were removed after inspection. This is same-Mac recovery,
not physically independent disaster recovery.

The return order received 1,000 native base units and paid 990 wrapped units
(10-unit bridge fee; 5,000-lamport network fee). Finalized Solana payout at slot
453690143:
`2sKESTDE76hyN7oLSChYTHWzznpkVkcWAstfUJkR1p11X9iwXrES5YaVjbS4jw5Kw9c6HszaE5vQWggjLGqBLc29`.
Both independent providers returned identical finalized transaction contents and
metadata, including the exact 990-unit customer credit. An initial attempt expired
without executing; its saved nonexecution proof gated the successful generation-1
retry. This was one economic payment, not two funded orders.

Final custody balances were 95,778 native units, 3,004,020 wrapped units and
4,990,000 lamports. All matched the ledger exactly, with no in-flight effects.
Critical sequence and verified backup coverage both reached 76. A final service
restart preserved both paid orders, their original quotes and payout IDs. The VM
is running with intake paused for review; other test/build VMs remain stopped.
Private evidence is under `mainnet-pilot-20261004/current-review-20261005/` in the
retained secrets directory. These transfers used dedicated customer clients;
real-wallet UI approval, independent-host recovery and independent security review
remain separate release gates.

## Durable offline mint acceptance (2026-10-05)

The new `CreateNonce` and `NonceMint` token operations passed the local Cabal token
suite, including independent exact instruction/account validation, changed intent
refusal, nonce-state/version/authority parsing, imported-key identity, offline CLI
confirmation, private-file permissions and no-overwrite checks. Ordinary token
recovery contracts still pass. Linux token acceptance also passed on Ubuntu ARM64
and x86-64 at `ba5c0f1`, with one build job and actual platform SDK libraries.
Private logs are `token-nonce-{arm,x86}-ba5c0f1.log` in the retained
`installer-acceptance-20261004` directory. This does not update the older bridge
packages or prove installation of the final version.

Real Devnet acceptance used the retained disposable test authority and a separate
test payer, not Mainnet or bridge custody. The payer created nonce account
`Gqfkf2VojwkcdSp2YbTkoAufViDLhZY39wdRpXxA4AZM`, assigning its authority to the
test mint authority. Creation finalized as
`2Vx1xf9E4sZq2r63gBLXjFKDdH5fktPsnvGHSxr8UyQD4kmjnTcH7ypcegTsfzANYkKL3VQdEyuicyh1VsB3HSvV`.
Both base58 import and offline signing ran with macOS sandbox network access denied,
without an offline RPC configuration. The test copied the signed file between
isolated working directories; no physical USB device was used.

After an ordinary blockhash captured during preparation became invalid, the saved
nonce mint finalized at slot 507838464 with signature
`35EviD6g3pi39emd9SvvZsDRtBbt8GSVfu9h6eEkv4CNXPdjeb9ZTFdrzQfJnBppMyCpa9g8gpnHayywcGCKjBSg`.
RPC returned exactly the signed bytes; recipient token balance increased from 0
to 1 base unit. Creation and mint each cost 5,000 lamports; nonce rent was 1,447,680.
Replaying the saved mint returned the same finalized result and unchanged balance.
Tampered intent and a one-lamport fee ceiling were refused before submission. A
second signed intent using the consumed nonce was refused with
`token_nonce_consumed_or_changed`, and its signature remained absent. No automatic
replacement signature was generated. Private evidence is
`postgres-integration/private/offline-nonce-20261005/acceptance.json` in the retained
build root. This establishes the tested Devnet token path, not customer-wallet,
Mainnet nonce, physically separate-device or independent-security acceptance.


## Consolidated final acceptance

At `ba5c0f1`, root `cabal build all -j1 --offline` and all three Cabal test suites
passed on macOS. All three suites also passed on Ubuntu x86-64; the updated token
suite passed separately on Ubuntu ARM64. The explicit `ecx-store-check` contracts
then passed against disposable real PostgreSQL databases: role isolation, exclusive
writer, atomic reservations, replay/conflict handling, checkpoint rollback/fencing,
saved orders, historical fees, settlement and recovery. The same batch passed real
restic encryption/readback/restoration, corruption and wrong-password refusal,
exact saved attempts/postings, and real-process pinned HTTPS signer tests including
concurrency, certificate/auth refusal, second-read rejection and interruption cleanup.
The disposable databases/role were removed and child processes reaped.

The browser source and installer are unchanged from the accepted `509f617` version
(`git diff 509f617..ba5c0f1 -- 2-Wrap-Unwrap-Server/web 2-Wrap-Unwrap-Server/install`
is empty). Retain its actual served GHC-JavaScript/reload evidence rather than
claiming a new customer-wallet approval. Current Cabal browser asset checks and
HTTPS contracts passed. No funded Mainnet test was repeated for the offline token
delta. This freezes the implementation at `ba5c0f1`; later documentation-only commits
do not silently change that implementation boundary.

Private final logs: `ecx-final-{build,tests,contracts}-ba5c0f1.log`, the ledger/TLS
contract logs, and `all-nonce-x86-ba5c0f1.log`, retained with installer acceptance.

## Internal review and audit map

The 2026-10-05 review traced the following boundaries at `ba5c0f1`. No additional
implementation defect was demonstrated in this pass. This is an internal,
source-level review supported by the named contracts, not an independent audit,
an exhaustive review of every dependency, or a claim of perfect security.

| Boundary | Code to trace | Property checked |
| --- | --- | --- |
| Customer input | `api/Bridge/API.hs`, `workflow/Bridge/Web.hs`, `src/Bridge/Domain.hs` | Four customer endpoints; typed plans; bounded bodies/admission; capability-bound orders; integer amounts and immutable quotes |
| Critical dispatch | `src/Bridge/Operation/Internal.hs`, `workflow/Bridge/Critical.hs` | Closed caller/severity requests; one critical entry; signer transport remains inside its operation implementation and serialized critical lifetime |
| Signer authority | `workflow/Bridge/Signer.hs`, `workflow/Bridge/Credentials.hs`, `workflow/Bridge/Payment.hs` | Authenticated pinned HTTPS; process-role checks; saved deployment/decision binding; restricted private keys; independently validated reply |
| Durable ledger | `runtime/Bridge/Store.hs`, `runtime/Bridge/Store/Schema.hs` | Opaleye operations; exclusive writer, row locks, atomic reservations, immutable signed attempts, unique receipt/settlement use and balanced postings |
| Native effects | `chain/Bridge/NativePayment.hs` | Confirmed unique prevouts; exact outputs/change/fees; unchanged signed template; canonical block/depth and bounded replacement-family winner checks |
| Solana effects | `chain/Bridge/SolanaMessage.hs`, `chain/Bridge/SolanaPayment.hs`, `chain/Bridge/PaymentObservation.hs` | Exact signed instructions/keys/message; finalized observation; token deltas, fee/rent and failed-transaction effects; expiry requires separate evidence |
| Observation and solvency | `workflow/Bridge/Observer.hs`, `workflow/Bridge/Reconciliation.hs`, `chain/Bridge/PaymentSource.hs` | Failed scans do not advance readiness; revision-bound reconciliation; source eligibility; independent configured evidence where required |
| Recovery and backup | `workflow/Bridge/Recovery.hs`, `runtime/Bridge/Fence.hs`, `runtime/Bridge/Store/Backup.hs` | Identity/sequence checks; monotonic fence; coherent snapshot; full encrypted backup readback before acknowledgement; paused restoration |
| RPC failure | `chain/Bridge/RPC.hs` | Bounded responses, request identity, redacted errors; allowlisted read retries; ambiguous mutations never automatically retried |
| Offline administration | `1-Make-Wrapped-ECX/Token.hs`, `Token/Network.hs`, `Token/Signing.hs` | Imported-key identity; exact nonce creation/mint semantics; no RPC in offline signing; no automatic replacement signature; exact replay/consumed-nonce refusal |

Paths are relative to `2-Wrap-Unwrap-Server` except the token row. A reviewer should
follow one order through reservation, receipt, preparation, backup, signing,
broadcast intent and settlement; then follow the same order through an interrupted
send and restore. Compare the actual transaction with the saved intent, and check
that uncertain effects remain obligations rather than becoming spendable inventory.
Review configuration trust, operating-system isolation and backup independence
separately: the Haskell types cannot establish those deployment properties.

## Remaining public-release gates

1. **Customer wallet:** approve a real Devnet Solana Pay payment in a supported
   wallet, then verify reference/effects, payout, reload and errors. No website
   wallet connection is required.
2. **Real-chain recovery:** permanent source loss/double spend, coverage/return and
   a changed native winner need valid alternate L2L history or miner cooperation.
   The retained node has no suitable alternate branch. The upstream throwaway
   Signet challenge differs from L2L; it cannot substitute for this evidence.
3. **Independent recovery:** obtain a physically separate HTTPS backup repository
   and clean host, with upload/deletion separation and retention. Restore funded
   custody plus in-flight work, exclude the old signer, reconcile and explicitly
   resume. Mac/VM drills cannot establish physical independence.
4. **Production arrangements:** operator-approved issuer/mint/reserve policy,
   host/domain, independent RPC capacity, support and alert destination. Verify
   actual routes, TLS renewal and deployment behavior against those resources.
5. **Review:** obtain independent security/distribution review. See [dependency findings](DEPENDENCY-REVIEW.md)
   and [notice scope](THIRD-PARTY.md); inventories are not security certification.
6. **Final release:** use an operator-controlled release trust key, and obtain explicit publication and
   valuable-fund activation approval.

No outstanding gate is closed by fewer source lines, an unchanged status report,
or a green test whose scope does not cover it. Retain exact bytes and actual
financial evidence; do not repeat funded tests or installer builds without a
relevant change.
