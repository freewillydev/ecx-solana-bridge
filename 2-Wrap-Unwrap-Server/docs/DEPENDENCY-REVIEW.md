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
  compiled reachability. Inspection of the frozen macOS executable with `nm`
  confirms that `GHC.Internal.Numeric.readFloat` and
  `GHC.Internal.Text.Read.Lex.numberToRational` are linked. Their presence is not
  evidence of an attacker-reachable call, but excludes treating the source grep
  as proof that these routines are absent from the executable. Keep this finding
  open for input-path analysis and independent review.
  The subsequent input-path review verified the pinned GHC 9.14.1, Aeson 2.3.2.0
  and scientific 0.3.8.1 source archives. No application `readFloat` call was found.
  `Domain` parses amounts from at most 19 ASCII unit digits (or 11 whole/8 fractional
  coin digits). `Native.nativeAmount` checks exponent and coefficient bounds before
  exponentiation. Aeson's bounded integer instances use `toBoundedInteger`, which
  rejects excessive magnitude before constructing the integer. The store's direct
  `floatingOrInteger` input comes from PostgreSQL SUM over bigint journal entries,
  not a customer/RPC JSON number. Browser `Double` values are clock/date FFI values.
  A Cabal QuickCheck contract now decodes actual order/policy wire records with
  positive/negative billion-scale and machine-limit exponents under a one-second
  deadline, rejects numeric and string amount forms, and retains a valid-order
  control. It passed with the bridge suite. Existing native amount checks cover
  minimum/maximum scientific exponents. These tests cover the named boundaries;
  they do not waive the generic library finding, establish a compiled call graph,
  or certify all transitive HTTP/TLS/database/browser parser paths. Source hashes
  and scope are recorded in private `numeric-input-boundaries.json` beside the
  existing source inventories. The deployed runtime remains unchanged.
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
artifact. Current package-notice collection covers all 358 package versions;
distribution/license obligations and independent application review remain open;
see [THIRD-PARTY.md](THIRD-PARTY.md). Historical Linux results do not certify
this macOS build or a future installer.

## Bundled restic binary

The signed ARM64 installer `8db99c8` contains restic 0.19.1 built with Go 1.26.4
(SHA-256 `2fb45ac6f9071b6f20eb883953a188f9e7c7cb6bbe43c67a2e47ada4e85ee7f0`).
It is outside the Cabal/Cargo inventories above. Its build metadata contains 79
Go dependency modules. govulncheck 1.8.0 binary-mode analysis against the Go database
updated 2026-10-01 reported 22 advisory IDs, including TLS/HTTP/runtime and dependency
findings. Binary findings are not proof of reachable exploitation, but this binary
must not be reused for the public release.

A candidate built from checksum-verified upstream restic v0.19.1 with the retained
`install/restic-security.patch`, Go 1.26.8 and no `selfupdate` tag resolves every
fixable advisory reported in that scan. The remaining GO-2026-5932 OpenPGP wildcard
report has no fixed version; the exact Linux/ARM64 selected import graph contains
no OpenPGP or self-update package. Retain this evidence for reviewer confirmation,
not a blanket waiver of the crypto module. The scanner's main-module version is
`(devel)`, so its report also does not establish upstream restic advisory coverage.
See [govulncheck's binary-mode limitations](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck).

Candidate SHA-256:
`f5fdb349699c6b0a82a3c5bf4b92e94769842ae909f5ffb010dc694b668740bf`.
In Ubuntu ARM64, old backups restored with the candidate and candidate backups
restored with the old binary; both complete data checks passed and a wrong password
was refused. This used disposable local files/repositories, no custody keys, no
bridge services and no external chain calls. The fixture and copied executables
were removed and the VM stopped. It does not establish bridge checkpoint or remote
backup acceptance. The signed installer has not been replaced. The paused VM now uses the reviewed
binary after the bridge integration check below.

`build/toolchains.json` pins the upstream module checksum, compiler, patch and
reviewed candidate hash. Packaging now rejects the old binary before building.
There is no reviewed x86-64 hash yet. Remaining work is updated Go/restic notices,
independent applicability review, x86-64 acceptance and
regeneration/authentication of the final artifact. Private `restic-*` source,
scan, import and compatibility evidence is in `security-audit/current-20261004`.

The frozen Linux bridge executable subsequently recovered the real sequence-55
custody snapshot through the candidate and existing HTTPS repository, inspected its
ledger/native-wallet/key/config bindings, then uploaded the bundle and completed
its mandatory full download/readback. The custody manifest SHA-256 stayed
`683700290474dc44eadb3b8b05fb3b48a2f8b081e1ea603e3861aa360580256f`.
The new snapshot is
`0a5d2fd769107f31bea65cf870c625cd851e152a87dbc2ba1499ce4932e20e12`.
This exercises the actual closed custody upload/download implementation used by
checkpoints, not just standalone restic. It does not exercise a new signing-triggered
checkpoint or ledger activation. Both services remained stopped; temporary recovered
keys and files were removed. The candidate replaced `/opt/ecx/bin/restic` atomically
as root mode 0755, retaining the old tool root-only for explicit recovery; the bridge
executable was unchanged. The VM was stopped afterward. This repository still lives
on the same physical Mac, so independent disaster recovery remains unproven.

The Go advisory module index was also checked directly for `github.com/restic/restic`
and contained no matching module record on 2026-10-04. This addresses the scanner's
missing main-module version only as published-database evidence, not a source audit
or guarantee that restic has no unknown vulnerabilities. Private integration,
deployment and module-index records accompany the earlier scans.
