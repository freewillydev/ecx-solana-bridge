# Simplification plan

Revised 2026-10-02. This replaces the previous execution sequence. Simplify the
complete product for human review before adding more machinery or rebuilding
packages. This is an implementation plan, not a claim that the refactor is done.
The previous plan and evidence remain in Git history at commit `6d293a3`.

## Active execution: controlled replacement

The user chose a separate rebuild after the inventory review. Follow
[rebuild/README.md](../rebuild/README.md) for the current construction order.
The preserved baseline is `ba31b28`; build the replacement through root Cabal,
extracting proven protocol and financial behavior, then remove the old application
only after migration and real-chain acceptance. The baseline implementation steps
below remain requirements/reference, not a competing instruction to keep polishing
its installer or reorganizing its modules.

Current replacement checkpoint: pure monetary/funding/accounting types, preserved
customer wire records, caller/severity-indexed existential requests and four
restricted Servant handlers. The private Opaleye store now implements ledger reads and atomic pause/earned-fee
reservation/cancellation, verified against disposable PostgreSQL. Authorized saved-order reads now preserve
historical terms, capability access, review overlays and backup-gated instruction
visibility. Atomic order creation now includes idempotency, immutable terms,
inventory and both operating holds, readiness and daily-budget checks, with
PostgreSQL rollback/replay acceptance. Guarded instruction storage now covers native
allocation claims, immutable results, derived Solana references, backup-gated first
exposure and expiry preserving obligation holds. Native RPC provisioning, high-level evaluators, chain adapters and execution remain unfinished.
No existing custody state has been moved. See the rebuild README for scoped counts
and evidence; do not compare this subset against the entire old storage layer.

## Product and audit contract

Keep the useful behavior of Marcus's published conversion service: quote, create
order, identify deposit, confirm it, transfer existing treasury inventory, report
status, and refund when appropriate. His mint tooling is JavaScript; the published
conversion backend is Rust. Its reviewed reference is ecash-com/wrapped-ecx at
`b980b4372c4844d3d42ff1926fd0da848631cebc`.

Retain Haskell/Servant, PostgreSQL/Opaleye, connection-free customers, 1% new fees
both ways, historical saved terms, native deposit addresses, Solana Pay references,
QR/payment links, saved-order recovery, refunds, explorer/trading links and support.
Keep bounded operator treasury/earned-fee operations, reconciliation and recovery.
Use real L2L Signet/Solana Devnet for development; canonical deployment is a separate
acceptance gate. Mint/metadata administration, liquidity placement, LP locking and
compounding remain external tools with separate keys. Use existing market providers
for price discovery/charts rather than building an exchange or pricing engine.

A reviewer must be able to trace a request through its typed operation, authority
check, durable decision, chain effect and balanced settlement. Every retained file
must serve a current product function, invariant, protocol boundary, deployment need
or license obligation. Readability wins over code golf and arbitrary line quotas.

## Baseline and desired shape

At this review: 431 tracked files; 58 production Haskell modules / 9,331 lines;
9 legacy modules / 2,298 lines; 31 integration files; 27 scripts; 26 deployment
files; 13 test files / 6,504 lines; 218 documentation files including 186 evidence
artifacts. Local dependencies and build caches are not tracked source bloat.
Required license notices are not development clutter.

Aim for roughly 15–20 production Haskell modules, one narrow Solana SDK FFI library,
one thin frontend, one test suite with one acceptance runner, and three maintained
guides. Seek roughly 50–75 first-party tracked files, excluding required notices
and lockfiles. These are provisional review targets, not reasons to hide logic or
remove protection. Measure actual reductions in concepts, dependencies, entry points
and review steps as well as files and lines.

## Main.hs and the operation boundary

The supplied original is preserved verbatim at `docs/reference/Main.hs`, received
2026-10-02 from `/Users/lukekensik/Downloads/Main.hs`. Its SHA-256 and design mapping
are in ARCHITECTURE.md. Read this 118-line reference before changing operation
types, handlers or interpreter boundaries. Preserve its constrained typeclasses,
GADTs and severity intent while correcting unfinished or permissive sketch types.
It is a design reference, excluded from production builds.

