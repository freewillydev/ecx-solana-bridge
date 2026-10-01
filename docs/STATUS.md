# Implementation status — 2026-10-01

**The PostgreSQL local public-test product is now the active runtime.** The
SQLite baseline was stopped and its final snapshot imported with every record
compared. Both new 1% customer conversions completed through the actual API and
worker on real L2L Signet / Solana Devnet. The wrap needed one explicit approved
retry after a proven expired attempt; its original signed bytes remain recorded.

The connection-free full refund completed. Its owner was derived from verified
Solana Pay evidence. After a rate limit interrupted unsigned preparation, the
PostgreSQL cancellation path retained principal, inventory and history; the next
generation returned all 10,000 units. A clean restart preserved financial rows,
critical sequence and terminal customer statuses. See
[PostgreSQL product evidence](evidence/postgres-product-flows.json). Installer
code now provisions private PostgreSQL, read/write roles, typed initialization,
explicit legacy import and private dump backups. ARM64 installation, repeat
installation, reboot, role restrictions and same-host restoration of all 38
tables passed. See [installer evidence](evidence/postgres-installer-arm64.json).
x86-64 PostgreSQL acceptance, full recovery/audit, actual supported-wallet
signing and canonical deployment
remain open. Canonical `implementationReady` remains false.

Earlier SQLite launch/transfer/restart evidence below is historical baseline
coverage. It does not prove the revised PostgreSQL installer or full recovery.

## Verified locally

