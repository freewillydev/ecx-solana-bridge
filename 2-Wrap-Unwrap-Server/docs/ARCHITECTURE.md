# Architecture and financial contracts

The source map is in the [server README](../README.md). This guide defines the
boundaries a reviewer must trace; [release review](RELEASE-REVIEW.md) records what
is actually verified. There is one Servant HTTP/worker process and one dedicated
signer. PostgreSQL, the native daemon, Solana RPC and restic are dependencies.
The Haskell browser is compiled by GHC JavaScript; Rust is confined to SDK FFI.
Public HTTPS terminates directly in the worker's WarpTLS listener; no reverse-proxy
process is required. Optional certificate/key environment variables enable public
IPv4 TLS; their absence preserves loopback HTTP, and partial configuration refuses
startup. Constant-space global request/order admission budgets precede the existing
body/concurrency controls in TLS mode. These controls grant no DSL authority and
are not a separate process isolation boundary. The signer remains separate.

## Requests, dictionaries and evaluators

The user's exact [Main.hs](reference/Main.hs) is preserved outside production
builds, SHA-256 `f1d0777a8d2fddd62881aa5d85f518884c9d4efb451480f1520a677ab2319ea2`.
Read it before changing the operation boundary. The production grammar corrects
its permissive/incomplete sketch types while retaining its constrained design:

```haskell
data family Evaluation (severity :: Severity)

class Typeable (OperationContext caller severity op)
    => Operation caller severity op | caller -> op, op -> caller where
  type OperationContext caller severity op = (context :: Constraint)
    | context -> caller severity op
  command :: op severity a -> DSL caller severity a
  interpretOperation :: DSL caller severity a -> Either Text (DSL caller severity a)
  authorizeOperation :: Evaluation severity -> op severity a -> IO ()
  evaluateOperation :: Evaluation severity -> op severity a -> IO a

data Request caller severity a where
  Request :: Operation caller severity op
          => op severity a -> Request caller severity a

checkedRequest :: forall caller severity a.
  Request caller severity a -> Either Text (DSL caller severity a)
checkedRequest (Request (op :: requested severity a)) =
  interpretOperation @caller @severity @requested (command op)
```

Four closed caller families and six ground instances cover customer/operator
safe and critical work, and worker/signer critical work. Functional dependencies
fix each caller's family; severity-indexed GADTs fix its executable instructions.
The associated `OperationContext` family returns an injective constraint type;
each instance defines it as its fully specified `Operation` constraint.
DSL constructors retain only that fully specified associated constraint. The private
matching-only `Instruction` view lives beside the ground instances in `Critical.hs`,
where their type equations reduce it to the exact `Operation` dictionary. It recovers
that dictionary from the closed grammar without admitting arbitrary instructions.

`checkedRequest` constructs the DSL from the original existential request and
selects that request's `interpretOperation` instance explicitly. That pure method
uses `eqT` and `Refl` to establish equality of the request and DSL's **constraint
types**. There is no `operationDictionary` method or explicit dictionary argument.
This check does not compare dictionary values, leaf constructors or payloads.
Coherent ground instance heads, construction from the original request and the
typed leaf results remain essential; reflection does not replace authorization.

`Plan caller a` contains a safe or critical existential request. Customer handlers
have `ServerT CustomerAPI (Plan 'Customer)` and contain no effects. Servant's hoist
checks and evaluates the request; only its concrete result is serialized.
Order creation being critical does not confer operator or signer authority.
Cabal's customer-api component hides `Operation.Internal` and has no runtime,
store or chain dependency. Pure HTTP/control assembly carries concrete instance
constraints; startup supplies the implementations. Review exports and component
dependencies as well as types.

All six `Operation` instances live in `Critical.hs`, beside the safe and critical
evaluators. Their methods implement concrete effects except local signer execution,
which belongs directly to the gated critical evaluator. There is no
`Interpreter` class, callback bundle or arbitrary environment/program execution
instance. The core declares an opaque `Evaluation` data family; only `Critical.hs`
defines its two concrete severity instances and can construct them. Safe resources
are a reader and public configuration. Critical resources are either worker
resources or signer resources, which contain no writer. IO is fixed; polymorphism
in the result preserves the result selected by the operation's GADT.

Both evaluators recover `Instruction` and call `authorizeOperation`. Safe evaluation
then calls `evaluateOperation`. Critical evaluation matches the four `SigningDSL`
leaves in a signer context, keeping each read/sign/recheck or checkpoint sequence
inside its held gate; all other cases call `evaluateOperation`. The signer instance's
method constructs only the worker's HTTPS client and refuses local signer execution.
There is no signer `run` helper or method that executes keys outside `evalCritical`.
`runProcess`
owns the concrete worker or signer service lifetime. After validating that mode's
resources it allocates one gate and defines the sole `evalCritical` call site.
It then runs HTTP/worker/control or signer HTTPS with that local dispatch. It does
not return an evaluator or hand one to a caller-supplied continuation. The CLI
normalizes both startup modes before its single `runProcess` call; its resource
bracket passes only resource data, never evaluators. Each process retains its own
gate and resource context. Worker entry refuses
signer requests; signer entry refuses customer/operator/worker requests. Internal
worker and signer instructions pass `checkedRequest` and invoke the concrete method
inside the already-held gate, without reacquiring it. Only that internal signer
method constructs the HTTPS client; the signer context executes local signing.

