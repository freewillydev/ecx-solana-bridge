# Release continuation

Owner: WRAPPED ECX SOL (01a0f386-08b9-7611-896d-93fd473ea928), sole writer of ecx-bridge / codex/ubuntu-one-command. Read controller PROTOCOL.md and OWNERS.md before writes. Helpers/verifiers are read-only. Never delete data or replay completed payments. Public ingress remains OFF.

## Current state

Production remains FAIL. Exact candidate 8c18bd88c0d65b2291802d805a246a754b5d61c0 is now installed on sole funded host i-0fc7cf24ffe177dd2. Installer SHA256 1adc398d1a45a7da34f2ee184da7a7cae282eca0c7259bd2b9b4eeb948fd10b9 (40,278,127 bytes, 48 manifest entries). Release directory /opt/ecx-bridge/releases/b3492835d90f0cb86c900aa32e0cbdd9066bca266219e8ea722a1d2d97ae8a19. This supersedes old ef2f17d runtime; retain old artifact and all backups.

Checked upgrade SSM 8b4a943a-ec6d-46b8-8145-46d85a020316 Success/0. Normal lifecycle saved/verified backup and preserved custody; no manual symlink switch or payment replay. Private /root/ecx-release-8c18bd8/upgrade.log and upgrade.exit. Post-upgrade 7a48ba2b-c9da-4355-8682-8a673f1d55cb verified same original Paid order IDs, quotes and payout IDs, current candidate, no pending upgrade, active worker/signer and inactive public tunnel. Operator status 515ab612-4ddc-4dbe-aa2b-a6b974c051af: paused=false, reason=ready, criticalSequence=105, backupSequence=105.

## Verification and security

Original sealed scan a78bb337-7642-4c2d-bee4-9a653b601387 against 2f6c921 found two medium issues. 179/185 files reviewed, all runtime/test/build/scripts; six nonruntime documents/inventories deferred. Do not rewrite sealed artifacts or equate scan completion with release approval.

Recovery staging patch720c961: root-owned staging hierarchy and ancestor validation, early legacy-path refusal. Local suite/static review and Linux privileged contract 79142eba-e0cc-40a7-ab54-8da45bb0aa5e PASS.

History patchb21464f: bounded rolling observation history, typed durable scratch/CAS, atomic commit/retirement, old-binary stale-progress compatibility. Strict absence/expiry proofs unchanged, no automatic resume. Linux core/dedicated progress/backup-restore PASS. Initial default test failed a confirmed real-clock fixture race; test-only 8c18bd8 stabilizes expiry/pause before HTTP comparison without weakening assertions. One diagnostic failed worker_already_running; cause remains unproven, evidence retained. Final default ebc61e2a-2463-46a5-9db6-2778b14c8e91 PASS.

Full exact-candidate build/all three test suites/ten PostgreSQL modes PASS: f86ce8b4-e208-4a76-b60c-7875139d96cc. Modes fence, setup, setup_residue, server, server_canonical, tls, tls_canonical, cache, history_progress, history (1001). Hash receipt 0b67ba64-4e97-4f31-9882-0b2ee48d3ca4; logs /home/ubuntu/ecx/release-8c18bd8-*.log on retired source i-0a62cafbef864b8a7. Custody services there remain inactive/masked. Preserve logs/databases; stop instance when no longer needed.

Fresh separate release_candidate_verifier independently inspected exact source, SSM evidence and installer hash: scoped remediation PASS; overall production FAIL. Earlier protocol_corrected_verifier: protocol PASS / production FAIL. No merge or completion approval.

Derived history fix report: /Users/lukekensik/.codex/state/plugins/codex-security/scans/ecx-bridge/artifacts-83a15996a6f20553b8636342c2d21a4103912483358647ecc82bc5fe4b358f3a/findings/history-progress-fix-8c18bd8.md (SHA256 ae8e26238cf0f34c86ac425ac94d8fdd984bc6e8cadd86a8f12693103bf19541). Sealed report under sibling 2f6c921a44180e7fb36ac2be71b2c0568c77dceb_20261009T220630Z_cevdpyi4/report.md. Dependency advisories bincode/Cabal/base remain documented, not accepted or resolved.

## Exact next steps