| Check | Result and evidence |
| --- | --- |
| Haskell application | Builds on macOS arm64 / GHC 9.14.1 with the frozen Cabal graph |
| Financial/state tests | 367 examples pass, plus 100 generated arithmetic cases; [test output](evidence/haskell-tests.txt) |
| SQLite actually linked | 3.53.4, exact upstream source identity checked by the application; [doctor](evidence/doctor.json) |
| Rust helper | Seven tests pass, including unsigned payout previews with an unavailable signer; the separate Devnet setup and deposit-client examples compile; fixed SDK/interface graph in `Cargo.lock` |
| Browser build | TypeScript strict check and esbuild succeed; generated module about 11.6 KiB |
| Declared browser dependencies | npm audit reports zero vulnerabilities at this check; [report](evidence/npm-audit.json). This is not a complete dependency audit. |
| Unix transport | Same Servant customer contract on both sides; socket modes, separate admin API and duplicate-worker lock tested |
| HTTP product | Customer config/liveness/readiness 200 in explicit public-test mode; canonical intake remains disabled; public `/audit` returns 404 and no-store/CSP headers are present. [API evidence](evidence/local-product-http.json), [launch](evidence/local-product-launch.json). |
| Browser inspection | Earlier paused page inspected; [historical screenshot](evidence/local-preview.jpg). Current interface passes TypeScript/build checks; fresh browser and wallet acceptance remain blocked by unavailable browser policy verification. |
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
| Unsigned redemption deposits | Helper-built exact owner/mint/amount/memo, backup/deadline/fee/balance checks and a separate official-SDK tester; actual finalized order deposit captured in the regression suite |
| Late deposit and full refund | A real 10,000-unit receipt first observed after its fixed deadline was held for review, then returned in full to its bound owner; zero bridge fee, 5,000-lamport operator network cost; [evidence](evidence/late-ledger-refund.json) |
| Conclusive outgoing Solana expiry | The rate-limited refund attempt remained saved. Finalized height, invalid blockhash and complete anchored token/SOL histories proved absence; one replacement finalized. Original bytes, preparation and decision remain recorded; [evidence](evidence/late-ledger-refund.json). Independent-provider refusal paths are contract tests, not canonical acceptance. |
| Schema 4→5 | Existing financial rows, pending signed bytes and critical sequence preserved; private snapshot retained; [migration](evidence/expiry-migration.json) |
| Operator retry gate / schema 6 | Expiry leaves an obligation in review; a separate private command rechecks the source and absence proof before recording operator approval. Tests prevent automatic replacement, revival after refund and approval after a source reorg. The actual ledger upgrade preserved all financial records; the CLI refused the already-settled refund, created no approvals, and the worker restarted with healthy scans; [evidence](evidence/operator-retry-upgrade.json). Successful approval currently has contract-test coverage; the earlier live replacement preceded this gate. |
| Quote operating budgets / schema 7 | Separate payout/refund allowances, immutable fee ceilings, atomic transfer to payment holds, rolling 24-hour caps and queue limits including extra refunds. Concurrent admission, expiry/failure/refund, clock rollback and restart checks pass. The real ledger upgrade preserved financial records; old costs were conservatively timestamped, private budget readback matched, and all scans restarted healthy; [evidence](evidence/operating-budget-upgrade.json). New budgeted quote/payment behavior currently has contract-test coverage. |
| Native quote admission | Daemon-classified scripts, owned/watch-only refusal and unsigned funding for exact native net/refund amounts. The real node accepted normal amounts and the tested 294-unit P2WPKH output; it refused 293 units, a wrong-network address and a custody address. Wallet state and all financial ledger rows stayed unchanged, with healthy scans after restart; [evidence](evidence/native-admission.json). Full customer intake and other native address-type acceptance remain separate gates. |
| Solana quote admission | Official-SDK wallet/ATA checks, account policy, exact net/full-refund fee estimates, balances, rent ceilings and unsigned simulation. Actual Devnet accepted both directions and simulated a fresh recipient ATA at 1,488,440 lamports; custody, mint and token-account destinations were refused. The helper had no signer configured, no funds moved, financial records stayed unchanged and all scanners restarted healthy; [evidence](evidence/solana-admission.json). New-ATA creation here is simulation only; customer HTTP/browser acceptance remains. |
| Order provisioning / schema 8 | The real ledger upgrade preserved all financial records and the three previously issued instructions; [upgrade](evidence/provisioning-upgrade.json). A real process exited immediately after Signet address allocation. Its replacement recovered the saved label and issued the same address; retries allocated none. A Devnet redemption memo was also issued/replayed. Both unfunded one-minute quotes expired on the real clock and released their holds; no deposits, payments or postings were added, and all three scans restarted healthy; [acceptance](evidence/order-provisioning.json). Backup-failure, pause, stale-scan and concurrency cases have contract coverage. This does not complete remote restore or browser acceptance. |
| Continuous custody checks / schema 9 | Worker checks include known unbooked outgoing effects, native fees, Solana failure fees/rent, ledger revision and history consistency. Contract tests cover drift, concurrency, stale reads, source loss and changed settlement anchors. The actual upgrade preserved every financial row and critical sequence; all three real custody balances matched twice across reopening and in the restarted worker. No order or payment was added at that checkpoint; readiness stayed 503. [Evidence](evidence/custody-reconciliation.json). The later paused-worker test below supplies live native in-flight evidence; Solana in-flight acceptance, complete reorg accounting and host-loss recovery remain. |
| Unsigned recovery / schema 10 | Native funding now saves its validated draft before locking inputs. Cancellation journals an exact generation and cleanup, excludes late callbacks, and retains principal, inventory and unused fees. Contract tests cover lost unlock replies/reopen, unknown locks, changed drafts, custody failures, subsequent refund and source loss. The real upgrade preserved every existing financial row and critical sequence; the command refused a completed payment, and restarted custody checks matched. [Upgrade evidence](evidence/unsigned-recovery-upgrade.json). |
| Real unsigned interruption and cancellation | One actual 10,000-unit Signet deposit funded the test. Separate processes exited after saving the real Solana request and the real native refund draft, before each signer. Both exact generations were cancelled; native cleanup released only its recorded inputs. One generation-one native refund returned the full 10,000 units, with a 208-unit operator fee. No Solana payout was signed. Both drafts and cancellation decisions remain recorded. Completed-command/payment replay changed no financial records, earlier records were preserved, and the rebuilt worker restarted with matching custody and three healthy scanners. [Evidence](evidence/unsigned-preparation-recovery.json). Lost unlock replies, foreign locks and source reorgs have offline contract coverage; this does not complete restore/reorg recovery. |
| Ordinary paused-worker recovery / live native in-flight check | One real 10,000-unit Devnet redemption paid 9,900 native units with a 141-unit network fee and 100-unit wrapped bridge fee. The submitting process exited immediately with saved `BroadcastIntent`. The normal worker restarted paused, matched the 10,041-unit unbooked native outflow while the exact transaction was in the real mempool, then booked that transaction after confirmation. Exactly one new signed attempt exists. The private `recover` command subsequently changed no financial rows or critical sequence; all earlier financial/binding rows were preserved. The final worker has three healthy scanners, matching custody, no pending payments/holds and readiness 503. [Evidence](evidence/paused-worker-recovery.json). Eight new offline examples cover no-send behavior, failure, source review, expiry and independent attempt progress. This does not complete native-node restart, reorg or host-loss restore. |
| Native locks after a real node restart | A new real 10,000-unit Devnet redemption saved its unsigned native draft and exited before the signer. The dedicated Signet daemon restarted with the same binary, arguments, chain identity and wallets; its advisory locks were empty. The ordinary paused worker validated and restored exactly the two recorded inputs, with no financial or critical-sequence change. Repeating recovery restored zero additional inputs. Exact cancellation retained principal/inventory/fees, then one generation-one payout paid 9,900 native units with a 141-unit network fee. All seven prior orders were preserved; completed recovery replay changed no financial records. Final custody matched and readiness stayed 503. [Evidence](evidence/native-lock-recovery.json). Fifteen additional offline examples cover signed/unseen attempts, mempool eviction, source review, pending cancellation, foreign/changed inputs, lost replies and false acknowledgments. This does not complete host-loss restore, replacement families or reorg accounting. |
| Stale snapshot with a subsequently completed real payout | The sequence-27 snapshot predates the latest redemption's order, source and payout. Replaying an isolated copy against actual Signet/Devnet retained the 10,000-unit receipt as unallocated with no obligation, flagged the unknown native payout, and refused custody certification while paused. Reopening and replaying the copy changed no financial rows; all prior financial/binding rows survived. The live sequence-31 ledger and original snapshot were unchanged; no chain mutation was invoked. [Evidence](evidence/stale-snapshot-quarantine.json). This does not establish highest-backup selection, key restoration, signer fencing or operator resume. |
| Database failure boundary | Local SQLite tests exposed a failed COMMIT leaving a transaction open and automatic rollback masking `SQLITE_FULL`. The application now rolls back action/commit failures, preserves the original exception, and prevents further ledger use after database or cleanup failure until reopening. Four added cases cover request cancellation, an actual deferred-constraint COMMIT failure, a bounded page-limit `SQLITE_FULL`, and a failed BroadcastIntent write; balances, sequence, exact bytes and holds survive reopening. The rebuilt application then reopened the actual sequence-31 ledger and restarted with unchanged financial/binding rows, matching custody, healthy scanners and readiness 503. [Evidence](evidence/ledger-transaction-fence.json). File-page limits do not establish physical disk-full or power-loss durability. |
| Native settlement finality / schema 11 | The actual upgrade preserved all financial/binding rows. Disconnecting the existing payout's block only in the dedicated node's local view returned that payment to the mempool. The normal paused worker journaled one review, exposed `NeedsReview`, and retained the review across restart. Reconsidering the block reconfirmed the same payout; completed replay and another restart changed no financial rows, costs or attempts. Sequence advanced 31→33 for the two recovery decisions. [Evidence](evidence/native-finality-recovery.json). The harness's public GET after the intermediate restart returned a transient 503; its private audit had confirmed the review and its cleanup restored the block. Continuation finished without repeating disconnection. New anchors, missing/conflicting bytes, changed costs/policy, stale evidence, identity refusal and additional-refund customer status have eleven offline contract examples. This is not public-consensus reorg, source-loss, compensation or replacement-family acceptance. |
| Worker reconnect | Customer Unix requests now use fresh connections, with retries still disabled. A regression test retains GET and POST clients across a real worker/socket replacement. The rebuilt local public proxy also stayed running across an actual worker restart: its first authenticated order GET returned 200 and its first invalid-capability POST returned the expected 409, with one request each and no financial change. [Evidence](evidence/unix-worker-reconnect.json). This addresses the stale connection observed during the finality test; genuine worker downtime still returns an error. |
| Source recovery / schema 12 | Loss of eligibility journals review without releasing obligations or holds. A proven native conflict records a balanced, reversible `source_deficit`; unavailable RPC evidence preserves any recorded deficit. Sixteen offline examples cover unsigned, signed, possibly-sent and paid exposure, restoration, ambiguous/stale proof, rollback and journal immutability. The actual upgrade preserved all financial/binding rows. Local disconnection of the original wrap's real source block exposed `NeedsReview` before and after worker restart; restoring it returned the same order to `Paid`. The absent mempool source remained unavailable, with no invented deficit. Completed replay and restart retained all eight orders, seven attempts and balances; critical sequence advanced 33→47 for source and affected native-payment decisions. [Evidence](evidence/native-source-recovery.json). No public consensus reorg, confirmed double spend or new transfer was produced. Permanent loss treatment and full resume remain unfinished. |
| Restored source approval / schema 13 | Source loss snapshots the exact suspended obligation and work. A private operator command rechecks source, pending outcomes and custody before restoring only its previous `ready`/`paying` state. Changed work, expiry, prior failure, pending cancellation, stale restoration and paid obligations are refused. No funds, bytes or attempts change; later sending requires backup coverage of the approval. Sixteen offline cases cover success across work stages, refusal, replay/reopen and atomic rollback. The actual upgrade retained all financial/binding rows, source decisions and sequence 47. The CLI refused the already-paid wrap without creating an approval; the normal worker restarted with matching custody, healthy scanners and readiness 503. [Evidence](evidence/source-approval-upgrade.json). Successful approval has offline coverage only; this is not full resume or permanent-loss handling. |
| Native loss capital / schema 14 | A private command covers the full proved source deficit with explicitly chosen, unreserved native float/earnings. It preserves customer claims, work and protected allocations; pending obligations remain reviewed. Source return releases the same capital split once, atomically with deficit reversal. Twenty-one offline cases cover exposure stages, fresh chain/custody proof, reservations, unavailable evidence, replay/reopen and atomic cover/return failures. The real migration and refusal to fund the already-restored wrap preserved all financial/binding rows, source decisions and sequence 47. The worker restarted with matching custody and healthy scanners. [Evidence](evidence/source-loss-upgrade.json). No live loss was funded. Active lost-source obligations, missing destination value and full resume remain unfinished. |
| Unsigned native replacement construction | The adapter retains every original input, the exact recipient/amount, change address, replay fields and saved fee ceiling; increased fees reduce change only. It verifies actual chain/wallet state, confirmed owned prevouts, known mempool spenders and unchanged views. Thirteen offline contracts exercise economic changes, unavailable/conflicting inputs, wallet lag, wrong identity, unexpected signatures and changing evidence. The real Signet node constructed an unsigned candidate from the earlier confirmed payment and the production pending guard refused that confirmed member. Balances, locks and key counts stayed unchanged. [Evidence](evidence/native-replacement-construction.json). This does not implement durable family authorization, replacement signing/sending, family custody normalization or single-winner settlement. |
| Single economic settlement / schema 15 | Settlement requires an unresolved intent, a paying/reviewed obligation and its active correctly denominated fee hold. SQLite independently permits only one settled attempt per intent. Ten offline cases cover either candidate winning, concurrent/late callbacks, reopening, released/wrong holds, accidental intent reopening and atomic winner-write failure. The real migration, completed recovery replay and worker restart retained all financial/binding rows, eight orders, seven attempts and sequence 47. The unique index exists and all custody balances/scans match. [Evidence](evidence/settlement-winner-upgrade.json). This protects the ledger boundary; native family authorization/signing, winner observation and reorg compensation remain unimplemented. |
| Durable native replacement drafts / schema 16 | Private commands persist or cancel an unsigned higher-fee template against the exact pending original attempt, source and current custody. Replay is idempotent, decisions are immutable and bounded, and cancellation retains the original payment and reservations. Eleven offline cases cover restart, changed work, cancellation, stale custody, source loss, original settlement during drafting and atomic write failure. The real migration, settled-parent refusal, completed recovery replay and worker restart preserved all eight orders, seven attempts, financial/binding rows, source journal and sequence 47. Custody and all scanners matched. [Evidence](evidence/replacement-draft-upgrade.json). No live replacement draft or new signature was created; signing, member observation, family custody and reorg compensation remain unfinished. |
| Native family journal, signer and recovery / schema 17 | Up to eight same-input members share one intent and fee hold. Signing stays bound to its exact draft; either member may settle, custody counts one active effect and eviction restores one lock set. Twenty-eight new offline cases cover lineage, signing failures, cancellation/source changes, both winners, stale/conflicting views, backup/send selection, reopening and same-winner reconfirmation. A changed winner retains review. The real upgrade/refusal/replay/restart preserved all eight orders, seven attempts, financial/binding/source records and sequence 47; custody/scanners matched. [Upgrade](evidence/native-family-upgrade.json). The reader also verified one existing confirmed real Signet payment without wallet changes. [Readback](evidence/native-family-readback.json). No replacement signature or member was created live; winner-change compensation and real replacement acceptance still gate the signing/send command. |
| Usable customer API and automatic worker | Real HTTP orders completed in both directions: 10,000 native → 9,980 wrapped; 10,000 wrapped → 9,900 native. Exactly two new payout attempts, all prior financial rows preserved, no pending intents/fee holds, and all three custody balances match. Clean launcher stop/start retained the same completed orders and financial rows. [Evidence](evidence/local-product-transfers.json). Customer deposits used the dedicated native wallet and official-SDK client; this is not browser-wallet acceptance. |
| Native winner-change accounting / schema 18 | A proved different member becomes the single settled winner; only the network-fee difference is booked, with principal and bridge fees unchanged. Former winners retain immutable evidence, and underfunded operating allocations block resume. Twenty added contract cases cover both directions, cycles, concurrency, reopening, stale evidence, atomic failure and output ownership before signing. The combined 367-example suite passes; the actual product-start migration preserved all prior records. No live replacement family was signed in this checkpoint. [Migration](evidence/local-product-launch.json). |
| Operating funding for local testing | A dedicated official-SDK client saved and sent one 0.1 Devnet SOL transfer from the existing user-funded setup payer. The private command scanned the finalized receipt and assigned it to operating fees once. Replay/restart retained ten orders, nine attempts and all prior financial rows. Operating SOL is now 103,486,560 lamports. Four additional contracts cover absent evidence, wrong amount, non-SOL assets, reviewed observations and idempotent reopen. [Evidence](evidence/local-operating-funding.json). |
| Snapshot freshness during normal chain progress | Native/Solana history-head advancement and concurrent ledger revisions invalidate custody certification without imposing a permanent operator pause. Intake/readiness and payment scheduling stay blocked until a fresh successful check. Balance discrepancies, changed payment evidence and existing operator pauses remain blocked. Contract tests cover refusal while stale, fresh recovery and retained manual pause; the original live pause was observed before the fix. |
| Bounded read retries | Explicit read-only RPC allowlist; at most two waits, bounded numeric Retry-After; sends and wallet mutations are never retried by the transport layer |
| Real ledger-driven redemption | 10,000 wrapped units in, 9,900 native units out, 100-unit token bridge fee and 141-unit native network fee; confirmed native payout and matching custody balances; [evidence](evidence/first-ledger-redemption.json) |
| Native payout interruption | The acceptance process was terminated with the payout in the real mempool and restarted paused. It reconciled the same transaction after confirmation; no second attempt was created; [interruption](evidence/native-payout-interruption.json). This is one real interruption point, not complete host-loss recovery. |
| Both directions replay/restart | Reopening and replaying the wrap, refund and redemption changed no financial records or signed attempts. After normal-worker restart, all three scans were healthy, authenticated reads returned two `Paid` orders and one `Refunded`, and readiness remained 503; [replay](evidence/both-directions-replay.json), [restart](evidence/both-directions-restart.json) |

