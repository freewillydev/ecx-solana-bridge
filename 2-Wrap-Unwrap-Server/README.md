# Wrap / unwrap server

The bridge exchanges existing ECX and wrapped-ECX inventory with **1% fees each
way**. One Haskell Servant server serves the website; a separate signer controls
keys. PostgreSQL/Opaleye records obligations and payments. Nginx is not required.

Start with the [repository quickstart](../README.md). The Ubuntu x86_64 candidate
is under acceptance testing; a public one-command release is not yet verified.
Keep recovery phrases and independent ledger backups—keys alone cannot recover
in-flight obligations.

- [Setup, HTTPS and recovery](docs/INSTALL.md)
- [Operating the bridge](docs/OPERATIONS.md)
- [Architecture and source audit map](docs/ARCHITECTURE.md#audit-path)
- [Build and test from source](docs/LOCAL-DEVELOPMENT.md)
- [Verified results and remaining gates](docs/RELEASE-REVIEW.md)

`ecx-bridge version` prints the Cabal package version, not a Git revision.
