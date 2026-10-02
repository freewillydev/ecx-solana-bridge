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

Start a configured build with `scripts/start-local CONFIG --binary BINARY`. The task-specific [Start-Bridge.command](../../Start-Bridge.command) supplies the current private configuration and compiled executable paths. It uses public test funds only. The Signet daemon must already be running, and the external disk must be mounted. A startup with unresolved/reviewed work remains paused for inspection. Do not start a second ledger writer or rerun historical one-shot acceptance drivers.

The loopback preview started on `http://127.0.0.1:61734`. It runs the explicit real L2L Signet / Solana Devnet test mode with customer intake enabled after startup checks. The current browser tool cannot verify its administrator policy, so browser-wallet signing remains unverified. Open the loopback URL manually to inspect the interface.

The current process IDs, logs and private configuration are in `work/build/cache/local/` relative to the task workspace, two directories above this repository. `preview-processes.json` records the launcher, worker/web process IDs and port. The launcher owns both child processes; terminating that verified launcher stops its children. Before stopping a recorded PID, verify its executable and arguments still match this task; operating systems reuse PIDs. Do not kill processes by broad name or port patterns. These processes are for local inspection, not installed background services.

For a first manual round trip, wrap `0.00020000` Signet coins to receive `0.00019960` Devnet tokens, then redeem those tokens. Wrapping the minimum `0.00010000` produces less than the minimum redemption amount after the fee. Create a quote only when ready to deposit; its deadline is fixed. The operator fee account now includes a journaled 0.1 Devnet SOL top-up, removing its original one-active-order funding bottleneck; configured queue and daily fee limits still apply. New token accounts consume additional operator rent, so inspect the operating budget before extended testing. These are real public networks; Signet confirmation time is outside the application’s control.

The current customer socket is `/Volumes/Crucial X9/CodexBuilds/ecx-bridge-20260930/local/run/customer/api.sock`; the separate administrator socket is `/Volumes/Crucial X9/CodexBuilds/ecx-bridge-20260930/local/run/admin/api.sock`. Read their paths from the private configuration when running diagnostics. The old `/tmp/ecx-bridge-0930/` paths are no longer used. The development web and worker run under the same local account. Actual service-user separation is still a Linux test requirement.

The product launch upgraded the ledger to schema 18 with critical sequence 47, preserving the eight historical orders and seven signed attempts. The two subsequent customer-API transfers are paid. The transfer checkpoint was critical sequence 52, ten terminal orders and nine saved attempts; a clean launcher restart preserved all financial rows. [Product evidence](evidence/local-product-transfers.json). The known treasury, prior probes and application-ledger payments are reconciled to the actual chains. The original wrap exchanged 10,000 native units for 9,980 wrapped units, earned 20 native units and spent 5,000 lamports. A later 10,000-unit Solana deposit was first observed after its deadline and fully refunded; its expired refund attempt and one replacement are preserved. Two one-minute provisioning quotes expired unfunded, with every hold released. Three redemptions and the unsigned-recovery full refund also completed. Do not create treasury allocations from historical gross receipts without reconciling already-spent outputs. Each worker loop scans native, custody-token and fee-payer SOL history, expires provisional holds, reconciles native source recovery, changed native settlement finality and pending recorded payments, reconstructs native locks, checks custody, then waits 15 seconds. Private `/scanners` reports history health; `/audit` includes custody and pending-work summaries. Explicit test mode runs the existing payment pass after recovery/custody checks and accepts customer orders. Ordinary worker mode remains paused. Consult the latest status/evidence before resuming an acceptance process.

The schema 1→2, 2→3, 3→4, 4→5, 5→6 and 6→7 migrations preserve financial rows and critical/backup sequences and start paused. Consistent private snapshots were taken before the local upgrades. Schema 3 adds preparation policy/draft records; schema 4 adds treasury records and separate SOL history; schema 5 adds preparation generations and immutable expiry evidence; schema 6 requires a journaled operator approval before replacement. No migration erases old attempts. The actual 4→5 upgrade preserved hashes of every existing financial table, including pending signed bytes: [evidence](evidence/expiry-migration.json). For a manual one-shot scan, stop the verified worker PID, then run `ecx-bridge scan /absolute/private/config.json`; the exclusive ledger lock prevents concurrent workers or offline commands.