The earlier native payment and three-unit Solana payments were standalone probes. The later wrap and redemption completed through the application ledger with dedicated public-test wallets and a command-line acceptance tool. A separate late deposit was fully refunded. These results establish both real chain directions, but not browser-wallet support or full restart/host-loss recovery. Deterministic codec and RPC fixtures remain explicitly labeled as offline tests; the captured order-deposit fixture comes from the actual finalized Devnet transaction.

## Coverage against the approved sequence

### Execution checkpoints and change control

The current architecture is the approved Haskell application, two real-chain adapters, PostgreSQL/Opaleye ledger, severity DSL and thin connection-free interface. The older gate table below records baseline work; the [integrated implementation plan](IMPLEMENTATION-PLAN.md) governs current sequencing. These are delivery gates, not equal-sized percentages. The earlier overall percentage estimates were subjective and are no longer the progress measure.

| Gate | Required remaining evidence | Current state |
| --- | --- | --- |
| U1 — Usable local test bridge — **first priority** | Existing real-chain core exposed through customer API and thin UI; both automatic transfer directions; saved-order reload; simple start command; actual supported-wallet signing | API, UI and launcher implemented; both real customer-API transfers and a clean restart pass with matching custody. Actual wallet/browser acceptance remains blocked by unavailable browser policy verification. Additional recovery gates below follow this explicitly authorized local test milestone. |
| R1 — Complete native replacement workflow | Exact private operator draft/sign/send; backup and source gates; one actual Signet replacement family, confirmation, paused restart and matched custody | Winner-change accounting and signer guards pass contract tests; schema 18 is applied. Integrated operator send and real-family acceptance deferred until U1. |
| R2 — Close recovery state transitions | Explicit covered-source resolution, proved missing-destination treatment, finalized Solana history-loss handling, and unchanged claims during ambiguous evidence | Partial; existing source/finality/capital journals are the implementation base. Follow U1. |
| R3 — Complete restore and resume | Critical backup coverage, old-ledger/old-signer fencing, key restore, exact-byte recovery and a final resume decision; independent-provider Solana expiry, in-flight and backlog acceptance | Partial; follow U1. Remote and clean-host checks also close D1. |
| N1 — Actual ECX betanet | Official node/provenance/checkpoint, separate funded profile, replay fields and real deposit/payout/refund | Not started; real node and test allocation required. |
| D1 — Reproducible installation and recovery | One-line Ubuntu installation from verified pinned artifacts; service/helper isolation; retained remote backups; fresh-host/key restoration and affected fault checks | One-command source and compiled installers pass on local Ubuntu 24.04 ARM64, including separate users, sandboxed helper, real-chain doctor, repeated installation and VM reboot. Signed publication, x86-64 acceptance, remote backups and full host/key restore remain. The separate x86-64 Ubuntu 24.04 QEMU VM has booted without host mounts; its source installer is running, with acceptance still pending. |
| S1 — Reviewable open-source test release | Frozen source and dependency/license/advisory evidence; installed-release acceptance and independent review; material findings resolved with focused regression checks | Not complete. Reproducible notice collection covers all 333 dependency entries; Bitcoin Core source notices and SQLite disclaimer excerpts are recorded with provenance; system-library notices and native applicability review remain. Release-notice integration is implemented but awaits a completed Linux build; independent review remains. See THIRD-PARTY.md. Publication and valuable-fund deployment are not implied. |
| C1 — Remaining approved rollout | Canonical mint/reserves/identities and explicitly authorized pilot; separately authorized real market/liquidity integrations; conditional official mainnet activation | Preserved in the full plan; external facts and explicit valuable-fund authorization required. |