1. Fresh Ubuntu i-080ffde827e5b745b (172.31.47.125), no ingress, currently usefully syncing real betanet. Interrupted/reentry 336cec8e-3d1a-43fb-9431-e1a73533d7ce PASS (exit0, four prompts, zero seconds); configure bf0e0b0f-27b3-4479-b29f-9d34bccd9cb7 PASS (nine prompts). Original 7a6aad6e driver reached its600-second timeout and killed its child but accepted exit1; that is NOT a passing cancellation test. Corrected driver rejects timeout and explicitly exits returned menu. No application fix was needed. Private evidence /root/ecx-fresh-8c18bd8.
2. New custody setup encrypted off-host /Users/lukekensik/Documents/Codex/aws-ecx/private/fresh-8c18bd8-complete-setup.der, SHA256814c29a3dff465ba1509b7cd1e41787db924236ab01c081bd2f5098aa6225bb0; decrypted in memory and expected key/recovery files verified before start. Initial real start2045adcc-b26b-4905-8ca6-0f89c7962fcb exits1 with native_not_ready_rerun_start. Both providers, separate new encrypted restic repository and pinned real node installation passed. Read-only133dc9db-e0e0-487e-98b8-22f32ce29bdd: initial sync subsequently progressed to blocks148885/headers971570 (174acf5e-71e9-410f-81ff-fa8139abac7f); initialblockdownload=true. All pre-start setup/key file hashes remained unchanged. Wait for sync, inspect getblockchaininfo through generated native-admin.auth without logging credentials, then rerun SAME `/usr/local/bin/ecx-bridge start /var/lib/ecx-bridge-setup/.ecx-bridge`; retain new log/exit file per attempt. Never generate replacement keys. Start may next request SOL funding; verify any signed attempt/on-chain state before retry. No funding has been sent to this fresh wallet. Full fresh running/reboot acceptance still FAIL. Preserve backups and compare before-start-hashes.json.
3. Review prerelease https://github.com/freewillydev/ecx-solana-bridge/releases/tag/review-2026-10-09-security-remediation published unsigned; GitHub asset digest matches1adc398d. No production trust claim. Retired source/build i-0a62cafbef864b8a7 is stopped after all jobs completed; disks/logs/databases retained. Other old test VMs remain stopped. Fresh syncing node, sole funded deployment and backup host are the only currently needed machines. Stop fresh test host when no longer actively syncing/testing.
4. Luke deferred real Solana Pay wallet-app availability, external alert destination and production signing custodian/trust channel. Do not ask repeatedly or fabricate substitutes. These remain FAIL. Dependency advisory release-authority disposition also required.
5. Fresh separate pre-public PASS required for SEC/BUILD/INSTALL/WALLET/FUNDS/RESTORE/ALERT/TRUST plus ingress OFF. Only then separately authorized public HTTPS acceptance; then fresh final overall PASS. No deadline waives a check.

## Backup credential incident and preserved custody

Owner diagnostic exposed a backup HTTP credential by parsing a rest:-wrapped URL as ordinary URL. Old worker credential revoked; old401/new200 verified, actual signer-role restic read of original snapshot PASS. No wallet key or encryption password read by that diagnostic. Never print URL/components, restore old credential or copy it from logs.

Rotation receipts: 579af13c-7567-4b53-8587-8e47c5c76ad9, 46912611-3ead-46bd-a5f3-54e9714d3beb, 89f0e471-6d4b-4ba5-a1d5-5ee125d44167. Private records on destination /root/ecx-release-8c18bd8/rotation and backup i-000a82a5bf73e153c /root/ecx-backup-private/rotation-8c18bd8. Production repository remains /worker/production-20261009/. Registered setup /var/lib/ecx-bridge-restore/setup references rotated input /root/ecx-funded-restore-ef2f17d/inputs/repository.

Original paid990 wrapped and2970 native transfers unchanged. Snapshot105 62826c26c9d024e4ca275a762d4b8e8a47f8262357da010003f6713d96f155f6 retained. Private evidence /Users/lukekensik/Documents/Codex/2026-10-08/i-x20/work/release-acceptance.json and production-checkpoint.md. Customer capabilities/config/keys never enter Git or outputs. Older unfunded instances i-05a1d37ba2560b807 and i-0cf53b8026e02ad28 remain stopped.
