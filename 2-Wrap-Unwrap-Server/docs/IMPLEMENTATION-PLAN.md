# Remaining implementation plan

## Completed nine-step implementation goal

This user-approved list supersedes the earlier ten-item accounting in Git history. The independently executable work is complete, with evidence under these same numbers. External
wallet approval, physically independent disaster recovery, L2L alternate history,
issuer arrangements and independent security sign-off remain separate release gates.

| Step | Completion evidence required | Current status |
| --- | --- | --- |
| 1. Durable offline minting | Closed nonce creation/preparation/signing/submission, exact message validation, consumed-nonce refusal and documented USB workflow | Complete locally; token Cabal suite passes nonce creation, mint, parser and offline signing contracts |
| 2. Devnet offline acceptance | Disposable imported key, real prepare/offline-sign/submit, finalized effects, replay/tamper/consumed-nonce cases | Complete; nonce creation and delayed mint finalized, exact bytes/effects and refusals verified; see RELEASE-REVIEW |
| 3. Linux token CLI | Updated token suite and executable on ARM64 and x86-64 | Complete at ba5c0f1; actual Ubuntu builds and token suites pass on both architectures |
| 4. Internal security review | Trace retained API/DSL/authorization/ledger/signer/settlement/recovery; concrete findings resolved or explicitly scoped | Complete internal pass at ba5c0f1; boundary-by-boundary audit map and explicit limits in RELEASE-REVIEW |
| 5. Dependencies and notices | Resolve applicable findings, record upstream limits and verify final distribution notices | Complete internal review: both final Linux graphs, payload notices and ELF linkage verified; unresolved upstream findings and independent distribution review remain explicit |
| 6. Current release documentation | Separate resolved history from current blockers and bind evidence to source versions | Complete: concise current review, immutable historical evidence link, one active numbered plan |
| 7. Consolidated acceptance | Relevant final browser/database/concurrency/interruption/recovery checks, without repeating unchanged funded tests | Complete at ba5c0f1: all three Cabal suites on macOS/x86-64; real PostgreSQL, encrypted restic recovery and process HTTPS contracts pass; unchanged browser evidence retained |
| 8. Review freeze | One source identity, audit map, limitations and reviewer checklist | Complete: implementation frozen at ba5c0f1, with audit map, review sequence and external limits |
| 9. Final artifacts and GitHub | Build/verify final artifacts once; install/upgrade/recovery instructions; source and evidence pushed | Complete: 548c509 ARM64/x86-64 artifacts built, payloads and test signatures verified; source/evidence pushed; public signing/publication remain operator decisions |

Use one build job and stop temporary processes. Local nonce fixtures are not real
Devnet acceptance. Recent-blockhash offline signing at `3207bd2` is implemented but
does not satisfy step 1's delayed-signing requirement.


## Required product and boundaries

A connection-free native ECX/Solana SPL inventory bridge, charging 1% in each
direction on new immutable quotes. Preserve native deposit addresses, Solana Pay
references, payment links/QR codes, saved-order recovery, refunds, explorer/trading
links, bounded treasury/revenue operations and complete financial reconciliation.
Use real L2L Signet/Solana Devnet for development and the canonical betanet/Mainnet
profile for deployment. The canonical round trip already passed; its historical
runtime is not silently replaced by later acceptance claims.

One Servant HTTP/worker process and a separate signer; PostgreSQL/Opaleye inside
closed DSL operations; GHC-JavaScript browser; Haskell/HTML/CSS application code
and bounded Rust SDK FFI; root-Cabal builds. Preserve the exact
[Main.hs reference](reference/Main.hs), constrained existential/typeclass/GADT
architecture, separate evaluators and sole authorized critical dispatch site.
[ARCHITECTURE.md](ARCHITECTURE.md) defines the concrete financial contracts.
Token mint authority and liquidity keys remain outside bridge custody. Durable
nonce minting does not authorize arbitrary Solana instructions or automatic
resigning. Unattended compounding and LP locking are separate optional scope.

## Execution order

Finish steps 1–2 before Linux acceptance. While the one-job Linux build runs,
complete substantive source/dependency review and current documentation. Fix only
concrete defects and run relevant tests once. Finish the consolidated acceptance
before the review freeze; build final release artifacts last, from that source.
Reuse expensive build caches and completed funded evidence. Stop unused VMs and
processes. Do not treat a historical passing artifact as proof for new code.

Every step must identify its exact source, test/artifact evidence and limitations.
Internal review is not independent sign-off. A blocker in an external release gate
is not a reason to stop independent work, nor permission to relabel fixture evidence.

## External release dependencies

| Requirement | Needed from operator/external party |
| --- | --- |
| Customer-wallet acceptance | Human approval of an actual Devnet Solana Pay transaction |
| Real native conflict/reorg acceptance | Valid alternate L2L blocks or miner cooperation |
| Disaster-independent funded restoration | Separate backup storage and clean host, retention/deletion separation, old-signer exclusion |
| Production operation | Host/domain, independent RPC capacity, support/alert destination and issuer/reserve arrangements |
| Independent security/distribution review | Reviewer separate from this implementation work |
| Publication and activation | Operator release-key ownership and explicit approval |

The detailed completed evidence and remaining public gates are in
[RELEASE-REVIEW.md](RELEASE-REVIEW.md). Earlier ten-item and chronological plans are
retained in Git history at `ba5c0f1`; this nine-step list is authoritative now.

## Clean reinstall contract

Keys alone do not reconstruct the ledger, customer obligations or uncertain
transactions. Recovery needs a coherent encrypted snapshot of native wallet,
Solana key, configuration, ledger, exact signed attempts and sequence/identity
manifests, plus passwords retained outside the server.

Quiesce the old worker, verify a final snapshot, retire its fence and revoke old
signing access. Restore into staging on the new host, validate identity and minimum
sequence, migrate forward, adopt the fence, reconcile both chains and pending work,
then explicitly resume. A lost host needs review of uncertain effects since its
newest backup. Never wipe the only ledger/key copy or initialize an empty ledger
for existing custody.

Preserve integer accounting, immutable terms, unique receipt use, atomic reserves,
exact signed bytes, backup barriers and exclusive ownership. Keep notices, locks
and historical evidence; remove obsolete implementation and duplicate explanations,
not required security behavior.
