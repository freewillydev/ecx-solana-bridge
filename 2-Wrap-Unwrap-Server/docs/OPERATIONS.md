# Operating the bridge

All commands below run from the repository root using the sole server executable:

```sh
bridge() { cabal run -v0 exe:ecx-bridge -- "$@"; }
```

For the installed package, use its matching data directory instead of Cabal:

```sh
bridge() { env ecx_bridge_datadir=/opt/ecx-bridge/current/share /opt/ecx-bridge/current/bin/ecx-bridge "$@"; }
```

Initialization and schema-21 restoration read migrations from that directory.
Installed systemd services already set it; direct maintenance commands must too.

`CONFIG`, `SIGNER_CONFIG`, `KEYFILE`, `BACKUP_CONFIG` and staging paths refer to
reviewed private files/directories. Read [INSTALL.md](INSTALL.md) first. The candidate installer supports fresh installation and code-only upgrade; it
does not provide an automatic wipe/reinstall recovery command.

## Credentials and startup

The worker needs local `PGHOST`, `PGPORT`, `PGDATABASE`, writer `PGUSER`, and a
distinct SELECT-only `PGREADUSER`. `PGPASSWORD`/`PGREADPASSWORD` are optional where
peer authentication is unavailable. The signer uses its SELECT-only `PGUSER` and
signer-only native credential/key. Reader roles need SELECT on tables/sequences,
without writes or sequence USAGE/UPDATE. Review node and filesystem permissions;
two processes running as one user do not establish credential isolation.

Use a separate administrative account; service identities must not inherit SSH
login or sudo access. Verify this after reboot, including cloud-init/Lima account
provisioning. For a VM sharing native-wallet backup staging with its host, do not
rely on virtiofs ownership alone. Protect traversal with a root-owned guest-native
parent accessible only to the signer, exclude staging from the worker's service
namespace, and test actual worker denial and signer backup success after reboot.

`CONFIG` sets `serverPort`, `fenceDirectory`, `signerPort`, `signerAuthFile` and
`solanaSdkLibrary`. Optional `ECX_INTERFACE_CONFIG` supplies support/explorer/trading
links; `ECX_ASSETS` overrides Cabal's generated browser directory. The signer token
is a protected 64-hex-character file; its certificate is `signerAuthFile.pem` and
private TLS key `signerAuthFile.key`. Worker and signer must agree on identity and
authentication. Only the signer may read custody keys/full native credentials.

```sh
bridge check-config CONFIG
bridge check-signer SIGNER_CONFIG KEYFILE
bridge observe CONFIG
# Or, instead of observe, run the paying worker:
bridge serve CONFIG
# In the separate signer process, using its own database environment:
bridge signer SIGNER_CONFIG KEYFILE
# If required custody checkpoints are configured, use this signer command instead:
bridge signer SIGNER_CONFIG KEYFILE BACKUP_CONFIG STAGING
```

`observe` accepts all three configured profiles, including canonical ECX/Solana
Mainnet, and refuses order creation, resume and outgoing payments. It still writes
verified observations and reconciliation evidence to the deployment ledger; use
its matching ledger/fence and restricted native credentials, not a copied Devnet
configuration. Canonical observation retains the pinned mint/checkpoint, independent
verifier and required-backup configuration checks. It needs no signing process.
`serve` and `signer` also accept all three profiles. `serve` starts paused;
explicit resume performs recovery/readiness checks. Canonical mode uses the same
order, refund and payout engine, with no separate signing or broadcast path.
Both server ports bind loopback. Keep the operator/fence directory mode 0700 and
short enough for the Unix-socket path limit. The operator socket is mode 0600 and
is separate from signer HTTPS.

