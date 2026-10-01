# Implementation status — 2026-09-30

**This is an unfinished development checkpoint, not a functioning bridge or a deployable custody release.** `implementationReady = False` in `Bridge.Worker`; it is deliberately not a configuration toggle. New orders and unsigned deposit transactions cannot be requested. No administrator resume endpoint is exposed.

## Verified locally

| Check | Result and evidence |
| --- | --- |
| Haskell application | Builds on macOS arm64 / GHC 9.14.1 with the frozen Cabal graph |
| Financial/state tests | 35 examples pass, plus 100 generated arithmetic cases; [test output](evidence/haskell-tests.txt) |
| SQLite actually linked | 3.53.4, exact upstream source identity checked by the application; [doctor](evidence/doctor.json) |
| Rust helper | Five tests pass; the separate Devnet setup example compiles; fixed SDK/interface graph in `Cargo.lock` |
| Browser build | TypeScript strict check and esbuild succeed; generated module about 6.7 KiB |
| Declared browser dependencies | npm audit reports zero vulnerabilities at this check; [report](evidence/npm-audit.json). This is not a complete dependency audit. |
| Unix transport | Same Servant customer contract on both sides; socket modes, separate admin API and duplicate-worker lock tested |
| HTTP preview | Customer config/liveness 200, readiness 503, public `/audit` 404; no-store/CSP headers; [evidence](evidence/http-preview.json) |
| Browser inspection | Actual local page loaded; both fee previews and the direction-specific refund controls checked; deposits disabled; [screenshot](evidence/local-preview.jpg) |
| Real native chain | Public L2L Signet synchronized; challenge and height-16000 checkpoint match |
| Real native payment | Daemon-funded/signed PSBT, 100,000 units to dedicated tester, 282-unit fee, three confirmations at latest check; [transaction](https://explorer.signet.drivechain.info/tx/b2278e8dd0be7be001a5630545ddb73c83423ee1ee7dbd0327675e27f1642bd3), [evidence](evidence/signet-probe.json) |
| Solana identity | Public Devnet genesis checked; intended test mint does not yet exist; doctor correctly reports `mint_not_found` |

The native payment used the standalone probe and dedicated public-test wallets. It was **not** a ledger-driven cross-chain order. The serialized Solana fixtures are explicitly codec tests and use no substitute network.

## Coverage against the approved sequence

| Plan stage | Status | Remaining exit requirements |
| --- | --- | --- |
| 1. Dependency and integration boundary | Partial | Linux build/systemd/helper sandbox; funded real Devnet mint; actual browser-wallet finalized deposit; dependency provenance/notice/security review |
| 2. Economic/API contracts | Partial | Implement native destination/dust policy, rolling budgets, full state/error contracts for replacement/reorg/recovery; validate all exception examples |
| 3. Durable ledger/worker | Partial | Existing primitives are tested; still need explicit cancellation/disk-full fault injection, production-size reconciliation and restore coverage |
| 4. Both chain observers | Not complete | Wire native output watcher, paginated Solana custody watcher, historical evidence, unknown receipts, freshness checks and cursor recovery; atomic batch primitive is ready |
| 5. Settlement and recovery | Not complete | Wire signing validation, actual fee/rent budgets, serialized scheduler, source rechecks, exact-byte send/rebroadcast, finality reconciliation, native replacement families, Solana expiry and remote backup barrier |
| 6. Usable public-test bridge | Not complete | Both real directions through the browser, new recipient ATA, reload/rejection/expiry flows and supported-wallet matrix |
| 7. Actual ECX betanet | Not started | Adequately sized host/node, official daemon/checkpoint and replay-policy tests, funding and real round trips |
| 8. Installation and recovery | Not complete | Candidate service files exist; installer, release verification, remote backup permissions/retention, key restore and clean-host restore still required |
| 9. Independent review | Not performed | Freeze and independently review the working installed test release before valuable funds |
| 10. Canonical pilot | Not authorized/launched | Operator identities, reserve/supply evidence, limits, remote backups, independent RPC and explicitly allocated funding |
| 11. Market integrations | Not started | Real pool decision, separately authorized LP capital, actual Jupiter routes and historical price data |
| 12. Future mainnet | Conditional | Official launch identity/terms and a separately reviewed activation |

Some pure ledger work overlapped the first integration stage, as allowed by the plan. Passing these tests does not close any later stage's real-chain or recovery gate.

## External inputs and next actions

1. **Devnet funding:** the dedicated setup payer `3psSKHRPopKXPcBajcm2crjoKzrUtWyfsqeprTRMxAqZ` had zero lamports at the last read. A faucet request failed with an internal error; one later retry returned HTTP 429, after which requests stopped. The setup example needs at least 0.02 Devnet SOL; 0.1 gives room for the acceptance probes. Never send mainnet SOL to this test request. The official guide's alternative proof-of-work faucet was inspected: its CLI first requests an ordinary airdrop when the payer has fewer than 5,000 lamports, so it does not resolve this zero-balance bootstrap through the currently rate-limited RPC. It was not installed or run. [Official faucet guide](https://solana.com/developers/cookbook/development/airdrops-and-faucets), [inspected CLI source](https://github.com/jarry-xiao/proof-of-work-faucet/blob/1efbcbf87497ed6d75a9bda373766ab11c5b4501/cli/src/main.rs).
2. Run the already prepared setup example against public Devnet, persist/reconcile its one setup attempt, and confirm the actual eight-decimal mint and custody/tester accounts. Produce real helper transactions including the exact three-unit case and a new recipient ATA. Then prove browser-wallet signing; programmatic test-key signing does not substitute for that step.
3. Finish the two observers and outgoing state machine against those verified interfaces. Enforce instruction/attempt backup barriers and actual chain-balance reconciliation. Preserve the disabled intake gate during this work.
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
