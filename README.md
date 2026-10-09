# ECX Solana Bridge

Exchange ECX betanet coins and wrapped ECX on Solana Mainnet, **1:1 before a 1% fee
in each direction**. Customers use payment instructions; no wallet connection.

**Ubuntu 24.04 x86_64 · 4 GB RAM · 80 GB disk · sudo · internet access**

The installer sets up the bridge, dedicated signer, PostgreSQL and pruned ECX node.
No Haskell build or Nginx installation is needed.

**Review candidate, not production assurance.** See the
[release](https://github.com/freewillydev/ecx-solana-bridge/releases/tag/review-2026-10-09-security-remediation)
for verification information. Download and run:

```sh
curl --fail --location --proto '=https' --tlsv1.2 \
  -o ecx-bridge-ubuntu-24.04-x86_64.run \
  https://github.com/freewillydev/ecx-solana-bridge/releases/download/review-2026-10-09-security-remediation/ecx-bridge-ubuntu-24.04-x86_64.run
sudo sh ./ecx-bridge-ubuntu-24.04-x86_64.run
```

Have two independent Solana Mainnet HTTPS RPC URLs and a **new HTTPS restic backup
repository with access credentials**. For public HTTPS, also have a domain and
certificate/key files; otherwise choose local testing.

Choose **Set up this server**, answer the prompts and save both recovery phrases
and the backup encryption password. Use **Funding** for addresses and explicit
allocation of your verified deposits; use **Continue** for checked startup.
Node synchronization takes time. Orders stay paused until readiness checks pass.
Keep independent ledger backups: wallet keys alone do not recover pending transfers.

Open the same numbered menu from any directory, including after interruption:

```sh
sudo ecx-bridge
```

The menu offers status, saved setup, funding, pause, reviewed upgrades and backup
verification/download, staged restoration and checked activation. Status and exit
never start services. Restoration requires permanent exclusion of the old signer;
verification alone does not activate recovered custody. Advanced CLI commands remain
available.

## Upgrade the server

Download the reviewed new `.run` installer from [Releases](https://github.com/freewillydev/ecx-solana-bridge/releases)
and verify its published digest and release signature before running it:

```sh
sudo sh ./ecx-bridge-ubuntu-24.04-x86_64.run
```

Choose **Upgrade** and confirm the displayed release. The checked upgrade saves and
verifies a custody backup, stops services, installs the new version, and reconciles
saved work before resuming. It retains wallets, the ledger and settings—do not wipe
the server or run fresh setup. If interrupted, reopen `sudo ecx-bridge` and choose
**Continue** to resume the saved plan. Then use **Status** to check services and backup coverage; **Upgrade** displays
the installed release. Unsigned review candidates
are for testing; see [the detailed procedure](2-Wrap-Unwrap-Server/docs/INSTALL.md#guided-console-and-provider-preflight).

[Setup and recovery](2-Wrap-Unwrap-Server/docs/INSTALL.md) ·
[Upgrade and operation](2-Wrap-Unwrap-Server/docs/OPERATIONS.md) ·
[Token tools](1-Make-Wrapped-ECX/README.md) · [Liquidity tools](3-Create-CPMM-Pool/README.md) ·
[Architecture](2-Wrap-Unwrap-Server/docs/ARCHITECTURE.md) ·
[Source builds](2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md) ·
[Release evidence](2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md) · [License](LICENSE)
