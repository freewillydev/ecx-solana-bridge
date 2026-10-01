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

The preview ledger is at schema 10. The known treasury, prior probes and first application-ledger wrap are reconciled to the actual chains. The wrap exchanged 10,000 native units for 9,980 wrapped units, earned 20 native units and spent 5,000 lamports. A later 10,000-unit Solana deposit was first observed after its deadline and fully refunded; its expired refund attempt and one replacement are preserved. Two later one-minute provisioning quotes expired unfunded, with every hold released. Do not create treasury allocations from historical gross receipts without reconciling already-spent outputs. Each worker loop scans native history, custody-token history and fee-payer SOL history, expires provisional quote holds, reconciles custody, then waits 15 seconds. Private `/scanners` reports history health; `/audit` includes the custody check. Normal payment scheduling and customer intake remain disabled. Consult the latest status/evidence before resuming an acceptance process.

The schema 1→2, 2→3, 3→4, 4→5, 5→6 and 6→7 migrations preserve financial rows and critical/backup sequences and start paused. Consistent private snapshots were taken before the local upgrades. Schema 3 adds preparation policy/draft records; schema 4 adds treasury records and separate SOL history; schema 5 adds preparation generations and immutable expiry evidence; schema 6 requires a journaled operator approval before replacement. No migration erases old attempts. The actual 4→5 upgrade preserved hashes of every existing financial table, including pending signed bytes: [evidence](evidence/expiry-migration.json). For a manual one-shot scan, stop the verified worker PID, then run `ecx-bridge scan /absolute/private/config.json`; the exclusive ledger lock prevents concurrent workers or offline commands.

`scripts/reconcile-test-treasury.hs` is restricted to this exact public-test deployment and its known funding/probe IDs. Compile it against the pinned SQLite as described below, then pass the private configuration while the worker is stopped. It requires zero customer orders, verifies live public-chain evidence, reallocates existing receipts without double credit, books the known prior spends and compares live balances. A rerun is idempotent; it never signs, sends, creates orders or resumes the bridge. It is not a general treasury deposit or withdrawal interface.

That bootstrap now deliberately refuses this ledger because its first customer-shaped test order exists. Do not remove the restriction or delete the order to rerun it.

`scripts/public-test-order.hs CONFIG PRIVATE_REQUEST prepare|transaction|run|refund|status` is restricted to the existing deployment, dedicated tester, 10,000-unit amount and four named sequential acceptance orders. `public-test-wrap-1` completed. `public-test-redeem-1` was observed late and refunded. `public-test-redeem-2` completed the reverse conversion, including a process interruption between native broadcast and confirmation. The private request/capabilities and client attempts are in the private local state directory. Stop the verified worker before using it. `prepare` reuses the immutable request and instruction; `transaction` builds an unsigned source transfer; `run` uses actual observers and the payment pass, verifies balances and finishes paused. It permits at most two balance rescans when a deposit finalizes between history and account reads, never ignores a persistent discrepancy, and is not general in-flight reconciliation. The `refund` mode is bound to the single recorded late receipt. Never delete private records, reset deadlines or create new capabilities to force a retry. The tool does not open the customer API or configure remote backups.

`solana-helper/examples/deposit_devnet.rs PRIVATE_DEVNET_DIR PREPARED_JSON NEW_ATTEMPT_JSON` is a separate SDK test client. It independently compares the entire unsigned message against the exact known tester/mint/custody/amount/order, then signs with the dedicated tester and exclusively creates/fsyncs a private attempt file. It neither contacts RPC nor broadcasts, and refuses an existing output path. The test driver submits those saved bytes and launches the observer immediately; restarting an order must reuse its records. The first client attempt expired before submission and was retained with its absence evidence before an explicit replacement. This client replacement is separate from the application's schema-5 outgoing-payment recovery.

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