Keep the valid typeclass/constrained-existential/GADT design:

    class Operation s op | op -> s where
      command :: op a -> DSL s a
    data Request s a where
      Request :: Operation s op => op a -> Request s a
    resolve (Request op) = command op

Servant handlers construct typed plans containing existential Request values and
their Operation dictionaries. Only the runtime boundary calls resolve/command to
convert the packaged operation into a DSL value. Separate evalSafe and evalCritical
interpreters execute them through one authorized dispatcher, with one production
critical-evaluation call site. Keep result type and severity visible while hiding
the operation type. Safe context has only read authority, no signing keys or writable
ledger. Caller permissions are separate from severity: an order request can be
critical without giving its customer access to operator commands.
Use closed constructors and enforced module/component exports. No arbitrary IO/SQL
command, severity cast, incoherent instance, undefined placeholder or unnecessary
free-monad/effect framework. Retain the operation typeclasses; remove storage
typeclasses whose only remaining purpose is supporting the retired SQLite backend.

## Intended architecture

    Servant handlers -> request / closed DSL -> authorized dispatcher
      safe interpreter     -> read-only Opaleye queries
      critical interpreter -> payment workflow -> durable Opaleye transaction
                                              -> native / Solana adapters

- Domain: amounts, IDs, explicit states, payment purpose, accounting and pure decisions.
- Operations/API: small operation vocabulary, severity/caller permissions, pure handlers.
- Runtime: startup capabilities and the two interpreters.
- Workflow: prepare, journal, sign, save bytes, authorize/send, observe, settle.
- Recovery: cancellation, expiry, replacement and loss decisions using that same workflow.
- Store: typed schema and explicit transactions/queries; PostgreSQL only.
  Opaleye access belongs only to implementations of specific closed DSL operations;
  no generic query/SQL/callback operation or connection access for handlers.
  All application reads/writes, diagnostics, permission checks and database test
  fixtures/assertions use Opaleye. Replace remaining handwritten runtime SQL queries,
  including system-catalog checks, with typed Opaleye access. Keep PostgreSQL driver
  connection/transaction control and migration DDL as explicit infrastructure, not
  a second application query interface.
- Native/Solana: concrete adapters; separate codec/validation modules only where useful.
- Small configuration, RPC/process, backup and frontend boundaries.

Use one Haskell HTTP/API process and one dedicated Haskell signer process.
The HTTP process serves HTML/CSS and invokes its Servant Plan interpreter directly;
there is no public-to-worker HTTP proxy. Keep the local operator control socket private. Existing
local customer sockets may remain as alternate transport for acceptance clients,
not a separate application or intermediary. Keep one active paying workflow.

Only the critical DSL evaluator may communicate with the signer. Keep its generated Servant ClientM
client and connection capability private to that evaluator; handlers and the safe
context receive neither. Use closed signing requests tied to durable preparation
or replacement decisions, never arbitrary bytes, RPC methods or caller callbacks.
The signer independently checks identity, saved authorization, transaction effects
and limits before signing, and never broadcasts. Separate OS credentials must keep
Solana keys and native signing RPC authority inaccessible to the HTTP process.
Restrict the HTTP process's native RPC methods at the node; merely routing ordinary
calls through the signer does not isolate authority while a full cookie remains
readable. Preserved saved attempts and backup-before-sign/send gates still apply.

First-party application and browser logic use Haskell, with the browser compiled
by GHC’s JavaScript backend and HTML/CSS for presentation. Do not use WebAssembly. Keep the existing Solana SDK Rust
only behind a bounded Haskell FFI in the signer process; remove its subprocess
protocol after migration. Browser DOM bindings and the generated JavaScript runtime remain necessary,
but no TypeScript application or npm frontend build should remain. Preserve QR,
integer amounts, payment instructions, saved-order reload and error behavior.
PostgreSQL, the native node, Solana RPC and backup tooling remain dependencies.
The signer/FFI and JavaScript-backend frontend are implemented; deployment and
funded wallet acceptance remain pending.
The integrated architecture is not yet complete or accepted
on real chains; previous package evidence describes the earlier process design.

