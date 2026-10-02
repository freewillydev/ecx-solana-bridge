# Ubuntu installer

This installer targets Ubuntu 24.04 on ARM64 or x86-64. It installs the bridge,
fixed Solana helper, a private PostgreSQL 16 ledger, browser assets, systemd units and an
optional dedicated **real L2L public Signet** node. No simulated chain is offered.
The revised PostgreSQL package passed ARM64 installation, repeat installation,
reboot, private-role and same-host backup restoration checks in an Ubuntu VM on
the development Mac. See [the recorded checks](evidence/postgres-installer-arm64.json).
This run used observation mode and a fresh ledger; it did not authorize payments.
The native x86-64 package also passed fresh bridge installation, repeat installation,
cold restart, configuration/financial-record preservation and isolated same-host
restoration; see [x86 evidence](evidence/postgres-installer-x86.json).
That package predates the latest mandatory backup runtime and covered-source
changes, which require consolidated package acceptance. Neither architecture's
observation-only installation proves signer or independent-host recovery.

## One command

From a reviewed source checkout, as a normal sudo-enabled Ubuntu user:

```sh
./scripts/install --with-signet
```

This fetches checksum-pinned upstream toolchains, builds against the locked
dependencies, runs the application/helper tests and installs the resulting local
release. The first build takes time. Later servers can use the compiled installer
produced in `.release-build/`, without installing compilers:

```sh
sh ecx-bridge-ubuntu-24.04-aarch64.run --with-signet --config-dir /absolute/private/setup
```

Use the matching architecture's package. Run `sha256sum -c PACKAGE.run.sha256`
against a checksum obtained from a trusted source before execution. The embedded
archive checksum also catches corruption. These locally built artifacts are not
a signed public release, and there is no published download URL. Package checksums
do not authenticate an unknown distributor.

New builds also collect notices against the actual dependency graph and include
them with recorded Bitcoin Core and SQLite notices in the package manifest.
Missing dependency notices stop packaging. License applicability and system
library review remain separate release requirements; see THIRD-PARTY.md.

Without `--config-dir`, software and the requested node are installed, but the
bridge services wait for wallet configuration. Installation cannot supply funding,
mint authority, inventory or ownership of an existing wallet.

For interactive setup in a terminal, use `--configure` instead of `--config-dir`:

```sh
./scripts/install --with-signet --configure
```

The same flag is available in newly built compiled packages. The wizard asks for
real Devnet mint/custody/account identities, history origins, integer limits,
budgets, support/public URLs and the loopback port. RPC URLs and pasted keypair
JSON are hidden; terminal echo is restored on interruption and plaintext fallback
is refused. An existing keypair file must be private. The application checks that
its secret derives the configured custody public key, without signing or sending.
The setup is staged privately and validated before managed configuration is copied.
Default operation is observation-only; selecting a signer does not enable payments.
The wizard neither creates a mint nor provides funds or liquidity.

The compiled ARM64 package passed the interactive wizard on Ubuntu 24.04 with
real Signet/Devnet identities, a custom port and support link, followed by repeat
installation and reboot with port/link settings preserved. No signer was supplied and payment intake stayed paused.
Cross-release PostgreSQL upgrades now use the explicit `--upgrade` procedure below.
Locally modified service definitions are refused until reconciled.
See [setup evidence](evidence/postgres-setup-interface.json).

## Configuration supplied once

The private setup directory contains:

- `worker.json`: start with `config/l2l-devnet.example.json`; use actual mint,
  custody owner/ATA, history origins and limits appropriate to that deployment.
- `helper.json`: `deployment_id`, `mint`, `custody_owner` matching the worker,
  and `signer_path` set to `/etc/ecx-bridge/signer.json`, or null for observation.
- `signer.json`: the existing custody keypair in official Solana JSON format,
  only when the helper is configured to sign. Never use the mint-authority key.
- `interface.json` (optional): start with `config/interface.example.json`.
  Set `supportUrl` to an HTTPS support page or a simple `mailto:` address,
  `publicOrigin` to an externally configured HTTPS origin, and
  `nativeExplorerBase` to the correct network's transaction prefix ending `/tx/`.
  This file contains public presentation settings, not signing material.

`jupiterUrl` and `orcaUrl` accept operator-verified, prefilled mainnet trading
links. Jupiter must use its official host and contain the configured token mint;
Orca must use its official host and a pool address. Devnet deployments reject
these links rather than direct test tokens to mainnet. Pool mint/reserve identity
and a usable route still need real-chain verification before enabling links.
No embedded trading SDK or wallet connection is introduced.