`scripts/reconcile-test-treasury.hs` is restricted to this exact public-test deployment and its known funding/probe IDs. Compile it against the pinned SQLite as described below, then pass the private configuration while the worker is stopped. It requires zero customer orders, verifies live public-chain evidence, reallocates existing receipts without double credit, books the known prior spends and compares live balances. A rerun is idempotent; it never signs, sends, creates orders or resumes the bridge. It is not a general treasury deposit or withdrawal interface.

That bootstrap now deliberately refuses this ledger because its first customer-shaped test order exists. Do not remove the restriction or delete the order to rerun it.

`scripts/public-test-order.hs CONFIG PRIVATE_REQUEST prepare|transaction|run|refund|status` is restricted to the existing deployment, dedicated tester, 10,000-unit amount and five named sequential payment tests, alongside the two expired provisioning quotes. `public-test-wrap-1` completed. `public-test-redeem-1` was observed late and refunded. `public-test-redeem-2` completed the reverse conversion, including a process interruption between native broadcast and confirmation. The later unsigned and paused-worker recovery tests are described below. The private request/capabilities and client attempts are in the private local state directory. Stop the verified worker before using it. `prepare` reuses the immutable request and instruction; `transaction` builds an unsigned source transfer; `run` uses actual observers and the payment pass, verifies balances and finishes paused. It permits at most two balance rescans when a deposit finalizes between history and account reads, never ignores a persistent discrepancy, and is not general in-flight reconciliation. The `refund` mode is bound to the single recorded late receipt. Never delete private records, reset deadlines or create new capabilities to force a retry. The tool does not open the customer API or configure remote backups.

`solana-helper/examples/deposit_devnet.rs PRIVATE_DEVNET_DIR PREPARED_JSON NEW_ATTEMPT_JSON` is a separate SDK test client. It independently compares the entire unsigned message against the exact known tester/mint/custody/amount/order, then signs with the dedicated tester and exclusively creates/fsyncs a private attempt file. It neither contacts RPC nor broadcasts, and refuses an existing output path. The test driver submits those saved bytes and launches the observer immediately; restarting an order must reuse its records. The first client attempt expired before submission and was retained with its absence evidence before an explicit replacement. This client replacement is separate from the application's schema-5 outgoing-payment recovery.

## Operator fee funding for local tests

The current deployment has 103,486,560 lamports allocated for Solana fees and token-account rent. The 0.1 Devnet SOL top-up came from the existing user-funded setup payer, finalized on Devnet, and was allocated once at critical sequence 53. All ten orders and nine signed bridge attempts were preserved. [Evidence](evidence/local-operating-funding.json).

For a later top-up, transfer Devnet SOL to the configured custody owner and retain its signature. Stop the verified launcher, then run:

    ecx-bridge allocate-test-operating /absolute/private/config.json SIGNATURE LAMPORTS

Use the exact positive received lamport amount. This private command accepts only the public Signet/Devnet profile. It rescans both real chains, requires fresh matched custody, and atomically assigns only an observed finalized SOL receipt with matching evidence to operating funds. It cannot classify native coins, wrapped tokens or customer-bound deposits. It neither sends money nor resumes service. Repeating the same verified allocation is idempotent. Inspect its custody result, then restart with scripts/start-local or the task-specific Start-Bridge.command.

The separate fund_devnet SDK example is tied to this existing development payer and custody address and a fixed 0.1 SOL amount. It writes exact signed bytes to a new private file and never broadcasts. It is test setup tooling, not a runtime signer. Never rerun the completed local funding driver or remove its attempt file.

When a history head advances during a custody snapshot, the product temporarily reports unavailable and skips new payments until scanning catches up. It does not clear manual pauses or genuine discrepancy/recovery pauses. This replaces the earlier permanent pause on routine history advancement.

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

That real recovery order is now `Refunded`. Both processes exited before signing, each cancellation completed, and the native generation-one refund returned 10,000 units exactly once at a 208-unit operator network cost. The two original drafts and cancellation records remain intact. No Solana payout was signed for this order. At that checkpoint custody was 1,899,469 native units, 100,000,000,014 wrapped units and 3,491,560 lamports; critical sequence was 25 and all six orders were terminal. The recorded capability/request, source submission and exact refund attempt must be reused on inspection. The one-shot acceptance driver refuses to create them again. [Real recovery evidence](evidence/unsigned-preparation-recovery.json).