For each gate, implement the complete workflow, run its relevant tests, perform its real-network/host acceptance where required, and record the result once. Batch related schema/code changes before the live upgrade. Do not repeat completed one-shot acceptance drivers or add a new deployment checkpoint for each internal function. Passing a gate ends that work unless a specific failure, security finding or changed requirement reopens it. A proposed extra task must identify the requirement it satisfies or the concrete defect it fixes; otherwise defer it. Keep all remaining approved checks in the stage table below, including independent review, rather than declaring completion from test counts or matching balances.

Report the active gate, what evidence closed since the previous update, its next acceptance action and any verified blocker. Frozen dependencies stay pinned; upgrades require an actual compatibility/security reason. Real-network limits belong in the supported operating behavior and tests, not in substitute networks or silent retries of financial mutations.

| Plan stage | Status | Remaining exit requirements |
| --- | --- | --- |
| 1. Dependency and integration boundary | Partial | Linux ARM64 build/systemd/helper sandbox passed; actual browser-wallet finalized deposit and dependency provenance/notice/security review remain |
| 2. Economic/API contracts | Partial | Both chain admission checks and recoverable order provisioning passed scoped real-network checks; finish full state/error contracts for replacement/reorg/recovery and validate all exception examples |
| 3. Durable ledger/worker | Partial | Unsigned cancellation, generation fencing and database failure guards are implemented. Request cancellation, failed COMMIT and bounded SQLite capacity failure pass local tests. Physical filesystem/power-loss fault injection, production-size reconciliation and complete restore coverage remain |
| 4. Both chain observers | Partial | Real order-bound deposits, all three histories and continuous custody checks verified, including a live unconfirmed native payout. Solana in-flight acceptance, long-backlog recovery and complete reorg accounting remain |
| 5. Settlement and recovery | Partial | Source rechecks, intent/backup barriers, exact-byte sends, fee/rent settlement, real refunds, conclusive Solana expiry, unsigned cancellation, paused-worker recovery, native lock restoration, source-deficit accounting/capital coverage and same-payment reconfirmation work. Quote operating allowances and rolling caps are implemented. Still need explicit resolution of active lost-source obligations, missing destination value, full Solana history-loss recovery, live native replacement acceptance, full resume/restore checks, independent-provider live expiry acceptance and remote backup orchestration |
| 6. Usable public-test bridge | API and launcher verified; browser acceptance pending | Both automatic real-chain directions pass through the customer API. Complete actual desktop-wallet signing, browser reload and the subsequent wallet/edge-case matrix. |
| 7. Actual ECX betanet | Not started | Adequately sized host/node, official daemon/checkpoint and replay-policy tests, funding and real round trips |
| 8. Installation and recovery | Not complete | Ubuntu ARM64 installer, checksummed local package and clean-VM service acceptance passed; signed release distribution, remote backup permissions/retention and key/ledger host-loss restore remain |
| 9. Independent review | Not performed | Freeze and independently review the working installed test release before valuable funds |
| 10. Canonical pilot | Not authorized/launched | Operator identities, reserve/supply evidence, limits, remote backups, independent RPC and explicitly allocated funding |
| 11. Market integrations | Not started | Real pool decision, separately authorized LP capital, actual Jupiter routes and historical price data |
| 12. Future mainnet | Conditional | Official launch identity/terms and a separately reviewed activation |

