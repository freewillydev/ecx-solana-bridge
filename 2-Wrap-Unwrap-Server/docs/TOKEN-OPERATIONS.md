# Token, treasury and liquidity boundaries

The bridge transfers existing SPL inventory against native ECX. Its custody signer
has no mint, burn, metadata or LP-management endpoint. Use the separate root-Cabal
[token CLI](../../1-Make-Wrapped-ECX/README.md) and
[pool CLI](../../3-Create-CPMM-Pool/README.md) with separate keys.

## Identity and issuance

Verify full mint address, genesis, eight decimals, classic SPL Token program,
absence of freeze authority, custody owner and associated token account. Names,
icons and market symbols do not establish identity. Separately record mint and
metadata authorities and prove their keys are inaccessible to bridge custody.
Changing financial identity requires a reviewed deployment/migration, not editing
an active ledger's fingerprint. Test mints never stand in for canonical assets.

The token CLI implements key generation, mint creation, associated accounts,
issuance, burning and metadata creation/update. It validates exact messages and
archives signatures before returning. Submission uses saved bytes. Retain attempt
files and reconcile uncertain outcomes before new actions; `expired-unseen` is not
proof of nonexecution or permission to repeat issuance. General bounded expiry
recovery remains unfinished. Review issuance, reserves and circulation separately:
bridge custody reconciliation alone cannot establish backing for all circulating tokens.

The pinned upstream reference is Marcus's
[wecx-mint scripts](https://github.com/ecash-com/wrapped-ecx/tree/b980b4372c4844d3d42ff1926fd0da848631cebc/1-make-wrapped-ecx/wecx-mint).
It is historical design context, not current deployment tooling. Never copy an
upstream authority key or `.env` into the bridge. Our commands use integer base units.

## Treasury and market operations

Fund custody with operator-owned native inventory, the configured wrapped asset
and SOL operating capital. Observers must verify each receipt; paused allocation
uses the private `allocate-treasury` command, exact account split and ownership
attestation. See [OPERATIONS.md](OPERATIONS.md). There are no `/audit` or operator
allocation HTTP endpoints. Customer principal and protected backing/LP allocations
cannot be repurposed to conceal inventory shortages.

The pool CLI supports verified full-range Orca pool/position creation, liquidity
deposit/withdrawal and fee collection with saved-attempt submission. Use a separate
LP wallet/capital; never give it the bridge custody key. Real Devnet acceptance
covered funded liquidity, but fees collected were zero. Nonzero yield, reinvestment
and any LP-lock claim need their own evidence. No automated compounding or locking
is implied by pool creation.

Jupiter/Orca links provide trading in wrapped tokens; they do not replace native
wrap/unwrap deposit instructions. Publish the exact configured mint/pool and verify
current route availability. The pool CLI's safe `quote-mainnet` command has checked
the published pool `nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM` in both
USDC/wrapped directions. This was quote-only: no customer identity, signing or
execution. Pool fees, aggregator fees and the bridge's 1% conversion fee are distinct.

Canonical trading links remain disabled in the dedicated Devnet profile. Issuer
approval, canonical backing/authority, funded canonical flows and executed trading
acceptance remain [release gates](RELEASE-REVIEW.md). Follow the two CLI READMEs
for exact arguments and current supported operation limits.
