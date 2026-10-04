# Installation prerequisites

The current server is built through Cabal. **An automated installer is not yet
available.** The removed installer and Linux release workflow targeted the retired
server, configuration and backup protocol. Do not use an old release to deploy the
current source. Fresh/repeat installation, upgrade, reboot and clean restoration
on Ubuntu 24.04 ARM64/x86-64 remain acceptance gates.

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
signer TLS/authentication files, service supervision or reverse-proxy HTTPS. The
old systemd/provisioning templates were removed with the incompatible installer.
These responsibilities remain required for a deployed server.

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
  Use HTTPS for customer exposure through a reviewed local reverse proxy; the
  application and signer bind loopback. No public operator route exists.
- Provision off-host HTTPS restic storage and retain recovery credentials separately
  before enabling required backup. Automatic repository provisioning is unfinished.

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
