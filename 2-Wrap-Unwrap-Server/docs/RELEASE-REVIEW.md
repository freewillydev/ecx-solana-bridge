# Release review

The Mainnet round trip passed on frozen review candidate `54c2bfd`, deployed in
the Ubuntu ARM64 VM. Executable SHA-256:
`2ce848b303104209bc1bdb5828237db98b613b9c7a32f1a449a4ec93d3c13cbe`.
The canonical unwrap paid 2,970 native units from 3,000 wrapped units, with a
30-unit bridge fee and 141-unit network cost. The return wrap paid 990 wrapped
units from 1,000 native units, with a 10-unit bridge fee and 5,000-lamport network
cost. Finalized Solana transaction:
`569aQRwy8WE9KcMpL2DD8XiANbxquwakX864JEfKnKSFPg5KssVg41TDsh9cpcBg8QQrBh12HgQXA3U9ZfyfL2Xy`.
Alchemy and the independent public Mainnet endpoint returned identical finalized
transaction bodies at slot 453424255, with custody debited 990 and recipient
credited 990 canonical token units. The ledger records `PaymentPaid`; reconciliation
matches Native 97,889, Wrapped 3,002,010 and SOL 4,995,000 base units, all differences
zero. Critical sequence and backup coverage are 55. The remote snapshot at that
sequence retains the exact pre-broadcast attempt for an in-flight recovery drill.
Services are stopped; backup storage remains on the physical Mac. This completes
the funded round trip, not all public-release gates below.

Earlier keyed OnFinality attempts exhausted its observed 40/minute and 200/hour
response-unit limits. Relevant methods cost two response units. Alternative
SolanaTracker history omitted immutable origins and VibeStation rate-limited reads.
The current public verifier passed exact anchored history checks; this does not
establish production capacity or an SLA.

The full macOS root build passed on `3b1b3ba`; all three macOS Cabal suites passed
on `3e34b01`. Linux ARM64 passed the full root build and bridge suite on `3e34b01`;
its all-three-suite result is from `3b1b3ba`. The native-accounting changes also
passed disposable PostgreSQL/restic and actual HTTPS contracts. Subsequent sections
retain historical evidence within its recorded scope; they do not certify a later
artifact.

## Mainnet blocker history and closure

The documented public endpoint `https://api.mainnet.solana.com` passed two read-only
production-validator rounds against Alchemy: canonical identity/authority, complete
custody histories (three token and two operating transactions), exact finalized
transaction bodies and account balances agreed. VM observation then reconciled all
three assets with zero differences. This is pilot evidence, not a public-endpoint
SLA or a production provider recommendation.

The existing 990-unit liability received one explicit retry approval. Required
backup/readiness checks passed and generation 3 was signed, but reconciliation
returned `rpc_error_-32019` before broadcast intent. The node's historical storage
was unavailable; later direct reads succeeded. The error is not evidence of
nonexecution and the failing provider was not identified by the saved runtime code.
The bridge stopped without broadcasting. Subsequent two-provider expiry recovery
retired that exact attempt, and required remote backup caught up to critical
sequence 32. Worker, signer, tunnel and VM stopped; no next generation was approved.
The liability remains unpaid. The archive receiver still shares the physical Mac.

The shared RPC boundary retries this specific storage error only for
`getTransaction`, `getSignatureStatuses` and `getSignaturesForAddress`, sharing the
existing two-retry budget with connection closures and rate limits. Persistent
failure retains its error; writes and other errors never gain retry permission.
That fix (`0d144fd`) passed native/Linux ARM64 builds and Cabal bridge tests and
was deployed. Generations 4 and 5 reached backed-up broadcast intent but stopped
at the final 40-block lifetime guard before send. Pilot pacing of worker 4/signer 3
requests per second per host did not resolve this. Both attempts are now retired
with two-provider expiry evidence; critical sequence and backup coverage are 44.
No generation 6 is approved. Private evidence is retained under `fixed-mainnet-*`
and `paced-mainnet-*` in the deployment directory. The 990-unit payout is unpaid.

