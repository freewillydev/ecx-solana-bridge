{-# LANGUAGE GADTs #-}
module Main (main) where

import qualified AuthorityCheck
import qualified SourceApprovalCheck
import Bridge.Types hiding (deploymentFingerprint)
import Bridge.Ledger.Model (Deposit(..),Obligation(..),Preparation(..),CostLimits(..),ScanBatch(..),ChainEvent(..))
import qualified Bridge.Postgres.FeeWithdrawal as Withdrawal
import qualified Bridge.Postgres.Treasury as Treasury
import qualified Bridge.Postgres.Preparation as Preparation
import qualified Bridge.Postgres.Settlement as Settlement
import Bridge.Config
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Postgres.Runtime as Runtime
import Bridge.RPC (fieldValue)
import qualified Bridge.Order as Workflow
import qualified Bridge.SolanaPay as Pay
import qualified Bridge.Postgres.Observation as Observation
import qualified Data.Text.Encoding as TE
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
import System.Environment (lookupEnv,getArgs,withArgs)
import Test.QuickCheck (quickCheckWithResult, stdArgs, maxSuccess, forAll, chooseInt, elements, ioProperty, isSuccess, conjoin, counterexample)

-- Dedicated fresh schema contract, never the funded bridge's database.
main :: IO ()
main = getArgs >>= \case
  ["journal"] -> journalContracts
  ["source"] -> SourceApprovalCheck.run
  "fence":arguments -> withArgs arguments AuthorityCheck.run
  "observer":arguments -> withArgs ("observer":arguments) AuthorityCheck.run
  _ -> reject "postgres_contract_mode_required: journal | source | fence DATABASE_A DATABASE_B DIRECTORY | observer BRIDGE_BINARY CONFIG DATABASE DIRECTORY"

journalContracts :: IO ()
journalContracts = do
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
  treasuryContracts settings
  observerContracts settings
  quoteProperties settings
  journalProperties settings
  feeWithdrawalProperties settings
  putStrLn "PostgreSQL journal and backup acknowledgment: balanced writes, row locking, ownership, exact coverage, identity/receipt/stale refusal, idempotence, durable reopen, order/provisioning contracts, interruption, commit/capacity failure, send-authority rollback/fencing, treasury classification, fee funding and observer page contracts passed"


-- Retains the retired fee-funding harness's checks, generated for both assets.
-- Only funding/cancellation: no chain model, signer or payout claim.
feeWithdrawalProperties :: PG.ConnectInfo -> IO ()
feeWithdrawalProperties settings = do
  base <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
  let quantity n=either (error . T.unpack) id (amount n)
      cfg=base {maxInput=quantity (toInteger(maxBound::Int64))}
  bracket (PG.connect settings) PG.close $ \c->PG.withTransaction c
    (fixture c $ BeginFeeContract $ fingerprint cfg)
  result <- L.withLedger settings (fingerprint cfg) $ \ledger->
    quickCheckWithResult stdArgs {maxSuccess=20} $
      forAll (chooseInt (1000,100000)) $ \funded->forAll (elements [Native,Wrapped]) $ \currency->ioProperty $ do
        key <- randomId
        other <- randomId
        let holdings=(toInteger funded*3) `div` 5
            reason="dedicated accounting contract"
            balance account rows=M.findWithDefault 0 (T.pack(show currency),account) rows
            readBalances=L.ledgerAction ledger L.balances
            fresh=L.ledgerAction ledger (\c->fixture c FreshFeeContract)
            reserve identifier asset n recipient=void(Withdrawal.reserve ledger cfg 100 identifier asset (quantity n) recipient reason)
            cancelFunding why=void(Withdrawal.cancel ledger key why)
        before <- readBalances
        L.ledgerAction ledger $ \c->do
          fixture c (BeginFeeContract $ fingerprint cfg)
          L.posting c ("fee-fixture:"<>key) "database-only earned fee fixture"
            [(currency,"earned",toInteger funded),(currency,"external",negate $ toInteger funded)]
        expectError "custody_not_reconciled" (reserve key currency holdings "recipient")
        fresh
        expectError "fee_withdrawal_profile_mismatch" $ void(Withdrawal.reserve ledger
          cfg{deploymentId="another-deployment"} 100 key currency (quantity holdings) "recipient" reason)
        expectError "invalid_fee_withdrawal" (reserve key Sol holdings "recipient")
        expectError "invalid_fee_withdrawal" (reserve key currency 0 "recipient")
        expectError "invalid_fee_withdrawal" $ void(Withdrawal.reserve ledger
          cfg{maxInput=quantity (holdings-1)} 100 key currency (quantity holdings) "recipient" reason)
        expectError "insufficient_earned_fees" (reserve key currency (balance "earned" before+toInteger funded+1) "recipient")
        reserve key currency holdings "recipient"
        held <- readBalances
        require (balance "earned" held==balance "earned" before+toInteger funded-holdings
          && balance "fee_pending" held==balance "fee_pending" before+holdings) "fee_reservation_balance_mismatch"
        reserve key currency holdings "recipient"
        expectError "fee_withdrawal_conflict" (reserve key currency holdings "changed-recipient")
        replay <- readBalances
        require (replay==held) "fee_reservation_replay_changed_balances"
        expectError "custody_not_reconciled" (reserve other currency holdings "recipient")
        fresh
        expectError "insufficient_earned_fees" (reserve other currency (balance "earned" held+1) "recipient")
        cancelFunding "unsigned cancellation"
        released <- readBalances
        require (balance "earned" released==balance "earned" before+toInteger funded
          && balance "fee_pending" released==balance "fee_pending" before) "fee_cancellation_balance_mismatch"
        cancelFunding "unsigned cancellation"
        expectError "fee_withdrawal_cancellation_conflict" (cancelFunding "changed reason")
        replayCancel <- readBalances
        require (replayCancel==released) "fee_cancellation_replay_changed_balances"
        L.ledgerAction ledger (\c->fixture c (ReadyAt 100))
        expectError "fee_withdrawal_requires_pause" (reserve other currency 1 "recipient")
        pure True
  require (isSuccess result) "postgres_fee_withdrawal_properties_failed"

-- Replacement for the SQLite accounting fixtures: generated values run against
-- the actual PostgreSQL transaction and Opaleye implementation, not a model DB.
journalProperties :: PG.ConnectInfo -> IO ()
journalProperties settings = L.withLedger settings "journal-contract" $ \ledger -> do
  result <- quickCheckWithResult stdArgs {maxSuccess=40} $
    forAll (chooseInt (1,1000000)) $ \n -> forAll (elements [Native,Wrapped,Sol]) $ \asset -> ioProperty $ do
      event <- ("property:"<>) <$> randomId
      before <- L.ledgerAction ledger L.balances
      sequenceBefore <- readSequence ledger
      let delta=toInteger n
          key=(T.pack $ show asset,"property")
      rejected <- try (L.ledgerAction ledger $ \connection ->
        L.posting connection event "generated unbalanced refusal" [(asset,"property",delta)])
          :: IO (Either BridgeError ())
      unchanged <- L.ledgerAction ledger L.balances
      sequenceUnchanged <- readSequence ledger
      _ <- L.ledgerAction ledger $ \connection -> do
        L.posting connection event "generated conservation" [(asset,"property",delta),(asset,"external",-delta)]
        L.criticalSequence connection
      after <- L.ledgerAction ledger L.balances
      sequenceAfter <- readSequence ledger
      let totals balances = M.fromListWith (+) [(chain,value) | ((chain,_),value)<-M.toList balances]
      pure $ conjoin
        [ counterexample "unbalanced posting was not refused" (rejected==Left (BridgeError "unbalanced_journal"))
        , counterexample "failed write changed balances or sequence" (unchanged==before && sequenceUnchanged==sequenceBefore)
        , counterexample "successful commit did not advance once" (sequenceAfter==sequenceBefore+1)
        , counterexample "posting lost its exact delta" (M.findWithDefault 0 key after==M.findWithDefault 0 key before+delta)
        , counterexample "per-asset conservation failed" (totals after==totals before) ]
  require (isSuccess result) "postgres_journal_properties_failed"
 where
  readSequence ledger = do
    rows <- L.ledgerAction ledger (\connection -> fixture connection ReadCoverage)
    case rows of
      [(sequenceNo,_,_)] -> pure sequenceNo
      _ -> reject "corrupt_sequence"


-- Saved quote, replay and ownership properties replace backend-specific fixtures.
quoteProperties :: PG.ConnectInfo -> IO ()
quoteProperties settings = do
  base <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
  let cfg=base {maxQueued=100, minInput=either (error . T.unpack) id (amount 101),
                maxNativeDailyCost=either (error . T.unpack) id (amount 1000000),
                maxSolDailyCost=either (error . T.unpack) id (amount 1000000),
                maxSolAccountRent=either (error . T.unpack) id (amount 0)}
      capability=T.replicate 64 "a"
  L.withLedger settings "journal-contract" $ \ledger -> do
    result <- quickCheckWithResult stdArgs {maxSuccess=20} $
      forAll (chooseInt (101,10000)) $ \gross -> ioProperty $ do
        ident <- randomId
        let quantity=either (error . T.unpack) id (amount $ toInteger gross)
            request=OrderRequest NativeToWrapped quantity "destination" "refund" Nothing ident
        L.ledgerAction ledger (\connection -> fixture connection $ ReadyAt 100)
        first <- Order.createOrder ledger cfg 100 capability request
        replay <- Order.createOrder ledger cfg{nativeConfirmations=6,maxNativeFee=either (error . T.unpack) id (amount 1)} 999 capability request
        conflict <- try (Order.createOrder ledger cfg 100 capability request{recipient="other"}) :: IO (Either BridgeError Orders)
        wrongOwner <- try (Order.exposeOrder ledger False (T.replicate 64 "b") (ordersId first)) :: IO (Either BridgeError OrderView)
        view <- Order.exposeOrder ledger False capability (ordersId first)
        pure (first==replay && conflict==Left (BridgeError "idempotency_conflict")
          && wrongOwner==Left (BridgeError "order_not_found")
          && units(fee $ quote view)==fromIntegral ((gross+99) `div` 100)
          && units(net $ quote view)+units(fee $ quote view)==fromIntegral gross)
    require (isSuccess result) "postgres_quote_properties_failed"

-- Closed test operations: no arbitrary SQL/query callback in fixture access.
data Fixture a where
  InitializeFixture :: Fixture ()
  BeginFeeContract :: T.Text -> Fixture ()
  FreshFeeContract :: Fixture ()
  LockDeployment :: Fixture ()
  DeploymentState :: Fixture [Deployment]
  ReadCoverage :: Fixture [(Int64,Int64,Int64)]
  FundOrderTests :: Fixture ()
  ReadyAt :: Int64 -> Fixture ()
  InvalidateCustody :: Fixture ()
  OrderHoldCounts :: T.Text -> Fixture (Int,Int)
  ReplaceInstruction :: T.Text -> Fixture ()
  FreeWrapped :: Fixture Integer
  Inventory :: Asset -> Fixture Integer
  TreasuryState :: Fixture ([TreasurySpends],[ChainEvents])
  ReceiptState :: Fixture ([Deposits],[TreasuryAllocations])
  ScanState :: Fixture ([ScanOrigins],[ScanHealth],[ObservationEvidence],[ChainEvents],[Audit])
  ReceiptCounts :: Fixture (Int,Int)
  FailTransaction :: Fixture ()
  FailCommit :: IORef Bool -> Fixture ()
  FailCapacity :: Fixture ()
  FailCostPolicy :: Fixture ()
  FailEvidence :: Fixture ()
  OperatingFunds :: Fixture (Integer,Integer)
  InterruptedWrite :: MVar () -> MVar () -> Fixture ()
  FundedObligation :: Fixture Obligation
  SendState :: Fixture ([Attempts],[FeeReservations],[Reservations],[OperatingReservations])
  JournalState :: Fixture JournalSnapshot

data JournalSnapshot = JournalSnapshot [Events] [Postings] [(Int64,Int64,Int64)]
  [CustodyCheck] [Checkpoints] [OrderCostLimits] [Orders] deriving (Eq,Show)

fixture :: PG.Connection -> Fixture a -> IO a
fixture connection = \case
  BeginFeeContract identity -> do
    void $ O.runUpdate connection O.Update
      {O.uTable=deploymentTable,O.uUpdateWith= \row->row
        {deploymentFingerprint=O.sqlStrictText identity,deploymentPaused=O.sqlInt8 1}
      ,O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
    fixture connection InvalidateCustody
  FreshFeeContract -> void $ O.runUpdate connection O.Update
    {O.uTable=custodycheckTable,O.uUpdateWith= \row->row
      {custodycheckCheckedRevision=O.toNullable(custodycheckRevision row)
      ,custodycheckCheckedAt=O.toNullable(O.sqlInt8 100),custodycheckLastError=O.null}
    ,O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
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
  FreeWrapped -> L.freeInventory connection Wrapped
  Inventory asset -> L.freeInventory connection asset
  TreasuryState -> (,)
    <$> (sortOn (\r->(treasuryspendsChain r,treasuryspendsEventId r)) <$> O.runSelect connection (O.selectTable treasuryspendsTable))
    <*> (sortOn (\r->(chaineventsChain r,chaineventsEventId r)) <$> O.runSelect connection (O.selectTable chaineventsTable))

  ScanState -> (,,,,)
    <$> (sortOn scanoriginsChain <$> O.runSelect connection (O.selectTable scanoriginsTable))
    <*> (sortOn scanhealthChain <$> O.runSelect connection (O.selectTable scanhealthTable))
    <*> (sortOn observationevidenceHash <$> O.runSelect connection (O.selectTable observationevidenceTable))
    <*> (sortOn (\r->(chaineventsChain r,chaineventsEventId r)) <$> O.runSelect connection (O.selectTable chaineventsTable))
    <*> (sortOn auditId <$> O.runSelect connection (O.selectTable auditTable))
  ReceiptState -> (,)
    <$> (sortOn depositsId <$> O.runSelect connection (O.selectTable depositsTable))
    <*> (sortOn treasuryallocationsDepositId <$> O.runSelect connection (O.selectTable treasuryallocationsTable))
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
  FailEvidence -> void $ O.runUpdate connection O.Update
    { O.uTable=observationevidenceTable
    , O.uUpdateWith= \row->row {observationevidenceEvidenceJson=O.sqlStrictText "tampered"}
    , O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount }
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
    expectError "payment_not_prepared" $ L.ledgerAction ledger $ \c->
      Preparation.signingDecisionC c cfg (obligationId ob) generation
    Preparation.storeDraft ledger (obligationId ob) "{}" generation
    (prepared,_) <- L.ledgerAction ledger $ \c->Preparation.signingDecisionC c cfg (obligationId ob) generation
    require (preparationObligation prepared==ob && preparationDraft prepared==Just "{}"
      && preparationGeneration prepared==generation) "signing_decision_not_bound"
    expectError "preparation_generation_changed" $ L.ledgerAction ledger $ \c->
      Preparation.signingDecisionC c cfg (obligationId ob) (generation+1)
    -- Cancellation must fence the old generation without dropping its fee hold.
    let cleanup=object ["unsigned" .= True]
        cancelUnsigned=Preparation.beginCancellation ledger prepared 100 "contract cancellation" cleanup
        signing gen=L.ledgerAction ledger (\c->Preparation.signingDecisionC c cfg (obligationId ob) gen)
    expectError "pause_before_operator_action" cancelUnsigned
    L.pause ledger "contract cancellation"
    state ledger InvalidateCustody
    expectError "custody_not_reconciled" cancelUnsigned
    state ledger FreshFeeContract
    (_,held,_,_) <- state ledger SendState
    cancelUnsigned
    journal <- state ledger JournalState
    cancelUnsigned
    state ledger JournalState >>= \replayed->require (replayed==journal) "cancellation_replay_changed_journal"
    expectError "preparation_cancellation_conflict" $
      Preparation.beginCancellation ledger prepared 100 "different reason" cleanup
    expectError "preparation_cancellation_pending" (signing generation)
    Preparation.finishCancellation ledger prepared
    finished <- state ledger JournalState
    Preparation.finishCancellation ledger prepared
    state ledger JournalState >>= \replayed->require (replayed==finished) "completed_cancellation_replay_changed_journal"
    (_,retained,_,_) <- state ledger SendState
    require (held==retained) "unsigned_cancellation_released_fee_hold"
    expectError "preparation_not_found" (signing generation)
    state ledger (ReadyAt 100)
    Preparation.begin ledger cfg ob "Solana" 10000 "{\"contract\":true}"
    nextGeneration <- Preparation.active ledger (obligationId ob)
    require (nextGeneration==generation+1) "cancelled_generation_reused"
    expectError "preparation_generation_changed" (signing generation)
    Preparation.storeDraft ledger (obligationId ob) "{}" nextGeneration
    Preparation.storeAttempt ledger ob "Solana" txid "original-contract-bytes" "{}" 10000 Nothing nextGeneration
    expectError "preparation_not_unsigned" $ L.ledgerAction ledger $ \c->
      Preparation.signingDecisionC c cfg (obligationId ob) nextGeneration
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

-- Database-only scanner observations, not a live-chain acceptance claim.
-- Reuse the production scanner, allocation, quote and spend transactions.
treasuryContracts :: PG.ConnectInfo -> IO ()
treasuryContracts settings = do
  base <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
  let quantity n=either (error . T.unpack) id (amount n)
      cfg=base{maxQueued=100,maxSolAccountRent=quantity 0,
        maxNativeDailyCost=quantity 1000000,maxSolDailyCost=quantity 1000000}
      state ledger operation=L.ledgerAction ledger (\connection->fixture connection operation)
      scan ledger chain deposits events=do
        previous <- Observation.readCheckpoint ledger chain
        Observation.commitScan ledger (ScanBatch chain "treasury-contract" previous "treasury-cursor" 100 deposits events)
      review ledger=state ledger (ReadyAt 100) >> L.pause ledger "treasury contract"
      refuse ledger code did split=do
        before <- (,) <$> state ledger JournalState <*> state ledger ReceiptState
        expectError code (Treasury.allocate ledger 100 did split "operator capital")
        after <- (,) <$> state ledger JournalState <*> state ledger ReceiptState
        require (before==after) "rejected_treasury_allocation_changed_records"
      reason="dedicated database contract: operator-owned outflow"
      spend ledger chain txid=Treasury.classifySpend ledger chain txid reason
      checkReview ledger chain txid expected=do
        (_,events) <- state ledger TreasuryState
        require ([chaineventsNeedsReview e | e<-events,chaineventsChain e==chain,chaineventsEventId e==txid]==[expected]) "treasury_review_wrong"
  L.withLedger settings "journal-contract" $ \ledger->do
    -- Replace the retired standalone treasury runner's raw-SQL fixture with
    -- the same closed scanner and allocation operations used by the worker.
    tokenCursor <- Observation.readCheckpoint ledger "Solana"
    scan ledger "SolanaOperating"
      [Deposit "sol-operating:treasury-fund" Nothing Sol (quantity 10000) "slot" 1 True 100]
      [ChainEvent "treasury-fund" "unmatched_incoming" "slot" (object["delta" .= ("10000"::T.Text),"failed" .= False])]
    tokenCursorAfter <- Observation.readCheckpoint ledger "Solana"
    require (tokenCursor==tokenCursorAfter) "sol_operating_scan_moved_token_cursor"
    let wrongAsset=Deposit "sol-operating:wrong-stream" Nothing Native (quantity 10000) "slot" 1 True 100
    current <- Observation.readCheckpoint ledger "SolanaOperating"
    expectError "scan_asset_mismatch" (Observation.commitScan ledger (ScanBatch "SolanaOperating" "treasury-contract" current "wrong" 100 [wrongAsset] []))
    L.pause ledger "treasury contract"
    let allocate split owner=Treasury.allocate ledger 100 "sol-operating:treasury-fund" split owner
    expectError "custody_not_reconciled" (allocate [("operating",quantity 10000)] "operator capital")
    state ledger (ReadyAt 100)
    L.pause ledger "treasury contract"
    expectError "sol_reserved_for_operating" (allocate [("float",quantity 10000)] "operator capital")
    allocated <- allocate [("operating",quantity 10000)] "operator capital"
    allocatedJournal <- state ledger JournalState
    replay <- allocate [("operating",quantity 10000)] "operator capital"
    replayedJournal <- state ledger JournalState
    require (allocated==replay && allocatedJournal==replayedJournal) "treasury_allocation_replay_mutated_journal"
    expectError "treasury_allocation_conflict" (allocate [("operating",quantity 10000)] "different owner")

    review ledger
    refuse ledger "receipt_not_available_for_treasury" "contract-deposit:0" [("float",quantity 100000)]
    -- An eligible deposit is insufficient without accepted, matching scanner
    -- evidence. Failed/reviewed/unconfirmed receipts cannot fund the operator.
    forM_ [("no-proof","unmatched_incoming",True,False,False,"verified_treasury_receipt_required"),
           ("failed","unmatched_incoming",True,True,True,"verified_treasury_receipt_required"),
           ("review","unclassified",True,False,True,"verified_treasury_receipt_required"),
           ("unconfirmed","awaiting_verifier",False,False,True,"receipt_not_available_for_treasury")] $
      \(ident,kind,eligible,failed,observed,code)->do
        let did="sol-operating:"<>ident
            receipt=Deposit did Nothing Sol (quantity 10000) "slot" 1 eligible 100
            event=ChainEvent ident kind "slot" (object["delta" .= ("10000"::T.Text),"failed" .= failed])
        scan ledger "SolanaOperating" [receipt] (if observed then [event] else [])
        review ledger
        refuse ledger code did [("operating",quantity 10000)]
    forM_ [(Native,"Native"),(Wrapped,"Solana")] $ \(asset,chain)->do
      let ident="wrong-"<>T.pack(show asset); did="sol-operating:"<>ident
      scan ledger chain [Deposit did Nothing asset (quantity 10000) "block" 1 True 100] []
      review ledger
      refuse ledger "invalid_treasury_receipt_id" did [("operating",quantity 10000)]

    let nativeId="native:treasury-native:0"
        nativeReceipt=Deposit nativeId Nothing Native (quantity 1000) "database-funding" 1 True 100
        nativeProof=object["receipts" .= [object["id" .= nativeId,"amount" .= quantity 1000,
          "order" .= (Nothing::Maybe T.Text),"eligible" .= True]]]
    scan ledger "Native" [nativeReceipt] [ChainEvent "treasury-native" "incoming" "database-funding" nativeProof]
    review ledger
    refuse ledger "treasury_allocation_amount_mismatch" nativeId [("float",quantity 1001)]
    capitalBefore <- L.ledgerAction ledger L.balances
    let split=[("float",quantity 900),("operating",quantity 100)]
    capital <- Treasury.allocate ledger 100 nativeId split "operator capital"
    capitalAfter <- L.ledgerAction ledger L.balances
    require (capitalAfter==M.adjust (+900) ("Native","float")
      (M.adjust (+100) ("Native","operating") (M.adjust (subtract 1000) ("Native","unallocated") capitalBefore))) "treasury_allocation_credited_asset_twice"
    savedCapital <- (,) <$> state ledger JournalState <*> state ledger ReceiptState
    capitalRetry <- Treasury.allocate ledger 100 nativeId (reverse split) "operator capital"
    repeatedCapital <- (,) <$> state ledger JournalState <*> state ledger ReceiptState
    require (capital==capitalRetry && savedCapital==repeatedCapital) "treasury_split_reordering_changed_allocation"
    refuse ledger "treasury_allocation_conflict" nativeId [("float",quantity 1000)]

    -- Separate customer attempts, provisional quote holds and transferred
    -- fee holds from operator funds, even while the worker is paused.
    state ledger (ReadyAt 100)
    let request=OrderRequest NativeToWrapped (quantity 10000) "destination" "refund" Nothing "treasury-reserved"
    (_,priorSol) <- state ledger OperatingFunds
    priorWrapped <- state ledger (Inventory Wrapped)
    _ <- Order.createOrder ledger cfg 100 (T.replicate 64 "d") request
    (_,quotedSol) <- state ledger OperatingFunds
    require (priorSol-quotedSol==10000) "treasury_contract_quote_cost_not_held"
    scan ledger "SolanaOperating" [] [ChainEvent "quote-spend" "outgoing" "slot"
      (object["delta" .= T.pack(show $ negate priorSol),"feeUnits" .= quantity 5000])]
    expectError "treasury_spend_exceeds_free_allocation" (spend ledger "SolanaOperating" "quote-spend")
    scan ledger "Solana" [] [ChainEvent "float-spend" "outgoing" "slot"
      (object["delta" .= T.pack(show $ negate priorWrapped)])]
    expectError "treasury_spend_exceeds_free_allocation" (spend ledger "Solana" "float-spend")
    Order.expireQuotes ledger 100000
    (_,reservedSol) <- state ledger OperatingFunds
    scan ledger "SolanaOperating" [] [ChainEvent "reserved-spend" "outgoing" "slot"
      (object["delta" .= T.pack(show $ negate $ reservedSol+1),"feeUnits" .= quantity 5000])]
    expectError "treasury_spend_exceeds_free_allocation" (spend ledger "SolanaOperating" "reserved-spend")
    let customerId="contract-send-write-failure"
    scan ledger "Solana" [] [ChainEvent customerId "outgoing" "slot" (object["delta" .= ("-99000"::T.Text)])]
    checkReview ledger "Solana" customerId 1
    scan ledger "SolanaOperating" [] [ChainEvent customerId "outgoing" "slot"
      (object["delta" .= ("-5000"::T.Text),"feeUnits" .= quantity 5000])]
    checkReview ledger "SolanaOperating" customerId 1
    expectError "customer_attempt_cannot_be_treasury_spend" (spend ledger "Solana" customerId)
    expectError "customer_attempt_cannot_be_treasury_spend" (spend ledger "SolanaOperating" customerId)
    readiness <- L.readiness ledger
    require (not $ available readiness) "premature_customer_observation_did_not_pause"

    let economic=object["walletNetUnits" .= ("-100"::T.Text),"feeUnits" .= quantity 2,"confirmations" .= (1::Int)]
        event=ChainEvent "operator-payment" "outgoing" "database-block" economic
    scan ledger "Native" [] [event]
    expectError "treasury_spend_not_observed" (spend ledger "Native" "unknown")
    expectError "invalid_treasury_spend_attestation" (Treasury.classifySpend ledger "Native" "operator-payment" " ")
    -- Stored evidence alone does not authorize an operator mutation in live mode.
    state ledger (ReadyAt 100)
    expectError "treasury_spend_requires_pause" (spend ledger "Native" "operator-payment")
    L.pause ledger "operator outflow review"
    balances <- L.ledgerAction ledger L.balances
    decision <- spend ledger "Native" "operator-payment"
    afterBalances <- L.ledgerAction ledger L.balances
    let expected=M.adjust (subtract 100) ("Native","float") $
          M.adjust (subtract 2) ("Native","operating") $
          M.adjust (+102) ("Native","external") balances
    require (afterBalances==expected) "treasury_outflow_not_balanced_or_fee_wrong"
    (savedSpends,_) <- state ledger TreasuryState
    savedSpend <- case savedSpends of [row]->pure row; _->reject "treasury_spend_record_missing_or_duplicated"
    savedProof <- either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ treasuryspendsProofJson savedSpend)
    savedOwner <- fieldValue "ownershipAttestation" savedProof
    savedObservation <- fieldValue "observation" savedProof
    savedAnchor <- fieldValue "anchor" savedObservation
    require (savedOwner==reason && savedAnchor==("database-block"::T.Text)) "treasury_saved_proof_not_bound"
    beforeReplay <- state ledger JournalState
    repeated <- spend ledger "Native" "operator-payment"
    afterReplay <- state ledger JournalState
    require (decision==repeated && beforeReplay==afterReplay) "treasury_spend_replay_mutated_journal"
    checkReview ledger "Native" "operator-payment" 0
    -- This decision must not clear the other stream's outstanding review.
    checkReview ledger "SolanaOperating" "reserved-spend" 1
    expectError "treasury_spend_conflict" (Treasury.classifySpend ledger "Native" "operator-payment" "changed owner")
    scan ledger "Native" [] [event{chainEventEvidence=object["walletNetUnits" .= ("-100"::T.Text),"feeUnits" .= quantity 2,"confirmations" .= (2::Int)]}]
    checkReview ledger "Native" "operator-payment" 0
    scan ledger "Native" [] [event{chainEventAnchor="different-block"}]
    checkReview ledger "Native" "operator-payment" 1
    expectError "treasury_spend_conflict" (spend ledger "Native" "operator-payment")
    -- Token principal comes from float; a SOL wallet outflow (including its
    -- fee) comes wholly from operating. Neither can touch another allocation.
    forM_ [("Solana",Wrapped,"float","token-operator",object["delta" .= ("-100"::T.Text)]),
           ("SolanaOperating",Sol,"operating","sol-operator",object["delta" .= ("-100"::T.Text),"feeUnits" .= quantity 2])] $
      \(chain,asset,account,txid,proof)->do
        scan ledger chain [] [ChainEvent txid "outgoing" "slot" proof]
        before <- L.ledgerAction ledger L.balances
        _ <- spend ledger chain txid
        after <- L.ledgerAction ledger L.balances
        require (after==M.adjust (subtract 100) (T.pack(show asset),account)
          (M.adjust (+100) (T.pack(show asset),"external") before)) "treasury_stream_debited_wrong_allocation"
        checkReview ledger chain txid 0
  -- Saved decisions, bytes and reservations survive reconnect. Conflicting
  -- observed anchors still refuse replay after restart.
  L.withLedger settings "journal-contract" $ \ledger->do
    before <- (,) <$> state ledger JournalState <*> state ledger ReceiptState
    _ <- Treasury.allocate ledger 100 "sol-operating:treasury-fund" [("operating",quantity 10000)] "operator capital"
    _ <- Treasury.allocate ledger 100 "native:treasury-native:0" [("operating",quantity 100),("float",quantity 900)] "operator capital"
    after <- (,) <$> state ledger JournalState <*> state ledger ReceiptState
    require (before==after) "treasury_allocation_replay_changed_reopened_ledger"
    expectError "treasury_spend_conflict" (spend ledger "Native" "operator-payment")
    (spends,events) <- state ledger TreasuryState
    require (length spends==3) "treasury_decisions_lost_on_restart"
    require (any (\e->chaineventsEventId e=="operator-payment" && chaineventsNeedsReview e==1) events) "treasury_review_lost_on_restart"

-- Receipt/page contracts on the production PostgreSQL observer store.
observerContracts :: PG.ConnectInfo -> IO ()
observerContracts settings = do
  base <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
  let quantity n=either (error . T.unpack) id (amount n)
      cfg=base{maxQueued=100,maxSolAccountRent=quantity 0,
        maxNativeDailyCost=quantity 1000000,maxSolDailyCost=quantity 1000000}
      state ledger operation=L.ledgerAction ledger (\connection->fixture connection operation)
      snapshot ledger=(,,) <$> state ledger JournalState <*> state ledger ReceiptState <*> state ledger ScanState
      rejected ledger code action=do
        before <- snapshot ledger
        expectError code action
        after <- snapshot ledger
        require (before==after) "rejected_scan_published_partial_page"
      request=OrderRequest NativeToWrapped (quantity 10000) "destination" "refund" Nothing "observer-depth"
      cap=T.replicate 64 "e"
  originalEvidence <- L.withLedger settings "journal-contract" $ \ledger->do
    state ledger (ReadyAt 100)
    order <- Order.createOrder ledger cfg{nativeConfirmations=6} 100 cap request
    previous <- Observation.readCheckpoint ledger "Native"
    let receipt=Deposit "observer-shallow:0" (Just $ ordersId order) Native (quantity 10000) "block" 1 True 100
    rejected ledger "deposit_confirmation_policy_mismatch"
      (Observation.recordScan ledger "Native" previous "observer-native" [receipt])
    Observation.recordScan ledger "Native" previous "observer-native" [receipt{depositConfirmations=6}]
    candidates <- Observation.promotionCandidates ledger
    require (depositId receipt `elem` candidates) "eligible_receipt_missing_from_promotion"
    rejected ledger "conflicting_deposit_evidence" (Observation.recordScan ledger "Native" (Just "observer-native") "invalid-page"
      [receipt{depositId="must-not-commit:0",depositConfirmations=6},receipt{depositAmount=quantity 1,depositConfirmations=6}])
    rejected ledger "stale_scan_cursor" (Observation.recordScan ledger "Native" previous "stale" [])
    accepted <- Observation.promoteDeposit ledger 110 (depositId receipt)
    require accepted "saved_confirmation_depth_not_promoted"

    beforeFloat <- state ledger (Inventory Native)
    let unknown=Deposit "observer-unbound:0" Nothing Native (quantity 50000) "block" 1 True 100
    Observation.recordScan ledger "Native" (Just "observer-native") "unbound" [unknown]
    booked <- L.ledgerAction ledger L.balances
    Observation.recordScan ledger "Native" (Just "unbound") "unbound-replay" [unknown]
    replayed <- L.ledgerAction ledger L.balances
    afterFloat <- state ledger (Inventory Native)
    require (booked==replayed && beforeFloat==afterFloat) "unbound_receipt_became_float_or_replayed"
    promoted <- Observation.promoteDeposit ledger 110 (depositId unknown)
    require (not promoted) "unbound_receipt_created_obligation"
    candidatesAfter <- Observation.promotionCandidates ledger
    require (all (`notElem` candidatesAfter) [depositId receipt,depositId unknown]) "allocated_or_unbound_receipt_queued"
    expectError "refundable_deposit_not_found" (Settlement.createRefund ledger $ depositId unknown)
    rejected ledger "conflicting_deposit_evidence" (Observation.recordScan ledger "Native" (Just "unbound-replay") "rebound"
      [unknown{depositOrder=Just $ ordersId order,depositConfirmations=6}])

    let event=ChainEvent "observer-unbound" "unmatched_incoming" "block" (object["amount" .= ("50000"::T.Text)])
        batch=ScanBatch "Native" "treasury-contract" (Just "unbound-replay") "evidence" 100 [unknown] [event]
    Observation.commitScan ledger batch
    (_,_,proofsBefore,_,_) <- state ledger ScanState
    Observation.commitScan ledger batch{scanPrevious=Just "evidence",scanNext="evidence-replay",scanTime=110}
    (_,_,proofsAfter,_,_) <- state ledger ScanState
    require (proofsBefore==proofsAfter) "scan_replay_duplicated_evidence"
    rejected ledger "scan_origin_mismatch"
      (Observation.commitScan ledger batch{scanPrevious=Just "evidence-replay",scanOrigin="changed",scanNext="invalid-origin"})
    Observation.recordScanFailure ledger "Native" 120 "rpc_transport_unknown_outcome"
    Observation.recordScanFailure ledger "Native" 130 "rpc_transport_unknown_outcome"
    cursor <- Observation.readCheckpoint ledger "Native"
    (_,health,_,_,audits) <- state ledger ScanState
    require (cursor==Just "evidence-replay" &&
      [(scanhealthLastSuccess r,scanhealthCheckedAt r) | r<-health,scanhealthChain r=="Native"]==[(Just 110,130)] &&
      length [r | r<-audits,auditAction r=="scanner_failure",auditDetail r=="Native:rpc_transport_unknown_outcome"]==1)
      "scan_failure_moved_cursor_or_repeated_alert"

    state ledger (ReadyAt 100)
    redeem <- Order.createOrder ledger cfg 100 cap
      request{direction=WrappedToNative,recipient="native-destination",refund="",idempotencyKey="observer-pending"}
    Order.bindInstruction ledger (ordersId redeem) "solana-pay:observer-reference"
    binding <- Observation.lookupReferences ledger ["unrelated","observer-reference"]
    require (case binding of Just(oid,_,_,reference)->oid==ordersId redeem && reference=="observer-reference"; _->False)
      "reference_not_bound_to_saved_order"
    Observation.lookupReferences ledger ["unrelated"] >>= \unmatched->require (unmatched==Nothing) "unmatched_reference_bound"
    tokenCursor <- Observation.readCheckpoint ledger "Solana"
    let pending=Deposit "solana:observer-pending" (Just $ ordersId redeem) Wrapped (quantity 10000) "slot" 1 False 390
        waiting=ChainEvent "observer-pending" "awaiting_verifier" "slot" Null
        tokenBatch=ScanBatch "Solana" "treasury-contract" tokenCursor "observer-pending" 391 [pending] [waiting]
    Observation.commitScan ledger tokenBatch
    queue <- Observation.pendingVerification ledger
    require (queue==["observer-pending"]) "pending_verification_not_retained"
    immature <- Observation.promoteDeposit ledger 391 (depositId pending)
    require (not immature) "unverified_deposit_promoted"
    Observation.commitScan ledger tokenBatch{scanPrevious=Just "observer-pending",scanTime=450,
      scanDeposits=[pending{depositEligible=True,depositSeenAt=450}],scanEvents=[waiting{chainEventKind="incoming"}]}
    remaining <- Observation.pendingVerification ledger
    matured <- Observation.promoteDeposit ledger 450 (depositId pending)
    (deposits,_) <- state ledger ReceiptState
    require (null remaining && matured &&
      [depositsFirstSeen r | r<-deposits,depositsId r==depositId pending]==[390]) "verification_changed_first_seen_or_missed_grace"
    (_,_,evidence,_,_) <- state ledger ScanState
    tamper <- try (state ledger FailEvidence) :: IO (Either PG.SqlError ())
    require (case tamper of Left err->PG.sqlState err=="23514"; _->False) "immutable_observation_changed"
    expectFenced (state ledger ScanState)
    pure evidence
  L.withLedger settings "journal-contract" $ \ledger->do
    (_,_,reopenedEvidence,_,_) <- state ledger ScanState
    require (originalEvidence==reopenedEvidence) "failed_evidence_write_survived_restart"

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
