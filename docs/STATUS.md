# Implementation status — 2026-09-30

**This is an unfinished development checkpoint, not a deployable custody release.** One real ledger-driven wrap has completed through a scoped acceptance tool. `implementationReady = False` in `Bridge.Worker`; it is deliberately not a configuration toggle. New orders and unsigned deposit transactions cannot be requested through the customer API. No administrator resume endpoint is exposed.

## Verified locally

| Check | Result and evidence |
| --- | --- |
| Haskell application | Builds on macOS arm64 / GHC 9.14.1 with the frozen Cabal graph |
| Financial/state tests | 95 examples pass, plus 100 generated arithmetic cases; [test output](evidence/haskell-tests.txt) |
| SQLite actually linked | 3.53.4, exact upstream source identity checked by the application; [doctor](evidence/doctor.json) |
| Rust helper | Five tests pass; the separate Devnet setup example compiles; fixed SDK/interface graph in `Cargo.lock` |
| Browser build | TypeScript strict check and esbuild succeed; generated module about 6.7 KiB |
| Declared browser dependencies | npm audit reports zero vulnerabilities at this check; [report](evidence/npm-audit.json). This is not a complete dependency audit. |
| Unix transport | Same Servant customer contract on both sides; socket modes, separate admin API and duplicate-worker lock tested |
| HTTP preview | Customer config/liveness 200, readiness 503, public `/audit` 404; no-store/CSP headers; [evidence](evidence/http-preview.json) |
| Browser inspection | Actual local page loaded; both fee previews and the direction-specific refund controls checked; deposits disabled; [screenshot](evidence/local-preview.jpg) |
| Real native chain | Public L2L Signet synchronized; challenge and height-16000 checkpoint match |
| Real native payment | Daemon-funded/signed PSBT, 100,000 units to dedicated tester, 282-unit fee, three confirmations at the recorded probe check; [transaction](https://explorer.signet.drivechain.info/tx/b2278e8dd0be7be001a5630545ddb73c83423ee1ee7dbd0327675e27f1642bd3), [evidence](evidence/signet-probe.json) |
| Native preparation on real node | New Haskell validator accepted an unsigned 100,000-unit PSBT with confirmed owned input, owned change and 141-unit fee; no signing/broadcast, selected input unlocked; [evidence](evidence/native-unsigned-probe.json) |
| Preparation/restart contracts | Chain/fee reservation before wallet funding, immutable draft before signing, lost RPC response, repeated preparation, refund exclusion and post-backup source recheck tested; schema 2→3 preserved the actual local ledger; [restart evidence](evidence/native-preparation-restart.json) |
| Real native observer | Recorded the actual faucet receipt as unallocated and the standalone payment as an unknown outgoing transaction requiring review; [scan](evidence/observer-first-scan.json) |
| Observer replay and restart | Repeated scan did not duplicate deposits, postings or obligations; schema 1→2 migrated the local ledger and the observer restarted paused; [replay](evidence/native-observer-replay.json) |
| Solana history contracts | Exact cursor pagination, missing history, independent-verifier delay/disagreement, historical token ownership and version-0 account indexes tested with explicitly labeled fixtures |
| Solana identity/setup | Public Devnet genesis, actual eight-decimal legacy mint and custody account verified; [setup](evidence/devnet-setup.json), [doctor](evidence/doctor.json) |
| Solana preparation | Ledger reserves fee plus rent before the helper; saved request, local signature check, unsigned simulation and exact attempt reuse tested |
| Real Solana payouts | Three base units finalized to existing and new recipient ATAs; 5,000-lamport network fee each and 1,488,440-lamport rent for the new ATA; [existing](evidence/solana-devnet-existing-payment.json), [new](evidence/solana-devnet-new-payment.json) |
| Expired standalone attempt | Original signature was absent from finalized custody/owner history through the setup anchor after blockhash expiry; retained before one operator replacement, [evidence](evidence/solana-devnet-expired-attempt.json). This is not the application's automatic expiry implementation. |
| Real Solana observer/replay | Setup token receipt held as unallocated; standalone outgoing payments flagged for review; repeat scan created no duplicate deposits/postings/obligations; [evidence](evidence/solana-observer-replay.json) |
| Public-test treasury reconciliation | Three known funding receipts allocated and five prior outgoing asset effects booked, including fees/rent; ledger balances match live native, token and fee-payer SOL balances; [reconciliation](evidence/test-treasury-reconciliation.json) |
| Treasury migration/replay | Actual schema 3→4 preserved the ledger; repeat reconciliation changed no financial records; [migration](evidence/treasury-migration.json), [replay](evidence/test-treasury-replay.json) |
| SOL history and worker restart | Separate fee-payer cursor; a real Devnet read rejected a history origin with nonzero opening balance without advancing its cursor; three observation streams healthy and no pending review after restart; [origin check](evidence/solana-operating-origin-check.json), [scanners](evidence/treasury-scanner-restart.json) |
| Send/settlement contracts | Exact-byte retry, lost send response, backup acknowledgment, source recheck after backup, expired-blockhash hold, signed-only on-chain refusal and paused success/failure reconciliation tested |
| Live settlement-reader checks | New adapters verified the actual prior native payment and both finalized Solana payouts; no new transactions sent during readback; [evidence](evidence/settlement-adapter-readback.json) |
| First ledger-driven wrap | 10,000 native units in, 9,980 wrapped units out, 20-unit bridge fee and 5,000-lamport network fee; exact real-chain evidence and all custody balances matched; [order](evidence/first-ledger-wrap.json) |
| Completed-order replay/restart | A fresh ledger opening and payment pass changed no financial records; after worker restart, all scanners were healthy and the authenticated customer API returned the saved `Paid` order; [replay](evidence/first-ledger-wrap-replay.json), [restart](evidence/first-ledger-wrap-restart.json) |

The earlier native payment and three-unit Solana payments were standalone probes. The later 10,000-unit native deposit and 9,980-unit token payout form a complete application-ledger wrap. It used dedicated public-test wallets and the command-line acceptance tool; it does not establish browser-wallet support, a completed reverse direction or full restart/host-loss recovery. Deterministic codec and RPC fixtures remain explicitly labeled as offline tests.

## Coverage against the approved sequence

| Plan stage | Status | Remaining exit requirements |
| --- | --- | --- |
| 1. Dependency and integration boundary | Partial | Linux build/systemd/helper sandbox; actual browser-wallet finalized deposit; dependency provenance/notice/security review |
| 2. Economic/API contracts | Partial | Implement native destination/dust policy, rolling budgets, full state/error contracts for replacement/reorg/recovery; validate all exception examples |
| 3. Durable ledger/worker | Partial | Existing primitives are tested; still need explicit cancellation/disk-full fault injection, production-size reconciliation and restore coverage |
| 4. Both chain observers | Partial | Real order-bound native deposit and native/token/operating-SOL history verified. Order-bound Solana deposit, ongoing custody/in-flight reconciliation, long-backlog recovery and complete reorg reconciliation remain |
| 5. Settlement and recovery | Partial | Bounded payment pass now rechecks sources, enforces intent/backup barriers, sends exact bytes and posts verified outcomes including fee/rent. Still need quote/queue operating budgets, automatic startup recovery, destination reorgs, native replacement families, conclusive Solana expiry decisions and remote backup orchestration |
| 6. Usable public-test bridge | Not complete | Both real directions through the browser, new recipient ATA, reload/rejection/expiry flows and supported-wallet matrix |
| 7. Actual ECX betanet | Not started | Adequately sized host/node, official daemon/checkpoint and replay-policy tests, funding and real round trips |
| 8. Installation and recovery | Not complete | Candidate service files exist; installer, release verification, remote backup permissions/retention, key restore and clean-host restore still required |
| 9. Independent review | Not performed | Freeze and independently review the working installed test release before valuable funds |
| 10. Canonical pilot | Not authorized/launched | Operator identities, reserve/supply evidence, limits, remote backups, independent RPC and explicitly allocated funding |
| 11. Market integrations | Not started | Real pool decision, separately authorized LP capital, actual Jupiter routes and historical price data |
| 12. Future mainnet | Conditional | Official launch identity/terms and a separately reviewed activation |

Some pure ledger work overlapped the first integration stage, as allowed by the plan. Passing these tests does not close any later stage's real-chain or recovery gate.

## External inputs and next actions

1. **Devnet funding received:** the user funded the existing setup payer with 10 Devnet SOL. Setup and two tiny payout probes finalized. The actual mint is `Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM`; it is a public-test mint, not canonical ECX.
2. Complete a real helper-built incoming Solana transfer and ledger-driven native payout, then both directions through a supported browser wallet. The completed wrap used the command-line acceptance tool.
3. Complete ongoing custody/in-flight reconciliation and the remaining recovery paths. After the first ledger-driven wrap, balances match at 1,909,718 native units (1,759,980 float, 149,718 operating and 20 earned), 99,999,990,014 wrapped units (float), and 3,496,560 fee-payer lamports (operating). Neither the scoped treasury bootstrap nor this order is a general operator workflow or canonical reserve proof. Both Solana histories use the actual setup signature as their immutable origin.
4. **Linux server:** user requested local continuation and will provide server details later. The local Docker storage is reporting I/O errors; unrelated containers were left alone. Test Ubuntu 24.04, native node access, distinct service users, helper isolation, and pinned SQLite/restic artifacts when an appropriate target is available.
5. Complete full public Signet/Devnet round trips, crash/ambiguous-send cases, replacement/refund exclusions and host-loss recovery before enabling even a small tester pilot. ECX betanet requires its real node and separate test allocation.

Unfinished implementation is an additional requirement beyond those external inputs. Funding or server access alone will not make the current application ready.

## Dependency decisions and open review items

- Compatible Solana SDK 3/interface versions are pinned together. Selecting each newest crate independently produced incompatible instruction/address types; the recorded graph compiles and matches independent wire checks.
- The JavaScript setup dependencies were removed after their graph reported advisories. Test mint setup now uses the Rust SDK example, separate from the runtime helper. Wallet Standard and build tools are the remaining declared browser dependencies.
- The default `direct-sqlite` package bundled SQLite 3.45.0. The application now uses `+systemlib`, verifies the selected 3.53.4 source identity, and tests snapshots using the same selected CLI. The target release still needs verified Linux native artifacts.
- The Signet probe used the existing Bitcoin Core 30.2.0 binary from the local BitWindow installation. Its SHA-256 is recorded, but release signature/provenance validation is pending. This is not an approved release dependency merely because the probe succeeded.
- The dependency manifest includes the compiled Haskell graph, Rust graph including setup/tests, npm lock entries, licenses and available checksums. Compiler-distribution notice assembly, transitive review, Rust/Haskell advisory analysis and release signing remain outstanding.
- No public repository, release, one-line installer, official token minting, LP contribution, customer-fund transaction, external outreach or public launch was performed.

The next implementation must retain the original plan's security/recovery scope. Do not remove the disabled intake gate simply to make the interface appear finished.

The native preparation path has RPC contract tests and real unsigned validation; the earlier standalone signed native probe is separate evidence. The first wrap's native transfer was sent by the dedicated tester as a deposit. The application's native payout path still needs a complete real redemption order.

The normal worker's payment scheduling and HTTP intake remain behind the disabled implementation gate. The scoped wrap acceptance tool used the real payment pass to sign, persist, submit and finalize one obligation. The earlier standalone probes separately exercised an expired attempt followed by an explicit replacement; this does not establish automatic expiry or canonical independent-provider recovery acceptance.

The treasury checkpoint sent no transactions. Its operator tool checks the exact existing public-test deployment, requires zero customer orders, verifies the known funding and finalized probe evidence, and matches current chain balances. Customer attempts cannot be reclassified as treasury spends. An on-chain signature saved only as `signed`, without `BroadcastIntent`, now triggers review. The worker remains paused with intake disabled.
