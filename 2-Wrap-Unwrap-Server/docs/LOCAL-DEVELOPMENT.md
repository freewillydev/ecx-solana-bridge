# Local development

Follow [IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md) and read
[OPERATION-DSL.md](OPERATION-DSL.md) plus the preserved Main.hs before changing
handlers or interpreters. The old run diary and SQLite procedures are retained in
[Git history](https://github.com/ekulkisnek/ecx-solana-bridge/blob/aa09e1e/docs/LOCAL-DEVELOPMENT.md);
they are not current operating instructions.

## Build and tests

From the repository root, use the pinned dependencies and one build job:

```sh
cabal build all -j1 --offline
cabal test bridge-test -j1 --offline --test-show-details=failures
```

Offline builds assume cached dependencies. Cabal builds the pinned Rust SDK FFI
through its tracked hooks; Rust/Cargo remain prerequisites. SQLite and the legacy
library are retired. Preserve shared caches and private state. Cabal also builds
the browser with GHC JavaScript **9.12.2**, Emscripten **3.1.74** and its frozen
`web/cabal.project.freeze` graph. Only thin browser API bindings use JavaScript FFI;
application decisions and QR generation are Haskell. No npm step is required.

The hook finds `javascript-unknown-ghcjs-ghc` on PATH, or defaults to
`~/.local/share/ecx-ghc-js-9.12.2/bin/javascript-unknown-ghcjs-ghc`.
Set `ECX_GHC_JS` to another compiler path. If `emcc` is not on PATH, the hook uses
`ECX_EMSDK` (default `~/.local/share/ecx-emsdk`). Set `ECX_BROWSER_BUILD_DIR` to reuse
an external browser cache. The JavaScript backend uses asm.js for C inputs;
it is not the GHC WebAssembly backend. Native and browser builds both use one job.
Generated assets live under Cabal's library autogen directory; Runtime defaults
to that directory. A deployed bundle overrides it with `ECX_ASSETS`.

The PostgreSQL journal runner covers postings, ownership/row locks, backup receipts,
idempotent orders and saved policy, concurrent inventory reservations, duplicate/
partial deposits, expiry, instruction backup gates, and SQL-error rollback/fencing.
Fixtures and assertions use closed Opaleye operations. These are database contracts,
not live-chain acceptance. Generated QuickCheck properties exercise balanced
postings, failed-write atomicity, exact sequences, immutable quotes and ownership.
The same runner generates earned-fee funding/cancellation contracts for Native
and Wrapped assets: immutable terms, rejected replay conflicts, balanced holds,
exact cancellation, asset/amount bounds and pause/freshness gates. These are
funding-stage contracts; they do not prove fee signing or sending.

Use a fresh disposable database with all `migrations/postgresql/*.sql` applied in
filename order. This host uses socket `/tmp/ecx-pg-seam`, port 29436 and the current
OS user. Set `ECX_JOURNAL_CONTRACT_DATABASE` to a fresh `ecx_journal_contract_…`
database, run the binary from `cabal list-bin exe:ecx-postgres-journal-check`, then
drop that specific database. Never target an existing custody ledger.

The source-approval runner also uses only closed Opaleye fixture operations and
whole typed record comparisons. Set `ECX_SOURCE_CONTRACT_DATABASE` to a fresh
`ecx_source_approval_contract_…` database with the same migrations. It preserves
restoration, native finality/replacement, source-loss capital and exact-byte
rebroadcast/coverage contracts without signing or contacting either chain.

Other `integration/` runners cover recovery, snapshot/restore and real chains.
Read their restrictions before running them; some sign or transfer test funds.
Historical acceptance applies only to its recorded source/configuration/network.
Current release gaps are in [RELEASE-REVIEW.md](RELEASE-REVIEW.md).

## Local runtime

Use private configuration for real L2L Signet or ECX betanet with Solana Devnet.
Keep keys, cookies, credentials, ledgers, signed bytes and backups outside Git.
The root `cabal build all -j1` builds both server and frontend.
With the configured native node running and private PostgreSQL environment loaded:

```sh
scripts/start-local /absolute/private/config.json --binary /absolute/path/to/ecx-bridge
```

The launcher defaults to loopback port 61734; Ctrl-C stops its worker/web children.
Verify executable/arguments before stopping a recorded PID. Run only one paying
worker per custody identity. Respect persisted fences and retired sources; do not
enable an old clone or remove an observation-only recovery override to progress an order.

`PGREADUSER` must differ from `PGUSER`. Grant only schema usage, table SELECT. Startup rejects elevated roles, public-schema creation, table/
column writes and sequence use, including inherited grants. Readers use
`PGREADPASSWORD` only when supplied; safe operations use read-only transactions.
Do not weaken these checks to start a misconfigured instance.

The dedicated signer uses `signerPort` (8081 in examples) on 127.0.0.1.
`signerAuthFile` names a 64-character hexadecimal token generated from 32 random
bytes, stored outside Git. Both services may read that file (0600, or root-owned
0640 with a dedicated worker/signer group); nobody else may read or write it.
Its containing directory must reject group/world writes. The adjacent `.pem`
certificate is the worker's sole TLS trust anchor; the adjacent `.key` belongs
only to the signer, mode 0600. Generate the certificate with an IP subjectAltName
for 127.0.0.1 and maintain its expiry. Do not reuse a key or token from a fixture.
Start `ecx-bridge signer CONFIG PRIVATE_SIGNER_CONFIG` under its separate
SELECT-only PostgreSQL role before enabling the paying worker. The worker uses
Servant ClientM, certificate validation and BasicAuth only from its critical DSL
evaluator; it disables redirects, proxies and retries. Rotate token/certificate
with the worker paused and restart the signer; preserve its custody keys and ledger.
Existing installed services still require the dedicated-signer deployment update.

New orders charge 1% both ways; saved quotes keep their terms. Check inventory,
fee budgets, deadlines and exact network/token identities before real tests.
Reuse saved orders and exact attempts after interruption. Never reset a ledger,
delete an attempt or regenerate a capability to force a retry.

Use at most one bounded task VM when needed and stop it afterwards. Packaging and
cross-architecture installer builds follow runtime simplification. A Mac build is
not Linux installation evidence.

PostgreSQL migrations and the typed Opaleye records in `src/Bridge/Postgres/Schema.hs`
are the maintained schema sources. The retired SQLite importer, translators and
intermediate schema manifest remain at Git revision `6d293a3`. Do not regenerate
the current schema from SQLite; change it with a reviewed forward migration and
run the database contracts against the resulting schema.
