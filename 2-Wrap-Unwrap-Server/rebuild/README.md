# Replacement bridge

A connection-free ECX/Solana bridge charging 1% in both directions. This Cabal
package replaces baseline `ba31b28`; it is not yet release-ready. Keep the baseline
and its custody ledger until populated migration and real-chain parity pass.
Detailed development history and previous per-piece line comparisons are in Git
(up to `814af5f`); this document describes the current review target.

## Audit path

| Responsibility | Source within this package |
| --- | --- |
| Money, immutable quotes, explicit customer/earned funding | `src/Bridge/Domain.hs`, `Wire.hs` |
| Caller/severity GADTs, typeclass and existential requests | `src/Bridge/Operation/Internal.hs` |
| Restricted customer facade and four pure handlers | `src/Bridge/Operation.hs`, `api/Bridge/API.hs` |
| Safe/critical evaluation and payment orchestration | `workflow/Bridge/Critical.hs` |
| Admission, orders, payment, observation and custody | `workflow/Bridge/{Admission,Order,Payment,Observer,Reconciliation}.hs` |
| Closed Opaleye operations and atomic ledger transitions | `runtime/Bridge/Store.hs`, `Store/{Schema,Catalog}.hs` |
| Actual native/Solana RPC, codecs and effect validation | `chain/Bridge/` |
| Independent signing checks and authenticated HTTPS | `workflow/Bridge/{Signer,SigningTransport,Credentials}.hs` |
| Private operator commands | `workflow/Bridge/Control.hs` |
| Host fence, encrypted archives and custody recovery | `runtime/Bridge/{Fence,Store/Backup}.hs`, `workflow/Bridge/Recovery.hs` |
| Configuration, browser serving and resource lifetime | `workflow/Bridge/{Config,Web}.hs`, `app/Main.hs` |
| QuickCheck/protocol and PostgreSQL acceptance | `test/Main.hs`, `test/StoreCheck.hs` |

The exact supplied [Main.hs](../docs/reference/Main.hs) remains the architectural
reference, unmodified and excluded from builds. Servant handlers return
`Plan caller a`, packaging `Request caller severity a` with its `Operation`
dictionary. The interpreter resolves that dictionary to a closed DSL. Concrete
results, not existential values, are serialized over HTTP. Caller authority and
severity remain distinct; customer-critical requests cannot become signer/operator
requests. Safe and critical evaluators are separate, with one authorized runtime
critical dispatch. Cabal components hide privileged modules from the customer API.

There is one HTTP/worker process and one dedicated signer. The worker serves HTML,
CSS and the shared Haskell browser compiled by GHC's JavaScript backend. The Solana
SDK is Rust behind bounded Haskell FFI, not a signing subprocess. PostgreSQL,
native daemon, Solana RPC and restic remain external dependencies.

## Financial and authority boundaries

- Application row access, diagnostics and fixtures use Opaleye only inside specific
  closed operations. No handler receives a connection, generic query or IO callback.
  Driver connection/transaction control and reviewed schema DDL are infrastructure.
- Safe reads and the signer use SELECT-only roles. The writer owns the ledger
  advisory lock and a private monotonic host fence. Startup always pauses intake.
  Unexpected database failures fence the writer; stale snapshots cannot lower its
  watermark. Writer transactions do not span RPC, signing or remote backup.
- The critical evaluator alone constructs signer `ClientM` calls. The loopback HTTPS
  API accepts saved preparation/replacement decisions and custody checkpoints,
  never arbitrary bytes/RPC. It uses protected authentication, certificate pinning,
  bounded messages/timeouts and no automatic retries. The signer validates durable
  authority before and after signing, and never broadcasts or writes ledger rows.
- Worker native credentials must forbid signing/key export, including
  `walletprocesspsbt` even for unsigned requests. Replacement drafting therefore
  belongs at the signer. Observation, unsigned funding, `decodescript`, input locks
  and saved-byte submission require their specific permitted node methods.
  Separate OS credentials must also prevent reading the signing keys/full cookie;
  the current single-user local test does not prove that isolation.
- Integer accounting separates principal, float, earned fees, operating funds,
  unallocated receipts and protected allocations. New quotes use ceiling-rounded
  1% fees; saved terms never change. Network costs do not reduce the quoted payout.
