# Financial and API contracts

These are the contracts implemented in the current ledger plus the requirements that must be completed before intake. The disabled worker does not currently expose order creation or payout execution.

## Amounts and quotes

Both assets use eight decimal places. API amounts are base-unit decimal **strings**; `"3"` is three units and `"100000000"` is one coin. JSON numbers, exponent notation, signs, extra precision and overflow are rejected. Intermediate calculations use Haskell `Integer`; persisted amounts fit nonnegative signed 64-bit integers. Operational limits are lower and explicit in configuration.

Wrap fee: 20 basis points. Redemption fee: 100 basis points. For gross input `g`, `fee = ceiling(g * basisPoints / 10000)` and `net = g - fee`. A nonpositive net is rejected. Native fees, SOL fees, and permitted ATA rent are operator costs; they never reduce the quoted net. ATA rent and rolling operating-budget enforcement remain to be integrated.

An order permanently records direction, gross/fee/net, recipient, refund destination, source wallet when applicable, deposit deadline, confirmation grace deadline, native confirmation depth, Solana finality policy, and deployment fingerprint. A later configuration change cannot alter the stored policy. Only one exact source deposit can receive the quoted conversion; partial, duplicate-sized extra, late, or otherwise unclassified deposits need review.

For redemption, the refund destination is the bound source Solana owner. A copied memo from another source wallet cannot authorize the order. Native orders bind a fresh daemon-generated address before it is exposed. Native address allocation and chain validation are not wired into the current creation endpoint.

## Chart of accounts

Every event has balanced postings separately for each asset. Journal rows are append-only. The `external` account is the counter-entry for transfers into/out of custody, not a spendable balance.

| Allocation | Meaning | Available for new payouts? |
| --- | --- | --- |
| `float` | Operator-designated payout inventory and settled net incoming proceeds | Yes, less active reservations |
| `principal` | Bound customer deposits awaiting conversion or refund | No |
| `unallocated` | Receipts lacking an authoritative saved order binding | No |
| `earned` | Source-asset bridge fees recognized after successful settlement | No automatic reuse |
| `operating` | Explicit network-cost budget | Only approved network costs |
| `backing` | Protected wrapped-asset backing allocation | No |
| `lp` | Separately allocated market liquidity | No |

Never initialize float from the wallet balance alone. Verified treasury receipts and the associated capital allocation must reconcile with chain balances. Current `fundAllocation` is an internal primitive; the verified funding workflow is unfinished and unavailable over HTTP.

Examples below use coins for readability; code uses integer base units:

| Event | Journal effects |
| --- | --- |
| Receive native 100 | Native principal +100, external −100 |
| Wrap pays wrapped 99.8 | Native principal −100, float +99.8, earned +0.2; wrapped float −99.8, external +99.8 |
| Receive wrapped 100 | Wrapped principal +100, external −100 |
| Redeem pays native 99 | Wrapped principal −100, float +99, earned +1; native float −99, external +99 |
| Full refund of a native partial deposit 0.01 | Native principal −0.01, external +0.01; no second reservation against float |
| Successful or finalized failed Solana network fee | SOL operating −actual fee, external +actual fee |
| Unknown native receipt 0.01 | Native unallocated +0.01, external −0.01; no automatic quote, refund, or rebinding |
| Signed/potentially sent payout | No settlement posting yet; existing destination and fee holds persist |

Reorg compensation, settled destination rollback, native replacement-family accounting, ATA-rent postings and rolling limits are **not implemented**. Current loss of source eligibility stops first-send authorization and pauses allocated deposits for review. That is a guard, not full reorg recovery.

## Durable states

`Provisioning → AwaitingDeposit → Ready → Paying → Paid` is the normal order path. `ExpiredUnfunded`, `NeedsReview`, `Refunding`, and `Refunded` handle exceptions. A quote reservation moves through quote/obligation/payment and is released on settlement or a safe cancellation. Expiry never releases a signed payment's reservation.

Signed bytes are immutable. The ledger permits one unresolved outgoing intent per chain. It records `broadcast_intent` and a critical sequence before first send. Ambiguous native sends never expire automatically; a new transaction or refund cannot bypass the unresolved intent. Finalized Solana failure charges its real fee while preserving full customer principal. Expiry/re-signing and native replacements require the remaining reconciliation implementation.

A scanner batch uses a compare-and-swap on its previous cursor and commits all observations with the next cursor. A conflicting receipt rolls back the entire page. Repeated observations do not duplicate journal value. Unknown bindings remain quarantined; discovering chain history after restoring an old database cannot prove that an unrecognized deposit was never paid.

The database starts paused after every restart and holds an exclusive worker file lock. Internal `resumeAfterChecks` is not an admin route and must only be wired after identity, history, solvency, and unresolved-attempt reconciliation are implemented.

## API and authorization

The shared Servant definition is in `src/Bridge/API.hs`.

| Customer route | Current behavior |
| --- | --- |
| `GET /api/v1/config` | Public limits, profile, fees, availability, development gate |
| `POST /api/v1/orders` | Disabled until acceptance and implementation are complete |
| `GET /api/v1/orders/:id` | Bearer-capability access to that saved order, with backup coverage check |
| `POST /api/v1/orders/:id/transaction` | Disabled |
| `POST /api/v1/orders/:id/observations` | Bound, limited signature hints; never payment authority |
| `GET /healthz` | Process liveness |
| `GET /readyz` | Returns 503 while paused |

Before sending a create request, generate/save a cryptographically random 32-byte capability and an idempotency key. Send the capability as `Authorization: Bearer <64 lowercase hex characters>`. The server stores its domain-separated hash. The same capability/key/request retrieves the same order after a lost response; changed immutable content conflicts. A public order ID is insufficient authorization.

```json
{
  "direction": "NativeToWrapped",
  "input": "100000",
  "recipient": "<actual Solana wallet address>",
  "refund": "<actual native refund address>",
  "sourceOwner": null,
  "idempotencyKey": "<client-generated identifier>"
}
```

The example describes the contract, not an enabled API. Semantic errors currently return structured 409 responses; complete external error categorization is still pending. A separate filesystem-restricted admin socket provides readiness, pause and audit reads. The public process cannot proxy that API. No SQL console or unrestricted signing endpoint exists.

## Backup boundary

Canonical profiles require off-host coverage of both immutable deposit instructions and signed `BroadcastIntent` before exposure/send. The snapshot primitive uses SQLite `.backup`, verifies integrity/fingerprint/sequence, and requires restic exit zero with a snapshot ID. The remote barrier orchestration and fresh-host restoration are unfinished. Local test profiles can explicitly disable the remote requirement; canonical validation rejects that bypass.

No code path may treat a passed pure test, a current matching balance, or a successful upload exit alone as full host-loss recovery evidence.
