# Integrated implementation plan

Revised 2026-10-01. This is the target and sequencing contract, not a claim that
the migration or DSL conversion has already shipped. It incorporates the
recorded Main.hs and later typeclass edits from “Add interactive environment
prompts”; see [the DSL specification](OPERATION-DSL.md) for provenance and types.

## Target and constraints

One small Haskell application with Servant, two real chain adapters, one durable
PostgreSQL ledger accessed through typed Opaleye operations, and a thin
connection-free interface. Charge 100 basis points in both directions for new
orders. Preserve saved terms on existing orders. Supersede the published wrapped
ECX service's conversion, payment instructions, status, refunds, trading links,
token administration documentation and operator diagnostics.

Use actual L2L Signet and Solana Devnet first; actual ECX betanet and the canonical
wrapped token require separate acceptance. Keep the existing official-SDK helper,
real node and checked payment engine. No invented networks, custom token program,
new AMM, broker, extra public service or general-purpose workflow framework.

The architectural execution path is:

    HTTP input -> typed operation + existential dictionary
               -> handler resolves a result-indexed DSL value
               -> central Servant hoist/dispatcher
               -> safe evaluator OR critical evaluator
               -> typed response

The handler produces the DSL; it does not execute ledger, wallet or chain IO.
Existential packaging hides the operation type, not severity or response type.
Typeclasses elaborate commands; they do not themselves grant authorization.
Keep separate closed customer, operator and worker languages. A customer may
request order creation but cannot construct an arbitrary worker payout command.

## 1. Preserve the working baseline

- Record the exact source commit, dependency locks, existing tests and real-chain
  evidence. Inventory running processes and installer state before any changes.
- Create a consistent private SQLite snapshot using the existing backup mechanism;
  preserve its identity, critical sequence, financial journal and signed attempts.
  Keep secrets, ledger snapshots and capabilities outside Git.
- Freeze regression requirements: both directions, immutable quotes, one economic
  settlement, same-byte retries, unknown-send fencing, custody checks and restart.

Exit: recoverable source and state, with a recorded comparison baseline. Do not
replay one-shot funding/transfer scripts merely to recreate an evidence file.

## 2. Write the replacement and effect checklist

- Compare the published repository, deployed read-only quotes and supplied chat:
  wrap/unwrap, fees/minima, QR/URI instructions, deadlines, saved orders, refunds,
  explorers, support, Jupiter/Orca links, mint/metadata and diagnostics.
- Distinguish separate inventory conversion, mint administration and liquidity.
  Runtime payouts do not acquire mint authority or LP keys.
- Inventory every IO entry point in handlers, CLI, observer, ledger, settlement,
  reconciliation, recovery, signing and adapters. Record severity and caller.
- Classify reads/quotes as safe; order binding, address provisioning, evidence
  acceptance, economic writes, pause/resume, signing and sending as critical.
  Hints are safe only as bounded untrusted inbox writes, never accepted evidence.

Exit: each requirement and effect has an implementation location, permission and
acceptance check. Unverified deployed revisions/liquidity remain explicitly open.

## 3. Specify contracts and the DSL together

- Wrap: native deposit instructions plus a validated Solana destination.
  Unwrap: native destination plus a real Solana Pay request; no site wallet login.
- Define order/reference uniqueness, exact mint/destination/amount matching,
  finality, partial/extra/late payments, verified refund ownership, duplicate
  receipts and ambiguous-payment review. Select the simplest official Solana Pay
  flow that satisfies these checks and actual wallet support before implementing.
- Retain ownership authorization for viewing private orders and submitting hints.
  No wallet connection does not mean unauthenticated access to customer data.
- Define Severity, operation GADTs, the operation-to-DSL typeclass and constrained
  existential package. Keep operation -> severity, drop severity -> operation.
  Use DSL severity result indexing and concrete endpoint response types.
- Resolve each route to DSL and hoist once into Handler. No MonadIO, arbitrary
  LiftIO, arbitrary SQL/RPC commands, incoherent instances or severity casts.
- Keep the algebra single-step initially. Use only the pure/rejection/composition
  structure required by the installed Servant API. Any eventual composition must
  retain the maximum severity of its effects.
- Specify opaque caller/evidence capabilities and a single production call site
  for critical evaluation. Safe contexts have no signer, writable financial
  connection, wallet-mutating transport or broad worker Config.

Exit: compile the real Servant shape and operation types, including negative
compile checks for critical-to-safe evaluation and customer payout construction.
A standalone type example is not completion of handler conversion.

## 4. Specify fees and setup configuration

- Define 100 basis points both ways; use integer base units and existing rounding.
  Change backend, quote/config responses, UI and tests together when the new
  runtime is ready. Old orders always use their saved fee policy and payout.
