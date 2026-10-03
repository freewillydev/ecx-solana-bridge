# Orca full-range liquidity

Liquidity uses separate operator capital and keys, outside bridge custody. The
root-Cabal `ecx-pool` CLI derives canonical addresses and verifies existing
full-range pools, creates classic Splash pools and prepares full-range positions.
Position signing/submission is verified on Devnet. Unsigned liquidity deposit,
withdrawal and fee-collection preparation is implemented; its preflight and funded
execution remain unfinished.

```sh
cabal run -v0 ecx-pool -- prepare devnet REQUEST.json > prepared.json
cabal run -v0 ecx-pool -- check HTTPS_RPC MAX_FEE MAX_COST prepared.json
cabal run -v0 ecx-pool -- sign HTTPS_RPC MAX_FEE MAX_COST prepared.json PAYER_KEY VAULT_A_KEY VAULT_B_KEY NEW_ATTEMPT.json
cabal run -v0 ecx-pool -- submit HTTPS_RPC ATTEMPT.json
cabal run -v0 ecx-pool -- address devnet MINT_A MINT_B FEE_TIER_INDEX
cabal run -v0 ecx-pool -- inspect devnet HTTPS_RPC POOL MINT_A MINT_B
cabal run -v0 ecx-pool -- prepare-position devnet POSITION_REQUEST.json > position.json
cabal run -v0 ecx-pool -- check-position HTTPS_RPC MAX_FEE MAX_COST position.json
cabal run -v0 ecx-pool -- sign-position HTTPS_RPC MAX_FEE MAX_COST position.json PAYER_KEY POSITION_MINT_KEY NEW_ATTEMPT.json
cabal run -v0 ecx-pool -- prepare-liquidity devnet LIQUIDITY_REQUEST.json > liquidity.json
cabal test ecx-pool:pool-test --offline -j1 --test-show-details=direct
```

Choose `devnet` or `mainnet` explicitly. Mints must be in raw public-key byte order,
not alphabetical order. The address command takes the actual fee-tier index;
it is not necessarily the tick spacing. Inspection reads that index from the pool,
independently derives its PDA through the existing Solana SDK and verifies it.

`Pool.hs` owns a closed safe DSL. It has no signer, private-key, database, broadcast
or custody capability. It uses the shared bounded HTTPS RPC adapter and narrow
read-only FFI entry points for PDA derivation and unsigned instruction construction. No additional SDK dependencies are
introduced. Inspection verifies:

- Network genesis, fixed official Orca program and the network's config address.
- Canonical pool PDA, exact account layout/discriminator and supplied mint pair.
- Full-range-only tick spacing, exact integer price/tick fields and fee units.
- Classic SPL mint layouts and initialized vaults bound to the pool and each mint,
  without delegated or close authority. Wrapped-SOL vaults are supported.
- Pool, configuration, mints and vaults from one finalized multi-account snapshot.
  Protocol fees owed cannot exceed the corresponding vault balances.

Amounts, liquidity and the Q64.64 square-root price are emitted as decimal strings.
The output distinguishes fee-tier index, tick spacing, base fee and adaptive-fee
status. An adaptive tier's base fee is not an executable swap quote. Pool fees,
protocol fees and the bridge's 1% wrapping/unwrapping charges are different quantities.
Mint/freeze authorities are reported, not implicitly approved.

