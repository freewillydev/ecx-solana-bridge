# ECX wrap/unwrap bridge

A connection-free inventory bridge between real ECX-family native chains and a
classic Solana SPL token. New orders charge **1% in each direction**; saved quotes
retain their terms. The operator supplies inventory and pays network costs.
Conversion transfers existing inventory; minting and liquidity management use
separate tools and keys in the other two numbered folders.

**Use the [rebuilt application](rebuild/README.md).** It has completed funded
L2L Signet/Solana Devnet transfers, refunds and interrupted-operation checks.
The original test ledger has also migrated with financial-history comparisons and
completed both conversion directions. This is a test-network implementation,
not a finished public release or proof of perfect security.

## Architecture

One Haskell Servant server serves four customer routes and the browser. Its
handlers return caller/severity-indexed existential requests; typeclass methods
resolve those requests into closed DSL operations. Separate safe and critical
evaluators enforce authority. Concrete result records are serialized as JSON.

PostgreSQL/Opaleye provides the durable ledger. Every application row read/write
belongs to a specific closed operation. The worker saves preparation, authority
and exact signed bytes before sending; verified chain effects settle accounting.
Customer principal, inventory, earned fees and network-cost budgets stay separate.

A dedicated Haskell signer independently verifies saved decisions and signs but
never broadcasts. Only the critical evaluator calls its authenticated loopback
HTTPS Servant API. OS credential isolation is a separate deployment requirement.
The browser is Haskell compiled by GHC's JavaScript backend, with HTML/CSS and
thin browser bindings. The pinned Rust Solana SDK is used through bounded FFI.

## Build and run

From the repository root:

```sh
cabal build all -j1
cabal test all -j1
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- check-config /absolute/private/config.json
cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- observe /absolute/private/config.json
```

Configure actual nodes, PostgreSQL roles, an initialized/migrated ledger and its
host fence first. Starting a worker does not initialize or erase custody state.
For signing and paying mode, follow the [current startup commands](rebuild/README.md#build-and-run).
Use the configuration's `serverPort`; there is no separate Python launcher.

The [development guide](docs/LOCAL-DEVELOPMENT.md) describes compiler/cache setup.
The [rebuild guide](rebuild/README.md) owns the source map, operator commands,
migration/recovery procedures, acceptance evidence and remaining release gates.
The immutable [Main.hs reference](docs/reference/Main.hs) records the supplied DSL design.

## Remaining release work

Actual customer-wallet signing, broader funded recovery/reorg/restore acceptance,
cross-user signer isolation, encrypted-wallet recovery, off-host backups and
clean-host restoration remain outstanding. Canonical betanet/token activation,
real trading-route acceptance and independent security review are separate gates.
See the rebuild guide for the precise current checkpoint.

The baseline application, `deploy/` and older integration tools remain temporarily
because installer/upgrade callers still depend on them. Historical installer
packages and documentation describe that baseline, not the rebuilt process/config
contract. Do not use those packages as certification of this rebuild. Replace and
accept installation last, then remove the baseline implementation. No wipe or
automatic custody reset is part of the local startup path.