- Incorporate Main.hs's interactive setup prompts: domain/subdomain, mint,
  chain RPC endpoints, native wallet setup, Solana signer setup, port, minima,
  limits and fee configuration. Default fees are 1% in both directions.
- Hide secret input with guaranteed terminal echo restoration. Validate addresses,
  networks, genesis/checkpoints, mint/decimals, ranges and signer/custody identity.
  Never use Double for financial configuration or derive Show/Read on secrets.
- Split public configuration from private signer/node setup. Prefer existing
  key files and daemon wallet import; never pass a seed/private key in arguments,
  output, logs or frontend config. Interactive and noninteractive installation
  produce the same validated settings and private permissions.
- Setup/import/restore uses separate maintenance authority, not a public route or
  generic critical customer command. No keys are requested until needed.

Exit: deterministic validated configuration, immutable saved terms and explicit
secret handling, with no expansion of the online worker's authority.

## 5. Design PostgreSQL/Opaleye and evaluator capabilities

- Verify Opaleye/postgresql-simple compatibility with the pinned GHC and freeze
  the resolved dependency graph before attempting the full rewrite.
- Map all schema versions, tables, constraints, immutable journals, postings,
  reservations, attempts, decisions, cursors and critical sequences. Preserve
  integer ranges with checked conversions and database constraints.
- Use typed Opaleye definitions for application reads and writes. Restrict raw
  SQL to named schema/DDL, transaction and locking primitives Opaleye cannot
  express, plus the isolated legacy importer; do not disguise raw queries as
  an Opaleye database layer.
- Establish exclusive worker ownership, explicit row/advisory locking, revision
  checks, unique receipt/order/settlement constraints and transaction isolation.
  Define fencing after failed/uncertain commits and bounded retry rules.
- Separate read-only views, restricted hint inbox if retained, worker write and
  maintenance roles. PostgreSQL is private/local, with least-privilege access.
- Safe interpreter owns read capabilities. Critical interpreter owns write and
  signer capabilities and delegates to existing checked workflows.
- Do not hold database transactions across RPC, signing or backups. Preserve
  preparation -> committed journal -> backup barrier -> sign -> committed exact
  bytes -> backup barrier -> send -> independent observation -> settlement.
- Specify PostgreSQL snapshot/restore consistency and backup acknowledgement of
  critical sequences, including recovery after host loss and external effects.

Exit: schema, lock protocol, roles and backup contracts tested on PostgreSQL,
without changing the existing funded deployment.

## 6. Migrate access and execution boundaries together

- Implement typed table/query definitions, checked decoders and narrow transaction
  helpers. Convert safe queries first, then orders/admission, postings/budgets,
  observers, payment journals, settlement, reconciliation, recovery and audits.
- Replace direct handler IO with DSL construction and one central natural
  transformation. Preserve synchronous creation and existing response contracts.
- Route critical customer actions, worker scheduling and private operator CLI
  through the same guarded critical dispatcher. Recheck authorization/readiness
  at evaluation time; queued commands are not standing permission to spend.
- Enforce internal component/module exports: HTTP cannot import raw financial
  evaluators, ledger write functions, signer construction or verified-evidence
  constructors. Remove bypasses rather than simply renaming existing calls.
- Retain tested domain workflows instead of simultaneously rewriting accounting
  algorithms. Keep maintenance migration/restore entry points separate.

Exit: all runtime database access uses the new typed layer, all route effects
use DSL evaluation, one production critical-evaluator invocation site, enforced
imports and passing financial/boundary/concurrency regression checks.

## 7. Import, compare and cut over

- Build an isolated importer from a consistent snapshot, rejecting unknown schema,
  changed identity, overflow, missing rows or violated constraints.
- Compare every record and relationship, including balances, allocations,
  reservations, order terms/bindings, signed bytes, attempts, recovery decisions,
  history cursors, critical sequences and unresolved obligations.
- Rehearse restoration and startup paused. Stop the worker for final snapshot,
  import, comparison and controlled cutover. Preserve the old snapshot privately.
- Rollback to old state is valid only before new external effects. After any new
  signatures/sends, recover from the current journal; never run two workers or
  restore a stale ledger and resume blindly.

Exit: real test deployment on PostgreSQL with equivalent historical state,
reconciled custody and verified restart; remove SQLite runtime dependencies only
then. Keep legacy read support confined to the importer.

## 8. Implement connection-free redemption and updated fees

- Implement the selected official Solana Pay URI/request and immutable order
  binding through critical operations; expose instructions through safe reads.
- Validate actual instructions/effects, configured mint and destination, amount,
  order association and finality. Prevent one receipt satisfying multiple orders.
  Derive refund ownership from verified evidence; ambiguity requires review.
- Reuse existing payout and refund workflows behind critical evaluation. Preserve
  exact-byte retries, reservations and source/finality checks.