Custody inspection now runs the two independent provider reads concurrently against
one saved ledger snapshot. Each still validates finalized accounts and anchored
history; balances must agree and the ledger revision is rechecked. An exception
cancels the sibling inspection. This changes no signing permission, backup barrier,
RPC count or blockhash floor. The existing PostgreSQL contract now proves concurrent
entry and cancellation on failure from either side, alongside disagreement and
stale-view refusal. Native server/checker builds, the complete disposable
PostgreSQL/restic contract and Cabal bridge tests passed. The Linux ARM64 build and bridge suite also passed, and `fd318c9` was deployed
with the existing ledger/credentials preserved. Live readiness took 32.4 seconds
including recovery, with all three custody balances matching; this is not a
measurement of the entire signed-to-send window. A bounded generation-6 trial
reached backup-covered broadcast intent at sequence 49, then paused with
`scanners_not_fresh`; saved custody evidence reported `custody_native_history_advanced`.
Neither provider found its signature in history. The normal recovery workflow
then recorded full expiry proof and backup coverage at sequence 50. No generation 7
was approved; services, VM and tunnel stopped. The 990-unit obligation remains
unpaid. Diagnose moving-history refresh before further funded retries. Private
`parallel-mainnet-*` evidence includes the saved attempt, timing, provider responses
and final recovery readback.


The moving-history regression failed on the old code: a fresh but superseded scan
still led to `custody_not_reconciled`, selecting another custody read instead of a
rescan. `RecordCustody` now atomically marks the affected scan stale through its
existing closed Opaleye implementation. Last-success timestamps remain unchanged,
financial balances are preserved, and scan updates invalidate the custody revision.
The PostgreSQL contract covers both native and Solana advancement, unaffected-stream
preservation, refusal even after a premature custody report, successful rescan plus
fresh custody, and unchanged signed attempts when send authorization is refused.
Native builds, the complete PostgreSQL/restic contract and Cabal bridge tests passed.
No deadline, generation limit, backup requirement or authorization path changed.
The Linux build and bridge suite then passed, and the hash-verified candidate was
deployed. A live readiness check took 17.6 seconds before the explicitly approved
generation-7 retry. It passed required checkpoints and settled the original payout;
no deadline or generation cap was increased. The pre-fix refusals above are retained
as historical evidence, not current unpaid obligations. Private `rescan-mainnet-*`
artifacts hold final ledger, transaction, timing and snapshot evidence.

## Evidence already obtained

| Area | Evidence and limit |
| --- | --- |
| Customer conversions | Real L2L Signet/Solana Devnet wrap/unwrap through the server and dedicated signer; 1% saved fees and quoted net retained. Deposits used dedicated tester clients. |
| Refunds and earned fees | Finalized verified-owner refunds and native/wrapped earned-fee withdrawals through the shared engine, with replay/restart checks. Additional refunds preserve completed conversion views. |
| Ledger migration | Populated schema-18 copies and the original test ledger migrated to schema 21; exact signed work, financial history and 24 Opaleye projections compared. Historical records lacking executable cost policy remain archival only. |
| Browser | GHC-JavaScript fee previews, paused intake, private-link recovery/reload, preserved payout links and network-error/restart behavior checked against the actual server. Actual wallet signing remains open. |
| Custody restoration | Sequence-98 funded ledger restored into separate same-host staging; 24 projections matched and actual chain reconciliation passed. Minimum sequence 99 refused the archive. This does not prove off-host storage or clean-host wallet activation. |
| Automated boundaries | Cabal QuickCheck/protocol tests, actual HTTPS tests and PostgreSQL contracts cover typed authority, immutable accounting, fencing, concurrency, cancellation, source/replacement recovery and encrypted restic restoration. Fixtures do not prove all real-chain cases. |
| Canonical Mainnet mode | Both directions settled on real canonical ECX/Solana Mainnet, with exact net payouts and separately booked network costs. In-flight restoration and other release gates remain separate; earlier canonical process contracts use offline RPC fixtures. |
| Current VM deployment | Separate worker/signer UIDs and restricted PostgreSQL/native credentials passed live denial checks. Required HTTPS backups, an in-flight sequence-9 restore into a separate paused database, and a VM restart passed. The backup receiver shares the physical Mac; clean-host activation and disaster isolation remain open. |
| RPC pacing | Tests cover host budgets, idle/late wakeups, cancellation and actual HTTPS accounting of a read retry versus a refused send. Scoped Signet/Devnet operation passed at the default 2 requests/second per process/host. The Mainnet verifier's hourly quota exhausted during recovery; paced request starts do not guarantee hourly capacity or a usable payout window. |
| Signer model | Bounded two-request TLA+ model: 54,289 distinct states; path/output/dispatch invariants and negative mutations checked. No TLAPS/unbounded Haskell proof. |
| Token administration | Real Devnet mint/account creation, issuance/burn and metadata readback, preserving signed-attempt replay. Bounded expiry recovery now has a finalized mint-one/burn-one round trip; canonical authority/backing remain open. |
| Liquidity | Real Devnet pool/position creation, funded deposit/withdrawal and collection replay, plus bounded expiry recovery for an empty-position collection. Subsequent real trades generated 4 units of fees per asset; collection, fee-bounded reinvestment and full withdrawal passed. Unattended compounding is not implemented. |
| Trading | A real Mainnet SOL→USDC→canonical wrapped ECX purchase used Orca, including the published pool. Two providers confirmed 1,000,000 lamports input, 3,833,230 wrapped base units received and 6,404 lamports transaction fee. This is inventory acquisition, not bridge-conversion or backing evidence. |

