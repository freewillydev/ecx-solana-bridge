# Make Wrapped ECX

Token administration stays outside bridge custody. The bridge transfers existing
inventory; its signer API cannot mint or burn. This Cabal package creates classic SPL mints and creates/updates fungible Metaplex metadata. It prepares
`MintToChecked` and `BurnChecked` transactions with eight decimals. Its separate offline signing command saves validated signed bytes using
a dedicated authority key. `check` performs read-only chain preflight; `submit`
broadcasts only a saved, validated attempt and reconciles it on repeat invocation.

From the repository root:

```sh
cabal run -v0 ecx-token -- prepare /absolute/path/request.json > /absolute/path/prepared.json
cabal run -v0 ecx-token -- check devnet https://api.devnet.solana.com 10000 /absolute/path/prepared.json
cabal run -v0 ecx-token -- sign /absolute/path/prepared.json /private/authority.json /private/new-attempt.json
cabal run -v0 ecx-token -- submit devnet https://api.devnet.solana.com 10000 /private/new-attempt.json
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

Mint creation uses `verb: "create"` with exactly `protocol`, `verb`, `authority`,
`mint`, `seed`, `rent` and `blockhash`. `rent` is a positive decimal string of
lamports, equal to the actual RPC rent exemption for an 82-byte mint. Derive the
mint address with `cabal run -v0 ecx-token -- address AUTHORITY SEED`. The seed is a
public nonempty UTF-8 string of at most 32 bytes. This is Solana's standard System
Program `CreateAccountWithSeed` address, not a new private key or custody recovery
scheme. The same authority, seed and Token Program always identify the same mint.

Creation atomically funds the previously absent account and initializes eight
decimals, the specified mint authority and no freeze authority. Supply starts at
zero. The authority also pays rent and the transaction fee; only that authority
signs. `prepare`, `check`, `sign` and `submit` use the same workflow as mint/burn.
Preflight refuses an existing account or changed rent rather than overwriting or
refunding it. Haskell checks the address derivation and both exact instructions
independently of the SDK.

Metadata uses the same prepare/check/sign/submit sequence. Derive its standard
Metaplex PDA with `cabal run -v0 ecx-token -- metadata-address MINT`. The request has
exactly `protocol: 1`, `verb: "metadata"`, `authority`, `mint`, `blockhash` and:

```json
"metadata": {
  "create": true,
  "address": "THE_DERIVED_METADATA_PDA",
  "name": "Wrapped ECX",
  "symbol": "wECX",
  "uri": "",
  "max_cost": "20000000"
}
```

Use `create: false` to update existing metadata. `name` and `symbol` are nonempty
UTF-8 strings limited to 32 and 10 bytes; `uri` is at most 200 bytes and either empty,
HTTPS or IPFS. An empty URI publishes no off-chain JSON or image. Supply a real,
reviewed metadata URI for deployment; the tool does not host or fetch it.
The authority is the fee payer and initial/update authority. Creation requires
that it also controls mint issuance; updates verify the existing metadata authority
and mint. Both retain zero royalties and no creators/collection/uses. Creation is
mutable; updates preserve authority and mutability. Authority transfer, freezing and
NFT metadata are deliberately outside this fungible-token operation.

`max_cost` is a positive decimal lamport ceiling for the payer's total debit,
including Metaplex charges and rent, separate from the CLI's network-fee ceiling.
Preflight checks the simulated metadata fields and payer debit, conservatively
adding the network fee even if simulation has already deducted it. Submission
checks the actual finalized payer debit. These are preflight/reconciliation checks,
not an on-chain spending-limit instruction; an upgrade to the external program or
changed chain state between simulation and execution can still change its charges.

The encoder uses our existing Solana SDK through bounded FFI and the published
[Metaplex V3 creation](https://docs.rs/mpl-token-metadata/5.1.1/mpl_token_metadata/instructions/struct.CreateMetadataAccountV3.html)
and [V2 update](https://docs.rs/mpl-token-metadata/5.1.1/mpl_token_metadata/instructions/struct.UpdateMetadataAccountV2.html)
wire formats. Haskell independently checks all instruction bytes, account roles and
message fields. Golden transaction hashes were generated using the official 5.1.1
builders; no second Solana SDK or Metaplex runtime dependency is added.

Output contains the request and `unsignedTransaction` as base64. A transaction
preview does not prove account ownership, available funds, reserves or network
identity; independently verify those on the intended chain before offline signing.
Do not use custody keys for administration.

`sign` takes the exact output of `prepare`, validates its entire message again,
and checks the standard 64-byte Solana CLI keypair against the requested authority.
The key must be an owned regular mode-0600 file; key and output directories must
be owned, private directories. The critical evaluator signs with Ed25519, verifies
the signature, exclusively creates the output at mode 0600, and synchronizes both
file and directory before returning its transaction ID. Existing files are refused;
a failed write is retained for inspection. This record is not proof of submission
or finalization. Do not regenerate an attempt to retry a future uncertain send.
Offline signatures do not bind a genesis hash; intended-chain validation remains
required at submission. `check` and `submit` verify the selected Devnet/mainnet genesis
through HTTPS, classic SPL layouts, decimals, freeze/delegate/close authorities,
issuance authority or burn ownership/balance, fee payer, supply bounds, current fee
against the explicit lamport ceiling, and unsigned simulation. Minting does not
prove reserve backing. Canonical issuance still needs issuer approval.

`submit` first validates the saved signature and request, then checks historical
signature status. Existing pending work is reported without sending; finalized work
must match the exact saved transaction bytes and fee ceiling. Otherwise it repeats
preflight and sends those bytes with RPC retries disabled. A transport error is an
unknown outcome: retain the file and rerun `submit` with that same file. `submitted`
is not finality. An expired blockhash is not permission to regenerate an attempt;
expiry/absence review and a new approval are still manual. State is the immutable
signed attempt plus the real chain, not a mutable local success flag.

Trace [Token.hs](Token.hs): a closed `Safe` operation invokes the pinned SDK through
`ecx_token_prepare_v1`, then Haskell independently validates the complete message.
The safe FFI entry point accepts no keys or generic instructions.
[Token/Signing.hs](Token/Signing.hs) owns the separate closed critical evaluator;
[Token/Network.hs](Token/Network.hs) separates safe preflight from critical
submission. SDK buffers are bounded and caller-owned. The separate custody transfer entry point retains its old protocol.
The shared chain library is reused by this package; customer handlers still have no
chain, store or signer dependency.

QuickCheck compares the real SDK against Haskell validation across both operations,
including integer boundaries and changed-operation/account/amount rejection. Both
unsigned operations passed actual Devnet simulation against the existing test mint
`Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM`.
The existing custody FFI preview and bridge QuickCheck suite also passed.
Offline signing checks use disposable fixture keys and verify the actual Ed25519
signature, exact-file retention and rejection of changed terms, wrong authority,
corrupt public-key halves, out-of-range key bytes, unsafe permissions and symlinks.
A real one-base-unit mint/burn round trip also finalized on Devnet using the separate
test authority and tester account; each transaction cost 5,000 lamports. Supply and
tester balance changed by exactly +1 then -1; repeated submission returned the same
finalized result. Transactions:

- Mint: `5Z6BGtzNaNsBjMZcrAhNAcqXuxFGShYZ8q7CbunVhbkMgEP7rV9jMTCMf8gTBinEj8y9dpKwhSVQcb6E9HHoQsVu`
- Burn: `2gYsH21TZdubWjXSaXYoYUmcVFQrXpKXr3Mt3ApmWhSiyi8TRp56UReLLdwfKAL1xDsXVNiU8XiV8js3Z8ac6nBK`

Mint creation also finalized on Devnet at
`EGiiQQYXtQLing36xCFnNCHwBfuP2ddSkRTo6TDRQFHT`, transaction
`4SfGs4wGhEdAeHX3DPLj8R699G9iMfYaRdNXzjoudbZiDAyhGk2oSvhWFNqfcxe3V4uLYpU3v9JHJajpLDiDCcGd`.
Readback verified eight decimals, expected authority, zero supply and no freeze
authority. Exact replay succeeded; another creation preflight refused the existing
mint. No bridge deployment was switched to this new test mint.

Metadata creation and update also finalized on that new Devnet test mint, with
exact saved-attempt replay and matching on-chain fields:

- Create: `4ertJ4k76EGjegSSZsmo5ayHfgZcFe2Ti4nQNhm3Wwash97mGEcqzUYrfbHPS8DZW7LhiSKZMiRY4731gATKxhfQ`
- Update: `5UoLMgvamWnxeydKHDAbAXLKHRiaDD1sTfdmqu6J1urV6h7FKTkx4tTNyzXciMaGeGC7LVdiLdUZgxWgrqMdiT8b`

The test deliberately uses an empty URI. Existing-account creation, wrong mint,
wrong update authority and insufficient total-cost ceiling were refused. QuickCheck
covers official SDK golden messages, both operations, changed fields/roles,
UTF-8 byte bounds and the full maximum-length instruction.

Wrong-network, plain-HTTP and inadequate-fee-ceiling submissions were refused.
No canonical administration acceptance is claimed.
Protocol references: [Solana minting](https://solana.com/docs/tokens/basics/mint-tokens)
and [burning](https://solana.com/docs/tokens/basics/burn-tokens).

Remaining: standalone token-account provisioning, automatic bounded
expiry recovery and canonical administration acceptance. Keep the old Devnet setup example until those replacements pass.
Canonical issuance additionally requires actual issuer authority and reserve records;
see the [token operations guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md).
