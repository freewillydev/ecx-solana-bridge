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

Aim for roughly 15–20 production Haskell modules, one small Rust signing helper,
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

Use one application/executable with public/worker modes where needed for OS privilege
separation. Do not place custody authority in the public web process just to reduce
process count. Keep one active paying worker. PostgreSQL, the native node, Solana RPC
and existing backup tooling are explicit dependencies rather than custom frameworks.

## Ordered execution

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
   concrete PostgreSQL functions where abstraction no longer pays for itself.
   Remove redundant wrappers immediately after their replacement works.
   Core PostgreSQL budgeting is now part of Ledger, so allowance and journal
   arithmetic share one implementation. Retain remaining unique SQLite assertions
   until their production equivalent exists. Treasury-spend classification now uses
   the PostgreSQL operator DSL; duplicate SQLite treasury allocation/spend mutations
   and the separate treasury runner are retired. Funding guarantees are checked by
   the consolidated PostgreSQL journal contract, including immutable replay across restart.

4. **Make the domain and DSL the entry point for auditing.** Consolidate duplicate
   Plan/Request/DSL layers only when they add no distinct guarantee. Use explicit
   business ADTs/records instead of scattered state strings and Value blobs.
   Confine raw chain JSON to adapters. Put the operation vocabulary and permission
   table in one place. Preserve separate safe/critical evaluators and compile-time
   authority checks. Check the final design directly against the supplied Main.hs and document intentional corrections.

5. **Unify complete payment flows.** Trace wrap, unwrap, refund and fee withdrawal
   through one workflow. Represent customer-deposit funding and operator-earned
   funding explicitly; never create fake customer orders or deposits. Finish the
   withdrawal path here, reusing/replacing its recent reservation stage as needed.
   Consolidate Payment/Settlement/Preparation/PaymentStore and PostgreSQL wrappers
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