`Signer.hs` owns Servant routes, authentication and TLS transport. Signer startup
and key operations live in `Critical.hs`. The dedicated signer independently
authenticates requests and holds its gate across validation, signing and the
second durable-decision read. Sharing evaluator code does not merge processes,
credentials or gates. Safe reads remain concurrent. No database transaction spans
RPC, signing or remote backup. The workflow instances are intentionally orphan
instances: final-program coherence checks must import `Bridge.Critical`, rather
than testing the grammar component alone.

Do not add arbitrary IO/SQL operations, severity casts, incoherent authorization
instances or generic connection callbacks. The reference's weekly limit/multisig
comments are design notes, not implemented guarantees.

## Signer authority and output identity

Only the critical interpreter constructs the generated Servant `ClientM`. The
private API binds loopback HTTPS and authenticates with a protected token. The
worker trusts the configured certificate with hostname validation; transport has
bounded bodies/timeouts and no proxy, redirects or automatic retries. The signer
uses SELECT-only ledger access, validates saved authorization and exact effects
before/after signing, and never broadcasts.

| POST path | Leaf operation | Unique result constructor |
| --- | --- | --- |
| `/sign-preparation` | `SignPrepared` | `PreparedResult` |
| `/sign-replacement` | `SignReplacement` | `ReplacementResult` |
| `/draft-replacement` | `DraftReplacement` | `DraftResult` |
| `/checkpoint-custody` | `CheckpointCustody` | `CheckpointResult` |

`data family Result severity op` is injective in both indices. Leaf GADTs fix the
result before the command family is hidden existentially. Four disjoint JSON fields
and strict decoders preserve response identity. Retries may repeat the same saved
result; uniqueness means non-interchangeable constructor paths, not fresh values.

[test/formal/SignerPaths.tla](../test/formal/SignerPaths.tla) defines an explicit
`OutputStates` set and checks unique generating paths, route/output alignment,
authentication/refusal and critical-dispatch requirements. The two-request TLC
model reached 54,289 distinct states without violations; deliberate wrong-output,
reused-constructor, auth/dispatch-bypass and observer-dispatch mutations were rejected.
It includes an inductive argument, not a TLAPS-checked unbounded theorem or automatic
Haskell refinement proof. It does not prove cryptography, custody or OS isolation.
Ordinary constructors/JSON remain constructible by trusted code. A separate client
with valid signer credentials can call HTTPS; it is still subject to signer checks.

Custody keys and full native credentials must be inaccessible to the worker through
OS permissions and node RPC restrictions. Deny signing, key export, wallet unlock
and wallet lock; `walletprocesspsbt` is signing-capable even when a caller requests
an unsigned result. Replacement drafting therefore belongs at the signer. Process
separation alone is insufficient while a full credential remains readable.

Optional `nativeUnlockFile` contains 1–1024 exact UTF-8 bytes, no NUL or line ending,
in a protected mode-0600 regular file. Unlock/sign/relock occurs inside the signer
gate; cleanup also follows an uncertain unlock reply. A 120-second daemon lease
bounds exposure after process loss or failed relocking. The worker can allocate
cached descriptor addresses while locked; keypool exhaustion remains a node refusal.

## Database and financial authority

Every application row read/write, diagnostic, privilege check and test fixture
uses Opaleye in a specific closed operation. Connections, transaction control and
reviewed migration DDL are infrastructure. No handler gets a connection or generic
query evaluator. Safe evaluation and the signer use distinct SELECT-only roles,
including SELECT on sequences without USAGE/UPDATE. Startup checks inherited and
catalog privileges, schema creation and elevated role flags.

The writer owns a deployment advisory lock and an independent monotonic host fence.
Ledger actions explicitly use READ COMMITTED / READ WRITE and lock the deployment
row before reading decision facts; safe/signing reads use READ ONLY / REPEATABLE
READ snapshots. The fence advances before commit;
stale/wrong-identity/retired state is refused. Unexpected database failures fence the
connection; policy failures permit reuse only after successful rollback. Startup
pauses intake. Schema-18 migration retains exact history through migrations 006–008;
migrations 001–005 remain necessary baseline DDL. Fresh initialization expects the
complete schema and refuses residual financial rows.

Amounts are canonical base-unit decimal strings. Both conversion assets have eight
decimals; arithmetic uses Integer with bounded persisted values. New fee is
`ceiling(gross * 100 / 10000)` and net is gross minus fee. Reject nonpositive net.
Save quote, direction, destinations, deadlines, confirmation/finality, cost limits
and deployment fingerprint immutably. Network fees/rent never reduce quoted net.

Each append-only event balances independently by asset. Principal protects customer
receipts; float funds payouts; earned holds settled revenue; operating pays costs;
unallocated, backing and LP balances remain protected. External is a counter-entry,
not capital. Never infer spendable float from a wallet balance. Conversion, full
refund and earned-fee withdrawal share a payment engine with explicit funding types;
withdrawals never fabricate customer orders or deposits.

Admission reserves conversion and alternate refund costs, including rent, within
available allocations and rolling 86,400-second budgets. Immutable cost times and a
monotonic durable clock prevent clock rollback from resetting budgets. Expiry
releases only provisional holds. Funded/signed work retains its protection. Treasury
allocation requires a finalized eligible unbound receipt, an exact split, paused
service, ownership attestation and matching custody; SOL only funds operating.

