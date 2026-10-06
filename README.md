# ECX Solana Bridge

A connection-free ECX/Solana inventory bridge, with separate token and liquidity
administration. New conversions charge 1% in each direction. The implementation
uses Haskell, Servant and PostgreSQL/Opaleye; its browser uses GHC's JavaScript
backend and HTML/CSS. The Solana Rust SDK is called through bounded Haskell FFI.

The schema-22 candidate is ready for source review. Real L2L Signet/Solana Devnet
tests passed both conversions (10,000 → 9,900 base units), an additional-payment
refund, restart during payout and a verified Solana expiry followed by an approved
retry. Final custody matched the ledger exactly. The refactor has completed
117/120 checkpoints; external recovery, independent review and activation remain.
Its source-size target was not met: application/schema is 16,339 lines. See the
[measured results, evidence and release gates](2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md).

1. [Make Wrapped ECX](1-Make-Wrapped-ECX/README.md): mint, token-account and metadata operations.
2. [Wrap/Unwrap Server](2-Wrap-Unwrap-Server/README.md): customer orders, custody, payments and recovery.
3. [Create CPMM Pool](3-Create-CPMM-Pool/README.md): separate full-range Orca liquidity operations.

The private pilot's [customer interface](http://127.0.0.1:61992/) **is currently
offline**. After service restart, that forwarded address is accessible only on its
host Mac; it is not the standard repository port or a public service. Then review
the network, token, limits, fee previews and both direction forms. Creating an
order requires live availability; funding is a separate test step. Existing tester
orders require their private recovery links. Keep those links private.

The earlier canonical betanet/Mainnet pilot remains frozen at `548c509`; this
refactor has not upgraded it. Its confirmed round trip was 3,000 wrapped → 2,970
native, then 1,000 native → 990 wrapped base units. It uses an Ubuntu VM with separate
administrator, worker and signer users and restricted database roles. Same-host
in-flight restoration passed using the sequence-55 custody snapshot. Its HTTPS
backup receiver remains on the same Mac, so physically independent disaster
recovery is still unproved. Start the source audit with the
[server's audit path](2-Wrap-Unwrap-Server/README.md#audit-path).

Requires **GHC 9.14.1 and Cabal 3.16.1.0**. Select the pinned tools using the
[compiler setup instructions](2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md) before building.

Build from the repository root:

```sh
cabal build all -j1
cabal test all -j1 --test-show-details=direct
```

Cabal builds the SDK and browser through its hooks. Native GHC, Cabal, Rust/Cargo,
libpq and GHC JavaScript/Emscripten are compiler prerequisites; there is no npm
application build or WebAssembly backend. See [local development](2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md).

`ecx-bridge` is the sole server executable and serves public HTTPS directly with
WarpTLS; no Nginx, Node server or separate reverse proxy is required. See
[HTTPS configuration](2-Wrap-Unwrap-Server/docs/INSTALL.md#public-https-in-the-haskell-server).
PostgreSQL, native/Solana RPC access and restic backup storage remain required
runtime infrastructure. Public certificates must be supplied and renewed.

Actual customer-wallet acceptance,
remaining recovery cases, canonical authority/backing checks and independent
review remain. Signed ARM64 and x86-64 candidate packages passed clean installation,
repeat-fresh refusal, upgrade preservation, cold boot and service isolation checks.
Unfunded native-node/HTTPS-backup integration also passed. Funded clean-host
restoration and physically independent backup/retention remain open.
This is not a public or valuable-fund release.

[Architecture](2-Wrap-Unwrap-Server/docs/ARCHITECTURE.md) ·
[Operations](2-Wrap-Unwrap-Server/docs/OPERATIONS.md) ·
[Remaining plan](2-Wrap-Unwrap-Server/docs/IMPLEMENTATION-PLAN.md) ·
[MIT license](LICENSE)
