# Dependency review status

The 2026-10-04 review used the actual native GHC 9.14.1 and JavaScript GHC 9.12.2
Cabal plans, their freeze files, and the current Cargo.lock. It matched 36 published
[Haskell advisories](https://github.com/haskell/security-advisories/tree/57073681929c733854f3222e3fa7d14c05262508)
and ran cargo-audit 0.22.2 against RustSec commit
`ef6173cbc5c50ec8166f9a5b28f07834144373ee` (1,290 advisories).
These are version/source checks, not independent security certification.

| Inputs checked | Result after remediation |
| --- | --- |
| Native plan: 193 package/compiler versions, including build/test inputs | `base` HSEC-2023-0007; build-time `Cabal` HSEC-2026-0006 |
| Browser plan: 77 package/compiler versions | `base` HSEC-2023-0007 |
| Cargo lock: 150 dependencies | No matched vulnerability advisories; unmaintained bincode warning remains |

## Remediations and retained findings

- [HSEC-2026-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0007.md):
  browser Aeson was pinned to affected 2.2.3.0; it is now 2.2.5.1. Native Aeson stays
  2.3.2.0 with a patched-version floor. Both graphs use text-iso8601 0.1.1.2.
  The verified browser source rejects exponents below -1024 and above 1024 before
  fixed-point conversion. Root Cabal build, a fresh browser build directory and all
  three Cabal suites passed. The served asset matched the new build; reloading
  recovered the existing paid test order and payout link. This is dependency
  remediation, not a claim that the old application's types exposed every affected instance.
- [HSEC-2026-0008](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0008.md):
  crypton-x509 and crypton-x509-validation remain constrained to >=1.9.1. Existing
  QuickCheck checks permitted names and rejected exclusions; signer HTTPS also pins
  its certificate. These checks do not prove whole-TLS security.
- [HSEC-2023-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2023/HSEC-2023-0007.md):
  generic Numeric.readFloat remains affected in both base versions. Amounts use
  bounded integers/decimal strings. Refreshed hash-verified source inventories found
  no readFloat/numberToRational references in 159 native and 49 browser Hackage
  packages. They exclude 29/26 boot packages respectively and do not establish
  compiled reachability. Keep this finding open for independent review.
- [HSEC-2026-0006](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0006.md):
  Cabal 3.16.0.0 can delete duplicate source headers during configure. It belongs
  to the native build-hook dependency closure, not the server's linked-library
  closure. Build trusted pinned sources in a disposable checkout without custody
  credentials; the upstream build-time finding remains unresolved.
- [RUSTSEC-2025-0141](https://rustsec.org/advisories/RUSTSEC-2025-0141.html):
  bincode 1.3.3 remains unmaintained. All six production SDK FFI entries route through
  bounded JSON input to message/instruction construction and serialization; direct
  bincode deserialization in our helper is under cfg(test). Haskell separately
  validates returned bytes/effects. This source-path review includes token/pool
  operations but does not waive maintenance risk or prove all transitive code safe.
  Replacing the serializer requires exact Solana wire/signature compatibility.

## Reproducing the source inventory

From the repository root (use the browser plan and its explicit `--freeze` for JS):

```sh
2-Wrap-Unwrap-Server/scripts/check-readfloat-sources dist-newstyle/cache/plan.json \
  --cache /path/to/source-cache --report /path/to/report.json
```

`--download` retrieves checksum-verified Hackage archives. Optional `--ghc-source`
checks the matching pinned native compiler archive; it is not a call-graph proof.
Recheck both compiler graphs, FFI and actual platform/node binaries for the release
artifact. License/notice regeneration and independent application review remain
open; see [THIRD-PARTY.md](THIRD-PARTY.md). Historical Linux results do not certify
this macOS build or a future installer.
