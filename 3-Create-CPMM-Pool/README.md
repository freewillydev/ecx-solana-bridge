# Orca liquidity tools

To run the bridge, use the **[`.run` installer](../README.md)**. Pool creation and
liquidity management are optional, separate operations using separate keys and capital.

`ecx-pool` can inspect/create supported full-range Orca pools, create positions,
deposit/withdraw liquidity and collect fees. It does not automatically compound fees
or guarantee a Jupiter route.

With the [pinned source toolchain](../2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md),
run from the repository root:

```sh
cabal build exe:ecx-pool -j1
cabal run -v0 ecx-pool -- inspect devnet HTTPS_RPC POOL MINT_A MINT_B
```

Choose `devnet` or `mainnet` explicitly. Signed operations need fee/spending limits;
retain each transaction record and verify finality before replacing an uncertain attempt.

[Commands, request formats and tested examples](../2-Wrap-Unwrap-Server/docs/LIQUIDITY.md) ·
[Token and treasury boundaries](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md)
