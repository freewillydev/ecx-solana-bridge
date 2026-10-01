# Implementation status — 2026-09-30

**This is an unfinished development checkpoint, not a functioning bridge or a deployable custody release.** `implementationReady = False` in `Bridge.Worker`; it is deliberately not a configuration toggle. New orders and unsigned deposit transactions cannot be requested. No administrator resume endpoint is exposed.

## Verified locally

| Check | Result and evidence |
| --- | --- |
| Haskell application | Builds on macOS arm64 / GHC 9.14.1 with the frozen Cabal graph |
| Financial/state tests | 74 examples pass, plus 100 generated arithmetic cases; [test output](evidence/haskell-tests.txt) |
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

The native payment used the standalone probe and dedicated public-test wallets. It was **not** a ledger-driven cross-chain order. The deterministic Solana codec fixtures remain explicitly labeled. Separate captured finalized Devnet fixtures now exercise actual payout evidence. No ledger-driven cross-chain order has completed.

## Coverage against the approved sequence

| Plan stage | Status | Remaining exit requirements |
| --- | --- | --- |
| 1. Dependency and integration boundary | Partial | Linux build/systemd/helper sandbox; actual browser-wallet finalized deposit; dependency provenance/notice/security review |
| 2. Economic/API contracts | Partial | Implement native destination/dust policy, rolling budgets, full state/error contracts for replacement/reorg/recovery; validate all exception examples |
| 3. Durable ledger/worker | Partial | Existing primitives are tested; still need explicit cancellation/disk-full fault injection, production-size reconciliation and restore coverage |
| 4. Both chain observers | Partial | Both watchers exercised on actual Signet/Devnet history. Real order-bound deposits, operating-SOL reconciliation, long-backlog recovery and complete balance/reorg reconciliation remain |
| 5. Settlement and recovery | Partial | Both preparation paths, durable intent/cost holds and Solana finalized-outcome validation are implemented. Still need rent settlement postings/rolling budgets, automatic scheduler, live source rechecks, exact-byte send/rebroadcast, finality/reorg reconciliation, native replacement families, Solana expiry and remote backup orchestration |
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
2. Complete a real helper-built incoming transfer and browser-wallet signing. Programmatic outgoing probes do not substitute for an actual supported browser wallet or either full bridge direction.
3. Finish verified funding allocations, operating-SOL/custody reconciliation and the outgoing send/settlement/recovery loop. The observer's immutable origin is the actual setup signature. Its setup receipt remains unallocated, and standalone payouts remain review items until explicitly reconciled. Never book a second treasury credit over a receipt already recorded by the observer.
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

The native preparation module is not called by the worker's observer loop and has no HTTP signing route. Its full signing path has RPC contract tests; the fresh real-node check intentionally covered unsigned construction/validation only. The earlier standalone real signed payment remains separate evidence. No new signed native transaction or on-chain transfer was produced during this preparation checkpoint.

The new Solana preparation path, like the native path, is not scheduled by the worker or exposed over HTTP. The manual Devnet probes save and fsync exact signed bytes before submission. One initial send did not land before expiry; its bytes/history decision were retained before a single replacement. Bounded exact-byte retries then finalized both probes. The primary public Devnet RPC was used; this does not establish canonical independent-provider expiry/recovery acceptance.
