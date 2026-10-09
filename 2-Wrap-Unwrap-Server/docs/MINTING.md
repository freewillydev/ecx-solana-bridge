# Token minting and offline signing

Build `ecx-token` using [the source build guide](LOCAL-DEVELOPMENT.md).
These administration commands are separate from the bridge installer.

Run the commands below from `1-Make-Wrapped-ECX`.
`secretKey` is your existing mint-authority keypair file; keep it private and
outside Git, with mode `0600` in an owned `0700` directory. The authority must
control the mint and have SOL for transaction fees.

1. Fill in [inputs/mint.json](../../1-Make-Wrapped-ECX/inputs/mint.json): mint-authority public key, wrapped
   ECX mint, destination **token account** and amount. The signer obtains the
   blockhash automatically. Amounts use eight decimals: `100000000` means one token.

2. Configure signing:

   ```sh
   ecx-token configure
   ```

   Choose `sign`. Enter `network` (`devnet` or `mainnet`), your HTTPS `rpc`,
   `maxFeeLamports` (press Enter for `10000`, or retain your saved value) and
   `Transaction record file` (press Enter for `.ecx-token/token-transaction.json`).
   Configure creates `.ecx-token/` in your current directory with owner-only
   permissions (`0700`), saves its configuration there with mode `0600`, and stores
   the default transaction path as an absolute path. An existing unsafe directory
   or symlink is refused. This directory is ignored by Git.

   The transaction record contains signed bytes and recovery information, not your
   private key. Use the same file for submit/status/recover; choose a new filename
   for each new transaction. Existing records are not moved or overwritten.
   The field remains `attemptFile` for compatibility. Existing settings are retained;
   a legacy `./ecx-token.json` is read if no private configuration exists, and the
   next configure saves a private copy (the legacy file is left untouched).
   Invalid input displays a message and repeats the prompt. Enter keeps a shown
   default; empty required fields are requested again. Configuration does not need
   or read your key.

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

## Offline signing and USB submission

Build/install `ecx-token` on both computers before disconnecting the signing computer.
Only the online computer needs RPC configuration. This uses ordinary recent-blockhash
transactions for ordinary `mint` requests, which expire after about 150 slots.
For USB/off-site signing use **`nonce_mint`** instead: its durable nonce remains valid
until consumed or changed. [Solana documents nonce behavior here](https://solana.com/docs/core/transactions/durable-nonces).
The nonce authority must be the same key as the mint authority and fee payer.
Only minting has durable-nonce support; other token commands retain recent blockhashes.

Before the first offline mint, provision a nonce account on the online computer:

```sh
ecx-token configure              # choose nonce-address; owner = online payer; seed = offline-mint
ecx-token nonce-address unused   # prints the derived public nonce-account address; no key read
ecx-token configure              # choose nonce-rent; enter network and HTTPS RPC
ecx-token nonce-rent             # prints the required rent in lamports
```

Fill in [inputs/create-nonce.json](../../1-Make-Wrapped-ECX/inputs/create-nonce.json): `authority` is the
online payer, `nonceAccount` is the derived address, `owner` is the offline mint
authority, and `seed` matches the address derivation. Set `rent` to the returned
value (the template's 1447680 is checked against the actual network). Configure
`sign` with a new private transaction record and submit using the existing flow:

```sh
ecx-token configure
ecx-token sign /private/online-payer-key inputs/create-nonce.json
ecx-token submit /private/online-payer-key
```

Wait for `finalized`. This separate payer funds the nonce rent and creation fee;
it need not hold the offline mint key. The offline mint authority also needs SOL
for mint transaction fees. Keep one outstanding mint intent per nonce account.

1. On the offline computer, create a private working directory:

   ```sh
   mkdir -m 700 offline-token
   cd offline-token
   ```

   Save the exported **Solana account private key** in `phantom-export.txt` here,
   with mode `0600`. [Phantom's export instructions](https://help.phantom.com/articles/view-or-export-your-recovery-phrase-or-private-keys-in-phantom-25334064171795)
   describe selecting the account and network. Import accepts a base58-encoded
   64-byte keypair, not a recovery phrase, Ethereum key or hardware-wallet export.
   Do not paste secrets into command arguments or transfer them back to the server.
   An existing Solana CLI 64-number JSON keypair can be used directly without import.
   `enter-key` requires a real terminal, creates no temporary export file, restores
   terminal echo on failure, and refuses to overwrite an existing key. Choose one
   import command, not both.

   ```sh
   chmod 600 phantom-export.txt
   ecx-token import-key phantom-export.txt secretKey
   # Or enter it directly in a terminal, with input hidden:
   ecx-token enter-key secretKey
   ```

   Check the printed public key against the intended mint authority. Import checks
   the public half against the private seed and writes an owner-only JSON keypair;
   it does not create a new wallet or change authority on chain. Keep a secure backup.

2. On the online computer, fill in [inputs/nonce-mint.json](../../1-Make-Wrapped-ECX/inputs/nonce-mint.json), then configure
   `prepare-offline` with `network`, HTTPS `rpc` and `maxFeeLamports`:

   ```sh
   ecx-token configure
   ecx-token prepare-offline inputs/nonce-mint.json .ecx-token/prepared.json
   ```

   This reads the initialized nonce, validates the actual mint/account/authority and
   fee limit, simulates the unsigned transaction and saves it. Copy `prepared.json`
   onto the USB stick and then into `offline-token/` on the offline computer.

3. Sign on the offline computer:

   ```sh
   ecx-token sign-offline secretKey prepared.json signed-mint.json
   ```

   Review the displayed operation, authority, mint, destination token account and
   amount against your own records, then type `sign`. Amounts are integer base units
   (100000000 = one token). The signer validates the exact instructions and signature
   locally; it neither loads RPC settings nor contacts the network. It cannot establish
   current chain state, network identity, freshness or fees offline. Imported keys and
   signed records require an owned `0700` parent directory; existing files are never
   overwritten. Transfer **only `signed-mint.json`** back via USB.

4. On the online computer running the bridge, copy the signed record into
   `.ecx-token/`, set its permissions and submit it with the same network/RPC/fee
   configuration. This is a separate token-administration CLI operation; the bridge
   service does not receive the mint-authority private key.

   ```sh
   chmod 600 .ecx-token/signed-mint.json
   ecx-token submit-file .ecx-token/signed-mint.json
   ```

   Run the same command again to check/rebroadcast the **identical bytes** until
   `finalized`; `submitted` or `pending` does not mean finality. Submission verifies
   the saved intent/signature, selected network, current authority, fees and simulation.
   The file contains no private key, but anyone holding it can broadcast that mint.
   Retain it as the transaction record. Offline records do not contain the online
   recovery-history proof, so `recover` deliberately refuses them. If it expires or a
   send outcome is uncertain, establish the original outcome before authorizing a new
   mint; changing the nonce or blockhash and signing again could mint twice. An executed
   nonce transaction advances its nonce even if the mint instruction fails. A consumed
   nonce with no verifiable transaction outcome is a refusal, never permission to retry
   with a fresh signature. After a finalized result, prepare the next mint from the
   account's new nonce and use new filenames. Use `submit-file` for nonce status;
   the ordinary blockhash-based `status` command deliberately refuses nonce records.

The shared token implementation is in `2-Wrap-Unwrap-Server/administration/`.
This command and fresh bridge ATA setup use the same closed operations; the bridge
worker and dedicated signer do not depend on this administration component.
