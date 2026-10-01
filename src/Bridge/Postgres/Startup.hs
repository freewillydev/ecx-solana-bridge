module Bridge.Postgres.Startup (resumeAfterChecks) where
import Bridge.Config
import Bridge.Types
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import qualified Bridge.Postgres.Custody as Custody
import qualified Bridge.Postgres.Budget as Budget
import Control.Monad (forM_)
import Data.Int (Int64)
import qualified Opaleye as O

-- Startup is explicit, profile-gated by Runtime and revision-fenced. A crash
-- with unresolved work cannot silently grant a new signing/send authority.
resumeAfterChecks :: Config -> Ledger -> Int64 -> IO ()
resumeAfterChecks cfg ledger now = do
  snapshot <- Custody.readSnapshot cfg ledger now False
  ledgerAction ledger $ \c->do
    checks <- O.runSelect c (O.selectTable custodycheckTable) :: IO [CustodyCheck]
    require (case checks of
      [row]->custodycheckRevision row==Custody.revision snapshot && custodycheckCheckedRevision row==Just(custodycheckRevision row) && custodycheckLastError row==Nothing && maybe False (\at->at>=0 && at<=now && now-at<=60) (custodycheckCheckedAt row)
      _->False) "custody_not_reconciled"
    intents <- O.runSelect c (O.selectTable intentsTable) :: IO [Intents]
    require (all ((==1).intentsResolved) intents) "unresolved_intents_require_review"
    obligations <- O.runSelect c (O.selectTable obligationsTable) :: IO [Obligations]
    require (all ((/="review").obligationsStatus) obligations) "obligations_require_review"
    deficits <- O.runSelect c $ do
      row <- O.selectTable postingsTable
      O.where_(postingsAccount row O..== O.sqlStrictText "source_deficit")
      pure(postingsDelta row)
      :: IO [Int64]
    require (sum(map toInteger deficits)==0) "source_shortfall_requires_review"
    orders <- O.runSelect c (O.selectTable ordersTable) :: IO [Orders]
    limits <- O.runSelect c (O.selectTable ordercostlimitsTable) :: IO [OrderCostLimits]
    require (all (\row->any ((==ordersId row).ordercostlimitsOrderId) limits ||
      ordersStatus row `elem` ["Paid","Refunded","ExpiredUnfunded"] && all (\ob->obligationsOrderId ob/=ordersId row || obligationsStatus ob `elem` ["paid","cancelled"]) obligations) orders) "legacy_order_cost_review_required"
    forM_ ["Native","Sol"] $ \asset->Budget.freeOperating c asset >>= \free->require (free>=0) "operating_allocation_requires_funding"
    _ <- O.runUpdate c O.Update {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 0,deploymentPauseReason=O.sqlStrictText "ready"},O.uWhere= \row->deploymentSingleton row O..== O.sqlInt8 1,O.uReturning=O.rCount}
    _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "resume") (O.sqlStrictText "checks_complete")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()