Some pure ledger work overlapped the first integration stage, as allowed by the plan. Passing these tests does not close any later stage's real-chain or recovery gate.

## External inputs and next actions

1. **Devnet funding received:** the user funded the existing setup payer with 10 Devnet SOL. Setup and two tiny payout probes finalized. The actual mint is `Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM`; it is a public-test mint, not canonical ECX.
2. Finish U1 first: both automatic customer-API transfers and a clean launcher restart have passed; actual browser-wallet use is the remaining main-product check when browser access is available. Preserve existing accounting, source, identity, amount, fee, idempotency and custody protections. Additional recovery/restore cases follow this local test milestone; canonical intake remains disabled.
3. Current local product checkpoint: custody matches 1,879,346 native units, 100,000,020,034 wrapped units and 103,486,560 fee-payer lamports. Ten orders are terminal: six `Paid`, two `Refunded`, two `ExpiredUnfunded`; schema is 18 and critical sequence is 53. Nine signed attempts are preserved, including the earlier expired Solana attempt. There are no unresolved intents or active fee holds. Both new orders were created through HTTP and paid by the running test worker, without a private order/payment-pass tool. Their deposits came from dedicated real-chain tester clients, not a browser extension. The eight prior orders and financial/binding rows were preserved, and clean restart changed no financial rows. Matching totals do not establish full host-loss recovery or canonical reserve backing. Both Solana histories retain their actual setup origin.
4. **Linux installer:** at the user’s request, completed on this computer using separate Ubuntu build and clean runtime VMs on the external drive. Docker was left alone. The runtime VM uses real L2L Signet and Solana Devnet identities in observation mode, with a separate native wallet and no copied custody signer. See INSTALL.md and evidence/linux-installer.json. Remote backup/restore remains separate.
5. Complete remaining recovery and installation gates before a broader or valuable-fund pilot. The explicitly authorized local public-test product proceeds now. ECX betanet still requires its real node and separate test allocation.