## Paused worker and one-shot recovery

The ordinary worker now scans, reconciles saved payment outcomes, reconstructs native input locks and checks custody even with the implementation gate closed. With the verified worker stopped, `ecx-bridge recover CONFIG` runs that same pass under the exclusive ledger lock and leaves the deployment paused. It cannot prepare, sign, broadcast or approve a replacement. Inspect `payments.attempts` for per-attempt outcomes/errors, `nativeLocks`, all three scanner results and the current custody report; exit zero alone does not certify a clean recovery. Unknown results retain their exact bytes and holds. Private `/audit` includes `pendingPayments`, without transaction bytes.

The scoped tool's `interrupt-after-submit` mode accepts only the named `public-test-paused-recovery-1` redemption. It requires fresh source/custody evidence, no unrelated pending work and no prior preparation for that obligation. It invokes the actual payment pass once, verifies a saved native `BroadcastIntent`, then exits with code 75 before bookkeeping. The ordinary worker must finish the recorded outcome while staying paused. The private request is `paused-recovery-request.json`; preserve it and the saved client attempt. Repeating the interruption cannot create another preparation. No migration or network configuration change is required; the ledger remains schema 10.

The actual test is now `Paid`. A real 10,000-unit Devnet source transfer preceded one native payout of 9,900 units, with a 141-unit network fee. After the forced exit, the normal paused worker matched the exact 10,041-unit outflow while it was in the native mempool, then settled that same transaction after confirmation. Replaying `recover` changed no financial records; the previous six orders were preserved. At that checkpoint custody was 1,889,428 native units, 100,000,010,014 wrapped units and 3,491,560 lamports. Seven orders were terminal, with critical sequence 27, six saved signed attempts and no pending payment or operating holds. [Evidence](evidence/paused-worker-recovery.json).

During the final preview restart, the Mac startup disk refused Unix socket creation and even a symlink. This task's empty old socket directories were removed, and the two configured socket paths were moved to the existing external `local/run/` directory. The old private configuration is retained as `config-before-socket-relocation.json`. Deployment fingerprint, network/key/ledger settings and limits were unchanged. Both exact preview processes were restarted and verified: config/liveness 200, readiness 503, public `/audit` 404, customer socket 0660 and admin socket 0600. Historical one-shot drivers with `/tmp` socket paths must not be rerun unchanged. This local storage repair is not proof of application disk-full recovery or Linux installation.

## Native-node restart and input locks

The paused recovery pass now validates the native chain and dedicated wallet, saved policy/draft or signed attempt, and current confirmed owned prevouts before restoring only missing recorded locks. It verifies the resulting exact lock set before any signer can run. A pending cancellation is never relocked. Foreign locks or changed/unavailable inputs pause recovery without releasing funds. A known recorded transaction in the mempool or active chain requires no locking of spent inputs; an evicted transaction must pass the current-input checks again. The pass never signs, sends, unlocks unknown inputs or resumes service.

The scoped `unsigned-native-locks` mode is restricted to `public-test-native-locks-1` and exits before `walletprocesspsbt`. Its real test stopped and restarted the same dedicated Signet daemon, verified that advisory locks were lost, and let the ordinary paused worker restore precisely the two saved inputs. An immediate replay changed no financial rows or critical sequence and restored zero additional inputs. Exact cancellation retained all funds; generation one then paid 9,900 native units once, with a 141-unit network fee. Preserve `native-lock-recovery-request.json` and the saved client attempt; do not reissue the deposit or rerun the one-shot funding driver.

The final completed replay was unchanged, every prior financial/binding row was preserved, and the worker restarted with three healthy scanners and matching custody. At that checkpoint balances were 1,879,387 native units, 100,000,020,014 wrapped units and 3,491,560 lamports. Eight orders were terminal, critical sequence was 31, seven signed attempts were saved, and no payment/operating holds remained. The schema was 10. [Evidence](evidence/native-lock-recovery.json). This verifies an actual native-daemon restart; old-backup/key restoration, signer fencing and reorg accounting remain distinct gates.

## Stale-snapshot quarantine

