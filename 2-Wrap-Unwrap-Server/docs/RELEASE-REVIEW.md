# Release review

The current implementation is a reviewable test-network product, not a completed
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
| Signer model | Bounded two-request TLA+ model: 54,289 distinct states; path/output/dispatch invariants and negative mutations checked. No TLAPS/unbounded Haskell proof. |
| Token administration | Real Devnet mint/account creation, issuance/burn and metadata readback, preserving signed-attempt replay. Canonical authority/backing and bounded uncertain-attempt recovery remain open. |
| Liquidity | Real Devnet pool/position creation, funded deposit/withdrawal and collection replay. Collected fees were zero; nonzero yield/reinvestment remains unverified. |
| Trading | Read-only Jupiter quotes used the expected published Orca pool in both directions. Quotes do not prove executed swaps, current route availability or backing. |

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

## Gates still open

1. **Customer wallet:** sign a real Devnet Solana Pay deposit in a supported wallet;
   verify reference/effects, both directions, saved-order recovery, refunds and
   browser errors. A test client or wallet-opening link does not close this gate.
2. **Recovery effects:** verify permanent source loss/double spend, coverage/return,
   native replacement/winner change/rebroadcast and restoration with in-flight
   signed work. Complete funded encrypted-wallet signing and restored operation.
   Preserve one payout, correct capital/cost accounting and exact saved bytes.
3. **Isolation and off-host recovery:** exercise the current worker/signer under
   separate OS and PostgreSQL identities, actual restricted native RPC, and denied
   key/full-cookie/unlock access. Restore funded custody on a clean host using a
   real off-host HTTPS repository, separate deletion authority, retained passwords,
   protected retention and explicit old-host exclusion/revocation.
4. **Administration and canonical use:** finish bounded token/pool expiry recovery
   without duplicate effects, nonzero LP fees/reinvestment where promised, issuer
   approval, canonical authority/reserves and funded betanet/canonical acceptance.
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
