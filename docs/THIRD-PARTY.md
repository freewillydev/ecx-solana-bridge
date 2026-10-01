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

The initial Linux collection has 333 entries, with texts collected for 330.
Two offline runs produced identical notice output. The unresolved entries are:

- GHC runtime `rts-1.0.3`: its package-specific notice was not located in the
  compiler bindist. The GHC compiler notice is included separately; this is not
  being assumed to settle the runtime entry.
- `r-efi-6.0.0`: neither its published archive nor the root of its recorded
  repository revision contains a standalone license text selected by the collector.
- `spl-memo-interface-2.0.0`: the crate omits its notice; the repository named in
  its package metadata returned 404 for the crate-recorded commit.

Bitcoin Core and bundled dependencies, SQLite's amalgamation notices, Ubuntu
system libraries, and obligations beyond the presence of license texts remain
to be reviewed. Dual-license choices have not been made by the collector.

This collection is source material for the release review. It has not yet been
integrated into a replacement installer, and does not certify the existing local
installer for public distribution. The installed/tested application is unchanged.
