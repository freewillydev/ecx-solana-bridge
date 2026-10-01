# Integrated implementation plan

Revised 2026-10-01. This plan replaces the earlier thirteen-stage sequencing.
Build the complete test-network product first, then audit its completed pieces.
Implementation, integration, verification and audit are distinct checkpoints.

## Product contract

One small Haskell Servant application, two real chain adapters, PostgreSQL with
Opaleye throughout runtime database access, and a thin connection-free interface.
Use actual L2L Signet and Solana Devnet during development. Actual ECX betanet and
the canonical wrapped token are separate release acceptance requirements.

New orders charge 1% in both directions, using integer base units and existing
rounding rules. Historical orders retain their saved terms. Wrapping accepts a
Solana destination and provides native deposit instructions. Unwrapping accepts
a native destination and provides a standard Solana Pay request. Customers pay
in their wallets without connecting them to the website.

Supersede the published service's conversions, quotes, payment instructions/QR,
saved orders, status, refunds, explorers, trading links, token administration
documentation and restricted operator diagnostics. Mint authority and liquidity
keys remain separate from the online bridge. Use existing official tooling and
checked payment algorithms; no new token program, AMM or workflow framework.

## Architecture fixed before further expansion

    Servant handler -> typed operation -> result/severity-indexed DSL
                    -> central dispatcher -> safe or critical evaluator
                    -> Opaleye / existing real-chain workflows -> response

Handlers construct DSL values; evaluation performs effects. The constrained
existential hides operation type while retaining severity and result type. The
operation typeclass determines severity; it does not grant caller authorization.
Keep closed customer, operator and worker command sets and one production
critical-evaluation invocation. Safe evaluation has no signer, financial write
capability, wallet mutation transport or full private configuration. No arbitrary
LiftIO, SQL/RPC command or severity cast. See [the DSL specification](OPERATION-DSL.md)
for the Main.hs-derived design and provenance.

Fix shared domain, storage, adapter and API contracts once. Implement both ends
of any necessary contract change in the same batch. Reuse existing workflows
while replacing storage; do not redesign accounting simultaneously.

## 1. Finish the whole runtime and both customer flows

Continue from the existing PostgreSQL schema, historical import comparison,
real scanner/custody checks, payment port, Servant DSL and Solana Pay/interface
work. Do not repeat these investigations or treat each module as a new project.
Both new 1% conversions, a verified-owner full refund, explicit expired retry,
unsigned cancellation, browser quote/reload and clean restart now have integrated
Signet/Devnet evidence. Preserve this working baseline while completing the thin
interface, configuration and installation work below.

1. Finish and compile the actual PostgreSQL startup, scan/reconcile and paying
   worker loop with the existing API, DSL, observer, preparation and settlement.
   Bring across the recovery operations needed for normal restart. Unimplemented
   recovery situations must remain paused and visible rather than spend blindly.
2. Complete one continuous customer path in each direction: quote, create order,
   copy/QR/payment link, real deposit, observation, payout, status and saved-order
   reload. Keep old outstanding order instructions usable or resolve their
   obligations explicitly; a new interface cannot abandon historical orders.
3. Finish the normal refund path with verified ownership. Bind Solana receipts to
   the actual mint, custody, amount and reference; prevent deposit reuse. Reuse
   the existing payout engine rather than adding a second implementation.
4. Perform controlled local cutover: inventory processes, stop the old paying
   worker, take a final consistent snapshot, import into a fresh PostgreSQL
   ledger, compare state and reconcile custody before enabling payment. Preserve
   the old snapshot privately. Never run two paying workers against one custody.
5. Demonstrate both conversions through the real customer API/interface on
   Signet/Devnet, including one normal refund and one restart. Verify recorded
   payout amounts, 1% fees, historical terms and custody. Resolve failures that
   block these flows; put unrelated findings in the audit backlog.

**Checkpoint: both conversions, refund and reload/restart work as one product.**
This is a development milestone, not approval for valuable-fund operation.

## 2. Finish the usable, one-command product

6. Complete only the remaining thin interface features: exact fees/net amount,
   deadlines, clear errors, explorer links, support contact and configured
   Jupiter/Orca links. Verify actual liquidity before claiming trading works.
   A trading link does not itself replace bridge deposit/redemption instructions.
7. Finish interactive configuration and protected noninteractive config input:
   endpoints/networks, domain/port, mint/custody, key files, minima and limits.
   Hidden secret prompts must restore terminal echo. Validate integer ranges and
   identities. Reuse existing configuration rather than adding a framework.
8. Update the existing one-command installer for PostgreSQL, private access,
   restricted roles, migrations, node/helper/application services, health and
   backups. Preserve ledger and keys during repeat installation and upgrades.
   Keep raw SQL confined to named DDL/transaction/locking primitives and the
   legacy importer. Remove SQLite runtime dependencies after successful cutover.
9. Prove clean installation, health and restart on one local Ubuntu 24.04
   architecture. Rebuild the other architecture after the first complete package
   works; do not rebuild both for every unrelated source change.
