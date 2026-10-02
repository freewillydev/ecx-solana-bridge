# Bridge development

Read 2-Wrap-Unwrap-Server/docs/IMPLEMENTATION-PLAN.md before architecture work. The current priority is
human-auditable simplification: remove duplication, obsolete artifacts and unnecessary
abstractions while preserving required behavior and financial invariants.

Before operation, handler or interpreter changes, read 2-Wrap-Unwrap-Server/docs/reference/Main.hs in full
and 2-Wrap-Unwrap-Server/docs/OPERATION-DSL.md. Main.hs is the user's exact architectural reference from
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
