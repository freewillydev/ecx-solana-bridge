# ECX Solana Bridge

Exchange ECX betanet coins and wrapped ECX on Solana Mainnet, **1:1 before a 1% fee
in each direction**. Customers use payment instructions; no wallet connection.

**Ubuntu 24.04 x86_64 · 4 GB RAM · 80 GB disk · sudo · internet access**

The installer sets up the bridge, dedicated signer, PostgreSQL and pruned ECX node.
No Haskell build or Nginx installation is needed.

**Review candidate, not production assurance.** See the
[release](https://github.com/freewillydev/ecx-solana-bridge/releases/tag/review-2026-10-09-boot-policy)
for verification information. Download and run:

```sh
curl --fail --location --proto '=https' --tlsv1.2 \
  -o ecx-bridge-ubuntu-24.04-x86_64.run \
  https://github.com/freewillydev/ecx-solana-bridge/releases/download/review-2026-10-09-boot-policy/ecx-bridge-ubuntu-24.04-x86_64.run
sudo sh ./ecx-bridge-ubuntu-24.04-x86_64.run
```

Have two independent Solana Mainnet HTTPS RPC URLs and a **new HTTPS restic backup
repository with access credentials**. For public HTTPS, also have a domain and
certificate/key files; otherwise choose local testing.

Answer the prompts, save both recovery phrases and the backup encryption password,
then follow the funding and allocation instructions for ECX, wrapped ECX and SOL.
Node synchronization takes time. Orders stay paused until readiness checks pass.
Keep independent ledger backups: wallet keys alone do not recover pending transfers.

After interruption or funding, resume from any directory:

```sh
sudo ecx-bridge
```

[Setup and recovery](2-Wrap-Unwrap-Server/docs/INSTALL.md) ·
[Upgrade and operation](2-Wrap-Unwrap-Server/docs/OPERATIONS.md) ·
[Token tools](1-Make-Wrapped-ECX/README.md) · [Liquidity tools](3-Create-CPMM-Pool/README.md) ·
[Architecture](2-Wrap-Unwrap-Server/docs/ARCHITECTURE.md) ·
[Source builds](2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md) ·
[Release evidence](2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md) · [License](LICENSE)
