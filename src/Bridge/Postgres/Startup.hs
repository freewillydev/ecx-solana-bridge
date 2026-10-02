module Bridge.Postgres.Startup (resumeAfterChecks,resumeAfterReview) where
import Bridge.Config
import Bridge.Types
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import qualified Bridge.Postgres.Custody as Custody
import qualified Bridge.Postgres.Budget as Budget
import qualified Bridge.Postgres.Order as Order
import Control.Monad (forM_)
import Bridge.Settlement (PaymentTransport,reconcilePaymentsWith,readSavedPayment,recheckSourceWith)
import Bridge.Postgres.PaymentStore (Store(..),pendingAttempts)
import qualified Bridge.Postgres.PaymentStore as Payments
import qualified Bridge.Ledger.Model as Domain
import Bridge.RPC (fieldValue)
import Data.Aeson (Value)
import Data.Text (Text)
import Data.List (sort)
import Data.Int (Int64)
import qualified Opaleye as O

-- Startup is explicit, profile-gated by Runtime and revision-fenced. A crash
-- with unresolved work cannot silently grant a new signing/send authority.
resumeAfterChecks :: Config -> Ledger -> Int64 -> IO ()
resumeAfterChecks cfg ledger now = resumeChecked cfg ledger now Nothing

-- Explicit operator authority to continue existing exact saved work. Startup
-- never invokes this path. RPC evidence is checked outside ledger transactions;
-- the final transaction fences every still-pending attempt before resuming.
resumeAfterReview :: IO Int64 -> PaymentTransport -> Config -> Ledger -> IO ()
resumeAfterReview clock transport cfg ledger = do
  state <- readiness ledger
  require (not $ available state) "pause_before_operator_action"
  result <- reconcilePaymentsWith transport cfg (Store ledger)
  outcomes <- fieldValue "attempts" result :: IO [Value]
  failures <- mapM (fieldValue "error") outcomes :: IO [Maybe Text]
  require (all (==Nothing) failures) "resume_payment_requires_review"
  saved <- pendingAttempts (Store ledger)
  require (length saved<=1000) "resume_payment_backlog"
  forM_ saved $ \attempt->do
    require (Domain.attemptState attempt `elem` ["signed","broadcast_intent"]) "resume_payment_requires_review"
    (obligation,_) <- readSavedPayment transport cfg (Store ledger) attempt
    recheckSourceWith transport cfg (Store ledger) obligation
  _ <- Payments.reconcileCustodyWith clock transport cfg ledger
  now <- clock
  resumeChecked cfg ledger now (Just saved)

resumeChecked :: Config -> Ledger -> Int64 -> Maybe [Domain.Attempt] -> IO ()
resumeChecked cfg ledger now reviewed = do
  snapshot <- Custody.readSnapshot cfg ledger now False
  ledgerAction ledger $ \c->do
    checks <- O.runSelect c (O.selectTable custodycheckTable) :: IO [CustodyCheck]
    require (case checks of
      [row]->custodycheckRevision row==Custody.revision snapshot && custodycheckCheckedRevision row==Just(custodycheckRevision row) && custodycheckLastError row==Nothing && maybe False (\at->at>=0 && at<=now && now-at<=60) (custodycheckCheckedAt row)
      _->False) "custody_not_reconciled"
    intents <- O.runSelect c (O.selectTable intentsTable) :: IO [Intents]
    case reviewed of
      Nothing->require (all ((==1).intentsResolved) intents) "unresolved_intents_require_review"
      Just expected->do
        attempts <- O.runSelect c (O.selectTable attemptsTable) :: IO [Attempts]
        expiries <- O.runSelect c (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
        let unresolved=[intentsId i | i<-intents,intentsResolved i==0]
            pending=[a | a<-attempts,attemptsIntentId a `elem` unresolved,
              attemptsTxid a `notElem` map solanaexpiriesTxid expiries]
            actual=sort [(attemptsTxid a,attemptsIntentId a,attemptsState a,attemptsCriticalSequence a) | a<-pending]
            checked=sort [(Domain.attemptId a,Domain.attemptIntent a,Domain.attemptState a,Domain.attemptSequence a) | a<-expected]
        require (actual==checked && all (\intent->any ((==intent).attemptsIntentId) pending) unresolved) "resume_payment_changed"
    events <- O.runSelect c $ do
      row <- O.selectTable chaineventsTable
      O.where_ (chaineventsNeedsReview row O..== O.sqlInt8 1)
      pure (chaineventsEventId row)
      :: IO [Text]
    require (null events) "chain_observations_require_review"
    nativeReviews <- O.runSelect c Order.recoveryPayments :: IO [(Text,Text)]
    require (all ((=="reconfirmed").snd) nativeReviews) "native_settlement_requires_review"
    covered <- O.runSelect c Order.accountedLosses :: IO [Text]
    deposits <- O.runSelect c (O.selectTable depositsTable) :: IO [Deposits]
    require (all (\row->depositsAllocated row/=1 || depositsEligible row==1 || depositsId row `elem` covered) deposits) "source_reorg_requires_review"
    sourceReviews <- O.runSelect c Order.recoverySources :: IO [(Text,Text)]
    require (all (\(did,state)->state=="restored" || did `elem` covered) sourceReviews) "source_recovery_requires_review"
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
    Order.checkIntakeReadyC c now
    _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "resume") (O.sqlStrictText "checks_complete")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()
