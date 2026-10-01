# Operator runbook

This runbook describes the current PostgreSQL Signet/Devnet product. Canonical
betanet/mainnet activation, remote recovery and independent security review remain
release gates. The installer never creates a token or pool and defaults to paused
observation. See [installation](INSTALL.md) for the one-command package setup.

## Customer use

Wrapping: enter the Solana destination, native refund address and amount, create
an order, then pay the exact native deposit address shown before its deadline.
Unwrapping: enter the native destination and amount, create an order, then open or
scan the Solana Pay request in a wallet supporting the actual cluster/token.
Send the specified amount with the generated reference; an ordinary token transfer
without that reference does not substitute for the request. No website wallet
connection is required. The paying wallet must have SOL for its transaction fee.

New quotes charge 1% in either direction. The saved quote is authoritative;
pre-existing quotes retain their original fee. Save the order page/recovery details
privately. A reload recovers locally saved orders on that browser; clearing browser
storage removes that convenience. A payment sent after expiry does not revive the
quote. Use the order status and support contact instead of sending another deposit
when an outcome is unclear. Refunds use verified ownership and return principal
without a bridge fee; their network costs come from operator operating funds.

## Restricted diagnostics

On an installed server, the customer HTTP listener is loopback-only. The operator
socket is worker-owned mode 0600 and must never be published by the reverse proxy.
The following reads do not invoke signing:

```sh
sudo -u ecx-worker curl --unix-socket /run/ecx-bridge/admin/api.sock http://localhost/health
sudo -u ecx-worker curl --unix-socket /run/ecx-bridge/admin/api.sock http://localhost/scanners
sudo -u ecx-worker curl --unix-socket /run/ecx-bridge/admin/api.sock http://localhost/audit
```

Pause new intake with an explicit reason:

```sh
sudo -u ecx-worker curl --unix-socket /run/ecx-bridge/admin/api.sock \
  -H 'Content-Type: application/json' -d '{"pauseReason":"operator maintenance"}' \
  http://localhost/pause
```

Pausing intake does not stop completion/recovery of already authorized obligations.
For an offline maintenance snapshot stop the worker service and confirm it is
inactive. `/resume` is a private POST that rechecks readiness; it is not a way to
bypass custody/history errors. Private POST operations also include `/refund`
(`depositId`), `/retry-solana` (`transaction`, `reason`) and `/cancel-preparation`
(`intent`, `generation`, `cancellationReason`). `/approve-source-recovery`
accepts `obligation`, `restorationSequence`, `approvalReason` and restores only the
exact reviewed work after the saved source restoration is reverified.

The PostgreSQL private socket also supports this replacement workflow:

1. Pause; call `/prepare-native-replacement` with `parentTransaction`,
   `replacementFee` (integer base units as a JSON string), `replacementReason`.
   It saves an unsigned template and returns `draftSequence`.
2. While paused, call `/sign-native-replacement` with `draftSequence`. It rechecks
   the source, custody and exact template, then persists the signature and lineage.
   A repeated call returns the same saved member; it does not make a new signature.
3. Call `/resume` after reviewing the saved work. The normal worker can send the
   latest authorized member; `/send-native-replacement` with `draftSequence` also
   advances that exact member through the existing send/backup/observation engine.
   A paused deployment returns a paused outcome without broadcasting.

An unsigned draft can be cancelled through `/cancel-native-replacement` using
`cancelledDraftSequence`, `replacementCancellationReason`. Cancellation cannot
remove a signature or release the original payment. `/cover-source-loss` takes
`lossDeposit`, `lossRecoverySequence`, `lossCapital` (`lossFloat`, `lossEarned`,
base-unit strings), `lossReason`. It independently verifies the missing source
and current custody view before allocating existing free capital. It does not
resume, sign or send, and cannot treat an RPC failure as a proved loss. Restored
sources return the covered capital through the recovery journal.

These commands use closed critical DSL operations and the same serialized
interpreter as the worker. Rejections require investigation rather than direct
ledger editing. PostgreSQL storage contracts pass; live replacement/source-loss,
crash/backup and canonical-chain acceptance remain release requirements.

The CLI `scan`, `reconcile`, `recover`, `approve-source-recovery`,
`cover-source-loss` and native replacement commands still target the legacy SQLite
implementation. **Do not run those against the PostgreSQL deployment.** Use the
private PostgreSQL routes above. Native advisory-input
lock recovery now runs in the PostgreSQL worker and has actual unsigned-draft
node-restart acceptance; it is not an operator command. `postgres-init` is offline maintenance;
`postgres-test-worker` is the explicit public-test payment runtime. Do not run a
second worker against the same custody accounts under another database.

Health 200 only proves process liveness. Readiness 503 is expected in observation
mode or while inventory, chain history, synchronization or custody checks fail.
Inspect service status and the private diagnostics before changing configuration:

```sh
sudo systemctl status ecx-bridge-worker ecx-bridge-web ecx-bridge-postgres ecx-bridge-node
sudo journalctl -u ecx-bridge-worker -u ecx-bridge-web --since '30 minutes ago'
```