Representative funded transactions from the migrated test deployment:

- Native unwrap: `35cd02a112319cf73ccf8e7262e6fe5b0e0eaa9ffc2830220784517a114c4e12`.
- Wrapped payout: `5eWzmgGVNGZkKVET6kHAokYUttkNrX4bGLiQm6uRz1xMCtKnw73AiGwSUZYjNerzWV2WrmZn4GL9NsXzM87m5chg`.
- Native earned withdrawal: `31a2c3bc8c6117225a11f1ed4a7767d682af6515ab46808287fc61a7129b6c8d`.

The conversion tests used 50,000 gross, 500 fee and 49,500 net; the native withdrawal
paid 500 with a separate 141-unit network fee. The deployment was left paused at
sequence 98. Private custody/evidence is retained outside Git; never overwrite newer
activity with the pre-migration backup. Earlier host-installation and permission
checks concern the retired deployment and are not current installation acceptance.

The canonical source promotion passed `cabal build all` (native tools, FFI SDK and
GHC-JavaScript browser), all three Cabal suites, and disposable PostgreSQL/restic,
actual server/control, HTTPS signing and encrypted real-Signet-wallet recovery
contracts. The configuration CLI and both example shapes were checked; six
compile contracts preserved the Operation caller/severity boundary. All eight SQL
migrations and the supplied Main.hs reference retained identical bytes. Temporary
test resources were removed. This verifies the promotion, not the release gates below.

Mainnet enablement and the shared strict SPL mint parser passed the root build,
all three Cabal suites, PostgreSQL/restic contracts and both Devnet and canonical
server/HTTPS variants. Tests retain pinned mint/checkpoint, independent-provider,
backup, profile-alignment and native replay-policy refusals. Mint validation now
checks the full classic layout and unsigned supply range on both providers and
requires matching mint authorities; it does not establish issuer approval or pin
an expected authority. At that checkpoint, the running funded deployment remained
Signet/Devnet. No Mainnet transaction was broadcast by those tests, no new runtime component/file was added,
and disposable databases, roles and processes were removed after testing.

The subsequent Mainnet pilot acquired canonical inventory in transaction
`4ACeCJBRbMDhUsQSuf8u5VW8tboLVw4QtiW5oZzj3UKjJg7rs64WmYPKUSBJa7YPH9bH228wmMLHx4PftCReFQ1K`.
The route used published Orca pool `nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM`
with a 1% slippage bound. Separate custody then received 0.03 wrapped ECX and 0.005 SOL;
its native wallet received 100,000 ECX base units. Account creation was externally paid,
and full custody history was retained. The worker's restricted native RPC credential
passed all fourteen forbidden-method checks, while the wallet stayed locked.
The separate canonical ledger starts paused with required backups enabled; off-host
checkpoints and a funded bridge round trip remain outstanding. Same-user local
processes do not prove production credential isolation.

A later Ubuntu 24.04 ARM64 VM rehearsal built current source with root Cabal and
passed all three suites. The Linux build reused the Mac's GHC-JavaScript bundle
only after checking its source/artifact manifest; stale and corrupt bundle tests
also passed. The sequence-3 custody bundle was inspected, its ledger restored
through the closed recovery command, the Mac fence retired and the VM fence adopted.
Worker and signer now run as separate OS users with separate peer-authenticated
PostgreSQL roles; the worker cannot read the signer key, native credential or unlock
file. Both systemd services start successfully.
The Mac runs an authenticated append-only HTTPS restic receiver: a VM probe was
uploaded, restored byte for byte, and deletion/overwrite attempts were refused.
This is the same physical host, and the existing ECX node remains on the Mac via
an SSH tunnel. It is not independent disaster protection. The first checkpoint
uploaded successfully but could not verify recovery because Ubuntu's restic 0.16.4
lacks `dump --target`. Installing checksum-verified upstream 0.19.1 allowed the exact
snapshot to pass `recover-custody` at sequence 3. The normal operator resume then
completed its full checkpoint/readback and chain/custody checks; the first unfunded
customer order advanced both critical and backup coverage to 4. No backup barrier
was waived. A real customer then deposited 3,000 canonical wrapped units on Mainnet;
the bridge accepted the 30-unit fee quote and broadcast its 2,970-unit ECX payout.
At that checkpoint, confirmation and the return wrapping leg were pending; it did
not establish a completed round trip. Required backup coverage reached sequence 9.

