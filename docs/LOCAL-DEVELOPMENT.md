# Local development and continuation

## Source and build

The source is this repository. Compiler/dependency downloads and private test state for this local run live on the external Crucial X9 disk, reached from the task workspace through `work/build/cache`. They are intentionally outside this repository and are not release artifacts. The large existing caches and unrelated Docker containers must not be removed as part of bridge development.

The local ignored `cabal.project.local` selects the installed SQLite 3.53.4 library and headers. Do not commit this host-specific file. `cabal.project` and the freeze file enable `direct-sqlite +systemlib`; the actual source identity is checked at runtime. `scripts/check` resolves the selected library through `pkg-config` for other machines.

From this repository in the current task, the existing build can be used with:

```sh
cabal --config-file=../../work/build/cabal.config build all \
  --builddir=../../work/build/cache/dist-newstyle
```

Large temporary files should continue to use the existing external `tmp` directory. Generic source-build instructions are in the README. A build on this Mac does not verify Linux packaging.

## Current preview

The loopback preview started on `http://127.0.0.1:61734`. It reports the real L2L Signet / Solana Devnet profile, with intake disabled. No wallet was detected in the in-app browser, and no browser signature test was performed.

The current process IDs, logs and private configuration are in `work/build/cache/local/` relative to the task workspace, two directories above this repository. `preview-processes.json` records only the worker/web process IDs and port. Before stopping a recorded PID, verify its executable and arguments still match this task; operating systems reuse PIDs. Do not kill processes by broad name or port patterns. These processes are for local inspection, not installed background services.

The worker's customer socket is `/tmp/ecx-bridge-0930/customer/api.sock`; its administrator socket is separate at `/tmp/ecx-bridge-0930/admin/api.sock`. The development web and worker run under the same local account. Actual service-user separation is still a Linux test requirement.

The preview ledger is at schema 4 and paused. The known treasury, prior probes and first application-ledger wrap are reconciled to the actual chains. The wrap exchanged 10,000 native units for 9,980 wrapped units, earned 20 native units and spent 5,000 lamports. Replaying it created no new financial rows. Do not create treasury allocations from historical gross receipts without reconciling already-spent outputs. The worker scans native history, custody-token history and fee-payer SOL history every 15 seconds. Private `/scanners` reports their cursors, last success/error and pending review. The new payment pass is implemented but normal worker scheduling and customer intake remain disabled.

The schema 1→2, 2→3 and 3→4 migrations preserve financial rows and critical/backup sequences and start paused. Consistent private snapshots were taken before the local upgrades. Schema 3 adds preparation policy/draft records; schema 4 adds treasury records and separate SOL history. Neither erases old attempts. For a manual one-shot scan, stop the verified worker PID, then run `ecx-bridge scan /absolute/private/config.json`; the exclusive ledger lock prevents concurrent workers or offline commands.

`scripts/reconcile-test-treasury.hs` is restricted to this exact public-test deployment and its known funding/probe IDs. Compile it against the pinned SQLite as described below, then pass the private configuration while the worker is stopped. It requires zero customer orders, verifies live public-chain evidence, reallocates existing receipts without double credit, books the known prior spends and compares live balances. A rerun is idempotent; it never signs, sends, creates orders or resumes the bridge. It is not a general treasury deposit or withdrawal interface.

That bootstrap now deliberately refuses this ledger because its first customer-shaped test order exists. Do not remove the restriction or delete the order to rerun it.

`scripts/public-test-wrap.hs CONFIG PRIVATE_REQUEST prepare|run|status` is the scoped acceptance tool for the single existing `public-test-wrap-1` order. Its private request/capability and client attempt are in the private local state directory. Stop the verified worker before using it. `prepare` reuses the immutable request and issued address; `run` uses the actual observer and payment pass, checks balances and finishes paused. The existing order is already paid: rerunning only reconciles it. Never delete its private record or create a new capability to force another attempt. The native tester saved exact signed bytes before funding the issued address. The tool does not open a browser, enable the customer API or configure remote backups.

## Real L2L Signet node

The isolated node directory is `work/build/cache/l2l-signet` relative to the task workspace. RPC binds only to `127.0.0.1:29432`; peer listening is disabled. The node uses the official L2L Signet challenge and the independently checked height-16000 checkpoint recorded in the example configuration. It runs separately from the user's other nodes/wallets.

Wallets `ecx-bridge-test` and `ecx-bridge-tester` are dedicated to this test. The verified native probe has its possibly-sent record at `work/build/cache/native-probe.json`; the checked-in evidence omits raw transaction/input material. Rerunning `scripts/native-smoke.py` against that exact existing record only checks or rebroadcasts the same transaction. Never delete the record to force a retry. Interrupted PSBT funding without saved signed bytes requires inspection of the wallet's locked inputs.