## Current refactor checkpoint

Implemented in source:

- Four customer routes, connection-free orders, existential Plan/Request handlers,
  separate safe/critical evaluators and Cabal-enforced private components.
- One direct HTTP server and an authenticated loopback HTTPS signer. Its ClientM
  capability is private to critical evaluation; operator control remains local.
- PostgreSQL/Opaleye only; the SQLite component, storage typeclasses and dbPath
  setting are removed. Existing configs must omit dbPath. Financial identity and
  legacy-ledger refusal remain unchanged.
- Shared admission, accounting, saved-record codecs, preparation/cancellation,
  settlement/refunds, source coverage/return, treasury funding and resume checks.
  Earned-fee withdrawal has reservation/cancellation only, not a complete payment flow.
- Root Cabal builds the native app, bounded Solana SDK FFI and GHC JavaScript
  frontend. No TypeScript/npm application or WASM backend remains.
- One native QuickCheck suite and one PostgreSQL contract executable for journal,
  source recovery, host fencing and actual observer authority. These checks do not
  substitute for funded-chain, wallet or deployment acceptance.

Current ownership and invariants live in [ARCHITECTURE.md](ARCHITECTURE.md); change
history belongs in Git. Remaining Python tools/tests need consolidation. Signer OS
isolation/native-RPC restrictions, actual two-process funded flows, supported-wallet
signing, clean-host recovery and Linux packaging remain unverified release gates.
Historical installer evidence describes an earlier process design.

## Reinstall and recovery contract

The desired upgrade is a clean reinstall using the same recovery parameters.
Those parameters identify the deployment/network/mint/custody identities and an
off-host encrypted recovery repository, with its unlock material retained outside
the server. They are not merely RPC URLs or public addresses. Do not pass secrets
on command lines or automatically initialize an empty ledger for an existing identity.

A coherent recovery snapshot must include the native wallet/descriptors/key state,
Solana custody key, private signer configuration, PostgreSQL financial ledger,
exact signed attempts, sequence/backup manifests and supported schema version.
Independent key or seed backup is useful but cannot replace order history, receipt
binding or send decisions. Do not introduce a new key-derivation scheme to pretend
both existing wallets are reproducible from one parameter.

The reinstall sequence is: pause and quiesce the old worker; fence/retire it and
revoke old signing authority; make and verify the final off-host snapshot; install
from a pinned release; restore the verified snapshot into staging; restore keys
with separate permissions and validate both identities; adopt the sequence fence
without lowering it; migrate forward; rescan/reconcile both real chains and pending
signed attempts; resume only after matching balances/authorizations and readiness.
A crashed host requires recovery from the newest complete snapshot and review of
any uncertain later effects, not automatic replay or a guessed empty ledger.

Coins remain on their chains. A reinstall restores control and correct accounting;
it cannot recreate spent/lost funds, missing keys, or unavailable unbacked decisions.
No wipe command is implemented or authorized by this goal. Never erase the only
copy of wallet state or journal. Acceptance requires clean-host restoration with
nonempty balances on both chains and in-flight work, no duplicate economic payout,
refusal of stale/wrong-identity snapshots, and exclusion of the old worker.
This off-host recovery path is still a release gate, not a current one-command promise.

## Ordered execution

The current goal is a reviewable Signet/Devnet bridge. Complete the current
architecture end to end before optional module-count or line-count reductions.
Historical funded evidence is a regression baseline, not acceptance of the new
signer and GHC JavaScript browser. The latest inventory found stale helper
sandbox deployment, removed-route checks, standalone Rust examples and Python
row access. These are concrete remaining work, not release evidence.

Complete these milestones in order:

1. **Deploy the authority boundary.** Install a separate signer OS user/service,
   SELECT-only PostgreSQL identity, protected TLS/auth/private signing files and
   restricted native worker RPC credentials. Remove worker membership/access to
   native full-authority credentials and custody keys. Verify permitted worker
   methods and refusal of signing/key export at the real node. Retire the old
   helper subprocess/sandbox. Do not regenerate existing custody keys or reset
   the ledger. A second process without credential isolation does not pass.