`scripts/stale-snapshot-probe.py` is restricted to the historical sequence-27 snapshot and the known completed native-lock test. It copies the snapshot into a new private directory, changes only the copy's configured ledger path, then runs the application's read-only-on-chain `reconcile` command twice across ledger reopening. It cannot start a worker, change wallet locks, sign, broadcast or allocate a receipt. Never replace the live ledger with this copy.

The actual run retained the missing order's 10,000 wrapped units as unallocated, created no obligation, and kept the unknown native payout under review. Custody certification failed with `chain_observations_require_review`, availability stayed paused and the copy's sequence remained 27. Only the newly observed receipt and its balanced postings were added; earlier records and the second replay were unchanged. The live ledger stayed at sequence 31 with its original financial rows, and the source snapshot's hash was unchanged. [Evidence](evidence/stale-snapshot-quarantine.json).

The private successful inspection directory is `stale-snapshot-acceptance-2`; retain it as a quarantined copy. An earlier harness configuration was refused before ledger opening because its unused Unix socket paths exceeded the configured length bound. The final harness preserves the validated socket paths and uses no sockets. This check accepts one real lost-order scenario, not a complete remote/key restore or permission to resume.

## Database failure handling

The ledger now handles failures during COMMIT as well as inside the transaction body. It attempts rollback while preserving the original error, then blocks every ledger operation after a database or cleanup failure with `ledger_requires_reopen`. It does not rely on writing a pause record to a failing database. Stop the failed worker, resolve the storage problem, and reopen for paused reconciliation; no endpoint clears this guard. An ordinary policy refusal or request cancellation leaves the writer usable only if rollback succeeds.

At that checkpoint the suite passed 215 examples plus 100 generated arithmetic cases. Added tests exercise cancellation before commit, an actual deferred-constraint failure at COMMIT, a bounded SQLite file-page limit producing `SQLITE_FULL`, and a failed BroadcastIntent write. They verify rollback, unchanged critical sequence, blocked send authorization and retained bytes/holds across reopening. These local fixtures do not contact a chain or fill the host filesystem.

After rebuilding, the actual ledger was backed up privately as `pre-ledger-transaction-fence.sqlite`, reopened for one ordinary recovery pass, and served by the restarted worker. Every financial/binding row and critical sequence 31 was preserved; integrity and foreign-key checks passed, all three custody balances matched, no pending payments or preparations remained, and HTTP readiness stayed 503. The schema remains 10. [Evidence](evidence/ledger-transaction-fence.json). The scoped payment and provisioning tools were also recompiled against the updated library.

## Native settlement finality and worker reconnect

Schema 11 adds an immutable recovery journal for previously settled native payments. The ordinary paused worker now reports `nativeSettlements`; private `/audit` includes the latest `nativeSettlementRecovery` decisions. A payment with an open review appears as `NeedsReview` to its capability holder, retaining its original transaction link. Reconfirmation of the same exact payment changes proof only, with no new payment or monetary posting. The deployment stays paused.

The actual height-16428 public Signet block was disconnected and reconsidered only in the dedicated node's local view. The latest existing redemption payout returned to the mempool, acquired a `confirming` record at sequence 32, and regained its original block with a `reconfirmed` record at sequence 33. The worker retained the review across restart. The test harness encountered a transient HTTP 503 on its public read after that restart; its `finally` restored the block. Continuation inspected the restored node and finished recovery/replay without disconnecting the block again. The public review was verified before restart and private audit after restart; that intermediate public read is not claimed as passing. [Evidence](evidence/native-finality-recovery.json).

All eight orders, seven saved attempts, financial/binding rows and balances survived unchanged. Custody remains 1,879,387 native units, 100,000,020,014 wrapped units and 3,491,560 lamports. The private schema-10 snapshot is `pre-native-finality-v11.sqlite`. Preserve it, the acceptance state, capability and original payment. Both one-shot finality drivers have completed and must not be rerun to repeat the disconnection. This is not public-consensus reorg evidence; new anchors and missing/conflicting payment paths have offline coverage. Source loss, compensation, replacement families and complete host-loss restore remain.