The private configuration sets both `solanaHistoryStart` and `solanaOperatingHistoryStart` to the saved real setup signature. These anchor the custody-token and fee-payer histories independently. The SOL origin must have zero opening owner balance. It also sets the separate `maxSolAccountRent` ceiling to `"2100000"` lamports; configurations must provide this field, even if new ATAs are disallowed by setting it to `"0"`. The first successful scans store the immutable origins. Every later scan must find its previous cursor; an empty or truncated history response stops progress. Do not change origins to skip unexpected transfers. The observer has verified real order-bound deposits and replayed real setup and payouts without duplicate accounting. Multi-page stopped-scanner recovery still needs real acceptance coverage.

## Manual Solana adapter probes

`scripts/solana-probe.hs` prepares a fixed three-unit public-Devnet payment using the actual helper/RPC, or verifies saved finalized evidence. Compile it with the same Cabal environment and SQLite linker settings as the native probe. `scripts/solana-smoke.py CONFIG PRIVATE_DEVNET_DIR COMPILED_PROBE` wraps it with exclusive-create, fsynced attempt files before send, bounded exact-byte rebroadcast and finalized byte/balance/cost checks. It uses the setup tester for the existing-ATA case and setup payer for the new-ATA case. It is an operator acceptance tool, not a ledger or a worker.

The initial `devnet-three-existing` signature expired without appearing in finalized history. Its original attempt and exact setup-anchored history decision remain in the private directory. The explicit `--replace-expired-existing` option validates that saved decision and names a single `devnet-three-existing-retry-1` attempt; it never overwrites the original. That replacement and `devnet-three-new` have both finalized. For this existing local run, include that flag on subsequent checks so they reconcile the saved successful replacement. Never delete an attempt to force a new signature. A missing status alone cannot authorize replacement.

The exported evidence contains public test identities and finalized transaction data, without private keys or signer paths. These programmatic probes do not prove browser-wallet support, full bridge settlement, remote recovery or canonical activation.

## Operator retry approval

With the normal worker stopped, `ecx-bridge approve-solana-retry CONFIG EXPIRED_SIGNATURE REASON` is the private operator entry point. It takes exclusive ledger ownership, starts paused, and only authorizes the latest proven-expired unresolved obligation after fresh source and history checks. It never signs, sends or resumes. Existing successful obligations cannot be reopened. A new preparation requires the approval record and all ordinary funds, source, signing and backup checks. The schema-5 live refund remains historical evidence; no approval was retroactively invented for it. The actual schema-6 upgrade and refusal check are recorded in [evidence](evidence/operator-retry-upgrade.json).

## Recovery and deployment

Only a consistent local SQLite snapshot has been tested. `Bridge.Backup` also has a bounded restic invocation, but real remote upload failure/acknowledgment/retention and a fresh-host/key restore remain pending. Do not infer recoverability from the existence of snapshot code.

`deploy/` contains candidate service/Caddy/helper-launcher files, not an installer. Linux dynamic linking, bubblewrap behavior, native-cookie group access, limits and service startup must be tested together. The canonical activation additionally requires operator-provided backing/float/fee allocations, approved mint policy, independent Solana verification and remote backup configuration.

## Operating budget checkpoint

Configuration now requires `maxNativeDailyCost` and `maxSolDailyCost` as base-unit strings. The existing local public-test configuration uses `"10000"` native units and `"10000000"` lamports. Per-order fee/rent ceilings remain 1,000 native units and 10,000 + 2,100,000 lamports. This change did not create an order or send a payment.

The schema-7 upgrade preserved every financial table and the critical sequence. Six historical operating postings now carry conservative migration-time timestamps. Private `/audit` includes the current rolling-budget breakdown: 423 native units and 1,508,440 lamports of booked costs, zero active holds, and free operating allocations of 149,577 native units and 3,491,560 lamports at this checkpoint. Historical costs leave the rolling window after a full day; the balances remain reduced by the actual spends. [Upgrade and restart evidence](evidence/operating-budget-upgrade.json).

The quote and payment contract tests exercise reservations and limits. Existing pre-schema-7 orders have no invented fee snapshots; the three funded test orders are terminal. Unfinished legacy orders require operator recovery before resumption. Worker payment scheduling and browser intake remain disabled while browser integration and the remaining recovery gates are completed.

## Native admission probe

