# Remaining implementation plan

The replacement is now the sole server application. The duplicate server,
obsolete Python acceptance harnesses and incompatible installer have been removed.
Historical implementations and evidence remain in Git. Current source ownership
is in [ARCHITECTURE.md](ARCHITECTURE.md); acceptance scope is in
[RELEASE-REVIEW.md](RELEASE-REVIEW.md).

## Required product

Deliver a small, auditable inventory bridge that supersedes the published service:
connection-free wrapping/unwrapping, 1% new fees both ways, immutable quotes,
native deposit addresses, Solana Pay references, QR/payment links, saved-order
recovery, refunds, explorer/trading links and support. Retain bounded treasury and
earned-fee operations, reconciliation, cancellation, replacement and recovery.
Use real L2L Signet/Solana Devnet; canonical deployment needs its own acceptance.

Preserve the supplied [Main.hs](reference/Main.hs) unmodified and outside builds.
Keep its typeclass/constrained-existential/GADT intent, specific caller/severity
contexts, separate evaluators, and one authorized critical entry. Only closed
Opaleye operations access application rows. Keep one HTTP/worker process and one
credential-isolated signer; Haskell/HTML/CSS application code, GHC JavaScript
browser, bounded Rust SDK FFI and root-Cabal builds. Token authorities and liquidity
keys remain separate. Pool management, LP-lock claims and fee reinvestment require
separate explicit tooling and evidence; they are not bridge-custody privileges.

## Sequence

1. **Promoted whole: verified.** Root Cabal build, bridge/token/pool suites,
   PostgreSQL/restic contracts, server/control, HTTPS signing and encrypted native
   wallet recovery passed using canonical targets. Migration bytes and the exact
   architectural reference are unchanged. Removing legacy harnesses does not waive
   outstanding same-count record-corruption, retention or clean-host recovery checks.
2. **Close substantive recovery gaps.** Exercise permanent source loss/coverage,
   restored sources, native replacement/winner change/rebroadcast, and restoration
   with in-flight work. Retain exact bytes, one economic settlement and capital
   accounting. Complete funded encrypted-wallet signing and recovery; scoped
   wallet/export checks do not establish full funded recovery. Fix concrete
   failures in the shared payment engine rather than adding parallel paths.
3. **Complete customer acceptance.** Use an actual supported Solana Pay wallet on
   Devnet. Verify its signed transaction/reference, both conversion directions,
   refund ownership, saved-order reload and actionable errors in the current
   browser. Dedicated tester clients and QR/link rendering are partial evidence.
4. **Finish administration recovery and liquidity acceptance.** Add bounded
   token/pool attempt recovery without duplicating mint/burn/deposit effects.
   Expired-unseen status is not proof of nonexecution. Preserve attempt lineage
   and require sufficient chain evidence before replacing an uncertain attempt.
   Verify nonzero fee collection and any promised reinvestment separately. Confirm
   issuer-approved canonical identity, authority, backing and executable routes
   before enabling canonical trading/customer flows.
5. **Prove deployment and disaster recovery.** Run worker/signer under separate OS
   identities and database roles; deny worker access to custody keys, native full
   credentials and unlock/lock RPC. Verify the current processes, not only file
   permissions. Use a real off-host HTTPS restic repository with separate upload
   and operator deletion authority. Restore funded custody plus in-flight work on
   a clean host, revoke old authority, adopt the fence, reconcile and resume.
   Add restricted retention that preserves required recovery snapshots.
6. **Reintroduce one-command installation last.** Implement against the sole
   current executable/configuration and complete migration chain. Never revive
   the old helper or command protocol. Verify fresh install, repeat install,
   upgrade, reboot and restored operation on Ubuntu 24.04 ARM64 and x86-64.
   Reuse expensive builds; run packaging acceptance after runtime changes settle.
7. **Release review.** Review dependency/license applicability and the complete
   trust boundary independently. Authenticate a review artifact tied to the tested
   commit. Public publication and valuable-fund activation remain explicit
   operator decisions after all required gates close.

## Clean reinstall contract

Recovery parameters identify the deployment and the off-host encrypted repository,
with unlock material retained outside the server. A coherent snapshot includes
native wallet state, Solana custody key, configuration, ledger, exact signed
attempts and identity/sequence manifests. Seeds or public addresses cannot restore
order history, authorization or unavailable funds. Do not invent a new derivation
scheme to make existing wallets appear recoverable from one parameter.

Quiesce the old worker, retain and verify a final snapshot, retire its fence and
revoke old signing access. Restore into staging on the new host, validate identities,
migrate forward without erasing history, adopt an independently known minimum
sequence, reconcile both chains and pending attempts, then explicitly resume.
A lost host requires review of uncertain effects after its newest complete snapshot.
Never wipe the only ledger/key copy or initialize an empty ledger for existing custody.

## Working rules

Replace coherent paths, verify them, and remove their predecessors. Keep required
licenses, dependency locks and the exact architectural reference. Prefer fewer
concepts and review steps over line-count targets. Do not hide authority in generic
IO/SQL callbacks or sacrifice integer accounting, immutable terms, receipt uniqueness,
atomic reservations, exact signed bytes, backup barriers or exclusive ownership.
Stop task-owned temporary services and reuse shared nodes/caches. Completion means
all retained behavior has appropriate evidence; passing local checks alone is not
release certification or proof of perfect security.
