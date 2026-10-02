# Dependency security review

This review checks published advisories against the actual frozen build inputs.
It is not independent application review or a claim that unknown vulnerabilities
are absent. [Machine evidence](https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/dependency-advisory-review.json) records
lockfile hashes, database revisions and the remaining review items.

On October 1, npm audit reported zero advisories across the locked web graph.
Cargo-audit 0.22.2 reported zero known vulnerabilities across 150 Rust dependencies,
using RustSec revision `6de4455103aced2cba86e3b86e5c090b22827cf1`.
It reported [RUSTSEC-2025-0141](https://rustsec.org/advisories/RUSTSEC-2025-0141.html)
for unmaintained bincode 1.3.3. Production helper code uses bincode for serialization
of upstream Solana messages/transactions; its bincode deserialization calls are
inside tests. Changing the serializer without preserving the official wire format
would break payment signatures. This maintenance finding remains for independent
review rather than being hidden or automatically waived.

The [official Haskell advisory export](https://github.com/haskell/security-advisories/tree/generated/osv-export)
was inspected at revision `b3b322f94099749633bf31c50a824b2ad1054bb0`.
The old frozen certificate packages were affected by
[HSEC-2026-0008](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0008.md),
which concerns X.509 Name Constraints during TLS certificate validation. The
updated frozen group uses crypton-x509/validation 1.9.1, store/system 1.9.0,
crypton 1.1.5, ram 0.22.1, TLS 2.4.4, connection 0.4.6 and http-client-tls 0.4.0.
The TLS advisory no longer matches this graph.

The upstream update replaces the memory dependency with ram. Application APIs,
ledger schema, fee terms and signed transaction formats are unchanged. GHC 9.14's
base/time/containers versions exceed the declared bounds in serialise/cborg;
exceptions are limited to those specific dependencies in `cabal.project`.
Compilation and all 371 application examples pass. A separate certificate-only
regression creates a constrained issuer and checks that permitted DNS succeeds,
while outside and explicitly excluded DNS names fail validation. It uses no chain,
wallet, signer or network stand-in, and runs in the Linux release builder too.
Actual Signet/betanet native identities and HTTPS Devnet identity checks pass with
the patched binary. Offline custody-key validation passes and the existing ledger
fingerprint is unchanged. These checks signed and broadcast nothing.

The export still matches
[HSEC-2023-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2023/HSEC-2023-0007.md)
against base's generic `Numeric.readFloat`; the record lists no fixed version.
The application has no direct call to that function. Amounts use bounded integer
units and checked decimal strings. The October 2 source inventory verifies the
build plan against the freeze file and scans 164 configured Hackage packages from
archives matching the build plan's SHA-256 values. None contains a `readFloat` or
`numberToRational` reference in its Haskell/preprocessor source files. This is a
source inventory, not a call-graph or generated-code reachability proof.

The separately pinned GHC 9.14.1 source archive also matches its checksum. Its
3,862 library source files locate the generic conversion in
`GHC.Internal.Numeric`, the rational/exponent implementation in
`GHC.Internal.Text.Read.Lex`, public reexports and a test-local name. Manual review
of `GHC.Internal.Read` confirms integer `Read` uses the integer conversion and
Float/Double use the ranged conversion. This agrees with the advisory's stated
mitigation; the unsafe generic function remains available. The 27 compiler-supplied
boot units have not received a compiled-unit reachability proof. Preserve the
package-level finding for independent review.

The frozen Aeson 2.3.2.0 and text-iso8601 0.1.1.2 are beyond/at the respective
fixed versions in [HSEC-2026-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0007.md).
That distinct negative-exponent JSON finding does not match these frozen versions.
No deliberately memory-exhausting proof-of-concept was executed.

See [pinned source inventory](https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/readfloat-source-inventory.json). Reproduce
with `scripts/check-readfloat-sources PLAN --cache SOURCE_CACHE --report REPORT`;
`--download` fetches missing official Hackage archives and refuses checksum
mismatches. Optional `--ghc-source ARCHIVE` inventories the separately pinned boot
source. These tools do not extract archives, compile, start a worker or waive a
vulnerability. Input PLAN must correspond to the actual frozen build.

Native system-library applicability, full license obligations and independent
review remain release gates. Installation of the patched compiled artifacts is
now verified on ARM64 and x86-64; the newer deployment-only releases retain those
same binaries.
