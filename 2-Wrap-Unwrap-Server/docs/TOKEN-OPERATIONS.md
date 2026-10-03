# Token, inventory and liquidity operations

The bridge transfers an existing SPL token against native ECX inventory. Its
custody signing protocol exposes no minting or metadata operation. Token administration and
liquidity positions use separate operator tooling and keys, outside this server.
Ordinary customers use deposit instructions and Solana Pay; the bridge website
requires no wallet connection.

## Adopt the correct token

Record the complete mint address, chain genesis, eight decimals, original SPL
Token program (`TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`), absence of a
freeze authority, and the custody owner/associated token account. These are
checked by the adapters; token names and icons do not establish identity.
Separately record mint and metadata authorities and verify that their keys are
not held by the server; protocol restrictions alone cannot remove authority
from a key. Authority separation remains an operator/release check.
Publish the configured mint and distinguish Devnet inventory from canonical
assets. Changing a mint or custody identity requires a new reviewed deployment,
not editing an active ledger's fingerprint.

Use the root-Cabal [token administration CLI](../../1-Make-Wrapped-ECX/README.md)
for separate key generation, mint creation, associated token accounts, issuance,
burning and metadata. It has real Devnet acceptance, immutable signed attempts,
separate safe/critical evaluators and independent transaction validation. Create
and fund distinct test identities explicitly; retain the saved attempts and
reconcile them before issuing another operation. These test mints do not authorize
or replace the canonical token. Existing canonical assets require their actual
authority and reserve records; the bridge cannot recreate their identity.
The previous standalone Rust setup example is preserved in Git at `d6246c8`;
its private keys and transaction records are not migrated or deleted by this change.

## Upstream administration reference

Marcus's [wecx-mint scripts](https://github.com/ecash-com/wrapped-ecx/tree/b980b4372c4844d3d42ff1926fd0da848631cebc/1-make-wrapped-ecx/wecx-mint)
provide separate mint creation, metadata creation/update, mint-to and burn
operations. This reference pins the reviewed upstream snapshot. Review its
source and lockfile before use; its defaults target mainnet, so select Devnet
explicitly for testing. Its amount convention is human token units, unlike our
API's integer base units. Never copy its authority keys or `.env` into a bridge
release. Minting there does not verify native reserves.