Current runtime checks verified separate worker/signer UIDs, NoNewPrivileges,
seccomp and no effective/permitted/ambient capabilities. The worker could not open
six signer secret files. Its restricted native credential passed thirteen harmless
forbidden-method probes; `walletlock` exclusion was inspected rather than called.
An authenticated invalid-generation signer request passed the current Opaleye
SELECT-only role check before its expected refusal, without a key operation.
The VM now uses a separate administrative UID. The signer's existing UID and key
ownership were retained, but its passwordless sudo grant and SSH authorized key
were removed, its shell disabled, and SSH explicitly denied. Lima/cloud-init now
provisions only the separate administrator. Fresh connections and reboot checks
confirmed administrator access, signer SSH/sudo denial, worker secret-file denial,
valid signer key identity and an unchanged ledger at sequence 26/coverage 25.

Actual directory-open checks exposed caller-dependent ownership on the Mac-shared
virtiofs staging mount: mode 0700 there did not deny worker access. A root-owned
guest-native parent directory, mode 0710 with the signer's group, now protects
traversal; the worker unit also marks staging inaccessible. After reboot, signer
access succeeded and worker access failed with EACCES. A harmless cross-host file
probe and the existing native-wallet backup command both passed; the latter
archived the actual encrypted wallet and verified its manifest without signing.
Temporary probes were removed. Worker and signer remain disabled and stopped;
the supervised native-node tunnel uses the separate administrator and retained
host-key pinning. This closes the observed account/staging defects, not the wider
production isolation or independent disaster-recovery review.

Signer transport rotation subsequently passed on the paused VM: a new token and
TLS key/certificate replaced both services' transport configuration. Old trust
failed TLS verification; the old token received 403; the actual worker UID's new
credentials reached the critical evaluator, which rejected an invalid generation
before chain access. Worker access to the new TLS private key was denied. Custody
key/unlock material and the sequence-27 ledger were unchanged. Both services were
stopped afterward. The existing Cabal-built HTTPS/PostgreSQL contract now also
checks rotation, saved-attempt refusal and unchanged ledger/RPC activity in both
Devnet and canonical profiles, using offline chain fixtures. No production code
or new runtime component was added; public-edge TLS and host recovery remain open.

The exact sequence-9 HTTPS snapshot containing the in-flight payout was recovered
and its full custody/configuration/archive bindings verified. The closed restore
command produced a distinct paused database at sequence 9, which was then dropped;
no fence was adopted and no recovered signer activated. This verifies in-flight
snapshot recovery on the existing VM. The VM was then restarted with that payment
still pending. Services returned paused, the supervised loopback-only SSH tunnel
reconnected using a persistent pinned host key, and normal resume restored readiness
with sequence/coverage 9 unchanged. Tunnel runtime credentials now live in a protected
local directory, avoiding background access to the removable build disk. This covers
VM restart; Mac/node reboot, unattended VM startup and independent clean-host
activation remain unverified.

Live observation exposed a verifier closing an idle HTTPS connection without a
response. The RPC read allowlist now shares at most two retries across that failure
and rate limits; sends, signing mutations, unknown methods and timeouts do not retry.
Root build, all three Cabal suites and the actual HTTPS/PostgreSQL signer contract
passed, including request counts and pacing for a closed read versus refused sends.
The paused pilot subsequently reconciled all three real custody balances with zero
differences and no pending attempts or payment candidates. Its independent readback
ran while the worker was stopped to exclude concurrent ledger changes. This closes
the observed read-transport failure, not the remaining deployment/release gates.
The existing operator DSL allocated the three verified receipts at critical sequence
3: native float 75,000 plus operating 25,000; wrapped float 3,000,000; SOL operating
5,000,000, all in base units. A second independent readback matched every chain
balance after allocation. Offline `backup-custody` and `check-custody` then verified
the sequence-3 ledger, encrypted native wallet/unlock material, Solana key and
configuration bundle. This is a protected same-host copy, not an off-host checkpoint
or restore test. At that earlier checkpoint the temporary Mainnet worker was stopped,
no bridge order or payout existed, and required backup coverage was still zero.
The later VM rehearsal above supersedes that runtime state.