The node was left running for subsequent public-network tests. Its data directory and keys are on the external disk. Use the node's CLI with this **exact** data directory for an orderly stop; do not stop unrelated native nodes.

`scripts/native-unsigned-probe.hs` exercises the new native preparation module on that real Signet wallet under the ledger lock. It accepts a private configuration path and the dedicated tester's recipient, funds and validates an unsigned PSBT, then releases only the selected input locks. It has no signing or broadcasting step. The successful run left deposits/postings/obligations/attempts unchanged, as recorded in `docs/evidence/native-unsigned-probe.json`. If interrupted before cleanup, inspect the specific test wallet's locks; do not blindly unlock the wallet.

Compile this manual probe against the same pinned SQLite library as the application. The initial `runghc` invocation selected macOS's system SQLite and was correctly rejected before any wallet operation. The successful local binary was compiled with `-L/opt/homebrew/opt/sqlite/lib` and `-optl-Wl,-rpath,/opt/homebrew/opt/sqlite/lib`, into the external build cache. Keep the SQLite runtime identity check; do not disable it to run an interpreter. `scripts/check` typechecks the probe without executing it.

## Devnet setup

Private keys and setup records are under `work/build/cache/devnet`, outside source control. Do not print, copy into a screenshot, or include the keypair files in a release. The public setup manifest identifies the payer, custody owner, tester and intended mint. The setup transaction has finalized and `doctor` verifies the actual mint and custody ATA. The user supplied 10 Devnet SOL to the existing setup payer.

To reconcile the existing completed setup, run the separate example with the same absolute private directory:

```sh
cargo run --locked --manifest-path solana-helper/Cargo.toml \
  --example setup_devnet -- /absolute/private/devnet-directory
```

Use the already configured external `CARGO_HOME`/`CARGO_TARGET_DIR` for this Mac. The example checks Devnet genesis, creates an eight-decimal legacy SPL mint, two token accounts and test allocations, and saves/fsyncs exact signed bytes before sending. On a later invocation it checks the saved signature before looking at remaining funding. A pending/expired/failed setup outcome requires reconciliation; the tool deliberately refuses to create another setup transaction automatically.

The test mint authority is separate from the custody key and is not installed with the bridge helper. No official wbECX mint authority is needed or requested.

The private configuration sets both `solanaHistoryStart` and `solanaOperatingHistoryStart` to the saved real setup signature. These anchor the custody-token and fee-payer histories independently. The SOL origin must have zero opening owner balance. It also sets the separate `maxSolAccountRent` ceiling to `"2100000"` lamports; configurations must provide this field, even if new ATAs are disallowed by setting it to `"0"`. The first successful scans store the immutable origins. Every later scan must find its previous cursor; an empty or truncated history response stops progress. Do not change origins to skip unexpected transfers. The Solana observer has replayed the real setup and payouts without duplicate accounting. A real order-bound customer deposit and multi-page stopped-scanner recovery remain acceptance work.

## Manual Solana adapter probes

`scripts/solana-probe.hs` prepares a fixed three-unit public-Devnet payment using the actual helper/RPC, or verifies saved finalized evidence. Compile it with the same Cabal environment and SQLite linker settings as the native probe. `scripts/solana-smoke.py CONFIG PRIVATE_DEVNET_DIR COMPILED_PROBE` wraps it with exclusive-create, fsynced attempt files before send, bounded exact-byte rebroadcast and finalized byte/balance/cost checks. It uses the setup tester for the existing-ATA case and setup payer for the new-ATA case. It is an operator acceptance tool, not a ledger or a worker.

The initial `devnet-three-existing` signature expired without appearing in finalized history. Its original attempt and exact setup-anchored history decision remain in the private directory. The explicit `--replace-expired-existing` option validates that saved decision and names a single `devnet-three-existing-retry-1` attempt; it never overwrites the original. That replacement and `devnet-three-new` have both finalized. For this existing local run, include that flag on subsequent checks so they reconcile the saved successful replacement. Never delete an attempt to force a new signature. A missing status alone cannot authorize replacement.

The exported evidence contains public test identities and finalized transaction data, without private keys or signer paths. These programmatic probes do not prove browser-wallet support, full bridge settlement, remote recovery or canonical activation.

## Recovery and deployment

Only a consistent local SQLite snapshot has been tested. `Bridge.Backup` also has a bounded restic invocation, but real remote upload failure/acknowledgment/retention and a fresh-host/key restore remain pending. Do not infer recoverability from the existence of snapshot code.

`deploy/` contains candidate service/Caddy/helper-launcher files, not an installer. Linux dynamic linking, bubblewrap behavior, native-cookie group access, limits and service startup must be tested together. The canonical activation additionally requires operator-provided backing/float/fee allocations, approved mint policy, independent Solana verification and remote backup configuration.
