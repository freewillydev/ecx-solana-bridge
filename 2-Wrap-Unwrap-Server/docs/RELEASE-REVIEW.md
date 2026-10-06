# Release review

The bridge has completed funded development tests and a canonical betanet/Solana
Mainnet round trip. It is ready for source review, **not public-release approval**.
The [previous nine-step internal completion plan](https://github.com/freewillydev/ecx-solana-bridge/blob/6fa7334/2-Wrap-Unwrap-Server/docs/IMPLEMENTATION-PLAN.md) is complete.
The [auditable-core refactor plan](IMPLEMENTATION-PLAN.md) is in progress;
its implementation and acceptance are not complete. Passing an older candidate's
tests does not certify later source or packages.

## Financial-core refactor execution

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
