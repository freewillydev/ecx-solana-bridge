# Ubuntu installer

This installer targets Ubuntu 24.04 on ARM64 or x86-64. It installs the bridge,
fixed Solana helper, a private PostgreSQL 16 ledger, browser assets, systemd units and an
optional dedicated **real L2L public Signet** node. No simulated chain is offered.
The revised PostgreSQL package is being verified in local Ubuntu VMs. Earlier
installer evidence covers the SQLite baseline, not this replacement.
ARM64 acceptance is performed in a separate Ubuntu VM on the development Mac;
see the installation evidence for the checks actually completed. x86-64 requires
its own acceptance run before claiming support has been verified there.

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

## Configuration supplied once

The private setup directory contains:

- `worker.json`: start with `config/l2l-devnet.example.json`; use actual mint,
  custody owner/ATA, history origins and limits appropriate to that deployment.
- `helper.json`: `deployment_id`, `mint`, `custody_owner` matching the worker,
  and `signer_path` set to `/etc/ecx-bridge/signer.json`, or null for observation.
- `signer.json`: the existing custody keypair in official Solana JSON format,
  only when the helper is configured to sign. Never use the mint-authority key.

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
different release is also refused rather than automatically migrating a funded
ledger. Back up and review upgrades separately. Full host-loss restore, release
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
