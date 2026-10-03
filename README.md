# ECX Solana Bridge

A connection-free ECX/Solana inventory bridge, with separate token and liquidity
administration. New conversions charge 1% in each direction. The implementation
uses Haskell, Servant and PostgreSQL/Opaleye; its browser uses GHC's JavaScript
backend and HTML/CSS. The Solana Rust SDK is called through bounded Haskell FFI.

1. [Make Wrapped ECX](1-Make-Wrapped-ECX/README.md): mint, token-account and metadata operations.
2. [Wrap/Unwrap Server](2-Wrap-Unwrap-Server/README.md): customer orders, custody, payments and recovery.
3. [Create CPMM Pool](3-Create-CPMM-Pool/README.md): separate full-range Orca liquidity operations.

Build from the repository root:

```sh
cabal build all -j1
cabal test all -j1 --test-show-details=direct
```

Cabal builds the SDK and browser through its hooks. Native GHC, Cabal, Rust/Cargo,
libpq and GHC JavaScript/Emscripten are compiler prerequisites; there is no npm
application build or WebAssembly backend. See [local development](2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md).

`ecx-bridge` is the sole server executable. Funded L2L Signet/Solana Devnet flows
have passed scoped acceptance. Actual wallet signing, deployed credential isolation,
off-host recovery and other [release gates](2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md)
remain. The obsolete installer was removed; automated installation and clean
reinstallation are unfinished. This is not a valuable-fund release.

[Architecture](2-Wrap-Unwrap-Server/docs/ARCHITECTURE.md) ·
[Operations](2-Wrap-Unwrap-Server/docs/OPERATIONS.md) ·
[Remaining plan](2-Wrap-Unwrap-Server/docs/IMPLEMENTATION-PLAN.md) ·
[MIT license](LICENSE)