The associated-constraint interpreter refactor also passed the root build, all three
Cabal suites and the same PostgreSQL/server/HTTPS/encrypted-wallet contracts.
One positive and nine rejected compile cases checked caller/severity alignment,
closed instance heads, injective constraint identity, dictionary coercion, distinct
signer results and private interpreter environments. `eqT` establishes constraint-type
equality only; it does not prove dictionary-value identity or custody security.

The subsequent evaluator consolidation passed the root build, all three Cabal
suites and the PostgreSQL/server/HTTPS/encrypted-wallet contracts. One positive
and seventeen rejected compile cases checked the assembled program's ground
instances, constraint injectivity, caller/severity/result separation, private
evaluation resources and customer-facade restrictions. Both process startups now
share one critical evaluator; `Operation` methods implement authorization and
execution. `Interpreter` and the explicit dictionary method are removed. The three
central files decreased from 1,193 to 1,176 lines. These checks do not establish
completion of the funded recovery and release gates below.

DSL constructors now retain only their fully specified `OperationContext`.
The matching view is private to `Critical.hs`, where the ground instance equations
resolve that constraint to `Operation`. Six duplicate constraints were removed;
the relocation reduces the two affected code files by two lines overall. The root
build, all three Cabal suites and server/HTTPS contracts passed. A positive compile
case constructs all six DSL forms using only their associated contexts; eighteen
negative cases reject authority/type violations and access to the private view.

Process startup now joins in `runProcess`, which owns the sole critical dispatch
and never returns an evaluator callback. The former worker/signer factories are
removed. Root build, all three Cabal suites, PostgreSQL/restic, executable
HTTP/control and HTTPS contracts passed. Real concurrent HTTPS requests check
signer serialization, second-read refusal and gate recovery. Customer HTTP also
exercises the worker's private signer client, rejecting malformed backup receipts
and preserving acknowledgment/replay behavior. Compile checks reject imports of
the retired factories and private evaluator resources. The two production files
change from 1,059 to 1,061 lines; the contract file falls from 3,852 to 3,757.
Tests use service interfaces instead of acquiring private evaluators. Automatic
worker sign/persist/replay retains component and historical evidence, but was not
rerun on funded chains for this startup change; opt-in live migration/observation
drivers were adapted and compiled, not rerun.

Recovery readiness now refreshes after source/plan reads and permits one additional
bounded repair if reconciliation ages the scans. Native recovery rereads historical
receipts outside the incremental cursor, retaining atomic receipt/evidence updates.
QuickCheck covers historical recovery, deduplication and batch limits; PostgreSQL
checks that a confirmation-only update invalidates custody without changing balances
or creating work. Root build, all suites and SOURCE/server/HTTPS contracts passed.
These regressions do not close the remaining funded recovery acceptance gates.

The funded encrypted-wallet drill restored an already signed native payout and
completed it using unchanged bytes, then signed and settled a new native payout
with the recovered wallet. Its restored HTTP wrap subsequently settled as
`PaymentPaid`, with payout
`896KTxnzFQQZ6tJMK143tUhKhbE6fuAtiraJQfDJqv6V3vVf38wQBjWdFMikq1LYEmFu3dxLzEDJhuhHFsihVoc`.
The expired generation remains in history; verified expiry and explicit retry
approval preceded its successor. A later real Solana Pay tester deposit also
settled native payout `f2376847434952256d7426cfef5a6f3dd58870e6caa80da3309e73148f753e8b`
for 990 net from 1,000 gross, with the 10-unit bridge fee and separate operator
network cost. Current ledger checks confirm both paid states, no pending attempts
or payment candidates, and fresh scans/custody. This is same-host Signet/Devnet
recovery evidence, not clean-host or Mainnet acceptance.
Earlier rate limits exposed a verifier-outage bug: rereading a verified deposit could revoke
its eligibility. Unavailable verification now refuses the scan without changing
receipts; actual disagreement remains reviewable. Root build, all three suites and
PostgreSQL/HTTPS contracts passed, including repeated-cursor timeout/rate-limit/
missing-result regressions. The funded acceptance inspector retains retired attempt
history and scan/custody diagnostics. Its direct worker-stage driver has been
removed with the evaluator factories: funded recovery must now use the real
service interfaces and durable backup barriers, rather than private evaluator
callbacks or timing termination to prevent a broadcast. Funded native replacement
acceptance remains open.
Singleton native payouts now share the replacement-family evidence reader for
observation, custody and lock recovery, removing 88 production lines across four
existing files. Root build, all three Cabal suites and the existing PostgreSQL/HTTPS
contract pass. Offline regressions distinguish retained-but-evicted wallet records
from active spenders and reject changed bytes, foreign spends, unavailable or
unstable evidence. Custody now separately reports and normalizes proved inputs
excluded by retained inactive wallet transactions, counting a replacement family's
shared inputs once. It requires explicit non-abandoned/conflict/trust evidence,
`avoid_reuse=false`, zero pending wallet credit and stable family/balance anchors.
Missing/all-abandoned families add nothing; unexplained differences still refuse
readiness. Root build and all three Cabal suites passed, followed by PostgreSQL/restic
and actual HTTPS contracts. The isolated restored-ledger cases cover both active
replacement fees, retained/abandoned/missing families, exact correction and remaining
mismatch, pending-credit refusal, unchanged-balance mempool transitions and the existing
single-family constraint. No schema or settlement rule changed. Funded eviction,
replacement and rebroadcast acceptance remain open; these fixtures do not close them.

