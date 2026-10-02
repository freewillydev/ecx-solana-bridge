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

The genuine Devnet setup example is
[`setup_devnet.rs`](../solana-helper/examples/setup_devnet.rs). It creates a
separate test mint and journals submitted setup transactions. Reconcile a saved
attempt before running setup again. This does not create or authorize the
canonical token. Existing canonical assets require their actual authority and
reserve records; the bridge cannot recreate them under the same address.

## Use existing administration tools

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
review, matching reserve/circulation accounting and the release gates. No
administration transaction was executed by this documentation change.

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
mint/burn authority. See `evidence/upstream-replacement-refresh.json`.