Metaplex provides maintained [token creation tooling](https://www.metaplex.com/docs/tokens/create-a-token)
and [metadata update tooling](https://www.metaplex.com/docs/tokens/update-token).
Use the actual metadata update authority, retain transaction identifiers and the
old/new metadata URI, and verify the resulting account on the intended chain.
Metadata updates are independent of customer quotes and the bridge ledger.
Authority changes, additional issuance and burns require separate operator
review, matching reserve/circulation accounting and the release gates. The dedicated test mint acceptance is recorded in the token CLI README.

## Fund the bridge

Transfer operator-owned native inventory, configured wrapped tokens and SOL fee
capital into the configured custody accounts. Let the actual observers finalize
each receipt. Pause the paying worker, inspect `/audit`, attest ownership and
use `/allocate-treasury` as described in [INSTALL.md](INSTALL.md#allocating-fresh-treasury-funding-postgresql).
Allocate each whole receipt to explicit accounts; SOL is restricted to operating
fees. Stock and fee budgets are separate. Resume only after custody and startup
checks pass. Quote admission refuses insufficient inventory; it never mints a
replacement token or spends protected backing to conceal a shortage.

Ledger custody reconciliation proves the server's recorded holdings. It does
not, by itself, prove backing for every token circulating outside the server.
That requires the complete issuance, reserve and redemption records.

## Configure trading separately

Use a separate liquidity wallet and the actual token pair. Follow Orca's
[pool creation procedure](https://docs.orca.so/create/pools/clmm); keep pool,
position, initial funding, authority and subsequent fee records. The reviewed
upstream vision calls for a full-range constant-product pool: select Orca
full-range/Splash rather than a finite concentrated price range. Verify the
actual created pool parameters; the linked CLMM documentation alone does not
prove that choice. Retain separately verifiable LP ownership/lock evidence if
publishing a liquidity-lock claim. A bridge ledger does not establish an LP lock.
External pool
or vault management handles any fee reinvestment. The bridge does not place
liquidity, auto-compound yields or manage positions with customer custody keys.
Do not manually move server inventory into a pool without a supported ledger
spend workflow; use separately held liquidity capital.

Configure `jupiterUrl`/`orcaUrl` in `interface.json` only after verifying the
canonical mint, pool identity, token pair and an actual route/quote. The current
configuration deliberately excludes trading links on Devnet. A visible link
is not evidence of liquidity or executable routing. Market availability and
canonical backing acceptance remain open release gates.

An October 2 read-only upstream refresh found the same reviewed commit
`b980b4372c4844d3d42ff1926fd0da848631cebc`. The server conversion contract still
uses native per-order addresses and Solana Pay references, with no bridge
mint/burn authority. See `https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/upstream-replacement-refresh.json`.

## Published pool readback

The pool from the September 30 conversation,
`nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM`, was read at finalized
mainnet state on October 2. Its Orca Whirlpool account binds USDC
`EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` to
`EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq`. The latter has eight
decimals, no freeze authority, and mint authority
`6Av9JtnZGADBATo3uyLVC12XojJYKJhZxv578cJR2sKT`. Both vaults are initialized
classic SPL accounts owned by the pool and bind to their exact respective mints.
Recorded vault balances are 33365.220290 USDC and 11000.17981711 wrapped tokens.
These balances are a snapshot, not the initial funding or all circulating backing.

The account's tick spacing is 32896, above Orca's upstream full-range-only
threshold of 32768; its fee-rate field is 10000 hundredths of a basis point
(1%). Layout/discriminator/owner and source hashes are recorded in
`https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/published-orca-pool-readback.json`. This single-provider read does not
prove issuer approval, reserve backing, LP ownership/lock, auto-compounding or
Jupiter routing. The current [Cabal pool verifier](../../3-Create-CPMM-Pool/README.md)
additionally verifies the canonical PDA and reports the published pool's distinct
fee-tier index 1034 and adaptive-fee status; its stored 1% is a base fee, not a
guaranteed total swap fee. It does not change the bridge's configured dedicated Devnet
mint or authorize mainnet operations.

## Published Jupiter routes

On October 2, actual quote-only reads of Jupiter's Swap V2 `/order` endpoint
returned direct Metis/Whirlpool routes through that same pool in both directions:
1000000 USDC base units quoted 32520698 wrapped base units, and 100000000 wrapped
base units quoted 3007388 USDC base units. Each route allocated 10000 basis points
to the exact published pool and token pair. The reported aggregator fee was
10 basis points, separate from the pool fee and the bridge's 1% conversion fee.
Quotes change; these amounts are evidence snapshots, not customer price promises.

From the repository root, repeat the read-only check through the pool's safe DSL:

```sh
cabal run -v0 ecx-pool -- quote-mainnet \
  nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM \
  EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v \
  EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq \
  1000000 100000000 > /path/to/market-quotes.json
```

The Haskell replacement passed both real quoted directions on October 3:
1000000 USDC base units → 35807675 wrapped base units; 100000000 wrapped base
units → 2731334 USDC base units. Both used the expected Whirlpool with a 10-basis-point
aggregator fee. Cabal QuickCheck covers wrong pair/pool/amount, split routes,
execution fields, error responses and integer limits.

The operation supplies no wallet identity, signs nothing,
and refuses unexpected pair/pool bindings or a non-direct route. It records
response hashes and timestamps, and never calls `/execute`. The real endpoint
accepted these requests without credentials, although the
[current API documentation](https://developers.jup.ag/docs/swap) specifies an
API key; future authentication refusal must be investigated rather than treated
as absent liquidity. See `https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/published-jupiter-routes.json`.

Both quoted routes are verified. An assembled transaction and executed swap are
not verified. Canonical configuration, issuer approval and backing gates remain
open; trading links stay disabled in the dedicated Devnet deployment.
