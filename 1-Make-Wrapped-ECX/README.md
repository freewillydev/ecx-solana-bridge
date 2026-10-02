# Make Wrapped ECX

Token issuance and metadata administration belong here, outside bridge custody.
The bridge transfers an existing SPL token; it does not mint or burn tokens.

The existing [token operations guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md)
records token identity, authority separation, reviewed upstream tooling and
Devnet setup. The [current test-mint setup](../2-Wrap-Unwrap-Server/solana-helper/examples/setup_devnet.rs)
remains with its existing SDK build until the Haskell/FFI conversion is complete.

This folder establishes the administration boundary; it does not yet contain
an independent Haskell token administration program. Canonical issuance requires
actual issuer authority and matching reserve records.