Unfinished implementation is an additional requirement beyond those external inputs. Funding or server access alone will not make the current application ready.

## Dependency decisions and open review items

- Compatible Solana SDK 3/interface versions are pinned together. Selecting each newest crate independently produced incompatible instruction/address types; the recorded graph compiles and matches independent wire checks.
- The JavaScript setup dependencies were removed after their graph reported advisories. Test mint setup now uses the Rust SDK example, separate from the runtime helper. Wallet Standard and build tools are the remaining declared browser dependencies.
- The default `direct-sqlite` package bundled SQLite 3.45.0. The application now uses `+systemlib`, verifies the selected 3.53.4 source identity, and tests snapshots using the same selected CLI. The target release still needs verified Linux native artifacts.
- The Signet probe used the existing Bitcoin Core 30.2.0 binary from the local BitWindow installation. Its SHA-256 is recorded, but release signature/provenance validation is pending. This is not an approved release dependency merely because the probe succeeded.
- The dependency manifest includes the compiled Haskell graph, Rust graph including setup/tests, npm lock entries, licenses and available checksums. Compiler-distribution notice assembly, transitive review, Rust/Haskell advisory analysis and release signing remain outstanding.
- No public repository, published release, official token minting, LP contribution, customer-fund transaction, external outreach or public launch was performed.

The original plan's security/recovery scope remains on the release backlog. The latest user instruction authorizes a bounded local public-test product first; only the explicit Signet/Devnet command enables intake.

The native preparation path has RPC contract tests, real unsigned validation and a completed ledger-driven redemption. The earlier standalone signed native probe is separate evidence. The first wrap's native transfer was sent by the dedicated tester as a deposit; the redemption payout was signed, persisted and settled by the application.

The normal worker now reconciles already-recorded payment outcomes while paused. Ordinary `worker` mode retains the disabled intake gate; explicit `test-worker` mode enables the existing payment path only on the public test profile. The scoped order acceptance tool uses the real payment pass. Schema-5 expiry was exercised by the real refund using the primary public-Devnet RPC; canonical independent-provider recovery remains a separate gate. The earlier standalone probes and client-side expiry decisions remain separate historical evidence.

The treasury checkpoint sent no transactions. Its operator tool checks the exact existing public-test deployment, requires zero customer orders, verifies the known funding and finalized probe evidence, and matches current chain balances. Customer attempts cannot be reclassified as treasury spends. An on-chain signature saved only as `signed`, without `BroadcastIntent`, now triggers review. The ordinary worker stays paused; the separate public-test mode is described above.

## PostgreSQL / typed DSL integration checkpoint (2026-10-01)

The new private `ecx-postgres-seam` executable compiles against Opaleye 0.10.8.0,
postgresql-simple 0.7.0.1 and the existing GHC 9.14.1 toolchain. Servant handlers
resolve constrained operation packages to result/severity-indexed DSL values;
the central hoist selects separate safe and critical evaluators. A real local
PostgreSQL 16.14 status row was read, updated through the critical pause DSL,
read again and independently checked using psql. Safe reads run in PostgreSQL
read-only transactions; there is one critical evaluator invocation site.

This establishes compatibility and the real execution seam, not financial
migration completion. The existing funded SQLite worker is unchanged. Typed
financial tables, separate database roles, migrated workflows and real-chain
acceptance remain next. Evidence: [postgres-dsl-seam.json](evidence/postgres-dsl-seam.json).

### Financial schema translation

The complete final legacy schema now has fresh PostgreSQL DDL in
`migrations/postgresql/001.sql`, with a column/object mapping and a reproducible
strict translator. PostgreSQL accepted all 38 tables, 12 explicit indexes, five
views and 84 triggers. Targeted checks verified immutable postings, asset
constraints, custody revision updates and JSON validation; test rows rolled back.
Typed Opaleye definitions for deployment, events, postings and custody compile.
This is schema/access-layer progress; financial runtime conversion and exhaustive
semantic parity checks remain. [Evidence](evidence/postgres-financial-schema.json).

### Typed financial tables and core journal

All 38 financial tables now have explicit generated record types, nullable/default
field mappings and Opaleye adapters in `Bridge.Postgres.Schema`. The core
PostgreSQL ledger implements session ownership, serialized transaction boundaries,
connection fencing, audited pause, critical sequences, balances and balanced
postings. A dedicated local database contract passed balanced write, unbalanced
rejection, sequence increment, competing-worker refusal and close/reopen checks.
Financial workflow conversion is still underway; this is not customer conversion
or real-chain acceptance. [Evidence](evidence/postgres-journal.json).

### Budget and order-storage conversion in progress

The PostgreSQL budget module now uses typed Opaleye queries for operating holds,
allocations, rolling spent costs, high-water accounting time, daily limits,
quote cost reservations and transfer to payment costs. Order storage now has
capability-checked reads, saved idempotency matching, immutable instruction binding
and backup-coverage lookup. Both modules compile. These are internal building
blocks: public recovery-aware order views, full admission/provisioning and worker
wiring are still incomplete; no customer flow has switched to PostgreSQL yet.