## Customer and payment lifecycle

A random saved 32-byte capability and idempotency key precede order creation.
`Authorization: Bearer <64 lowercase hex characters>` grants access; only a
domain-separated hash is stored. Replaying identical immutable input recovers the
order; changed input conflicts. Order IDs, QR codes, memos and payment links alone
grant neither access nor deposit credit.

Wrapping binds an external Solana recipient and native refund address. Unwrapping
binds a native recipient and Solana Pay reference, then verifies the actual sender
for refunds. Native admission checks the real checkpoint/network, supported scripts,
ownership, dust and fee policy. Solana admission checks genesis, classic SPL program,
mint/ATA identity, initialized mint layout, decimals, absent freeze authority,
ownership, balances and fee/rent limits. The shared mint parser also validates
issuance authority and bounded supply; configured providers must agree on authority,
while differing supply snapshots are allowed. This does not pin an issuer-approved
authority. Unsupported
extensions, delegates, close authorities and account forms are refused. Simulation
success does not guarantee later execution.

All three profiles use this same order/payment path. `CanonicalBeta` binds the
ECX checkpoint and canonical mint to Solana Mainnet genesis, requires an independent
HTTPS verifier and requires backup coverage in the deployment configuration.
The CLI validates that configuration before creating reader/writer/signer resources;
`runProcess` checks their chain and customer identity alignment. Mainnet has no
separate evaluator or manual payout shortcut. Observation mode still refuses paying
operations; paying mode starts paused and must pass operator resume checks.

Native provisioning saves a unique claim before allocating an address. Only the
claim creator allocates; retries recover the exact labeled owned, solvable,
non-change P2WPKH address. Ambiguous allocation cannot silently allocate another.
Instruction exposure requires unexpired, unpaused intake, retained holds, fresh
custody/scans and required backup. Recovery never extends saved deadlines.

1. Observe the exact qualifying deposit; preserve liabilities for partial, late,
   additional, unknown or ambiguous receipts and route them to review/refund.
2. Save a funded outgoing intent and exact preparation generation/draft. Native
   locks may cover only saved inputs; independently check prevouts, change and fees.
3. Obtain required backup coverage, sign the saved decision, independently validate
   the result and persist its exact bytes. A lost signing reply grants no send authority.
4. Record broadcast intent and sequence, cover it, then recheck source, readiness,
   costs and Solana validity. Submit only saved authorized bytes.
5. Independently observe actual confirmed/finalized effects and atomically settle
   principal, fees, operating costs and reservations. A signature or submission
   acknowledgement is not settlement. One economic payment has one settled winner.

Solana preparations retain exact messages, references, blockhash/validity and cost
limits; Haskell checks SDK bytes and Ed25519 signatures. Failed finalized transactions
book only verified costs. Additional refunds never overwrite a completed conversion's
payout link. Old unfinished records without saved executable policy require review.

## Observation and recovery

Observers atomically commit pages with their previous cursor. Native, custody-token
and SOL histories retain immutable origins. Unknown outflows are quarantined;
signed/unseen bytes do not explain spent funds. Errors preserve cursors.
An unavailable Solana verifier refuses the whole token scan, preserving existing
receipt eligibility; contradictory finalized evidence still enters review. New
receipts wait for successful verification, and scanner failure pauses intake.
Custody compares actual balances with journal balances and only verified observed unbooked
effects. A revision fences the snapshot; financial changes invalidate it. First
intake/exposure requires scans/custody no older than 60 seconds. Checks never resume
the service by themselves. Source updates and slow plan RPC can invalidate readiness;
refresh it before preparation, signing, queuing and send authorization. Keep the
final transaction-acceptance/blockhash check after that refresh. Refresh is bounded;
if custody reads age the scans, recheck and refresh again without extending their
60-second validity. If custody discovers history ahead of a saved cursor, its
closed ledger operation also marks the affected scan stale without advancing the
last successful scan time. The next readiness refresh must observe that history;
it cannot repeatedly certify the same old cursor. Native advancement invalidates
the native scan; a Solana history mismatch invalidates both Solana streams.
A completed scan still requires fresh custody reconciliation before authorization.
Recovering native receipts are reread beyond the incremental
cursor so their deposit state and matching evidence are committed together.

Paused recovery can record observed effects and recover owned input locks, but
cannot prepare/broadcast new payments. Foreign locks stay untouched. Cancellation
journals exact cleanup, excludes recorded signatures and retains liabilities;
unknown cleanup stays pending. Never unlock an empty input list. Generation count
is bounded at eight, and old-generation callbacks cannot change newer work.

Solana retry requires every configured provider to establish finalized height past
saved validity, invalid blockhash, absent transaction/status and complete histories
to immutable origins. Truncated/unavailable history is not proof. Preserve bytes and
principal, then require a separate paused immutable approval for a new generation.
Amount, recipient and reference remain fixed; costs are reserved again.