10. Supply concise customer/operator instructions, redacted diagnostics and
    separate mint/metadata, inventory and pool setup documentation. Distinguish
    bridge fee revenue from pool auto-compounding. Validate an actual supported
    wallet's Solana Pay payment and browser reload. If browser automation is
    unavailable, continue independent implementation and record that acceptance
    as pending; do not call an untested wallet flow verified.

**Checkpoint: the complete test-network product is usable and installable with
one command.** No unfinished essential path is relabeled as an audit item.
At this point, stop feature expansion and begin the systematic audit.

Current installation evidence: the PostgreSQL ARM64 package passes fresh-ledger
installation, repeat installation, reboot, restricted-role checks and same-host
backup restoration. Finish the remaining interface/configuration features and
actual wallet payment acceptance, then verify the x86-64 package.

## 3. Audit the completed product in bounded passes

Audit against the same integrated build. Each finding records its component,
consequence, corrective action and affected acceptance check. Fix related
findings together, then rerun affected checks. Broaden regression testing only
when a change affects shared financial behavior.

11. **Execution and authorization:** typeclass/DSL resolution, existential result
    types, exports/component boundaries, safe capabilities, caller restrictions,
    single critical call site and any remaining bypasses.
12. **Ledger and recovery:** typed mappings/checked integers, constraints and
    balanced append-only postings; reservations, exclusive ownership, isolation,
    concurrent requests, revision fences and uncertain commits; exact migration
    comparisons and historical fee preservation.
13. **Payments and chains:** actual instruction/effect validation, reference and
    receipt uniqueness, finality, deadlines, partial/extra/late/ambiguous deposits,
    refund ownership, exact-byte retries, interrupted signing/sending, replacement
    families, reorgs and loss recovery. Implement missing recovery functionality
    found here before release; fail-closed handling alone is not final completion.
14. **Operations and installation:** secrets and redaction, least-privilege roles,
    bounded fee sweeping, health/support procedures, clean/repeat install,
    corrupted-package refusal, upgrade and reboot on ARM64 and x86-64, remote
    backup and paused clean-host restore with identity/history/custody checks.
15. **Release:** dependency/license notices and artifact integrity, actual betanet
    and canonical-token identity/authority/inventory acceptance, bounded operator
    pilot and independent security review. Public publication is a separate
    decision from the existing private repository.

**Checkpoint: audit findings resolved and release evidence recorded.** Do not
promise perfect security or zero debugging. A hot wallet retains material risk.

## Construction rules: what runs now and what waits

Run at most one test VM at a time, with one build job by default. Shut it down
when its acceptance/build is finished; do not keep idle architecture VMs running.

During construction, check that the whole application compiles, real interfaces
fit, the next customer flow works, and its necessary financial protections hold.
Run existing relevant regressions at integration milestones. Do not create a
bespoke executable, report or extensive test matrix for every small module.

Defer exhaustive negative/failure-injection matrices, rare-case exploration,
export-by-export reviews, cosmetic refactors, documentation polish, notice
refreshes and repeated platform builds to the completed-product audit. Record
those items briefly instead of stopping the main flow to solve each one.

Keep these protections in the initial implementation: private secrets and
customer capabilities, integer accounting, immutable saved terms, unique
receipts, one economic settlement, reservations, durable exact signed bytes,
backup barriers where required, single worker ownership and fail-closed handling
of uncertain external effects. Do not hold database transactions across RPC,
signing or backups. Preserve preparation -> journal -> backup -> sign -> saved
bytes -> backup -> send -> independent observation -> settlement.

A passed check is repeated only after a relevant change invalidates its evidence.
A task must advance the runtime, a customer flow, installation, or resolve a
shown integration failure. Stop improving a component when the next complete
flow can use it. Avoid alternative implementations and speculative abstractions.

Restoration requires the current journal as well as keys. After new external
effects, an old SQLite snapshot is not a safe rollback state. Configuration and
seeds alone do not reconstruct order obligations or payment history.

Report progress using the three checkpoints above and concrete working flows.
Do not use arbitrary completion percentages, confuse compilation with actual
wallet acceptance, or claim that an unfinished core path is merely an edge case.

## Execution batching — 2026-10-01

Complete each remaining workflow across storage, shared chain logic, closed DSL,
private/public API as applicable, interface and installer before opening a new
checkpoint. Use incremental one-job compilation and scoped contracts during
implementation, then run the shared suite once for the complete batch. Record
which requirement each acceptance proves and reuse that evidence until a relevant
change or concrete failure invalidates it. Avoid repeating toolchain downloads,
VM installation, package builds, full suites or real transfers for internal helper
changes. Group Linux packaging/install checks after runtime workflows stabilize;
keep one 3-GiB task VM at most and stop disposable resources after acceptance.

Prioritize the usable integrated product. Preserve all financial/signing guards
while building it; then perform the outstanding deep recovery, clean-host restore,
canonical network, supported-wallet and independent release reviews together.
Database fixture acceptance does not substitute for actual chain/host acceptance.