Account layouts, program/config identities and PDA seeds follow Orca source commit
[`f4b99e79e7140f3917e4ce81a2e8ad06ccdf8ce4`](https://github.com/orca-so/whirlpools/tree/f4b99e79e7140f3917e4ce81a2e8ad06ccdf8ce4/rust-sdk/client/src).
Full-range-only means tick spacing at least 32768, per the pinned
[tick constants](https://github.com/orca-so/whirlpools/blob/f4b99e79e7140f3917e4ce81a2e8ad06ccdf8ce4/rust-sdk/core/src/constants/tick.rs).
The current verifier covers classic SPL assets and the original mutable Orca
program. It does not support Token-2022 assets or the separate immutable deployment.

## Creation request

`prepare` takes exactly `payer`, `mintA`, `mintB`, `vaultA`, `vaultB`,
`sqrtPriceX64` and `blockhash`. All are strings; the price is a canonical integer
representing the square root of the raw-unit B/A price, multiplied by 2^64.
Mint decimal differences must therefore be accounted for before choosing it.
The vaults are two new, distinct keypair public keys. Use separate liquidity capital.
The command does not open private keys or access a network.

The current creation path fixes the ordinary Splash tier and tick spacing to 32896.
It derives the pool and fee-tier PDAs through the SDK, builds classic InitializePool,
and independently checks its complete message in Haskell: three zero signatures,
all account identities and permissions, one instruction, exact price and blockhash.
This does not initialize tick arrays or deposit liquidity. The published adaptive
1034 tier remains supported for inspection, not creation.

`check` rederives the complete preparation and verifies HTTPS/genesis, the real
fee tier, initialized classic mints, absent pool/vaults and system-owned payer.
It reads rent and fee quotes, then simulates the exact zero-signature transaction
without replacing its blockhash. Resulting pool identity, empty vaults, initial
price, fee settings and debit must match. `MAX_FEE` and `MAX_COST` are positive
integer lamports. The reported maximum debit conservatively adds the network fee
even if simulation already deducted it. Quote/simulation success is not a future
execution guarantee.

`Pool.Signing` owns two closed critical operations. Signing repeats preflight,
checks each protected key against its message signer, verifies every signature,
and exclusively saves a mode-0600 attempt with file/directory fsync before returning.
Key and output directories must be private and paths absolute. Token and pool
administration share these file protections through `Bridge.AdminKey`; neither
gets bridge custody authority. New vault keys can be generated with `ecx-token keygen`.

Submission verifies the saved message/signatures and rederives its PDAs. It checks
historical status before any send, repeats preflight only for an unseen attempt,
and sends exactly the archived bytes. A finalized result must match those exact
bytes and the saved fee/total-debit limits. A timeout retains the attempt; run
`submit` again. No command refreshes its blockhash, overwrites an attempt, or
silently signs a replacement. Expired/unresolved attempts require review.

## Full-range position preparation

`POSITION_REQUEST.json` has exactly six string fields: `payer`, `pool`, `mintA`,
`mintB`, `positionMint`, and `blockhash`. The payer also owns the position; the
position mint is a fresh keypair public key, not either pool asset. The supported
tick spacing is 32896, with full-range ticks -427648 and 427648. Preparation derives
the position PDA, ownership ATA and both boundary-array PDAs, and combines two
idempotent dynamic-array initializations with classic `OpenPosition`. Existing
compatible arrays can be reused. No liquidity moves in this transaction.

`Pool.Position` independently checks all three instructions, two zero signatures,
account roles, blockhash and tick bounds. Preflight verifies the real pool and
network, absent position accounts, system payer and fee limit. Exact simulation
must create an empty full-range position and one payer-owned NFT, with no mint or
freeze authority and no token-account delegate/close authority. The conservative
simulated debit must fit `MAX_COST`. `sign-position` repeats those checks and then
uses the same protected signing, exclusive durable save and exact-byte submission
path as pool creation. The closed action distinguishes the two-signature position
transaction from the three-signature pool transaction. Existing pool-attempt files
retain their original format; position attempts carry an explicit operation tag.

Actual Devnet simulation at slot 507074039 passed with conservative debit 8,264,840
lamports; fee limit 1 and cost limit 20,000 were refused. The public simulation is
retained in the existing fixture, with ownership/request/byte-mutation regression
checks. The position was then created and finalized on Devnet:

- Position: `7gadbytE2t3vQs9skcq2EYXkjBGYcGboGeeCHfUavLRT`.
- Transaction: `zPBoKHBhLkurqhuDbwKBXNMifav5wSRDGCuEigB2kaMjPfv4NPBehDTjpAngqGAqUyvz9Z8SVaFz3CDCAV4Jf3c`.
- Readback slot: 507076115; fee 10,000 lamports; total debit 8,254,840 lamports.

Readback verified zero liquidity, both full-range tick bounds, both initialized
boundary arrays, and the payer-owned NFT with removed mint authority. Wrong mint
keys and attempt overwrites were refused. Repeat submission returned the same
finalized result; the previously saved pool creation also remained readable and
finalized. An empty position does not establish funded liquidity or trading.

## Liquidity transaction preparation

`LIQUIDITY_REQUEST.json` contains `verb` (`deposit`, `withdraw`, or `collect`),
`position` (the six-field position request above), `vaultA`, `vaultB`, `liquidity`,
`limitA`, and `limitB`. The last three values are canonical unsigned decimal
strings. Liquidity is Orca's integer liquidity quantity, not a human token amount.
For deposits, limits cap token spending; for withdrawals, they specify minimum
receipts. Both are in each mint's raw base units. Fee collection requires all
three amount fields to be zero and refreshes accrued fees before collecting.

The SDK derives the position/ownership/token-account/boundary-array addresses.
Haskell independently checks the exact account roles, instruction sequence,
blockhash, integer payload and sole zero signature. Deposit/withdrawal each use
one classic SPL Orca instruction; collection uses update-fees followed by collect.
The custody decoder's account limits are unchanged. No new SDK dependencies were
added. Protocol tests cover all three operations, byte mutations, changed accounts
and blockhash, malformed decimals and u128 overflow.

This command only prepares unsigned bytes. It does not prove ownership, available
balances, pool/vault correspondence, current fees or transaction success. Before
signing can be enabled, the liquidity evaluator must verify the actual accounts,
simulate exact token/liquidity deltas within saved cost limits and reuse durable
signing/submission. Funded deposit/withdrawal and fee collection have not passed
real-chain acceptance yet.

## Verified checkpoint

Live read-only acceptance passed for:

| Network | Pool | Tick spacing | Fee-tier index |
| --- | --- | --- | --- |
| Mainnet | `nNKg814Wq3uTkoG4fM8LzvBQv4Fu2iCgKFmK2YmPQzM` | 32896 | 1034 |
| Devnet | `26WuWhkPBhG5d6kZwHBTruLxLvbSe7C62qH21zpisP9c` | 32896 | 32896 |

The published mainnet pair is USDC / `EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq`;
the Devnet pair is wrapped SOL / Orca devUSDC
`BRjpCHtyQLNCo8gqRUr8jtdAj5AjPYQaoqbvcZiHok1k`. Mainnet uses an adaptive tier;
Devnet uses the ordinary Splash tier. Both stored base fees were 10000 millionths
at readback. These are snapshots, not future fee promises.

The public finalized mainnet fixture records its slot and source. QuickCheck uses
that real account data to verify PDA derivation and refusal of wrong network,
identity, owner, executable flag, layouts, disabled mints, invalid vault authority,
frozen/delegated/closable vaults and excessive protocol liabilities. Token and bridge
regressions remain in their existing Cabal suites. Creation checks also reject
wrong-network/request changes and a one-bit mutation at every transaction byte;
the custody decoder rejects the three-signature transaction. These are offline
wire-contract tests, not evidence of a finalized pool creation. The same fixture
also retains an actual Devnet unsigned creation simulation for the separately
created test mint / Orca devUSDC pair. Preflight passed with 6,944,360 lamports rent,
15,000 fee and conservative maximum debit 6,974,360. Real checks refused a fee
limit of 1 and a total-cost limit of 20,000. That simulation preceded the finalized creation below.

The closed signing/submission path then created Devnet pool
`FDL7cuLgL3Yog4B5MJY51eLA9fWqjqm9XFX1vnwdLs9Y`, using the separate test mint
`EGiiQQYXtQLing36xCFnNCHwBfuP2ddSkRTo6TDRQFHT` and Orca devUSDC, with transaction
`tdbzmJadcw3nxqsAKg87aE5no5Jfr68WmrBR2LYeh1uMxaqQQUtunremFGxHyuAqjZsLa31MmXK28TrExKGDF4S`.
Finalized readback at slot 507072063 verified both vaults, zero token balances,
zero liquidity and the requested Q64.64 price 18446744073709551616. Repeating
submission returned the same finalized result. Wrong vault keys were refused;
the signed attempt remained mode 0600 and could not be overwritten. A prior
never-submitted test attempt was preserved after finalized blockhash expiry and
absent transaction/history checks; the CLI did not replace it automatically.
This proves creation only, not funded liquidity or trading.

## Remaining implementation

Creation preflight now binds the real ordinary tier and explicit price/cost limits.
The closed signer supports independent vault signatures in addition to the payer,
keeping the bridge's one-signature custody protocol unchanged. Full-range position
and boundary-array preparation/preflight, signing/submission and finalized ownership readback now pass Devnet
acceptance. Liquidity deposit/withdrawal and fee-collection wire preparation is
implemented; complete actual-account/effect preflight, saved signing/submission
and funded Devnet acceptance. Adaptive-tier initialization can have additional authority
requirements; do not assume the published tier is permissionless.

LP ownership/lock, fee reinvestment, issuer approval, reserve backing, deployed
program verification and actual Jupiter routes are separate checks. The pool
snapshot proves none of these. See the existing
[liquidity guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md#configure-trading-separately)
for the broader operator requirements.
