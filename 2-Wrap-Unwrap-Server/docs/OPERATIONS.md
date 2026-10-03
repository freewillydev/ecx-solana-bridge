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

## Restricted diagnostics and local control

The customer HTTP listener is loopback-only. Operator HTTP endpoints are removed.
Use `ecx-bridge operator CONFIG < command.json` as the service owner. This sends
one bounded named operation over the private mode-0600 socket and evaluates its
existential Plan through the existing safe/critical dispatcher. Never expose this
socket or the signer socket through a reverse proxy. Current installed releases
still use the old control protocol until their deployment is explicitly upgraded.

Examples of command file contents:

```json
{"operation":"audit"}
```

```json
{"operation":"pause","arguments":"operator maintenance"}
```

`health` and `scanners` are read operations; `resume` performs the same reconciliation
and saved-authority checks as the old private route. Arguments are a single value
for unary operations or a positional array for multiple arguments:

| Operation | Arguments |
| --- | --- |
| refund | deposit ID |
| retry-solana | [transaction, reason] |
| cancel-preparation | [intent, generation, reason] |
| approve-source-recovery / approve-covered-source | [obligation, sequence, reason] |
| rebroadcast-native | [transaction, recovery sequence, reason] |
| prepare-native-replacement | [parent transaction, fee base-unit string, reason] |
| sign-native-replacement / send-native-replacement | draft sequence |
| cancel-native-replacement | [draft sequence, reason] |
| cover-source-loss | [deposit, recovery sequence, capital object, reason] |
| allocate-treasury | [receipt, [[allocation, amount string]], ownership attestation] |
| classify-treasury-spend | [observation stream, transaction, ownership attestation] |

Pause before replacement/recovery review. A lost response is an uncertain outcome;
inspect the journal before acting again. The CLI never automatically retries.
Restart and resume retain saved bytes and economic settlement protections.

## Backup and release maintenance

The hourly timer writes private PostgreSQL custom archives plus SHA-256 manifests
under `/var/lib/ecx-bridge/private/backups`. Trigger it and inspect its result:

```sh
sudo systemctl start ecx-bridge-backup.service
sudo systemctl status ecx-bridge-backup.service
```

The backup service pins a separate read-only PostgreSQL snapshot and uses that
same snapshot for the dump, deployment metadata and every table count. Financial
transactions keep running; no worker capability or deployment row lock is held
across the dump. Archives and manifests stay private, with SHA-256 integrity.

Verify a **trusted backup produced by this installation** with:

```sh
sudo python3 /opt/ecx-bridge/current/deploy/postgres-verify-backup.py /var/lib/ecx-bridge/private/backups/ledger-TIMESTAMP.json
```

The verifier creates a random disposable database, revokes public access,
restores the archive transactionally, compares deployment metadata and all table
counts, and drops the database. It never starts a worker or changes the source
ledger. On an installed host the root wrapper copies only the ledger archive and
manifest into temporary PostgreSQL-owner storage; it does not copy signing keys.
Restore only trusted archives: PostgreSQL restoration executes their SQL.

The real PostgreSQL acceptance also writes to an isolated copy between metadata
capture and `pg_dump`, proves those newer writes are excluded, and rejects a
checksum mismatch. This is **not** remote durability or fresh-host recovery:
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

The root-Cabal [token administration CLI](../../1-Make-Wrapped-ECX/README.md)
provides key generation, eight-decimal classic mint creation, associated token
accounts, mint/burn and metadata operations. It replaces the standalone Rust setup
example. Fund separate test identities explicitly; use prepare/check/sign/submit
for each operation and keep every immutable signed attempt. Choose Devnet explicitly
for testing. A newly created test mint is not the canonical wrapped ECX token.

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

For an independently reviewed operator outflow already recorded by the scanner,
pause and POST `/classify-treasury-spend` on the private operator socket with
`observationStream` (`Native`, `Solana` or `SolanaOperating`), `observedTransaction`
and `spendOwnershipAttestation`. This books the observed principal/network cost
against available operator allocations and clears only that event's review. It
never signs or sends a transaction and rejects customer attempts or reserved funds.
Exact replay returns the saved sequence; a changed anchor, economic effect or
attestation conflicts. Reconcile before resuming.

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

## Critical snapshot retention

`deploy/postgres-retention.py` previews a fixed policy for one deployment: the
last two snapshots, seven daily, four weekly and twelve monthly snapshots, plus
every snapshot at the highest recorded critical sequence. The sequence rule
preserves the most advanced financial journal independently of clock ordering.
Only snapshots tagged both `ecx-bridge-critical` and the exact deployment
fingerprint are considered. Malformed sequence metadata is refused.

From a source checkout (the next consolidated package will include this tool):

```sh
sudo python3 deploy/postgres-retention.py --fingerprint DEPLOYMENT_FINGERPRINT --repository-file /etc/ecx-bridge/backup.repository --password-file /etc/ecx-bridge/backup.password
```

