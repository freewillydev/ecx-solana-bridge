# ECX wrap/unwrap server

One Haskell Servant server and one dedicated signer convert existing native ECX
and Solana SPL inventory. Customers receive deposit instructions; the website
requires no wallet connection. New quotes charge **1% in each direction**, with
network costs paid separately by the operator. Saved terms remain immutable.

This is the only server implementation in the repository. It has completed real
L2L Signet/Solana Devnet conversions, refunds, earned-fee withdrawals and scoped
recovery checks. It is not yet a public or valuable-fund release. See the precise
[evidence and remaining gates](docs/RELEASE-REVIEW.md).

## Build and run

From the repository root:

```sh
cabal build all -j1
cabal test all -j1 --test-show-details=direct
cabal run exe:ecx-bridge -- check-config /absolute/private/config.json
cabal run exe:ecx-bridge -- observe /absolute/private/config.json
```

Startup requires a reviewed deployment configuration, migrated PostgreSQL ledger,
distinct writer/reader roles, and an adopted host fence. `observe` cannot create
orders or send payouts. `serve` permits paying workflows but starts paused; a
separate signer and guarded operator resume are required. Follow [installation
prerequisites](docs/INSTALL.md) and [operations](docs/OPERATIONS.md), not a test fixture.
There is currently **no automated installer**. The incompatible old installer,
server and deployment harnesses have been removed.

## Audit path

| Responsibility | Source |
| --- | --- |
| Amounts, quotes, funding and wire records | `src/Bridge/{Domain,Wire}.hs` |
| Caller/severity GADTs and existential requests | `src/Bridge/Operation/Internal.hs` |
| Four pure Servant handlers | `api/Bridge/API.hs` |
| Operation instances, shared critical evaluator and signing | `workflow/Bridge/Critical.hs` |
| Admission, orders and payment validation | `workflow/Bridge/{Admission,Order,Payment}.hs` |
| Observation and custody reconciliation | `workflow/Bridge/{Observer,Reconciliation}.hs` |
| Closed Opaleye operations and transactions | `runtime/Bridge/Store.hs`, `Store/{Schema,Catalog}.hs` |
| Native/Solana adapters and protocol codecs | `chain/Bridge/` |
| Signer HTTPS transport and protected credentials | `workflow/Bridge/{Signer,Credentials}.hs` |
| Local operator control and custody recovery | `workflow/Bridge/{Control,Recovery}.hs` |
| Host fence and encrypted archives | `runtime/Bridge/{Fence,Store/Backup}.hs` |
| Startup, configuration and browser serving | `app/Main.hs`, `workflow/Bridge/{Config,Web}.hs` |
| Haskell browser and Cabal asset hooks | `web/`, `build/` |
| QuickCheck and PostgreSQL contracts | `test/Main.hs`, `test/StoreCheck.hs` |

Servant handlers package typed requests; `Operation.command` resolves them into
closed DSL instructions. Separate evaluators enforce safe/critical authority.
All application database access uses Opaleye inside specific closed operations.
Only critical evaluation owns the signer client. The signer independently checks
saved decisions and never broadcasts. [Architecture](docs/ARCHITECTURE.md)
describes these boundaries, accounting invariants and the bounded TLA+ model.

## Customer API

| Route | Result |
| --- | --- |
| `GET /api/v1/config` | Identity, limits, fees, links and availability |
| `POST /api/v1/orders` | Create/recover an immutable order |
| `GET /api/v1/orders/:id` | Authorized order status |
| `POST /api/v1/orders/:id/transaction` | Authorized Solana Pay instructions |

Amounts are integer base-unit strings. A saved private capability authorizes order
access; an order ID alone does not. Wrapping binds a Solana destination and native
refund address. Unwrapping uses a Solana Pay reference and derives refund ownership
from verified deposit effects. Only actual chain observations credit deposits.

[Token administration](../1-Make-Wrapped-ECX/README.md) and
[liquidity operations](../3-Create-CPMM-Pool/README.md) use separate keys outside
customer custody. Trading links do not provide the native wrap/unwrap service.

[Operations](docs/OPERATIONS.md) · [Development](docs/LOCAL-DEVELOPMENT.md) ·
[Implementation plan](docs/IMPLEMENTATION-PLAN.md) · [Release review](docs/RELEASE-REVIEW.md)
