# Mint wrapped ECX

Requires **GHC 9.14.1 and Cabal 3.16.1.0**. Select the pinned tools using the
[compiler setup instructions](../2-Wrap-Unwrap-Server/docs/LOCAL-DEVELOPMENT.md) before building.

Build from the repository root, then put the executable on this shell's PATH:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

git clone https://github.com/emscripten-core/emsdk.git \
  "$HOME/.local/share/ecx-emsdk"

cd "$HOME/.local/share/ecx-emsdk"
./emsdk install 3.1.74
./emsdk activate 3.1.74
source ./emsdk_env.sh
emconfigure ghcup install ghc --set javascript-unknown-ghcjs-9.12.2

ghcup install cabal
cabal update
ghcup run --install --ghc 9.14.1 --cabal 3.16.1.0
ghcup run --ghc 9.14.1 -- cabal build exe:ecx-token -j1
export PATH="$(dirname "$(ghcup run --install --ghc 9.14.1 --cabal 3.16.1.0 -- cabal list-bin exe:ecx-token)"):$PATH"
cd 1-Make-Wrapped-ECX
```

Run the commands below from `1-Make-Wrapped-ECX`.
`secretKey` is your existing mint-authority keypair file; keep it private and
outside Git, with mode `0600` in an owned `0700` directory. The authority must
control the mint and have SOL for transaction fees.

1. Fill in [inputs/mint.json](inputs/mint.json): mint-authority public key, wrapped
   ECX mint, destination **token account** and amount. The signer obtains the
   blockhash automatically. Amounts use eight decimals: `100000000` means one token.

2. Configure signing:

   ```sh
   ecx-token configure
   ```

   Choose `sign`. Enter `network` (`devnet` or `mainnet`), your HTTPS `rpc`,
   `maxFeeLamports` (press Enter for `10000`, or retain your saved value) and
   `Transaction record file` (default `token-transaction.json`). This stores the
   signed transaction and recovery information, not your private key. The default
   is relative to the directory where you run the commands; that directory must
   be owned by you with mode `0700`. When running from this repository, instead
   enter an absolute path inside your existing private directory, for example
   `/private/token-transaction.json`. Use the same file for submit/status/recover;
   choose a new filename for each new transaction. Existing records are not
   overwritten. The configuration field remains `attemptFile` for compatibility.
   Settings are saved in `ecx-token.json`.
   Configuration does not need or read your key.

3. Sign the mint request:

   ```sh
   ecx-token sign /private/secretKey inputs/mint.json
   ```

   This validates the request against the selected network and saves the signed
   transaction at `attemptFile`. It does not submit it.

4. Submit those saved bytes, then check finality:

   ```sh
   ecx-token submit /private/secretKey
   ecx-token status /private/secretKey
   ```

   These commands reuse the saved settings and do not read the key. `submitted`
   is not finality; wait for `finalized`. If submission is interrupted, retain the
   attempt and check its status; do not sign the same mint into a new attempt.
