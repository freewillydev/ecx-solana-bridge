# Release continuation

Owner: WRAPPED ECX SOL (01a0f386-08b9-7611-896d-93fd473ea928), sole writer of ecx-bridge / codex/ubuntu-one-command. Read controller PROTOCOL.md and OWNERS.md. Helpers read-only. Never delete data or replay completed payments. Public ingress OFF. Production FAIL until every DONE.md gate passes; deadline does not waive gates.

## Current source and runtime

Source8c2c9eb4d67192296be9feb806e4f09e0b7b2897 is pushed and installed on sole funded host i-0fc7cf24ffe177dd2. Public unsigned prerelease review-2026-10-09-six-confirmations. Installer40,282,254bytes, SHA256722cba45da5f22e3082dec3ff97519c1dce1ca3e3554e4698b156004fc195c53; GitHub digest matches. Runtime release0ee0664eeaa9e72b2dcb19931fc5d2c2a883592e0136e4415fd04b763577f526. Older source/artifacts/evidence remain preserved.

Local bridge suite /tmp/ecx-optional-entropy-final-test.log PASS. Linux build/all bridge/token/pool suites/package5b3330ce-2c78-4051-a16b-46997877a61e PASS. Logs /home/ubuntu/ecx/release-8c2c9eb-{build,tests,package}.log on retired source/build i-0a62cafbef864b8a7. First build attemptf251c2e2 failed because remote aws executable absent; replaced with private presigned transfer, no source issue. Canonical PostgreSQL contractb4d65e5f-16d5-4e2e-bf84-ec0b6f2a1072 PASS; /home/ubuntu/ecx/release-8c2c9eb-canonical-v2.log, retained stopped cluster /tmp/ecx-release-contract.vRtQtQeN. First attempt0d2373ad used wrong socket path; preserved failed logs/cluster, corrected to documented hardcoded socket. Earlier full eleven-mode financial acceptance is8c18bd8 (defaultebc61e2a plus10modesf86ce8b4), not rerun on finalsource.

Checked upgrade6bc6d80a-42c9-484a-90b3-164624e3d654 Success/0. Stagingcea5edd2 verified source and48manifest entries before runtime change. Postcheck71c4ee3f-656e-4df5-9e5b-3b177bcd564c PASS: managed console current, no pendingupgrade, active worker/signer, configs6, original Paid orders/quotes/payoutIDs unchanged. Statusfa85eba3 PASS: critical=backup105, ready/unpaused; PG/native/worker/signer all127.0.0.1, cloudflaredinactive. Private records /root/ecx-release-8c2c9eb onfundedhost.

Active ten-minute soak SSM e422f3ba-c176-4a0a-80b7-865cde982eed, host i-0fc7cf24ffe177dd2. Poll this exact handle; do not restart it on observation timeout. It verifies11samples every60s, Paid orders unchanged, backed-up105, ready, no restarts/publicoff; private soak.jsonl. Get terminal result before claimingPASS.

## Security and verifier

Sealed Codex Security diff ce915317-fc28-4018-940f-c40583615060: exact8c18bd8..8c2c9eb, all19changedpaths, zero findings. Independent readonlyhelpers covered7wallet/policy/testfiles and2installers; parent10docs/evidence. Report /Users/lukekensik/.codex/state/plugins/codex-security/scans/ecx-bridge/8c2c9eb4d67192296be9feb806e4f09e0b7b2897_20261010T002005Z_85x46rhi/report.md. No live gate certification or advisorywaiver. Snapshot trustedoperator input, notgenesisvalidation. Reported scanusage2,435,923tokens includes2,350,208cachedinput perplugin.

Originalfullscan a78bb337-7642-4c2d-bee4-9a653b601387 at2f6c921 found2Medium issues. Both fixed/deployed: root recovery ancestry720c961, bounded durable historyb21464f withtestfixture8c18bd8. Regression receipts79142eba, ebc61e2a, f86ce8b4; originalsealed179/185 unchanged, sixremainingdocs supplementscopedPASS. bincode/Cabal/base advisories remain open for documented release-authority disposition. Prior release_candidate_verifier scopedremediationPASS/overallproductionFAIL. New final independent per-gate verdict still required.

## Fresh installation and external gates