- Conversion, refund and earned-fee withdrawal share one payment engine. It commits
  preparation and authorization, saves exact signed bytes, records broadcast intent,
  rechecks source/coverage/limits, and submits those bytes. Only independently
  observed effects settle accounting. An uncertain response grants no new payment.
- Duplicate receipts/settlements are rejected. Cancellation cannot erase signatures.
  Solana retry requires verified expiry and explicit approval. Native replacements,
  winner changes and rebroadcast preserve one economic payout and immutable history.
  Covered-source payment requires current loss proof, full capital cover and a
  separate saved approval; it never fabricates physical source eligibility.
- Required backup coverage gates instructions, signing and sending. Custody
  checkpoints upload and read back the complete bundle before acknowledging its
  exact current sequence. Slow backups trigger fresh scans/reconciliation, not
  extended quote deadlines or waived coverage. Missing backup configuration refuses
  required checkpoints. Local tests use `backupRequired=false` explicitly.

## Customer and operator interfaces

| Customer route | Purpose |
| --- | --- |
| `GET /api/v1/config` | Identity, fees, limits, links and availability |
| `POST /api/v1/orders` | Create or recover an immutable order |
| `GET /api/v1/orders/:id` | Authorized saved-order status |
| `POST /api/v1/orders/:id/transaction` | Authorized Solana Pay instructions |

Save a random 32-byte capability and idempotency key before creating an order.
Send `Authorization: Bearer <64 lowercase hex characters>`; only its hash is stored.
The public order ID does not grant access. Amounts are decimal base-unit strings.
Wrapping supplies a Solana recipient and native refund address. Unwrapping supplies
an external native recipient; verified deposit effects establish the refund owner.
There is no website wallet connection. A Solana Pay reference binds the deposit;
QR codes/payment links alone are not proof of payment. Supported-wallet signing and
browser reload/error behavior still need end-to-end acceptance.

Operator commands are JSON on stdin to `operator CONFIG`. They use the private
mode-0600 control socket under the owned mode-0700 fence directory, then the same
DSL dispatcher. This is not the signer transport or a public operator HTTP API.
Keep that directory short enough for the host's Unix-socket path limit.
[Control.hs](workflow/Bridge/Control.hs) defines exact accepted fields and rejects
unknown fields. Commands include:

- `status`, `native-reviews`, `pause`, `resume`, `repair-completed-order`;
- `allocate-treasury`, `classify-spend`, `withdraw-fees`, `cancel-fees`, `refund`;
- `cancel-preparation`, `retry-solana`;
- `cover-source-loss`, `approve-covered-source`, `approve-source-recovery`;
- `draft-replacement`, `sign-replacement`, `cancel-replacement`, `rebroadcast-native`.

Allocation requires a verified unbound receipt, exact split, paused service and
current custody. Resume independently recovers pending work and checks node
permissions, scans, custody and required backup; pause/resume is not a bypass.
Token issuance, metadata and pool administration remain outside bridge custody in
[1-Make-Wrapped-ECX](../../1-Make-Wrapped-ECX/README.md) and
[3-Create-CPMM-Pool](../../3-Create-CPMM-Pool/README.md).

## Build and run

Run from the repository root; use one build job and reuse compiler/SDK caches:

```sh
cabal build ecx-bridge-rebuild:exe:ecx-bridge-rebuild -j1
cabal test ecx-bridge-rebuild:rebuild-test -j1 --test-show-details=direct
bridge() { cabal run ecx-bridge-rebuild:exe:ecx-bridge-rebuild -- "$@"; }
bridge check-config CONFIG
bridge check-signer SIGNER_CONFIG KEYFILE
bridge observe CONFIG
# Or, in place of observe:
bridge serve CONFIG
# In a separate process:
bridge signer SIGNER_CONFIG KEYFILE
# With required custody checkpoint support, use instead:
bridge signer SIGNER_CONFIG KEYFILE BACKUP_CONFIG STAGING
```

Cabal hooks build SDK/browser inputs. `CONFIG` is a reviewed private deployment
configuration, not a fixture. Supply local `PGHOST`, `PGPORT`, `PGDATABASE`,
`PGUSER`, optional `PGPASSWORD`, and a distinct SELECT-only `PGREADUSER`/optional
`PGREADPASSWORD` for the worker. The signer uses its SELECT-only `PGUSER`, full
native signing credential and custody key. Reader roles need SELECT on tables and
sequences, not sequence USAGE/UPDATE. `ECX_INTERFACE_CONFIG` and `ECX_ASSETS` are
optional; assets normally come from Cabal. The protected signer token is at
`signerAuthFile`, certificate at `.pem`, private TLS key at `.key`.

