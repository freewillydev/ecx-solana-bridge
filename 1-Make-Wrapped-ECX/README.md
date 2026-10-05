# Mint wrapped ECX

Run these commands from `1-Make-Wrapped-ECX` with `ecx-token` on your PATH.
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
   `maxFeeLamports` (for example `10000`) and `attemptFile` (a new absolute path
   inside a private directory). Settings are saved in `ecx-token.json`.
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
