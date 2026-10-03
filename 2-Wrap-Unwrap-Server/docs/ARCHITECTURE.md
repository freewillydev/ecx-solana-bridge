# Architecture and financial contracts

This guide describes the current source and the invariants reviewers must verify.
It is not release certification. [RELEASE-REVIEW.md](RELEASE-REVIEW.md) separates
historical real-chain evidence from outstanding acceptance; the
[implementation plan](IMPLEMENTATION-PLAN.md) tracks unfinished simplification.

## Audit path

| Responsibility | Source |
| --- | --- |
| Amounts, quotes, records | `types/Bridge/Types.hs`, `Model.hs`, `Ledger/Model.hs` |
| Closed operations and existential requests | `types/Bridge/Operation/Internal.hs`; customer facade `Operation.hs` |
| Four customer routes and pure handlers | `api/Bridge/API.hs` |
| Authorization, safe/critical evaluation, scheduling | `src/Bridge/Postgres/Runtime.hs` |
| Admission and instruction provisioning | `src/Bridge/Admission.hs`, `Order.hs`, `Postgres/Order.hs` |
| Preparation, saved-byte send, settlement | `src/Bridge/Payment.hs`, `Settlement.hs`, `Postgres/Preparation.hs`, `Postgres/Settlement.hs` |
| Native/Solana protocol validation | `src/Bridge/Native*.hs`, `Solana*.hs`, `RPC.hs` |
| Recovery and custody | `src/Bridge/Recovery.hs`, `Reorg.hs`, `Reconciliation.hs`, corresponding `Postgres/` operations |
| Transactions, accounting, immutable records | `src/Bridge/Postgres/Ledger.hs`, `Schema.hs`, `migrations/postgresql/` |
| Dedicated signer and local operator control | `src/Bridge/Operator.hs`, `Signer.hs`, `Control.hs` |
| Host fence and backup | `src/Bridge/Postgres/Fence.hs`, `Backup.hs`, `Maintenance.hs`, `deploy/` |

The deployment has one HTTP/API process and one dedicated signer process.
The HTTP process serves HTML/CSS and the Haskell browser compiled by GHC's
JavaScript backend. It evaluates customer requests directly; there is no HTTP
proxy to a second worker. PostgreSQL, native daemon, Solana RPC and backup tooling
remain external dependencies. Token administration and market liquidity have
separate keys and live outside bridge custody in the other numbered folders.

## Main.hs, existential requests and severity

The exact user-supplied reference is [reference/Main.hs](reference/Main.hs), from
“Add interactive environment prompts”, supplied 2026-10-02. Its SHA-256 is
`f1d0777a8d2fddd62881aa5d85f518884c9d4efb451480f1520a677ab2319ea2`.
Keep it unmodified, outside production builds, and read it before changing this boundary.

The production core retains its typeclass/constrained-existential/GADT design:

```haskell
class Operation (s :: Severity) (op :: Type -> Type) | op -> s where
  command :: op a -> DSL s a

data Request (s :: Severity) a where
  Request :: Operation s op => op a -> Request s a

resolve :: Request s a -> DSL s a
resolve (Request operation) = command operation
```

`Request s a` hides the operation type, retaining its dictionary, result type and
severity. `Plan a` wraps that request in a safe/customer/operator/worker envelope.
Customer handlers have type `ServerT CustomerAPI Plan`; they package operations,
not IO or an already evaluated result. Servant's hoist calls `interpret`, which
resolves the dictionary to a DSL and evaluates it. Only the resulting concrete
record is serialized as the HTTP response. The existential is not wire JSON.

Safe and critical evaluators remain separate. The runtime has one `evalCritical`
call under its workflow gate; authority is checked before waiting for that gate.
The gate spans chain calls and individual database transactions, so scanning cannot
change a payment's observed source midway through a workflow. Safe reads remain
concurrent. The signer has its own restricted signing evaluator and serialization gate.

Severity and caller permission are distinct: order creation is critical without
allowing customers to sign or administer funds. Observer mode allows pause and
recorded-effect reconciliation, but refuses order creation, resume, signatures and
broadcasts. Closed operator commands cover pause/resume, refunds, treasury decisions,
cancellation, source recovery, replacement and rebroadcast. No HTTP request can
supply arbitrary SQL, IO, chain methods, signed bytes to authorize, or an evaluator.

Cabal enforces three private components. `bridge-types` owns the grammar and pure
records. `customer-api` sees the restricted operation facade, with Internal hidden
by a module mixin, and has no runtime/database/signer/client dependency.
`bridge-runtime` owns capabilities and evaluation. The separate `ecx-build-assets`
package provides Cabal hooks for SDK/browser builds; it adds no runtime service.
Keep compile-failure checks for forbidden customer imports and authority construction.

