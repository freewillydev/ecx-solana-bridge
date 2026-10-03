# Local development

Use the [rebuild guide](../rebuild/README.md) for the current source map, private
configuration, PostgreSQL contracts, startup, migration and recovery commands.
Older deployment/integration tools still target the baseline; they are not an
alternate way to initialize or run the rebuilt worker.

## Build once, reuse caches

Run from the repository root:

```sh
cabal build all -j1 --offline
cabal test all -j1 --offline --test-show-details=direct
```

Omit `--offline` only when dependencies must first be fetched. Native GHC, Cabal,
Rust/Cargo, libpq and GHC JavaScript 9.12.2/Emscripten are prerequisites. OpenSSL
is needed by certificate/release tests. Cabal hooks compile the bounded Rust SDK
and Haskell browser; no separate Cargo or npm build is required. The rebuilt
QuickCheck suite also runs the pinned SDK tests against its existing Cargo cache.

The browser hook finds `javascript-unknown-ghcjs-ghc` on PATH or defaults to
`~/.local/share/ecx-ghc-js-9.12.2/bin/javascript-unknown-ghcjs-ghc`.
Set `ECX_GHC_JS` for a different compiler location. The matching package tool is
selected with Cabal's `--with-hc-pkg`. If `emcc` is not on PATH, the hook uses
`ECX_EMSDK` (default `~/.local/share/ecx-emsdk`). This is the JavaScript backend,
not WebAssembly. Browser bindings, fee arithmetic, QR and order recovery are Haskell.

Reuse `ECX_BROWSER_BUILD_DIR`, `CARGO_HOME` and `CARGO_TARGET_DIR` when caches live
on another disk. Build one job at a time. Generated SDK/browser paths come from
`ecx-build-assets`; `ECX_ASSETS` may select a deployed asset bundle. Do not delete
shared caches or run extra VMs/services to force a build.

## Run the actual application

With reviewed private configuration and PostgreSQL environment already set:

```sh
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- check-config /absolute/private/config.json
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- observe /absolute/private/config.json
```

The configuration owns `serverPort`. The obsolete Python `start-local` wrapper
is removed. Existing migrated ledger and host-fence state are required; startup
never creates a replacement for missing custody history. Observe mode cannot
create orders or send payouts. Paying mode starts paused and requires guarded
operator resume plus its separate authenticated signer; see the rebuild guide.

Keep keys, capabilities, credentials, exact signed attempts and backups outside
Git. Run only one paying worker per custody identity. A duplicate database does
not create independent custody. Never lower a fence, erase attempts, change saved
quotes or generate another deposit to force a stuck payment through.

Use distinct SELECT-only reader/signer PostgreSQL identities, restricted native
worker RPC credentials and separately protected signing keys. Local same-user
acceptance does not prove cross-user isolation. Separate processes alone do not
prevent access to a readable signing credential.

## Verification

The three Cabal suites cover bridge, token administration and liquidity tools.
The rebuilt bridge suite owns monetary, wire, adapter, HTTP, signer, credential,
TLS and SDK regressions; the duplicate baseline Hspec suite is retired.
PostgreSQL contracts use closed Opaleye fixtures in `rebuild/test/StoreCheck.hs`,
against explicitly disposable migrated databases only. Their commands and modes
are in the rebuild guide. Never point a fixture runner at an existing custody ledger.

Compiler/protocol/database tests do not prove real-chain or wallet acceptance.
Record funded results against actual identities, transactions and source revisions;
resume interrupted work from its saved order and exact attempt. Inspect task-owned
processes before stopping them, close temporary browser tabs, and preserve shared
nodes/PostgreSQL. Packaging and clean Linux installation remain the final phase.
