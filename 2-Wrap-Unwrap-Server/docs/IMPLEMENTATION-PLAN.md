# Simplification plan

Revised 2026-10-02. This replaces the previous execution sequence. Simplify the
complete product for human review before adding more machinery or rebuilding
packages. This is an implementation plan, not a claim that the refactor is done.
The previous plan and evidence remain in Git history at commit `6d293a3`.

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
are in OPERATION-DSL.md. Read this 118-line reference before changing operation
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

The customer HTTP API now has four routes: configuration, create order, read order,
and read payment instructions. Servant handlers return `Plan a` with a constrained
existential `Request`; Runtime resolves its dictionary into the severity-indexed
DSL. Wire results use concrete records, not arbitrary JSON `Value`. Operator
recovery is a local CLI over a mode-0600 framed Unix socket, using the same runtime
dispatcher; its old HTTP routes and handlers, health/readiness routes and optional
deposit-hint operation are removed. The signer uses its separate authenticated Servant API.

The dedicated Haskell signer and critical-only client are implemented in source;
real two-process acceptance, OS isolation and restricted native RPC credentials
still need deployment verification. The signer uses a SELECT-only database role,
checks the durable decision before and after signing, and never broadcasts.
Old deployment/acceptance helpers still need conversion to this architecture;
previous installer evidence cannot establish this new boundary.

The legacy SQLite component and migrations are retired. QuickCheck checks integer
accounting and the SDK boundary; generated journal and immutable-quote properties
run against real PostgreSQL in the consolidated contract runner. Captured native
and Solana protocol checks remain. Recovery interruption, native winner changes,
replacement/cancellation and loss-cover acceptance must be reverified against the
current PostgreSQL DSL and dedicated signer. Removing the obsolete backend does
not establish parity of every former SQLite fixture or complete release acceptance.

Unused adapter convenience functions and four run-specific native/Solana probes
are removed. Production flows use the checked workflow primitives; captured
protocol fixtures and current acceptance runners remain. The obsolete probes
are recoverable from Git history, and `file-embed` is no longer a direct dependency.

Cabal project and dependency lock are at the repository root. Its tracked build
hook generates the native SDK artifact before compiling Haskell and tracks Rust
source/lock/toolchain inputs. `cabal test` also runs the SDK's own contracts. The GHC JavaScript frontend now builds through the same Cabal entry point,
with a separate frozen pure dependency graph and shared domain types. Its real
observation-only API browser checks cover configuration, rounded fees, precision,
direction switching, recovery-fragment stripping, saved reload and missing-order
errors without console errors. TypeScript/npm application files and build commands
are removed. Full funded browser/Solana Pay flows remain acceptance work. Linux
cross-compiler/bootstrap and its runtime notices remain release packaging gates;
the local Cabal build does not prove a clean Linux release.

The private signing Servant boundary now lives in `Bridge.Operator`: only
sign-preparation, draft-replacement and sign-replacement. Handlers package critical
existential requests; the hoist resolves `SigningDSL` and serializes evaluation.
`Bridge.Signer` retains independent ledger checks and signing credentials.
Signer transport is now authenticated HTTPS on 127.0.0.1, with a protected shared
token and a dedicated pinned trust certificate. Runtime uses the shared Servant
ClientM contract only inside critical evaluation. No signer Unix listener remains.
Credential/certificate ownership, renewal and separate service users still require
installation acceptance. The
existing private control protocol is preserved separately in `Bridge.Control`;
this change does not remove pause/refund/recovery functionality or add public routes.

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

Immediate priority, per the latest instructions: finish the direct HTTP server,
dedicated signer with critical-only communication, Solana SDK Haskell FFI and
Haskell frontend using GHC's JavaScript backend (no WebAssembly). Complete and
verify those replacements together before the next repository-wide deletion pass.
Use Marcus's `marcusmmmz/wecx-mint` compact root (README, package files and
scripts) as the layout reference. Cabal files replace npm application files;
`scripts/server.hs` is the named server entry point. Keep source, interface,
configuration and tests only where this service requires them, consolidate
operational scripts, and avoid separate top-level folders for each acceptance
runner, backend, language or historical phase.
Then remove every obsolete or irrelevant tracked file/folder, including retired
frontend/helper/proxy code and unused deployment/test tools. Preserve essential
invariant checks, dependency locks and licenses; do not hide clutter elsewhere.
The sequence below remains the broader refactor checklist, subject to that priority.

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