`serve` starts paused and permits explicit guarded resume. `observe` refuses order
creation and outgoing sends. Public modes currently require L2L Signet/Devnet or
ECX betanet/Devnet profiles; canonical activation is not approved or accepted.

For a genuinely new deployment, apply reviewed baseline PostgreSQL migrations
001–005, then rebuild migrations 001–003 to an empty database, and run:

```sh
bridge initialize-ledger CONFIG
bridge adopt-ledger CONFIG 0
```

Initialization claims exclusive ownership, refuses residual financial rows, creates
only schema-21 metadata/custody/clock rows, and starts paused with zero sequences.
Matching repeat initialization preserves state. It does not run/verify full DDL,
restore coins/history, initialize keys or authorize sending. Existing custody must
use recovery/migration, never a fresh ledger with its old keys.

## Backup and recovery

Offline maintenance uses closed operations in the same executable:

| Command after `bridge` | Result |
| --- | --- |
| `backup-native-wallet CONFIG DESTINATION` | New node wallet archive and durable manifest |
| `restore-native-wallet CONFIG MANIFEST` | Restore into an unused configured wallet name |
| `backup-custody CONFIG KEYFILE DIRECTORY` | Pause/exclusively export a complete custody bundle |
| `check-custody CONFIG MANIFEST MINIMUM_SEQUENCE` | Offline bundle identity/integrity inspection |
| `upload-custody CONFIG BACKUP_CONFIG MANIFEST MINIMUM_SEQUENCE` | Upload, download and inspect the complete encrypted snapshot |
| `recover-custody CONFIG BACKUP_CONFIG SNAPSHOT DIRECTORY MINIMUM_SEQUENCE` | Retain a verified decrypted bundle in new private staging |
| `restore-ledger CONFIG MANIFEST MINIMUM_SEQUENCE` | Restore into a new restricted paused staging database |
| `recover-ledger CONFIG BACKUP_CONFIG SNAPSHOT STAGING MINIMUM_SEQUENCE` | Download/verify the ledger archive, then the same staging restore |
| `adopt-ledger CONFIG MINIMUM_SEQUENCE` | Initialize/advance a matching host fence without lowering it |
| `retire-ledger CONFIG MINIMUM_SEQUENCE` | Permanently retire the matching local fence |

Use independently known minimum sequences and full 64-character snapshot IDs,
never `latest` or guessed zero. Staging must be owned/private; destinations must
not already exist. Database restoration needs separate database-creation authority.
Custody export needs writer/reader database credentials and offline native/key access;
it requires the worker stopped. No command overwrites a wallet, automatically
activates restored custody, acknowledges itself or resumes the worker.

The bundle binds ledger dump/manifest, native wallet/manifest, Solana key and
configuration; its completion manifest is written last. It preserves signing state
and financial history, not old RPC cookies/TLS credentials. Native encrypted-wallet
unlock material is not yet supported: export refuses encrypted wallets. Same-UID
native/key/staging access is currently required.

`BACKUP_CONFIG` contains protected absolute `restic`, `repositoryFile` and
`passwordFile` paths. Production accepts `rest:https://...` away from loopback,
not local/plain-HTTP storage. Repository creation and independently retained
credentials/password are operator responsibilities. Restore verifies authenticated
paths/tags, hashes, schema, identity and sequence, streams fixed files without tree
extraction, then validates the restored database through closed Opaleye operations.
Failed staging is cleaned where safe; uncertain database creation may require
inspection. Restored custody certification is invalidated. Fence retirement does
not revoke signing credentials on another host; that requires explicit revocation.

Local encrypted-restic tests are not proof of off-host durability. Key seeds alone
cannot restore order history, saved signatures, authorization or missing funds.

## Verification and current evidence

The existing `rebuild-store-check` Cabal executable uses a fresh disposable migrated
PostgreSQL database and SELECT-only role, supplied by
`ECX_REBUILD_CONTRACT_DATABASE` and `ECX_REBUILD_CONTRACT_READER`. Inspect
[test/StoreCheck.hs](test/StoreCheck.hs) for fixture setup and mode requirements;
never point contract fixtures at custody. Direct binary invocation needs Cabal's
`ecx_bridge_rebuild_datadir`; `cabal run` supplies packaged fixture data.