Use `--port PORT` with protected noninteractive configuration, or enter the port
in the wizard. It remains a loopback listener. `publicOrigin` records your domain;
it does not configure DNS, TLS or a reverse proxy. Preserve the configured port
on repeat installation; a changed existing setting requires a reviewed edit.

Required managed paths in `worker.json`:

| Field | Value |
| --- | --- |
| `dbPath` | `/var/lib/ecx-bridge/private/ledger.sqlite` |
| `customerSocket` | `/run/ecx-bridge/customer/api.sock` |
| `adminSocket` | `/run/ecx-bridge/admin/api.sock` |
| `helperPath` | `/opt/ecx-bridge/current/deploy/helper-sandbox.sh` |
| `helperConfig` | `/etc/ecx-bridge/helper.json` |

With `--with-signet`, also use `nativeRpc: http://127.0.0.1:29432` and
`nativeCookie: /run/ecx-node/rpc.cookie`. The installer creates or loads
the configured descriptor wallet in this dedicated node. It does not replace an
existing wallet. Synchronization proceeds against the real public network;
checkpoint validation remains the application's responsibility.

`dbPath` remains a legacy configuration field for compatibility; the PostgreSQL
worker does not open it. Database settings live in the private `postgres.env`,
using `/run/ecx-postgres`, port 29436 and database `ecx_bridge`. PostgreSQL listens
only on its private Unix socket. Peer mapping gives the worker a restricted
`ecx_worker` role and safe evaluation a SELECT-only `ecx_read` role. The dedicated
cluster is separate from any system PostgreSQL cluster.

Default mode starts the PostgreSQL observation-only worker and keeps intake paused. For an
already configured and funded public Signet/Devnet deployment, pass
`--test-worker` explicitly. That mode requires the custody signer and rejects
other profiles. Its normal reconciliation gates still apply. Do not install a
second active signer for an existing deployment: this installer is not a
hot-wallet migration or backup restoration procedure.

## Operation

The web service listens on loopback at `http://127.0.0.1:8080`. Use an SSH tunnel
for remote access; a public domain/TLS reverse proxy is a separate configuration.
The installer does not open firewall ports or expose native RPC.

```sh
systemctl status ecx-bridge-worker ecx-bridge-web ecx-bridge-node ecx-bridge-postgres
curl -fsS http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/readyz
sudo journalctl -u ecx-bridge-worker -u ecx-bridge-web -n 50
sudo systemctl stop ecx-bridge-web ecx-bridge-worker
sudo systemctl start ecx-bridge-worker ecx-bridge-web
```

`healthz` means the process is responding. A 503 from `readyz` is expected in
observation mode and while custody checks, funding or synchronization are pending.
Installation success does not mean the bridge is ready to accept deposits.

The web user cannot read private configuration, the ledger, signer or native RPC
cookie. The helper runs in a filesystem/network namespace exposing only its
binary, system libraries and fixed configuration/key. A narrowly scoped AppArmor
profile permits namespace creation by the worker-only bubblewrap executable;
global Ubuntu namespace restrictions are not disabled.

Repeating the same installation preserves the release, configuration and ledger
and does not restart active services. Different configuration is refused. A
different release requires `--upgrade`; configuration changes and legacy-ledger
migration remain separate actions. Full host-loss restore, release
signing/publication and independent security review are separate unfinished gates.

## Existing ledger and backups

An existing SQLite ledger is not automatically replaced. Stop its worker, take a
consistent final snapshot, preserve it privately, then supply
`--legacy-snapshot /absolute/private/final.sqlite` during reviewed installation.
The importer requires an empty PostgreSQL destination and compares every record
before committing. Repeat installation with the same import requires its recorded
source digest and comparison report. After new external effects, the old snapshot
is no longer a safe rollback state. Never run two paying workers for one custody.

The hourly `ecx-bridge-backup.timer` creates consistent custom-format PostgreSQL
dumps under `/var/lib/ecx-bridge/private/backups`, validates the archive inventory
and records a digest. These local files do not acknowledge remote durability or
replace the valuable-fund backup barrier. Keep keys and off-host journal backups
protected. A full clean-host restore rehearsal remains a release acceptance task.

## Upgrade an existing PostgreSQL release

Verify the new package checksum, then run as the same sudo-enabled user:

```sh
sh ecx-bridge-ubuntu-24.04-aarch64.run --upgrade
```

This supports the managed PostgreSQL 16 / ledger schema 18 installation. It
verifies the old release and its managed units, stops the worker, web, backup
timer and dedicated node, and creates a private ledger dump plus configuration,
key, native-wallet and unit archive under `/var/lib/ecx-bridge/upgrades/`. It
checks archive readability and digests before replacing managed deployment files,
applying supported schema corrections and switching the release. Configuration,
keys, port and observation/test mode are preserved. New configurations cannot be
combined with `--upgrade`. Local modifications to managed units require review.