The real Mainnet return deposit also exposed an unconfirmed arrival between native
scanning and custody inspection. An unknown history entry now invalidates custody
with the existing history-advanced condition so the next scan can catch up; a known
reviewed or changed entry retains its strict refusal. The two-line guard passed the
root build, bridge suite and PostgreSQL/HTTPS contracts. Regressions prove that this
deferral removes certification, does not authorize intake, and never clears an
existing pause. The deployed pilot required a normal checked resume before the fix.
Readiness is repaired before obtaining a new blockhash; redundant outer worker
refreshes are removed while leaf checks and both backup barriers remain. This
reduces `Critical.hs` by three lines; the verifier fix adds no production lines.

The PostgreSQL archive contract additionally compares all 22 existing migration
projections alongside deployment, attempts and postings. A committed recipient
change with unchanged row counts stays outside the exported snapshot and restored
records; same-length dump-byte corruption is rejected. These assertions reuse the
existing backup/restore cycles. Successful dump handles now close explicitly before
validation and hashing. This does not establish protected remote retention.

Administration recovery subsequently passed the root build and all three Cabal
suites, followed by real Devnet acceptance through Solana's public RPC and
OnFinality. Signed mint and empty-position collection attempts were deliberately
left unsubmitted until expiry. Both providers supplied finalized expiry and complete
history through the saved blockhash origins. Each recovery saved one direct child;
repeating recovery returned the same bytes, parent submission was refused, and
finalized child submission replay produced no additional effect. A one-base-unit
mint followed by a checked burn restored supply to 200,000,000,000 and the tester's
balance to 99,997,925,053. Pool owner/vault token balances were unchanged; each of
the three submitted transactions charged 5,000 lamports.

- Recovered mint: `6295tzQeV9Zquqe94hGJGBCn68fZQeJwGv3AeovgQtRVjXs41VoFW2QgTi6humaHUX6iXYKUZb1oMw9Z3dtfujju`.
- Recovered collection: `44sFY6S7mkN3bZKUdw7C5EKxEH3EQdQewdqEC9ZRo9DhjnV8uMFpqgD5pZNPfg8dFWhHTjvnEnSQqguPB8GL9Fiu`.
- Restoring burn: `GAEbjW9S465r362gnprkwh37LUtnk6RkgJAFLTysNPE8t2ju34TQZCw2DwGBQncs5W16Yutv4tY9grTtywvMBJV`.

The live run also exposed stale pooled connections after verifier throttling;
separate read sessions fixed the recovery run without retrying sends. RPC failures
before recovery left no successor or send authority. Private attempts, provider
evidence and tested binary hashes are retained outside Git. The failed-transaction
recovery branch has offline evidence, not a deliberately failed live transfer;
nonzero LP fees, other live recovery action families and canonical use are not
established by this run. Publication-crash hardlinks require the documented manual
inspection; two-provider history remains a trust assumption, not cryptographic
proof of nonexecution.

## Gates still open