The local customer transport now keeps no idle Unix connections and still retries no request. The regression test keeps both GET and POST clients alive across a real worker/socket replacement. The rebuilt local web process also stayed running across a worker restart: its first authenticated order GET returned 200 and its first invalid-capability POST returned 409, without retries or financial changes. [Reconnect evidence](evidence/unix-worker-reconnect.json). Requests during worker downtime can still fail. At that checkpoint the suite contained 227 examples plus 100 generated arithmetic cases.

## Native source recovery

Schema 12 adds immutable source-recovery decisions and reversible deficit accounting for proven native conflicts. The worker reports `sources`, while private `/audit.sourceRecovery` lists the latest state, shortfall and payment exposure. Loss of eligibility preserves obligations and holds; ambiguous RPC evidence cannot create or forgive a deficit. Restoration leaves the deployment paused, and reviewed obligations require explicit operator recovery. Permanent loss absorption and complete resume remain unfinished.

The original wrap's actual height-16396 source block was disconnected and reconsidered only in the dedicated node's local view. The wrap became `NeedsReview`, retained that public status across worker restart, then returned to `Paid` after restoration. The two affected native sources were absent from the mempool, so the worker recorded unavailable evidence and no deficit. Four affected native payouts also entered review and reconfirmed. Six source decisions and eight payment decisions advanced the critical sequence from 33 to 47.

Completed one-shot recovery and another normal-worker restart retained every financial/binding row, all eight terminal orders, all seven saved attempts and custody balances of 1,879,387 native units, 100,000,020,014 wrapped units and 3,491,560 lamports. No new payment or monetary posting was created, all scanners and custody checks passed, and readiness stayed 503. [Evidence](evidence/native-source-recovery.json). This was neither a public consensus reorg nor a confirmed double spend. Deficit/reversal, unavailable proof, pre-send exposure and rollback paths have offline contract coverage. The full suite now passes 243 examples plus 100 generated arithmetic cases.

Retain the private schema-11 snapshot `pre-source-recovery-v12.sqlite` and the completed `native-source-recovery-state.json`. The one-shot `work/accept-native-source-recovery.py` driver completed and restored the node; never rerun it to disconnect the source block again. Manual tools must be rebuilt against schema 12 before opening this ledger. Do not rewrite the existing request, source, payment, deadlines or capability to exercise recovery.

## Explicit approval after source restoration

With the normal worker stopped, `ecx-bridge approve-source-recovery CONFIG OBLIGATION RESTORATION_SEQUENCE REASON` takes exclusive ledger ownership and remains paused. Select the still-reviewed obligation and latest restored source sequence from private audit. The command runs recovery, verifies the actual source, reconciles saved outcomes, checks current custody and restores only the exact obligation state suspended by the original source loss. It refuses changed work, expired/failed or paid attempts, pending cancellation and unavailable legacy context. The approval changes no money; its preceding recovery pass may book already-recorded payments. Nothing is signed or sent. Later sending still requires normal authorization and backup coverage of the new approval. This is not the service-resume command.

Schema 13 preserves the older source journal and adds immutable approval records. The actual migration retained all eight orders, seven attempts, financial/binding rows and critical sequence 47. The new command was invoked for the completed wrap at restored-source sequence 42; it correctly returned `source_approval_not_expected` and created no approval. The rebuilt worker restarted with three healthy scanners and matching balances of 1,879,387 native units, 100,000,020,014 wrapped units and 3,491,560 lamports. The authenticated wrap remained `Paid`; readiness remained 503. [Evidence](evidence/source-approval-upgrade.json).

Retain `pre-source-approval-v13.sqlite` and the completed `source-approval-upgrade-state.json`. The one-shot `work/accept-source-approval-upgrade.py` driver completed and must not be rerun. Successful operator approval, snapshot fencing, repeated source episodes, rollback and the approval backup barrier have offline coverage; no additional live source loss or payment was created. The full suite passes 259 examples plus 100 generated arithmetic cases. Manual payment/provisioning tools must use the current schema-13 library before opening the ledger.

## Native loss capital and return

With the normal worker stopped, `ecx-bridge cover-source-loss CONFIG DEPOSIT LOSS_SEQUENCE FLOAT_UNITS EARNED_UNITS REASON` can cover a proved native source deficit using a full-receipt split of free native float and earnings. Read the latest loss sequence and receipt from private audit. Fresh conflict and physical-custody checks must agree on the native wallet block and unchanged ledger revision. The command stays paused, preserves existing work/claims and never signs or sends. Successful coverage/return is currently verified by offline contracts; no live source deficit has been funded.