On failure, services remain stopped. If activation had begun, the previous release
is selected; database changes are not automatically reversed and this is not a
complete rollback. Inspect the failure and private backup before repairing and
resuming. Never restore an old ledger over newer financial decisions. Upgrade
backups are local recovery material, not acknowledged remote durability.

ARM64 acceptance covers cross-release upgrades, repeat installation, nine
preserved configuration files, 32 unchanged durable tables, a nonempty audit
marker, two verified private backups, same-host restoration and reboot. The
fixture was observation-only without signing material or payments; valuable-fund
upgrade, key restoration, x86 and remote recovery remain separate gates. See
[upgrade evidence](evidence/postgres-upgrade-arm64.json).

## Native x86 build

The private repository has a manually dispatched `Native Linux release` workflow
on Ubuntu 24.04 x86-64. It runs the same pinned builder and tests, verifies the
installer checksum and retains only compiled installer/public manifest artifacts
for seven days. It has read-only repository permission, no deployed keys and no
chain payment configuration. Actions are pinned to commit hashes. Toolchain and
frozen dependency caches avoid repeating setup; the job does not run on each push.
This replaces slow local x86 compiler emulation. Installation/reboot acceptance
still runs in the local x86 Ubuntu VM; CI build success alone does not close it.

### Existing ECX betanet node with Solana Devnet

The PostgreSQL test worker also accepts `ECXBetanetDevnet`, using
`config/ecx-betanet-devnet.example.json`. Supply an existing synchronized actual
ECX node with the pinned height-967680 checkpoint, its protected RPC cookie,
a dedicated native wallet, and separately configured noncanonical Devnet token
custody and PostgreSQL ledger. Use the existing `--config-dir` installation path
and explicit `--test-worker` option after funding/reconciliation. Do not combine
this profile with `--with-signet`, reuse another deployment's custody balances,
or relabel a canonical mainnet token as a Devnet mint.

Read-only actual node/compiled-adapter and observation-mode authorization checks
pass. A funded betanet conversion/refund and installation acceptance still remain;
the existing complete round trips are Signet/Devnet evidence.

### Backup-required Devnet acceptance

The explicit `--backed-test-worker` mode exercises the production backup barrier
on real Signet/Devnet or betanet/Devnet. It requires `backupRequired: true` in the
worker configuration. Ordinary `--test-worker` still requires `false`; neither
mode permits canonical/mainnet activation. Prepare the same private configuration
directory used for test installation, plus:

- `backup.json`: copy `config/backup.example.json` unchanged for managed paths.
- `backup.repository`: a protected file containing the independently hosted
  restic REST repository URL, beginning `rest:https://`.
- `backup.password`: the protected restic encryption password file.

Keep credential inputs as regular files with mode `0600`. Repository credentials
belong in that private file, never the command line or a public configuration.
The installer preserves existing configuration and refuses changed values on
repeat installation. It installs the Ubuntu restic package, stores credentials
with worker-only access, and configures the explicit backed worker command:

```sh
sudo sh ecx-bridge-ubuntu-24.04-ARCH.run --config-dir /absolute/private/setup --backed-test-worker
```

Initialize the independently managed repository with restic before use; the
bridge does not implicitly initialize or replace storage. The managed command
runs as `ecx-worker` and uses `/etc/ecx-bridge/backup.repository` and
`/etc/ecx-bridge/backup.password`. Ensure its credentials and outbound access can
reach that repository. Existing deployments need a stopped-worker, reviewed
configuration/mode change; `--upgrade` deliberately preserves the existing mode.

Each required barrier makes an exact MVCC snapshot through the read-only database
role, uploads archive and manifest, reads back authenticated snapshot metadata,
and acknowledges only that snapshot's sequence through the owning Haskell ledger
capability. A failed upload emits no receipt and cannot advance coverage or expose
unbacked instructions. This acceptance mode does not by itself prove independent
host durability, signer/key restoration, old-worker fencing or canonical custody;
those remain separate release gates. The tested local encrypted round trip is
explicitly not off-host acceptance.

### Approving an operator-covered native source loss

After pausing, reconciling the current source/custody evidence and recording a
full source-loss capital allocation with `cover-source-loss`, approve each
original suspended obligation separately through the private operator socket:

```sh
sudo -u ecx-worker curl --unix-socket /run/ecx-bridge/admin/api.sock \
  -H 'Content-Type: application/json' \
  --data '{"coveredObligation":"ORIGINAL_OBLIGATION_ID","coveredLossSequence":MISSING_SOURCE_SEQUENCE,"coveredApprovalReason":"Reviewed original obligation and active capital cover"}' \
  http://localhost/approve-covered-source
```

Use the current missing-source recovery sequence, not a transaction ID or a
backup sequence. The request deliberately leaves the bridge paused and signs or
sends nothing. A current full cover, unchanged suspended work, current negative
native source evidence and reconciled custody are required. Explicit resume runs
the normal global reconciliation and reservation checks. Later signing/sending
uses the existing engine and its backup barriers; an already saved payment stays
the same payment. A returned capital cover cannot authorize a subsequent loss.

### Rebroadcasting a recoverable missing native payout

The private `GET /audit` response includes `nativeRecoveryReviews` with each
current transaction, state and exact recovery sequence. While paused, use the
private `POST /rebroadcast-native` action for an already settled native payment
whose original inputs are again unspent and whose family has no active payment:

```json
{
  "rebroadcastTransaction": "ORIGINAL_NATIVE_TRANSACTION_ID",
  "rebroadcastRecoverySequence": 123,
  "rebroadcastReason": "Reviewed missing original payment and current input evidence"
}
```

Send that JSON through the same protected operator socket as the other actions.
Replace 123 with the exact current diagnostic sequence. This action **broadcasts
the existing signed transaction** and leaves intake paused. It creates no new
signature, economic intent, principal posting, input or payout destination.
The immutable recovery journal records the decision before sending; configured
backup coverage must include that decision. Identity, finalized source,
wallet/tip, exact saved bytes, previous output amounts/scripts and absence of an
active family transaction are checked again after the backup completes.

An active/mempool payment, spent input, unrelated conflict, uncertain RPC response
or changed review cannot authorize another send. A lost send reply retains the
decision and bytes; reconcile before issuing another action. Confirmation uses
the existing finality recovery workflow, followed by separate explicit resume.
This does not repair an irrecoverable payout whose inputs have been consumed by
an unrelated confirmed transaction. It also does not prove general custody
readiness while the original settlement remains under review. Database and
authority checks pass; live missing-payment acceptance remains required.

### Host-local custody ownership and stale-ledger fencing

Paying PostgreSQL workers require `ECX_WORKER_FENCE_DIR` and a deliberately
initialized fence. The installer creates `/var/lib/ecx-bridge/fence`, owned by
the worker with mode 0700, and records the fixed path in protected `fence.env`.
It initializes the fence from the checked ledger only while the worker is stopped.
Upgrade/reinstall preserve it. The local launcher now always uses PostgreSQL and
defaults to one shared `~/.local/state/ecx-bridge/worker-fence` for the OS account.
Direct CLI users must supply the same directory used by the other workers for
those custody keys; changing directories is not a safe way to bypass ownership.

The host lock spans database clones. Its mode-0600 watermark binds the deployment
fingerprint and greatest critical sequence. Every new critical sequence reaches
an atomic, fsynced file before database commit. A stale ledger is refused before
startup mutates it or creates API sockets. An uncertain commit may leave the
watermark ahead of the database; preserve it and recover the missing decisions.
There is no automatic lowering/reset to make an old ledger runnable.

First adoption for an existing local deployment requires stopping all old
workers before this explicit command, using the normal private PG environment:

```sh
ECX_WORKER_FENCE_DIR=/absolute/protected/host-fence ecx-bridge postgres-init-worker-fence CONFIG
```

For a host handoff, stop the paying worker, then use
`postgres-retire-worker CONFIG` with that same environment. It pauses the checked
ledger and durably retires the source host's paying-worker fence. Repeating the
command preserves the retirement marker; initialization cannot reactivate it.
The retirement record is necessary handoff evidence, not a replacement for a
verified latest ledger/key backup, disabling the old host's key/RPC access and
reviewing restored custody before resume.

Keep the local fence outside ledger rollback archives, and never overwrite it
with an older backup. Do not restore a retired source-host fence verbatim as an
active destination fence. Independent-host fencing, the destination's reviewed
first adoption and actual key restoration remain part of restore acceptance.
Updated runtime fences cannot constrain old binaries or other software that
already holds a private key; the initial stop/access handoff remains required.

The old `worker`/`test-worker` names now resolve to PostgreSQL modes. Direct
SQLite financial CLI commands are disabled; recovery actions use the private
operator API. Legacy SQLite library code remains for migration/regression work.
Fresh-install treasury allocation still needs its PostgreSQL operator workflow;
the prior SQLite treasury utility must not be used on the PostgreSQL deployment.