### PostgreSQL admission and recovery-aware views

Order admission now has a typed transaction for idempotency, 1% saved quotes in
both directions, queue/inventory limits, operating reservations and scanner/custody
freshness. Recovery-aware order views use typed projections of the existing latest
recovery/accounted-loss views and preserve instruction visibility/backup gating.
The library compiles. Runtime order acceptance is not yet verified; native
provisioning/issuance, observation/payment wiring and the revised connection-free
source/refund contract still need conversion before customer use.

### Native provisioning journal conversion

PostgreSQL order storage now implements native allocation claims, recovered
address recording and instruction issuance through Opaleye. Allocation replay
returns recovery-only permission; paused/expired recovered addresses remain
recordable without reopening the quote. Issuance retains backup coverage,
readiness, deadline and quote/operating reservation checks plus its audit record.
Compilation passes; real node integration and runtime provisioning acceptance
remain before this replaces the existing worker path.

### PostgreSQL provisioning orchestration

The order orchestration now compiles with the existing real native/identity RPC
transport, preserving commit-before-allocation, recovered-address lookup, backup
callback and instruction issuance. Expiry releases quote reservations atomically
without marking a funded order unfunded. This path remains unwired to the paying
worker: observers/reconciliation/payment conversion, consistent 1% adapter quote
previews and connection-free Solana Pay association are still required. No new
addresses, deposits or payouts were performed in this checkpoint.

### PostgreSQL receipt observation conversion

The typed observation module compiles for receipt identity/amount/policy checks,
atomic first-receipt accounting, confirming receipt updates, scan cursor fencing,
instruction lookup and saved native-depth policy. It intentionally refuses source
eligibility loss or existing recovery history until source-recovery journaling is
converted; this is a temporary migration limitation, not the final behavior.
Full evidence-page commit, observer wiring and payment settlement remain pending.
The existing paying worker is unchanged.

### Source journal integrated into receipt updates

Typed source-recovery journaling now preserves missing-value postings, restored
operator-loss allocations, critical sequences, audit records and pause behavior.
Payment/replacement work hashes retain the legacy tuple encoding and order.
Receipt updates now journal lost eligibility and verified non-native restoration;
the temporary conversion refusal has been removed. Compilation passes, while
runtime recovery parity, focused native-source proof checks and full observer/page
commit conversion remain pending before paying-worker cutover.

### Atomic PostgreSQL scanner-page commit

The typed scanner-page commit now includes origin/cursor fencing, deposit updates,
immutable evidence, known-payment/approved-treasury classification, sticky event
review, cursor advancement and scanner health in one transaction. Failure booking
preserves prior success, audits changed errors and pauses the deployment. The
existing economic evidence decoder is reused. The library compiles; adapter wiring,
real scan replay, custody reconciliation and payment conversion remain before
cutover. This checkpoint does not change the running funded worker.

### Shared real-chain observer wired to PostgreSQL storage

The existing observer now uses a narrow storage interface; both backends retain
exactly the same real RPC identity, history, decoding and finality logic. The
PostgreSQL implementation supplies checkpoints, instruction/policy lookups,
evidence commits, pending verification, promotion and scanner health. Eligible
exact deposits become reserved conversion obligations through typed transactions.
The full existing bridge-test suite passes after the shared observer refactor.
Actual PostgreSQL-backed chain replay, custody reconciliation and paying-worker
wiring remain incomplete; no live funds were moved.

### Consistent historical ledger import

The maintenance importer copied the existing local ledger's consistent SQLite
snapshot into an isolated PostgreSQL schema. All 545 records across all 38 tables
matched, column for column, inside the destination transaction before commit.
Foreign keys remained enforced; user triggers were temporarily suspended to retain
historical journals/revisions. Generated identities were advanced to imported
maxima. Snapshot/full comparison report stay private outside Git; the paying worker
was not switched. [Evidence](evidence/postgres-ledger-import.json).

### Real PostgreSQL-backed chain replay

The imported PostgreSQL ledger ran the shared real L2L Signet/Solana Devnet
observer successfully: native, token and operating SOL scanners all recorded fresh
success, no errors and no review events. It remained paused pending reconciliation;
no payout engine, signer, address allocation or broadcast was invoked. The original
funded worker was unchanged. [Evidence](evidence/postgres-real-scan.json).

### PostgreSQL custody integrated with shared transaction verification

The real imported ledger now passes the existing custody reconciliation algorithm
through typed Opaleye storage: Native 1,879,346, Wrapped 100,000,020,034 and Sol
103,486,560 base units all match real chain balances exactly. Snapshot validation
retains saved settlement evidence, history freshness, source reviews and balanced
journals. Shared saved-payment verification now accepts the PostgreSQL storage
boundary, including native family lineage and in-flight effect normalization.
There were no pending effects in this run; that path still needs integrated live
acceptance after payment writes are ported. The existing 367 regression examples
passed. No signing or sending occurred and the imported deployment stays paused.
[Evidence](evidence/postgres-custody.json). Next: payment preparation, journal and
settlement writes, then the production worker/API and connection-free interface.

### Shared payment preparation and settlement wired to Opaleye

The existing native/Solana preparation and payment-pass algorithms now accept the
PostgreSQL store through narrow storage interfaces. Typed transactions preserve
fee holds, preparation generations and retry authorization, cancellation fences,
draft/signed-byte storage, source refresh, broadcast intent/backup authorization,
native replacement send choice, successful settlement, failed Solana fees and
expiry records. No second signing or chain-validation implementation was added.
The library and its consumers compile. Eight historical settled payments were
validated against immutable saved transaction policies and the real adapters;
idempotent settlement acceptance passed and custody still matched exactly. No new
payment was signed/sent. New PostgreSQL preparation/settlement writes need actual
integrated acceptance, and production API/DSL, recovery startup, refunds, backups,
connection-free interface and installer remain unfinished.

