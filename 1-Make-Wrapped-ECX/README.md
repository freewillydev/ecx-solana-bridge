# Make Wrapped ECX

Token administration stays outside bridge custody. The bridge transfers existing
inventory; its signer API cannot mint or burn. This Cabal package currently prepares
unsigned classic SPL `MintToChecked` and `BurnChecked` transactions with eight
decimals. Its separate offline signing command saves validated signed bytes using
a dedicated authority key. Neither command contacts a network or broadcasts.

From the repository root:

```sh
cabal run -v0 ecx-token -- prepare /absolute/path/request.json > /absolute/path/prepared.json
cabal run -v0 ecx-token -- sign /absolute/path/prepared.json /private/authority.json /private/new-attempt.json
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
identity; independently verify those on the intended chain before offline signing.
There is no sending command yet. Do not use custody keys for administration.

`sign` takes the exact output of `prepare`, validates its entire message again,
and checks the standard 64-byte Solana CLI keypair against the requested authority.
The key must be an owned regular mode-0600 file; key and output directories must
be owned, private directories. The critical evaluator signs with Ed25519, verifies
the signature, exclusively creates the output at mode 0600, and synchronizes both
file and directory before returning its transaction ID. Existing files are refused;
a failed write is retained for inspection. This record is not proof of submission
or finalization. Do not regenerate an attempt to retry a future uncertain send.
Offline signatures do not bind a genesis hash; intended-chain validation remains
required at submission.

Trace [Token.hs](Token.hs): a closed `Safe` operation invokes the pinned SDK through
`ecx_token_prepare_v1`, then Haskell independently validates the complete message.
The safe FFI entry point accepts no keys or generic instructions.
[Token/Signing.hs](Token/Signing.hs) owns the separate closed critical evaluator;
the CLI has one critical dispatch site. Its buffers are bounded
and caller-owned. The separate custody transfer entry point retains its old protocol.
The shared chain library is reused by this package; customer handlers still have no
chain, store or signer dependency.

QuickCheck compares the real SDK against Haskell validation across both operations,
including integer boundaries and changed-operation/account/amount rejection. Both
unsigned operations passed actual Devnet simulation against the existing test mint
`Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM`; no transaction was signed or broadcast.
The existing custody FFI preview and bridge QuickCheck suite also passed.
Offline signing checks use disposable fixture keys and verify the actual Ed25519
signature, exact-file retention and rejection of changed terms, wrong authority,
corrupt public-key halves, out-of-range key bytes, unsafe permissions and symlinks.
No real authority key has been used by the signing acceptance tests.
Protocol references: [Solana minting](https://solana.com/docs/tokens/basics/mint-tokens)
and [burning](https://solana.com/docs/tokens/basics/burn-tokens).

Remaining: mint creation, metadata creation/update, chain preflight, durable
exact-byte submission/reconciliation and actual finalized administration
acceptance. Keep the old Devnet setup example until those replacements pass.
Canonical issuance additionally requires actual issuer authority and reserve records;
see the [token operations guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md).
