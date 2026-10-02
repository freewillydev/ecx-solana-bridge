{-# LANGUAGE GADTs #-}
module Main (main) where

import Bridge.Types hiding (deploymentFingerprint)
import Bridge.Ledger.Model (Deposit(..),Obligation(..),CostLimits(..))
import qualified Bridge.Postgres.Preparation as Preparation
import qualified Bridge.Postgres.Settlement as Settlement
import Bridge.Config
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Postgres.Runtime as Runtime
import Bridge.RPC (fieldValue)
import qualified Bridge.Order as Workflow
import qualified Bridge.SolanaPay as Pay
import qualified Bridge.Postgres.Observation as Observation
import qualified Data.ByteString as BS
import Data.Aeson (eitherDecodeStrict', Value(..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.IORef
import Bridge.Order (OrderTransport(..))
import Control.Monad (void, forM_, when)
import qualified Bridge.Postgres.Ledger as L
import Bridge.Postgres.Schema
import qualified Opaleye as O
import Control.Exception (bracket, try, IOException)
import Control.Concurrent.Async (withAsync,wait,mapConcurrently,cancel)
import Control.Concurrent.MVar (MVar,newEmptyMVar,putMVar,takeMVar)
import Opaleye.Internal.Column (Field_(Column))
import qualified Opaleye.Internal.HaskellDB.PrimQuery as Expr
import System.Timeout (timeout)
import qualified Opaleye.Internal.Locking as Locking
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import qualified Database.PostgreSQL.Simple as PG
import System.Posix.User (getEffectiveUserName)
import qualified Data.Text as T
import System.Environment (lookupEnv)

-- Dedicated fresh schema contract, never the funded bridge's database.
main :: IO ()
main = do
  user <- getEffectiveUserName
  database <- lookupEnv "ECX_JOURNAL_CONTRACT_DATABASE" >>= maybe (reject "contract_database_required") pure
  require ("ecx_journal_contract_" `T.isPrefixOf` T.pack database) "disposable_contract_database_required"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,
        PG.connectDatabase=database,PG.connectUser=user}
  bracket (PG.connect settings) PG.close $ \connection->
    PG.withTransaction connection (fixture connection InitializeFixture)
  -- A second connection must wait for the Opaleye FOR UPDATE owner, then
  -- proceed after commit. This exercises the database lock, not a Haskell mutex.
  bracket (PG.connect settings) PG.close $ \first->
    bracket (PG.connect settings) PG.close $ \second->do
      PG.begin first
      fixture first LockDeployment
      withAsync (fixture second LockDeployment) $ \pending->do
        blocked <- timeout 200000 (wait pending)
        require (blocked==Nothing) "deployment_row_lock_missing"
        PG.commit first
        released <- timeout 2000000 (wait pending)
        require (released==Just ()) "deployment_row_lock_not_released"
  L.withLedger settings "journal-contract" $ \ledger->do
    L.ledgerAction ledger $ \connection->do
      L.posting connection "contract" "isolated accounting contract" [(Native,"float",100),(Native,"external",-100)]
      n <- L.criticalSequence connection
      require (n==1) "critical_sequence_failed"
    invalid <- try (L.ledgerAction ledger $ \connection->L.posting connection "invalid" "unbalanced" [(Native,"float",1)]) :: IO (Either BridgeError ())
    require (case invalid of Left _->True; _->False) "unbalanced_posting_accepted"
    bs <- L.ledgerAction ledger L.balances
    require (M.lookup ("Native","float") bs==Just 100 && M.lookup ("Native","external") bs==Just (-100)) "journal_balance_failed"
    -- Diagnostics remain usable during active worker ownership, without
    -- pausing it, claiming its lock or changing any deployment metadata.
    before <- L.ledgerAction ledger (\connection->fixture connection DeploymentState)
    diagnostic <- Runtime.checkDatabase settings "journal-contract"
    engine <- fieldValue "engine" diagnostic
    version <- fieldValue "serverVersionNumber" diagnostic
    readOnly <- fieldValue "readOnly" diagnostic
    require (engine==("PostgreSQL"::T.Text) && (version::Int64)>=160000 && readOnly)
      "database_diagnostic_wrong"
    expectError "ledger_profile_or_schema_mismatch" (Runtime.checkDatabase settings "wrong-profile")
    after <- L.ledgerAction ledger (\connection->fixture connection DeploymentState)
    require (before==after) "diagnostic_changed_deployment"
    competing <- try (L.withLedger settings "journal-contract" (const $ pure ())) :: IO (Either BridgeError ())
    require (case competing of Left _->True; _->False) "worker_lock_failed"
    let receipt=T.replicate 64 "a"
        refused action=do
          result <- try action :: IO(Either BridgeError ())
          require (case result of Left _->True; _->False) "invalid_backup_accepted"
        coverage=L.ledgerAction ledger (\connection->fixture connection ReadCoverage)
    refused $ L.acknowledgeBackup ledger "wrong-deployment" 1 receipt
    refused $ L.acknowledgeBackup ledger "journal-contract" 2 receipt
    refused $ L.acknowledgeBackup ledger "journal-contract" 1 "not-a-remote-receipt"
    coverage >>= \rows->require (rows==[(1,0,0)]) "rejected_backup_mutated_state"
    -- A concurrent financial commit after the snapshot must remain uncovered.
    L.ledgerAction ledger L.criticalSequence >>= \n->require (n==2) "backup_contract_sequence_failed"
    L.acknowledgeBackup ledger "journal-contract" 1 receipt
    L.acknowledgeBackup ledger "journal-contract" 1 receipt
    coverage >>= \rows->require (rows==[(2,1,1)]) "backup_covered_newer_work_or_replay_mutated_state"
    refused $ L.acknowledgeBackup ledger "journal-contract" 0 receipt
    coverage >>= \rows->require (rows==[(2,1,1)]) "backup_coverage_regressed"
  L.withLedger settings "journal-contract" $ \ledger->do
    bs <- L.ledgerAction ledger L.balances
    require (M.lookup ("Native","float") bs==Just 100) "reopen_balance_failed"
    coverage <- L.ledgerAction ledger (\connection->fixture connection ReadCoverage)
    require (coverage==[(2,1,1)]) "backup_acknowledgment_not_durable"
  orderContracts settings
  provisioningContracts settings
  rollbackContract settings
  putStrLn "PostgreSQL journal and backup acknowledgment: balanced writes, row locking, ownership, exact coverage, identity/receipt/stale refusal, idempotence, durable reopen, order/provisioning contracts, interruption, commit/capacity failure and send-authority rollback/fencing passed"


-- Closed test operations: no arbitrary SQL/query callback in fixture access.
data Fixture a where
  InitializeFixture :: Fixture ()
  LockDeployment :: Fixture ()
  DeploymentState :: Fixture [Deployment]
  ReadCoverage :: Fixture [(Int64,Int64,Int64)]
  FundOrderTests :: Fixture ()
  ReadyAt :: Int64 -> Fixture ()
  InvalidateCustody :: Fixture ()
  OrderHoldCounts :: T.Text -> Fixture (Int,Int)
  ReplaceInstruction :: T.Text -> Fixture ()
  FreeWrapped :: Fixture Integer
  ReceiptCounts :: Fixture (Int,Int)
  FailTransaction :: Fixture ()
  FailCommit :: IORef Bool -> Fixture ()
  FailCapacity :: Fixture ()
  FailCostPolicy :: Fixture ()
  OperatingFunds :: Fixture (Integer,Integer)
  InterruptedWrite :: MVar () -> MVar () -> Fixture ()
  FundedObligation :: Fixture Obligation
  SendState :: Fixture ([Attempts],[FeeReservations],[Reservations],[OperatingReservations])
  JournalState :: Fixture JournalSnapshot

data JournalSnapshot = JournalSnapshot [Events] [Postings] [(Int64,Int64,Int64)]
  [CustodyCheck] [Checkpoints] [OrderCostLimits] [Orders] deriving (Eq,Show)

fixture :: PG.Connection -> Fixture a -> IO a
fixture connection = \case
  DeploymentState -> O.runSelect connection (O.selectTable deploymentTable)
  LockDeployment -> do
    rows <- O.runSelect connection $ Locking.forUpdate $ do
      row <- O.selectTable deploymentTable
      O.where_ (deploymentSingleton row O..== O.sqlInt8 1)
      pure (deploymentSingleton row)
    require (rows==[1::Int64]) "fixture_deployment_missing"
  InitializeFixture -> do
    existing <- O.runSelect connection (O.selectTable deploymentTable) :: IO [Deployment]
    require (null existing) "fresh_contract_database_required"
    _ <- O.runInsert connection O.Insert
      { O.iTable=deploymentTable
      , O.iRows=[Deployment (O.sqlInt8 1) (O.sqlInt8 18) (O.sqlStrictText "journal-contract")
          (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "contract")]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    _ <- O.runInsert connection O.Insert
      { O.iTable=custodycheckTable
      , O.iRows=[CustodyCheck (O.sqlInt8 1) (O.sqlInt8 0) O.null O.null O.null O.null]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    pure ()
  ReadCoverage -> do
    rows <- O.runSelect connection $ do
      row <- O.selectTable deploymentTable
      pure (deploymentCriticalSequence row,deploymentBackupSequence row)
      :: IO [(Int64,Int64)]
    receipts <- O.runSelect connection $ do
      row <- O.selectTable auditTable
      O.where_ (auditAction row O..== O.sqlStrictText "backup")
      pure (auditId row)
      :: IO [Int64]
    pure [(current,covered,fromIntegral(length receipts)) | (current,covered)<-rows]

  FundOrderTests -> do
    L.posting connection "order-capital" "database-only order contract"
      [(Native,"float",999900),(Native,"operating",1000000),(Native,"external",-1999900),
       (Wrapped,"float",1000000),(Wrapped,"external",-1000000),
       (Sol,"operating",1000000),(Sol,"external",-1000000)]
    void $ O.runInsert connection O.Insert
      { O.iTable=operatingclockTable,O.iRows=[OperatingClock (O.sqlInt8 1) (O.sqlInt8 100)]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    void $ O.runInsert connection O.Insert
      { O.iTable=checkpointsTable
      , O.iRows=[Checkpoints (O.sqlStrictText chain) (O.sqlStrictText "database-contract")
                | chain<-["Native","Solana","SolanaOperating"]]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    void $ O.runInsert connection O.Insert
      { O.iTable=scanhealthTable
      , O.iRows=[ScanHealth (O.sqlStrictText chain) (O.toNullable (O.sqlInt8 100)) O.null (O.sqlInt8 100)
                | chain<-["Native","Solana","SolanaOperating"]]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    fixture connection (ReadyAt 100)
  ReadyAt now -> do
    void $ O.runUpdate connection O.Update
      { O.uTable=scanhealthTable
      , O.uUpdateWith= \row->row {scanhealthLastSuccess=O.toNullable(O.sqlInt8 now),
          scanhealthLastError=O.null,scanhealthCheckedAt=O.sqlInt8 now}
      , O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount }
    void $ O.runUpdate connection O.Update
      { O.uTable=custodycheckTable
      , O.uUpdateWith= \row->row {custodycheckCheckedRevision=O.toNullable(custodycheckRevision row),
          custodycheckCheckedAt=O.toNullable(O.sqlInt8 now),custodycheckLastError=O.null}
      , O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount }
    void $ O.runUpdate connection O.Update
      { O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 0}
      , O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount }
  InvalidateCustody -> void $ O.runUpdate connection O.Update
    { O.uTable=custodycheckTable
    , O.uUpdateWith= \row->row {custodycheckCheckedRevision=O.null}
    , O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount }
  OrderHoldCounts oid -> do
    orders <- O.runSelect connection $ do
      row <- O.selectTable ordersTable
      O.where_ (ordersId row O..== O.sqlStrictText oid)
      pure (ordersId row)
      :: IO [T.Text]
    holds <- O.runSelect connection $ do
      row <- O.selectTable reservationsTable
      O.where_ (reservationsOrderId row O..== O.sqlStrictText oid)
      pure (reservationsOrderId row)
      :: IO [T.Text]
    pure (length orders,length holds)
  ReplaceInstruction oid -> void $ O.runUpdate connection O.Update
    { O.uTable=ordersTable
    , O.uUpdateWith= \row->row {ordersInstruction=O.toNullable(O.sqlStrictText "replacement")}
    , O.uWhere= \row->ordersId row O..== O.sqlStrictText oid,O.uReturning=O.rCount }
  FreeWrapped -> do
    balances <- L.balances connection
    held <- O.runSelect connection $ do
      row <- O.selectTable reservationsTable
      O.where_ (reservationsAsset row O..== O.sqlStrictText "Wrapped" O..&&
                reservationsPhase row O../= O.sqlStrictText "released")
      pure (reservationsAmount row)
      :: IO [Int64]
    pure (M.findWithDefault 0 ("Wrapped","float") balances-sum(map toInteger held))

  ReceiptCounts -> do
    obligations <- O.runSelect connection (O.selectTable obligationsTable) :: IO [Obligations]
    events <- O.runSelect connection $ do
      row <- O.selectTable eventsTable
      O.where_ (eventsId row O..== O.sqlStrictText "deposit:contract-deposit:0")
      pure (eventsId row)
      :: IO [T.Text]
    pure (length obligations,length events)
  JournalState -> do
    events <- O.runSelect connection (O.selectTable eventsTable)
    postings <- O.runSelect connection (O.selectTable postingsTable)
    coverage <- fixture connection ReadCoverage
    custody <- O.runSelect connection (O.selectTable custodycheckTable)
    checkpoints <- O.runSelect connection (O.selectTable checkpointsTable)
    limits <- O.runSelect connection (O.selectTable ordercostlimitsTable)
    orders <- O.runSelect connection (O.selectTable ordersTable)
    pure (JournalSnapshot (sortOn eventsId events) (sortOn postingsId postings) coverage
      custody (sortOn checkpointsChain checkpoints) (sortOn ordercostlimitsOrderId limits) (sortOn ordersId orders))
  SendState -> (,,,)
    <$> (sortOn attemptsTxid <$> O.runSelect connection (O.selectTable attemptsTable))
    <*> (sortOn feereservationsIntentId <$> O.runSelect connection (O.selectTable feereservationsTable))
    <*> (sortOn reservationsOrderId <$> O.runSelect connection (O.selectTable reservationsTable))
    <*> (sortOn (\r->(operatingreservationsOrderId r,operatingreservationsKind r))
          <$> O.runSelect connection (O.selectTable operatingreservationsTable))
  FundedObligation -> do
    rows <- (O.runSelect connection $ do
      row <- O.selectTable obligationsTable
      O.where_ (obligationsDepositId row O..== O.sqlStrictText "contract-deposit:0")
      pure row) :: IO [Obligations]
    case rows of
      [row]->pure (Obligation (obligationsId row) (obligationsOrderId row)
        (obligationsDepositId row) (obligationsKind row) (obligationsAsset row)
        (obligationsAmount row) (obligationsRecipient row))
      _->reject "funded_contract_obligation_missing"
  InterruptedWrite reached hold -> do
    L.posting connection "interrupted" "cancellation contract"
      [(Native,"float",1),(Native,"external",-1)]
    void $ L.criticalSequence connection
    void $ O.runUpdate connection O.Update
      { O.uTable=checkpointsTable
      , O.uUpdateWith= \row->row {checkpointsAnchor=O.sqlStrictText "uncommitted"}
      , O.uWhere= \row->checkpointsChain row O..== O.sqlStrictText "Native",O.uReturning=O.rCount }
    putMVar reached ()
    takeMVar hold
  FailCommit bodyCompleted -> do
    -- Fault-injection DDL only. Application/test row access still uses Opaleye.
    -- This deferred FK fails at COMMIT, after the entire body has returned.
    void $ PG.execute_ connection "CREATE TEMP TABLE contract_commit_parent (id text PRIMARY KEY); CREATE TEMP TABLE contract_deferred_commit (event_id text REFERENCES contract_commit_parent(id) DEFERRABLE INITIALLY DEFERRED)"
    L.posting connection "commit-rollback" "deferred commit contract"
      [(Native,"float",1),(Native,"external",-1)]
    void $ L.criticalSequence connection
    void $ O.runInsert connection O.Insert
      { O.iTable=O.table "contract_deferred_commit" (O.requiredTableField "event_id")
      , O.iRows=[O.sqlStrictText "missing-event"],O.iReturning=O.rCount,O.iOnConflict=Nothing }
    writeIORef bodyCompleted True
  OperatingFunds -> (,) <$> L.freeOperating connection "Native" <*> L.freeOperating connection "Sol"
  FailCostPolicy -> void $ O.runUpdate connection O.Update
    { O.uTable=ordercostlimitsTable,O.uUpdateWith= \row->row {ordercostlimitsNativeFee=O.sqlInt8 5}
    , O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount }
  FailCapacity -> do
    -- PostgreSQL reports its actual disk_full SQLSTATE, without filling the
    -- host disk. This exercises error preservation, not filesystem durability.
    void $ PG.execute_ connection "CREATE FUNCTION pg_temp.contract_capacity_failure() RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'contract capacity failure' USING ERRCODE='53100'; END $$"
    void $ L.criticalSequence connection
    void (O.runSelect connection (pure (Column (Expr.FunExpr "pg_temp.contract_capacity_failure" []) :: O.Field O.SqlBool)) :: IO [Bool])
  FailTransaction -> do
    L.posting connection "must-rollback" "constraint rollback contract"
      [(Native,"float",1),(Native,"external",-1)]
    -- A genuine PostgreSQL uniqueness failure must roll back that posting too.
    void $ O.runInsert connection O.Insert
      { O.iTable=eventsTable,O.iRows=[Events (O.sqlStrictText "contract") (O.sqlStrictText "duplicate")]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }

-- Database contracts only: no RPC, signer, wallet or fabricated chain adapter.
-- Parse the example for its configuration shape; no network identity is used.
orderContracts :: PG.ConnectInfo -> IO ()
orderContracts settings = do
  base <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
  let quantity n=either (error . T.unpack) id (amount n)
      cfg=base {maxQueued=100,maxSolAccountRent=quantity 0,
                maxNativeDailyCost=quantity 1000000,maxSolDailyCost=quantity 1000000}
      capability=T.replicate 64 "a"
      request=OrderRequest NativeToWrapped (quantity 100000) "destination" "refund" Nothing "order-contract"
      expect code action=do
        result <- try (void action) :: IO (Either BridgeError ())
        require (case result of Left(BridgeError actual)->actual==code; _->False) ("expected:"<>code)
  L.withLedger settings "journal-contract" $ \ledger->do
    L.ledgerAction ledger (\connection->fixture connection FundOrderTests)
    first <- Order.createOrder ledger cfg 100 capability request
    retry <- Order.createOrder ledger cfg 999 capability request
    require (first==retry) "order_retry_changed_saved_terms"
    expect "idempotency_conflict" (Order.createOrder ledger cfg 100 capability request{recipient="changed"})
    expect "order_not_found" (Order.exposeOrder ledger False (T.replicate 64 "b") (ordersId first))
    view <- Order.exposeOrder ledger False capability (ordersId first)
    require (nativeDepth(policy view)==1 && fee(quote view)==quantity 1000 && net(quote view)==quantity 99000) "saved_order_terms_wrong"
    saved <- Order.createOrder ledger cfg{nativeConfirmations=6,maxNativeFee=quantity 5,
      maxSolFee=quantity 1,maxSolAccountRent=quantity 999999} 100 capability request
    require (saved==first) "configuration_changed_existing_order"
    limits <- Preparation.costLimits ledger (ordersId first)
    require (limits==CostLimits (quantity 1000) (quantity 10000) (quantity 0)) "saved_fee_ceilings_changed"
    fresh <- Order.createOrder ledger cfg{nativeConfirmations=6} 100 capability request{idempotencyKey="new-policy"}
    newView <- Order.exposeOrder ledger False capability (ordersId fresh)
    depth <- Observation.maximumNativeDepth ledger 1
    require (nativeDepth(policy newView)==6 && depth==6) "new_confirmation_policy_missing"
    Order.bindInstruction ledger (ordersId first) "database-instruction"
    hidden <- Order.exposeOrder ledger True capability (ordersId first)
    require (depositInstruction hidden==Nothing) "unbacked_instruction_exposed"
    expect "backup_pending" (Order.issueInstruction ledger cfg{backupRequired=True} 100 capability (ordersId first))
    coverage <- Order.instructionBackup ledger True capability (ordersId first)
    sequenceNo <- maybe (reject "instruction_coverage_missing") pure coverage
    L.acknowledgeBackup ledger "journal-contract" sequenceNo (T.replicate 64 "b")
    issued <- Order.issueInstruction ledger cfg{backupRequired=True} 100 capability (ordersId first)
    require (depositInstruction issued==Just "database-instruction") "backed_instruction_hidden"
    Order.expireQuotes ledger 100000
    expired <- Order.exposeOrder ledger False capability (ordersId fresh)
    require (status expired=="ExpiredUnfunded") "expired_order_erased"
    expect "order_no_longer_provisioning" (Order.bindInstruction ledger (ordersId fresh) "late-address")
    free <- L.ledgerAction ledger (\connection->fixture connection FreeWrapped)
    require (free==1000000) "expiry_did_not_release_inventory"
    -- Both payout and refund funds must be admitted atomically; rejection
    -- leaves every hold unchanged. The funded inventory alone is insufficient.
    let state :: Fixture a -> IO a
        state operation=L.ledgerAction ledger (\connection->fixture connection operation)
        largeRent=cfg{maxSolAccountRent=quantity 980000}
    rentOrder <- Order.createOrder ledger largeRent 100 capability request{idempotencyKey="rent"}
    funds <- state OperatingFunds
    require (funds==(999000,10000)) "quote_did_not_reserve_rent_and_refund"
    before <- state JournalState
    beforeHolds <- state SendState
    expect "insufficient_fee_budget" (Order.createOrder ledger largeRent 100 capability request{idempotencyKey="no-fee-capacity"})
    after <- state JournalState
    afterHolds <- state SendState
    require (before==after && beforeHolds==afterHolds) "rejected_fee_quote_changed_holds"
    holds <- state (OrderHoldCounts $ ordersId rentOrder)
    require (holds==(1,1)) "quote_inventory_hold_missing"
    (_,_,_,allowances) <- state SendState
    require (sortOn id [operatingreservationsKind r | r<-allowances,operatingreservationsOrderId r==ordersId rentOrder]==["conversion","refund"]) "quote_outcome_allowances_missing"
    Order.expireQuotes ledger 100000
    expect "insufficient_fee_budget" (Order.createOrder ledger cfg{maxNativeFee=quantity 1000001} 100 capability request{idempotencyKey="unfunded-refund"})
    state FreeWrapped >>= \n->require (n==1000000) "rejected_refund_quote_reserved_inventory"
    let limited=cfg{maxSolDailyCost=quantity 25000}
        small=request{input=quantity 10000}
    admitted <- mapConcurrently (\n->try (Order.createOrder ledger limited 100 capability
      small{idempotencyKey="daily-"<>T.pack(show n)}) :: IO (Either BridgeError Orders)) [1..20::Int]
    require (length [() | Right _<-admitted]==2 &&
      all (\case Left(BridgeError code)->code=="operating_daily_limit"; Right _->True) admitted) "concurrent_daily_cap_not_serialized"
    state OperatingFunds >>= \fundsAfter->require (fundsAfter==(998000,980000)) "concurrent_daily_holds_wrong"
    Order.expireQuotes ledger 100000
    results <- mapConcurrently (\n->try (Order.createOrder ledger cfg 100 capability
      request{idempotencyKey=T.pack(show n)}) :: IO (Either BridgeError Orders)) [1..20::Int]
    require (length [() | Right _<-results]==10 &&
      all (\case Left(BridgeError code)->code=="insufficient_inventory"; Right _->True) results) "concurrent_inventory_reservation_failed"
    remaining <- L.ledgerAction ledger (\connection->fixture connection FreeWrapped)
    require (remaining==10000) "reserved_inventory_or_fee_wrong"

    Order.expireQuotes ledger 100000
    let redemption=OrderRequest WrappedToNative (quantity 100000) "native-destination" "" Nothing "connection-free"
        transport=Workflow.OrderTransport (pure 100) (const $ pure ()) (pure ())
          (\_ _ _->reject "unexpected_native_rpc") (\_->reject "unexpected_backup")
    -- Exercise the production provisioning workflow without any chain IO.
    provisioned <- Workflow.createCustomerOrderWith transport cfg ledger capability redemption
    instruction <- either reject pure (Pay.payInstruction $ orderId provisioned)
    require (depositInstruction provisioned==Just instruction &&
      fee(quote provisioned)==quantity 1000 && net(quote provisioned)==quantity 99000)
      "connection_free_redemption_binding_wrong"
    let noEffects=transport {Workflow.orderAdmission=const $ reject "unexpected_readmission",
                             Workflow.orderIdentity=reject "unexpected_identity_call"}
    replay <- Workflow.createCustomerOrderWith noEffects cfg ledger capability redemption
    require (replay==provisioned) "provisioning_replay_changed_order"
    expect "idempotency_conflict" (Workflow.createCustomerOrderWith transport cfg ledger capability
      redemption{recipient="changed"})
    funded <- Order.createOrder ledger cfg 100 capability request{idempotencyKey="funded"}
    partial <- Order.createOrder ledger cfg 100 capability request{idempotencyKey="partial"}
    Order.bindInstruction ledger (ordersId funded) "funded-instruction"
    let deposit=Deposit "contract-deposit:0" (Just $ ordersId funded) Native
          (quantity 100000) "database-anchor" 1 True 100
    Observation.recordScan ledger "Native" (Just "database-contract") "funded" [deposit]
    promoted <- Observation.promoteDeposit ledger 110 "contract-deposit:0"
    require promoted "eligible_deposit_not_promoted"
    Observation.recordScan ledger "Native" (Just "funded") "replayed" [deposit{depositConfirmations=2}]
    repeated <- Observation.promoteDeposit ledger 120 "contract-deposit:0"
    counts <- L.ledgerAction ledger (\connection->fixture connection ReceiptCounts)
    require (not repeated && counts==(1,1)) "deposit_replay_duplicated_accounting"
    Observation.recordScan ledger "Native" (Just "replayed") "partial"
      [Deposit "partial:0" (Just $ ordersId partial) Native (quantity 10) "database-anchor" 1 True 100]
    accepted <- Observation.promoteDeposit ledger 110 "partial:0"
    review <- Order.exposeOrder ledger False capability (ordersId partial)
    require (not accepted && status review=="NeedsReview") "partial_deposit_not_held_for_review"
    Order.expireQuotes ledger 100000
    retained <- L.ledgerAction ledger (\connection->fixture connection FreeWrapped)
    require (retained==901000) "expiry_released_eligible_obligation"

-- Each fault runs against a disposable real PostgreSQL ledger. A failed
-- commit/send-intent cannot leak a posting, advance its sequence or grant send.
rollbackContract :: PG.ConnectInfo -> IO ()
rollbackContract settings = do
  L.withLedger settings "journal-contract" $ \ledger->do
    before <- state ledger JournalState
    reached <- newEmptyMVar
    hold <- newEmptyMVar
    withAsync (state ledger (InterruptedWrite reached hold)) $ \pending->do
      entered <- timeout 2000000 (takeMVar reached)
      require (entered==Just ()) "interrupted_transaction_not_entered"
      cancel pending
    after <- state ledger JournalState
    require (before==after) "interruption_published_uncommitted_state"
  bodyCompleted <- newIORef False
  forM_ [("23505",FailTransaction),("23503",FailCommit bodyCompleted),("53100",FailCapacity),("23514",FailCostPolicy)] $ \(code,operation)->do
    before <- L.withLedger settings "journal-contract" $ \ledger->do
      original <- state ledger JournalState
      result <- try (state ledger operation) :: IO (Either PG.SqlError ())
      require (case result of Left err->PG.sqlState err==code; _->False) ("database_fault_not_preserved:"<>T.pack(show(code,result)))
      expectFenced (state ledger JournalState)
      pure original
    L.withLedger settings "journal-contract" $ \ledger->do
      after <- state ledger JournalState
      require (before==after) "failed_transaction_changed_journal"
      paused <- L.readiness ledger
      require (not $ available paused) "failed_transaction_reopened_unpaused"
  readIORef bodyCompleted >>= \finished->require finished "commit_fault_occurred_before_body_completed"
  broadcastWriteContract settings
 where
  state ledger operation=L.ledgerAction ledger (\connection->fixture connection operation)

expectFenced :: IO a -> IO ()
expectFenced action = do
  result <- try (void action) :: IO (Either IOException ())
  require (case result of Left _->True; _->False) "failed_transaction_connection_reused"

broadcastWriteContract :: PG.ConnectInfo -> IO ()
broadcastWriteContract settings = do
  base <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
  let quantity n=either (error . T.unpack) id (amount n)
      cfg=base {maxSolAccountRent=quantity 0,maxNativeDailyCost=quantity 1000000,maxSolDailyCost=quantity 1000000}
      state ledger operation=L.ledgerAction ledger (\connection->fixture connection operation)
      txid="contract-send-write-failure"
  (before,saved) <- L.withLedger settings "journal-contract" $ \ledger->do
    state ledger (ReadyAt 100)
    ob <- state ledger FundedObligation
    Preparation.begin ledger cfg ob "Solana" 10000 "{\"contract\":true}"
    generation <- Preparation.active ledger (obligationId ob)
    Preparation.storeAttempt ledger ob "Solana" txid "original-contract-bytes" "{}" 10000 Nothing generation
    original <- state ledger JournalState
    signed <- state ledger SendState
    -- A genuine server constraint refuses the authority-granting state write.
    L.ledgerAction ledger $ \connection->void $ PG.execute_ connection
      "ALTER TABLE attempts ADD CONSTRAINT contract_send_write_failure CHECK (state <> 'broadcast_intent')"
    result <- try (Settlement.markBroadcastIntent ledger txid) :: IO (Either PG.SqlError Int64)
    require (case result of Left err->PG.sqlState err=="23514"; _->False) "broadcast_write_failure_missing"
    expectFenced (Settlement.authorizeRecordedSend ledger False txid)
    pure (original,signed)
  bracket (PG.connect settings) PG.close $ \connection->void $ PG.execute_ connection
    "ALTER TABLE attempts DROP CONSTRAINT contract_send_write_failure"
  L.withLedger settings "journal-contract" $ \ledger->do
    after <- state ledger JournalState
    attempts <- state ledger SendState
    require (before==after && saved==attempts) "failed_broadcast_write_changed_bytes_or_holds"
    expectError "broadcast_intent_required" (Settlement.authorizeRecordedSend ledger False txid)

-- Offline RPC contracts against the production PostgreSQL order workflow.
-- The in-memory node below models uncertain replies, not a real network.
provisioningContracts :: PG.ConnectInfo -> IO ()
provisioningContracts settings = do
  base <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
  let quantity n=either (error . T.unpack) id (amount n)
      cfg=base {maxQueued=100,maxSolAccountRent=quantity 0,
                maxNativeDailyCost=quantity 1000000,maxSolDailyCost=quantity 1000000}
      cap=T.replicate 64 "c"
      request name=OrderRequest NativeToWrapped (quantity 10000) "destination" "refund" Nothing name
      ready ledger now=L.ledgerAction ledger (\connection->fixture connection (ReadyAt now))
      saved ledger name=Order.findSavedOrder ledger cfg cap (request name) >>= maybe (reject "missing_provisioning_order") pure
      hidden ledger row=do
        view <- Order.exposeOrder ledger False cap (ordersId row)
        require (depositInstruction view==Nothing) "unissued_instruction_exposed"
      countIs count n=readIORef count >>= \actual->require (actual==n) "allocation_count_wrong"
      lost transport wallet method params=do
        result <- orderNative transport wallet method params
        if method=="getnewaddress" then reject "rpc_transport_unknown_outcome" else pure result
      run name action=do
        putStrLn ("Provisioning contract: "<>T.unpack name)
        L.withLedger settings "journal-contract" $ \ledger->do
          Order.expireQuotes ledger 100000
          ready ledger 100
          (transport,count) <- provisioningTransport cfg name
          action ledger transport count (request name)
      create transport ledger req=Workflow.createCustomerOrderWith transport cfg ledger cap req
  run "issued-replay" $ \ledger transport count req->do
    first <- create transport ledger req
    require (depositInstruction first==Just ("fixture-receive-"<>idempotencyKey req<>"-1")) "address_not_issued"
    L.pause ledger "contract-paused"
    let noChecks=transport {orderAdmission=const $ reject "unexpected_admission",orderIdentity=reject "unexpected_identity"}
    replay <- Workflow.createCustomerOrderWith noChecks cfg{maxInput=quantity 2,maxSolFee=quantity 1} ledger cap req
    require (replay==first) "issued_replay_changed"
    expectError "idempotency_conflict" (create noChecks ledger req{recipient="changed"})
    countIs count 1
    -- Verify the database trigger itself, not just bindInstruction's guard.
    changed <- try (L.ledgerAction ledger (\connection->fixture connection (ReplaceInstruction $ orderId first))) :: IO (Either PG.SqlError ())
    require (case changed of Left err->PG.sqlState err=="23514"; _->False) "instruction_mutation_accepted"
  run "admission-failure" $ \ledger transport count req->do
    expectError "fixture_admission_failed" (create transport{orderAdmission=const $ reject "fixture_admission_failed"} ledger req)
    missing <- Order.findSavedOrder ledger cfg cap req
    require (missing==Nothing) "failed_admission_stored_order"
    countIs count 0
  run "stale-admission" $ \ledger transport count req->do
    expectError "scanners_not_fresh" (create transport{orderClock=pure 161} ledger req)
    expectError "intake_paused" (create transport{orderAdmission=const $ Observation.recordScanFailure ledger "Solana" 100 "contract-outage"} ledger req)
    missing <- Order.findSavedOrder ledger cfg cap req
    require (missing==Nothing) "stale_admission_stored_order"
    countIs count 0
  run "lost-reply" $ \ledger transport count req->do
    expectError "rpc_transport_unknown_outcome" (create transport{orderNative=lost transport} ledger req)
    prior <- saved ledger (idempotencyKey req)
    require (ordersStatus prior=="Provisioning") "lost_reply_not_durable"
    hidden ledger prior
    recovered <- create transport ledger req
    require (orderId recovered==ordersId prior && deadline recovered==ordersDeadline prior &&
      depositInstruction recovered==Just ("fixture-receive-"<>idempotencyKey req<>"-1")) "lost_reply_recovery_changed_order"
    countIs count 1
  run "unresolved-allocation" $ \ledger transport count req->do
    let absent wallet method params=if method=="getnewaddress" then reject "rpc_transport_unknown_outcome" else orderNative transport wallet method params
    expectError "rpc_transport_unknown_outcome" (create transport{orderNative=absent} ledger req)
    expectError "native_allocation_unresolved" (create transport ledger req)
    countIs count 0
  run "ambiguous-label" $ \ledger transport count req->do
    let values=[Null,object [],object ["one" .= object ["purpose" .= ("receive"::T.Text)],"two" .= object ["purpose" .= ("receive"::T.Text)]]]
    forM_ (zip [1::Int ..] values) $ \(i,value)->do
      let bad wallet method params=if method=="getaddressesbylabel" then pure value else orderNative transport wallet method params
      expectError "native_allocation_ambiguous" (create transport{orderNative=bad} ledger req{idempotencyKey="ambiguous-"<>T.pack(show i)})
    countIs count 0
  run "address-policy" $ \ledger transport count req->do
    let bad wallet method params=do
          value <- orderNative transport wallet method params
          pure $ case (method,value) of
            ("getaddressinfo",Object fields)->Object(KM.insert "ismine" (Bool False) fields)
            _->value
    expectError "native_allocation_policy_mismatch" (create transport{orderNative=bad} ledger req)
    saved ledger (idempotencyKey req) >>= hidden ledger
    void $ create transport ledger req
    countIs count 1
  run "concurrent-retry" $ \ledger transport count req->do
    results <- mapConcurrently (const (try (create transport ledger req) :: IO (Either BridgeError OrderView))) [1..20::Int]
    let succeeded=[view | Right view<-results]
    require (case succeeded of first:rest->all (==first) rest; []->False) "concurrent_retry_changed_order"
    countIs count 1
    row <- saved ledger (idempotencyKey req)
    counts <- L.ledgerAction ledger (\connection->fixture connection (OrderHoldCounts $ ordersId row))
    require (counts==(1,1)) "concurrent_retry_duplicated_reservation"
  run "pause-during-allocation" $ \ledger transport count req->do
    let stopping wallet method params=do
          value <- orderNative transport wallet method params
          when (method=="getnewaddress") (L.pause ledger "contract-paused")
          pure value
    expectError "intake_paused" (create transport{orderNative=stopping} ledger req)
    row <- saved ledger (idempotencyKey req)
    require (ordersInstruction row==Just ("fixture-receive-"<>idempotencyKey req<>"-1")) "paused_allocation_not_recorded"
    hidden ledger row
    countIs count 1
  run "backup-deadline" $ \ledger transport count req->do
    let backed=cfg{backupRequired=True}
    expectError "backup_pending" (Workflow.createCustomerOrderWith transport backed ledger cap req)
    prior <- saved ledger (idempotencyKey req)
    hidden ledger prior
    now <- newIORef 100
    let delayed=transport {orderClock=readIORef now,orderBackup= \n->do
          L.acknowledgeBackup ledger "journal-contract" n (T.replicate 64 "d")
          writeIORef now (ordersDeadline prior+1)
          ready ledger (ordersDeadline prior+1)}
    expectError "deposit_window_closed" (Workflow.createCustomerOrderWith delayed backed ledger cap req)
    hidden ledger prior
    countIs count 1
  run "late-recovery" $ \ledger transport count req->do
    free <- L.ledgerAction ledger (\connection->fixture connection FreeWrapped)
    expectError "rpc_transport_unknown_outcome" (create transport{orderNative=lost transport} ledger req)
    ready ledger 100000
    expectError "deposit_window_closed" (create transport{orderClock=pure 100000} ledger req)
    row <- saved ledger (idempotencyKey req)
    require (ordersStatus row=="ExpiredUnfunded" && ordersInstruction row==Just ("fixture-receive-"<>idempotencyKey req<>"-1")) "late_recovery_reopened_order"
    hidden ledger row
    after <- L.ledgerAction ledger (\connection->fixture connection FreeWrapped)
    require (after==free) "late_recovery_retained_quote_hold"
    countIs count 1
  (transport,count) <- provisioningTransport cfg "restart"
  let req=request "restart-recovery"
  prior <- L.withLedger settings "journal-contract" $ \ledger->do
    ready ledger 100
    expectError "rpc_transport_unknown_outcome" (create transport{orderNative=lost transport} ledger req)
    saved ledger (idempotencyKey req)
  L.withLedger settings "journal-contract" $ \ledger->do
    expectError "intake_paused" (create transport ledger req)
    hidden ledger prior
    ready ledger 100
    L.ledgerAction ledger (\connection->fixture connection InvalidateCustody)
    expectError "custody_not_reconciled" (create transport ledger req)
    ready ledger 100
    restored <- create transport ledger req
    require (orderId restored==ordersId prior && deadline restored==ordersDeadline prior) "restart_lost_allocation_claim"
    countIs count 1

expectError :: T.Text -> IO a -> IO ()
expectError code action=do
  result <- try (void action) :: IO (Either BridgeError ())
  require (case result of Left(BridgeError actual)->actual==code; _->False) ("expected:"<>code<>", got:"<>T.pack(show result))

provisioningTransport :: Config -> T.Text -> IO (OrderTransport,IORef Int)
provisioningTransport cfg name=do
  count <- newIORef 0
  addresses <- newIORef ([]::[(T.Text,T.Text)])
  let native wallet method params=do
        require wallet "provisioning_requires_wallet"
        case (method,params) of
          ("getwalletinfo",[]) -> pure $ object ["walletname" .= nativeWallet cfg,"descriptors" .= True,
            "private_keys_enabled" .= True,"external_signer" .= False,"scanning" .= False]
          ("getaddressesbylabel",[String label]) -> do
            found <- map snd . filter ((==label).fst) <$> readIORef addresses
            if null found then reject "rpc_error_-11" else pure $ object
              [Key.fromText address .= object ["purpose" .= ("receive"::T.Text)] | address<-found]
          ("getnewaddress",[String label,String "bech32"]) -> do
            n <- atomicModifyIORef' count (\old->(old+1,old+1))
            let address="fixture-receive-"<>name<>"-"<>T.pack(show n)
            atomicModifyIORef' addresses (\old->((label,address):old,()))
            pure (String address)
          ("getaddressinfo",[String address]) -> do
            labels <- map fst . filter ((==address).snd) <$> readIORef addresses
            pure $ object ["address" .= address,"labels" .= labels,"ismine" .= True,"solvable" .= True,
              "ischange" .= False,"scriptPubKey" .= ("0014"<>T.replicate 40 "1")]
          _ -> reject ("unexpected_provisioning_rpc:"<>method)
  pure (OrderTransport (pure 100) (const $ pure ()) (pure ()) native (const $ pure ()),count)