The actual schema 13→14 migration and restored-source refusal preserved all eight orders, seven signed attempts, financial/binding rows, source decisions and critical sequence 47. The CLI returned `source_loss_not_proven` for the completed wrap at source-restoration sequence 42 and made no capital allocation. The normal worker restarted with healthy scans and matching custody of 1,879,387 native units, 100,000,020,014 wrapped units and 3,491,560 lamports. The wrap remained `Paid`, readiness 503. [Evidence](evidence/source-loss-upgrade.json).

Retain the private `pre-source-loss-v14.sqlite` snapshot and completed `source-loss-upgrade-state.json`. The one-shot `work/accept-source-loss-upgrade.py` driver completed and must not be rerun. The full suite passes 280 examples plus 100 generated arithmetic cases. Manual tools must be rebuilt against schema 14 before opening this ledger. Covers and exact capital returns are immutable recovery records; keep them in future backups. Active lost-source obligations remain quarantined until their separate recovery path is implemented.

## Unsigned native replacement diagnostic

`scripts/native-replacement-probe.hs CONFIG NEW_FIXTURE_PATH` is restricted to the existing dedicated public-Signet configuration and earlier captured confirmed payment. It does not open the ledger or stop the worker. Its RPC allowlist excludes sends, input-lock changes and address allocation; `walletprocesspsbt` is permitted only with signing/derivation export/finalization disabled. The requested fixture must not already exist.

The actual pending guard returned `native_replacement_member_not_pending` for confirmed transaction `b2278e8dd0be7be001a5630545ddb73c83423ee1ee7dbd0327675e27f1642bd3`. A separate unsigned construction check reduced its change by 100 units, raising the fee from 282 to 382 while retaining the 100,000-unit recipient output and all inputs. Wallet balances, locks, transaction count and key-pool counts remained unchanged. [Evidence](evidence/native-replacement-construction.json). The captured unsigned fixture is built from already-spent inputs; it is not a signed replacement or live RBF acceptance. No migration was required. Durable operator family authorization, signing/sending, winner-only accounting and family reorg recovery remain to be integrated.

## Single-settlement migration

Schema 15 adds `one_settled_payment_per_intent`; settlement also checks the unresolved intent, obligation state and active fee hold before any posting. The real migration, completed recovery replay and normal worker restart retained all eight orders, seven attempts, financial/binding rows, source records and critical sequence 47. Custody matched 1,879,387 native units, 100,000,020,014 wrapped units and 3,491,560 lamports, all scanners were healthy, the wrap remained `Paid` and readiness remained 503. [Evidence](evidence/settlement-winner-upgrade.json).

Retain the private `pre-settlement-winner-v15.sqlite` snapshot and completed `settlement-winner-upgrade-state.json`. The one-shot `work/accept-settlement-winner-upgrade.py` driver completed and must not be rerun. Manual payment/provisioning tools must use the schema-15 library. The full suite passes 303 examples plus 100 generated arithmetic cases. The new competing-callback tests operate only in isolated ledgers; no live replacement or additional payment was created.

## Durable native replacement drafts

With the verified worker stopped, the private commands are:

```sh
ecx-bridge prepare-native-replacement CONFIG TRANSACTION FEE_UNITS REASON
ecx-bridge cancel-native-replacement CONFIG DRAFT_SEQUENCE REASON
```

They leave the deployment paused. Preparation checks the exact original pending payment, real chain/source evidence and current custody before saving an unsigned template. Cancellation retains that original payment and all reservations. Replaying an exact cancelled decision returns its saved cancelled state; it cannot reactivate it. Neither command invokes a signer, sends, allocates keys or changes locks. The preparation command first runs ordinary recovery, which may book already-confirmed payments.

Schema 16 migrated the actual ledger without changing financial/binding rows, source records or sequence 47. Attempting to draft a replacement for the already-settled native payout returned `native_replacement_not_expected` and created no decision. Completed recovery replay and the restarted worker retained matching custody, healthy scanners and readiness 503. [Evidence](evidence/replacement-draft-upgrade.json).

