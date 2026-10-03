# Make Wrapped ECX

Token administration stays outside bridge custody. The bridge transfers existing
inventory; its signer API cannot mint or burn. This Cabal package currently prepares
unsigned classic SPL `MintToChecked` and `BurnChecked` transactions with eight
decimals. It neither reads keys nor contacts a network or submits transactions.

From the repository root:

```sh
cabal run ecx-token -- prepare /absolute/path/request.json
cabal test ecx-token:token-test --test-show-details=direct -j1
```

The JSON request has exactly seven fields:

| Field | Meaning |
| --- | --- |
| `protocol` | Integer `1` |
| `verb` | `mint` or `burn` |
| `authority` | Mint authority for issuance; account owner for burning; also fee payer |
| `mint` | Actual classic SPL mint public key |
| `account` | Existing initialized token account for that mint |
| `amount` | Positive canonical decimal string of base units, at most `18446744073709551615` |
| `blockhash` | Recent blockhash from the intended Solana network |

Output contains the request and `unsignedTransaction` as base64. A transaction
preview does not prove account ownership, available funds, reserves or network
identity; those require real-chain checks before signing. The current preparation
command deliberately has no signing or sending command.

Trace [Token.hs](Token.hs): a closed `Safe` operation invokes the pinned SDK through
`ecx_token_prepare_v1`, then Haskell independently validates the complete message.
The FFI entry point accepts no keys or generic instructions. Its buffers are bounded
and caller-owned. The separate custody transfer entry point retains its old protocol.
The shared chain library is reused by this package; customer handlers still have no
chain, store or signer dependency.

QuickCheck compares the real SDK against Haskell validation across both operations,
including integer boundaries and changed-operation/account/amount rejection. Both
unsigned operations passed actual Devnet simulation against the existing test mint
`Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM`; no transaction was signed or broadcast.
The existing custody FFI preview and bridge QuickCheck suite also passed.
Protocol references: [Solana minting](https://solana.com/docs/tokens/basics/mint-tokens)
and [burning](https://solana.com/docs/tokens/basics/burn-tokens).

Remaining: mint creation, metadata creation/update, separate authority signing,
durable exact-byte submission/reconciliation and actual finalized administration
acceptance. Keep the old Devnet setup example until those replacements pass.
Canonical issuance additionally requires actual issuer authority and reserve records;
see the [token operations guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md).