Real Devnet nonzero fee collection and explicit reinvestment passed after bounded
trades in the separate test pool. The existing CLI collected 4 units per asset,
reinvested 3 A / 4 B under receipt-sized caps and withdrew all liquidity. Finalized
attempt replay and empty-position readback passed; six transactions cost 5,000
lamports each. No runtime code or custody authority was added. Transaction IDs and
bounds are in the [pool acceptance](../../3-Create-CPMM-Pool/README.md#nonzero-fees-and-explicit-reinvestment).
This does not establish unattended compounding, LP locks or canonical use.

The current macOS source/package notice inventory now covers all 358 distinct
versions across both actual Cabal plans and Cargo.lock. It adds missing notices
for 41 hash-verified Hackage archives and 18 installed compiler packages, retaining
the original historical notice bytes. Graph membership, source hashes and retained
text headers were independently cross-checked. This closes package-text collection
for these graphs, not final-binary platform, runtime or redistribution review; see
[THIRD-PARTY.md](THIRD-PARTY.md). No runtime code or services were added.

The funded Signet additional-deposit refund on 2026-10-04 settled through the
normal worker, HTTPS signer and payment engine. Transaction
`1c015cf15eb5e6f075442beb99037404c4aa53bdd53411a881f6ac2d25375303`
returned 1,000 base units to the original order's immutable refund address.
Paused observation recorded `PaymentPaid`, released principal and booked the
actual 1,000-unit native network fee against operating funds. Remaining native
ledger holdings are 1,090 float, 10 earned and 900 operating; the original
990-unit wrapped conversion remains paid with its original transaction.
An offline custody archive and integrity check passed at critical sequence 37.
The scoped worker/signer were stopped; Mainnet was untouched.

This run did **not** complete positive replacement acceptance: Core selected a
transaction without change and consumed its entire saved 1,000-unit fee ceiling.
No replacement decision or child was created. A subsequent replacement test needs
sufficient change and fee headroom under a newly saved policy; never modify an
existing payment's ceiling to make a test pass.

A subsequent real Signet/Devnet run established replacement headroom before taking
payment. A 2,000-unit wrapped deposit authorized the normal 1,980-unit native payout.
Parent `a20ad3fe2218247c3674fa2f93882a81a205edc7990bbb4c9c1cb6d7798758f3`
paid a 747-unit network fee; the closed operator draft/sign workflow produced child
`028d2d471d90c38ad73ddb3ce6f37f55a0861ac25fd92abfa986713041e5cb8f`
with an 847-unit fee under the immutable 1,000-unit ceiling. Draft/sign replay
returned decision 44 and the identical child without changing ledger state.
The native node retained only the child in its mempool; decoded transactions
preserved inputs, sequences, version, locktime and the 1,980-unit recipient output,
reducing only owned change by 100. The first draft request correctly refused stale
custody immediately after the parent broadcast; paused observation restored custody
before the same terms were accepted. Both services stopped after child broadcast
at critical sequence 46. The child subsequently confirmed, and a paused worker
restart settled the order once with that child as the customer-visible payout.
The recipient received exactly 1,980 units; the ledger booked 20 wrapped units of
bridge revenue and only the winning 847-unit native network cost. Native float
became 1,110 and operating became 1,553; wrapped principal returned to zero,
float became 35,890 and earned became 20. Repeated observation left the complete
payment/balance view unchanged. The post-settlement custody export and integrity
check passed, and all scoped processes stopped. Positive funded replacement,
exact authorization replay and restart settlement now have live evidence; winner
changes after reorg still require separate acceptance. Explicit rebroadcast has
the isolated real-chain evidence below.

A subsequent isolated recovery drill restored that sequence-46 custody snapshot
into a new PostgreSQL ledger with separate restricted roles and a new fence. The
production native-wallet restore verified its descriptors. Two Core nodes copied
from real L2L Signet history connected only over loopback; no signer ran. Invalidating
the winning transaction's block on both copies, then restarting with empty mempools
and automatic wallet broadcasting disabled, made the settled payout unavailable.
The production paused worker recorded recovery review at sequence 47 with
`custody:native_settlement_requires_review`, preserving all balances and PaymentPaid.
Explicit `rebroadcast-native` authorization using that review anchor returned the
same child to the isolated mempool. Reconsidering the original block restored its
confirmation and cleared the review. Closed Opaleye reads verified identical
balances, transaction family and customer payment before and after recovery.
Both nodes and the worker stopped afterward. Evidence is retained privately under
`native-reorg-acceptance-20261004`; no custody secrets are published. This proves
restored-ledger detection and explicit saved-transaction rebroadcast against real
Core behavior, not an observed public-network reorg, a changed winning transaction,
a clean-host restore or recovery of an in-flight snapshot. Mainnet and the shared
Signet node were untouched by this drill.

The current executable also restored the real sequence-7 in-flight custody backup
from the earlier funded recovery run into a separate restricted PostgreSQL ledger.
Its `broadcast_intent` attempt, exact signed bytes and policy matched the saved
pre-backup evidence. Restoring the wallet against later real Signet history exposed
a false refusal: Core's rescan advanced address indexes from 1 to 2/3 while retaining
the same descriptors. Restore validation now permits forward-only allocation indexes
within the expanded keypool, keeping descriptor identity and all other fields exact;
shrinking ranges, backward/out-of-range indexes and changed descriptors are rejected.
The production restore then passed. Without a signer or new broadcast, the paused
worker recognized confirmed transaction
`16ef98729d8e739986ef3c0fcae8873ad1d4b1d5d9803cee33a33504c856a24a`
and settled its saved 990-unit payment with the original 141-unit network cost.
Wrapped principal became zero, float 990 and earned 10. Repeated observation left
the entire payment/balance view unchanged. Later deposits absent from this old
snapshot remained unallocated; unexplained later activity kept intake paused for
review, rather than automatically resuming stale state. Both isolated nodes and
worker stopped. Private evidence lives under `inflight-restore-20261004`.
This closes same-host restoration of this in-flight native attempt against later
confirmed history; Solana in-flight recovery, changed native winners, lost-host
uncertainty and physically independent clean-host recovery remain distinct gates.

Restoring the same deployment's sequence-23 backup also preserved its retired
Solana attempt `32RKrYFti4fHFN5xTZJfS8hzRwof3cpDne7NYBao9HUKCkW4tzZDjUaNcFDdjeC45bhnJsqeWWziuxpPLF7raVYQ`
byte-for-byte in review. Paused observation retained 1,000 native units of customer
principal and produced no successor attempt; later unallocated activity required
review. The snapshot was taken after expiry retirement, with no current signed
attempt, so it does **not** close pending-Solana restoration. Private evidence is
under `solana-inflight-restore-20261004`; all scoped processes stopped.

The run exposed an operator CLI error-reporting issue: server refusals were printed
as successful stdout responses. The CLI now raises returned errors through its
existing nonzero-exit/stderr path. Actual executable/PostgreSQL contracts passed
for both development and canonical configurations, checking successful status and
rejected resume, unchanged balances and process cleanup. This adds six application
lines and five assertions/runner lines in the existing test file, with no new files
or authority paths. These contracts do not send chain transactions.

The 2026-10-04 dependency refresh replaced the browser's affected Aeson 2.2.3.0 pin
with patched 2.2.5.1. Root build (also with a fresh browser build directory), all
three Cabal suites, served-asset hash comparison and saved paid-order reload passed.
No application-code lines or runtime files were added. The actual native/browser
plans and Cargo lock were checked against current advisories; generic readFloat,
build-time Cabal header deletion and bincode maintenance findings remain explicitly
scoped in [DEPENDENCY-REVIEW.md](DEPENDENCY-REVIEW.md). This does not close independent
review or distribution/license requirements.

1. **Customer wallet:** sign a real Devnet Solana Pay deposit in a supported wallet;
   verify reference/effects, both directions, saved-order recovery, refunds and
   browser errors. A test client or wallet-opening link does not close this gate.
2. **Recovery effects:** verify permanent source loss/double spend, coverage/return,
   native winner changes after reorg and restoration with in-flight
   Solana work. Retain the completed same-host encrypted-wallet drill as regression
   evidence; clean-host funded recovery remains in the following gate.
   Preserve one payout, correct capital/cost accounting and exact saved bytes.
3. **Isolation and off-host recovery:** exercise the current worker/signer under
   separate OS and PostgreSQL identities, actual restricted native RPC, and denied
   key/full-cookie/unlock access. Restore funded custody on a clean host using a
   real off-host HTTPS repository, separate deletion authority, retained passwords,
   protected retention and explicit old-host exclusion/revocation.
4. **Administration and canonical use:** retain the completed nonzero fee collection
   and explicit reinvestment evidence; finish issuer approval, canonical authority/reserves and funded
   betanet/canonical acceptance. Extend recovery acceptance where the offline-only
   cases and remaining operation families require it; retain the verified bounds.
   Verify actual token/pool identity and current executable routes before enabling links.
5. **Dependencies and independent review:** resolve applicability/reachability and
   license questions recorded in [DEPENDENCY-REVIEW.md](DEPENDENCY-REVIEW.md) and
   [THIRD-PARTY.md](THIRD-PARTY.md); obtain independent review of source and deployment.
   Earlier dependency inventories are not a clean bill of health for a new artifact.
6. **Installation/release:** implement and test the new one-command installer and
   current service policies on Ubuntu 24.04 ARM64/x86-64, including repeat install,
   upgrade, reboot and restore. The old installer/release workflow was removed.
   Authenticate a review candidate only after substantive runtime work settles.

Audit from the operation grammar/API through critical authorization, durable store,
chain validators, signer, settlement and recovery. Review exports, OS credentials,
transaction boundaries, backup acknowledgements and fence/old-key assumptions together.
Findings should state the affected invariant, concrete trigger/consequence, required
change and evidence proving closure. Neither fewer lines nor green local tests
establish perfect security. Public publication and valuable-fund activation require
their own operator decision after the required gates close.
