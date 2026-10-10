# Local development

Run commands from the repository root. Build with one job and reuse compiler/SDK
caches; no VM or extra node is needed for ordinary source changes.

The native freeze requires **GHC 9.14.1 (`base-4.22.0.0`) and Cabal 3.16.1.0**.
`base` ships with GHC; a solver error rejecting `base-4.20.2.0` means the selected
compiler does not match the freeze. Keep the freeze intact. With GHCup installed,
open a shell with the pinned tools (installs them if absent):

```sh
ghcup run --install --ghc 9.14.1 --cabal 3.16.1.0 -- bash
ghc --numeric-version
cabal --numeric-version
```

The versions must print `9.14.1` and `3.16.1.0`. Run the build commands below
inside that shell; `exit` returns to your original tool selection. If GHC 9.14.1
is already installed outside GHCup, select it explicitly with Cabal's
`--with-compiler=/absolute/path/to/ghc-9.14.1`, using Cabal 3.16.1.0.
The GHC JavaScript compiler has its separate 9.12.2 freeze; do not apply the native
compiler selection to the browser's internal project.

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

A native deployment host without GHC JavaScript can reuse a browser bundle from
a trusted source build of the same browser inputs. The normal root Cabal build
writes `manifest.sha256` beside its generated `web/index.html`, `web/style.css`
and `web/dist/wallet.js` under the `ecx-build-assets` component's autogen directory.
Copy that complete `web` directory to the deployment host, then build from the
repository root:

```sh
ECX_BROWSER_PREBUILT=/absolute/ecx-browser-bundle cabal build all -j1 --offline --builddir=dist-prebuilt
```

OpenSSL supplies SHA-256 on both build hosts. Before copying any assets, the hook
checks the manifest against all nine tracked browser inputs, including the browser
project/freeze files and shared `Domain.hs`/`Wire.hs`, and against all three artifact
files. It rechecks sources and copied artifacts before recording the manifest as
a Cabal output. Missing, changed or malformed bundles fail the build; the manifest
is data and supplies no executable commands or file paths. Keep the bundle intact
and obtain it from your trusted build host; hashes bind contents, not builder identity.
Use a distinct Cabal build directory when selecting a different bundle or switching
between prebuilt and source mode, because environment changes alone need not
invalidate Cabal's cache. The bundle files are tracked dependencies once selected.
Without `ECX_BROWSER_PREBUILT`, Cabal retains the full GHC JavaScript source build.

## Ubuntu source toolchain

For contributors building from source; installer users do not need these tools.
The pinned static secp256k1 prerequisite avoids Ubuntu 24.04's older library.

```sh
cd ~
mkdir ecash-bridge
cd ecash-bridge
git clone https://github.com/freewillydev/ecx-solana-bridge.git

sudo apt update
sudo apt install -y build-essential cmake jq curl pkg-config libpq-dev libgmp-dev libffi-dev \
  zlib1g-dev libssl-dev
sh ecx-solana-bridge/2-Wrap-Unwrap-Server/install/secp256k1 "$HOME/.local/share/ecx-secp256k1"
export PKG_CONFIG_PATH="$HOME/.local/share/ecx-secp256k1/prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

git clone https://github.com/emscripten-core/emsdk.git \
  "$HOME/.local/share/ecx-emsdk"

cd "$HOME/.local/share/ecx-emsdk"
./emsdk install 3.1.74
./emsdk activate 3.1.74
source ./emsdk_env.sh
ghcup config add-release-channel cross
emconfigure ghcup install ghc --set javascript-unknown-ghcjs-9.12.2

cd ~/ecash-bridge/ecx-solana-bridge/

ghcup install cabal
cabal update
ghcup run --install --ghc 9.14.1 --cabal 3.16.1.0 -- cabal build exe:ecx-bridge -j1
export PATH="$(dirname "$(ghcup run --install --ghc 9.14.1 --cabal 3.16.1.0 -- cabal list-bin exe:ecx-bridge)"):$PATH"
cd 2-Wrap-Unwrap-Server

sudo env "PATH=$PATH" ecx-bridge configure
```

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

### Isolated PostgreSQL release contracts (Ubuntu)

Run as an ordinary OS user in a dedicated disposable test checkout/host, never
with custody credentials. Put PostgreSQL server/client tools, the pinned compiler,
Cabal, OpenSSL and restic on PATH. This recipe uses a private Unix socket only;
trust authentication is confined by its 0700 directory. It refuses an existing
socket directory instead of touching an existing server. Save it as a temporary
script or run in a fresh Bash shell from the repository root:

```bash
set -euo pipefail
umask 077
export USER="$(id -un)"
export PGUSER="$USER" PGPORT=29436 PGHOST=/tmp/ecx-pg-seam
unset PGSERVICE PGPASSWORD PGDATABASE PGOPTIONS
[ "$(id -u)" -ne 0 ]
[ ! -e "$PGHOST" ]
mkdir -m 0700 "$PGHOST"
contract_root=$(mktemp -d "${TMPDIR:-/tmp}/ecx-release-contract.XXXXXXXX")
initdb -D "$contract_root/data" -A trust
trap 'pg_ctl -D "$contract_root/data" -m fast -w stop' EXIT
pg_ctl -D "$contract_root/data" -l "$contract_root/postgres.log" \
  -o "-k $PGHOST -p 29436 -c listen_addresses='' -c max_connections=25" -w start
export ECX_REBUILD_CONTRACT_READER=ecx_contract_reader
createuser --no-superuser --no-createdb --no-createrole "$ECX_REBUILD_CONTRACT_READER"
cabal build ecx-bridge:exe:ecx-bridge ecx-bridge:exe:ecx-store-check -j1 --offline
export ECX_REBUILD_EXECUTABLE="$(cabal list-bin ecx-bridge:exe:ecx-bridge)"
# Locate the SDK generated by this Cabal build, not a system library.
export ECX_REBUILD_TEST_SDK="$(find "$PWD/dist-newstyle" -name libecx_solana_sdk.so -type f -print -quit)"
[ -f "$ECX_REBUILD_TEST_SDK" ]
for mode in default fence setup setup_residue server server_canonical tls tls_canonical cache history history_progress; do
  export ECX_REBUILD_CONTRACT_DATABASE="ecx_rebuild_contract_${mode}"
  createdb "$ECX_REBUILD_CONTRACT_DATABASE"
  for migration in 001 002 003 004 005 006 007 008; do
    psql -X -v ON_ERROR_STOP=1 -d "$ECX_REBUILD_CONTRACT_DATABASE" \
      -f "2-Wrap-Unwrap-Server/migrations/$migration.sql"
  done
  psql -X -v ON_ERROR_STOP=1 -d "$ECX_REBUILD_CONTRACT_DATABASE" <<'SQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ecx_contract_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ecx_contract_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ecx_contract_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ecx_contract_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO ecx_contract_reader;
SQL
  (
    unset ECX_REBUILD_MIGRATION_ONLY ECX_REBUILD_PAYMENT_ROOTS_ONLY ECX_REBUILD_LIVE_OBSERVER_CONFIG
    unset ECX_REBUILD_SETUP_ONLY ECX_REBUILD_SETUP_RESIDUE ECX_REBUILD_SERVER_ONLY ECX_REBUILD_TLS_ONLY
    unset ECX_REBUILD_CANONICAL ECX_REBUILD_FENCE_ONLY ECX_REBUILD_NATIVE_RECOVERY_ONLY
    unset ECX_REBUILD_ENCRYPTED_NATIVE_ONLY ECX_REBUILD_CUSTODY_ONLY ECX_REPORT_CACHE_ONLY
    unset ECX_REBUILD_HISTORY_ONLY ECX_REBUILD_HISTORY_COUNT ECX_PROVISION_TEST ECX_PROVISION_CHILD ECX_FUNDED_RECOVERY_CONFIG
    case "$mode" in
      fence) export ECX_REBUILD_FENCE_ONLY=1;;
      setup) export ECX_REBUILD_SETUP_ONLY=1;;
      setup_residue) export ECX_REBUILD_SETUP_ONLY=1 ECX_REBUILD_SETUP_RESIDUE=1;;
      server) export ECX_REBUILD_SERVER_ONLY=1;;
      server_canonical) export ECX_REBUILD_SERVER_ONLY=1 ECX_REBUILD_CANONICAL=1;;
      tls) export ECX_REBUILD_TLS_ONLY=1;;
      tls_canonical) export ECX_REBUILD_TLS_ONLY=1 ECX_REBUILD_CANONICAL=1;;
      cache) export ECX_REPORT_CACHE_ONLY=1;;
      history) export ECX_REBUILD_HISTORY_COUNT=1001;;
      history_progress) export ECX_REBUILD_HISTORY_ONLY=1;;
    esac
    cabal run ecx-bridge:exe:ecx-store-check -j1 --offline
  ) >"$contract_root/$mode.log" 2>&1
  printf '%s PASS (exit 0)\n' "$mode"
done
printf 'Retained evidence and databases: %s\n' "$contract_root"
```

Expected: eleven named PASS lines, all commands exit zero, stopped isolated cluster
on shell exit. On failure retain its log/database; do not label omitted modes PASS.
No database or directory is deleted by this recipe. The owner may arrange cleanup
with Luke; never remove a socket directory owned by another run. This recipe is
source-derived; its execution against the final candidate is still required.

Migration and real-node recovery modes below need their stated historical fixtures
or disposable real node and are additional gates when their components change.
They are not covered by the eleven-mode matrix or by core QuickCheck. Never substitute
a funded ledger. Use `cabal run ecx-store-check` for packaged fixture data; direct
binary invocation needs `ecx_bridge_datadir` pointing to the server package.

