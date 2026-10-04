# Operating the bridge

All commands below run from the repository root using the sole server executable:

```sh
bridge() { cabal run -v0 exe:ecx-bridge -- "$@"; }
```

`CONFIG`, `SIGNER_CONFIG`, `KEYFILE`, `BACKUP_CONFIG` and staging paths refer to
reviewed private files/directories. Read [INSTALL.md](INSTALL.md) first. There is
no current automated installer or wipe/reinstall command.

## Credentials and startup

The worker needs local `PGHOST`, `PGPORT`, `PGDATABASE`, writer `PGUSER`, and a
distinct SELECT-only `PGREADUSER`. `PGPASSWORD`/`PGREADPASSWORD` are optional where
peer authentication is unavailable. The signer uses its SELECT-only `PGUSER` and
signer-only native credential/key. Reader roles need SELECT on tables/sequences,
without writes or sequence USAGE/UPDATE. Review node and filesystem permissions;
two processes running as one user do not establish credential isolation.

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
two retries for 429 replies and closed connections without a complete response;
all HTTPS attempts consume the budget. Timeouts, other transport failures, unknown
methods, signing mutations and sends are not automatically retried.
Pacing does not remove background observation or replace public-facing DDoS controls.

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

1. Pause and quiesce the old worker. Record its identity and independently retained
   sequence. Export and verify the final snapshot; preserve all originals.
2. Retire the old local fence and revoke old credentials/access. The fence marker
   cannot invalidate copied signing keys on another host. A lost host requires an
   explicit containment strategy and review of possibly newer chain effects.
3. Install reviewed current code/toolchains on the destination. Recover to new
   staging; check manifest, hashes, exact identities, sequence and supported schema.
4. Restore the ledger and native wallet without overwriting existing destinations.
   Configure restored Solana/unlock material with separate signer permissions and
   fresh transport/RPC credentials. Retain financial identity while changing only
   reviewed operational paths. Apply only missing forward migrations offline.
5. Point the destination at the verified staged database, adopt the minimum sequence
   without lowering the fence and start in observation mode. Reconcile both real
   chains, full custody and all saved in-flight attempts. Resolve discrepancies.
6. Start the dedicated signer and paying mode only after old-host exclusion and
   readiness are established; explicitly resume. Retain the recovery record.

No command overwrites a wallet, automatically activates restored custody or erases
unknown outcomes. Seeds alone cannot recover order history or authorization. Never
restore an older ledger over newer activity or initialize a fresh ledger with old
custody keys. Clean-host/off-host funded restoration remains a release gate.
