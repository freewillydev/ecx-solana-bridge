# Dependency review status

The frozen native/browser Cabal graphs, Cargo.lock and `../build/toolchains.json`
are the current input inventory. The server promotion did not perform a fresh
advisory, compiled-reachability or license audit. Earlier evidence is retained in
[Git history](https://github.com/freewillydev/ecx-solana-bridge/blob/6d293a3/docs/evidence/dependency-advisory-review.json)
and must be matched to the actual release inputs before use.

## Retained findings and controls

- X.509 Name Constraints: the previous review matched
  [HSEC-2026-0008](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0008.md).
  Root Cabal requires crypton-x509 and crypton-x509-validation >=1.9.1. The current
  QuickCheck suite tests permitted names and rejected exclusions. Signer HTTPS
  additionally pins its certificate. These checks are not whole-TLS verification.
- The historical Cargo review reported unmaintained bincode 1.3.3
  ([RUSTSEC-2025-0141](https://rustsec.org/advisories/RUSTSEC-2025-0141.html)).
  It remains pinned for Solana message compatibility. Reassess maintenance and
  current FFI reachability; the earlier transfer-only review predates token/pool
  instruction support. Any replacement needs exact wire/signature acceptance.
- The historical Haskell advisory export matched base's generic `Numeric.readFloat`
  against [HSEC-2023-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2023/HSEC-2023-0007.md).
  Application amounts use bounded integer units and checked decimal strings.
  Earlier source scanning found no direct application/dependency references, but
  affected symbols existed in a previous installed binary. Keep independent
  reachability review open; source scanning alone does not settle it.
- Native Aeson 2.3.2.0 and browser Aeson 2.2.3.0 use separate compiler graphs.
  Review both actual frozen graphs, including text-iso8601, against
  [HSEC-2026-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0007.md)
  and the current advisory database. The earlier native review is not blanket
  browser coverage.

The remaining source-inventory utility accepts the actual Cabal plan:

```sh
# From 2-Wrap-Unwrap-Server; paths to caches/report are operator choices.
./scripts/check-readfloat-sources ../dist-newstyle/cache/plan.json \
  --cache /path/to/source-cache --report /path/to/report.json
```

`--download` retrieves checksum-verified Hackage archives; optional `--ghc-source`
inventories the pinned compiler sources. This is a read-only review utility, not an
advisory waiver or application test. The retired Linux release workflow is not a
current build, installation or security acceptance result.

Before public/valuable-fund release, refresh advisories and source provenance for
the exact native, GHC-JavaScript, FFI and platform inputs; assess unresolved findings;
regenerate notices and review license obligations; obtain independent application
review. [THIRD-PARTY.md](THIRD-PARTY.md) describes retained legal evidence.
