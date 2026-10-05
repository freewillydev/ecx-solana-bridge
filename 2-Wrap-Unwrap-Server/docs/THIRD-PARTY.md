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

The 2026-10-05 `linuxSourceGraphs` check also matches both actual Linux Cabal
plans at `c547f5b`: each has 188 non-local package versions, with 159 source archive
hashes matching the retained Hackage records and 29 compiler-bundled package/version
notice matches. There are no missing records or source-hash mismatches. This closes
the graph-to-notice inventory comparison; it does not re-audit platform license
bytes or satisfy the separate distribution obligations below.

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

## Candidate binary linkage (2026-10-05)

Direct inspection of the ELF program/dynamic headers inside the exact ARM64
`0a545ba` and x86-64 `fb2cb84` installer payloads confirms the recorded bridge,
SDK and reviewed restic hashes. Both bridge binaries reference system libc/libm,
zlib, libpq and GMP; the SDK references libc and libgcc (plus the platform loader).
Neither executable/SDK contains DT_RPATH or DT_RUNPATH. Both restic binaries have
no PT_INTERP or DT_NEEDED entries. This is direct-linkage evidence, not an inventory
of transitive system libraries, statically incorporated code or runtime dlopen paths.
Ubuntu packages supply the system libraries; they are not copied into these bundles.

Both actual payloads include the 2,226,420-byte combined notice file and the
coverage record for 118 restic/compiler notice files, together with the project
license and retained native-node notices. The project-license SHA-256 is
`3764c52a349b6fc4bbedb12d9b87867f9d2ee42c0fbd3330d0033b07da55f085`.
The later Linux graph-comparison metadata is not retroactively present in these
frozen payloads. Private `release-elf-linkage.json` records artifact and component
hashes, ELF machine IDs, direct dependencies and loader paths. No rebuild or
runtime mutation was required. Final attribution/license-choice and embedded-code
obligation review remains open; collected notices alone do not resolve it.

## Declared licenses and named-file coverage

The 2026-10-05 archive review verified source checksums for the union of 165 Hackage
packages in the native/browser/Linux plans and 149 Cargo registry packages in the
lock (the local SDK crate is separate). Hackage declarations comprise 133 BSD-3,
21 MIT, nine BSD-2, one ISC and one PublicDomain declaration. Cargo declarations
include alternative-license expressions and unicode-ident's conjunctive Unicode-3.0
requirement; all three of its Apache/MIT/Unicode texts are retained. r-efi declares
MIT OR Apache-2.0 OR LGPL-2.1-or-later; this expression does not by itself require
choosing its LGPL alternative. These are reported upstream declarations, not a
legal compatibility determination or proof of actual linked membership.

A complete archive-member scan found 224 Cargo and 171 Hackage conventionally named
license/copying/copyright/notice/author files. Every text is present in the combined
notice bundle, including the decompressed streaming-commons test LICENSE.gz.
No source download or build was needed. Private hackage-license-metadata.json and
cargo-license-metadata.json retain per-package declaration/checksum and scan scope.
This closes that named-file comparison, not embedded source-header obligations,
compiler/runtime or system-library review. The separate Go collection is described
above. Keep the independent distribution gate open.

## Final internal artifact check

The `548c509` ARM64/x86-64 review packages each contain the retained notice and
coverage files byte-for-byte. Both actual Cabal plans match 188 non-local records
and 159 distinct source hashes; the unchanged Cargo lock is covered by the retained
registry inventory. Exact pinned restic binaries and all 40 payload-manifest entries
were verified, including browser source/artifact hashes. Direct ELF linkage still
uses Ubuntu-provided libc/libm, zlib, libpq, GMP and libgcc; these system libraries
are not redistributed inside the package, and no RPATH/RUNPATH is embedded.

This closes the internal final-artifact inventory check. It does not convert
collected upstream declarations into independent legal approval, prove absence of
embedded obligations, or waive the documented upstream security findings. Preserve
all notices and the restic modification patch/source pins. Independent distribution
review remains a public-release gate. Exact artifacts and limitations are recorded
in [RELEASE-REVIEW.md](RELEASE-REVIEW.md#final-review-artifacts).
