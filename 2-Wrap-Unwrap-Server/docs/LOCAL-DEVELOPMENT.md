# Local development

Run commands from the repository root. Build with one job and reuse compiler/SDK
caches; no VM or extra node is needed for ordinary source changes.

```sh
cabal build all -j1 --offline
cabal test all -j1 --offline --test-show-details=direct
# Targeted bridge checks:
cabal test ecx-bridge:bridge-test -j1 --offline --test-show-details=direct
```

Omit `--offline` only when dependencies first need fetching. Prerequisites are
native GHC/Cabal, Rust/Cargo, libpq and GHC JavaScript 9.12.2/Emscripten. OpenSSL and
Python are used by the retained release-authentication tooling exercised from the
Haskell tests. Cabal builds SDK/browser inputs; there is no separate application
Cargo/npm build or WebAssembly backend.

The browser hook finds `javascript-unknown-ghcjs-ghc` on PATH or under
`~/.local/share/ecx-ghc-js-9.12.2/bin/`. Set `ECX_GHC_JS` to override it. The matching
package tool is selected explicitly. If `emcc` is absent, `ECX_EMSDK` defaults to
`~/.local/share/ecx-emsdk`. Reuse `ECX_BROWSER_BUILD_DIR`, `CARGO_HOME` and
`CARGO_TARGET_DIR` for caches on another disk. Do not delete shared caches to force
recompilation. Native and browser wire/amount types share `src/Bridge`.

## Running

With reviewed private configuration, migrated ledger, host fence and database
roles in place:

```sh
cabal run exe:ecx-bridge -- check-config /absolute/private/config.json
cabal run exe:ecx-bridge -- observe /absolute/private/config.json
```

Paying mode and the separate signer are described in [OPERATIONS.md](OPERATIONS.md).
No test fixture is a deployment template. Keep credentials, capabilities, keys,
attempt files and custody snapshots outside Git. Never use a copied database as
independent custody, lower a fence, alter saved terms or erase signed work.

## Consolidated verification

`bridge-test`, `token-test` and `pool-test` are Cabal QuickCheck/protocol suites.
The bridge suite includes actual HTTP/TLS boundaries, protected credentials,
protocol vectors and the pinned SDK's tests. `ecx-store-check` exercises closed
Opaleye fixtures against an explicitly disposable migrated PostgreSQL database and
SELECT-only role. Its existing `ECX_REBUILD_*` environment names remain stable;
they identify test modes, not another application.

Set `ECX_REBUILD_CONTRACT_DATABASE` to a fresh `ecx_rebuild_contract_*` database and
`ECX_REBUILD_CONTRACT_READER` to its restricted reader. Inspect `test/StoreCheck.hs`
for the local PG host/port and mode-specific setup before running it. It contains
financial mutations and fault DDL: never point it at a custody ledger. Use
`cabal run ecx-store-check` so Cabal supplies packaged fixture data; direct binary
invocation needs `ecx_bridge_datadir` pointing to the server package.

| Mode | Additional input / scope |
| --- | --- |
| Default | Ledger, concurrency, recovery and local encrypted restic contracts |
| `ECX_REBUILD_MIGRATION_ONLY=1` | Populated offline schema-18 copy with baseline DDL 001–005; applies 006–008; optional `ECX_REBUILD_MIGRATION_RECOVERY_CONFIG` for read-only real-chain reconciliation |
| `ECX_REBUILD_SETUP_ONLY=1` | `ECX_REBUILD_EXECUTABLE`; optional `ECX_REBUILD_SETUP_RESIDUE=1` |
| `ECX_REBUILD_SERVER_ONLY=1` | `ECX_REBUILD_EXECUTABLE`; process, HTTP and private control |
| `ECX_REBUILD_TLS_ONLY=1` | `ECX_REBUILD_TEST_SDK`; actual HTTPS saved-decision signing |
| `ECX_REBUILD_FENCE_ONLY=1` | Database/filesystem ownership and sequence fencing |
| `ECX_REBUILD_NATIVE_RECOVERY_ONLY=1` | Executable, `ECX_REBUILD_NATIVE_RECOVERY_COOKIE`, `ECX_REBUILD_NATIVE_WALLET_DIRECTORY`; disposable real-node wallet |
| `ECX_REBUILD_ENCRYPTED_NATIVE_ONLY=1` | Same native recovery inputs; encrypts only its disposable wallet |
| `ECX_REBUILD_CUSTODY_ONLY=1` | With native/encrypted recovery mode and disposable DB; complete custody bundle |
| `ECX_REBUILD_LIVE_OBSERVER_CONFIG=CONFIG` | Observation-only real-chain checks with restricted native credentials |

For the bounded formal check, run from `2-Wrap-Unwrap-Server/test/formal`:

```sh
java -Xmx256m -XX:+UseParallelGC -cp /path/to/tla2tools.jar tlc2.TLC -workers 1 -metadir /tmp/ecx-tlc-states -config SignerPaths.cfg SignerPaths.tla
```

Use the reviewed TLA+ 1.7.4 tools. The model checks an abstract finite state space,
not the whole implementation. See [ARCHITECTURE.md](ARCHITECTURE.md).

Record tests against their exact source/artifact and real-chain identities. Reuse
funded evidence only within its actual scope. Stop task-owned temporary processes,
remove disposable databases/wallets, and close temporary tabs after acceptance;
preserve shared native/PostgreSQL services and funded custody.
