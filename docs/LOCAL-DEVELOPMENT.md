# Local development

Follow [IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md) and read
[OPERATION-DSL.md](OPERATION-DSL.md) plus the preserved Main.hs before changing
handlers or interpreters. The old run diary and SQLite procedures are retained in
[Git history](https://github.com/ekulkisnek/ecx-solana-bridge/blob/aa09e1e/docs/LOCAL-DEVELOPMENT.md);
they are not current operating instructions.

## Build and tests

Use the pinned dependencies and one build job:

```sh
cabal build exe:ecx-bridge exe:ecx-postgres-journal-check -j1 --offline
cabal test bridge-test -j1 --offline --test-show-details=failures
```

Offline builds assume cached dependencies. Remaining legacy tests still need the
pinned SQLite library selected by the local Cabal configuration; production uses
PostgreSQL. Keep host-specific paths ignored. Preserve shared caches and private state.

The PostgreSQL journal runner covers postings, ownership/row locks, backup receipts,
idempotent orders and saved policy, concurrent inventory reservations, duplicate/
partial deposits, expiry, instruction backup gates, and SQL-error rollback/fencing.
Fixtures and assertions use closed Opaleye operations. These are database contracts,
not live-chain acceptance.

Use a fresh disposable database with all `migrations/postgresql/*.sql` applied in
filename order. This host uses socket `/tmp/ecx-pg-seam`, port 29436 and the current
OS user. Set `ECX_JOURNAL_CONTRACT_DATABASE` to a fresh `ecx_journal_contract_…`
database, run the binary from `cabal list-bin exe:ecx-postgres-journal-check`, then
drop that specific database. Never target an existing custody ledger.

Other `integration/` runners cover recovery, snapshot/restore and real chains.
Read their restrictions before running them; some sign or transfer test funds.
Historical acceptance applies only to its recorded source/configuration/network.
Current release gaps are in [RELEASE-REVIEW.md](RELEASE-REVIEW.md).

## Local runtime

Use private configuration for real L2L Signet or ECX betanet with Solana Devnet.
Keep keys, cookies, credentials, ledgers, signed bytes and backups outside Git.
Build the frontend with `npm ci --prefix web` and `npm run build --prefix web`.
With the configured native node running and private PostgreSQL environment loaded:

```sh
scripts/start-local /absolute/private/config.json --binary /absolute/path/to/ecx-bridge
```

The launcher defaults to loopback port 61734; Ctrl-C stops its worker/web children.
Verify executable/arguments before stopping a recorded PID. Run only one paying
worker per custody identity. Respect persisted fences and retired sources; do not
enable an old clone or remove an observation-only recovery override to progress an order.

`PGREADUSER` must differ from `PGUSER`. Grant only schema usage, table SELECT and
sequence SELECT. Startup rejects elevated roles, public-schema creation, table/
column writes and sequence use, including inherited grants. Readers use
`PGREADPASSWORD` only when supplied; safe operations use read-only transactions.
Do not weaken these checks to start a misconfigured instance.

New orders charge 1% both ways; saved quotes keep their terms. Check inventory,
fee budgets, deadlines and exact network/token identities before real tests.
Reuse saved orders and exact attempts after interruption. Never reset a ledger,
delete an attempt or regenerate a capability to force a retry.

Use at most one bounded task VM when needed and stop it afterwards. Packaging and
cross-architecture installer builds follow runtime simplification. A Mac build is
not Linux installation evidence.
