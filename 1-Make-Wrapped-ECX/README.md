# Make Wrapped ECX

Token administration stays outside bridge custody. The bridge transfers existing
inventory; its signer API cannot mint or burn. This Cabal package creates classic SPL mints and creates/updates fungible Metaplex metadata. It prepares
`MintToChecked` and `BurnChecked` transactions with eight decimals. Its checked
signing command saves validated signed bytes using a dedicated authority key.
`check` performs read-only chain preflight; `submit`
broadcasts only a saved, validated attempt and reconciles it on repeat invocation.

From the repository root:

```sh
cabal run -v0 ecx-token -- configure
# Choose sign; enter network, rpc, maxFeeLamports and attemptFile.
# Fill the placeholders in inputs/mint.json before signing.
cabal run -v0 ecx-token -- sign /private/authority.json 1-Make-Wrapped-ECX/inputs/mint.json
cabal run -v0 ecx-token -- submit /private/authority.json
cabal test ecx-token:token-test --test-show-details=direct -j1
```

The installed executable uses the same interface: `ecx-token configure` takes no
key; `ecx-token sign secretKey inputs/mint.json` takes the key and transaction
request explicitly. Other operations take `COMMAND KEYFILE`.
Configuration prompts save `ecx-token.json` in the working directory, retaining
settings for other commands. Enter accepts an existing value. Setup does not read
a key, contact RPC, sign or broadcast. The file is atomically replaced with private
permissions; protect it because RPC URLs may contain credentials. The key file
remains a separate standard 64-byte Solana keypair JSON array, with no settings.
Paths resolve from the working directory. The key argument is used only by
`sign`, `recover` and `keygen`; other commands do not open it. `keygen` treats it
as the new output path and does not need configuration.

Configure each command before its first use when its required fields are missing.
The sign settings also cover submit and status; no network or fee ceiling
is silently selected. `maxFeeLamports` is a canonical positive integer string,
for example `10000`. Request/prepared/signed-attempt files retain their existing
formats and validation. To submit a recovered child, configure `attemptFile` to
the saved `.retry` path. Configuration never changes an already signed attempt.

[inputs/mint.json](inputs/mint.json) is a mint-request template. Replace its public
authority, mint, destination **token account** and blockhash placeholders with
values from the intended network. The supplied key must control that mint.
`100000000` base units means one wrapped ECX with eight decimals. The template is
deliberately not executable until filled in; it grants no canonical mint authority.
`sign` builds and validates the unsigned transaction through the safe DSL before
the critical signing operation performs live checks and saves it. It never broadcasts.
Optional `prepare` and `check` still support inspecting an unsigned transaction:
configure `requestFile` for prepare and `preparedFile` for check.

Mint/burn requests have exactly seven fields:

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
mint address with `cabal run -v0 ecx-token -- address KEYFILE` after configuring
`owner` (the authority) and `seed`. The seed is a
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

Create separate standard Solana keypair files with
`cabal run -v0 ecx-token -- keygen /absolute/private/new-key.json`. The parent must
already be owned and private. The critical evaluator uses the cryptographic random
source, writes the 64-byte CLI-compatible keypair as mode-0600 JSON, synchronizes
file and directory, and returns only the public key. It refuses existing files.
Back up these keys; repeating key generation does not recover an earlier identity.
Keep issuance, custody and tester/LP identities separate. Fund each required fee
payer explicitly from your wallet or the real Devnet faucet.

Derive a classic associated token account with
`cabal run -v0 ecx-token -- associated-address KEYFILE` after configuring `owner`
and `mint`. To provision it, use a
request with exactly `protocol: 1`, `verb: "associated"`, `authority` (fee payer),
`mint`, `account` (derived address), `owner`, `rent` and `blockhash`. `rent` is the
positive decimal lamport result of `getMinimumBalanceForRentExemption(165)` on the
selected network. Pass this request through the same prepare/check/sign/submit
commands. Owners must be ordinary on-curve public keys; the payer may be the owner.
The SDK derives the canonical address and uses idempotent creation. Haskell checks
the complete instruction and writable roles independently. Preflight accepts an
absent account or an initialized account with matching owner/mint and no freeze,
delegate or close authority. Existing accounts need no further rent. Finalization
checks that payer debit is at most the saved rent allowance plus the network fee.
No account is closed, reassigned or funded through an arbitrary transfer operation.

Metadata uses the same prepare/check/sign/submit sequence. Derive its standard
Metaplex PDA with `cabal run -v0 ecx-token -- metadata-address KEYFILE` after
configuring `mint`. The request has
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
identity; signing repeats those checks on the selected chain.
Do not use custody keys for administration.

