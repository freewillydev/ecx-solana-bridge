# ECX Bridge

A small inventory bridge: one Haskell/Servant application, two chain adapters, one SQLite ledger, and a thin browser interface. A separate Rust executable uses official Solana SDK and SPL interface crates to construct and sign a fixed transaction format. No custom blockchain or token program.

**Development checkpoint — not ready for public custody.** Both ledger-driven directions have completed on real L2L Signet / Solana Devnet, alongside a full refund of a late deposit. The redemption survived a process interruption after broadcast and settled the same native transaction. The code builds and 133 tests pass. Browser signing, full reconciliation/recovery and Linux deployment remain unfinished. Customer intake and signing routes are disabled in code. See [STATUS.md](docs/STATUS.md) for the evidence and outstanding work.

## Components

| Component | Responsibility |
| --- | --- |
| `ecx-bridge worker` | Owns the ledger and private configuration. Serves separate customer and administrator Unix sockets. |
| `ecx-bridge serve` | Serves static assets and proxies the typed customer API. Binds only to loopback. Receives no key or database path. |
| `Bridge.Budget` | Immutable order fee ceilings, separate payout/refund allowances, rolling 24-hour operating caps and private budget reporting. |
| `Bridge.Ledger` | Quotes, inventory reservations, protected principal, obligations, exact signed attempts, fee accounting, backup coverage, audit records. |
| `Bridge.Native` / `Bridge.Solana` | Real node/RPC identity checks and bounded calls. Native destinations use daemon script classification and ownership checks. Adapter integration is incomplete. |
| `Bridge.Observer` | Native wallet history and separate finalized Solana token/SOL histories; atomic evidence/cursors, quarantined unknown activity, independent-provider deposit checks. |
| `Bridge.NativePayment` / `Bridge.SolanaPayment` / `Bridge.Payment` | Validate outgoing transactions and native quote amounts with the real daemon, reserve operating costs, save exact preparation requests/drafts before signing and signed bytes afterward. Solana simulations use unsigned copies. |
| `Bridge.Settlement` | Recheck the bound source, journal broadcast intent, enforce backup coverage, send recorded bytes and book verified outcomes. Worker scheduling remains behind the disabled acceptance gate. |
| `Bridge.Deposit` | Build and validate an unsigned order-bound Solana deposit, with customer token/SOL balance, fee, expiry and backup checks. |
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
# Exclusive ledger access: stop the worker before this one-shot scan.
cabal run ecx-bridge -- scan /absolute/private/config.json
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
- Live native observer recorded the faucet receipt and quarantined the standalone payment. A repeated scan changed no deposits, postings or obligations: [replay evidence](docs/evidence/native-observer-replay.json).
- Live unsigned PSBT preparation passed the new recipient/change/input/fee validator with a 141-unit fee. It did not sign or broadcast, and released its selected input lock: [evidence](docs/evidence/native-unsigned-probe.json).
- Exact three-base-unit unsigned/signed Solana fixtures are checked against an independent Haskell decoder and Ed25519 verification. These are codec tests, **not Devnet transaction evidence**.
- The real eight-decimal Devnet test mint was created by `solana-helper/examples/setup_devnet.rs`: [setup evidence](docs/evidence/devnet-setup.json). Mint authority remains separate from custody.
- Real three-unit Devnet transfers finalized to an [existing account](https://explorer.solana.com/tx/2GobRapeVX92w9QKpyomVvTLswXGjvkxdbvu9Azk5CCXPbujUfEshdVEccq9QGFkboaqAS1VcgiDWvB7giC9tCG3?cluster=devnet) and a [new recipient account](https://explorer.solana.com/tx/4kjhetrGow3ty6446oBCzSstVUtp6GGPyWeJcB63sZyKNK8eoosHvEwww6h6cQ9dpLZXK2tf5aBJHC8FrPVZE8aD?cluster=devnet). Haskell checks matched the recorded bytes, amounts, fees and rent. The first expired attempt and the history decision preceding its replacement are retained in [evidence](docs/evidence/solana-devnet-expired-attempt.json). These are standalone adapter probes, not bridge orders.
- The Solana observer scanned the actual setup and payouts; replay created no duplicate entries: [evidence](docs/evidence/solana-observer-replay.json).
- The known public-test funding and prior probes are now reconciled to the ledger, including SOL fees and recipient-account rent. Allocations move observed receipts instead of crediting them twice; a repeated reconciliation left financial records unchanged: [balances](docs/evidence/test-treasury-reconciliation.json), [replay](docs/evidence/test-treasury-replay.json). The separate SOL scanner rejects a history origin with omitted opening funds: [real-network check](docs/evidence/solana-operating-origin-check.json).
- The first application-ledger wrap completed from a real [Signet deposit](https://explorer.signet.drivechain.info/tx/e5e565c3d87e79dba7c0f2f8d45ad07e6449051bcfe16c69f05226ac6d7ce737) to a finalized [Devnet payout](https://explorer.solana.com/tx/35u82cFNK2RZsiFpSYPGr26UkWP8FH4CgStxNB8LJSuVfvAcbAfpT5nWnG6BkWeNTVPSTK88k5NKbEaEizGn9Yip?cluster=devnet). The payment pass handled source checks, signing, persistence, broadcast and settlement. Custody balances matched afterward, and replay changed no financial records: [order evidence](docs/evidence/first-ledger-wrap.json), [replay](docs/evidence/first-ledger-wrap-replay.json). This used the scoped command-line acceptance tool, not a browser wallet or enabled customer API.
- A real Devnet deposit first observed after its immutable deadline was returned in full. The rate-limited refund attempt expired; the application proved absence through finalized, setup-anchored token and fee-payer histories before one replacement. The original attempt and all preparation generations remain saved: [refund and expiry evidence](docs/evidence/late-ledger-refund.json), [schema migration](docs/evidence/expiry-migration.json). This used the primary public-Devnet RPC; independent-provider canonical acceptance remains outstanding.
- The reverse conversion accepted 10,000 wrapped units and paid 9,900 native units, booking a 100-unit token bridge fee and a 141-unit native network fee. Its actual [Signet payout](https://explorer.signet.drivechain.info/tx/88c8c46cc3c6f34e880ffc3978c3095159059ef663c2e1573ebcf2839c3d4350) settled after the acceptance process was terminated in the mempool phase and restarted. All custody balances matched: [redemption evidence](docs/evidence/first-ledger-redemption.json), [interruption](docs/evidence/native-payout-interruption.json).
- Replaying all three completed orders changed no financial records. The normal worker then restarted with healthy scanners and authenticated order reads, while public readiness remained disabled: [replay](docs/evidence/both-directions-replay.json), [restart](docs/evidence/both-directions-restart.json).

The native smoke script is restricted to the real L2L Signet and two dedicated test wallets. It persists exact signed bytes before sending. It is an integration probe, not a ledger-driven bridge.

## Design and next work

[Contracts and accounting](docs/CONTRACTS.md), [implementation status](docs/STATUS.md), and [local operation](docs/LOCAL-DEVELOPMENT.md) distinguish implemented behavior from planned behavior. Candidate service files are in `deploy/`; they are not a tested distribution. There is no published installer or release URL yet.

MIT license for this repository. Dependency licenses remain their respective owners' licenses. License metadata is inventoried; release notice assembly and independent dependency/security review are still pending.