| Mode | Additional input / scope |
| --- | --- |
| `ECX_REBUILD_HISTORY_ONLY=1` | Durable Solana progress, writer restart, stale CAS, rollback, checkpoint/receipt atomicity, no duplicate posting and old-binary/re-upgrade compatibility. |
| Default | Ledger, concurrency, recovery and local encrypted restic contracts |
| `ECX_REBUILD_HISTORY_COUNT=1001` | Default mode with 1,001 sequential offline refund/settlement/replay histories on one order; measures actual customer reads at increasing sizes and across the 1,000-row page boundary. Accepts 2–2,000; ordinary runs retain two refunds. No RPC or funds. |
| `ECX_REBUILD_PAYMENT_ROOTS_ONLY=1` | Populated schema-21 fixture from baseline `e684f9b`; converts through the closed Opaleye operation, compares retained records, customer views, queues and all work hashes, checks migration refusal/kill/rollback/constraints, then tests ordinary legacy-archive restoration. Ends paused on schema 22. The `child` value is private test-process plumbing. |
| `ECX_REBUILD_MIGRATION_ONLY=1` | Populated offline schema-18 copy with baseline DDL 001–005; applies 006–008 and the closed schema-22 conversion; optional `ECX_REBUILD_MIGRATION_RECOVERY_CONFIG` for read-only real-chain reconciliation |
| `ECX_REBUILD_SETUP_ONLY=1` | `ECX_REBUILD_EXECUTABLE`; optional `ECX_REBUILD_SETUP_RESIDUE=1` |
| `ECX_REBUILD_SERVER_ONLY=1` | `ECX_REBUILD_EXECUTABLE`; process, HTTP and private control |
| `ECX_REBUILD_TLS_ONLY=1` | `ECX_REBUILD_TEST_SDK`; actual HTTPS saved-decision signing |
| `ECX_REBUILD_CANONICAL=1` | With server/TLS mode: canonical Mainnet profile using offline RPC fixtures; no Mainnet sends |
| `ECX_REBUILD_FENCE_ONLY=1` | Database/filesystem ownership and sequence fencing |
| `ECX_REBUILD_NATIVE_RECOVERY_ONLY=1` | Executable, `ECX_REBUILD_NATIVE_RECOVERY_COOKIE`, `ECX_REBUILD_NATIVE_WALLET_DIRECTORY`; disposable real-node wallet |
| `ECX_REBUILD_ENCRYPTED_NATIVE_ONLY=1` | Same native recovery inputs; encrypts only its disposable wallet |
| `ECX_REBUILD_CUSTODY_ONLY=1` | With native/encrypted recovery mode and disposable DB; complete custody bundle |
| `ECX_REBUILD_LIVE_OBSERVER_CONFIG=CONFIG` | Observation-only real-chain checks with restricted native credentials |

Fresh default/setup/server/TLS/fence contracts receive 001–008; their closed
initializer installs schema 22. Do not apply 009 manually. The preserved migration
fixture on this development host is `ecx_rebuild_contract_g_legacy_roots_20261006`;
run the destructive migration test on a clone, not that baseline. It contains only
offline fixture histories, no live keys or paying services.

To reproduce that baseline, build `ecx-store-check` at `e684f9b` in an isolated
checkout and run its payment-roots mode on a fresh 001–008 disposable database.
Before the run, install a test-only deployment trigger which raises SQLSTATE
`P2221` when `NEW.schema_version=22`; this deliberately stops before committing
conversion after the old runtime has generated the histories. Drop that trigger
and function after the controlled failure, then clone the database for the current
contract. This is fixture capture, not a passing test. Keep the original untouched;
the current runtime intentionally cannot generate new payments on schema 21.

For the bounded formal check, run from `2-Wrap-Unwrap-Server/test/formal`:

```sh
java -Xmx256m -XX:+UseParallelGC -cp /path/to/tla2tools.jar tlc2.TLC -workers 1 -metadir /tmp/ecx-tlc-states -config SignerPaths.cfg SignerPaths.tla
```

Use the reviewed TLA+ 1.7.4 tools. The model checks an abstract finite state space,
not the whole implementation. See [ARCHITECTURE.md](ARCHITECTURE.md).

Record tests against their exact source/artifact and real-chain identities. Reuse
funded evidence only within its actual scope. Stop task-owned temporary processes,
retain disposable databases/wallets until cleanup is authorized, and close temporary tabs after acceptance;
preserve shared native/PostgreSQL services and funded custody.

### Capability boundary compilation checks

After building the core library, the positive control must compile; each negative
variant must fail for the named missing capability or incompatible nominal index:

```sh
cabal exec -- ghc -fno-code -package ecx-bridge -package operation-capabilities \
  2-Wrap-Unwrap-Server/test/CapabilityCompile.hs
for check in BAD_COMPILE BAD_WIDEN BAD_CALLER BAD_SEVERITY BAD_RESULT BAD_COERCE; do
  if cabal exec -- ghc -fno-code -package ecx-bridge -package operation-capabilities \
      -D"$check" 2-Wrap-Unwrap-Server/test/CapabilityCompile.hs; then
    echo "Unexpected compilation success: $check"
    exit 1
  fi
done
```

Inspect diagnostics: a missing package or syntax error is not a passing negative
test. `bridge-test` also checks actual existential dispatch, all customer/signer
routes, and mismatched caller, severity and result interpretations. These checks
are separate from PostgreSQL contracts and do not certify runtime authorization.
