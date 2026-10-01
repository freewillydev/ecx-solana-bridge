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

The public preview ledger is newly initialized, empty and paused. The standalone network probe's receipt/payment is not represented as application float. Do not create treasury allocations from a wallet's historical gross receipts without reconciling already-spent outputs.

## Real L2L Signet node

The isolated node directory is `work/build/cache/l2l-signet` relative to the task workspace. RPC binds only to `127.0.0.1:29432`; peer listening is disabled. The node uses the official L2L Signet challenge and the independently checked height-16000 checkpoint recorded in the example configuration. It runs separately from the user's other nodes/wallets.

Wallets `ecx-bridge-test` and `ecx-bridge-tester` are dedicated to this test. The verified native probe has its possibly-sent record at `work/build/cache/native-probe.json`; the checked-in evidence omits raw transaction/input material. Rerunning `scripts/native-smoke.py` against that exact existing record only checks or rebroadcasts the same transaction. Never delete the record to force a retry. Interrupted PSBT funding without saved signed bytes requires inspection of the wallet's locked inputs.

The node was left running for subsequent public-network tests. Its data directory and keys are on the external disk. Use the node's CLI with this **exact** data directory for an orderly stop; do not stop unrelated native nodes.

## Devnet setup

Private keys and setup records are under `work/build/cache/devnet`, outside source control. Do not print, copy into a screenshot, or include the keypair files in a release. The public setup manifest identifies the payer, custody owner, tester and intended mint. A generated mint key is not an on-chain mint; `doctor` currently confirms it is missing.

When real Devnet funding is available, run the separate example with the absolute private directory:

```sh
cargo run --locked --manifest-path solana-helper/Cargo.toml \
  --example setup_devnet -- /absolute/private/devnet-directory
```

Use the already configured external `CARGO_HOME`/`CARGO_TARGET_DIR` for this Mac. The example checks Devnet genesis, creates an eight-decimal legacy SPL mint, two token accounts and test allocations, and saves/fsyncs exact signed bytes before sending. On a later invocation it checks the saved signature before looking at remaining funding. A pending/expired/failed setup outcome requires reconciliation; the tool deliberately refuses to create another setup transaction automatically.

The test mint authority is separate from the custody key and is not installed with the bridge helper. No official wbECX mint authority is needed or requested.

## Recovery and deployment

Only a consistent local SQLite snapshot has been tested. `Bridge.Backup` also has a bounded restic invocation, but real remote upload failure/acknowledgment/retention and a fresh-host/key restore remain pending. Do not infer recoverability from the existence of snapshot code.

`deploy/` contains candidate service/Caddy/helper-launcher files, not an installer. Linux dynamic linking, bubblewrap behavior, native-cookie group access, limits and service startup must be tested together. The canonical activation additionally requires operator-provided backing/float/fee allocations, approved mint policy, independent Solana verification and remote backup configuration.