The reference sketch is not itself production-ready: remove its severity-to-operation
functional dependency because one severity has many operations; never permit a safe
evaluator to accept critical input or downgrade WrapEcx to SafeWrap. Its polymorphic
RequiredOperation and unfinished runSafe are not escape hatches to implement.
Do not introduce severity casts, incoherent authorization instances, MonadIO, arbitrary
callbacks, generic RunQuery/RunSQL, or an unnecessary free-monad framework. Weekly
supply limits and multisig in its comments are design notes, not current guarantees.

## Database and custody authority

All application row access, diagnostics and test fixtures must use Opaleye, within
implementations of specific closed operations. Connections and generic query
callbacks stay outside handlers. libpq connection/transaction control and reviewed
schema/role/fault-injection DDL are separate infrastructure. SQLite is retired.

Safe evaluation uses a distinct SELECT-only role and read-only transactions.
Startup checks inherited privileges, schema creation, relation/column writes,
sequence access and elevated role flags. Fixed catalog expressions do not accept
caller-selected SQL or function names. The signer also uses a read-only ledger role.
Offline installation/migration authority is not a customer or operator HTTP route.

Ledger actions serialize on the deployment row; session ownership excludes another
paying worker. Host fencing persists a monotonic sequence before commit and rejects
stale, wrong-identity or retired ledgers. SQL/IO errors or failed rollback fence the
connection. Policy errors permit reuse only after successful rollback. Restart
begins paused. No SQL transaction spans chain RPC, signing or remote backup.

Only the critical evaluator communicates with the signer through generated Servant
ClientM calls. Its HTTPS API binds to 127.0.0.1 and exposes sign-preparation,
draft-replacement and sign-replacement, tied to saved decisions. BasicAuth uses a
256-bit protected token; the worker trusts only the protected configured certificate
with hostname validation. No proxy, redirect, automatic retry or unbounded response
is allowed. Token/certificate ownership and directory permissions are checked;
the TLS key is signer-only. Local operator control remains a separate mode-0600
framed Unix socket, not an operator HTTP API or a signer transport.

The signer checks deployment, saved authorization, transaction effects and limits
before and after signing; it never broadcasts. The SDK Rust library is reached only
through bounded Haskell FFI, with caller-owned buffers and no allocator/pointer
ownership crossing the ABI. Unsigned construction supplies public identities and no
key path; Haskell independently validates messages and signatures. Simulation uses
zero signatures, never usable signed bytes. Separate OS users and restricted native
RPC credentials must prevent bypass via a full wallet cookie. Deployment proof of
that separation and real two-process acceptance remain release work.

## Customer contract

| Route | Result |
| --- | --- |
| `GET /api/v1/config` | Profile, limits, fees, public links and availability |
| `POST /api/v1/orders` | Create/recover an immutable order in authorized paying mode |
| `GET /api/v1/orders/:id` | Authorized saved-order view |
| `POST /api/v1/orders/:id/transaction` | Authorized payment instructions for the bound order |

No wallet connection is required. Native wrapping supplies a Solana recipient and
native refund address; redemption binds the native recipient and Solana Pay
reference, then derives the refund owner from the verified deposit. The customer's
wallet signs its own deposit. Copy/QR/payment links and saved-order recovery are
presentation, not authority to credit a deposit.
There are no public operator, health, readiness or deposit-hint endpoints.

Before creating an order, save a random 32-byte capability and idempotency key.
Send `Authorization: Bearer <64 lowercase hex characters>`; the ledger stores a
domain-separated hash. A public order ID is insufficient. An identical capability,
key and request recovers the original order; changed immutable content conflicts.
Bridge errors currently map to JSON errors with HTTP 409; parser/transport rejection
is separate. Error categorization and funded wallet UX still require acceptance.

Both conversion assets use eight decimals. Amounts are base-unit decimal strings,
not JSON numbers, exponent notation or signed/fractional text. Intermediate totals
use Integer; persisted amounts obey signed-64-bit and lower configured bounds.
For new orders, fee = ceiling(gross * 100 / 10000), net = gross - fee; reject net <= 0.
Historical terms are immutable. Network fees and permitted ATA rent are operating
costs and cannot reduce quoted net. Save direction, amounts, destinations, source
binding, deadlines, confirmation/finality policy and deployment fingerprint.
Only an exact qualifying deposit earns the conversion; ambiguous, partial, extra,
late or unknown receipts retain their liabilities and enter review/refund handling.