| Mode | Additional environment / scope |
| --- | --- |
| Default | Financial/ledger contracts and local encrypted restic restoration |
| `ECX_REBUILD_MIGRATION_ONLY=1` | Disposable restored, offline, populated schema-18 ledger with baseline DDL through 005; applies rebuild 001–003 and checks preserved history; optional `ECX_REBUILD_MIGRATION_RECOVERY_CONFIG` runs observation-only reconciliation against real test chains |
| `ECX_REBUILD_SETUP_ONLY=1` | `ECX_REBUILD_EXECUTABLE`; optional `ECX_REBUILD_SETUP_RESIDUE=1` |
| `ECX_REBUILD_SERVER_ONLY=1` | `ECX_REBUILD_EXECUTABLE`; process/HTTP/private control |
| `ECX_REBUILD_TLS_ONLY=1` | `ECX_REBUILD_TEST_SDK`; actual TLS and saved signing decisions |
| `ECX_REBUILD_FENCE_ONLY=1` | Actual PostgreSQL/filesystem ownership and watermark contracts |
| `ECX_REBUILD_NATIVE_RECOVERY_ONLY=1` | Executable, `ECX_REBUILD_NATIVE_RECOVERY_COOKIE`, `ECX_REBUILD_NATIVE_WALLET_DIRECTORY`; fresh real-node test wallet |
| `ECX_REBUILD_CUSTODY_ONLY=1` | With native recovery mode and disposable DB; complete bundle restoration |
| `ECX_REBUILD_LIVE_OBSERVER_CONFIG=CONFIG` | Real-chain scans through observation-only DSL; restricted native credentials |

Populated migration passed on a disposable copy of `ecx_fresh_treasury_acceptance`:
two paid orders, two exact signed attempts and 31 postings were preserved, together
with deposits, obligations, customer intent bindings, preparations and reservations.
The rebuild's read-only evaluator decoded each migrated payment and its balances.
Identity and sequence stayed unchanged; schema advanced from 18 to 21 while paused.
An archived in-flight host-restore ledger also passed: three signed attempts and
33 postings survived, and its one pending attempt remained discoverable and readable.
The comparison includes cancellation, expiry/retry, replacement/winner and source
recovery records. Two older archives preserved their records but failed cutover
acceptance: each contains three payments without saved order cost policies; the
rebuild refuses those payments rather than inventing historical limits. The original
ledgers were untouched. The in-flight copy also passed real-node reconciliation
through the critical evaluator: its signed native transaction remained unseen and
pending, exact bytes/ledger history stayed unchanged, and repeated reconciliation
was idempotent. No signer or broadcast was enabled. This proves retained-work recovery,
not migrated settlement or funded recovery parity. The schema-18 backups lacked
baseline DDL 005: verify installed DDL, not only the version number.

Prior root Cabal, QuickCheck, PostgreSQL, TLS and local-restic runs passed their
recorded scopes. Protocol mutations, receipt fixtures and local-restic transport
seams do not establish funded chain behavior or production off-host HTTPS operation.
The live observer contract verifies all three scans, unchanged repeated accounting,
refusal of signing/broadcast, all 13 forbidden native signing/key methods, and
permitted `decodescript` access needed for customer admission.

