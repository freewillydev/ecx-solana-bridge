# Release review handoff

Review the committed source and the eventual consolidated Linux artifacts separately.
The private draft predates current authorization, frontend, escrow and subprocess
changes. Passing evidence for an older binary does not certify the current source.
No independent reviewer has signed off, and canonical intake remains disabled.

## Working product and evidence

| Requirement | Evidence and practical limit |
| --- | --- |
| Connection-free conversions, 1% new fees, preserved historical terms | `evidence/postgres-fresh-product-live.json`, `evidence/installed-paying-product.json`: real API/worker transfers on L2L Signet and Solana Devnet; dedicated clients supplied deposits. |
| Verified-owner refund, canceled unsigned preparation | `evidence/postgres-product-flows.json`: real finalized refund; does not prove every ambiguous/late receipt case. |
| Customer saved-order recovery | `evidence/customer-manual-recovery-link.json`: actual browser recovery/reload and selectable private-link text; external wallet signing and clipboard bytes remain unverified. |
| Severity DSL, separate read identity and one critical dispatcher | `evidence/dsl-public-boundary-audit.json`, `evidence/observer-separated-reader-authority.json`: compiler consumer probes and actual restricted PostgreSQL/API checks. New source must still receive consolidated Linux acceptance. |
| Native replacement and confirmation recovery | `evidence/postgres-native-family-live.json`: actual replacement/confirmation and same-member loss/reconfirmation; not a public winner-changing reorg. |
| Native signed-unsent host recovery | `evidence/installed-native-inflight-restore.json`: actual retired-source archive and new-host saved-byte recovery. |
| Solana signed-unsent host recovery | `evidence/installed-solana-inflight-restore.json`: 38 tables restored, retained bytes, actual two-provider expiry, explicit retry, one finalized replacement and restart. Off-host durability/key revocation excluded. |
| PostgreSQL source loss/restoration | `evidence/postgres-source-local-disconnect.json`: actual local Signet block invalidation/reconnection, unchanged postings/attempts. No permanent loss or double spend. |
| Encrypted escrow and retention tools | `evidence/encrypted-handoff-staging-local.json`, `evidence/backup-retention-local.json`: real local restic encryption/restore and retention; not physically independent storage. |
| Current regression batch | `evidence/process-group-cleanup.json`: library build and 374 Haskell examples, including surviving-child cleanup; not installed Linux acceptance. |

## Review boundaries

Start with `src/Bridge/Operation.hs` and `Operation/Internal.hs`, then
`Postgres/Server.hs` and `Postgres/Runtime.hs`. Handlers resolve into closed plans;
only the central dispatcher evaluates critical work. SafeContext uses separate
read credentials. Examine exports and Cabal component boundaries as well as
individual functions: a safe type is insufficient if it can import worker authority.

Review `Postgres/Ledger.hs`, `Schema.hs`, `Maintenance.hs` and PostgreSQL migrations
for transaction ownership, immutable records, numeric bounds, constraints and
worker sequencing. Runtime queries use Opaleye; named maintenance/locking/DDL
primitives and the explicit historical importer are separate boundaries. The
`legacy` library is regression compatibility, not the production database layer.

Follow `Payment.hs`, `Settlement.hs` and `Postgres/PaymentStore.hs` through native
and Solana validators, source checks, preparation, signed-byte journal, backup,
recorded-send authorization, observation and settlement. Review interrupted
commits, changed chain evidence, expired generations, native replacement winners,
source-loss capital and refund ownership together. No transaction may remain
open across an RPC, signing or remote backup call.

Review `Process.hs`, `Postgres/Backup.hs`, `deploy/postgres-remote-backup.py`,
`encrypted-handoff.py` and host fencing together. Backup receipts must represent
an authenticated exact snapshot with sufficient sequence. A source retirement
marker cannot revoke copied keys on another machine. Remote-host independence,
repository deletion authority and operator password escrow need deployment evidence.

The Rust helper accepts bounded fixed requests and signs official SDK messages;
inspect independent Haskell byte validation and sandbox filesystem access too.
Dependency findings remain in `DEPENDENCY-REVIEW.md` and `THIRD-PARTY.md`. Generic
readFloat code is present in the installed ELF; attacker-controlled reachability
is unresolved. Bincode is pinned and unmaintained; no migration or waiver is implied.

## Remaining gates

1. Complete concrete permanent-loss/double-spend and winner-change acceptance;
   identify whether a failing case needs implementation or stronger evidence.
   Existing database fixtures and local disconnects cannot prove public consensus
   behavior. Keep customer obligations and capital accounting intact throughout.
2. Perform actual supported Solana Pay wallet signing with a dedicated Devnet
   identity. Record resulting transaction/reference validation and order recovery.
   A tester client or wallet-opening link does not establish this gate.
3. Exercise the real off-host HTTPS repository with separate worker/operator
   credentials, retention, receipt barrier and clean-host restoration. Prove
   recovery without relying on the lost host, including password/key custody and
   an explicit old-key retirement/revocation strategy.
4. Verify issuer-approved canonical configuration, supply/backing and funded
   betanet/canonical flows. Verify the full-range pool and executable market route
   before claiming Jupiter/Orca availability. No canonical funds are allocated here.
5. Complete dependency/license applicability and independent security review.
   If the plan's bounded fee-sweeping requirement is retained, it still needs a
   supported ledger/signing workflow and acceptance; no general fee-withdrawal
   command is implemented or certified by the current evidence.
6. After substantive fixes, build source once for ARM64/x86, perform affected
   install/upgrade/reboot/restoration checks, and authenticate a new private review
   candidate. Public publication and valuable-fund activation require their own
   operator decision.

Findings should identify the exact commit/artifact, affected invariant, concrete
trigger, consequence, required change and a check that would prove closure.
Tests and reports support only their stated scope. Do not replace outstanding
external gates with local approximations or mark the whole project complete.
