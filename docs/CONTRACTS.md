# Financial and API contracts

These are the contracts implemented in the current ledger plus the requirements that must be completed before intake. The disabled worker does not currently expose order creation or payout execution.

## Amounts and quotes

Both assets use eight decimal places. API amounts are base-unit decimal **strings**; `"3"` is three units and `"100000000"` is one coin. JSON numbers, exponent notation, signs, extra precision and overflow are rejected. Intermediate calculations use Haskell `Integer`; persisted amounts fit nonnegative signed 64-bit integers. Operational limits are lower and explicit in configuration.

Wrap fee: 20 basis points. Redemption fee: 100 basis points. For gross input `g`, `fee = ceiling(g * basisPoints / 10000)` and `net = g - fee`. A nonpositive net is rejected. Native fees, SOL fees, and permitted ATA rent are operator costs; they never reduce the quoted net. Solana preparation reserves the sum of separate fee and rent ceilings. Settlement records network fees and account rent as separate balanced expenses and caps their total against the saved reservation. New quotes also reserve their payout and refund cost allowances; rolling operating caps are enforced as described below. Native quote amounts now pass the daemon-based admission check below; complete customer intake remains disabled.

An order permanently records direction, gross/fee/net, recipient, refund destination, source wallet when applicable, deposit deadline, confirmation grace deadline, native confirmation depth, Solana finality policy, and deployment fingerprint. A later configuration change cannot alter the stored policy. Only one exact source deposit can receive the quoted conversion; partial, duplicate-sized extra, late, or otherwise unclassified deposits need review.

For redemption, the refund destination is the bound source Solana owner. A copied memo from another source wallet cannot authorize the order. Native orders bind a fresh daemon-generated address before it is exposed. `Bridge.Order` integrates chain admission and recoverable provisioning; the customer creation endpoint remains disabled until the remaining acceptance gates pass.

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

Never initialize float from the wallet balance alone. `allocateTreasuryReceipt` moves an existing eligible, unbound receipt from `unallocated` into explicit allocations while paused. The split must exactly equal the receipt, and SOL may only fund `operating`. Saved ownership evidence and allocation are immutable; exact repeats do not post again. There is no runtime arbitrary-credit primitive. A general verified operator workflow remains unfinished and unavailable over HTTP.

`recordTreasurySpend` classifies an already observed operator outflow with immutable verification evidence. It protects customer attempts and active float/fee reservations, posts the principal and operating costs once, and clears only that event's review. A later changed anchor or economic effect requires review again. `scripts/reconcile-test-treasury.hs` uses these primitives for the exact known test setup and standalone probes, then compares all custody allocations with actual chain balances. It does not authorize new payments, canonical funding, or automatic reorg repair.

Examples below use coins for readability; code uses integer base units:

| Event | Journal effects |
| --- | --- |
| Receive native 100 | Native principal +100, external −100 |
| Wrap pays wrapped 99.8 | Native principal −100, float +99.8, earned +0.2; wrapped float −99.8, external +99.8 |
| Receive wrapped 100 | Wrapped principal +100, external −100 |
| Redeem pays native 99 | Wrapped principal −100, float +99, earned +1; native float −99, external +99 |
| Full refund of a native partial deposit 0.01 | Native principal −0.01, external +0.01; no second reservation against float |
| Successful or finalized failed Solana network fee | SOL operating −actual fee, external +actual fee |
| Successful recipient-account creation | SOL operating −actual rent, external +actual rent; distinct from the network fee |
| Unknown native receipt 0.01 | Native unallocated +0.01, external −0.01; no automatic quote, refund, or rebinding |
| Signed/potentially sent payout | No settlement posting yet; existing destination and fee holds persist |

Reorg compensation, settled destination rollback, native replacement-family accounting are **not implemented**. Current loss of source eligibility stops first-send authorization and pauses allocated deposits for review. That is a guard, not full reorg recovery.

## Native destination admission

`checkNativeQuote` verifies the real native chain identity, then checks the actual recipient script for a redemption or the bound refund script for a wrap. Wallet ownership and watch-only destinations are refused. The daemon must classify the script as P2PKH, P2SH, P2WPKH, P2WSH or Taproot; unknown witness versions, anchor outputs and other script types are unsupported. Native payment preparation uses the same destination check.