`sign` takes the transaction-request JSON file, builds its unsigned transaction
through the safe evaluator, and validates its entire message again.
It then captures a finalized payer-history anchor and fresh blockhash on the selected
network, changes only the request's blockhash, rebuilds and preflights the message,
and checks the standard 64-byte Solana CLI keypair against the requested authority.
The key must be an owned regular mode-0600 file; key and output directories must
be owned, private directories. The critical evaluator signs with Ed25519, verifies
the signature, and atomically publishes the complete mode-0600 record after syncing
its bytes. The file and parent directory are synchronized before its transaction ID
is returned. Existing files are refused. The record retains the genesis, fee cap,
canonical absolute path, history anchor and validity window; it is not proof of
submission or finalization. `check`, signing and `submit` verify the selected Devnet/mainnet genesis
through HTTPS, classic SPL layouts, decimals, freeze/delegate/close authorities,
issuance authority or burn ownership/balance, fee payer, supply bounds, current fee
against the explicit lamport ceiling, and unsigned simulation. Minting does not
prove reserve backing. Canonical issuance still needs issuer approval.

`submit` first validates the saved signature and request, then checks historical
signature status. Existing pending work is reported without sending; finalized work
must match the exact saved transaction bytes and fee ceiling. Otherwise it repeats
preflight and sends those bytes with RPC retries disabled. A transport error is an
unknown outcome: retain the file and rerun `submit` with that same file. `submitted`
is not finality. State is the immutable signed attempt family plus the real chain,
not a mutable local success flag. Tracked submission requires the saved network and
fee cap and refuses an ancestor that already has a valid successor.

For a tracked attempt whose outcome needs recovery:

```sh
cabal run -v0 ecx-token -- configure
# Choose recover; enter rpc, verifierRpc and the parent attemptFile.
cabal run -v0 ecx-token -- recover /private/authority.json
cabal run -v0 ecx-token -- configure
# Choose submit; set attemptFile to the saved child (new-attempt.json.retry).
cabal run -v0 ecx-token -- submit /private/authority.json
```

`recover` never broadcasts. Two independently operated HTTPS providers must establish
either the same finalized failed transaction or expiry and complete absence through
the saved history origin. Distinct hostnames are enforced; choosing independent
operators remains your responsibility. Unavailable, truncated, pending, successful
or disagreeing evidence is refused. Recovery preserves every operation field and
the original fee cap; it changes only the blockhash after collecting a new context
and repeating preflight. It saves the direct child as `ATTEMPT.retry`. Repeating
recovery returns that same validated child's ID without creating another attempt.
There are at most eight generations, including the original.

All ancestors must remain at their saved paths. Each child binds the raw predecessor
file hash, immutable intent and root. A protected OS family lock serializes signing,
recovery and submission across CLI processes. Copying an attempt elsewhere cannot
start another branch. Preserve the `.lock` file; never delete it while a process may
be active. These files and locks do not exclude a second host holding copied keys;
keep one administration authority active.

A crash during exclusive publication can leave the complete attempt and its
`.pending-*` staging name as two links to the same inode. Reads refuse that state.
With all family processes stopped, inspect the owned mode-0600 files and confirm
the identical inode before removing only its staging link; retain the attempt and
lock file. A partial staging file alone grants no submission authority. Preserve
uncertain files for inspection; do not sign the same intent into a new family.
The two-provider checks rely on honest, complete RPC history; they are not a
cryptographic proof of nonexecution. Fee caps apply to each attempt, so failed
generations can incur additional fees.

Legacy three-field saved attempts remain readable by `status` and usable for exact
`submit`. Automatic recovery refuses them because their original history and
validity context was not recorded. The old offline `sign PREPARED KEY OUTPUT` CLI
form is removed. New signing requires network, HTTPS RPC and a fee ceiling.

For inspection without any possibility of sending, use
`cabal run -v0 ecx-token -- status KEYFILE` with configured `network`, `rpc` and
`attemptFile`.
The safe DSL verifies the archived signature/request and network, then reports
`pending`, `finalized`, `failed`, `unseen` or `expired-unseen`. Finalized results
must match the archived bytes. Missing history, even with an expired blockhash,
does not prove nonexecution or authorize a replacement. Fee limits remain
submission checks; neither command certifies reserve backing.

Every CLI operation enters [Token/Operation.hs](Token/Operation.hs) as a
constrained existential `Request s a`. Its `Operation` dictionary resolves to a
closed `DSL s a`, retaining the result type and safe/critical severity. Separate
evaluators dispatch preparation/preflight versus key generation/signing/submission.
The DSL constructors are hidden; no request supplies arbitrary IO or callbacks.
This matches the bridge and pool request pattern without exposing administration
over HTTP. Lower-level evaluators remain library exports for composition; this
type boundary does not replace separate OS credentials.

