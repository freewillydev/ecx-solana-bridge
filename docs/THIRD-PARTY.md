# Dependency notice collection

`third-party/THIRD_PARTY_NOTICES.txt` preserves upstream license texts, with a
source and filename above each. `third-party/coverage.json` records the actual
Linux build-plan hash, lockfile hashes, source-archive checksums, individual
notice hashes and unresolved entries. It includes build/test dependencies
conservatively; it does not claim every listed package is linked into the runtime.

Reproduce it in the Linux source/build environment:

```sh
./scripts/collect-notices .release-build docs/third-party --fetch-missing
# With populated caches, repeat offline:
./scripts/collect-notices .release-build docs/third-party
```

The collector checks Hackage archives against Cabal's actual plan and crate
archives against Cargo.lock. Some crates omit workspace licenses: their repository
root notices are fetched at the exact commit recorded in the published crate's
`.cargo_vcs_info.json`. Those entries are identified separately and still require
an applicability check. esbuild's platform binary uses the notice from its
same-version parent package. Absent optional npm platform packages are enumerated
separately; the installed Linux npm graph is the collection target.

The Linux collection has 333 entries, with texts collected for all 333.
Offline regeneration produces identical notice output. The three initial gaps
were resolved from upstream evidence:

- GHC runtime `rts-1.0.3`: the official GHC 9.14.1 source archive, verified
  against the published SHA-256, supplies the distribution license and the
  runtime's `BSD-3-Clause` declaration in `rts/rts.cabal`. Coverage records
  hashes for the source archive and declaration separately.
- `r-efi-6.0.0`: its published `AUTHORS` file contains license text and
  copyright attributions. The collector now retains AUTHORS files.
- `spl-memo-interface-2.0.0`: its metadata names an old repository, but the
  exact crate-recorded commit is available in the official
  [memo repository](https://github.com/solana-program/memo/commit/0ed6992878c38222eb1b30367eea4a3ffd3ba068).
  A version-specific repository correction retrieves that commit's LICENSE.

`third-party/bitcoin-core` preserves 12 original notice files from the official
Bitcoin Core 30.2 source archive. Its provenance records the archive's published
SHA-256 and each notice hash. This includes source-tree dependency notices
conservatively, including files that may not apply to the distributed binaries.
It does not establish notices for dependencies downloaded separately during
Bitcoin Core's upstream build, or verify the release signatures.

`third-party/sqlite` preserves the copyright disclaimer comments from the core,
API header and CLI shell in the pinned SQLite 3.53.4 source archive. Provenance
records the archive's SHA3-256, full source-file hashes and notice excerpt hashes.
Additional embedded-component applicability, Ubuntu system libraries, and
obligations beyond the presence of license texts remain to be reviewed.
Dual-license choices have not been made by the collector.

The release builder now regenerates dependency notices against its actual build
graph, refuses missing entries, verifies saved native-notice hashes and includes
the notices in the hashed package inventory. This packaging change is awaiting
the next completed Linux build. The previously delivered ARM64 installer is
unchanged and does not contain this collection. Neither collection nor packaging
certifies a release for public distribution.
