# ECX Solana Bridge

Exchange ECX betanet coins and wrapped ECX on Solana Mainnet, **1:1 before a 1% fee
in each direction**. Customers use payment instructions; no website wallet connection.
The operator supplies both assets and pays network costs.

**Release candidate:** funded deployment and interrupted-install acceptance are
still in progress. A verified public download-and-install command is not published yet.

For a reviewed candidate already downloaded, run this from its directory:

```sh
sudo sh ./ecx-bridge-ubuntu-24.04-x86_64.run
```

Target server: **Ubuntu 24.04 x86_64, 4GB RAM, 80GB disk, sudo and internet access**.
Setup installs the pruned ECX node, PostgreSQL, bridge and dedicated signer.
Blockchain synchronization and funding take additional time.

Have two independent Solana Mainnet RPC URLs and an HTTPS restic backup destination.
For a public site, also supply its HTTPS origin and certificate/key files.
Record the generated recovery phrases, then fund the displayed ECX, wrapped-ECX
and SOL addresses. Orders must remain paused until the readiness checks pass.
Retain the ledger backups as well as the wallet recovery phrases.

[Server setup and recovery](2-Wrap-Unwrap-Server/docs/INSTALL.md) ·
[Token administration](1-Make-Wrapped-ECX/README.md) ·
[Liquidity](3-Create-CPMM-Pool/README.md) ·
[Architecture](2-Wrap-Unwrap-Server/docs/ARCHITECTURE.md) ·
[Source builds](2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md) ·
[Release evidence](2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md) · [License](LICENSE)