Logs and audit responses are operator data. Share a reviewed excerpt containing
error codes, timestamps, order IDs and public transaction IDs. Do not grant broad
SSH/sudo access to obtain logs. Never attach configuration, environment files,
keypair JSON, cookies, database dumps or customer recovery credentials to support
reports. The web user deliberately cannot access worker secrets or the ledger.

## Backup and release maintenance

The hourly timer writes private PostgreSQL custom archives plus SHA-256 manifests
under `/var/lib/ecx-bridge/private/backups`. Trigger it and inspect its result:

```sh
sudo systemctl start ecx-bridge-backup.service
sudo systemctl status ecx-bridge-backup.service
```

The backup service checks archive readability. Same-host restoration with row
comparison has been tested. This is **not** remote durability or fresh-host recovery:
copy retention, encryption/key escrow, wallet/node backup and a separate-host
restore drill remain required. A ledger dump alone cannot recover custody keys.
Do not delete the last known good archive or signed-attempt history.

Same-release reinstall preserves managed configuration. An explicit compiled
package `--upgrade` now verifies the existing PostgreSQL release, stops services,
saves private ledger/configuration/key/native-wallet recovery material and
replaces only verified managed deployment files. Local edits are refused. Failure
leaves services stopped; selecting the old release does not undo committed schema
changes or authorize resuming. See [the upgrade procedure](INSTALL.md). ARM64
observation-only upgrade and same-host dump restoration pass; valuable-fund, key
and remote restore acceptance remain required.

## Mint, metadata and backing administration

Runtime conversions transfer existing inventory; they do not mint or burn. Keep
mint authority, metadata authority, reserve/backing keys and LP positions off the
bridge server. Custody compromise must not also grant token issuance or control
of unrelated liquidity capital. Solana separates mint and other authority roles;
see the [Token Program basics](https://solana.com/docs/tokens/basics).

The repository provides a **Devnet-only** setup example, excluded from the installed
custody helper:

```sh
cd solana-helper
cargo run --locked -j 1 --example setup_devnet -- /absolute/private/test-state
```

It pins Devnet genesis, creates an eight-decimal classic SPL mint with no freeze
authority, creates custody/tester associated token accounts, and issues test
inventory. It retains a pending transaction journal and refuses a second attempt
while its predecessor is unresolved. If funding is missing it reports a public
Devnet funding address and sends nothing. This creates a distinct test mint; it
must never be described as the canonical wrapped ECX token.

For canonical adoption, first obtain the issuer-approved cluster, mint, decimals,
Token Program, authorities and backing policy. Verify them from finalized on-chain
accounts using independent RPC sources. Verify the native node's real network and
checkpoint as well. Record outstanding supply, backing obligations, reserve
locations, issuer approvals and an issuance/redemption reconciliation procedure.
An inventory bridge's matching local balances are not evidence of global backing.
Do not automatically revoke mint authority: ongoing backed issuance may require it,
and authority revocation is an irreversible policy decision.

The current example does not publish metadata. For a classic SPL mint, use a
separately pinned/reviewed compatible metadata tool and the metadata authority,
not the bridge signer. [Metaplex Token Metadata](https://www.metaplex.com/docs/smart-contracts/token-metadata)
attaches metadata to a mint through a separate account and URI. Review the actual
fungible-token standard and applicable program fees before execution. Verify the
resulting mint address, name, symbol, URI, image and update authority from the chain
and fetched JSON. A symbol/name is not token identity; publish the mint address.
Do not replace the configured SPL mint with a different token standard merely to
obtain metadata. No metadata transaction has been accepted by this project yet.

## Inventory and Solana liquidity

Allocate bridge native float, wrapped-token float and operating funds separately.
Supply finalized transaction IDs/history origins and reconcile them through the
ledger's supported funding process before enabling payments. Native network fees,
SOL fees and account rent need operating budgets; the 1% bridge fee is not proof
that a transaction can pay its network costs. Never repair a balance by changing
rows directly or silently treating an unexplained inflow as earned fees.

Liquidity is a separate operator workflow using the actual approved mint and
counter-asset. Use the existing [Orca documentation](https://docs.orca.so/) to choose
and create a compatible pool, record its program/address, deposits, fee tier and
any range settings, and validate both swap directions with actual small trades.
Amounts and prices in the conversation were historical examples, not deployment
parameters. Obtain explicit capital authorization before depositing LP funds.
Keep position control outside bridge custody.

A pool link alone does not prove Jupiter routing. Query actual mint information and
an executable quote using the current [Jupiter developer documentation](https://developers.jup.ag/docs/tokens/token-information),
then verify the returned mints, route, amounts and slippage on the intended cluster.
Record successful route evidence before exposing the operator-verified prefilled
Jupiter/Orca links in `interface.json`. Devnet configuration rejects mainnet trading
links. No route, pool capital or auto-compound setup is currently claimed.

Bridge fees belong to conversion accounting. Pool trading fees accrue to the LP
position; any auto-compounding service has its own permissions and costs. Do not
feed its keys into the bridge or count its yield as bridge reserves without an
explicit reconciled transfer. Historical pricing and the intended eCash-site
integration remain later market deliverables after real routing is proven.
