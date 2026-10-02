# Create CPMM Pool

Liquidity setup belongs here, using separate operator capital and keys.
It is independent of the wrapping service and customer custody.

The existing [liquidity guide](../2-Wrap-Unwrap-Server/docs/TOKEN-OPERATIONS.md#configure-trading-separately)
records full-range pool requirements, the published Orca pool, fee accounting
and route verification. Pool fees and the bridge's 1% conversion fee are separate.

This folder establishes the liquidity boundary; it does not yet contain an
independent Haskell pool creation program. Pool creation, LP ownership and any
fee reinvestment must be verified against the actual selected service and chain.
