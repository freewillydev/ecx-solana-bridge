# Wrap / unwrap server

Use the **[`.run` installer and quickstart](../README.md)** on Ubuntu 24.04 x86_64.
It installs the server, dedicated signer, PostgreSQL and pruned ECX node.

```sh
sudo sh ./ecx-bridge-ubuntu-24.04-x86_64.run
# Resume setup after interruption or funding:
sudo ecx-bridge
```

The bridge exchanges existing inventory with a 1% fee each way. Keep both recovery
phrases, the backup password and independent ledger backups. Orders remain paused
until funding, allocation and readiness checks pass.

[Detailed setup](docs/INSTALL.md) · [Operation and upgrades](docs/OPERATIONS.md) ·
[Architecture](docs/ARCHITECTURE.md) · [Source builds](docs/LOCAL-DEVELOPMENT.md) ·
[Release evidence](docs/RELEASE-REVIEW.md)