- Activate 1% new-order calculations and matching API/UI display, preserving every
  old quote. Use actual configured tokens/chains, no substitute protocol.

Exit: real-chain payment association and duplicate/refund contracts pass; no
customer command acquires direct signing/broadcast authority.

## 9. Simplify the customer interface

- Remove wallet connection controls and Wallet Standard dependencies after their
  remaining uses are replaced. Customers approve payments in their wallet.
- Provide copyable addresses/URIs, QR codes, wallet-opening links, exact net/fees,
  deadlines, reloadable saved orders, status/refunds, explorers and support.
- Persist only appropriate order-recovery data; keep signing and operator secrets
  out of browser storage. Safe queries still enforce private order ownership.

Exit: actual wallet transfer and browser reload work without website connection.

## 10. Finish feature parity and administration

- Add configured token identity and prefilled Jupiter/Orca links; verify route
  availability against actual liquidity before promising trading availability.
- Document separate official mint/metadata tooling, backing/inventory, pool setup,
  fee revenue accounting and an explicit bounded operator fee-sweep workflow.
  Earned bridge fees and pool auto-compounding are different operations.
- Provide redacted operator diagnostics/support access without .env, signer,
  cookie or private customer-data disclosure. Diagnostic reads stay safe and
  privately authorized; corrective actions stay critical.

Exit: replacement checklist complete or explicitly gated by external deployment.

## 11. Finish the one-command installer and upgrades

- Install PostgreSQL, restricted roles/private access, schema and validated config;
  configure existing application/node/helper services, health and backups.
- Support interactive prompts or protected config files. Package libpq/runtime
  dependencies and updated notices; remove packaged SQLite after cutover support.
- Preserve ledger and signer material during upgrades; detect incompatible config
  or schema. Do not promise “wipe and reinstall” restores all coins: keys recover
  wallet control, but order obligations, attempt history and off-chain decisions
  require the journal and verified backups too.
- Implement paused clean-host restore followed by identity/history/custody checks.
  Same initial settings alone are not a substitute for durable ledger recovery.
- Repeat clean install, repeat install, corrupted-package refusal, reboot and
  upgrade acceptance on Ubuntu 24.04 ARM64 and x86-64, locally on this computer.

Exit: one-command artifacts and reproducible evidence for both architectures,
including PostgreSQL, configuration and restore behavior.

## 12. Run integrated acceptance

- Real L2L Signet/Solana Devnet wrap and unwrap; real wallet Solana Pay acceptance;
  reload, rejected/late/extra/duplicate payments, refunds and support display.
- PostgreSQL restart, concurrent admission, stale revisions, failed transactions,
  interrupted signing/sending, preserved bytes and independent settlement.
- Boundary checks: safe evaluator cannot write economic state or access signers;
  public/customer requests cannot construct operator/worker commands; source and
  component checks confirm the sole critical evaluation site.
- Verify fee preservation for historical orders, both new 1% flows, reconciled
  custody and no unexplained obligations. Record actual evidence, not estimates.

Exit: complete public-test product ready for customer testing and review.

## 13. Finish release gates

- Complete replacement-family/reorg/loss recovery and live acceptance cases;
  remote backup and clean-host restoration with irreversible effects accounted.
- Verify actual ECX betanet and canonical wrapped-token configuration/authority,
  inventory and operator-funded pilot separately from Devnet acceptance.
- Finish dependency/licensing review, release integrity and independent security
  review; document hot-wallet exposure, operator limits and incident procedures.
- Public publication is separate from the existing private repository. Valuable
  fund operation requires the applicable acceptance gates, not just a typecheck.

Exit: evidence-backed release decision. No claim of perfect security or zero
implementation failures; typed boundaries and preserved contracts reduce the
places where mistakes can reach funds.

## Delivery order: working product first, deep audit second

This section supersedes the earlier stage-by-stage delivery order and exit gates.
The thirteen sections above retain the full scope and acceptance inventory; they
are not thirteen sequential audit projects. Build their required functionality
as one integrated product before exhaustive verification. Keep an explicit audit
backlog instead of expanding each implementation step indefinitely.

### Phase A — Establish the integration seam

1. Preserve the source baseline and consistent private ledger snapshot. Do this
   once; do not repeatedly reproduce historical financial evidence.
2. Verify the dependency graph and compile a minimal **real Servant route -> typed
   operation resolution -> DSL -> safe/critical evaluator -> real PostgreSQL via
   Opaleye** path. Include the actual real-chain adapter interfaces and helper
   configuration. No fake chains or replacement mock protocol.
3. Fix the shared domain types, schema mapping, evaluator capabilities, customer
   command restrictions and payment contract. Use existing concrete domain types
   wherever possible. Choose one Solana Pay flow; do not build competing designs.

Checkpoint: the actual components fit together and compile. Spend time resolving
foundational incompatibilities here, not polishing isolated components.