The application does not guess the node's dust setting from its relay fee. It asks the selected wallet to build an unsigned PSBT for the exact native net payout or full native refund amount. Change uses an existing confirmed, safe, owned wallet address, with `lockUnspents=false`. There is no new address, signer, input lock or send in this path. The ordinary independent recipient/change/input/fee validator checks the result, which is discarded rather than persisted as a payment. Real payment preparation still reserves funds and uses input locks. Both reviewed daemons apply their active dust policy during wallet construction. [Core wallet implementation](https://github.com/bitcoin/bitcoin/blob/v30.2/src/wallet/spend.cpp), [ECX wallet implementation](https://github.com/ecash-com/bitcoin/blob/ca64033c137457a3c8ca394186759819a2ab0694/src/wallet/spend.cpp), [PSBT options](https://bitcoincore.org/en/doc/30.0.0/rpc/wallet/walletcreatefundedpsbt/).

This is a conservative admission check: it requires available confirmed wallet inputs even when checking a possible future refund. Missing funds, old payment locks, excessive estimated fees or a node refusal prevent the new quote. It is not a guarantee of later fee levels or final mempool acceptance. The payment path checks those conditions again and cannot reduce the quoted net. Unexpected tiny receipts remain ledger liabilities; failing to construct a refund does not forfeit them.

The scoped real-order tool runs this check before creating a new ledger order and starts the deadline afterward. Public customer creation remains disabled until admission, provisioning, reconciliation and recovery are integrated. The real-node probe verifies P2WPKH dust refusal and wrong-network/owned-address refusal without creating orders or payments; it does not prove other address types or actual ECX operation. [Evidence](evidence/native-admission.json).

## Solana wallet admission