2. **Finish earned-fee withdrawal.** Connect earned-fund reservation through the
   same durable signing/send/settlement workflow using an explicit funding type.
   Cover cancellation, retry and interrupted operation without synthetic orders
   or deposits, and accept a bounded withdrawal on the real test networks.
3. **Accept the current customer product.** With that signer and the current
   browser, complete both funded L2L Signet/Solana Devnet directions, refund,
   saved-order reload, restart and interrupted signed-attempt recovery. Use an
   actual supported Solana Pay wallet for the customer signing check. Preserve
   exact source revision and transaction identifiers in one acceptance record;
   injected database fixtures do not establish network or wallet behavior.
4. **Retire incompatible tooling in one pass.** Move unique Python row assertions
   and acceptance behavior into the Cabal/Opaleye runner; remove superseded
   scripts, obsolete helper configuration and standalone Rust example entry
   points once their needed functionality is covered. Keep operational backup
   behavior until its replacement is verified. Update installation and recovery
   configuration to the actual signer layout, including private credentials.
5. **Produce the review checkpoint.** Run a consolidated current-source build,
   QuickCheck/database checks and the acceptance above; reconcile README,
   architecture, operating instructions and GitHub to the tested commit. Clearly
   separate the reviewable public-test milestone from off-host clean-host restore,
   broader loss/reorg acceptance, canonical activation and independent review.

Finish fee-withdrawal implementation before the next costly Linux build so that
current customer and operator workflows receive one integrated acceptance batch.
No arbitrary module/file target is a completion gate. Keep one build job, reuse
warm caches, and stop only task-owned temporary services. Packaging for both Linux
architectures follows substantive runtime acceptance, not each source edit.
The workstreams below retain the broader requirements and invariants; their
numbering is not a competing execution priority.

1. **Freeze behavior and classify the tree.** Preserve the baseline commit and a
   consistent private ledger backup. Map every file to keep, merge/rewrite, remove,
   or historical artifact. Make one small matrix linking required behavior to its
   implementation and essential check. Identify any proposed behavior removal
   explicitly; do not silently shrink the accepted product. Preserve wallet state.

2. **Remove noise without changing behavior.** Remove historical evidence dumps,
   screenshots, progress diaries and obsolete plans from the current checkout once
   preserved in history/private release artifacts. Replace overlapping status
   documents with one current checklist. Keep a compact current acceptance summary
   tied to source/artifact identity. Remove unused probes and run-specific VM tools.
   Do not move the clutter into another directory in the same checkout. Preserve
   required licenses, provenance and dependency locks.

3. **Finish storage and test consolidation.** PostgreSQL has replaced SQLite and
   its single-instance compatibility classes. Preserve unique legacy assertions
   until their current workflow has equivalent coverage; do not treat backend
   removal as proof of parity. Keep all row access, including diagnostics and test
   fixtures, inside closed Opaleye operations. Driver connection/transaction control
   and schema/role/fault-injection DDL remain explicit infrastructure. Consolidate
   remaining Python acceptance tools into the existing Haskell suite/runner, then
   delete their predecessors. Preserve exact saved records, failure categories,
   atomicity, interruption/replay and sequence/backup fences. Historical migration
   tools remain in Git; do not restore them as another active backend.

4. **Make the domain and DSL the entry point for auditing.** Keep the supplied
   Main.hs reference, Operation dictionaries, existential requests, separate
   evaluators and compile-time authority checks. Preserve the guarantees of
   Plan/Request/DSL while removing redundant wrappers and discarded reports.
   Use explicit business types instead of scattered state strings and Value blobs;
   confine raw chain JSON to adapters. Keep operation vocabulary and permissions
   traceable, customer components unable to import runtime/database/signer authority,
   and SDK/browser build hooks separate from runtime services. Document intentional
   corrections to Main.hs in ARCHITECTURE rather than duplicating that explanation.