Native replacement retains inputs, sequence, version/locktime, recipient/amount,
change address and fee ceiling; only change decreases to fund the added fee. Keep
all bounded family members and immutable decisions observable. Foreign spenders,
conflicting drafts and ambiguous winners require review. Observe the sole actual
winner; a proven later winner change adjusts only costs, never principal again.
Singleton and replacement payouts share the same verified family reader for
observation, custody effects and input-lock recovery. A retained zero-confirmation
wallet record alone does not establish an active spend; absence requires stable
chain/wallet views and unchanged unspent inputs. For a retained non-abandoned,
non-conflicted inactive transaction, custody adds back the verified shared inputs
excluded by Core's wallet balance, once per family. This reporting correction is
separate from economic in-flight effects; missing or abandoned records add nothing.
It requires explicit untrusted wallet records, disabled address-reuse avoidance,
and zero wallet pending credit: even unrelated unconfirmed pending balance defers
normalization, so asynchronous wallet mempool updates cannot double-count change. Family
classification and balance anchors are rechecked together; unexplained mismatches,
overlapping families and changing or unavailable evidence still refuse readiness.
Rebroadcast requires explicit saved approval, current source proof and backup and
uses identical bytes. It does not grant replacement authority.

Source loss retains obligations, holds and attempts. Corroborated native loss books
a deficit; unavailable data is not loss. Return reverses it once and restores
confirmation review. Separate source-restoration or covered-source approval binds
the exact suspended work, latest decision, current custody and required coverage.
Full loss coverage consumes only genuinely free native float/earned capital, never
principal, operating, backing or LP. Return restores the original split once.
Unresolved reviews, deficits or missing policy prevent resume.

Read-only RPC retries use a fixed bounded allowlist. Solana history-storage error
`-32019` retries only the three history methods within the same two-retry budget
as rate limits and closed connections; exhaustion preserves the error. Wallet mutations, sends and
unknown outcomes are not automatically retried. Fixtures are not substitutes for
real protocol/network acceptance.

The shared RPC manager spaces HTTPS admissions by normalized hostname using a
monotonic clock and a cancellation-safe per-host gate. It runs once per actual
HTTP request, including each allowed retry. Waiting for one provider does not block
another. Worker and signer budgets are separate; deployment must keep their sum
and other consumers within provider quotas. Pacing neither authorizes a payment nor
extends its saved deadlines, custody freshness, backup or blockhash checks.

Token and pool administration have their own closed critical evaluators, outside
custody. `Token.Network` and `Pool.Signing` own private signing helpers and immutable
attempt families. `Token.Signing` also owns closed offline key-import/sign operations:
it validates the exact prepared intent and key, then saves a portable signed record
without RPC or recovery claims. Online submission reuses `Token.Network` validation;
offline records cannot use automatic successor recovery. Ordinary requests use recent
blockhashes. The closed `NonceMint` request instead binds an initialized System Program
nonce account to the same mint authority/fee payer, advances it as the first instruction
and then mints the exact checked amount. Haskell validates every key, writable role and
instruction independently of SDK encoding. Preflight/submission checks the current
nonce value and authority; a consumed nonce is refused unless the saved signature is
already observed. `CreateNonce` provisions rent with a separate online payer using
create-with-seed and initialization; nonce authority is the explicit owner, not
implicitly the payer.
Import accepts
base58 64-byte Solana keypairs with matching public halves, not seed phrases.
Shared `Bridge.AdminStatus` collects read-only recovery evidence;
it cannot sign or broadcast. Recovery binds a payer-history anchor to the actual
block that produced the saved blockhash, then requires two providers to establish
finalized failure or expiry with complete anchored absence. The sole successor
changes only the blockhash, retains its predecessor hash and limits, and is saved
before any submission. Protected files and process locks prevent local branching;
RPC completeness and exclusion of other hosts holding keys remain trust assumptions.
See the token/pool READMEs for commands, bounds and publication-crash handling.

## Backup boundary

Required instruction/sign/send coverage acknowledges the exact durable sequence.
A checkpoint exports a consistent PostgreSQL snapshot plus native wallet, Solana
key, configuration and manifests, uploads via restic and verifies the downloaded
bundle before acknowledgement. Slow backups trigger fresh observation, not waived
coverage or renewed quotes. No SQL transaction spans remote upload.

Encrypted-wallet export requires configured unlock material even if already
unlocked. Format-2 custody archives bind encrypted state, exact file set and secret;
unencrypted archives retain format 1. Export validates the secret against the wallet
before/after backup and checks source bytes/state. Keep passphrase administration
quiescent. Offline inspection checks integrity without unlocking; restoration must
point `nativeUnlockFile` at the recovered private file.

Restore into new staging, verify identity/schema/minimum sequence, migrate forward,
adopt a nondecreasing fence and reconcile both chains before explicit resume. A
local retirement marker does not revoke copied keys elsewhere. Never replace a
missing ledger with a new empty ledger for existing custody. See
[OPERATIONS.md](OPERATIONS.md) for commands and old-host exclusion requirements.

## Refactor baseline contract inventory

This inventory describes source `3d4970b` on schema 21. It is the compatibility
boundary for the financial-core refactor, not a claim that the proposed schema 22
is already implemented. Names below are exact source constructors/commands.

### Customer, worker and signer

