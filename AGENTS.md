# Bridge development

Read 2-Wrap-Unwrap-Server/docs/IMPLEMENTATION-PLAN.md before architecture work. The current priority is
human-auditable simplification: remove duplication, obsolete artifacts and unnecessary
abstractions while preserving required behavior and financial invariants.

Before operation, handler or interpreter changes, read 2-Wrap-Unwrap-Server/docs/reference/Main.hs in full
and 2-Wrap-Unwrap-Server/docs/ARCHITECTURE.md. Main.hs is the user's exact architectural reference from
“Add interactive environment prompts”, supplied 2026-10-02. Keep it unmodified and
outside production builds. Preserve the typeclass/constrained-existential/GADT
severity design; correct the sketch's incomplete or permissive types as explained
in the DSL guide. Keep separate safe/critical evaluators and one authorized critical
dispatch site. Re-read the reference after context loss when doing architecture work.

Use targeted reads, one build job, and no idle task VMs. Consolidate tests and
documentation instead of creating a new report or executable for each small change.
Keep required licenses and dependency locks.

Database access: use Opaleye for all application reads/writes, diagnostics, role
checks and database test fixtures/assertions. No raw SQL query/execute escape path
for those operations and no alternative database backend. Underlying libpq
connections/transaction control and schema-migration DDL are separate infrastructure.

Opaleye queries belong only to implementations of specific closed DSL operations.
Do not expose connection/query callbacks or generic RunQuery/RunSQL operations to
handlers. Keep connection capabilities private to the relevant interpreter.

Run Cabal build/test commands from the root (one build job). Use Cabal hooks for
non-Haskell compiler inputs; do not require separate application build commands.
Keep customer HTTP limited to configuration/order/payment instructions. Local
operator control must use the closed DSL dispatcher, not operator HTTP routes.
SQLite and its legacy test library are retired; use QuickCheck and actual
PostgreSQL contracts. Run other bridge operations from 2-Wrap-Unwrap-Server. Keep token administration in
1-Make-Wrapped-ECX and liquidity operations in 3-Create-CPMM-Pool, separate from custody.

## How to run and verify this project

Read `/Users/lukekensik/.codex/controller/PROTOCOL.md` and `OWNERS.md` before writes. Only the registered ecx-bridge owner edits this lane; helpers/verifiers are read-only. Preserve all data unless Luke explicitly authorizes deletion. Keep `DONE.md` criteria unchanged without logged reason and controller agreement. Append meaningful steps to `.audit/release.tsv` and refresh `RESUME.md` before stopping. No completion or merge without a fresh separate verifier's explicit PASS.

Setup: follow `2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md`. Native tools are GHC 9.14.1 and Cabal 3.16.1.0; browser is GHC JavaScript 9.12.2. Do not loosen freezes to fit a different compiler. From repository root, in the pinned toolchain shell:

```sh
cabal build all -j1
cabal test all -j1 --test-show-details=direct
cabal test ecx-bridge:bridge-test -j1 --test-show-details=direct
cabal list-bin ecx-bridge:exe:ecx-bridge
```

The isolated PostgreSQL contracts and prerequisites are documented in LOCAL-DEVELOPMENT.md; passing ordinary QuickCheck is not evidence those integration contracts ran. Use disposable test databases, never production credentials.

Run setup on a dedicated Ubuntu host using the verified published installer and `2-Wrap-Unwrap-Server/docs/INSTALL.md`. Explicit source-built flow is `ecx-bridge configure` then `ecx-bridge start` from the setup directory, with root permissions where documented. These commands create keys/install services and can move funds; never run them casually on an existing custody host. Operator commands and restricted status are in `2-Wrap-Unwrap-Server/docs/OPERATIONS.md`.

How a stranger verifies DONE.md:

- SEC: read the sealed scan report identified in RESUME.md, both regression tests and fresh reviewer verdict tied to the final commit; inspect DEPENDENCY-REVIEW.md. Scan completion alone fails this gate.
- BUILD: run the pinned commands above and documented PostgreSQL contracts, retain exit codes and final commit/artifact digest.
- INSTALL: follow INSTALL.md on an isolated clean Ubuntu host using that exact artifact; observe configure/interruption/start/reboot/resume and private file retention. Do not substitute the configure-only result.
- WALLET: follow the customer Solana Pay payment instructions in a real wallet app on the stated test network, save order ID and transaction ID, check 1% fee, settlement and reload. Never replay a funded order.
- FUNDS / RESTORE: inspect RELEASE-REVIEW.md and authorized private acceptance evidence; cross-check the recorded transactions and restored ledger, source exclusion and fresh backup. Missing access is unverified, not PASS.
- ALERT: use the documented monitoring procedure in OPERATIONS.md and retain external failure/recovery receipts; a local log is insufficient.
- TRUST: independently obtain the designated public key and verify the final release signature and digest; unsigned review artifacts fail.
- PUBLIC: inspect actual tunnel/firewall/listeners to confirm access stays disabled while other gates fail. Only after the independent pre-public PASS specified in DONE.md and separately authorized enablement, verify the intended HTTPS endpoint; obtain final independent PASS afterwards. Public GitHub source is not public bridge access.
- VERIFY: a fresh verifier records per-row PASS/FAIL, evidence and overall verdict in the owner's audit trail. The owner records their findings without rewriting failures as passes.

Do not expose configuration secrets, wallet keys, bearer capabilities or authenticated RPC URLs in any evidence file. Failed/deferred checks remain FAIL with their unblock condition.

Never log a backup repository URL or an unvalidated URL component. Restic URLs may wrap HTTPS as `rest:https://...`; ordinary URL parsing then places credentials inside the apparent path. Keep diagnostic output to fixed status fields and rotate any credential accidentally disclosed.
