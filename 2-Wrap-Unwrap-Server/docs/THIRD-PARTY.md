# Dependency notices

`third-party/THIRD_PARTY_NOTICES.txt` preserves original upstream license texts.
`third-party/coverage.json` records the historical build-plan/lock hashes, source
checksums, individual notice hashes and collection scope. These retained notices
cover a previous Linux build graph, including build/test dependencies. They are
not a complete inventory or license approval for the current application.

`third-party/bitcoin-core` retains the original Bitcoin Core 30.2 notices and
source/checksum provenance. `third-party/sqlite` retains the pinned SQLite source
notices: the native daemon's descriptor wallet can depend on SQLite even though
the bridge ledger uses only PostgreSQL/Opaleye. Preserve these legal materials.

The old release builder, notice collector and installed-library inventory wrapper
were removed with the superseded deployment. Their source and prior reports remain
in Git history at `eaf8358`. The current toolchain pins are in
`../build/toolchains.json`; native/browser Cabal freeze files and Cargo.lock retain
application dependency selections. Before distributing binaries, regenerate
notices from both actual Cabal compiler graphs, the complete Cargo graph, bundled
native node and actual platform libraries. Review attribution, license choices,
redistribution and embedded-component obligations independently of collection.

## Open dependency findings

The 2026-10-04 advisory refresh still identifies unmaintained bincode 1.3.3
([RUSTSEC-2025-0141](https://rustsec.org/advisories/RUSTSEC-2025-0141.html)).
It is retained for Solana SDK wire compatibility. The refreshed source-path review
includes all six token/pool/bridge FFI entries; Haskell independently validates
bounded SDK output. This does not resolve the maintenance finding.

The earlier source and installed-symbol inventories also retained the generic
`Numeric.readFloat` finding for independent reachability review. Its symbols in
an old binary neither establish an attacker-controlled path nor prove absence in
the current binary. See [DEPENDENCY-REVIEW.md](DEPENDENCY-REVIEW.md).

The current advisory review also retains a build-time Cabal source-header deletion
finding. Previous Linux notice and loader checks remain historical evidence;
the advisory refresh does not replace a distribution/license audit.