| Entry | Input → result | Authority / refusal boundary | Existing checks |
| --- | --- | --- | --- |
| `GET /api/v1/config` | none → `PublicConfiguration` | Safe reader; availability reports failed intake without authorizing work | `Main.handlerContract`, `SigningTransportCheck`, `StoreCheck.orderWorkflowContract` |
| `POST /api/v1/orders` | required Authorization + `OrderRequest` → `OrderView` | Critical customer; paying mode, validated identity/addresses, immutable replay, capacity/holds/freshness/backup | `orderWorkflowContract`, `serverMain`, `tlsMain` |
| `GET /api/v1/orders/:id` | id + Authorization → `OrderView` | Safe capability-scoped read; applies source/payment review overlay | `ledgerMain`, `paidRefundContract` |
| `POST /api/v1/orders/:id/transaction` | id + Authorization → `PaymentInstruction` | Safe read of saved payable order; no allocation, signing or send; refuses closed deposit window | `orderWorkflowContract`, `SigningTransportCheck` |

The worker leaves are `CheckpointBackup Int64 -> ()`, `RecoverNativeSettlements`,
`RecoverNativeSources`, `RecoverNativeLocks`, `RunWorkerCycle`, `ObserveChains`,
`ReconcileCustody` (all `-> ()`), `PrepareOutgoing payment -> ()`,
`SignPreparedPayment payment -> transaction`, `ReconcilePayment transaction -> ()`,
`QueuePayment transaction -> Int64`, `BroadcastPayment transaction -> ()`.
They are critical worker-only instructions, implemented by `Critical.hs` and
specific Store operations. The cycle observes/reconciles while paused; preparation,
queue/send and signing require their saved policy/readiness checks. The guarded
payment boundary pauses on failure. Recovery never implicitly resumes intake.

The four signer leaves and result constructors are listed above. Their payloads
are respectively `(deployment,payment,generation)`, `(deployment,decision)`,
`(deployment,parent,fee)` and `(deployment,minimumSequence)`. A request names saved
work, never arbitrary transaction bytes. `runProcess` contains the only
`evalCritical` call; `Critical.hs` contains the only generated signer client.
`SigningTransportCheck` verifies HTTP authentication/result identity;
`StoreCheck.tlsMain` verifies actual HTTPS and changed-during-signing refusal.
The latter mode is separate from the default PostgreSQL suite.

### Operator and administration inventory

The private operator envelope is JSON on stdin to `ecx-bridge operator CONFIG`.
`Control.controlPlan` rejects unknown fields and selects these closed leaves:

| Commands | Inputs after `operation` | Result / implementation and checks |
| --- | --- | --- |
| `status`, `native-reviews` | none | Safe `ServiceStatus` / review tuples; `Critical`, `ledgerMain` |
| `pause`, `resume` | reason / none | `()`; explicit pause/resume readiness; `serverMain` |
| `refund` | deposit | Saved `RefundAuthorization`; `refundContract`, `paidRefundContract` |
| `repair-completed-order` | order | `()`; only verified settled conversion+refund repair; `paidRefundContract` |
| `withdraw-fees`, `cancel-fees` | id,asset,amount,recipient,reason / id,reason | Payment/status text; `ledgerMain`, `earnedCancellationContract` |
| `allocate-treasury`, `classify-spend` | deposit,split,reason / chain,transaction,reason | Sequence; `treasuryContract` |
| `cancel-preparation` | payment,generation,reason | `()`; `cancellationContract`, `earnedCancellationContract` |
| `retry-solana` | transaction,reason | `()`; separate paused approval; `expiryContract` |
| `rebroadcast-native` | transaction,recovery,reason | Same transaction ID; `nativeReplacementContract`, `serverMain` |
| `draft-replacement`, `sign-replacement`, `cancel-replacement` | parent,fee,reason / decision / decision,reason | Decision / transaction / `()`; `nativeReplacementContract`, `tlsMain` |
| `cover-source-loss`, `approve-covered-source`, `approve-source-recovery` | deposit,recovery,float,earned,reason / payment,recovery,reason / payment,restoration,reason | `()`; `restorationContract` |

These commands retain their operation-specific paused-state, ownership, current
evidence, budget and reason requirements; successful parsing grants none of them.
Only `pause` is allowed as a critical operator action in observation-only mode.

The bridge CLI also retains `configure`, `start [DIRECTORY]`, `check-config`,
`check-signer`, `initialize-ledger`, `serve`, `observe`, `signer`,
`backup-native-wallet`, `restore-native-wallet`, `backup-custody`, `check-custody`,
`upload-custody`, `recover-custody`, `restore-ledger`, `recover-ledger`,
`adopt-ledger`, `retire-ledger`. Exact positional forms remain in `app/Main.hs`
and OPERATIONS. `ConfigureCheck`, `setupMain`, `fenceMain`, `archiveContract` and
the native/custody modes cover their distinct boundaries. Configuration/start are
local setup, not extra HTTP routes; signer keys remain outside worker resources.

`ecx-token` retains `configure`, `keygen`, `enter-key`, `import-key`, `prepare`,
`check`, `sign KEY TRANSACTION`, `prepare-offline`, `sign-offline`, `submit-file`,
`submit`, `recover`, `status`, `inspect-policy`, `address`, `nonce-address`,
`nonce-rent`, `associated-address`, `metadata-address`. Its closed transaction
verbs are `mint`, `burn`, `create`, `associated`, `metadata`, `nonce_mint`,
`create_nonce`. `Token.Operation` separates safe preparation/network reads from
key/sign/send operations; `token-test` covers codecs, effects, private files,
terminal key entry, offline intent and recovery. Recent-blockhash input acquisition
and durable nonce signing retain their different freshness rules.

