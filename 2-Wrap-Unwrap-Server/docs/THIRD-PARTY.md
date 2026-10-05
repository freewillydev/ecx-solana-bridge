# Dependency notices

`third-party/THIRD_PARTY_NOTICES.txt` preserves original upstream license texts.
`third-party/coverage.json` records build-plan/lock hashes, source checksums,
individual notice hashes and collection scope. Its `currentSourceGraph` section
covers all 358 distinct package versions in the 2026-10-04 macOS native/browser
Cabal plans and complete Cargo lock, including build/test dependencies.
The refresh added 41 Hackage package versions from hash-verified source archives
and 18 compiler-bundled versions from installed compiler documentation. Boot
records identify that provenance and hash their installed package metadata;
the JavaScript RTS uses its distribution license and declared BSD-3-Clause license.
Historical Linux records and notice bytes remain intact. Presence of these texts
does not complete review of compiler/runtime components, platform libraries or
redistribution obligations, and does not certify a future Linux release artifact.

`third-party/bitcoin-core` retains the original Bitcoin Core 30.2 notices and
source/checksum provenance. `third-party/sqlite` retains the pinned SQLite source
notices: the native daemon's descriptor wallet can depend on SQLite even though
the bridge ledger uses only PostgreSQL/Opaleye. Preserve these legal materials.

The old release builder, notice collector and installed-library inventory wrapper
were removed with the superseded deployment. Their source and prior reports remain
in Git history at `eaf8358`. The current toolchain pins are in
`../build/toolchains.json`; native/browser Cabal freeze files and Cargo.lock retain
application dependency selections. Before distributing binaries, verify the
retained notices against that artifact's actual compiler/Cargo graphs, bundled
native node and platform libraries. Review attribution, license choices,
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

The patched ARM64 restic candidate has a separate `resticCandidate` inventory in
`coverage.json`; it is **not** included in the 358 Cabal/Cargo versions above.
All 79 module source checksums matched its embedded build metadata. The collection
preserves 118 notice files across those modules, upstream restic and the Go 1.26.8
compiler/runtime archive, including nested notices. Each entry records source and
notice hashes. Identical license texts share one retained body; all 118 original
byte sequences were verified against the combined notice text. Existing notices
were preserved byte-for-byte. This adds 58 distinct text blocks to the existing
bundle without adding notice files or application code.

This closes notice-file collection for that candidate, not review of license
choices, embedded source-header obligations, platform libraries, or the final
artifact's distribution obligations. Go archive collection includes compiler
notices as well as runtime notices. Recheck the exact binary and graph if either
changes. See the candidate hashes and remaining checks in
[DEPENDENCY-REVIEW.md](DEPENDENCY-REVIEW.md).
