{-# LANGUAGE GADTs #-}
module Main (main) where

import Bridge.Types hiding (deploymentFingerprint)
import Bridge.Ledger.Model (Deposit(..))
import Bridge.Config
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Postgres.Observation as Observation
import qualified Data.ByteString as BS
import Data.Aeson (eitherDecodeStrict')
import Control.Monad (void)
import qualified Bridge.Postgres.Ledger as L
import Bridge.Postgres.Schema
import qualified Opaleye as O
import Control.Exception (bracket, try, IOException)
import Control.Concurrent.Async (withAsync,wait,mapConcurrently)
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
  rollbackContract settings
  putStrLn "PostgreSQL journal and backup acknowledgment: balanced writes, row locking, ownership, exact coverage, identity/receipt/stale refusal, idempotence, durable reopen, order contracts and SQL-error rollback/fencing passed"


-- Closed test operations: no arbitrary SQL/query callback in fixture access.
data Fixture a where
  InitializeFixture :: Fixture ()
  LockDeployment :: Fixture ()
  ReadCoverage :: Fixture [(Int64,Int64,Int64)]
  FundOrderTests :: Fixture ()
  FreeWrapped :: Fixture Integer
  ReceiptCounts :: Fixture (Int,Int)
  FailTransaction :: Fixture ()
  JournalState :: Fixture ([Events],[Postings],[(Int64,Int64,Int64)])

fixture :: PG.Connection -> Fixture a -> IO a
fixture connection = \case
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
    void $ O.runUpdate connection O.Update
      { O.uTable=custodycheckTable
      , O.uUpdateWith= \row->row {custodycheckCheckedRevision=O.toNullable(custodycheckRevision row),
          custodycheckCheckedAt=O.toNullable(O.sqlInt8 100),custodycheckLastError=O.null}
      , O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount }
    void $ O.runUpdate connection O.Update
      { O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 0}
      , O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount }
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
    pure (sortOn eventsId events,sortOn postingsId postings,coverage)
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
    saved <- Order.createOrder ledger cfg{nativeConfirmations=6} 100 capability request
    require (saved==first) "configuration_changed_existing_order"
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
    results <- mapConcurrently (\n->try (Order.createOrder ledger cfg 100 capability
      request{idempotencyKey=T.pack(show n)}) :: IO (Either BridgeError Orders)) [1..20::Int]
    require (length [() | Right _<-results]==10 &&
      all (\case Left(BridgeError code)->code=="insufficient_inventory"; Right _->True) results) "concurrent_inventory_reservation_failed"
    remaining <- L.ledgerAction ledger (\connection->fixture connection FreeWrapped)
    require (remaining==10000) "reserved_inventory_or_fee_wrong"

    Order.expireQuotes ledger 100000
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

rollbackContract :: PG.ConnectInfo -> IO ()
rollbackContract settings = do
  before <- L.withLedger settings "journal-contract" $ \ledger->do
    original <- L.ledgerAction ledger (\connection->fixture connection JournalState)
    result <- try (L.ledgerAction ledger (\connection->fixture connection FailTransaction)) :: IO (Either PG.SqlError ())
    require (case result of Left err->PG.sqlState err=="23505"; _->False) "constraint_failure_missing"
    fenced <- try (L.ledgerAction ledger L.balances) :: IO (Either IOException (M.Map (T.Text,T.Text) Integer))
    require (case fenced of Left _->True; _->False) "failed_transaction_connection_reused"
    pure original
  L.withLedger settings "journal-contract" $ \ledger->do
    after <- L.ledgerAction ledger (\connection->fixture connection JournalState)
    require (before==after) "failed_transaction_changed_journal"