`ecx-pool` retains `address`, `inspect`, `quote-mainnet`, `prepare`, `check`,
`sign`, `prepare-position`, `check-position`, `sign-position`, `prepare-liquidity`,
`check-liquidity`, `sign-liquidity`, `submit`, `status`, `recover`.
`Pool.Operation` separates inspection/preparation from saved-attempt signing/send.
Pool creation, full-range position/boundary initialization, deposits, withdrawals
and collection are exercised in `pool-test`. Reinvestment is an explicit liquidity
operation; unattended compounding, multisig and LP locking are not implemented scope.

### Formats and failure semantics to retain

`Wire.hs` is the exact HTTP field/enum codec contract: `OrderRequest` has
`direction,input,recipient,refund,sourceOwner,idempotencyKey`; `OrderView` has
`orderId,request,quote,status,deadline,depositInstruction,payoutTx,policy`.
Payment instruction fields are `uri,reference,mint,amount,refundPolicy`.
Public configuration strips `pub` and lowercases the first letter. Amounts remain
base-unit strings; quotes have `gross,fee,net`. Missing Authorization is a Servant
failure; valid syntax with rejected authority/policy returns HTTP 409 with
`{"error":code}`. Body/concurrency/cross-origin/admission refusals retain
413/503/403/429. Unexpected infrastructure exceptions are not successful defaults.

Public status vocabulary is `Provisioning`, `AwaitingDeposit`, `ExpiredUnfunded`,
`NeedsReview`, `Ready`, `Preparing`, `Paying`, `Refunding`, `Refunded`, `Paid`.
`PaymentReady/Paying/Paid/Review/Cancelled` is the current internal projection,
not a replacement public enum. Preserve capability hashing, idempotency conflict,
Solana reference and original conversion payout-link precedence.

Retain strict configuration fields/fingerprint (`Config.hs`), private setup
source-file references (`Configure.hs`), token `.ecx-token/ecx-token.json` defaults
and legacy read-only fallback. Preserve saved `PaymentTerms`, `SignedAttempt`,
native/Solana draft/message bytes, token/pool attempt/parent formats, custody archive
formats 1/2 and schema-21 backup manifests. Exact keys, decoder bounds and rejected
unknown fields remain owned by their existing codecs; no new compatibility codec.

Policy/conflict (`*_conflict`, `*_invalid`, `*_required`) means no successful
mutation. Stale evidence (`*_changed`, freshness/coverage refusals) requires a fresh
bounded inspection, not weaker checks. Unavailable RPC/DB is not proof of absence.
`rpc_transport_unknown_outcome`, `signer_outcome_unknown`, `operator_outcome_unknown`
retain saved work for inspection; never automatically create a successor.
`corrupt_*` and a fenced connection require investigation/recovery. `guarded` payment
failures pause intake; signing exceptions pause with `signing_requires_review`;
scans retain cursors and mark failure. Safe customer reads do not resume or pause.

### Invariant and interruption map

| Invariant | Pure/adapter rule | Durable/process enforcement | Existing evidence and limitation |
| --- | --- | --- | --- |
| I01 | Profile/genesis/checkpoint/mint parsers | Deployment fingerprint, startup role/process checks | `ChainCheck`, `serverMain`, `tlsMain`; issuer approval external |
| I02 | `Domain` Amount/Quote/Payment, exact codec checks | Immutable request/quote/policy/attempt triggers | Main amount/accounting properties; `ledgerMain` historical terms |
| I03 | `Domain.settlement`, bounded cost amounts | Balanced event posting, unique event IDs, append-only journal | `ledgerMain`, archive comparisons |
| I04 | Receipt binding, source proof, allocation arithmetic | Unique deposit use, held principal/operating/fee reservations | Promotion/refund/treasury contracts |
| I05 | Verified outcome/family classification | Intent/attempt winner checks + unique settlement event | Duplicate settlement and native family contracts; alternate-chain history still open |
| I06 | Saved-byte/protocol equality | Preparation/attempt/queue sequences; no signer broadcast | TLS/signing/expiry/restart contracts; unknown outcomes retained |
| I07 | Subject equality and 60-second freshness | Custody revision, scan anchors, re-read before/after signing | `tlsMain`, native readiness/custody regression; new code must rerun these |
| I08 | Closed GADTs, contexts, unique results | Sole critical dispatch; auth/SELECT-only role/OS/RPC separation | Main, SigningTransportCheck, TLA+; bounded model only |
| I09 | Identity/sequence/coverage checks | Advisory lock, deployment row, host fence before commit, backup | `fenceMain`, `archiveContract`; physical independent restore open |
| I10 | Fee/rent/generation/deadline bounds | Immutable cost times, operating clock, holds, eight generations | Main/chain and expiry/cancellation/budget contracts |
| I11 | Exact observed effects; unknown differs from absent | Atomic page+cursor+evidence, current custody revision | ObservationCheck, custodyContract; fixtures are not real reorgs |
| I12 | Family/source/cancellation proof checks | Append-only loss/cover/return/winner approvals | restoration/replacement/cancellation contracts; live conflicts open |
| I13 | Exact file/key/manifest validation | Ownership/mode/link refusal, exclusive publication and locks | ConfigureCheck, SigningTransportCheck, archive/token/pool tests |
| I14 | Stable wire/CLI and derived display precedence | Capability scope, paused boot, protected setup | API/server/refund/token/pool checks; customer-wallet interaction open |
| I15 | Bounds on amounts/lists/bodies/history | Concurrency/admission/RPC budgets, fenced failures | Chain/transport checks; production load/security review open |

