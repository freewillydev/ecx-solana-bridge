# Release continuation

Owner: WRAPPED ECX SOL (01a0f386-08b9-7611-896d-93fd473ea928), ecx-bridge lane, branch codex/ubuntu-one-command. Read controller PROTOCOL.md and OWNERS.md before writes. Helpers are read-only.

## Current state

Production is NOT ready. Reviewed source 2f6c921; published/runtime candidate ef2f17d, artifact SHA256 2fa48bb4216f1dd028d512a44cd21d4d67358f9421050697f0774f64006110b2. Security scan a78bb337-7642-4c2d-bee4-9a653b601387 is sealed with two medium findings. Never edit its canonical artifacts or represent a completed scan as a pass.

All runtime/test/build/script source reviewed; 179/185 tracked files, six nonruntime documents/inventories deferred. Findings: Solana history catch-up stalls beyond 1,000 newer signatures; root recovery chown path races through service-owned ancestry. Recovery-staging candidate patch is now in the working tree: separate root-owned staging hierarchy, ancestor verification, early legacy-path refusal; targeted --restore-only test passed locally. Full local bridge suite PASS; fresh recovery_patch_reviewer static PASS. Privileged Ubuntu --restore-root-only contract PASS (SSM 79142eba-e0cc-40a7-ab54-8da45bb0aa5e), exercising both roles and retained completed stages plus hostile ancestor cases; no RPC/restoration/payment. Protocol verifier protocol_corrected_verifier: protocol PASS, production FAIL. Solana history fix not yet applied. Dependency advisories bincode/Cabal/base retain documented upstream/transitive limits.

Exact published clean-host configure, interrupted setup and reentry passed; full fresh running install remains open. Unfunded test hosts i-05a1d37ba2560b807 and i-0cf53b8026e02ad28 stopped. Sole funded custody host i-0fc7cf24ffe177dd2; retired source i-0a62cafbef864b8a7 must remain fenced. Public access OFF. Original round trip and funded restore passed; do not resend them.

## Exact next steps

1. Recovery ancestry patch is committed/pushed as 720c961 and passed local full suite, fresh static patch review and Linux privileged contract. Public/runtime artifact still ef2f17d, so it is not deployed. Retired source services remained masked/inactive. Preserve generated regression fixtures. Continue the Solana history fix from the read-only history_boundary_investigator report; implement bounded durable catch-up without skipping receipts.
2. Add regressions proving hostile ancestor replacement cannot affect external ownership and ordinary recovery still works. For history, prove progress over >1,000 signatures across interruption without skipping or duplicating receipts. Do not merely raise/remove the cap or skip the anchor.
3. Run one-job targeted Cabal checks, then applicable full contracts once the combined patch is stable. Obtain a fresh read-only bypass/regression verdict before declaring either fixed. Rebuild/publish/deploy only a verified candidate with preserved backups.
4. Complete fresh running install acceptance against that artifact; retain original custody identity. Never activate competing funded signers.
5. Reconcile every DONE.md row and request fresh separate final verifier PASS/FAIL. Do not merge, call production done, or enable public ingress before PASS.

## Evidence and blockers

Local sealed report: /Users/lukekensik/.codex/state/plugins/codex-security/scans/ecx-bridge/2f6c921a44180e7fb36ac2be71b2c0568c77dceb_20261009T220630Z_cevdpyi4/report.md
Private operational evidence: /Users/lukekensik/Documents/Codex/2026-10-08/i-x20/work/release-acceptance.json and production-checkpoint.md. Keep credentials/capabilities out of logs and Git.

Clean configure SSM: 65e6dc6f-f8da-469b-9322-4a97b10d58d2; final unchanged-private-files/process check dabbc9b2-d1d4-4337-a092-5ef61344f0fa. These do not certify runtime installation.

Luke deferred manual wallet, external alert destination and production signing custodian/trust channel; do not ask repeatedly or mark them passed. Local remediation can proceed. No new transfers are needed for protocol adoption. Standing fund authorization remains subject to no duplicates, verified signer/chain outcomes and retained backups.