`scripts/native-admission-probe.hs CONFIG TESTER_NATIVE_ADDRESS` is restricted to the existing public L2L Signet deployment and dedicated tester wallet. Stop the verified worker before running it. It takes the ledger lock, refuses unresolved preparations/payments, and uses only native reads plus unlocked unsigned PSBT construction. It neither creates an order nor signs/sends a transaction. The normal acceptance tool also invokes the native check before creating any new order.

The actual node accepted a 10,000-unit full refund candidate and a 9,900-unit payout candidate, both with 141-unit estimated fees. The tested P2WPKH destination accepted 294 units and refused 293 units. Those two boundary cases temporarily lower only the probe's minimum-input setting; the live configuration remains at 10,000. Wrong-network and bridge-owned destinations were rejected. Custody keypool sizes, transaction count and input locks remained unchanged, as did every financial ledger table and critical sequence. [Saved evidence](evidence/native-admission.json).

This validates current node policy and the shared unsigned validator. It does not sign a new native payment, activate public intake, establish all destination-type compatibility, or complete recovery.

## Solana admission probe

`scripts/solana-admission-probe.hs CONFIG` is restricted to the existing public-test deployment. Stop the verified worker before using it; it takes the ledger lock and refuses unresolved payments/preparations. Its temporary helper configuration contains only public identities and no signer path. It uses a read/simulation RPC allowlist, independently refuses any usable simulation signature, and creates no order or payment.

Actual Devnet admitted the dedicated tester for a 9,980-unit wrap payout and 10,000-unit redemption/full-refund preview, with 5,000-lamport message fees. A fresh unfunded recipient key was used only to simulate missing-ATA creation, requiring 1,488,440 lamports; its key was not saved and it must never receive funds. The old setup payer's ATA already exists because the earlier standalone payout created it. Custody owner/account, configured mint and the tester's token account were refused as wallet inputs. All observed balances, financial tables and critical sequence remained unchanged; the worker restarted with three healthy scans. [Evidence](evidence/solana-admission.json).

The normal scoped acceptance tool runs both chain checks before creating a new order, then starts the immutable deadline. Its three existing terminal payment orders are reused without a new quote; the two known expired provisioning orders may coexist. Public intake and browser signing remain disabled; simulation does not establish later fee levels, account state or successful settlement.

## Provisioning and first exposure

Schema 8 adds an immutable native allocation claim and separates a recorded instruction from its first issuance. The schema upgrade kept every existing financial row and critical sequence, marked the three previously bound instructions as already issued, and created no order/address. A private pre-upgrade snapshot is retained. [Upgrade evidence](evidence/provisioning-upgrade.json).

`scripts/provisioning-probe.hs CONFIG PRIVATE_REQUEST interrupt|recover|redeem|expire|status` is restricted to this deployment and two named 10,000-unit test requests. They use real one-minute quotes with zero confirmation grace; the running configuration's 300-second quote and 1,200-second grace settings remain unchanged. The private capability files are `provision-wrap-1.json` and `provision-redeem-1.json` in the private local state directory. Never recreate those capabilities or delete an order to force another allocation.

The actual `interrupt` run exited with code 75 immediately after the daemon returned from `getnewaddress`, before the address was saved or exposed. The allocation claim survived in SQLite. A fresh `recover` process found the wallet's single matching receive label, verified ownership/script/readiness and issued that same address; another retry allocated no new address. The redemption request used a deterministic memo without allocating a native address. Both quotes then reached their original wall-clock deadlines, became `ExpiredUnfunded` and released all inventory and operating holds. No source deposit, signed attempt, payment or monetary posting was added. The original three financial orders remain unchanged. Critical sequence was 18 at that checkpoint, reflecting the native claim/address and Solana memo. [Real-network acceptance](evidence/order-provisioning.json).

Both requests are terminal; `interrupt` must not run again and refuses an existing order. `status` and idempotent recovery retain the original binding and deadline. The normal payment acceptance tool also permits the single named unsigned-recovery test and requires these two provisioning quotes to be expired. Recompile manual tools against the current schema before opening the ledger. First exposure also has contract tests for stale scans, malformed labels, concurrent retries, pauses and backup/deadline failures. Remote backup/restore, reorg recovery and browser-wallet acceptance remain outstanding.