`Admission` owns both preflights, called once by the order workflow. It does not
reserve funds or grant signing/send authority. Native admission verifies the real
checkpoint/network and daemon-classified supported recipient/refund scripts, refusing owned/watch-only destinations. An unsigned funding
probe applies actual daemon dust/fee policy to the exact amount, with no new address,
lock or signature. It is conservative and is repeated at payment preparation.
Wrapping admission on Solana validates real deployment, wallet owners, legacy ATAs, mint/program,
decimals, authority/layout, balances, fees, rent and blockhash context. Missing payout
ATAs may be created; prefunded empty accounts reduce rent, never below zero.
Delegates, close authorities and unsupported owner/account types are refused.
Redemption admission checks deployment identity; source ownership is established from
the actual Solana Pay deposit, without a pre-bound customer wallet.
Admission/simulation success is not a future execution guarantee.

Native address provisioning commits a unique claim before getnewaddress. Only the
claim creator may allocate; retries recover the exact label and owned, solvable,
non-change P2WPKH address. Missing/ambiguous evidence cannot allocate again. Record
the instruction and critical sequence before backup or exposure. First exposure
requires unexpired, unpaused intake, retained holds, fresh scans/custody and applicable
backup coverage. Already issued instructions remain historical data through expiry
or pause. Recovery cannot renew deadlines or reopen released reservations.

## Accounting and payment lifecycle

Each append-only event balances separately per asset. `external` is a counter-entry,
not spendable capital. `principal` protects customer deposits; `unallocated` protects
unknown receipts; `float` is payout inventory less reservations; `earned` is settled
bridge revenue; `operating` pays network costs; `backing` and `lp` are protected
allocations. Proven source loss uses `source_deficit` without erasing customer claims.
Never infer available float from a wallet balance or expose arbitrary credit.

For a new 100-unit conversion, settlement moves source principal -100, source float
+99 and earned +1, then destination float -99 and external +99. A full refund returns
principal without taking inventory a second time. Network fees and account rent are
separate operating expenses; a finalized failed Solana transaction charges only its
verified fee. No settlement is posted merely because bytes were signed or submitted.

Treasury allocation requires a verified eligible unbound receipt, paused operation,
current custody and an immutable ownership attestation; splits equal the receipt,
and SOL only funds operating. Classification of an already observed operator spend
protects customer attempts and active holds, then records costs once. Changed evidence
reopens review. Fee withdrawal currently has reservation/cancellation storage only;
its complete signing/send workflow remains unfinished.

Quotes reserve conversion and alternate refund operating allowances, including rent.
Admission requires allocation minus holds to cover costs, and the last 86,400 seconds
of booked expenses plus holds/new costs to fit configured daily limits. Rejections
commit no order/hold. Preparation transfers allowances once; expiry releases only
provisional holds; funded or signed work retains its protection. Immutable cost
booking times and a monotonic durable clock prevent backward time from resetting
budgets. Old unfinished orders without saved cost policy require explicit review.

Trace the durable sequence:

1. Admit and bind the order, reserve inventory and both cost allowances.
2. Observe an eligible deposit and create its conversion/refund obligation.
3. Reserve one outgoing intent per chain and save a preparation generation/draft.
4. Cover the required durable decision before signing; independently validate the
   signature and persist exact bytes. A lost reply grants no send authority.
5. Record BroadcastIntent and its critical sequence; obtain applicable backup
   acknowledgment. Recheck source, pause/readiness, limits and Solana validity.
6. Authorize and submit only those saved bytes. Uncertain responses retain all work.
7. Independently observe the actual finalized economic effect and atomically settle
   principal, fees, costs and reservations. A unique settled-winner constraint and
   transaction checks prevent a second economic payout.

Normal states are Provisioning, AwaitingDeposit, Ready, Preparing, Paying and Paid;
review, expiry and refund states retain distinct liabilities. Native funding saves
its exact template before locks/signatures; only its saved inputs may be locked.
Validate confirmed owned prevouts, recipient/change, fee ceiling and replay fields.
Solana preparation saves exact message/reference/blockhash/validity, fee/rent limits
and request; locally validate SDK bytes and Ed25519 signature. Recorded attempts
are immutable, including across restart. Broadcast acknowledgment is not settlement.

## Recovery, observation and restart

Scanner pages commit observations and next cursor atomically against the previous
cursor. Keep immutable origins for native, custody-token and fee-payer-SOL histories.
The SOL origin cannot omit earlier funding. Unknown bindings/outflows are quarantined;
a merely signed attempt does not explain an on-chain outflow. Complete historical
source ownership/reference/economic effects are required, not a copied memo or hint.
Provider errors retain the cursor; repeated observations cannot duplicate value.