Fresh i-080ffde827e5b745b: original8c18bd8 configure/interruption/reentry PASS; preserved setup /var/lib/ecx-bridge-setup/.ecx-bridge. Encrypted offhostcopy /Users/lukekensik/Documents/Codex/aws-ecx/private/fresh-8c18bd8-complete-setup.der SHA814c29a3dff465ba1509b7cd1e41787db924236ab01c081bd2f5098aa6225bb0. Real nodefullysynced1a88bd4f viaMacsnapshot; start3f053eb6 exitsfund_solana_owner_then_rerun_start. No ATAattempt/bootstrapcomplete/worker config yet. Wallet9Dfte8EDq1L9F2N4qTuMqtAEZUmDcvXpCu7EGXEHVcjY had0finalizedlamports onpublicMainnet at00:28UTC. Pending userquestion asks0.003SOL orseparatenoncustodyfundingsource. Never bypass existingbridgecustodyaccounting to fund it. No generatedwallet fundedbyus. VMstoprequested afterdc10994b verifiednocustodyservices; preserveallvolumes/data. ResumeVM only forfundedacceptance.

Original fresh bootstrap is sealed atdepth1: do not editbootstrap-bound.json orregeneratekeys. Complete preserved setup withcompatibleoriginalruntime, then explicitreviewedpolicytransition6 beforeorders; fullfinalartifactfreshinstall acceptance stillFAIL. Existingfundeddeployment transitioned6 withbothservice+retainedsetupconfigs preserved/checkpointed3cc791a9; historicalordersretaintheirterms.

User deferred realSolanaPaywallet-app test, externalalertdestination, productionsigningcustodian/trustchannel. Do notfabricatesubstitutes orrepeatedlyask. WALLET/ALERT/TRUST remainFAIL. PUBLIC andVERIFY dependonallgates. Unsignedreviewartifactdoesnotpassthetrustgate.

## Immediate next steps

1. Pollsoake422f3ba; getfreshseparateverifier per-DONErow againstfinalsource/artifact/evidence. Review exact installer upgradeconsole preservation andallapplicablechecks; reportanygapexplicitly.
2. Retiredsource/build i-0a62cafbef864b8a7 currentlyRUNNING forcompletedbuild; custodyservicesverifiedinactivec5dea03e. Allowverifiertoinspectlogs thenstopinstance; preservevolumes/databases. CheckfreshVMstopped. No localbuild/testprocessleft.
3. Continuefreshacceptance onlywhenSOLfunded/authorizednoncustodyfunderavailable; inspect onchain/savedattemptbeforeanyretry. No newpaymentsneededonexistingPaidorders.
4. RefreshDONEstatusandthisfilewithterminalsoak/verdict, append.audit/release.tsv. Source/docpointerchangesafter8c2c9eb donotchangebuiltartifact. KeepPRdraft/unmerged/publicOFF.

## Custody and snapshot references

OriginalPaidnative2970 tx0addb4273ab0cfbd2e0a339ae358f41d74e7ac35b5988c21a150375216a86d8e; wrapped990 tx9J5RPEYoUSTBZhDatHEs5jaJ1LSYpqpa3bXYGRsg9ZnJcggHdV8XtfLHpRwdvTtKysLobe5cwXsp1Xc2dQD3WcN. Neverresend. Customerprivateaccess /root/ecx-funded-restore-ef2f17d/customer-access.json; after-orders.json ineachreleaseevidencedir. Identity87570fb9723c263b6832a597f7a4bcc3fe42dd8546f55266b6b1d1e9751fe368. Backuphosti-000a82a5bf73e153c; activeprivateproductionrepositoryretained. EarlierbackupHTTPcredentialrotated:old401/new200, originalsnapshotreadPASS. NeverprintresticURLorparsedcomponent; neverrestoreoldcredentials.

PinnedchainonlysnapshotSHA87e21e2cb2054fa079f1873e42dee555de2f1631eadf4e09e7dab376ea172428,11,094,047,271bytes,checkpoint967680=00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042. Publicexactobjectdedicatedbucketecx-betanet-snapshots-242254325782-us-east-2; custody/buildbucketsprivate. Fullanonymousdownload37fd5274PASS. Defaultbootstrap/repeat57cb5a3bPASS; isolatedtestnodestopped/disabled1a88bd4f. Existingnodeuntouched; fullsyncoverrideECX_NODE_SYNC=full. Rebootduringpromotionmayrequiremanualreview; unexpecteddatafailclosed. SourceMacnodestopped; do notstartunneedednodes.
