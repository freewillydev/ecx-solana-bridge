# Release review

The bridge has completed funded development tests and a canonical betanet/Solana
Mainnet round trip. It is ready for source review, **not public-release approval**.
The [nine-step internal completion plan](IMPLEMENTATION-PLAN.md) is complete. Passing
an older candidate's tests does not certify later source or packages.

## Source and evidence boundaries

| Version | Verified scope | Not established by that evidence |
| --- | --- | --- |
| `54c2bfd` | Funded canonical wrap/unwrap, exact finalized bytes, reconciliation; same-host in-flight Solana recovery | New public TLS, later token changes, independent-host recovery |
| `509f617` | Ubuntu ARM64/x86-64 signed test packages, clean installation, repeat upgrade preserving custody/configuration, installed public HTTPS and paused intake | Public-domain renewal, funded clean-host restore, public release signing |
| `ba5c0f1` | Consolidated macOS/x86-64 suites and PostgreSQL/recovery/HTTPS contracts; durable offline token minting: macOS and Ubuntu ARM64/x86-64 token suites; real Devnet delayed signing/submission and refusal checks below | Independent release gates below |

Detailed historical transaction IDs, source hashes, snapshots, test scope and
private evidence locations remain in the immutable
[pre-consolidation record](https://github.com/freewillydev/ecx-solana-bridge/blob/ba5c0f1/2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md).
Resolved RPC, freshness, unpaid-payout and installer blockers in that history are
**not current blockers**. There is no new funded Mainnet retry to perform merely
to reproduce the already settled round trip.

## Completed acceptance retained

| Area | Evidence | Limit |
| --- | --- | --- |
| Customer conversions | Real L2L Signet/Solana Devnet conversions with immutable 1% fees; canonical Mainnet round trip | Deposits used tester clients; actual customer-wallet approval remains open |
| Refunds/revenue | Verified-owner refunds, additional-deposit refund preserving the original payout, native/wrapped earned-fee withdrawal, replay/restart | Scoped funded cases, not all possible chain histories |
| PostgreSQL ledger | Schema 18 → 21 migration; 24 projections, exact attempts and financial history compared; QuickCheck and real PostgreSQL transaction/fencing/concurrency contracts | Synthetic source-loss/winner-change evidence is not a real-chain reorg |
| Browser | GHC-JavaScript forms, fee previews, paused intake, saved-order reload, payout links and error behavior | No completed real Solana Pay wallet signing flow |
| Recovery | Native replacement/rebroadcast and same-host in-flight restoration; Solana in-flight restoration; encrypted native-wallet restoration | Physically independent funded disaster recovery remains open |
| Native source changes | Real Signet confirmation rollback/return observed by the paused worker without duplicated settlement | No confirmed double spend, permanent source loss or alternate winning payout |
| Isolation | Separate service identities, read-only signer database role, denied custody/native key access, native unlock/sign/backup RPC restrictions, service-account SSH denials | Independent whole-system security review remains open |
| TLS and admission | Real WarpTLS HTTPS, plaintext/body rejection, private-key checks, bounded concurrency and atomic global request/order limits | Not network-level DDoS protection or production load/renewal evidence |
| Signer model | Two-request TLA+ model: 54,289 states, unique output/path/dispatch invariants and negative mutations | Not a TLAPS/unbounded proof or automatic Haskell refinement |
| Token administration | Devnet mint/account creation, mint/burn, metadata, exact replay, expiry and finalized-failure recovery | Issuer approval and canonical backing remain external |
| Liquidity | Devnet pool/position creation, deposit/withdrawal, nonzero collection, explicit fee-bounded reinvestment and failure recovery | No unattended compounding or LP-lock claim |
| Trading | Real Mainnet SOL→USDC→canonical wrapped ECX acquisition via Orca; two-provider effects checked | No guarantee of ongoing routes, liquidity or reserve backing |
| Installation | Both Linux architectures: authenticated installation/upgrade, cold boot and isolation on recorded candidates; unfunded native/HTTPS-backup integration | Final-source packaging and funded independent restoration remain separate |

### Canonical funded checkpoint

On `54c2bfd`, 3,000 wrapped base units paid 2,970 native units; 1,000 native units
then paid 990 wrapped units. Fees were 30 and 10 units respectively, with network
costs booked separately. Alchemy and the independent verifier returned identical
finalized Solana payout bytes at slot 453424255:
`569aQRwy8WE9KcMpL2DD8XiANbxquwakX864JEfKnKSFPg5KssVg41TDsh9cpcBg8QQrBh12HgQXA3U9ZfyfL2Xy`.
All three custody assets reconciled without differences; sequence/backup coverage
was 55. Restoration of its pre-broadcast snapshot recovered the settled payout
from the real chain without another signature or payment. Backup storage still
shares this physical Mac.

### Retained package identities

The exact `509f617` test-signed packages passed installed HTTPS/upgrade checks:

| Architecture | SHA-256 |
| --- | --- |
| ARM64 | `5b89ceaeda28a4d52a32a10daf62f27351f4e218877d28e8207cf90a35d3a072` |
| x86-64 | `5a3dec48318d8226eb564807d73dff15cc7ba562a88c17e19bb367ae426decc4` |

They include the reviewed restic build and all 40 payload-manifest entries,
including the nested browser manifest. The acceptance signing key is not a public
release trust key. Private artifacts/evidence are in
`installer-acceptance-20261004/candidate-509f617/` under the retained secrets directory.
Do not label them as containing later token changes.

## Final review artifacts

Both Ubuntu 24.04 packages were built from clean commit `548c509`, which adds only
review documentation to implementation freeze `ba5c0f1`:

| Architecture | SHA-256 |
| --- | --- |
| ARM64 | `2e6c05ad00f1205ff818039fe564dfb5ebe22b5a35ca6b514b4805a48b943265` |
| x86-64 | `dfafeb10f5b0a4fec20e87446168f1a9352ede64efde225027e1bd0ec71a1adf` |

For each artifact, all 40 payload-manifest entries matched, with no unlisted payload
files, links or traversal paths. The nested browser manifest matched its actual
source files and generated assets. Migrations, installer and notices matched the
frozen checkout; restic matched the reviewed architecture-specific pin. Both Linux
plans matched all 188 non-local notice records and 159 distinct source hashes.
ELF architecture, loader and direct dependencies were inspected: no RPATH/RUNPATH;
system libraries remain dynamically supplied by Ubuntu, not copied into the bundle.
The actual compiled SDK was exercised by that architecture's token suite.

The format-2 release index was signed with the retained **acceptance-only key**;
`release-auth verify` passed for both artifacts. This verifies artifact integrity
and the test signer, not public-release authorization. Final payload inspection
and authentication are new; clean/repeat installation and cold-boot evidence remain
bound to the earlier candidates above. The installer/browser source is unchanged;
no new installation or funded transfer is claimed for these final packages.

Artifacts, index and `final-artifact-review.json` are in private
`installer-acceptance-20261004/candidate-548c509/`. Build/install/upgrade commands are
in [INSTALL.md](INSTALL.md); paused restoration and old-signer exclusion are in
[OPERATIONS.md](OPERATIONS.md). The installer bundles the bridge, SDK, browser and
backup client. Token/pool administration remains separately Cabal-built using its
own README; no mint authority is installed into the custody server. All temporary
build VMs were stopped after verification. Later evidence-only documentation commits
do not require rebuilding these immutable artifacts.

## Durable offline mint acceptance (2026-10-05)

The new `CreateNonce` and `NonceMint` token operations passed the local Cabal token
suite, including independent exact instruction/account validation, changed intent
refusal, nonce-state/version/authority parsing, imported-key identity, offline CLI
confirmation, private-file permissions and no-overwrite checks. Ordinary token
recovery contracts still pass. Linux token acceptance also passed on Ubuntu ARM64
and x86-64 at `ba5c0f1`, with one build job and actual platform SDK libraries.
Private logs are `token-nonce-{arm,x86}-ba5c0f1.log` in the retained
`installer-acceptance-20261004` directory. This does not update the older bridge
packages or prove installation of the final version.

Real Devnet acceptance used the retained disposable test authority and a separate
test payer, not Mainnet or bridge custody. The payer created nonce account
`Gqfkf2VojwkcdSp2YbTkoAufViDLhZY39wdRpXxA4AZM`, assigning its authority to the
test mint authority. Creation finalized as
`2Vx1xf9E4sZq2r63gBLXjFKDdH5fktPsnvGHSxr8UyQD4kmjnTcH7ypcegTsfzANYkKL3VQdEyuicyh1VsB3HSvV`.
Both base58 import and offline signing ran with macOS sandbox network access denied,
without an offline RPC configuration. The test copied the signed file between
isolated working directories; no physical USB device was used.

After an ordinary blockhash captured during preparation became invalid, the saved
nonce mint finalized at slot 507838464 with signature
`35EviD6g3pi39emd9SvvZsDRtBbt8GSVfu9h6eEkv4CNXPdjeb9ZTFdrzQfJnBppMyCpa9g8gpnHayywcGCKjBSg`.
RPC returned exactly the signed bytes; recipient token balance increased from 0
to 1 base unit. Creation and mint each cost 5,000 lamports; nonce rent was 1,447,680.
Replaying the saved mint returned the same finalized result and unchanged balance.
Tampered intent and a one-lamport fee ceiling were refused before submission. A
second signed intent using the consumed nonce was refused with
`token_nonce_consumed_or_changed`, and its signature remained absent. No automatic
replacement signature was generated. Private evidence is
`postgres-integration/private/offline-nonce-20261005/acceptance.json` in the retained
build root. This establishes the tested Devnet token path, not customer-wallet,
Mainnet nonce, physically separate-device or independent-security acceptance.


## Consolidated final acceptance

At `ba5c0f1`, root `cabal build all -j1 --offline` and all three Cabal test suites
passed on macOS. All three suites also passed on Ubuntu x86-64; the updated token
suite passed separately on Ubuntu ARM64. The explicit `ecx-store-check` contracts
then passed against disposable real PostgreSQL databases: role isolation, exclusive
writer, atomic reservations, replay/conflict handling, checkpoint rollback/fencing,
saved orders, historical fees, settlement and recovery. The same batch passed real
restic encryption/readback/restoration, corruption and wrong-password refusal,
exact saved attempts/postings, and real-process pinned HTTPS signer tests including
concurrency, certificate/auth refusal, second-read rejection and interruption cleanup.
The disposable databases/role were removed and child processes reaped.

The browser source and installer are unchanged from the accepted `509f617` version
(`git diff 509f617..ba5c0f1 -- 2-Wrap-Unwrap-Server/web 2-Wrap-Unwrap-Server/install`
is empty). Retain its actual served GHC-JavaScript/reload evidence rather than
claiming a new customer-wallet approval. Current Cabal browser asset checks and
HTTPS contracts passed. No funded Mainnet test was repeated for the offline token
delta. This freezes the implementation at `ba5c0f1`; later documentation-only commits
do not silently change that implementation boundary.

Private final logs: `ecx-final-{build,tests,contracts}-ba5c0f1.log`, the ledger/TLS
contract logs, and `all-nonce-x86-ba5c0f1.log`, retained with installer acceptance.

## Internal review and audit map

The 2026-10-05 review traced the following boundaries at `ba5c0f1`. No additional
implementation defect was demonstrated in this pass. This is an internal,
source-level review supported by the named contracts, not an independent audit,
an exhaustive review of every dependency, or a claim of perfect security.

| Boundary | Code to trace | Property checked |
| --- | --- | --- |
| Customer input | `api/Bridge/API.hs`, `workflow/Bridge/Web.hs`, `src/Bridge/Domain.hs` | Four customer endpoints; typed plans; bounded bodies/admission; capability-bound orders; integer amounts and immutable quotes |
| Critical dispatch | `src/Bridge/Operation/Internal.hs`, `workflow/Bridge/Critical.hs` | Closed caller/severity requests; one critical entry; signer transport remains inside its operation implementation and serialized critical lifetime |
| Signer authority | `workflow/Bridge/Signer.hs`, `workflow/Bridge/Credentials.hs`, `workflow/Bridge/Payment.hs` | Authenticated pinned HTTPS; process-role checks; saved deployment/decision binding; restricted private keys; independently validated reply |
| Durable ledger | `runtime/Bridge/Store.hs`, `runtime/Bridge/Store/Schema.hs` | Opaleye operations; exclusive writer, row locks, atomic reservations, immutable signed attempts, unique receipt/settlement use and balanced postings |
| Native effects | `chain/Bridge/NativePayment.hs` | Confirmed unique prevouts; exact outputs/change/fees; unchanged signed template; canonical block/depth and bounded replacement-family winner checks |
| Solana effects | `chain/Bridge/SolanaMessage.hs`, `chain/Bridge/SolanaPayment.hs`, `chain/Bridge/PaymentObservation.hs` | Exact signed instructions/keys/message; finalized observation; token deltas, fee/rent and failed-transaction effects; expiry requires separate evidence |
| Observation and solvency | `workflow/Bridge/Observer.hs`, `workflow/Bridge/Reconciliation.hs`, `chain/Bridge/PaymentSource.hs` | Failed scans do not advance readiness; revision-bound reconciliation; source eligibility; independent configured evidence where required |
| Recovery and backup | `workflow/Bridge/Recovery.hs`, `runtime/Bridge/Fence.hs`, `runtime/Bridge/Store/Backup.hs` | Identity/sequence checks; monotonic fence; coherent snapshot; full encrypted backup readback before acknowledgement; paused restoration |
| RPC failure | `chain/Bridge/RPC.hs` | Bounded responses, request identity, redacted errors; allowlisted read retries; ambiguous mutations never automatically retried |
| Offline administration | `1-Make-Wrapped-ECX/Token.hs`, `Token/Network.hs`, `Token/Signing.hs` | Imported-key identity; exact nonce creation/mint semantics; no RPC in offline signing; no automatic replacement signature; exact replay/consumed-nonce refusal |

Paths are relative to `2-Wrap-Unwrap-Server` except the token row. A reviewer should
follow one order through reservation, receipt, preparation, backup, signing,
broadcast intent and settlement; then follow the same order through an interrupted
send and restore. Compare the actual transaction with the saved intent, and check
that uncertain effects remain obligations rather than becoming spendable inventory.
Review configuration trust, operating-system isolation and backup independence
separately: the Haskell types cannot establish those deployment properties.

## Remaining public-release gates

1. **Customer wallet:** approve a real Devnet Solana Pay payment in a supported
   wallet, then verify reference/effects, payout, reload and errors. No website
   wallet connection is required.
2. **Real-chain recovery:** permanent source loss/double spend, coverage/return and
   a changed native winner need valid alternate L2L history or miner cooperation.
   The retained node has no suitable alternate branch. The upstream throwaway
   Signet challenge differs from L2L; it cannot substitute for this evidence.
3. **Independent recovery:** obtain a physically separate HTTPS backup repository
   and clean host, with upload/deletion separation and retention. Restore funded
   custody plus in-flight work, exclude the old signer, reconcile and explicitly
   resume. Mac/VM drills cannot establish physical independence.
4. **Production arrangements:** operator-approved issuer/mint/reserve policy,
   host/domain, independent RPC capacity, support and alert destination. Verify
   actual routes, TLS renewal and deployment behavior against those resources.
5. **Review:** obtain independent security/distribution review. See [dependency findings](DEPENDENCY-REVIEW.md)
   and [notice scope](THIRD-PARTY.md); inventories are not security certification.
6. **Final release:** use an operator-controlled release trust key, and obtain explicit publication and
   valuable-fund activation approval.

No outstanding gate is closed by fewer source lines, an unchanged status report,
or a green test whose scope does not cover it. Retain exact bytes and actual
financial evidence; do not repeat funded tests or installer builds without a
relevant change.