3. **Remove SQLite and duplicate storage abstractions.** Move unique useful assertions
   from legacy tests into pure/PostgreSQL tests, then delete legacy-src, its Cabal
   component, sqlite-simple, obsolete SQLite migrations and active import tooling.
   Historical migration tools remain available at the baseline revision. Replace
   PreparationStore, SettlementStore and similar backend-compatibility classes with
   concrete PostgreSQL functions where abstraction no longer pays for itself. All eleven
   single-instance storage typeclasses and the Store newtype are now removed.
   Fifty forwarding bindings are removed; workflows call their concrete PostgreSQL
   operations directly. The severity-indexed Operation dictionary is retained.
   Custody inspection/recording now lives together in Reconciliation, rather than
   creating a cycle through a backend adapter. Ledger queries and transaction
   boundaries are unchanged by this consolidation.
   The unused SQLite dbPath setting and its validation are removed. Existing
   configs must omit it; the financial identity hash and old-ledger refusal remain
   unchanged.
   The remaining PaymentStore module is now removed: settlement queries live with
   settlement mutations, custody queries live with custody checks, and native
   families use their existing validator directly. One domain View replaces the
   duplicate Snapshot; schema-to-obligation/attempt projections have one definition.
   Customer handlers now sit beside their four Servant routes in API.hs; the
   operation algebra depends on pure model types rather than the HTTP API module.
   Saved-record JSON encoding and decoding now share one implementation in
   Ledger.Model. Payment records share their error category; other workflows retain
   their existing error codes. Stored bytes and Aeson parsing rules are unchanged.
   Preparation cancellation now lives with preparation; Solana retry and refund
   creation live with settlement. Their separate store modules are removed, and
   the custody freshness check is called directly from its owner. Cancellation
   generation lookups share one query with preparation/signing checks.
   Remove redundant wrappers immediately after their replacement works.
   The standalone TLS executable and Python certificate generator are retired;
   their real-validator assertions now run as generated QuickCheck cases inside
   the existing Cabal suite, including exact and descendant DNS exclusions.
   Core PostgreSQL budgeting is now part of Ledger, so allowance and journal
   arithmetic share one implementation. Retain remaining unique SQLite assertions
   until their production equivalent exists. Treasury-spend classification now uses
   the PostgreSQL operator DSL; duplicate SQLite treasury allocation/spend mutations
   and the separate treasury runner are retired. Funding guarantees are checked by
   the consolidated PostgreSQL journal contract, including immutable replay across restart.
   The standalone raw-SQL FeeWithdrawalCheck is retired: its unique funding,
   pause/freshness, immutable replay and cancellation assertions now run as
   QuickCheck cases for both Native and Wrapped in the existing journal runner,
   using closed Opaleye fixture operations. SourceApprovalCheck now also uses closed Opaleye fixture operations and typed
   whole-row snapshots. Its restoration, native finality, replacement winner,
   loss-cover/return and covered-source send-fence assertions are preserved and
   pass against a fresh disposable PostgreSQL database; no signer or chain call
   occurs in that contract.
   Journal, source-recovery and host-fence contracts now share the single
   ecx-postgres-check executable. Fence fixtures initialize only explicitly named
   fresh disposable databases and use Opaleye for every row read/write; the last
   Haskell raw row queries are removed. Fault-injection DDL stays explicit.
   Receipt/page atomicity and delayed verification also use the PostgreSQL contract;
   legacy resume-policy checks remain until their whole workflow is migrated.
   Chain scanning no longer executes Opaleye directly: reference lookup, promotion
   selection and scanner diagnostics are named operations in the observation store.

4. **Make the domain and DSL the entry point for auditing.** Consolidate duplicate
   Plan/Request/DSL layers only when they add no distinct guarantee. Use explicit
   business ADTs/records instead of scattered state strings and Value blobs.
   Confine raw chain JSON to adapters. Put the operation vocabulary and permission
   table in one place. Preserve separate safe/critical evaluators and compile-time
   authority checks. Cabal now separates private types, customer API and runtime
   libraries. The API hides internal DSL constructors and cannot depend on database,
   signing or RPC implementations; operator planning is internal to the runtime.
   SDK/browser hooks live in a separate build-support package so Cabal 3.16 can
   enforce these component boundaries. No new runtime service is introduced.
   Check the final design directly against the supplied Main.hs and document intentional corrections.

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
