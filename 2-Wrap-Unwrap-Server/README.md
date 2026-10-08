# ECX wrap/unwrap server

One Haskell Servant server and one dedicated signer convert existing native ECX
and Solana SPL inventory. Customers receive deposit instructions; the website
requires no wallet connection. New quotes charge **1% in each direction**, with
network costs paid separately by the operator. Saved terms remain immutable.

This is the only server implementation in the repository. Earlier versions completed real
L2L Signet/Solana Devnet conversions, refunds, earned-fee withdrawals and scoped
recovery checks. It is not yet a public or valuable-fund release. See the precise
[evidence and remaining gates](docs/RELEASE-REVIEW.md).

The current financial-core refactor uses schema 22: payment roots own execution,
while immutable funding and retained chain/recovery evidence remain separate.
This version passed local migration/restoration/process checks and real Signet/
Devnet conversions, an additional-payment refund, payout restart and Solana expiry/
retry. These used dedicated tester clients; wallet approval, external recovery and
independent review remain. Historical canonical tests do not approve this refactor
for valuable funds.

## Build and run

clone this repo into a folder ecash so the command cd ~/ecash works

Requires **GHC 9.14.1 and Cabal 3.16.1.0**. Select the pinned tools using the
[compiler setup instructions](docs/LOCAL-DEVELOPMENT.md) before building.

From the repository root:

```sh
cd ~
mkdir ecash-bridge
cd ecash-bridge
git clone https://github.com/freewillydev/ecx-solana-bridge.git

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

git clone https://github.com/emscripten-core/emsdk.git \
  "$HOME/.local/share/ecx-emsdk"

cd "$HOME/.local/share/ecx-emsdk"
./emsdk install 3.1.74
./emsdk activate 3.1.74
source ./emsdk_env.sh
ghcup config add-release-channel cross
emconfigure ghcup install ghc --set javascript-unknown-ghcjs-9.12.2

cd ~/ecash/ecx-solana-bridge/

ghcup install cabal
cabal update
ghcup run --install --ghc 9.14.1 --cabal 3.16.1.0
ghcup run --ghc 9.14.1 -- cabal build exe:ecx-bridge -j1
export PATH="$(dirname "$(ghcup run --install --ghc 9.14.1 --cabal 3.16.1.0 -- cabal list-bin exe:ecx-bridge)"):$PATH"
cd 2-Wrap-Unwrap-Server

ecx-bridge check-config /absolute/private/config.json
ecx-bridge observe /absolute/private/config.json
```

Startup requires a reviewed deployment configuration, migrated PostgreSQL ledger,
distinct writer/reader roles, and an adopted host fence. `observe` cannot create
orders or send payouts. All three profiles, including `CanonicalBeta` on Solana
Mainnet, support `serve` and `signer`. `serve` permits paying workflows but starts paused; a
separate signer and guarded operator resume are required. Follow [installation
prerequisites](docs/INSTALL.md) and [operations](docs/OPERATIONS.md), not a test fixture.
The candidate automated installer has passed clean installation, upgrade and
cold-boot checks on Ubuntu 24.04 ARM64 and x86-64. It is not yet a public release;
use the authenticated installation procedure and retain the recovery prerequisites.

Public HTTPS runs directly in this executable through WarpTLS. No external web
server or reverse proxy is needed. Configure the certificate/key as described in
[installation](docs/INSTALL.md#public-https-in-the-haskell-server); without them,
the customer listener remains loopback HTTP. The signer remains a separate process
using the same executable. PostgreSQL, chain RPC and backup infrastructure remain
necessary.

## Audit path

| Responsibility | Source |
| --- | --- |
| Amounts, quotes, funding and wire records | `src/Bridge/{Domain,Wire}.hs` |
| Pure financial decisions and customer projection | `src/Bridge/Lifecycle.hs` |
| Caller/severity GADTs and existential requests | `src/Bridge/Operation/Internal.hs` |
| Four pure Servant handlers | `api/Bridge/API.hs` |
| Operation instances, shared critical evaluator and signing | `workflow/Bridge/Critical.hs` |
| Admission, orders and payment validation | `workflow/Bridge/{Admission,Order,Payment}.hs` |
| Observation and custody reconciliation | `workflow/Bridge/{Observer,Reconciliation}.hs` |
| Closed Opaleye operations and transactions | `runtime/Bridge/Store.hs`, `Store/{Schema,Catalog,Projection}.hs` |
| Offline schema conversion with preserved history | `runtime/Bridge/Store/Migration.hs`, `migrations/009-*.sql` |
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
provides the request-to-effect diagram, authoritative facts, transition map,
invariant/test index and bounded TLA+ model limits.

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