### Actual Servant API resolves operations into the severity DSL

The new PostgreSQL runtime serves the existing customer/admin API types. Handlers
construct existential operation requests and resolve them to severity/result-indexed
DSL values; one dispatcher invokes critical evaluation. The public handler facade
does not expose worker commands, DSL constructors or evaluators. Safe evaluation
holds only public configuration, database connection settings and a backup flag,
and uses Repeatable Read / Read Only transactions without signer or chain transport.
Critical evaluation supplies the real order, deposit, observer, custody and shared
payment workflows. Deposit hints currently use critical evaluation; there is no
safe writable inbox capability.

`postgres-api CONFIG` reads PGHOST/PGPORT/PGDATABASE/PGUSER (optional PGPASSWORD)
and serves a paused Signet/Devnet deployment after a real scan/reconciliation.
Actual Unix-socket config, health, readiness (503 while paused), operator pause,
audit and scanner routes passed. Existing bridge regressions passed after storage
interface conversion. This is an integrated API checkpoint, not a paying-worker
cutover: the connection-free Solana Pay contract, startup/recovery, full role/module
isolation, remaining operator functions, UI and installer are still unfinished.
The original funded deployment was not changed.

### Connection-free Solana Pay and thin interface implemented

New PostgreSQL unwrap orders require only the native destination and amount;
`sourceOwner` is absent and the refund field is empty. A durable order-derived
32-byte reference is stored before instructions are issued. The safe payment
instructions route produces a standard Solana Pay v1 transfer URI. The shared
observer matches reference-bearing transactions and verifies Transfer or
TransferChecked, read-only/non-signer reference placement, signing authority, mint,
custody, historical token ownership and exact balance effects. Independent-RPC
verification and pre-send source checks use the same decoder. Legacy memo receipts
remain supported by the shared observer/payment engine. Immutable observation
evidence records the verified source owner for PostgreSQL refund authorization;
the private operator API can create a refund without choosing its recipient.

The thin interface now has manual destinations, integer 1% quotes both ways,
copyable instructions, locally generated QR codes, Solana Pay wallet-opening links,
private saved-order recovery/history, polling, deadlines and payout explorer links.
Wallet Standard connection/signing dependencies and controls were removed. New wrap
admission uses the saved 1% quote; unwrap admission no longer requires knowing the
payer before a wallet pays. Haskell build and TypeScript checking/bundling pass.
An offline reference-placement/ownership contract was added to the existing test
suite; this is not evidence of an actual wallet transfer. New PostgreSQL round trips,
ordinary-wallet Devnet acceptance, rendered UI checks, controlled worker startup
and remaining recovery/installer work still need completion. The funded original
deployment has not been switched. Solana Pay URIs do not select Devnet; the interface
explicitly tells testers to select the matching network in their wallet.

Specification: https://solana.com/docs/tools/solana-pay/specification/version1

### PostgreSQL paying runtime cutover (2026-10-01)

The complete PostgreSQL test worker compiles and runs through the shared severity
DSL dispatcher. It continuously scans, reconciles and advances saved payments;
startup requires fresh custody, resolved intents and supported order cost state.
Unimplemented recovery situations remain paused for explicit completion/review.
The local launcher now accepts `--postgres` with protected libpq PG* settings.

The original SQLite launcher and both children were verified stopped before a
final consistent snapshot. The fresh `ecx_bridge_runtime` database imported and
compared all 546 records across 38 tables. Startup enabled the public-test worker.
A custody/history race now skips payment until fresh reconciliation, as in the
existing worker. Opaleye's full-row updates exposed column-trigger incompatibility;
the schema generator and incremental migration 002 now guard actual value changes.
A rolled-back live PostgreSQL check permitted unchanged quotes and rejected altered
quotes. Existing regression suite: 368 examples, zero failures (primarily legacy
workflow/offline contract coverage; this does not establish full PostgreSQL audit).

Two customer API orders were created with 10,000-unit gross, 100-unit fee and
9,900-unit net. A real Signet deposit and a real Devnet reference-bearing Solana
Pay transfer were submitted using dedicated tester clients. Completion/settlement
is pending verification; this is not browser-wallet acceptance or a release gate.
Private capabilities, signed bytes, snapshots and configuration remain outside Git.

## Integrated setup and interface — 2026-10-01

The compiled ARM64 installer now accepts private interactive configuration, validates
custody key identity without signing, and installs separate public interface settings.
Ubuntu acceptance used actual Signet/Devnet identities without a signer, port 8090,
a support link and repeated installation; liveness passed and intake remained paused.
The customer interface restores saved destination/fee terms, displays the configured
token explorer, and exposes only configured support/trading links. Local browser
reload and order recovery passed; supported-wallet signing remains open.
371 Haskell examples and nine installer checks pass. Cross-release service upgrades
remain separate work; the installer refuses differing existing unit definitions.
[Evidence](evidence/postgres-setup-interface.json).

## Operator runbook — 2026-10-01

[OPERATIONS.md](OPERATIONS.md) now covers customer payments, restricted diagnostics,
paused intake versus offline maintenance, backup/upgrade limits, and separate
mint/metadata, inventory and pool administration. Private `health`, `scanners` and
`audit` reads returned HTTP 200 and valid JSON against the active PostgreSQL runtime.
The guide distinguishes unported SQLite CLI commands and unverified canonical
backing, metadata transactions, liquidity/Jupiter routing and remote restoration.
Documentation does not satisfy those remaining execution gates.