### Phase B — Build one complete wrap and unwrap flow

4. Implement the PostgreSQL schema and typed access needed by the existing order,
   observer, payment and settlement workflows. Convert existing logic rather than
   redesigning accounting while changing storage. Bring required recovery paths
   across mechanically; do not deepen every recovery case during this phase.
5. Wire handlers to DSL values, separate evaluators and the single guarded critical
   dispatch site. Make the real worker run through this path. Ensure customer
   requests cannot reach signing or arbitrary worker operations.
6. Implement 1% new-order fees, native deposit instructions and connection-free
   Solana Pay redemption. Wire real observation, existing payout/refund machinery,
   saved order terms and status responses through to the thin UI.
7. Make the interface usable: amount/destination, exact fee/net, copy/QR/payment
   link, saved-order reload and status. Remove wallet connection once replaced.
8. Run one real Signet/Devnet round trip in each direction and one restart using
   the new PostgreSQL deployment. Check recorded payouts, fees and custody.

Checkpoint: the customer can complete both conversions through the actual product
without website wallet connection, using real networks and the new database.
This is a public-test development checkpoint, not valuable-fund release approval.

### Phase C — Make the complete product installable

9. Complete and verify the historical SQLite importer before touching the existing
   funded deployment. A separate fresh PostgreSQL test deployment may establish
   Phase B first; do not let a broad importer audit block integration development.
   Final cutover still requires complete state comparison and a stopped worker.
10. Finish configuration prompts/protected config input, feature-parity links,
    operator diagnostics and mint/liquidity documentation. Keep these thin and
    reuse existing tools; do not add a configuration framework or trading engine.
11. Update the existing one-command installer for PostgreSQL and the complete
    application. First prove clean installation, health and a restart on one local
    Ubuntu architecture. Complete the other architecture after the first works;
    do not repeatedly rebuild both for unrelated source changes.
12. Validate an actual supported wallet's Solana Pay flow and normal browser reload.
    Track unavailable browser automation separately; it must not block database,
    worker or installer implementation. Customer-flow acceptance still needs real
    evidence before it can be called verified.

Checkpoint: the whole public-test product is built, usable and installable, with
remaining audit items explicitly listed. No unfinished core path is hidden behind
“audit later.”

### Phase D — Audit each completed piece and harden for release

13. Review types/exports/capabilities and critical call sites; database invariants,
    locking, concurrent requests and failed commits; chain/payment association,
    refunds, deadlines and ambiguous deposits; exact-byte retries and interrupted
    effects; replacement/reorg/loss recovery; secret handling and diagnostics;
    installer/upgrade integrity; remote backup and clean-host restoration.
14. Execute adversarial and failure-injection cases by subsystem against the
    integrated product. Fix findings in bounded batches and rerun affected checks.
    Broaden regression testing when the change crosses a shared financial boundary.
15. Complete both installer architectures, dependency/licensing checks, actual
    betanet/canonical-token acceptance and independent security review. Valuable
    fund operation and public release retain the release gates above.

Checkpoint: evidence-backed release readiness, with material findings resolved.

### Development rules that prevent churn

- Maintain one short integration checklist and one separate audit backlog. Every
  task must either unblock the next working flow or address a concrete finding.
- Keep one implementation of each workflow. Avoid parallel old/new runtime paths
  except the temporary, isolated migration/import boundary.
- Prefer existing checked code and concrete types. Introduce abstraction only when
  needed to enforce the requested DSL/capability boundary or remove real duplication.
- Run compilation and targeted checks after each coherent change. Run the existing
  financial regression suite at shared-boundary milestones. Defer exhaustive new
  edge-case matrices, documentation polish, notice refreshes and full platform
  rebuilds until the relevant product checkpoint works.
- Do not keep adding tests that restate implementation, repeat already-passing
  acceptance without a relevant change, or turn hypothetical concerns into new
  infrastructure. Record concerns for the audit phase with their affected component.
- Stop polishing a component once it meets the next integration checkpoint. Report
  progress by working customer flows and installability, not lines, test counts or
  unsupported percentage estimates.
- Preserve essential protections during construction: private secrets, integer
  accounting, immutable saved terms, receipt uniqueness, one economic settlement,
  committed signed-byte journaling, authorization restrictions and fail-closed
  handling of uncertain effects. Deep audit may wait; these cannot be removed to
  make a demonstration pass.
- Keep the existing funded deployment intact while the new path is built. Never
  run two paying workers against the same custody. Use separate configured custody
  for a fresh paying deployment, or stop the old worker before a controlled switch.

The objective is rapid integration followed by systematic audit, not auditing an
unfinished collection of parts. No architecture eliminates debugging, but early
compilation of the real seams and reuse of proven domain logic reduce mismatches.
