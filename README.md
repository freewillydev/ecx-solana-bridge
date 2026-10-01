# ECX Bridge

A small inventory bridge: one Haskell/Servant application, two chain adapters, one SQLite ledger, and a thin browser interface. A separate Rust executable uses official Solana SDK and SPL interface crates to construct and sign a fixed transaction format. No custom blockchain or token program.

**Local public-test build — L2L Signet / Solana Devnet.** The explicit `test-worker` command connects the customer API to the existing order, ledger and payment engine. The browser provides deposit instructions, Wallet Standard signing, saved orders, status updates and transaction links. Both real-chain directions have completed through the customer HTTP API and running worker; a clean launcher restart preserved the ledger and completed order views. The application builds and 367 Haskell examples pass. Browser-wallet acceptance, complete recovery, Linux installation and independent review remain outstanding. Canonical intake stays disabled. See [STATUS.md](docs/STATUS.md) for evidence and remaining work.

## Components

| Component | Responsibility |
| --- | --- |
| `ecx-bridge worker` / `test-worker` | Owns the ledger and private configuration. Ordinary mode observes while paused; explicit public-test mode accepts orders and pays them. Both serve separate customer and administrator Unix sockets. |
| `ecx-bridge serve` | Serves static assets and proxies the typed customer API. Binds only to loopback. Receives no key or database path. |
| `Bridge.Budget` | Immutable order fee ceilings, separate payout/refund allowances, rolling 24-hour operating caps and private budget reporting. |
| `Bridge.Ledger` | Quotes, inventory reservations, protected principal, obligations, exact signed attempts, fee accounting, backup coverage, audit records. |
| `Bridge.Native` / `Bridge.Solana` | Real node/RPC identity checks and bounded calls. Native destinations use daemon script classification and ownership checks. Adapter integration is incomplete. |
| `Bridge.Observer` | Native wallet history and separate finalized Solana token/SOL histories; atomic evidence/cursors, quarantined unknown activity, independent-provider deposit checks. |
| `Bridge.Reconciliation` | Compare the journal and verified unsettled outgoing effects with custody balances at checked history positions; invalidate stale checks and pause on discrepancies. |
| `Bridge.Recovery` | Run paused observation, recorded-payment reconciliation, native input-lock reconstruction and custody checks; cancel an exact unsigned generation or approve restored source work against its saved state, retaining funds and attempts. |
| `Bridge.Reorg` | Recheck native source eligibility and settlement finality against the real wallet and durable scans; journal reversible source deficits and same-payment reconfirmation. Ambiguous evidence remains under review. |
| `Bridge.NativePayment` / `Bridge.SolanaPayment` / `Bridge.Payment` | Validate outgoing transactions and native quote amounts with the real daemon, reserve operating costs, save exact preparation requests/drafts before signing and signed bytes afterward. Solana simulations use unsigned copies. |
| `Bridge.NativeReplacement` | Validate and sign exact higher-fee templates; observe every member of the shared-input family. The private replacement signing/send command remains gated pending live acceptance. |
| `Bridge.Settlement` | Recheck the bound source, journal broadcast intent, enforce backup coverage, send recorded bytes and book verified outcomes. The paused worker reconciles saved attempts; explicit public-test mode also schedules new payments. |
| `Bridge.Deposit` | Build and validate an unsigned order-bound Solana deposit, with customer token/SOL balance, fee, expiry and backup checks. |
| `Bridge.Admission` | Solana wallet/ATA policy, balances, fee/rent estimates and unsigned simulation before a new order reserves funds. |
| `Bridge.Order` | Both chain admission checks, durable native allocation claims, label recovery, immutable memo/address binding and first-exposure checks. |
| `ecx-solana-helper` | Fixed mint/custody configuration; exact integer amounts; checked transfer, signer-bound memo, recipient ATA creation. Unsigned deposit/payout previews do not read the signer. No RPC client. |
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
# Scan and reconcile all custody balances; leave the deployment paused.
cabal run ecx-bridge -- reconcile /absolute/private/config.json
# Also book verified outcomes of recorded payments, without signing or sending.
cabal run ecx-bridge -- recover /absolute/private/config.json
```

Copy `config/l2l-devnet.example.json` into a private directory and replace every required value with the actual deployment inputs. The example deliberately contains no usable keys or invented mint. `doctor` checks actual chain identity, synchronization, mint and token-account policy; success does not certify settlement readiness.

To run the local public-test product after configuring and funding the real nodes and wallets:

```sh
./scripts/start-local /absolute/private/config.json --binary /absolute/path/to/ecx-bridge
```

Build the browser assets first. Open `http://127.0.0.1:61734`; Ctrl-C stops both child processes. The launcher accepts only `L2LSignetDevnet` with `backupRequired: false`. It starts the existing `test-worker` and loopback web proxy. Startup reconciles the ledger and checks custody before enabling transfers; unresolved or reviewed payments keep it paused. A later operational pause requires inspection and is not automatically cleared. Routine history-head advancement temporarily blocks intake and payment scheduling until the next fresh custody check. Use `worker` instead for observation-only operation.

