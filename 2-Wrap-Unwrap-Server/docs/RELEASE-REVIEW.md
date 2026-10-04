# Release review

The current implementation supports test-network and canonical Mainnet operation,
with funded bridge-conversion acceptance recorded only on test networks; it is not a completed
public release. Historical checks are regression evidence within their recorded
scope. Every release result must identify the exact source, artifact and environment;
a past transfer or installer does not certify later source or a new deployment.

## Evidence already obtained

| Area | Evidence and limit |
| --- | --- |
| Customer conversions | Real L2L Signet/Solana Devnet wrap/unwrap through the server and dedicated signer; 1% saved fees and quoted net retained. Deposits used dedicated tester clients. |
| Refunds and earned fees | Finalized verified-owner refunds and native/wrapped earned-fee withdrawals through the shared engine, with replay/restart checks. Additional refunds preserve completed conversion views. |
| Ledger migration | Populated schema-18 copies and the original test ledger migrated to schema 21; exact signed work, financial history and 24 Opaleye projections compared. Historical records lacking executable cost policy remain archival only. |
| Browser | GHC-JavaScript fee previews, paused intake, private-link recovery/reload, preserved payout links and network-error/restart behavior checked against the actual server. Actual wallet signing remains open. |
| Custody restoration | Sequence-98 funded ledger restored into separate same-host staging; 24 projections matched and actual chain reconciliation passed. Minimum sequence 99 refused the archive. This does not prove off-host storage or clean-host wallet activation. |
| Automated boundaries | Cabal QuickCheck/protocol tests, actual HTTPS tests and PostgreSQL contracts cover typed authority, immutable accounting, fencing, concurrency, cancellation, source/replacement recovery and encrypted restic restoration. Fixtures do not prove all real-chain cases. |
| Canonical Mainnet mode | `serve` and `signer` accept the canonical profile through the shared order/payment engine. Local contracts verify CLI startup, paused order refusal, observer restrictions, actual HTTPS signing of canonical-mint bytes, concurrent/repeated signing, second-read refusal and customer checkpoint handling. RPC effects are offline fixtures, not a funded Mainnet transfer. |
| RPC pacing | Root build, all three Cabal suites and server/HTTPS contracts pass. Tests cover host budgets, idle/late wakeups, cancellation and actual HTTPS accounting of a read retry versus a refused send. The local Signet/Devnet deployment resumed at the default 2 requests/second per process/host with fresh chain/custody checks and unchanged paid orders. This is not a Mainnet load test or a provider-wide quota guarantee. |
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
or restore test. The temporary Mainnet worker was stopped; no Mainnet bridge order
or payout was created, and required backup coverage remains at sequence 0.

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
unstable evidence. These do not establish funded eviction recovery: daemon wallet
balances can still exclude inputs reserved by inactive wallet transactions, and
custody mismatches continue to refuse readiness. The live balance/recovery case
and full operator replacement/rebroadcast acceptance remain open.
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
