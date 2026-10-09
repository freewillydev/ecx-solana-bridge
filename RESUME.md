# Release continuation

Owner: WRAPPED ECX SOL (01a0f386-08b9-7611-896d-93fd473ea928), ecx-bridge lane, branch codex/ubuntu-one-command. Read controller PROTOCOL.md and OWNERS.md before writes. Helpers are read-only.

## Current state

Production is NOT ready. Reviewed source 2f6c921; published/runtime candidate ef2f17d, artifact SHA256 2fa48bb4216f1dd028d512a44cd21d4d67358f9421050697f0774f64006110b2. Security scan a78bb337-7642-4c2d-bee4-9a653b601387 is sealed with two medium findings. Never edit its canonical artifacts or represent a completed scan as a pass.

All runtime/test/build/script source reviewed; 179/185 tracked files, six nonruntime documents/inventories deferred. Findings: Solana history catch-up stalls beyond 1,000 newer signatures; root recovery chown path races through service-owned ancestry. Recovery-staging candidate patch is committed/pushed as 720c961: separate root-owned staging hierarchy, ancestor verification, early legacy-path refusal; targeted --restore-only test passed locally. Full local bridge suite PASS; fresh recovery_patch_reviewer static PASS. Privileged Ubuntu --restore-root-only contract PASS (SSM 79142eba-e0cc-40a7-ab54-8da45bb0aa5e), exercising both roles and retained completed stages plus hostile ancestor cases; no RPC/restoration/payment. Protocol verifier protocol_corrected_verifier: protocol PASS, production FAIL. Solana history source patch b21464f is under validation; no runtime artifact changed. Dependency advisories bincode/Cabal/base retain documented upstream/transitive limits.

Exact published clean-host configure, interrupted setup and reentry passed; full fresh running install remains open. Unfunded test hosts i-05a1d37ba2560b807 and i-0cf53b8026e02ad28 stopped. Sole funded custody host i-0fc7cf24ffe177dd2; retired source i-0a62cafbef864b8a7 must remain fenced. Public access OFF. Original round trip and funded restore passed; do not resend them.

## Exact next steps

1. Diagnose default PostgreSQL customer-workflow failure in b21464f. Its dedicated history/restart/backup-restoration contract and Linux core suite passed; the broader contract failed a generic assertion. Test-only e1e65a3 adds HasCallStack at the assertion. SSM 698a5e3b-6e93-484c-91d4-18c32b89e3e0 is rerunning default on a NEW disposable database using the stopped isolated cluster; inspect its status/log before any retry. Do not restart a second job.
2. Inspect `/home/ubuntu/ecx/history-e1e65a3-default.log` on retired source i-0a62cafbef864b8a7. Preserve failed databases/logs, fix only the demonstrated failure and rerun applicable checks. Worker/signer/cloudflared must stay masked/inactive there; no custody services used by these tests.
3. Retain immutable logs/hashes and the fresh static verdict from history_final_verifier (PASS for b21464f correction, overall release FAIL). Do not mark history fixed until applicable contracts pass. Rebuild/publish/deploy only a verified candidate with preserved backups.
4. Complete fresh running install acceptance against that artifact; retain original custody identity. Never activate competing funded signers.
5. First obtain fresh separate pre-public PASS for SEC, BUILD, INSTALL, WALLET, FUNDS, RESTORE, ALERT and TRUST, plus proof ingress OFF. Only then separately authorize enablement and perform HTTPS acceptance. Afterwards obtain fresh final overall verifier PASS; no merge or production completion claim before that final PASS.

## Evidence and blockers

Local sealed report: /Users/lukekensik/.codex/state/plugins/codex-security/scans/ecx-bridge/2f6c921a44180e7fb36ac2be71b2c0568c77dceb_20261009T220630Z_cevdpyi4/report.md
Private operational evidence: /Users/lukekensik/Documents/Codex/2026-10-08/i-x20/work/release-acceptance.json and production-checkpoint.md. Keep credentials/capabilities out of logs and Git.

Clean configure SSM: 65e6dc6f-f8da-469b-9322-4a97b10d58d2; final unchanged-private-files/process check dabbc9b2-d1d4-4337-a092-5ef61344f0fa. These do not certify runtime installation.

Luke deferred manual wallet, external alert destination and production signing custodian/trust channel; do not ask repeatedly or mark them passed. Local remediation can proceed. No new transfers are needed for protocol adoption. Standing fund authorization remains subject to no duplicates, verified signer/chain outcomes and retained backups.

## Active history remediation candidate

The working patch adds bounded rolling observation history (4 pages per call,
500 retained oldest signatures), two typed auxiliary progress records in the
existing checkpoints table, CAS-bound closed writes and atomic batch/progress
retirement. Strict expiry/absence collection is unchanged. Pending verification
gets a reserved 500 slots and suppresses readiness while more remain. No automatic
resume. Full local bridge suite passed before the final stale-progress correction.

Fresh static reviewer history_patch_reviewer found one real regression: an older
binary can advance real coverage while leaving a saved progress record. The patch
now logically ignores scratch state bound to an obsolete checkpoint and replaces
it only in a closed locked write; no accounting is rewound. A dedicated
ECX_REBUILD_HISTORY_ONLY PostgreSQL contract covers restart, stale CAS, rollback,
retirement, duplicate posting and the old CommitScan/re-upgrade sequence.
Linux build/core/dedicated history/backup restore PASS on b21464f via SSM
f22839ff-1748-4a23-bff7-7274015b1e1c. Default PostgreSQL failed customer workflow;
verification is incomplete. Cluster stopped cleanly; disposable data retained.
Fresh history_final_verifier static correction PASS on exact b21464f, production FAIL.
No runtime artifact deployed. The 8 PM target never waives any DONE.md gate.