Before address allocation, only the saved claim survives; its owner can allocate,
others recover the same label. After preparation, exact generation/plan/holds
survive; unsigned recovery cannot discard foreign locks. Backup acknowledgment
binds its durable sequence, not newer writes. Lost signing replies leave preparation
and no permission to send. Once saved, exact signed bytes survive every retry.
Queue records a new sequence; send requires coverage and fresh final checks of that
queue. Lost send replies are resolved by observation of those bytes. A confirmed
outcome settles in one transaction; redelivery compares saved evidence and cannot
post principal again. A fence advanced before an uncertain commit may exceed the
ledger: startup refuses rather than lowering it. These are the D06 interruption
points exercised by the existing fixtures; a new pure decision cannot remove them.

Representative histories already live in `StoreCheck`: initial/unpaid and prepared
payments in `ledgerMain`, exact signed/queued fixtures in `test/fixtures`, successful
and extra-refund paths in `paidRefundContract`, failed/expired in `expiryContract`,
unsigned cancellations in both cancellation contracts, native family/source work in
`nativeReplacementContract`/`restorationContract`, and uncertain publication/restore
in `archiveContract`/`fenceMain`. Reuse their closed Opaleye fixtures. Their literal
keys, fake RPC responses and deterministic identifiers are never deployment data.

### Concrete lifecycle extraction contracts

`Lifecycle.hs` owns the existing `PaymentView`, `PreparedPayment` and
`RecordedAttempt` records; Store reexports them to avoid a broad caller migration.
These are the payment, preparation and attempt facts, not duplicate wire DTOs.
`Payment` already owns `Funding` (conversion/refund/earned), recipient and amount;
`PaymentTerms` owns policy/limits. Their constructors grant no execution authority.
The initial module deliberately retains schema-21 `PaymentStatus`; the proposed
economic phase is introduced only with its proven projection/migration.

| Current field/fact | Owner and intended fate |
| --- | --- |
| `orders.status`, `orders.payout_tx` | Admission and duplicated payment display; narrow admission state and derive payment view in G |
| `obligations.status` | Duplicated economic progress; retire in G after all callers use the payment root |
| `intents.resolved` | Incomplete payment lifecycle; replace by root phase/generation/winner/original settlement event in G |
| Order request/quote/policy/costs, capability/deadlines/instruction | Immutable order facts; retain exact historical terms and scope |
| Deposit anchor/depth/eligibility/allocation and source evidence | Receipt/execution eligibility; separate from whether principal was paid |
| Preparation generation/policy/draft/retired/cancelled | Exact plan and allowed successor/cleanup; retain |
| Attempt bytes/policy/generation/state/queue sequence/observation | Chain execution evidence; retain every byte and distinct phase |
| Fee holds, principal/operating reservations | Capital ownership and release/transfer; retain, not another economic phase |
| Journal events/postings, withdrawals/cancellations | Once-only economic effects and explicit earned funding; retain |
| Replacement/expiry/source loss/cover/return/approvals | Recovery evidence bound to subject/work; retain separately |
| Deployment/custody sequence, clock, scan origins/checkpoints/health | Shared authority/freshness bounds; retain, no parallel revision system |

Target phase validity is `Ready` with no active generation/winner, `Active g` with
exactly one belonging preparation, `Settled tx` with a belonging retained attempt
and immutable original settlement event, or `Cancelled` with cancellation evidence
and no active work. Execution review is independent, including after settlement.
Old-generation evidence cannot authorize the active generation. Until G, the
schema-21 rows/constraints enforce their existing combinations and unknown states
continue to refuse; the refactor must not guess a successful mapping.

Each pure decision receives only the facts needed by its closed Store leaf:

| Decision family | Actor / facts / result / idempotency |
| --- | --- |
| Settlement or finalized failure | Worker; expected/current queued attempt, funding, exact outcome/cost proof, unresolved fee hold, prior winner/failed cost. Replay or apply principal/cost/release/display effects. Same proof replays; changed proof/bytes/allowance conflicts. |
| Preparation/draft/signature retention | Worker; funding, saved limits/source/readiness, current work, allowed next generation, holds/budget. Reuse exact plan or create one permitted generation; no external effect in the decision. |
| Queue/send | Worker; current signed attempt/preparation/source, family selection, coverage, current readiness. Reuse queue or allocate its sequence / authorize exact saved bytes; no new bytes or signing. |
| Admission/promotion/refund | Customer/worker/operator respectively; immutable terms/receipt ownership/deadlines, capacity and saved allocations. Reuse/create order, promote once, or bind full-principal refund. No caller-selected refund recipient. |
| Treasury/earned fees | Operator; paused/fresh verified unbound receipt or free earned balance, exact split/recipient, current holds. Allocation/reservation/cancellation with balanced movements and immutable reason/replay identity. |
| Cancellation/expiry/retry | Operator or observation worker; exact active unsigned work or proved nonexecution, cleanup/approval/generation/source. Begin/finish/retire/approve separately; no timeout-derived permission. |
| Source/replacement/winner recovery | Operator/observation worker; exact bounded saved family, latest proof/approvals, source/custody and original postings. Preserve liabilities; apply only justified deficit/cover/return/cost adjustments. Principal never replays. |
| Read/control/backup/setup/admin | Retain their specific closed operations and independent proof/resource contracts above. They do not gain a generic lifecycle commit method. |