Retain `pre-replacement-draft-v16.sqlite` and `replacement-draft-upgrade-state.json` privately. The one-shot `work/accept-replacement-draft-upgrade.py` has completed and must not be rerun. Both manual acceptance tools were rebuilt against schema 16. The full suite passes 314 examples plus 100 generated arithmetic cases. Successful draft/cancellation and failure paths have offline coverage; no live replacement was signed or sent. Full family signing, member observation, custody normalization and reorg compensation remain outstanding.

## Native family journal and recovery

Schema 17 records each signed replacement's immutable draft lineage inside the original intent. The replacement signing adapter and coordinator are implemented, but no signing/send command is enabled. The worker's recovery paths observe all saved members, book the actual winner once, normalize one custody effect and reconstruct one shared input-lock set. The original, cancelled decisions and older signed members remain available for audit. An older member can win. Reconfirmation of the same settled winner preserves funds; a different winner requires the still-unfinished compensating accounting and keeps the deployment under review.

The actual 16→17 upgrade, completed recovery replay, settled-parent refusal and worker restart preserved all financial/binding rows, source records, eight orders, seven attempts and sequence 47. Real custody still matched 1,879,387 native units, 100,000,020,014 wrapped units and 3,491,560 lamports, with all three scanners healthy and readiness 503. [Upgrade evidence](evidence/native-family-upgrade.json). Retain private `pre-native-family-v17.sqlite` and `native-family-upgrade-state.json`; the one-shot `work/accept-native-family-upgrade.py` is complete and must not be rerun. Manual payment/provisioning tools were rebuilt against schema 17.

`scripts/native-family-readback.hs CONFIG` is a read-only diagnostic restricted to the dedicated existing public-test deployment. It verified the previously confirmed Signet payment through the new family reader, preserving wallet balances, transaction count and key-pool counts. Its allowlist excludes signing, sending and wallet mutations. [Readback evidence](evidence/native-family-readback.json). This exercises one actual confirmed member, not a live replacement family.

All 342 examples plus 100 generated arithmetic cases pass. The 28 new family/signing cases use captured public templates and explicitly non-sendable sibling byte stubs for deterministic RPC contracts. They test application state transitions, not a substitute network or cryptographic validity of those stubs. Actual replacement signing/broadcast, changed-winner accounting, complete destination loss and restore/resume remain separate gates.


## Installed Linux product acceptance driver

`integration/FreshProductCheck.py` can use `--installed-vm NAME` to run the
same customer, fee, finality and restart checks against the installed systemd
paying worker. The host state directory must contain that guest's matching
private `config.json`; use a separate `product/` journal for its own orders.
The driver verifies the exact configured custody/chain identity and installed
public-test payment mode before starting. It uses SSH stdin for requests and
reads the native RPC cookie inside the guest. It opens no public RPC port and
copies no existing custody or tester key into the guest. The Solana tester signs
locally with its existing dedicated Devnet key. The guest must already have its
own funded `ecx-bridge-tester` native wallet and configured treasury allocations.

Set `LIMA_HOME` to the dedicated task VM directory. Supply `--devnet-dir`,
`--deposit-helper` and `--report` as for local acceptance; `--binary` is unnecessary
for installed mode. Run only against the dedicated freshly funded acceptance
installation. This option does not provision funds, import a ledger or authorize
an existing signing deployment to be duplicated. On completion or timeout it
stops the installed worker and retains the exact requests and deposits for
reconciliation. GUI wallet signing and clean-host/key restoration remain separate
checks. The installed paying test now passes both directions, actual finality and restart
preservation on the fresh ARM64 deployment; see `evidence/installed-paying-product.json`.
Read-only public Solana RPC calls retry bounded 429/503 failures; customer send
operations are not retried by that transport.


The `pg-install` fixture now retains two newly created empty native wallets and
private funding-address/checkpoint journals under
`/var/lib/ecx-bridge/private/installed-paying-stage/`. Preparation is reproducible
with `integration/PrepareInstalledNative.py` run as root in that dedicated guest.
It checks the real L2L Signet challenge, refuses unjournaled preexisting names,
and sends no funding. The guest's existing observer installation remains intact;
preparation is not a paying-mode activation. Preserve its original database,
configuration and fence before switching to a distinct fresh acceptance deployment.

