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

The requested token CLI simplification uses `ecx-token COMMAND KEYFILE`, with
an explicit transaction-request file for `sign KEYFILE TRANSACTION.json`, and
non-secret inputs in a separate `ecx-token.json`; `ecx-token configure` prompts
for those inputs without a key argument. The existing closed operations and key-only
files are preserved. The token Cabal suite verifies the new argument/configuration
contract; real Devnet status readback and sign-only acceptance passed. The mint
request template is in `1-Make-Wrapped-ECX/inputs/mint.json`. This changes token
administration ergonomics, not the frozen custody server.

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
   Retain the completed token/pool finalized-failure recovery, nonzero LP collection and explicit fee-bounded reinvestment
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
7. **Finish one-command installation against the freeze.** The candidate installer
   targets the sole executable and complete migration chain. The hardened ARM64
   signed package passed clean fresh installation, repeat/upgrade, cold boot, TLS
   authentication and actual service-account SSH denials. The reviewed x86-64
   package now also passes clean installation, upgrade, repeat-fresh refusal,
   cold boot and service isolation. The updated ARM64 package passes the same
   installed checks. Unfunded native-node/HTTPS-backup integration and encrypted
   native-wallet restoration under installer accounts also pass. Finish funded
   clean-host restoration with independent storage and old-host exclusion.
   Reuse expensive builds; run packaging acceptance after runtime changes settle.
   Authenticate the final release artifact. Public publication and valuable-fund
   activation remain explicit operator decisions after the required gates close.

## Current handoff: local work versus external prerequisites

The frozen runtime and both signed candidate packages are ready for source review;
this does not mean public-release approval. Completed local work includes the token
CLI, all three Cabal suites on both Linux architectures, automated interface checks,
service-account isolation, installation/upgrade/cold boot, the funded Mainnet round
trip, same-host in-flight recovery, and installer-account native/HTTPS-backup and
locked-wallet restoration. All task VMs are stopped; the disposable installation
and node-integration VMs have been deleted. Retain the funded pilot and evidence.

| Still open | Next action and dependency |
| --- | --- |
| Internal review follow-through | Address concrete code/dependency/license findings against the frozen source; do not repeat completed funded or installer checks without a relevant change. Independent sign-off remains separate. |
| Remaining chain recovery evidence | Permanent confirmed source loss, coverage/return and a changed native winner need valid alternate L2L history; acquire a suitable real-chain fixture or miner cooperation. Do not substitute fabricated confirmations. Token and pool finalized-failure recovery now have live two-provider evidence; retain those completed cases. |
| Customer wallet acceptance | User signs a Devnet Solana Pay request in a supported wallet; verify reference/effects and completion in the existing browser flow. |
| Independent funded recovery | User supplies physically independent storage and a clean host, with retention/deletion separation. Restore, exclude the old signer, reconcile and explicitly resume. The Mac/VM drill cannot establish physical independence. |
| Production operation | Operator supplies independent RPC capacity, host/domain/support details and confirms issuer/reserve arrangements. |
| Public release | Independent security/distribution review, operator-controlled public signing key and explicit publication/activation decision. |

## Active ten-item worklist (2026-10-05)

This replaces the earlier eight-item local accounting with the user's newly
approved ten-item list. Preserve these numbers in progress reports. Passing a
subcheck does not close its entire item or the external release gates above.

| Item | Current work and completion boundary |
| --- | --- |
| 1. Internal code review | Trace authorization, DSL dispatch, signer access, accounting, deposits, payouts, refunds and recovery; fix demonstrated defects. Current pass confirms capability-bound reads/idempotency, saved signer decisions with a second read, and single-winner settlement. Startup/shutdown review also confirms structured service cancellation, paused startup and writer cleanup; existing interruption/rollback/fencing contracts cover the ledger boundary. Independent whole-system review remains separate. |
| 2. Dependency investigation | Preserve completed source/notice and HTTP parser checks; resolve or explicitly scope remaining parser, compiler/runtime, embedded-code and license findings for independent review. |
| 3. Locally executable tests | Batch relevant QuickCheck, PostgreSQL, concurrency/restart and recovery contracts. Complete for the current local batch: all three Cabal suites and the separate PostgreSQL contract executable passed. This includes concurrency, source-loss/coverage and winner-change ledger fixtures, plus encrypted restore. Real-chain and actual-wallet acceptance remain separate. |
| 4. Real Signet fixtures | Public search found no usable fixture. The retained real block index was inspected with networking/wallet loading disabled: only the active tip at 16,947 exists, no alternate branch. The node was stopped. The upstream throwaway challenge differs from L2L; a suitable external fixture/miner cooperation remains necessary for funded conflict acceptance. |
| 5. Browser interface | Retain completed form, instructions, saved-order, status/refund and error evidence; prepare an actual wallet flow without claiming a tester client is wallet acceptance. User approval remains separate. |
| 6. Existing test deployments | Operate only environments needed by these checks, preserve funded state and stop unused services. All task VMs were stopped at handoff. |
| 7. Authorized chain tests | Retain completed Mainnet round trip and token/pool recovery evidence; run another funded case only for a new justified requirement, within authorized limits. |
| 8. Local backup/recovery | Complete locally: the fresh disposable PostgreSQL/restic batch passed snapshot consistency, corruption/password refusal, encrypted restore, exact attempts/postings and fencing checks. Test database/role were removed. Physical independence requires another host/service. |
| 9. Production preparation | Public HTTPS now uses WarpTLS in the existing Haskell server; the optional Nginx template is removed. macOS and Ubuntu ARM64/x86-64 root builds and bridge suites passed direct TLS, plaintext/body refusal, certificate/key permissions and atomic admission/refill tests. Updated `509f617` packages for both architectures passed full payload coverage and local test-signature verification; Both exact candidates passed fresh installation, repeat upgrade with unchanged configuration/custody files, and installed-systemd HTTPS/paused-intake/key-isolation smoke checks. Disposable VMs were deleted. Actual domain/cert renewal, alert delivery, provider capacity and issuer details remain deployment prerequisites. |
| 10. Review handoff | Keep exact source/artifact identities, evidence, concise instructions, cleanup and GitHub synchronized; do not regenerate frozen artifacts for documentation-only changes. |

Use the existing expensive build and real-chain evidence. Do not repeat completed
acceptance merely to increment a counter. Final completion requires the scope of
each item, with genuine external dependencies stated explicitly.

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
