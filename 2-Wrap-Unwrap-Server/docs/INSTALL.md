# Installation prerequisites

The current server is built through Cabal. The candidate installer under `install/`
targets the rebuilt server; it is **not yet a certified release**. Do not use an old
release built for the retired server. The hardened ARM64 signed package passed clean
fresh installation, repeat/upgrade, cold boot and service isolation checks.
The reviewed x86-64 package now passes those checks too. Unfunded native-node and
HTTPS-backup integration under installer accounts also passed, including encrypted
wallet restoration. Funded clean-host restoration and independent storage remain open.

## Interactive setup

From a built checkout, run `cabal run exe:ecx-bridge -- configure`. With the
executable on PATH, fresh Ubuntu setup is:

```sh
sudo ecx-bridge configure
sudo ecx-bridge start
```

The wizard asks for a new private directory (default `./.ecx-bridge`), real network,
RPCs, custody identity, chain-history origins, limits, existing private key/credential
files, backup files, interface links and optional public TLS files. Blank input
accepts displayed defaults; `-` means none for optional inputs. Invalid answers
are retried; cross-field validation reopens the settings. It makes no network calls.
Source secret files must belong to the invoking user with private permissions;
when configuring as root, prepare root-owned copies. Existing output directories
are refused, and cancelled/failed collection removes only its newly created output.

If database/services are missing, it asks whether to provision them. Choosing yes
also collects the repository `scripts/release-auth` path, independently trusted
release public key and signed candidate directory. `start` invokes that authenticated
installer for new custody, which provisions PostgreSQL, roles, migrations and the
paused ledger. Choosing no leaves provisioning to the operator; it never substitutes
an empty ledger for missing existing services. An arbitrary existing PostgreSQL
installation alone is not an initialized bridge deployment.

`start [DIRECTORY]` checks that installed configuration matches the saved material,
starts the two systemd services, waits for the local operator interface and requests
checked resume. Failed readiness leaves intake paused with an error; fix prerequisites
and rerun `start`. It never rewrites an existing deployment's financial configuration.
A current package containing the optional interface/TLS installer support is required;
the previously frozen packages do not include these changes. This flow still requires
an actual synchronized native node, restricted RPC credentials, initialized remote
backup and funding/allocation. DNS and certificate renewal remain external setup.

The output directory contains copies of custody credentials and must remain private
(0700 directory, 0600 files). The installed signer key and RPC/unlock credentials
live under `/etc/ecx-bridge/signer/`; its token is shared with the worker via a
protected copy. Public TLS has a separate worker-only private key. The wizard does
not delete the sensitive source or setup copies after installation.

## Candidate installation and upgrade

Build from a clean reviewed Git checkout on Ubuntu 24.04, as an unprivileged user:

```sh
2-Wrap-Unwrap-Server/install/package /absolute/new-candidate /absolute/restic-0.19.1
```

This invokes the existing Cabal build, packages its executable, SDK, GHC-JavaScript
assets, all migrations, retained notices and the supplied restic 0.19.1 client.
It accepts only the reviewed restic hash for that architecture, checked before
compilation. The earlier upstream Go 1.26.4 binary has open advisory findings and
is refused. It creates a self-contained `.run` artifact and checksum. Artifact authentication
uses the retained Ed25519 `scripts/release-auth` protocol; the trust key must arrive
through a separate reviewed channel. The format-2 index authenticates only the architectures actually built and reviewed;
requesting an absent architecture is refused. Old format-1 indices are rejected.
Signing an ARM64 candidate does not establish x86-64 acceptance. Final restic/platform notice coverage remains a
distribution gate. The actual ARM64 builder and authenticated fresh-install path have been exercised;
the executable matched the frozen Mainnet-tested binary exactly.

Prepare `/root/ecx-material` as root-owned mode 0700, with regular mode-0600 files:

- `worker.json`, `signer.json`: complete reviewed configurations using the existing
  examples. Policies must agree except credential/unlock paths. Installed local
  credential, SDK and fence paths are substituted; financial identity is retained.
- `solana.keypair.json`: the dedicated new custody key matching the configurations.
- `native-worker.auth`, `native-signer.auth`: distinct native RPC credentials;
  enforce the worker method restrictions on the actual native daemon first.
- When backups are required: `backup.repository`, `backup.password`, pointing at an
  initialized off-host HTTPS restic repository with the required access separation.
- For an encrypted native wallet: `native-unlock`, containing the exact passphrase
  without a newline. Omit it only for an unencrypted wallet.

For **genuinely new, unfunded custody only**, the authenticated one-command path is:

```sh
sudo 2-Wrap-Unwrap-Server/scripts/release-auth install /trusted/release-public.pem /reviewed/candidate aarch64 -- fresh /root/ecx-material
```