Trace [Token.hs](Token.hs): a closed `Safe` operation invokes the pinned SDK through
`ecx_token_prepare_v1`, then Haskell independently validates the complete message.
The safe FFI entry point accepts no keys or generic instructions.
[Token/Signing.hs](Token/Signing.hs) owns key generation and pure archive validation.
[Token/Network.hs](Token/Network.hs)'s critical interpreter owns the private signing
helper, reached after network preflight and recovery validation. Signing is not a
public offline operation. SDK buffers are bounded and caller-owned.
The separate custody transfer entry point retains its old protocol.
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

The new mint's tester ATA, `Cdyg4e8nyuxxnLnwsb4R7PagtCzLPrbTv8hA3drhKeAU`, was
created and used for a one-base-unit issuance/burn round trip on real Devnet:

- Account: `5uMsuYGaTH6k8fch1VFqSVmo9xj23Vy9fMNkMMnY5EXcHobxRDdQ8Xu4LvmykUdy6yDYQUfDCTWrJfLDUirLbULD`
- Mint: `3a8Bu8ta5mggCw6xcDqHoyUKfVFWkHedrjSZs8cj9cLR6LaSTGy1ktMrb63vxhMQEFoHA99fTuUwY97ztx3iqBcW`
- Burn: `2u1FhizTSRbDv94MEodxcPKZ2fH3fRikNitwtQw3L21DcNkc758vCrHNmRcMEuGh2knGymon4htKsg435zMvYpRS`

Finalized readback and saved-attempt replay verify the account identity and supply
returning to zero. The old standalone Rust setup example is retired; its historical
source remains in Git and private keys/attempts remain untouched. Its one-shot
key generation and automatic SOL transfers are replaced by explicit key generation,
funding, and individual durable token operations above.

Wrong-network, plain-HTTP and inadequate-fee-ceiling submissions were refused.
No canonical administration acceptance is claimed.
Protocol references: [Solana minting](https://solana.com/docs/tokens/basics/mint-tokens)
and [burning](https://solana.com/docs/tokens/basics/burn-tokens).

Bounded recovery has offline codec, signature, lineage, idempotence and refusal
tests. Real Devnet expiry recovery also passed using Solana's public RPC and
OnFinality: one saved successor, idempotent recovery, superseded-parent refusal,
finalized mint of one base unit and exact replay. A subsequent checked burn restored
the original supply and tester balance. The finalized-failure branch has offline
evidence; this run does not establish canonical administration acceptance. See the
[release review](../2-Wrap-Unwrap-Server/docs/RELEASE-REVIEW.md) for transaction IDs.
Burn expiry recovery subsequently passed against the same two Devnet providers:
one saved successor, identical repeated recovery, refused parent and finalized
saved-byte replay. A separate checked mint restored the single burned base unit;
ending supply and tester balance matched their initial values exactly.
Canonical issuance additionally requires actual issuer authority and reserve records;
see the [token operations guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md).

ATA provisioning accepts initialized classic SPL mints with any valid decimal
count and no freeze authority, including six-decimal Orca Devnet USDC. Mint/burn
and bridge-token metadata operations retain their eight-decimal policy. Devnet
USDC ATA creation and saved-attempt replay have passed; a six-decimal mint request
is still refused by account-schema validation. See the pool README for transaction
identifiers and the separately funded liquidity workflow.

## Read-only token policy

```sh
cabal run ecx-token:exe:ecx-token -- configure
# Choose inspect-policy and enter the network, RPCs, mint and expected authorities.
cabal run ecx-token:exe:ecx-token -- inspect-policy KEYFILE
```

Use `mainnet` explicitly for a mainnet read, or `revoked` for an approved absent
mint authority. This is a safe existential request resolved through the token DSL;
it does not sign, submit or activate custody. It checks the actual genesis and
finalized classic SPL mint/account layouts, eight decimals, initialization,
freeze/delegation/close authority, expected identities and canonical integer units.
Both provider responses must agree on supply and custody inventory; their finalized
slots are reported separately. Distinct normalized HTTPS hostnames are mandatory;
the operator must still choose independently operated providers.

The old Python `check-token-policy` is removed. Account validation is shared with
token preflight rather than implemented twice. The affected production files total
370 → 318 lines across 3 → 2 files; tests use the existing QuickCheck module.
A read-only Devnet check through Solana's public RPC and OnFinality passed for
mint `Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM`: both reported supply
200,000,000,000 and custody 100,000,050,634 base units at finalized slots
507110525/507110544. This is not issuer approval, backing proof or canonical adoption.
