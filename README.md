# ECX Bridge

A small inventory bridge: one Haskell/Servant application, two chain adapters, one SQLite ledger, and a thin browser interface. A separate Rust executable uses official Solana SDK and SPL interface crates to construct and sign a fixed transaction format. No custom blockchain or token program.

**Development checkpoint — the bridge is not operational.** The code compiles and the financial-state tests pass. The real L2L Signet node and native PSBT payment have been exercised. Automated observers, settlement/reconciliation, Linux deployment, browser-wallet acceptance, and full recovery remain unfinished. Customer intake and signing routes are disabled in code. See [STATUS.md](docs/STATUS.md) for the evidence and outstanding work.

## Components

| Component | Responsibility |
| --- | --- |
| `ecx-bridge worker` | Owns the ledger and private configuration. Serves separate customer and administrator Unix sockets. |
| `ecx-bridge serve` | Serves static assets and proxies the typed customer API. Binds only to loopback. Receives no key or database path. |
| `Bridge.Ledger` | Quotes, inventory reservations, protected principal, obligations, exact signed attempts, fee accounting, backup coverage, audit records. |
| `Bridge.Native` / `Bridge.Solana` | Real node/RPC identity checks and bounded calls. Adapter integration is incomplete. |
| `ecx-solana-helper` | Fixed mint/custody configuration; exact integer amounts; checked transfer, signed memo, recipient ATA creation. No RPC client. |
| `web/` | Wallet Standard discovery, immutable order requests, recovery links, status display. No frontend framework or Node server. |

Native signing belongs to the official daemon wallet. Solana mint authority and LP/backing keys do not belong to the bridge runtime. Host compromise can compromise a hot wallet; this project makes no claim of perfect security or independent security review.

## Build and verify

Tested locally with GHC 9.14.1, Cabal 3.16.1.0, Rust 1.97.1, SQLite 3.53.4 and Node 25.4.0 on macOS arm64. Ubuntu 24.04 is the intended server target and has **not** yet passed the build/service gate. All three dependency graphs are locked; [the manifest](docs/dependencies.json) records versions, package licenses and available source checksums.

From this directory, with those tools installed:

```sh
./scripts/check
```

The script builds the application/helper/assets, runs the financial and wire-format tests, checks TypeScript and Rust formatting, and audits the declared npm graph. It requires `pkg-config` to select SQLite 3.53.4, and uses that installation's library, headers and CLI. The worker verifies the actual SQLite source identity at startup. On a Mac with that version already installed through Homebrew, select it with `PKG_CONFIG_PATH="$(brew --prefix sqlite)/lib/pkgconfig" ./scripts/check`. The live application does not require npm. This script is a source-build check, not a verified server installer.

```sh
cabal run ecx-bridge -- version
cabal run ecx-bridge -- check-config /absolute/private/config.json
cabal run ecx-bridge -- doctor /absolute/private/config.json
```

Copy `config/l2l-devnet.example.json` into a private directory and replace every required value with the actual deployment inputs. The example deliberately contains no usable keys or invented mint. `doctor` checks actual chain identity, synchronization, mint and token-account policy; success does not certify settlement readiness.

To inspect the paused development interface:

```sh
cabal run ecx-bridge -- worker /absolute/private/config.json
# In another terminal; use the same configured customer socket:
cabal run ecx-bridge -- serve /absolute/customer/api.sock 8096 /absolute/path/to/ecx-bridge/web
```

Build the browser assets first. Open `http://127.0.0.1:8096`. Administrator routes are unavailable through that public proxy. Different Unix users and Linux sandbox enforcement still need testing on the server; local socket tests alone do not prove service-user isolation.

## Public-network evidence

- Real L2L Signet PSBT payment: [transaction](https://explorer.signet.drivechain.info/tx/b2278e8dd0be7be001a5630545ddb73c83423ee1ee7dbd0327675e27f1642bd3), [saved evidence](docs/evidence/signet-probe.json).
- Exact three-base-unit unsigned/signed Solana fixtures are checked against an independent Haskell decoder and Ed25519 verification. These are codec tests, **not Devnet transaction evidence**.
- Devnet setup is prepared in `solana-helper/examples/setup_devnet.rs`. Actual mint creation and transfers are pending test SOL. This example is an operator tool, not part of the custody executable.

The native smoke script is restricted to the real L2L Signet and two dedicated test wallets. It persists exact signed bytes before sending. It is an integration probe, not a ledger-driven bridge.

## Design and next work

[Contracts and accounting](docs/CONTRACTS.md), [implementation status](docs/STATUS.md), and [local operation](docs/LOCAL-DEVELOPMENT.md) distinguish implemented behavior from planned behavior. Candidate service files are in `deploy/`; they are not a tested distribution. There is no published installer or release URL yet.

MIT license for this repository. Dependency licenses remain their respective owners' licenses. License metadata is inventoried; release notice assembly and independent dependency/security review are still pending.