## Ongoing custody checks

After stopping the verified worker, `ecx-bridge reconcile CONFIG` opens the ledger paused, scans the real chains and returns the custody report. Inspect `lastError`, `checkedRevision == revision`, `checkedAt` and `report.matches`; process exit zero alone does not mean the reported check passed. The command never sends funds or resumes intake. The worker runs the same check every loop. First exposure requires a current successful result, so the provisioning probe and scoped payment tool now call it before admission. Ordinary observation/settlement changes invalidate old reports atomically.

The actual schema 8→9 upgrade preserved all financial rows and critical sequence 18. A private pre-upgrade snapshot remains available. Two real checks across separate ledger openings and another after worker restart matched 1,899,677 native units, 100,000,000,014 wrapped units and 3,491,560 custody lamports. There were no new orders, deposits or payments; all five orders were terminal at that checkpoint. [Evidence](evidence/custody-reconciliation.json). `scripts/ledger-upgrade-check.hs CONFIG` is a separate no-RPC migration diagnostic; use only with an existing ledger, a retained backup and exclusive worker access. Earlier one-shot migration drivers are historical evidence tools and must not be rerun against a newer schema.

The Mac startup disk rejected new file writes during this checkpoint. The task workspace was copied with file-hash, mode and symbolic-link verification to `/Volumes/Crucial X9/CodexBuilds/ecx-bridge-20260930/workspace-b`; the original Documents path now links there. Build caches, the private ledger and wallets retain their existing external-drive locations. Two reproducible Homebrew download archives were preserved under the same build root's `relocated-downloads` directory to make space for the workspace link. Installed tools and unrelated projects were not changed. This development relocation is not evidence of the application's disk-full recovery behavior.


## Unsigned preparation recovery

Schema 10 preserves every existing preparation and adds immutable cancellation requests. The actual upgrade retained all monetary/binding rows and sequence 18, refused cancellation of an already-paid order, and restarted with three matching custody balances. A private `pre-unsigned-v10.sqlite` snapshot is retained. [Upgrade evidence](evidence/unsigned-recovery-upgrade.json).

Stop the verified worker, then use `ecx-bridge cancel-preparation CONFIG INTENT GENERATION REASON` for an unfinished generation with no recorded attempt. Private `/audit` reports `unsignedPreparations` with intent, generation, chain, draft presence and pending-cancellation state; it omits draft bytes. Cancellation starts paused, verifies the real source and current custody, and journals its cleanup before unlocking only recorded native inputs. No saved draft means there must be no wallet locks. Foreign locks or an ambiguous unlock reply leave the intent unresolved. Retry the exact intent, generation and reason after reconciliation; never blanket-unlock a wallet or erase an old draft.

Completion retains principal, destination inventory and unused fees. It does not resume or authorize a send. A later preparation uses a new generation and current budget admission; choosing a full refund releases only the unused conversion fee allowance. Signed/broadcast attempts use the existing exact-byte/expiry mechanisms and cannot be cancelled this way.

The scoped payment tool now has `unsigned-solana` and `unsigned-native` modes for exactly `public-test-unsigned-recovery-1`. They exit with code 75 after the actual request/draft is saved and before invoking the signer; native input locks have already been applied from the saved draft. Each mode refuses a second interruption for the same obligation. The native mode requires the completed Solana cancellation and explicitly chooses the bound full native refund. The private request is `unsigned-recovery-request.json`; never replace its capability or resubmit its source payment to repeat a test. Full startup/reorg/host-loss recovery and browser acceptance remain separate work.

That real recovery order is now `Refunded`. Both processes exited before signing, each cancellation completed, and the native generation-one refund returned 10,000 units exactly once at a 208-unit operator network cost. The two original drafts and cancellation records remain intact. No Solana payout was signed for this order. Current custody is 1,899,469 native units, 100,000,000,014 wrapped units and 3,491,560 lamports; critical sequence is 25. All six orders are terminal. The recorded capability/request, source submission and exact refund attempt must be reused on inspection. The one-shot acceptance driver refuses to create them again. [Real recovery evidence](evidence/unsigned-preparation-recovery.json).