Custody compares the journal with actual balances plus only verified, observed but
unbooked outgoing effects. Signed/unseen bytes add no adjustment. Native wallet,
active-block/history views must agree; contextual finalized Solana accounts/history
must agree, including any required independent provider. A ledger revision fences
RPC snapshots; financial changes invalidate prior certification. Intake and first
instruction exposure require a matching check no older than 60 seconds. Unexplained
balances/history fail closed; a successful check alone does not resume service.

Paused recovery may book recorded effects and reconstruct owned native locks, but
cannot prepare or broadcast new payments. Missing locks may be reapplied; foreign
locks are not cleared. Pending cancellation cannot relock inputs. Recovery visits
all pending families even after an individual observation failure, pauses and retains
the work. Errors are typed internally; durable evidence/audit remains authoritative.

Unsigned cancellation journals exact policy/draft cleanup before changing locks,
requires pause, source and custody checks, and excludes any recorded signature in
that generation. Never call lockunspent with an empty list. Lost replies leave
cancellation pending; completion retains principal/inventory/unused fee allowance.
Old-generation callbacks cannot affect newer work. Generation count is bounded at eight.

Solana expiry requires every configured provider to prove finalized height beyond
validity, invalid blockhash, absent historical status/transaction, and complete token
and fee-payer histories through immutable origins. Missing/truncated evidence is not
expiry. Retire only unused fee capacity, retaining bytes and principal/inventory.
A separate paused, immutable operator approval is required for another generation;
amount, recipient and reference remain unchanged, costs are reserved again.

Native replacement retains inputs, sequences, version/locktime, recipient/amount,
change address and fee ceiling; only change decreases as fees increase. Bound family
size and draft/generation decisions; validate every saved member and two consistent
chain/wallet views. Foreign spenders or ambiguous winners require review. Draft,
cancellation and signed-member records are immutable; cancelled drafts cannot reactivate,
unsigned decisions block conflicting sends, and ordinary sending selects the newest member.
All family members remain observable. Settle the actual sole winner; a later proven
winner change journals its fee adjustment and proof without paying principal again.
Same-winner reconfirmation changes no money. Real winner-change acceptance remains a gate.

Source eligibility loss retains obligations, holds, drafts and attempts. Native loss
requires corroborated wallet conflict, absent mempool entry and spent/missing UTXO;
unavailable data is not loss. A proven loss posts source_deficit against external.
Return reverses that deficit once, with review until saved confirmation policy holds.
Restoration approval checks the exact suspended-work hash, latest decision, source,
custody revision and unchanged obligation; it does not sign or resume. Later send
coverage must include the approval. A covered-source approval is a separate decision.

Loss coverage consumes only genuinely free native float/earned capital for the full
receipt, never principal, operating, backing or LP funds. Preserve source ineligibility
and customer claims. Coverage/return postings and immutable decisions are atomic;
return restores the original capital split once. Unavailable evidence cannot free it.
Explicit rebroadcast of an evicted settled native payment preserves its exact bytes,
review/approval sequence, current source proof and backup barrier. It never invents
replacement authority. Unresolved/reviewed work, unexplained observations, deficits
or missing legacy cost policies block resume; source restoration alone is insufficient.

Read-only RPC retries use a fixed allowlist, bounded attempts and capped Retry-After.
Wallet mutations, sends and unknown outcomes are not automatically retried. Chain
protocol behavior comes from the real adapters and captured vectors, not a local
invented network. Database fixtures and injected failures are not live-chain evidence.

## Backup and release boundary

Where configured, deposit exposure/signing/send gates require durable acknowledgment
covering the exact required sequence; successful callback return alone is insufficient.
Backups must preserve PostgreSQL financial records, exact signed attempts, native
wallet/descriptors/keys, Solana key, private signer configuration and sequence/identity
manifests. Key seeds alone cannot recover order/payment decisions or prevent duplicates.

Restore into staging from authenticated off-host encrypted storage, verify identities,
restore/adopt the sequence fence without lowering it, migrate forward, rescan/reconcile
both chains and pending work, then explicitly resume. Retire the old worker and revoke
its signing authority; a local marker cannot revoke copied keys on another host.
Never overwrite the only surviving ledger/keys or initialize an empty ledger as recovery.

Outstanding work includes fee-withdrawal integration, remaining test/tool consolidation,
actual Solana Pay wallet signing, deployed signer/native-RPC isolation, clean-host
off-host restore, permanent-loss/winner-change acceptance, canonical authority/backing
and funded flows, dependency/license review and independent security review. Linux
ARM64/x86 packaging acceptance follows substantive runtime work. Passing local tests
or historical artifacts does not close these gates or authorize public activation.