5. **Unify complete payment flows.** Trace wrap, unwrap, refund and fee withdrawal
   through one workflow. Represent customer-deposit funding and operator-earned
   funding explicitly; never create fake customer orders or deposits. Finish the
   withdrawal path here, reusing/replacing its recent reservation stage as needed.
   Consolidate payment, settlement and preparation workflows and PostgreSQL operations
   by responsibility. Keep effects and commit boundaries visible, with no transaction
   held across RPC, signing or backup.

6. **Simplify ledger and recovery together.** Give each financial fact one authoritative
   representation. Retain append-only postings, immutable signed attempts and necessary
   decisions; remove duplicated derived state only after proving reconstruction.
   Consolidate cancellation/retry/replacement/rebroadcast/source-recovery mechanics
   into a small typed recovery vocabulary. Keep actual chain-specific rules.
   Consolidate schema definitions and fresh-install schema while providing a verified
   forward migration for existing ledgers, including saved bytes and sequence fences.
   Redesigning the schema requires migration acceptance, not just compilation.

7. **Reduce the customer and operator surface.** One connection-free page, shared
   typed responses and minimal browser code. Keep QR generation through a pinned
   dependency; do not invent a codec to remove a build tool. One private operator
   command family can expose typed decisions instead of endpoints for every internal
   step. Keep pause/resume, funding, refunds, withdrawals and actionable redacted
   diagnostics. Existing mint/pool tooling stays outside the custody application.

8. **Replace the test collection with a compact specification.** Keep pure accounting
   and state-transition properties; PostgreSQL atomicity, locking and replay checks;
   DSL authority compile checks; protocol vectors; and one real-chain runner.
   Cover duplicate receipts, fees/reservations, wrong network/mint/recipient, refunds,
   ambiguous sends, expiry/replacement/reorg, restart and restore. Remove duplicate,
   obsolete and implementation-mirroring tests and bespoke executables. Port unique
   important assertions before removing their old harness. Tests should explain
   promises, not reproduce every helper. Local tests do not replace real-chain checks.

9. **Consolidate operations last.** One Ubuntu installation path, configuration format,
   backup/restore path and doctor command, using existing systemd/PostgreSQL/restic.
   Merge overlapping shell/Python wrappers. Keep backup coverage, key separation and
   source fencing while reducing their implementation. Reduce maintained prose to
   README (purpose/use/limits), ARCHITECTURE (audit path/DSL/invariants/reference),
   OPERATIONS (install/fund/pause/recover/upgrade), plus required legal/security
   disclosures. Build ARM64/x86 only after the runtime refactor is coherent.

10. **Review the reduced whole.** Trace every retained user/operator flow and interruption
    at each irreversible boundary. Run the consolidated suite and real Signet/Devnet
    acceptance. Close outstanding wallet-signing, off-host restore, native loss/winner
    change, canonical authority/backing/funded-flow and independent-review gates.
    Reuse old evidence only where its behavior and artifact scope still apply.
    Produce a private review candidate; public activation remains a separate decision.

## Rules and completion

Replace one coherent path, verify it, delete its predecessor. Avoid a second full
application growing beside the first. Validate necessary invariants during changes,
then test the integrated workflow; defer exhaustive edge matrices and packaging.
No new bespoke report or executable per helper. Use small targeted reads, one build
job and at most one 3-GiB task VM when necessary; stop it immediately after use.

Keep integer accounting, immutable quoted terms, unique receipts, atomic reservations,
single economic settlement, exact signed bytes, required backup-before-send barriers,
exclusive worker ownership and independent settlement validation throughout.

Completion requires both a genuinely smaller reasoning surface and every retained
function working with appropriate evidence. A short codebase is not automatically
trustworthy; the objective is a concise, legible implementation whose authority,
accounting and external effects a human can actually verify.

## Repository layout

The root has three project folders: `1-Make-Wrapped-ECX` for token administration,
`2-Wrap-Unwrap-Server` for the bridge and its build/test sources, and
`3-Create-CPMM-Pool` for separate liquidity operations. Administration and pool
programs remain pending; their folders point to the existing operational guide.
Shared Git metadata, CI, license and contributor instructions remain at the root.
