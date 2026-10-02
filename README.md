# ECX Solana Bridge

Three parts of the wrapped ECX project:

1. [Make Wrapped ECX](1-Make-Wrapped-ECX/README.md): token identity, issuance and metadata administration.
2. [Wrap/Unwrap Server](2-Wrap-Unwrap-Server/README.md): the Haskell bridge, ledger, chain adapters, interface and tests.
3. [Create CPMM Pool](3-Create-CPMM-Pool/README.md): separate liquidity setup and trading integration.

Build and test from the repository root with `cabal build all -j1` and
`cabal test all -j1`. Cabal builds the pinned Rust SDK FFI dependency internally;
Cargo/Rust remain compiler prerequisites. The GHC JavaScript browser conversion
and its Cabal build integration are still pending. Installation commands live in
`2-Wrap-Unwrap-Server`.
Token authorities and liquidity keys remain separate from customer custody.
The detailed bridge README records implementation status and remaining release gates.

[MIT license](LICENSE).