Review the preview first. During scheduled maintenance with payment workers
paused, add `--apply` to remove only the exact snapshot IDs selected by that
preview; newly arriving snapshots are never fed into a second deletion policy.
Use protected operator credentials with delete permission, separate from the
worker's append-only upload credentials. This command does not prune repository
data or acknowledge a worker backup barrier. Schedule restic pruning and its
subsequent repository check separately: pruning locks the repository and can
block critical uploads. See the [official restic retention documentation](https://restic.readthedocs.io/en/stable/060_forget.html).

Real local restic acceptance preserved an older-timestamp highest-sequence
snapshot and another deployment, applied the selected removals, and passed a
repository check. See `https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/backup-retention-local.json`. Actual remote
retention, recovery receipts and physical host-loss restoration remain unproved.

## Read-only token adoption acceptance

Before an issuer-approved deployment, compare the finalized mint and custody
accounts through both configured HTTPS RPC providers:

```sh
./scripts/check-token-policy /absolute/private/worker.json --expected-mint-authority ISSUER_APPROVED_PUBLIC_KEY --report /absolute/private/token-policy.json
```

Use `revoked` instead of a public key only when the approved policy explicitly
requires absent mint authority. The command checks actual cluster genesis, classic
SPL program, eight decimals, initialization, absent freeze authority, the expected
mint authority, and the configured custody account's owner/mint/state/delegation
policy. It compares supply and custody inventory across both finalized responses,
records their slots, and refuses mismatches or unavailable providers. Only bounded
rate-limited reads are retried; it never signs, mutates authority, initializes
storage or enables payments. Output omits RPC URLs and credentials.

Devnet acceptance passes for the dedicated test mint; see
`https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/token-policy-devnet.json`. This is not canonical-token acceptance or
proof of global reserve backing. Issuer approval, native reserve locations,
outstanding redemption obligations and issuance reconciliation must be reviewed
separately; the report explicitly leaves those claims unverified.

## Encrypted custody handoff escrow

A retired-host recovery bundle must include the ledger, native wallet/Solana key
archive, manifest and reviewed handoff journal. Use operator-owned encrypted
restic storage and credentials separate from the online worker's ledger-upload
repository. Keep the repository/password files private; do not give the worker
access to this escrow repository or its decryption password.

From the source checkout, after preparing and verifying the stopped-source
handoff:

```sh
sudo python3 deploy/encrypted-handoff.py /absolute/private/handoff --repository-file /absolute/private/operator-escrow.repository --password-file /absolute/private/operator-escrow.password
```

The command requires an existing HTTPS restic repository and protected regular
credential files. It refuses non-retired or mismatched source journals and
archive hashes, backs up all four files together, reads authenticated snapshot
metadata, restores into temporary private storage and compares every file hash.
It does not initialize storage, alter the original bundle, acknowledge worker
coverage, resume payments or install restored keys. Preserve its returned receipt
privately alongside the independently maintained decryption-key recovery policy.
It uses the `ecx-bridge-handoff` tag; critical-ledger retention does not delete
these custody archives. Review escrow retention separately.

The actual retired dedicated test-host bundle passed a real encrypted local
restic round trip, including the signing-material archive; see
`https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/encrypted-handoff-local.json`. The temporary restored material was
removed after hash comparison. Actual independent-host storage, password recovery,
host-loss restoration and old-key revocation remain release requirements. Do not
use an old ledger merely because its keys can still sign.

### Download and verify escrow before host restoration

Save the upload receipt in a private regular file (mode 0600). On the recovery
host, use the independently recovered operator repository/password files:

```sh
sudo python3 deploy/encrypted-handoff.py --restore-receipt /absolute/private/handoff-receipt.json --restore-to /absolute/private/verified-handoff --repository-file /absolute/private/operator-escrow.repository --password-file /absolute/private/operator-escrow.password
```

The destination must not exist. The command checks snapshot ID, deployment and
sequence tags, exact four-file association, every pinned file hash, and restored
handoff/manifest identity before placing files in a new 0700 directory with 0600
file modes. Existing recovery archives are refused. A filesystem failure while
placing files can leave an incomplete private destination; preserve it for
inspection rather than treating it as a verified restore. Success is returned
only after every file is staged. This does not start services or authorize keys.

Use the existing stopped-source/fresh-host restore procedure only after this
verification, matching the reviewed application release and reconciling chains,
obligations, signer identities and custody before any paying resume. Local real
restic acceptance matched all original bytes, verified private modes, refused an
existing destination and rejected a tampered receipt before staging. See
`https://github.com/ekulkisnek/ecx-solana-bridge/blob/6d293a3/docs/evidence/encrypted-handoff-staging-local.json`. Remote storage and actual host
loss remain distinct unverified gates.

### Recheck the dedicated recovered Solana acceptance

`integration/VerifyRecoveredSolana.py` verifies the retained Signet/Devnet test
recovery from its private staging journal against the installed customer API,
actual PostgreSQL ledger and two independent finalized providers. It requires
the completed expired-original/replacement fixture; it creates no order, retry
approval, signature or broadcast and does not start/resume services. Run against
the active restored destination with its observation API available:

```sh
python3 integration/VerifyRecoveredSolana.py PRIVATE_STATE \
  --vm RESTORED_TEST_GUEST --run-id RETAINED_RUN_ID --report PRIVATE_REPORT
```

The command checks the saved original hash, one settled replacement, exact 1%
fee, released holds, balanced postings and actual 9900-unit finalized effects,
then compares financial state before/after its reads. RPC read retries reuse the
existing bounded 429 policy. It does not repeat the separate restart test or
prove off-host durability. Never use the retired source guest for new staging.