Use `x86_64` on that architecture. Installation provisions PostgreSQL 16, separate
non-login worker/signer users with explicit SSH denial, restricted database roles,
signer TLS/authentication,
all eight schema migrations, a fresh paused ledger/fence and systemd units. It leaves
services stopped, enabled for boot; every worker startup requires checked resume.
It does not create chain assets, provision the native daemon, initialize remote
storage or provision public certificates. These are real deployment prerequisites, not
simulated networks. In particular, the native daemon must be able to produce wallet
backups in the signer's private staging path with the ownership required by the
backup validator; verify this integration before enabling required checkpoints.
A domain, public certificate and reviewed interface links remain operator configuration.

For a completed installation, replace the final arguments with `-- upgrade`.
Upgrade stops both services, switches the verified release atomically and preserves
keys, configuration, database and fence. It refuses changed migration bytes: schema
upgrades require the explicit offline procedure below. Repeating `fresh` refuses
existing state; repeating `upgrade` preserves it. Interrupted installation leaves
its state for inspection, never automatically erases or recreates custody. This is
not a wipe/restore command. Existing funded custody must follow [recovery](OPERATIONS.md#restore-or-upgrade).

The installer body and actual signed ARM64 package have been exercised with newly
generated unfunded custody, including a clean Ubuntu VM and cold boot. A reproduced
SSH-forwarding gap led to explicit `DenyUsers` policy for both service accounts;
`nologin` alone was insufficient. These checks do not establish funded restoration,
backup delivery or independent-host disaster recovery; see [release evidence](RELEASE-REVIEW.md).

## Public HTTPS in the Haskell server

The repository's `ecx-bridge` serves HTTPS directly using WarpTLS and the existing
Servant application. No Nginx or separate proxy application is required. With
neither TLS environment variable set it remains HTTP on 127.0.0.1 for local use.
Setting both enables IPv4 public HTTPS on `serverPort`; setting only one refuses
startup, without downgrading to HTTP. The separate signer keeps its own loopback
HTTPS listener and credentials.

Obtain a valid certificate/full chain for your domain and a **separate public TLS
private key**. Do not reuse the custody key or signer's TLS key. Store both under
a root-owned directory without group/other write permission. The TLS private key
must be a regular, non-symlink file owned by the worker (mode 0600); the certificate
must be owned by root or the worker and not group/other writable. Make the paths
readable within the worker's systemd sandbox. Configure `serverPort` in the worker
configuration and add a worker service drop-in using `sudo systemctl edit
ecx-bridge-worker`:

```ini
[Service]
Environment=ECX_PUBLIC_TLS_CERT=/etc/ecx-bridge/public-tls/fullchain.pem
Environment=ECX_PUBLIC_TLS_KEY=/etc/ecx-bridge/public-tls/privkey.pem
```

For port 443, also grant only the worker `AmbientCapabilities=CAP_NET_BIND_SERVICE`
and `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` in that drop-in. Alternatively use
an unprivileged HTTPS port. Pause before restarting; run daemon-reload, restart the
worker and check HTTPS and the existing checked-resume prerequisites. Provision
certificate renewal; new certificate bytes require a controlled worker restart.
The installer does not acquire certificates or configure your domain automatically.

Public TLS mode adds constant-space global admission budgets: approximately
30 requests/second (burst 60) and 30 order creations/minute (burst 2), including
trailing-slash order routes. Excess requests receive JSON HTTP 429 and Retry-After.
The existing 4-KiB body and 32-request application concurrency limits still apply.
There is no forwarding hop, proxy retry, cache or trusted forwarded-IP header.
These global budgets are not per-user fairness, TLS-handshake limits or protection
against network saturation; hosting/network protection remains external.

## Restic security candidate

The restic source is an external deployment dependency, not application code.
Fetch `github.com/restic/restic@v0.19.1` using `go mod download -json` and verify its
`Sum` against `build/toolchains.json`. Apply `install/restic-security.patch` to a
separate writable copy of that verified source. From that copy, the reviewed ARM64
candidate was built with:

```sh
GOTOOLCHAIN=go1.26.8 GOMAXPROCS=1 CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -p=1 -mod=readonly -trimpath -tags=disable_grpc_modules -ldflags='-s -w' -o restic-patched ./cmd/restic
```

For x86-64 use `GOARCH=amd64`. Check the output against the matching pinned
`restic-reviewed.aarch64` or `restic-reviewed.x86_64` SHA-256. Self-update
is deliberately not compiled into this managed deployment tool. The module patch
and checksums preserve the exact dependency choices; do not substitute an arbitrary
binary that prints the same version. This candidate passed local repository compatibility and the frozen bridge
custody upload/download/readback path. Its notices are collected; distribution review and final artifact acceptance remain.
The earlier signed installer remains historical acceptance evidence, not a public
release candidate with these security changes. See [dependency review](DEPENDENCY-REVIEW.md).

## Build

From the repository root, follow [LOCAL-DEVELOPMENT.md](LOCAL-DEVELOPMENT.md):

```sh
cabal build all -j1
cabal test all -j1 --test-show-details=direct
cabal list-bin ecx-bridge:exe:ecx-bridge
```

Cabal hooks build the native SDK library and GHC-JavaScript browser. A deployed
bundle must carry the resulting SDK/assets, configuration templates, all migrations
and applicable dependency notices. `build/toolchains.json` retains toolchain pins;
that file is not an installation command or release certificate.

## Required host configuration

Building source does not provision database roles/ACLs, native RPC restrictions,
signer TLS/authentication files, service supervision or public TLS certificates. The candidate installer supplies local service/database policy; native-node,
backup-destination and public HTTPS provisioning remain required.

- Run the HTTP/worker and signer as separate OS users. Only the signer may read the
  custody key, full native credential, TLS private key and optional wallet passphrase.
- Use PostgreSQL with a restricted writer role and SELECT-only reader/signer roles.
  Keep it local and deny ambient/public privileges. Readers need table/sequence
  SELECT; they must not have sequence USAGE/UPDATE, table writes or schema creation.
- Run the actual L2L Signet or supported ECX betanet native daemon. Restrict worker
  native RPC methods according to `chain/Bridge/Native.hs`; signing/key export,
  wallet unlock and wallet lock must be denied. Signer-only credentials must be
  protected by the filesystem as well as by RPC policy.
- Configure real Solana Devnet or canonical Mainnet identities and complete token/SOL
  history origins. `CanonicalBeta` supports orders and payouts, requires the pinned
  mint, an independent HTTPS verifier and backups; follow [operations](OPERATIONS.md).
  Funded Mainnet acceptance and the other release gates remain separate requirements.
- Protect the local operator/fence directory, signer token/certificate and key paths.
  The worker verifies the signer's TLS hostname as `127.0.0.1`; issue its certificate
  with `CN=127.0.0.1` and `subjectAltName=IP:127.0.0.1`, matching the existing transport
  fixture. Keep certificate and hostname verification enabled.
  Enable the built-in WarpTLS listener for public customer HTTPS as described above.
  The signer remains loopback-only. No public operator route exists.
- Provision off-host HTTPS restic storage and retain recovery credentials separately
  before enabling required backup. Automatic repository provisioning is unfinished.
  Use the reviewed, hash-pinned restic build described above at the absolute
  `restic` path in `BACKUP_CONFIG`. The version number alone is insufficient.
  Ubuntu 24.04's distro
  restic 0.16.4 lacks `dump --target`, which complete backup readback and recovery
  require; a successful upload alone does not complete a custody checkpoint.

Use the current examples under `config/` as templates, replacing every placeholder
with reviewed values. The native wallet must have the expected local descriptor
keys. A locked encrypted wallet additionally needs the signer's `nativeUnlockFile`;
see [OPERATIONS.md](OPERATIONS.md). Configuration contains file paths, not inline keys.

Worker and signer configurations identify the same financial deployment but use
appropriate native credentials. Review `workflow/Bridge/Config.hs` for the exact
fingerprint and accepted fields. Do not copy old `customerSocket`, `adminSocket`,
helper-subprocess or Python-uploader settings into current configuration.

## Database setup and migration

Apply reviewed `migrations/001.sql` through `008.sql` in order to a fresh private
database. Migrations 001–005 retain the baseline DDL; 006–008 advance schema 18 to
21 while preserving financial history. Existing databases require their actual
installed DDL to be checked before applying only missing migrations: version 18
alone does not prove that every baseline correction is present. Stop the paying
worker, preserve a consistent backup and verify financial records before/after.
Do not rerun non-idempotent schema files blindly.

For a genuinely new empty deployment, with local database credentials configured:

```sh
cabal run exe:ecx-bridge -- initialize-ledger /absolute/private/config.json
cabal run exe:ecx-bridge -- adopt-ledger /absolute/private/config.json 0
```

Initialization expects the schema already installed and creates only deployment,
custody and clock state. It refuses residual financial data and starts paused.
It does not create keys, fund custody, restore history or authorize payments.
Existing custody must follow recovery/migration, never this empty-ledger procedure.

[OPERATIONS.md](OPERATIONS.md) covers process startup, funding, operator commands
and restore. Deleting or reinstalling a server is not itself a recovery procedure.