Pure results are narrow operation-specific data, not table patches or callbacks.
Store gathers current facts and computes the result inside its locked transaction.
The first slice uses `Either Text` with the existing exact refusal codes, avoiding
a second competing error-to-wire translation table during extraction. The semantic
categories remain the conflict/stale/unavailable/corrupt/uncertain mapping above;
no catch-all success or retry is introduced.

Stable comparisons include full payment ID/funding/recipient/terms, preparation
generation/policy/draft/fee, exact attempt bytes and queue identity, current subject
source/approval and its necessary freshness/coverage. Normalize only the old/new
attempt state/observation when comparing an exact settlement replay, as the baseline
does. Unrelated deployment sequence changes are not subject changes; current
custody and scan checks still run independently. Do not normalize amounts, protocol
bytes, generation, evidence or ordering to make differential tests pass.

`LifecycleCheck` supplies bounded funding/delivery histories and validity-preserving
shrinkers. Its expected account map and paid set are independent of production
accounting. The new adapter uses actual pure settlement decisions for replay;
the baseline `Domain.settlement` adapter remains a test-only accounting comparison.
Settlement, preparation and queue/send now use the pure decisions in their closed
Store operations. Current facts are loaded under the existing deployment lock; no
caller may submit a precomputed decision or an arbitrary patch for commitment.
The existing real-PostgreSQL duplicate-settlement, extra-refund, stale-generation,
missing-backup and native-source-refresh regressions remain the durable oracle.
The separate HTTPS fixture suspends signing, invalidates custody, then proves the
second read refuses and the held gate recovers. Negative accounting mutations must
fail, demonstrating that the independent model is capable of detecting differences.

The initial pure slice consists of `decidePreparation`, `decideQueue`, `decideSend`
and `decideSettlement`. It has no IO, Store import, database callback or signer
resource. It cannot reserve, sign or send anything. Snapshot constructors remain
ordinary data; only specific Store leaves may reload and apply their results.

| Previous decision owner | Pure owner / remaining boundary |
| --- | --- |
| `settlePayment` fee/rent/proof bounds | `decideSettlement`; chain finality/effects verification stays in the adapter |
| `settlementContext` subject/replay/hold/winner checks | `decideSettlement`; Store loads current attempt/funding and at most one active hold/winner |
| `failSolana` exact failed-charge replay | `decideSettlement`; only recorded external fee charge is supplied, no absence inferred |
| `resolvePayment` customer outcome and paid-link precedence | `SettlementEffects`/`CustomerResolution`; applying a new outcome resolves intent/releases fee hold, success additionally releases customer reservations |
| `preparePayment` reuse/generation/fee/source/capital/budget decisions | `decidePreparation`; closed readers still prove lineage/source/identity and bind exact reservation purpose/currency |
| `intakeReady` snapshot predicates | `checkIntake`; readers must supply exactly the three named streams and error-free matching custody revision |
| `markBroadcast`/`authorizeSend` state/coverage decisions | `decideQueue`/`decideSend`; Store owns queue sequence, adapters retain final live chain acceptance checks |

Preparation budget input is the total before mutation. Subtract only this payment's
transferred customer operating hold (initial preparation) or unreleased prior fee
hold (authorized successor). A retired/expired hold already released is not subtracted
twice. The rolling spend total uses the Store's existing durable operating clock.
Live exact preparation replay deliberately does not require fresh admission; it
grants no new signing/send authority. All such later operations recheck readiness.

Checkpoint C (`a4aa94f`) compared the extracted settlement decisions with the old
Store writer across fifteen success/failure/replay/refusal paths. The temporary
comparison adapter is now removed. The independent model and original durable
assertions remain; no old/new runtime switch or second paying implementation exists.

Preparation's reader projects exact lineage, source authorization, holds and the
budget before mutation. Its writes consume only an approved `CreatePreparation`;
replay retains the existing generation/draft. Successor holds are replaced directly
after the decision, removing the old release/recheck/reset sequence. Required
single-row writes are checked. Queue allocation similarly checks exactly one
previously signed, unqueued attempt; send authorization returns its saved bytes.
`checkSendPayment` also validates paused native replacement subjects without
mistaking that permission for intake or broadcast authorization.

The PostgreSQL contracts now inject preparation/settlement constraint failures and
a deferred queue commit failure, comparing complete financial rows, holds, cost
clock/history, attempts and postings after rollback. Unexpected errors fence the
writer; ordinary policy refusals retain reuse after rollback. An independent
connection holds the deployment row while requests wait, then commits a competing
operating expenditure or recovery pause. Decisions must use those committed facts.
Two same-order requests also race behind that database lock; the sole-writer
advisory claim still excludes a second worker. These are bounded interleaving
checks, not a proof of every possible schedule or real-chain recovery history.
