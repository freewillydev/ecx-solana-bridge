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

## Interactive setup release candidate (2026-10-05)

Source `bc9713c` adds interactive `ecx-bridge configure`/`start`, source-file
references instead of copied setup secrets, and offline `ecx-token enter-key`.
The latter uses a real terminal with echo disabled, shares existing key validation,
restores echo on rejection and refuses piped input or output overwrite. Real-PTY
token acceptance passed on macOS and Ubuntu ARM64/x86-64; the full token/bridge
suites passed on both Ubuntu architectures.
The customer API, financial workflows, ledger, chain adapters, migrations and SDK
sources are unchanged from the funded `548c509` runtime; no new funded transfer is
claimed for these setup packages.

| Architecture | Package SHA-256 |
| --- | --- |
| ARM64 | `56ae772b86d04b58c8a3c675c07ed4d98859a9c87fbec94b0d3dc8a483c5fbe1` |
| x86-64 | `f17dc72aa42707c6833093566c6af9c8582af59c5a8bb36d4b1804e5d067e103` |

Both artifacts have 40 verified manifest entries, matching frozen installer,
migrations, nested browser manifest and retained notices. Each current Linux plan
matches all 188 non-local notice records and 159 dependency source hashes. ELF
architectures/loaders were checked, with no embedded RPATH/RUNPATH; restic matches
the reviewed architecture-specific pin. The format-2 indexes use the retained
**acceptance-only** signing key, not a public release authorization key.

ARM64 and x86-64 clean Ubuntu acceptance started without PostgreSQL or bridge services.
`configure` produced exactly five private JSON files and no key-file copies.
`start` installed PostgreSQL, restricted roles, migrations and the two services,
then refused readiness with chain access deliberately disabled. HTTPS, plaintext
refusal, signer authentication, key isolation, port 443 capabilities, source-file-
independent restart, repeat upgrade preservation, fresh-over-existing refusal and
cold boot passed on both architectures. Service accounts were denied SSH access.
No funded wallets were used. The bootstrap executable needs Ubuntu runtime
libraries (including `libpq5`); these were installed before running `configure`.
This is not evidence that an executable can launch on an OS lacking its libraries.

Private evidence is in `installer-acceptance-20261004/candidate-bc9713c/` and
`candidate-bc9713c-x86/`. These packages do not install the separate token/pool
administration executables; build those through Cabal. The funded pilot stays on
its previously verified runtime. External release gates below remain open.

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
the funded ARM64 upgrade and recovery checks below extend that evidence.

Artifacts, index and `final-artifact-review.json` are in private
`installer-acceptance-20261004/candidate-548c509/`. Build/install/upgrade commands are
in [INSTALL.md](INSTALL.md); paused restoration and old-signer exclusion are in
[OPERATIONS.md](OPERATIONS.md). The installer bundles the bridge, SDK, browser and
backup client. Token/pool administration remains separately Cabal-built using its
own README; no mint authority is installed into the custody server. All temporary
build VMs were stopped after verification. Later evidence-only documentation commits
do not require rebuilding these immutable artifacts.

## Frozen ARM64 funded deployment (2026-10-05)

The existing funded VM was upgraded to the `548c509` artifact above (implementation
`ba5c0f1`). Its installed bridge SHA-256 is
`2d2dd1f9772ac2284d4a1d75ebda764a0b215562f5a68813c2d70b74f983f757`.
All payload hashes and unchanged schema-21 migrations matched. A stopped-ledger
backup and the previous runtime were retained; configuration, custody keys and
fence were preserved. Saved paid orders remained readable. Paused intake,
unauthenticated signer rejection and worker denial of signer-key access passed.

The existing betanet node had a corrupt undo file. An APFS clone of the retained
September 25 node snapshot caught up through normal network validation, then
passed `verifychain 4 144`. The original node and snapshot were retained. Removing
only regenerable Cargo intermediates recovered approximately 13 GiB; no wallets,
source or backup archives were deleted. The recovered node uses the existing
wallet directory, a 550 MiB prune target and bounded memory. Its fallback fee is
1 base unit/vbyte; the bridge's 500-unit native transaction cap is unchanged.
The signer's persistent, restricted RPC credential survives node restarts;
`sendrawtransaction` remains forbidden for that credential.

The new wrapped-to-native order paid 2,970 native base units from 3,000 wrapped
units (30-unit bridge fee; 141-unit native network fee). Native payout:
`9ba36852f5a4bbc9c189a1db2e2a18d0b66b01d12de106c5cecfe9345883df5a`.
Restarting the worker, signer and native node while this payout was unconfirmed
retained that exact generation-0 attempt, which subsequently confirmed in block
971186 without a replacement payout.

The encrypted sequence-60 custody snapshot was downloaded, integrity-checked and
restored into a separate PostgreSQL database using the frozen runtime. It retained
the same in-flight attempt and restored paused. A requested minimum sequence of
61 was rejected. No restored signer or fence was activated; the staging database
and temporary plaintext were removed after inspection. This is same-Mac recovery,
not physically independent disaster recovery.

The return order received 1,000 native base units and paid 990 wrapped units
(10-unit bridge fee; 5,000-lamport network fee). Finalized Solana payout at slot
453690143:
`2sKESTDE76hyN7oLSChYTHWzznpkVkcWAstfUJkR1p11X9iwXrES5YaVjbS4jw5Kw9c6HszaE5vQWggjLGqBLc29`.
Both independent providers returned identical finalized transaction contents and
metadata, including the exact 990-unit customer credit. An initial attempt expired
without executing; its saved nonexecution proof gated the successful generation-1
retry. This was one economic payment, not two funded orders.

Final custody balances were 95,778 native units, 3,004,020 wrapped units and
4,990,000 lamports. All matched the ledger exactly, with no in-flight effects.
Critical sequence and verified backup coverage both reached 76. A final service
restart preserved both paid orders, their original quotes and payout IDs. The VM
is running with intake paused for review; other test/build VMs remain stopped.
Private evidence is under `mainnet-pilot-20261004/current-review-20261005/` in the
retained secrets directory. These transfers used dedicated customer clients;
real-wallet UI approval, independent-host recovery and independent security review
remain separate release gates.

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