At `c17e52d`, isolated deployment `rebuild-live-20261003` used fresh custody keys,
wallet and persistent ledger, independent of baseline custody. Operator DSL allocation
accepted 1,500 native operating units, 10,000 native float units, 25,000 wrapped
float units and 100,000,000 lamports. A dedicated Haskell tester submitted a real
10,000-unit Solana Pay deposit with the order's readonly reference:
`34xGfjKRoLb6MsWkgYtTCByoZpVSBWFmStZYkToHBPQTL6UdrXwna9QQPv7sS2zap3kMncJoNcFAmx9kVDaG7KP6`.
The bridge/dedicated signer sent the quoted 9,900-unit native payout:
`c816a2f9f3eda53ab93cbf8687a9b5286cad69133b34d3b5ad774f56c6de2c1f`,
with a separate 208-unit network fee. After one native confirmation, the paused
worker reconciled it to `Paid` with unchanged quoted terms and payout identity.
Reload and identical create replay match; a wrong capability is refused. Restart
preserved the order, paused at sequence 9 and left one native outgoing transaction.
The test minimum was then lowered to 1,000 units (existing terms unchanged), and
a reverse wrap quoted 1,000 gross, 10 fee and 990 net. Its native deposit
`8e9488e637a62b1aa26f15173b3a6baf81e8bf04d999e37cb52132d0a280d0be`
confirmed, and the order settled `Paid` with wrapped payout
`3UBC85cVNBvfsoFKrdmTW43w4BrEbesg2bbBik9sXZTFN4DDyifwGfFhhDYi7tjqbb51UtFDVa6aLxarh6fQ9YJa`.
The earned 100 wrapped units were withdrawn and settled through the same engine in
`2M5LN24FVYZxAubrJxZ1ANPZgqXHzCztYc9kj252fnvUB2CZbkJXVhXuyu9o2UGUyP6S9cUdVC9KV4iReK4Rno1c`.
An additional 1,000-unit deposit to the completed unwrap reference was fully refunded
to its verified sender in
`4pb4UpuF14CaVw9WoSxFhREYWnjCP5RBMP5EiJEC36y2ZWTnufBEQHrV6FRjdQmP8bZUU7pG2EiHW1FMYKzfhJC`.
Both Solana transactions finalized successfully; closed Opaleye reads show `PaymentPaid`,
released principal/fee holds and actual operating charges of 5,000 lamports each.
Exact decisions replay; a changed withdrawal amount is refused.

The extra refund exposed an order-view bug: preparation/signature recording changed
the completed conversion's status, letting refund settlement overwrite its payout
link. Both updates now preserve `Paid`, matching authorization/settlement guards.
The PostgreSQL regression checks the original view from authorization through
settlement and replay. For already affected rows, private
`{"operation":"repair-completed-order","order":"ORDER_ID"}` requires paused,
reconciled custody and derives the payout from a unique settled conversion. It
changes only the proven historical `Refunded` view whose link points to a settled
refund for that order; arbitrary status/payout input is forbidden. Repair advances
the fenced critical sequence and records both payout links in the audit. Exact
replay changes nothing. The actual test ledger was repaired at sequence 26 with
unchanged balances/refund and the original full customer response restored.
The full PostgreSQL contract, Cabal build and QuickCheck pass. Native refunds/fee withdrawals,
arbitrary crash recovery and real-wallet UX remain unproven.
Private keys/attempts/ledger remain outside Git.

## Remaining release work, in order

1. Extend the funded tests to native refunds/fee withdrawals and remaining
   interrupted-attempt recovery on the actual test networks. Finish real wallet
   signing and browser/reload/error acceptance; keep tester-client evidence distinct.
2. Prove populated baseline migration and financial/recovery parity, then remove the
   superseded application and duplicate tooling. Retain unique checks until covered.
   Consolidate stale repository-wide architecture/operating documents around the
   accepted rebuild; their earlier checkpoints are not current release certification.
3. Verify replacement/reorg/winner-change/rebroadcast and covered-source flows with
   real effects, including funded restore. Complete cross-UID signer isolation,
   encrypted-wallet unlock handling and off-host HTTPS/cross-host recovery.
4. Complete required Haskell/FFI token administration and selected real pool workflow;
   token mint/burn now has a Cabal CLI, separate critical signing/submission, and
   finalized Devnet round-trip/replay acceptance. Mint creation reuses the same
   workflow and has finalized Devnet acceptance. Metadata creation/update also pass
   real Devnet readback and saved-attempt replay, with no new SDK dependencies.
   Token-account provisioning and a new-mint issuance/burn round trip also pass;
   the standalone Rust setup example is retired. Administration expiry recovery remains.
   Retire remaining legacy Rust/Python tools after their required behavior is covered.
   Confirm canonical token authority, backing, liquidity and actual route availability.
5. Finish the current installer/upgrade path last, test clean Linux installation and
   restoration on both architectures, review dependencies, and obtain independent
   security review before valuable-fund/public activation. The old installer is not
   certification of this process design.

The objective is a smaller reasoning surface with every retained behavior verified.
Neither fewer lines, passing fixtures nor a successful test transfer proves perfect
security or completes the remaining gates.