For canonical ECX/Solana Mainnet, adapt the ECX betanet example with reviewed
deployment values. Set `profile` to `CanonicalBeta`, `mint` to
`EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq`, and `backupRequired` to `true`.
Retain the pinned ECX checkpoint at height 967680. Both Solana RPC endpoints must
use HTTPS, have different hostnames and report Mainnet genesis; configure an
independent provider, not two URLs for one service. Use the actual Mainnet custody
owner/ATA and token/SOL history origins, matching native wallet and deployment
ledger, and reviewed limits/confirmation policy. Changing profile changes the
fingerprint: an existing Devnet ledger cannot be reused as a Mainnet ledger.
Run the signer with `BACKUP_CONFIG STAGING`; required checkpoints cover orders and
outgoing work before instructions/signing/broadcast. Missing coverage remains a
refusal. Fund and allocate custody through the existing treasury workflow before
operator resume. Enabling the code path does not establish funded Mainnet acceptance;
see [release gates](RELEASE-REVIEW.md).

RPC transport defaults to **2 HTTPS request admissions per second per hostname
per process**. Set `ECX_RPC_REQUESTS_PER_SECOND` (integer 1–1000) separately on the
worker and signer before startup to change their budgets. Divide a shared provider
quota between those processes and any token/pool tools or other consumers; the
default two services can together admit about 4 requests/second to one provider.
Paths, API keys and ports on the same normalized hostname share a budget. Native
HTTP RPC is unpaced. This spaces request starts without accumulating idle burst
credit; it does not guarantee provider arrival times or cover compute-unit,
method-specific or monthly limits. Keep headroom. Allowlisted reads share at most
two retries for 429 replies, closed connections without a complete response, and
Solana history-storage error `-32019` on `getTransaction`, `getSignatureStatuses`
and `getSignaturesForAddress`;
all HTTPS attempts consume the budget. Timeouts, other transport failures, unknown
methods, signing mutations and sends are not automatically retried.
Pacing does not remove background observation or replace public-facing DDoS controls.

An HTTP or JSON-RPC 429 also closes admission to that provider hostname within
the same manager. Both token and SOL scans share this cooldown; the other provider
and native HTTP RPC remain independent. `Retry-After` seconds and HTTP dates are
honored; absent headers mean 60 seconds, and an unrecognized header closes that
manager until restart. Cooldown refusals do not sleep in the critical evaluator,
advance scan checkpoints, certify freshness, or automatically resume the ledger.
Worker and signer managers remain separate: this is reactive backoff, not a
provider-wide hourly quota allocator.

A successful idle cycle currently needs **at least 16 primary and 9 verifier
requests**, including identity checks, inclusive history anchors and independently
checked custody balances/history heads. Payments, verified incoming anchors,
pagination and retries add requests. Scans and custody must be at most 60 seconds
old, so continuous readiness needs more than the theoretical floors of **960
primary and 540 verifier requests/hour**, with headroom for cycle duration and
payments. The worker sleeps 15 seconds *after* each cycle; actual demand depends
on its duration. A 200/hour verifier allowance supports at most 22 complete idle
cycles/hour, roughly one every 162 seconds, and cannot meet this freshness policy.
Increasing the polling delay or adding cooldown does not make that plan adequate.
Do not loosen verification or extend freshness to fit an undersized quota.

