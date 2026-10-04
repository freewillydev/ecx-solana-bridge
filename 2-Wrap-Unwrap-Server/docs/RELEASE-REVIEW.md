# Release review

The application is available for source review; the pilot interface is currently
offline and public release remains open. The Ubuntu ARM64 pilot has `3e34b01`
deployed, executable SHA-256
`67beccef91cd7d6e61ab35dc5e6be63fd435d2845b137fbf167f9d4f4939ec37`.
Its real canonical Mainnet unwrap is paid: 3,000 wrapped base units in, 30 fee,
2,970 native units out, with a separate 141-unit network cost. The 1,000-unit native
return deposit is confirmed; its saved 990-unit wrapped payout remains pending.
Alchemy is the primary RPC; a keyed OnFinality endpoint is the independent verifier.
Observed headers reported limits of 40/minute and 200/hour. OnFinality assigns the
relevant [Solana methods two response units each](https://documentation.onfinality.io/support/solana),
so these limits allow roughly 20 calls/minute and 100/hour, not 200 requests/hour.
Closed retry and resume passed, but recovery exhausted that hourly quota before
broadcast. Both services are stopped pending sufficient verified capacity;
no new transaction was broadcast
by this retry. The private Mac interface at http://127.0.0.1:61992/ is offline.

Generations 0, 1 and 2 are retired with expiry evidence. After partial quota refill,
the normal paused-worker recovery verified generation 2 through both providers
and retained proof hash
`3ec0a47330399736fbbae26f55af6d6fb47fbae3a3ed43c129e0e2fd07e64166`.
Its signed attempt `4UNYK88afBe6FXDanTNdaAZ6ZWWPFiusYpo7Xys3NiHRDnYqrUpXwXqi1hMUeWMkuY2fSZuhGVR19mQjv4QRFBL7`
still has no broadcast sequence. The worker stopped after that bounded recovery;
the signer remained stopped, and no new generation was authorized. Critical
sequence is 27 and acknowledged backup coverage is 25.
The 990-unit obligation remains pending, so the Mainnet round trip is incomplete.

Source inspection estimates approximately 26 verifier calls for a fresh payout
cycle with the pilot's current single-page history, before retries or additional
refreshes. That exceeds the observed 20-call minute allowance if completed within
one minute. Signed-to-send work alone needs at least 12 verifier calls and a full
custody checkpoint. An hourly reset or per-second pacing cannot establish reliable
completion on this allocation; increase independent-provider capacity before
authorizing another generation.

Alternative public endpoints were rejected: SolanaTracker initially passed basic
checks but omitted immutable history origins (`solana_history_gap`); VibeStation
rate-limited history reads. The keyed OnFinality endpoint was restored. These probes
establish neither production provider capacity nor an SLA, and do not complete
blockhash-window acceptance.

The full macOS root build passed on `3b1b3ba`; all three macOS Cabal suites passed
on `3e34b01`. Linux ARM64 passed the full root build and bridge suite on `3e34b01`;
its all-three-suite result is from `3b1b3ba`. The native-accounting changes also
passed disposable PostgreSQL/restic and actual HTTPS contracts. Subsequent sections
retain historical evidence within its recorded scope; they do not certify a later
artifact.

## Evidence already obtained

| Area | Evidence and limit |
| --- | --- |
| Customer conversions | Real L2L Signet/Solana Devnet wrap/unwrap through the server and dedicated signer; 1% saved fees and quoted net retained. Deposits used dedicated tester clients. |
| Refunds and earned fees | Finalized verified-owner refunds and native/wrapped earned-fee withdrawals through the shared engine, with replay/restart checks. Additional refunds preserve completed conversion views. |
| Ledger migration | Populated schema-18 copies and the original test ledger migrated to schema 21; exact signed work, financial history and 24 Opaleye projections compared. Historical records lacking executable cost policy remain archival only. |
| Browser | GHC-JavaScript fee previews, paused intake, private-link recovery/reload, preserved payout links and network-error/restart behavior checked against the actual server. Actual wallet signing remains open. |
| Custody restoration | Sequence-98 funded ledger restored into separate same-host staging; 24 projections matched and actual chain reconciliation passed. Minimum sequence 99 refused the archive. This does not prove off-host storage or clean-host wallet activation. |
| Automated boundaries | Cabal QuickCheck/protocol tests, actual HTTPS tests and PostgreSQL contracts cover typed authority, immutable accounting, fencing, concurrency, cancellation, source/replacement recovery and encrypted restic restoration. Fixtures do not prove all real-chain cases. |
| Canonical Mainnet mode | The VM accepted a real canonical-token customer deposit and completed its native payout. The return native deposit is confirmed; wrapped payout/recovery remains pending. Earlier local canonical process/signing contracts use offline RPC fixtures. |
| Current VM deployment | Separate worker/signer UIDs and restricted PostgreSQL/native credentials passed live denial checks. Required HTTPS backups, an in-flight sequence-9 restore into a separate paused database, and a VM restart passed. The backup receiver shares the physical Mac; clean-host activation and disaster isolation remain open. |
| RPC pacing | Tests cover host budgets, idle/late wakeups, cancellation and actual HTTPS accounting of a read retry versus a refused send. Scoped Signet/Devnet operation passed at the default 2 requests/second per process/host. The Mainnet verifier's hourly quota exhausted during recovery; paced request starts do not guarantee hourly capacity or a usable payout window. |
| Signer model | Bounded two-request TLA+ model: 54,289 distinct states; path/output/dispatch invariants and negative mutations checked. No TLAPS/unbounded Haskell proof. |
| Token administration | Real Devnet mint/account creation, issuance/burn and metadata readback, preserving signed-attempt replay. Bounded expiry recovery now has a finalized mint-one/burn-one round trip; canonical authority/backing remain open. |
| Liquidity | Real Devnet pool/position creation, funded deposit/withdrawal and collection replay, plus bounded expiry recovery for an empty-position collection. Collected fees were zero; nonzero yield/reinvestment remains unverified. |
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
   native replacement/winner change/rebroadcast and restoration with in-flight
   signed work. Retain the completed same-host encrypted-wallet drill as regression
   evidence; clean-host funded recovery remains in the following gate.
   Preserve one payout, correct capital/cost accounting and exact saved bytes.
3. **Isolation and off-host recovery:** exercise the current worker/signer under
   separate OS and PostgreSQL identities, actual restricted native RPC, and denied
   key/full-cookie/unlock access. Restore funded custody on a clean host using a
   real off-host HTTPS repository, separate deletion authority, retained passwords,
   protected retention and explicit old-host exclusion/revocation.
4. **Administration and canonical use:** finish nonzero LP fees/reinvestment where
   promised, issuer approval, canonical authority/reserves and funded
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
