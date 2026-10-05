# ECX Solana Bridge

A connection-free ECX/Solana inventory bridge, with separate token and liquidity
administration. New conversions charge 1% in each direction. The implementation
uses Haskell, Servant and PostgreSQL/Opaleye; its browser uses GHC's JavaScript
backend and HTML/CSS. The Solana Rust SDK is called through bounded Haskell FFI.

The main application is available for source review. Scoped funded L2L
Signet/Solana Devnet flows passed. In the current Mainnet pilot, the unwrap is
`Paid` (3,000 gross → 2,970 net base units); the return wrap (1,000 → 990) remains
pending. The worker and signer are stopped after the keyed OnFinality verifier
exhausted its hourly quota. Alchemy remains the primary RPC. Recovery needs
sufficient verified RPC capacity; the Mainnet round
trip is not complete. See [evidence and release gates](2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md).

1. [Make Wrapped ECX](1-Make-Wrapped-ECX/README.md): mint, token-account and metadata operations.
2. [Wrap/Unwrap Server](2-Wrap-Unwrap-Server/README.md): customer orders, custody, payments and recovery.
3. [Create CPMM Pool](3-Create-CPMM-Pool/README.md): separate full-range Orca liquidity operations.

The private pilot's [customer interface](http://127.0.0.1:61992/) **is currently
offline**. After service restart, that forwarded address is accessible only on its
host Mac; it is not the standard repository port or a public service. Then review
the network, token, limits, fee previews and both direction forms. Creating an
order requires live availability; funding is a separate test step. Existing tester
orders require their private recovery links. Keep those links private.

The pilot has commit `3e34b01` deployed in an Ubuntu VM with separate administrator,
worker and signer users and restricted database roles. Reboot checks verified
signer login/sudo denial and worker exclusion from shared backup staging.
VM restart and recovery of a sequence-9 in-flight
snapshot passed. Its HTTPS backup receiver is on the same Mac, so independent
off-host disaster recovery remains unproved. Start the source audit with the
[server's audit path](2-Wrap-Unwrap-Server/README.md#audit-path).

Build from the repository root:

```sh
cabal build all -j1
cabal test all -j1 --test-show-details=direct
```

Cabal builds the SDK and browser through its hooks. Native GHC, Cabal, Rust/Cargo,
libpq and GHC JavaScript/Emscripten are compiler prerequisites; there is no npm
application build or WebAssembly backend. See [local development](2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md).

`ecx-bridge` is the sole server executable. Actual customer-wallet acceptance,
remaining recovery cases, canonical authority/backing checks and independent
review remain. A candidate installer now targets the frozen runtime; its ARM64
signed package passed clean installation, repeat/upgrade, cold boot and service
isolation checks. x86-64 and funded restore acceptance remain open. This is not a public or valuable-fund release.

[Architecture](2-Wrap-Unwrap-Server/docs/ARCHITECTURE.md) ·
[Operations](2-Wrap-Unwrap-Server/docs/OPERATIONS.md) ·
[Remaining plan](2-Wrap-Unwrap-Server/docs/IMPLEMENTATION-PLAN.md) ·
[MIT license](LICENSE)