The observer fixture was preserved before switching to a fresh funded paying
fixture. `SwitchInstalledFixture.py`, `FundInstalledCustody.py` and
`AllocateInstalledTreasury.py` are guarded dedicated-test orchestration, not
general deployment or production funding commands. Their private journals retain
exact transactions for replay. `InstalledPayingReinstallCheck.py` compares a
paused, stopped two-terminal-order fixture across a same-release reinstall,
including 31 durable tables, configuration hashes and the protected fence.
The earlier local preview supervisor and its worker/web children were stopped
after verifying its orders were terminal; recorded preview PIDs are historical.

The dedicated installed acceptance deployment has been handed off from
`pg-install` (retired; do not re-enable) to a fresh `restore` guest.
`PrepareInstalledHandoff.py` and `RestoreInstalledHandoff.py` are guarded test
orchestration for exactly the two-paid-order fixture, not general unattended
production restore commands. They retain private journals, verify stopped-source
archive digests and all table rows, and deliberately omit source fences/overrides.
The destination first starts in observation mode. `RestoredSignerCheck.py`
reproduces only saved settled signatures with no broadcast.

`FreshProductCheck.py --replay-only --restored-handoff PRIVATE_JOURNAL` requires
all existing request/deposit journals and refuses a missing on-chain deposit
rather than sending it. This verifies recovery of existing customer work without
issuing new funding or transfers. The installed restored worker finishes paused
and stopped. Both guests are on this physical computer; remote durability is
still unverified. Preserve the retired guest and private recovery journals.

The restored installed interface is forwarded from guest loopback port 8090 to
`http://127.0.0.1:61737/` while the `restore` VM is running. Actual browser
acceptance created two additional unfunded orders, so fixed two-paid-order
handoff/signature fixtures are no longer the entire current order set. Do not
rerun those guarded tools against this changed fixture. Retain the new records
for ordinary deadline/grace expiry; no new signing attempt or deposit was made.
Browser screenshots/evidence are in `docs/evidence/installed-browser-acceptance.json`.
External wallet signing and clipboard/private recovery-link verification remain.

### Encrypted backup acceptance on the configured repository

`integration/PostgresEncryptedBackupCheck.py` defaults to disposable local restic
storage. Supply both protected credential files to exercise an already initialized
HTTPS repository with the same uploader and authenticated read-back used by the
worker. Run as a PostgreSQL owner able to create/drop disposable databases, with
the explicit private `PGHOST`, `PGPORT` and `PGUSER` for the acceptance cluster:

```sh
python3 integration/PostgresEncryptedBackupCheck.py /absolute/trusted-ledger-manifest.json \
  --directory /absolute/private-acceptance-stage \
  --restic /usr/bin/restic \
  --repository-file /absolute/private-backup.repository \
  --password-file /absolute/private-backup.password \
  --report /absolute/acceptance-report.json
```

Use only a trusted ledger manifest from `deploy/postgres-backup.py`, not a release
package manifest. Remote mode uploads a new encrypted archive/manifest snapshot;
it does not initialize, prune or delete remote snapshots. The temporary restore
and isolated database are removed after the check. The test checks archive bytes,
deployment identity, all table counts and, for newly created manifests, SHA-256
digests of every row in every table. Legacy manifests report `tableContentsMatch`
as null; they do not gain row verification retroactively. The digest streams sorted
JSONB rows with UTC timestamp rendering inside the same exported snapshot used
by pg_dump. This does not prove signer-key recovery,
in-flight resumption or independent physical storage. Establish host independence
and retention separately. Neither mode acknowledges coverage in the live ledger
or starts a worker. Credentials and repository URLs are omitted from reports and
failure diagnostics. An unavailable repository fails the command without a success
report. The local round trip is recorded in
`docs/evidence/postgres-encrypted-backup-command.json`.

The restored ARM test deployment currently uses release
`c8786e4c208f2a226b7282c1`, including row-content backup verification. Its two
unfunded browser orders have now expired normally; the ledger retains four orders
and two paid attempts, at critical sequence 11. Upgrade and repeat installation
evidence is in `docs/evidence/installed-backup-tools-arm.json`. Preserve the
original private stopped upgrade archive and both state-comparison baselines.
The x86 deployment-only update remains pending; do not claim both architectures
have accepted these latest script changes yet.