`checkSolanaQuote` verifies the real Solana deployment, then asks the pinned SDK helper for an unsigned payout preview. The helper verifies on-curve wallet owners and derives the legacy ATA from the wallet, mint and Token Program. The preview uses the same checked transfer, idempotent ATA creation and signer-bound memo instructions as a payment, but never reads the custody key. Haskell checks the entire message and requires a zero signature and no reported transaction signature. Custody identities and the configured mint are refused as customer destinations. [Solana ATA derivation and account policy](https://solana.com/docs/tokens/basics/create-token-account).

A contextual account snapshot checks that an existing wallet account is an ordinary empty, non-executable System Program account. Token accounts, nonce accounts and program-owned accounts cannot stand in for the wallet owner. A wrap recipient may have no wallet account or ATA yet; the bridge pays ATA creation. An existing ATA must meet the same mint/owner/program/decimals/no-delegate/no-close-authority policy used at payment preparation. Missing ATAs and empty, prefunded system accounts use the live 165-byte rent quote, subtracting existing lamports without going below zero. A redemption requires the bound owner's supported ATA, the gross token amount and enough SOL for the unsigned incoming transfer.

Admission checks the exact net wrap payout or full wrapped refund message against the operator's current fee and rent ceilings. Wraps also check custody token inventory; both directions check operating SOL. The incoming redemption message's fee is checked against the customer's SOL. Fee estimates use real messages and the recent blockhash, with minimum RPC context slots. The actual outgoing wrap or incoming redemption message is simulated with zero signatures; a failed simulation or expiring blockhash rejects admission. A redemption's later refund does not require those incoming tokens to be in custody already. [Fee estimation](https://solana.com/docs/rpc/http/getfeeformessage), [contextual account reads](https://solana.com/docs/rpc/http/getmultipleaccounts).

No preview is an issued deposit instruction, payment intent or future execution guarantee. The ledger separately reserves the full configured outgoing/refund allowances, including rent even for an existing ATA. Payment and unsigned-deposit preparation still recheck live accounts, time and saved economic policy. The order coordinator runs both chain checks before a new order and starts its deadline afterward; idempotent existing orders retain their original policy. Public intake remains disabled.

## Recoverable order provisioning

Schema 8 separates recording an instruction from issuing it. Authenticated customer reads hide an instruction until the coordinator explicitly issues it. The first issuance requires an unexpired deposit window, unpaused intake, the original inventory/cost holds, three successful history scans no more than 60 seconds old, and acknowledged coverage of the instruction's critical sequence when remote backup is required. Pause, deadline and scan freshness are checked again after external RPC/backup work. Already-issued instructions remain available as historical order data while paused or expired; returning them does not renew a quote or its capacity. New settings do not alter an existing order.

For native deposits, the ledger commits a unique allocation claim with an order/deployment-specific wallet label before the first possible `getnewaddress` call. Only the caller that inserts that claim receives permission to allocate. Every later caller may only recover the saved label. The selected descriptor wallet must have private keys enabled, no external signer, no scan in progress and, when encrypted, be unlocked. A recovered address must be wallet-owned, solvable, non-change P2WPKH with that exact receive label. Missing, malformed or ambiguous recovery evidence cannot authorize another allocation. A claim that still has no address needs operator review; its unissued quote can expire and release capacity. [Label lookup](https://bitcoincore.org/en/doc/30.0.0/rpc/wallet/getaddressesbylabel/), [wallet readiness](https://bitcoincore.org/en/doc/30.0.0/rpc/wallet/getwalletinfo/), [address ownership and labels](https://bitcoincore.org/en/doc/30.0.0/rpc/wallet/getaddressinfo/).

The address and its critical sequence commit before backup or exposure. A pause/expiry during allocation does not discard a recovered address: it is retained against its original order, remains hidden if unissued, and cannot reopen released reservations. SQLite enforces immutable allocation claims and bound instructions. Redemption memos are deterministic from the deployment and order ID and need no wallet allocation. Network and backup work never holds the ledger transaction open.

The issuance marker is monotonic but not a new monetary commitment: the immutable quote/address binding must already be backed up before it is set. Restoring a snapshot from just before issuance may hide that instruction again, but still preserves its address, source binding and reservations. Full restore/reconciliation remains a separate release gate. Migration treats previously bound instructions as potentially already exposed and preserves their availability; it never allocates a replacement address.

The worker and order coordinator release provisional reservations after their original grace deadline. Funded obligations retain their holds. The scoped public-test tools use this coordinator; the customer HTTP creation route and automatic payment scheduling remain disabled.

## Operating limits

Schema 7 snapshots each new order's native fee, Solana fee and Solana ATA-rent ceilings separately. It reserves both the conversion cost and the alternate refund cost at quote time, against separately allocated native/SOL operating funds. This conservative policy includes the full rent ceiling even if the recipient already has an ATA. It avoids accepting orders whose inventory is available but whose fees or refunds cannot be funded.

Admission checks each asset independently: actual operating allocation minus all active holds must cover the new allowance, and booked operating expenses over the last 86,400 seconds plus active holds plus the new allowance must fit `maxNativeDailyCost` / `maxSolDailyCost`. All totals use streaming `Integer` arithmetic. A rejected admission commits no order or reservation. The global order limit also counts pending extra refunds attached to otherwise completed orders. Unrequested incoming funds still remain liabilities even when admission is closed.

Promotion retains both allowances. Preparation atomically transfers its relevant allowance into the intent's fee reservation, so it is counted once. Provisional quote expiry releases provisional costs; funded obligations retain theirs. A safe refund cancels the unused conversion allowance and uses its separate refund allowance. Success releases unused allowances and books actual network fees and rent separately. Failed Solana transactions book their actual fee while leaving full principal and the alternate refund allowance intact. Approved replacements and extra/late refunds must reacquire available operating capacity; an old transferred or released allowance cannot be spent twice. Changing fee ceilings affects new quotes; aggregate daily limits are checked from current configuration at new quote/preparation admission. Previously committed attempts remain subject to their saved costs and recovery rules.

Every negative operating posting receives an immutable booking timestamp in the same transaction. A durable accounting clock never moves backward, so a restart or backward wall-clock adjustment does not reset the budget. This relies on a correctly administered host clock; it is not a defense against a compromised operating system. Costs without trustworthy old timestamps are conservatively included for a full day from migration. These timestamps record accounting recognition, not invented chain times. The private `/audit` response reports balances, held allowances, recent expenses and daily limits from one ledger transaction.

The migration preserves prior economics and does not invent fee policies for legacy orders. Existing recorded attempts can still be reconciled. Any unfinished pre-schema-7 order without a cost policy prevents resumption and needs explicit operator recovery; there is no automatic retroactive approval. The three existing public-test orders were already terminal at upgrade. General exception recovery, complete chain admission and public intake integration remain separate unfinished gates.

## Durable states

`Provisioning → AwaitingDeposit → Ready → Preparing → Paying → Paid` is the normal order path. `ExpiredUnfunded`, `NeedsReview`, `Refunding`, and `Refunded` handle exceptions. A quote reservation moves through quote/obligation/payment and is released on settlement or a safe cancellation. Expiry never releases a preparing or signed payment's reservation.

Signed bytes are immutable. The ledger permits one unresolved outgoing intent per chain. It records `broadcast_intent` and a critical sequence before first send. Ambiguous native sends never expire automatically; a new transaction or refund cannot bypass the unresolved intent. Finalized Solana failure charges its real fee while preserving full customer principal. Conclusive Solana expiry is implemented below; native replacements still require further recovery work.

Schema 3 reserves the chain and maximum operating cost before wallet funding. The native adapter binds a specific owned change script, verifies confirmed wallet inputs and totals their exact values, checks recipient/net/fee and replay fields, then saves the unsigned draft before requesting a signature. It checks the final transaction against that same template and the node's mempool policy before saving signed bytes. A lost funding reply leaves the preparation unresolved and pauses further work. Unexplained UTXO locks are never silently cleared. The controlled unsigned development probe can unlock only its own exact selected inputs because its code has no signing or broadcast step.

Solana preparation saves the blockhash, validity height, obligation-specific memo reference and exact helper request before signing. It reserves `maxSolFee + maxSolAccountRent`, validates the SDK bytes and Ed25519 signature locally, and quotes fees/rent from the configured RPC. Existing ATAs cost no rent; a pre-funded empty system account receives only the remaining required rent. Delegates, close authorities, wrong owners/mints, unsupported layouts and insufficient balances are rejected. Simulation receives the same SDK message with its signature zeroed (`sigVerify=false`, no blockhash replacement), so it cannot relay a usable payment before persistence and backup. Recorded attempts are returned unchanged on retry. The finalized-outcome validator matches the entire original message, historical token deltas, payer debit, network fee and recipient-account rent. [Solana simulation contract](https://solana.com/docs/rpc/http/simulatetransaction), [message fee quote](https://solana.com/docs/rpc/http/getfeeformessage).

`authorizeRecordedSend` requires saved `BroadcastIntent`, applicable backup coverage, eligible source, paying obligation and unpaused deployment. It rechecks these after a backup wait; an idempotently returned broadcast sequence alone is insufficient. `Bridge.Settlement` reads the exact bound source transaction both before intent and after backup, checks the source's saved confirmation policy, and checks the Solana blockhash window again before send. An absent RPC result permits only another submission of the saved bytes under those same guards; it cannot authorize replacement or release reservations. A lost send response retains the durable intent. A backup callback returning successfully without a recorded coverage acknowledgment still cannot authorize a send.

The bounded payment pass reconciles saved attempts even while paused. Native settlement requires exact bytes, outputs and fee plus the active confirmed block. Solana settlement requires a successful or failed finalized transaction with verified historical economic effects; recent signature status alone never settles it. Successful settlement posts principal, bridge fees, network fees and rent in one database transaction. Finalized failure spends only its verified network fee. Exact repeated results are idempotent; contradictory fee/rent or proof is rejected. A signed-only attempt found on-chain requires review. Missing history or insufficient blockhash lifetime retains bytes and holds; expiry requires the separate evidence below. Destination-reorg recovery remains unfinished. [Native wallet result](https://bitcoincore.org/en/doc/30.0.0/rpc/wallet/gettransaction/), [Solana finalized transaction](https://solana.com/docs/rpc/http/gettransaction), [signature status history](https://solana.com/docs/rpc/http/getsignaturestatuses).

Schema 5 preserves numbered preparation generations and immutable Solana expiry decisions. Before retiring an attempt, each configured provider must show finalized height beyond its saved validity height, an invalid blockhash, no historical signature status or finalized transaction, and complete custody-token and fee-payer histories through their original anchors. The configured anchors must match the ledger's immutable scan origins. Canonical mode requires an independent provider. A missing response, truncated history, wrong genesis, stale provider or observed signature rejects expiry. The original signed bytes and broadcast sequence survive; only the proven unused fee reservation is released. Principal and destination reservations remain. [Blockhash expiration](https://solana.com/developers/cookbook/transactions/confirmation), [blockhash-validity RPC](https://solana.com/docs/rpc/http/isblockhashvalid).

Schema 6 requires a separate journaled operator decision before replacement, as specified in the approved plan. Expiry leaves the obligation in `review` and the order in `NeedsReview`. The private `approve-solana-retry` command requires a paused deployment and the latest expired attempt, revalidates the saved message, source eligibility, immutable history origins and conclusive absence, then records a reason, fresh evidence and critical sequence. It does not sign, broadcast or resume service. A repeated identical approval has no additional effect; a changed reason is rejected. A refunded, cancelled or already paid obligation cannot be revived. Preparation independently requires this approval even if another caller marks an obligation ready. The next preparation retains its amount, recipient and memo, reserves operating costs again, and needs a new broadcast intent and applicable backup acknowledgment. At most eight generations are permitted before further operator review.

RPC rate limiting retries only an explicit read-method allowlist, at most twice. Numeric `Retry-After` waits are capped at 15 seconds; unsupported or longer values stop the call. Wallet mutations, sends, unknown methods and transport failures are not retried by this layer. Payment retries remain under the ledger's exact-byte and first-send guards. [Public RPC limits](https://solana.com/docs/references/clusters).

`Bridge.Deposit` prepares an unsigned Solana source transaction for the authenticated immutable order. It enforces instruction-backup coverage, the bound owner and refund address, exact amount/mint/memo, source tokens, customer SOL for the quoted fee, account policy and blockhash lifetime. It rechecks deadline, order state and deployment availability after the external reads. Custody never signs this deposit. The ordinary HTTP transaction route remains disabled pending integration acceptance.

The worker's payment pass remains behind `implementationReady = False`. No new HTTP payout or resume route is enabled. Native fee estimation uses the configured daemon's conservative policy (and its explicitly configured fallback, if any), capped by the saved maximum total fee. A funding/fee-policy failure stops preparation; it never reduces the customer's net. RPC choices were checked against [Core 30's PSBT interface](https://bitcoincore.org/en/doc/30.0.0/rpc/wallet/walletcreatefundedpsbt/) and the [reviewed ECX implementation](https://github.com/ecash-com/bitcoin/blob/ca64033c137457a3c8ca394186759819a2ab0694/src/wallet/rpc/spend.cpp); real ECX execution remains a separate acceptance gate.

A scanner batch uses a compare-and-swap on its previous cursor and commits all observations with the next cursor. A conflicting receipt rolls back the entire page. Repeated observations do not duplicate journal value. Unknown bindings remain quarantined; discovering chain history after restoring an old database cannot prove that an unrecognized deposit was never paid.

Schema 2 adds immutable scan origins and observation evidence, latest event classifications, and scanner health. The native observer rechecks wallet ownership, output scripts, amounts and the order's saved confirmation depth. The Solana observer requires its exact history anchor, resolves historical token balances, and revisits deposits awaiting an independent provider. Unsupported or ambiguous balance effects and unknown outgoing transactions require review. Cursor advancement does not clear that review. Provider errors preserve the previous cursor.

Schema 4 adds the treasury records and a separate `SolanaOperating` history stream for the dedicated fee-payer owner. It is part of the same Solana adapter, with its own immutable origin and cursor. Historical lamport deltas include ordinary SOL receipts, network fees and recipient-account rent. The opening transaction must start with zero owner lamports; a later anchor cannot omit earlier funding. SOL observations never authorize customer conversions. Known customer outflows require a recorded broadcast intent or completed result; a merely signed attempt is not accepted as explained activity. Ongoing custody/in-flight reconciliation and full reorg recovery remain unfinished.

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

The example describes the contract, not an enabled API. Semantic errors currently return structured 409 responses; complete external error categorization is still pending. A separate filesystem-restricted admin socket provides `/health`, `/pause`, `/audit` and `/scanners`. Scanner evidence is private; the public proxy returns 404 for `/scanners`. No SQL console or unrestricted signing endpoint exists.

## Backup boundary

Canonical profiles require off-host coverage of both immutable deposit instructions and signed `BroadcastIntent` before exposure/send. The snapshot primitive uses SQLite `.backup`, verifies integrity/fingerprint/sequence, and requires restic exit zero with a snapshot ID. The remote barrier orchestration and fresh-host restoration are unfinished. Local test profiles can explicitly disable the remote requirement; canonical validation rejects that bypass.

No code path may treat a passed pure test, a current matching balance, or a successful upload exit alone as full host-loss recovery evidence.
