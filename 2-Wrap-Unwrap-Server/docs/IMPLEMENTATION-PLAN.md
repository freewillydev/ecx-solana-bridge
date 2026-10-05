# Remaining implementation plan

The sole server application is available for source review; the pilot interface is
currently offline. Prioritize a usable testing handoff and substantive runtime
findings; leave installer work last.
Source ownership is in [ARCHITECTURE.md](ARCHITECTURE.md); verified evidence and
remaining release gates are in [RELEASE-REVIEW.md](RELEASE-REVIEW.md).

The Mainnet round trip passed on review candidate `54c2bfd` in the Ubuntu ARM64
VM: 3,000 wrapped → 2,970 native, then 1,000 native → 990 wrapped. Both providers
returned the identical finalized Solana payout, and all three custody balances
reconciled with zero differences. The moving-history rescan regression passed
locally before this funded retry. Critical sequence and backup coverage are 55;
the sequence-55 custody snapshot preserves the exact pre-broadcast attempt.
Freeze this runtime for review and batch the remaining acceptance against it.
Services are stopped. Backup storage still shares the physical Mac; independent
backup/clean-host restoration and the remaining release gates are open.

## Required product

Deliver a small, auditable inventory bridge that supersedes the published service:
connection-free wrapping/unwrapping, 1% new fees both ways, immutable quotes,
native deposit addresses, Solana Pay references, QR/payment links, saved-order
recovery, refunds, explorer/trading links and support. Retain bounded treasury and
earned-fee operations, reconciliation, cancellation, replacement and recovery.
Use real L2L Signet/Solana Devnet for funded development. Canonical ECX/Solana Mainnet
supports the same order/payout engine; its deployment needs separate funded acceptance.

Preserve the supplied [Main.hs](reference/Main.hs) unmodified and outside builds.
Keep its typeclass/constrained-existential/GADT intent, specific caller/severity
contexts, separate evaluators, and one authorized critical entry. Only closed
Opaleye operations access application rows. Keep one HTTP/worker process and one
credential-isolated signer; Haskell/HTML/CSS application code, GHC JavaScript
browser, bounded Rust SDK FFI and root-Cabal builds. Token authorities and liquidity
keys remain separate. Pool management, LP-lock claims and fee reinvestment require
separate explicit tooling and evidence; they are not bridge-custody privileges.

## Sequence

The observed payout blockers are fixed and the existing Mainnet obligation is paid.
Do not create additional Mainnet orders for routine regression. Use the saved
pre-broadcast snapshot for in-flight restoration and existing Signet/Devnet fixtures
for remaining recovery work. Preserve both-provider agreement, required backups,
the 40-block send floor and the frozen candidate. Change runtime only for a
reproduced substantive finding; keep packaging last.

The latest local checkpoint is a confirmed additional-deposit Signet refund with
correct principal/cost settlement, the original conversion still paid, and a
verified offline custody snapshot. A subsequent funded native replacement is confirmed:
draft/sign replay returned the same child, a paused restart settled it once, repeated
observation preserved accounting, and its custody backup passed integrity checks.
Winner-change/reorg and rebroadcast acceptance remain separate. The operator CLI now reports server
refusals with a failing exit status, preventing scripts from continuing on an error.

1. **Hand over the product for review now.** Identify the review commit and built
   artifact. Begin source review while the pilot is stopped. After service restart,
   use http://127.0.0.1:61992/ on its host Mac for interface review; this is a
   forwarded pilot address, not a standard deployment port. Check network/token
   identity, limits, 1% previews and both forms without automatically creating or
   funding orders. Trace the existing audit path
   from pure Servant requests through authorization, closed Opaleye operations,
   chain validation, signing and settlement. Record concrete findings against the
   same candidate; keep private order capabilities and custody material outside Git.
2. **Finish customer acceptance and provider provisioning.** Retain the completed
   canonical round trip and exact finalized payout evidence. The public verifier
   worked for this pilot; production still needs sufficient independent-provider
   capacity. Do not repeat the funded round trip merely to recheck known results.
   Complete a real supported Solana Pay wallet flow on Devnet, including reference
   and effects, both conversion directions, refund ownership, saved-order reload
   and actionable browser errors. A tester client or rendered QR is partial
   evidence. Measure both required checkpoints and combined worker/signer RPC
   budgets inside the Solana blockhash window; preserve expiry and backup barriers.
3. **Close substantive recovery gaps.** Exercise permanent source loss/coverage,
   restored sources and native winner changes after reorg. Retain the completed
   explicit rebroadcast and same-host in-flight Solana restoration/replay evidence. Retain the completed isolated native rebroadcast and
   in-flight restore acceptance. Retain exact bytes, one economic settlement and capital
   accounting. Keep the completed same-host encrypted-wallet drill as regression
   evidence. Fix shared-engine failures without introducing parallel payment paths.
4. **Finish administration and canonical verification.** Extend the existing
   Devnet token/pool recovery acceptance to remaining required action families.
   Retain the completed nonzero LP collection and explicit fee-bounded reinvestment
   acceptance. Unattended compounding is not implemented. Preserve bounded
   lineage and complete two-provider evidence; expired-unseen status alone is not
   proof of nonexecution. Confirm issuer-approved canonical identity, authority,
   backing and executable trading routes before public use.
5. **Prove independent recovery and complete isolation review.** Retain the VM's
   separate OS/database identities and actual denied-key/RPC checks. Finish review
   of administrative access and service policies. Use a physically independent
   HTTPS restic repository with separate upload/deletion authority and protected
   retention. Restore funded custody plus in-flight work on a clean host, revoke
   old authority, adopt the fence, reconcile and resume. Verify host/node reboot
   and unattended VM startup as well as the completed VM restart.
6. **Complete independent release review.** Review source, deployment, dependency
   applicability and licenses against the tested candidate. Resolve substantive
   findings and preserve evidence for each remaining release gate. Local tests and
   the bounded TLA+ model do not replace independent review.
7. **Reintroduce one-command installation last.** Implement against the sole
   current executable/configuration and complete migration chain. Never revive
   the old helper or command protocol. Verify fresh install, repeat install,
   upgrade, reboot and restored operation on Ubuntu 24.04 ARM64 and x86-64.
   Reuse expensive builds; run packaging acceptance after runtime changes settle.
   Authenticate the final release artifact. Public publication and valuable-fund
   activation remain explicit operator decisions after the required gates close.

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
