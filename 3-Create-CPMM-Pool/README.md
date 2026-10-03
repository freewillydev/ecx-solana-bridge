# Orca full-range liquidity

Liquidity uses separate operator capital and keys, outside bridge custody. The
root-Cabal `ecx-pool` CLI currently derives canonical addresses and verifies existing
full-range pools and prepares unsigned classic Splash-pool creation. Signing and
submission, position ownership/funding and fee collection are
still unfinished; inspection is not a substitute for those operations.

```sh
cabal run -v0 ecx-pool -- prepare devnet REQUEST.json
cabal run -v0 ecx-pool -- address devnet MINT_A MINT_B FEE_TIER_INDEX
cabal run -v0 ecx-pool -- inspect devnet HTTPS_RPC POOL MINT_A MINT_B
cabal test ecx-pool:pool-test --offline -j1 --test-show-details=direct
```

Choose `devnet` or `mainnet` explicitly. Mints must be in raw public-key byte order,
not alphabetical order. The address command takes the actual fee-tier index;
it is not necessarily the tick spacing. Inspection reads that index from the pool,
independently derives its PDA through the existing Solana SDK and verifies it.

`Pool.hs` owns a closed safe DSL. It has no signer, private-key, database, broadcast
or custody capability. It uses the shared bounded HTTPS RPC adapter and a narrow
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

Preparation does not prove a blockhash is live, accounts are available, or funds
cover rent/fees. Chain preflight, protected signing and saved-byte submission are
still required before any transaction may be sent. Persisted preparations must
also have their derived addresses rechecked before signing.

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
wire-contract tests, not evidence of a finalized pool creation.

## Remaining implementation

Creation must bind the selected real fee tier and enforce explicit price/cost limits.
Orca requires independent vault signatures in addition to the payer: implement a
closed pool signing operation, keeping the bridge's one-signature custody protocol
unchanged. Then add tick-array initialization, full-range position creation,
liquidity deposit/withdrawal and fee collection with saved-attempt recovery and
real Devnet acceptance. Adaptive-tier initialization can have additional authority
requirements; do not assume the published tier is permissionless.

LP ownership/lock, fee reinvestment, issuer approval, reserve backing, deployed
program verification and actual Jupiter routes are separate checks. The pool
snapshot proves none of these. See the existing
[liquidity guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md#configure-trading-separately)
for the broader operator requirements.
