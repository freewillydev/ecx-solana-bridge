# Mint wrapped ECX

To run the bridge, use the **[`.run` installer](../README.md)**. Minting is a separate,
optional operator tool; it requires the mint authority and SOL for fees.

Build `ecx-token` from the repository root using the
[pinned compiler setup](../2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md):

```sh
ghcup run --ghc 9.14.1 --cabal 3.16.1.0 -- cabal build exe:ecx-token -j1
export PATH="$(dirname "$(ghcup run --ghc 9.14.1 --cabal 3.16.1.0 -- cabal list-bin exe:ecx-token)"):$PATH"
cd 1-Make-Wrapped-ECX
ecx-token configure
ecx-token sign /private/secretKey inputs/mint.json
ecx-token submit /private/secretKey
ecx-token status /private/secretKey
```

Before signing, fill in [mint.json](inputs/mint.json). `100000000` base units means
one token. Configure needs no private key; choose `sign`, the network and HTTPS RPC.
Keep the key outside Git in a private directory. Retain the transaction record and
wait for `finalized`; an uncertain submission is not permission to mint again.

[Minting, key import and offline USB signing](../2-Wrap-Unwrap-Server/docs/MINTING.md).