Native → wrapped orders display an exact Signet deposit address and amount. Wrapped → native orders bind the connected Devnet wallet and request its signature on the validated deposit transaction. Orders and private recovery links survive a page reload. If admission is temporarily unavailable, retry the saved request; it keeps the same idempotency key.

Administrator routes are unavailable through the public proxy. Different Unix users and Linux sandbox enforcement still need testing on the server. This command starts a configured local build; the clean-server installer remains a separate delivery gate.

For local operator fee top-ups, use the documented private [funding procedure](docs/LOCAL-DEVELOPMENT.md#operator-fee-funding-for-local-tests). It allocates an already observed Devnet SOL receipt; it cannot credit invented funds or customer principal.

## Public-network evidence

- **Current product acceptance:** two orders created through the customer HTTP API and paid automatically by `test-worker`, with all three custody balances matching. A clean launcher restart retained every financial row and both completed orders. [Transfer/restart evidence](docs/evidence/local-product-transfers.json), [API/proxy checks](docs/evidence/local-product-http.json), [preserved-ledger startup](docs/evidence/local-product-launch.json). Deposits used the dedicated native wallet and official-SDK Devnet tester; browser-wallet acceptance remains separate.
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
- Schema 9 preserved every financial row and critical sequence. The ongoing custody check matched actual native, wrapped-token and operating-SOL balances twice across reopening, then passed in the restarted worker: [evidence](docs/evidence/custody-reconciliation.json). In-flight, failed-payment, rent, changing-history and discrepancy paths have offline contract coverage; no new payment was sent during this check.
- The ordinary paused worker recovered a real redemption after the submitting process exited. It first matched the unconfirmed 9,900-unit payout plus its 141-unit fee against custody, then settled that same [native transaction](https://explorer.signet.drivechain.info/tx/c9083bb991bb97ea2c402cb9508b2ce14a9889cea4464bd5ba27202b7783c6c6) once after confirmation. Completed recovery replay changed no financial records; earlier orders were preserved and all custody checks passed: [evidence](docs/evidence/paused-worker-recovery.json). This is worker-process recovery and live native in-flight evidence, not host-loss restore or reorg acceptance.

The dedicated native daemon was also stopped and restarted after saving a real unsigned redemption draft. The ordinary paused worker restored exactly the lost input locks without signing or changing financial records. After cancellation retained its funds, one generation-one payout confirmed; completed recovery replay changed no financial records. [Node-restart evidence](docs/evidence/native-lock-recovery.json). Signed/unseen, evicted-payment and false-lock-acknowledgment cases have offline contract coverage; host-loss restore remains separate work.

An isolated copy of an earlier snapshot was replayed against the real chains after a redemption it did not contain had completed. The receipt remained unallocated, the unknown native payout required review, and reopening the copy added no duplicate financial records. The live ledger and original snapshot were unchanged. [Stale-snapshot evidence](docs/evidence/stale-snapshot-quarantine.json). This verifies quarantine for that missing order; remote backup selection, key restore and signer fencing remain unfinished.

The dedicated node's local view of an actual public Signet block was disconnected and restored. The existing payout moved back to the mempool, its customer status became `NeedsReview`, and the paused worker retained that review across restart. After restoration it reconfirmed the same payment with no new attempt or monetary posting. [Finality evidence](docs/evidence/native-finality-recovery.json). This was a local node-view test, not a public consensus reorg.

The original wrap's actual source block was also disconnected and restored locally. Its completed order entered review, retained that review through worker restart, and returned to `Paid` after restoration. All eight orders, seven attempts and financial/binding rows were preserved. [Source recovery evidence](docs/evidence/native-source-recovery.json). The deep disconnection left the source absent from the mempool; the application correctly treated that as unavailable evidence, not a proven double spend. Deficit postings for a proven native conflict and their reversal have offline contract coverage. Permanent loss treatment, missing destination value, replacement families and complete restore/resume remain unfinished.

The subsequent operator-approval migration preserved that ledger and refused to revive the completed wrap. The normal worker restarted with matching real-chain custody and unchanged financial records. [Upgrade/refusal evidence](docs/evidence/source-approval-upgrade.json). Successful restoration approval, stale-work refusal and the new approval's backup barrier have offline contract coverage; they do not establish full service resume.

The native smoke script is restricted to the real L2L Signet and two dedicated test wallets. It persists exact signed bytes before sending. It is an integration probe, not a ledger-driven bridge.

## Design and next work

[Contracts and accounting](docs/CONTRACTS.md), [implementation status](docs/STATUS.md), and [local operation](docs/LOCAL-DEVELOPMENT.md) distinguish implemented behavior from planned behavior. Candidate service files are in `deploy/`; they are not a tested distribution. There is no published installer or release URL yet.

MIT license for this repository. Dependency licenses remain their respective owners' licenses. License metadata is inventoried; release notice assembly and independent dependency/security review are still pending.