Provider header units must be checked separately from RPC call counts. OnFinality
[documents two response units per Solana call](https://documentation.onfinality.io/support/solana),
so the verifier floor above is 1,080 response units/hour. A header allowance of
200/hour is not evidence of 200 Solana calls/hour. Inspect the existing account's
plan and key restrictions before buying capacity: advertised plan allowances can
differ from the effective limits returned by an endpoint. Sharing duplicate
identity reads alone still leaves five verifier calls per cycle (300/hour at the
60-second boundary), so it cannot resolve this particular capacity mismatch.

### Installed monitoring and RPC budget

Set the per-process RPC allowance with `sudo systemctl edit ecx-bridge-worker`
and the corresponding signer unit, using:

```ini
[Service]
Environment=ECX_RPC_REQUESTS_PER_SECOND=2
```

Budget both processes and other clients together. After an orderly pause, apply
the drop-ins with daemon-reload and a controlled service restart; startup remains
paused until checked resume. A rate setting does not increase a provider's hourly
quota. Keep authenticated endpoint URLs out of monitoring output and access logs.

On the installed host, these read-only checks use existing service/DSL interfaces:

```sh
systemctl is-active ecx-bridge-worker ecx-bridge-signer
printf '%s\n' '{"operation":"status"}' | sudo -u ecxbridgew /opt/ecx-bridge/current/bin/ecx-bridge operator /etc/ecx-bridge/worker/config.json
curl --fail --silent --show-error --max-time 10 https://YOUR_DOMAIN/api/v1/config
```

Use the configured public domain/port and normal certificate verification. For
loopback-only development without TLS, use http://127.0.0.1:8080 instead. Monitor
the public HTTPS URL from outside the host
as well. HTTP 200 alone is not readiness: inspect the configuration's
`availability.available` and `availability.reason`. The private status reports `paused`,
`pauseReason`, `criticalSequence` and `backupSequence`. Alert on unexpected pause,
service failure, sustained unavailable intake, persistent backup lag, disk pressure,
certificate expiry and failures reported by the independent backup destination.
Brief sequence lag during a checkpoint is expected; do not automatically resume or
lower backup requirements to clear an alert. Route alerts to the chosen operator
without publishing order capabilities, keys or RPC URLs. Alert delivery, thresholds
and the public domain remain deployment-specific acceptance work.

### Rotate signer transport credentials

Pause the worker and stop both services, preserving the ledger and every saved
attempt. Generate a fresh random 64-hex token and a TLS key/certificate valid for
127.0.0.1. Replace the signer's token, `.pem` and `.key`, and the worker's matching
token and `.pem`, under their existing protected paths/ownership. The TLS private
key stays signer-only. Restart the signer to reload its authentication and TLS
state; changing files alone does not revoke an already running server's token.
Verify old certificate trust fails, the old token is rejected, and the worker's
new credentials reach the evaluator. Then restart the worker paused and use normal
checked resume. Transport rotation does not change custody keys, ledger identity
or saved transactions and does not replace custody recovery or key-compromise handling.

For an encrypted native descriptor wallet, set the signer's optional
`nativeUnlockFile` to a mode-0600 regular file with the exact 1–1024-byte UTF-8
passphrase, without NUL or line endings. The signer unlocks for at most 120 seconds
and relocks after signing, including failures. Keep passphrase/encryption changes
quiescent during signing or custody export. Worker RPC must deny unlock and lock.
Do not put passphrases, key bytes or authentication tokens in command arguments.

## Operator commands

Send one JSON object on stdin. For example:

```sh
printf '%s\n' '{"operation":"status"}' | bridge operator CONFIG
printf '%s\n' '{"operation":"pause","reason":"operator review"}' | bridge operator CONFIG
printf '%s\n' '{"operation":"resume"}' | bridge operator CONFIG
```

Successful commands emit JSON on stdout and exit zero. A rejected command emits
its JSON error on stderr and exits nonzero; scripts must stop on that failure.
An unknown outcome is not permission to retry a transfer or change its parameters.

The table lists fields **in addition to** `operation`. Required fields and their
types are enforced by `workflow/Bridge/Control.hs`; unknown fields are rejected.
Amounts are canonical base-unit strings, while recovery/decision/generation values
are JSON integers. Returned IDs/sequences must be retained exactly.

| operation | Fields |
| --- | --- |
| `status`, `native-reviews`, `resume` | None |
| `pause` | `reason` |
| `repair-completed-order` | `order` |
| `allocate-treasury` | `deposit`, `split`, `reason` |
| `classify-spend` | `chain`, `transaction`, `reason` |
| `withdraw-fees` | `id`, `asset`, `amount`, `recipient`, `reason` |
| `cancel-fees` | `id`, `reason` |
| `refund` | `deposit` |
| `cancel-preparation` | `payment`, `generation`, `reason` |
| `retry-solana` | `transaction`, `reason` |
| `cover-source-loss` | `deposit`, `recovery`, `float`, `earned`, `reason` |
| `approve-covered-source` | `payment`, `recovery`, `reason` |
| `approve-source-recovery` | `payment`, `restoration`, `reason` |
| `draft-replacement` | `parent`, `fee`, `reason` |
| `sign-replacement` | `decision` |
| `cancel-replacement` | `decision`, `reason` |
| `rebroadcast-native` | `transaction`, `recovery`, `reason` |

Funding must be operator-owned native inventory, configured wrapped inventory and
SOL operating capital. Let observers verify/finalize receipts, pause, then allocate
each eligible unbound receipt completely. `split` is an array of account/amount
pairs, for example `[["float","90000"],["operating","10000"]]` for a matching
100000-unit native receipt. SOL may only fund operating. The recorded attestation
and reconciliation are required; balance alone is not allocation authority.

Start new custody with a dedicated wallet. Pay its associated-token-account setup
from a separate funding wallet, and acquire trading inventory outside custody before
transferring it in. Retain complete token and SOL history, including account creation
and funding. Spending from an unallocated custody wallet can prevent its opening
reconciliation: allocation requires reconciliation, while classifying a spend requires
allocated capital. Do not work around this by skipping history or inventing an opening
balance. Existing custody with financial history requires migration or recovery.

Earned withdrawal uses a fresh 64-lowercase-hex `id`, asset `Native` or `Wrapped`,
amount and external recipient. Its reservations, preparation, signing and settlement
use the same engine as customer payments. An exact decision replay is idempotent;
changing its amount/recipient under the same ID is rejected. Do not manually spend
custody funds to bypass holds or protected backing/LP allocations.

Timeouts can mean an operation's outcome is unknown. Inspect durable status and
saved decisions before retrying; never invent another order, signature or generation
to resolve uncertainty. Paused recovery may record chain effects but does not grant
new send authority. Resume checks scans, custody, backup, source/review state and
node restrictions. Source return or an RPC acknowledgement alone does not resume.

Cancellation applies only to unsigned eligible work and retains its liabilities.
Solana retry needs complete expiry/nonexecution evidence and separate approval.
Native replacement/rebroadcast preserves the original economic payment and exact
saved decision. `repair-completed-order` repairs only the proven historical view
of a completed conversion overwritten by a later refund; it is not an arbitrary
status or payout editor.

## Backups

`BACKUP_CONFIG` has exactly `restic`, `repositoryFile` and `passwordFile` absolute
paths. Protect the files; retain repository/password access outside the server.
Production accepts `rest:https://...` away from loopback. Initialize the actual
repository separately and give the worker/signer only the required upload access;
operator deletion/retention authority must be separate. A local encrypted restic
repository is a test seam, not proof of off-host durability.

When `backupRequired=true`, the signer checkpoint must export, upload and verify
the complete custody bundle before acknowledging the exact sequence. Missing
configuration fails closed. Test deployments may explicitly set it false; those
runs do not prove the backup barrier's deployment.

For offline maintenance, stop the worker and use appropriate writer/reader database
credentials plus native/key access. Destinations must be new private locations:

| Command after `bridge` | Purpose |
| --- | --- |
| `backup-native-wallet CONFIG DESTINATION` | Archive the native wallet and its manifest |
| `restore-native-wallet CONFIG MANIFEST` | Restore into an unused configured wallet name |
| `backup-custody CONFIG KEYFILE DIRECTORY` | Export ledger, native wallet, Solana key and configuration |
| `check-custody CONFIG MANIFEST MINIMUM_SEQUENCE` | Inspect bundle identity and integrity offline |
| `upload-custody CONFIG BACKUP_CONFIG MANIFEST MINIMUM_SEQUENCE` | Upload, retrieve and verify the complete encrypted bundle |
| `recover-custody CONFIG BACKUP_CONFIG SNAPSHOT DIRECTORY MINIMUM_SEQUENCE` | Retrieve a verified bundle into new private staging |
| `restore-ledger CONFIG MANIFEST MINIMUM_SEQUENCE` | Restore a ledger archive into a new restricted paused database |
| `recover-ledger CONFIG BACKUP_CONFIG SNAPSHOT STAGING MINIMUM_SEQUENCE` | Retrieve a ledger-only archive and restore it into staging |
| `adopt-ledger CONFIG MINIMUM_SEQUENCE` | Initialize/advance a matching nondecreasing host fence |
| `retire-ledger CONFIG MINIMUM_SEQUENCE` | Permanently retire the matching local fence |
| `checkpoint CONFIG` | With the worker stopped and signer running, save and verify a fresh custody checkpoint under exclusive worker ownership; emit its receipt and exit |

`checkpoint` uses the worker's existing `PG*` settings, distinct `PGREADUSER`,
host fence and signer credentials. It does not listen for requests, run observers,
resume intake or submit payments. It is an upgrade building block, not yet the
complete guided stop/upgrade/resume workflow. Preserve the returned receipt before
stopping the signer; do not relaunch the worker between checkpoint and upgrade.

Use a separately retained minimum critical sequence and exact 64-character snapshot
ID, never `latest` or guessed zero. Ledger commands consume ledger manifests/snapshots;
for a full custody snapshot, first recover/check the bundle, then use its contained
ledger manifest with `restore-ledger`. Database restoration needs separate authority
to create databases. It returns a staging database name; it does not switch the
running application's `PGDATABASE` or resume service.

Completion manifests bind the exact files and are written last. Bundles preserve
financial history and keys, not old RPC cookies/TLS credentials. Encrypted native
wallet exports require `nativeUnlockFile` even if the wallet is already unlocked;
format 2 binds a copied `native-unlock` file. Export checks the secret against the
wallet before and after backup. After relocation, point the restored signer's
`nativeUnlockFile` to that protected copied file. Unencrypted bundles retain format 1.
Offline inspection never unlocks a wallet.

## Restore or upgrade

1. Pause and quiesce the old worker and signer. Record their identity and independently retained
   sequence. Export and verify the final snapshot; preserve all originals.
2. Retire the old local fence and revoke old credentials/access. The fence marker
   cannot invalidate copied signing keys on another host. A lost host requires an
   explicit containment strategy and review of possibly newer chain effects.
3. Install reviewed current code/toolchains on the destination. Recover to new
   staging; check manifest, hashes, exact identities, sequence and supported schema.
4. Restore the ledger and native wallet without overwriting existing destinations.
   Configure restored Solana/unlock material with separate signer permissions and
   fresh transport/RPC credentials. Retain financial identity while changing only
   reviewed operational paths. Current ledger restoration automatically converts
   schema 21 to 22 in the new private database and invalidates custody readiness.
   Older baselines first require their missing reviewed 001–008 migrations on an
   offline copy. Never run the 009 staging/activation files directly.
5. Point the destination at the verified staged database, adopt the minimum sequence
   without lowering the fence and start in observation mode. Reconcile both real
   chains, full custody and all saved in-flight attempts. Resolve discrepancies.
6. Before activating the recovered runtime, arrange native wallet loading on node
   restart. `restore-native-wallet` deliberately restores with automatic loading
   disabled. With both bridge processes stopped and the destination fence adopted,
   add `wallet=THE_VERIFIED_NATIVE_WALLET_NAME` to the ECX node configuration in the
   appropriate network scope, preserving its RPC restrictions. Restart the node
   and verify that the configured wallet is loaded. Do not enable automatic loading
   on a temporary recovery-inspection host. Fresh generated wallets already request
   persistent loading when created.
7. Start the dedicated signer and paying mode only after old-host exclusion and
   readiness are established; explicitly resume. Retain the recovery record.

No command overwrites a wallet, automatically activates restored custody or erases
unknown outcomes. Seeds alone cannot recover order history or authorization. Never
restore an older ledger over newer activity or initialize a fresh ledger with old
custody keys. Clean-host/off-host funded restoration remains a release gate.


### Guided same-schema upgrades (implementation under acceptance)

Run the newly reviewed Ubuntu installer with `sudo`, then use the same
`sudo ecx-bridge` entry command on every retry. The candidate must be a verified,
root-owned bundle. Existing setup, keys, addresses and database are retained.
A new candidate now enters a root-only upgrade journal; normal start cannot skip
an unfinished upgrade. It stops the worker, obtains a fresh verified checkpoint
through the critical evaluator, records the receipt and fence, stops the signer,
and switches the immutable release before performing the normal checked resume.
Persistent systemd conditions prevent worker restart during the frozen interval.

A failed step leaves its journal at `/var/lib/ecx-bridge-upgrade` and preserves the
original release and state. Rerun the same entry command after resolving the stated
prerequisite. Do not delete the journal or unblock services manually. A failure
after resume can safely stop/restart and reconcile the advanced ledger; it never
restores the pre-upgrade database. The fixed `check-fence CONFIG` command reads a
stopped worker's validated, nonretired fence under its lock without modifying it.

This path currently accepts identical migration inventories only. A schema change
still requires the reviewed offline conversion/recovery procedure; automatic
schema-21 to schema-22 integration and full interrupted-upgrade acceptance remain
release gates. Earlier installer evidence does not prove this new workflow.


### Managed native backup handoff

The installer configures a socket-activated, export-only native backup helper.
`ecxnode` retains ownership of native files; `ecxbridges` alone may request the fixed
wallet export through `/run/ecx-native-backup/export.sock`. No ordinary operator
needs to run its internal `native-backup-service` command. The signer checkpoint
uses it when `ECX_NATIVE_BACKUP_SERVICE=1`; signer HTTPS and database roles remain
unchanged. The export has a 240-second deadline and a 256 MiB streamed-transfer cap.

`native_backup_spool_requires_cleanup` means retained interrupted exports need
maintenance. Do not delete them while the native daemon may still be copying.
Stop the backup socket, all helper instances and the native node; verify they have
no remaining processes before inspecting/removing abandoned `export-<64 hex>`
directories in `/var/lib/ecx-betanet/bridge-backup`. Preserve `export.lock` and all
unrelated files. Resume the node and socket afterward. Automated recovery of this
hard-kill case and the reverse restore handoff remain acceptance/integration work.


## Password-protected funding view

`/info` exposes only the existing safe public reserve/readiness report. Optional
`/funding` is a read-only page protected by HTTP Basic authentication (username
`operator`). Serve it over HTTPS, directly or through an encrypted tunnel to the
loopback listener. It cannot allocate treasury, sign or send transactions.

Set `ECX_FUNDING_CONFIG` to an absolute private mode-0600 JSON file owned by
`ecxbridgew`, in a directory that user can traverse and other users cannot modify, with `salt`
(32 random bytes as hex), `hash` (32-byte PBKDF2-HMAC-SHA256 result, 600,000 rounds,
hex), `nativeAddress`, `owner`, `mint` and `ata`. Store no plaintext password.
Verify the native address belongs to the configured wallet before provisioning;
the page additionally refuses mismatched Solana owner/mint. Restart the worker
after provisioning or replacing this file. Missing configuration shows an explicit optional-page-not-configured message
(HTTP 503), without reading any custody data. Attempts share a two-second admission interval; responses are never cached.
Funding still requires confirmed observations, reconciliation and explicit
allocation through the existing operator workflow. Reserve timestamps may be stale.

### October 9 review deployment

`bridge.bitnames.info` serves the candidate `07bf9bb` with Bridge, Info and
password-protected Funding navigation. The worker runs `observe`: customer intake
is disabled and the signer is stopped. Stale reserve observations remain visibly
marked; this deployment does not establish transfer readiness. The published
`review-2026-10-09-site` installer matches `07bf9bb`; the earlier Ubuntu
review release remains available as a separate immutable artifact.

The AWS signer selects the Mac HTTPS restic repository through the standard
`/etc/ecx-bridge/signer/backup.json` paths, also referenced by saved setup. Original backup
configuration and snapshots remain intact. A fresh sequence-76 checkpoint passed
full restic data verification and isolated custody recovery, with matching manifest;
no recovered wallet or ledger was activated. Checkpoint SSM evidence:
`c005fd99-f91c-454f-8905-ead2d7b16fb5`; recovery:
`f5376d64-d173-4367-8cd6-be5ce6faaec6`.

The Mac must remain awake, online and logged in with its external drive attached.
The repository has a 2 GiB initial cap. Saved setup and installed backup credentials were reconciled and the temporary
backup override removed; upgrade retains the installed credentials. A wiped host
still requires explicit custody/ledger recovery, never a fresh install over old funds. This is a review deployment, not an unattended production
backup service or independent security approval.


### Independent RPC remediation and release handoff (October 9)

The observation-only AWS worker is active; its signer is stopped. Successful
individual history reads do not establish sustainable capacity. The observed
OnFinality endpoint advertises limits of 200/hour and 4,000/day; these header
counter units have not been established. The current idle verifier floor is nine
calls per cycle, or at least 540 calls/hour to maintain the 60-second freshness
window. Transfers and recovery require additional capacity. Do not weaken
freshness or provider independence to fit the observed limit.

The existing key works through both documented authentication formats. The AWS
worker has no proxy environment variables; a TLS handshake verifies the configured
provider hostname against a public certificate. The account dashboard also records
failed transaction reads. This establishes provider-facing throttling, not its
internal entitlement cause. The 400,000-unit workspace allowance may coexist with
endpoint limits. The Development label has no documented quota entitlement effect.
The last bounded history read at 13:10:13 UTC returned 200, remaining-hour 2, and no
Retry-After/reset headers. Do not infer an hourly reset time or force exhaustion.
The application's stable error codes intentionally omit remote bodies; existing
worker logs cannot recover an earlier raw 429 response.

Before resuming:

1. Obtain documented capacity for an independent provider covering finalized
   transaction history, account reads and signature pagination, with headroom above
   the application's measured total budget. Confirm any hourly/day restrictions.
2. Validate the existing history anchors and sustained scanner freshness through
   normal observation; retain redacted rejection diagnostics if one occurs.
3. Checkpoint and align worker and signer to the same reviewed installer. Retain
   funding configuration and backup credentials; enforce one active custody owner.
4. Reconcile reserves and backup coverage before the existing minimal funded
   acceptance. Record both directions, exact transaction IDs and 1% fees.

Provider support draft — prepared only, not sent:

> Our authenticated Solana archive endpoint returns intermittent HTTP 429 for
> ordinary finalized reads. At 2026-10-09 13:10:13 UTC, a successful getTransaction
> returned X-Ratelimit-Limit-Hour: 200, Limit-Day: 4000, Limit-Minute: 40 and
> Limit-Sec: 25, with Remaining-Hour: 2. The Developer workspace shows a 400,000
> response-unit daily allowance. Query and header API-key authentication behave
> alike. Please identify the units, scope and reset policy of these counters;
> explain which Solana entitlement enforces them; and identify a supported plan
> or configuration sustaining at least 540 read calls/hour plus transfer headroom.
> Are these endpoint, account, IP or upstream limits? No credentials are included.

The published review installer has a SHA-256 checksum, not a production release
signature or GitHub artifact attestation. The repository's `scripts/release-auth`
can sign an immutable artifact index and verify it against a separately trusted
Ed25519 public key. Existing development/acceptance keys do not authorize a public
production release. The operator must designate the release-key owner and trusted
public-key distribution channel; do not generate a new authority implicitly or
trust a key supplied only alongside the candidate it authenticates.
