{-# LANGUAGE ScopedTypeVariables #-}
-- Implementation of StoreSetup's closed, offline payment-root conversion.
-- No handler receives a connection, query callback or staged-schema evaluator.
module Bridge.Store.Migration (migratePaymentRoots) where

import Bridge.Domain
import Bridge.Error
import Bridge.Lifecycle (PaymentPhase(..),encodePaymentPhase,decodePaymentPhase)
import qualified Bridge.Wire as W
import qualified Bridge.Store.Schema as S
import qualified Bridge.Store.Projection as P
import Bridge.Store.Catalog (claimWorker)
import Bridge.Store.Backup (loadLedgerArchive,archiveSequence)
import Paths_ecx_bridge (getDataFileName)
import Control.Exception (bracket)
import Control.Monad (forM_,void)
import Data.Aeson (FromJSON,eitherDecodeStrict')
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Profunctor.Product (p2)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types (Query(..))
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import qualified Opaleye as O
import qualified Opaleye.Internal.Locking as Locking
import Opaleye.Internal.Column (Field_(Column),unColumn)
import qualified Opaleye.Internal.HaskellDB.PrimQuery as Expr

-- The verified archive must cover this exact quiescent ledger sequence. The
-- caller must exclude the old signer/host; the DB lock excludes active writers.
migratePaymentRoots :: PG.ConnectInfo -> Text -> Int64 -> FilePath -> IO (Int64,Int)
migratePaymentRoots settings identity minimumSequence manifest = do
  archive<-loadLedgerArchive identity minimumSequence manifest
  stage<-ddl "009-stage.sql"
  activate<-ddl "009-activate.sql"
  bracket (PG.connect settings) PG.close $ \c->
    Tx.withTransactionMode (Tx.TransactionMode Tx.ReadCommitted Tx.ReadWrite) c $ do
      claimWorker c >>= flip require "worker_already_running"
      rows<-O.runSelect c $ Locking.forUpdate (O.selectTable S.deployment) :: IO [S.Deployment]
      original<-case rows of
        [row] | S.singleton row==1 && S.fingerprint row==identity && S.schemaVersion row==21 && S.paused row==1->pure row
        _->reject "payment_root_migration_requires_paused_schema21"
      require (S.criticalSequence original==archiveSequence archive) "migration_snapshot_sequence_mismatch"
      one "migration_stage_failed" $ O.runUpdate c O.Update {O.uTable=S.deployment,
        O.uUpdateWith= \row->row {S.schemaVersion=num 2200},O.uWhere= \row->S.singleton row O..== num 1,O.uReturning=O.rCount}
      void $ PG.execute_ c (Query stage)
      customers<-customerRoots c ""
      earned<-earnedRoots c identity ""
      void $ admissionRows c identity ""
      unmapped<-O.runSelect c $ O.limit 1 $ do
        root<-O.selectTable S.paymentRoots
        O.where_ (O.isNull $ O.toNullable $ S.rootPhase root)
        pure (S.rootId root)
        :: IO [Text]
      require (null unmapped) "migration_unbound_payment_root"
      -- Compare the old customer's execution restriction before removing it.
      -- Unknown review is a refused conversion, never silently made ready.
      changed<-O.runSelect c $ O.limit 1 $ do
        ob<-O.selectTable S.obligations
        (root,state)<-P.paymentStates
        O.where_ (S.rootId root O..== S.obligationId ob O..&& state O../= S.obligationStatus ob)
        pure (S.obligationId ob)
        :: IO [Text]
      require (null changed) "migration_execution_state_not_proven"
      void $ PG.execute_ c (Query activate)
      -- New constraint triggers do not visit rows written before their creation.
      -- Explicitly validate every backfilled root through the same fixed check.
      validateRoots c ""
      -- Force all deferred root/FK checks before activation. No external action
      -- or checkpoint occurs within this transaction.
      void $ PG.execute_ c "SET CONSTRAINTS ALL IMMEDIATE"
      one "migration_activation_failed" $ O.runUpdate c O.Update {O.uTable=S.deployment,
        O.uUpdateWith= \row->row {S.schemaVersion=num 22,S.pauseReason=text "payment_root_migration_requires_reconciliation"},
        O.uWhere= \row->S.singleton row O..== num 1 O..&& S.schemaVersion row O..== num 2200,O.uReturning=O.rCount}
      pure (S.criticalSequence original,customers+earned)
 where
  ddl name=getDataFileName ("migrations/"<>name) >>= BS.readFile

-- Pages bound memory while the exclusive transaction keeps the source stable.
customerRoots :: PG.Connection -> Text -> IO Int
customerRoots c after = do
  rows<-O.runSelect c $ O.limit 1000 $ O.orderBy (O.asc S.obligationId) $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationId row O..> text after)
    pure row
    :: IO [S.Obligation]
  forM_ rows $ \ob->do
    require (S.obligationStatus ob `elem` ["ready","paying","paid","review","cancelled"]) "migration_unknown_payment_state"
    funding<-O.runSelect c $ do
      order<-O.selectTable S.orders
      source<-O.selectTable S.deposits
      O.where_ (S.orderId order O..== text(S.obligationOrder ob) O..&& S.depositId source O..== text(S.obligationDeposit ob))
      pure (S.requestJson order,S.quoteJson order,source)
      :: IO [(Text,Text,S.Deposit)]
    (requestJson,quoteJson,source)<-case funding of [row]->pure row; _->reject "migration_customer_funding_missing"
    request<-decode requestJson :: IO W.OrderRequest
    savedQuote<-decode quoteJson :: IO Quote
    require (S.depositOrder source==Just(S.obligationOrder ob) && S.depositAllocated source==1
      && W.input request==gross savedQuote) "migration_receipt_binding_invalid"
    let (incoming,outgoing)=case W.direction request of NativeToWrapped->("Native","Wrapped"); WrappedToNative->("Wrapped","Native")
    require (case S.obligationKind ob of
      "conversion"->S.depositAsset source==incoming && S.depositAmount source==units(gross savedQuote)
        && S.obligationAsset ob==outgoing && S.obligationAmount ob==units(net savedQuote) && S.obligationRecipient ob==W.recipient request
      "refund"->S.obligationAsset ob==S.depositAsset source && S.obligationAmount ob==S.depositAmount source
      _->False) "migration_customer_terms_mismatch"
    let key=S.obligationId ob
    root<-convertedRoot c key (Just key) Nothing (Just $ S.obligationDeposit ob) (S.obligationAsset ob) (S.obligationStatus ob=="cancelled")
    economic<-phase root
    require (case (S.obligationStatus ob,economic) of
      ("paid",Settled{})->True; ("cancelled",Cancelled)->True
      ("paying",Active{})->True; ("ready",Ready)->True
      ("review",Ready)->True; ("review",Active{})->True; _->False) "migration_economic_state_not_proven"
    saveRoot c root
  case reverse rows of
    row:_ | length rows==1000->(length rows+) <$> customerRoots c (S.obligationId row)
    _->pure(length rows)

earnedRoots :: PG.Connection -> Text -> Text -> IO Int
earnedRoots c identity after = do
  rows<-O.runSelect c $ O.limit 1000 $ O.orderBy (O.asc S.withdrawalId) $ do
    row<-O.selectTable S.withdrawals
    O.where_ (S.withdrawalId row O..> text after)
    pure row
    :: IO [S.Withdrawal]
  forM_ rows $ \saved->do
    let key=S.withdrawalId saved
    policy<-decode (S.terms saved) :: IO W.PaymentTerms
    require (W.deploymentFingerprint (W.paymentPolicy policy)==identity && S.quantity saved>0) "migration_invalid_withdrawal_terms"
    cancelled<-O.runSelect c $ do
      (identifier,_,_)<-O.selectTable S.cancellations
      O.where_ (identifier O..== text key)
      pure identifier
      :: IO [Text]
    require (length cancelled<=1) "migration_ambiguous_cancellation"
    root<-convertedRoot c ("fee:"<>key) Nothing (Just key) Nothing (S.asset saved) (not $ null cancelled)
    saveRoot c root
  case reverse rows of
    row:_ | length rows==1000->(length rows+) <$> earnedRoots c identity (S.withdrawalId row)
    _->pure(length rows)

-- This classifies economic ownership only. Source/retry restrictions are checked
-- independently above; final FKs/triggers check the full preparation/winner binding.
convertedRoot :: PG.Connection -> Text -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> Bool -> IO S.PaymentRoot
convertedRoot c key obligation withdrawal receipt asset cancelled = do
  chain<-case asset of "Native"->pure "Native"; "Wrapped"->pure "Solana"; _->reject "migration_invalid_payment_asset"
  prior<-O.runSelect c $ O.limit 2 $ do
    row<-O.selectTable S.intents
    O.where_ (S.intentId row O..== text key)
    pure row
    :: IO [S.Intent]
  forM_ prior $ \row->require (S.intentObligation row==obligation && S.intentWithdrawal row==withdrawal
    && S.intentChain row==chain && S.intentResolved row `elem` [0,1]) "migration_funding_changed"
  require (length prior<=1) "migration_ambiguous_payment"
  generations<-O.runSelect c $ O.limit 9 $ O.orderBy (O.asc $ \(g,_,_)->g) $ do
    (identifier,g,_,_,retired,stopped)<-S.workPreparations
    O.where_ (identifier O..== text key)
    pure (g,retired,stopped)
    :: IO [(Int64,Maybe Text,Int64)]
  require (length generations<=8 && map (\(g,_,_)->g) generations==[0..fromIntegral(length generations)-1]) "migration_generation_history_invalid"
  require ((null prior)==null generations) "migration_intent_history_missing"
  winners<-O.runSelect c $ O.limit 2 $ do
    attempt<-O.selectTable S.attempts
    O.where_ (S.attemptIntent attempt O..== text key O..&& S.attemptState attempt O..== text "settled")
    pure (S.attemptId attempt)
    :: IO [Text]
  events<-O.runSelect c $ O.limit 2 $ do
    attempt<-O.selectTable S.attempts
    (event,_)<-O.selectTable S.events
    O.where_ (S.attemptIntent attempt O..== text key O..&& event O..== (text "settlement:" O..++ S.attemptId attempt))
    pure event
    :: IO [Text]
  let unresolved=case prior of [row]->S.intentResolved row==0; _->False
      active=[g | (g,Nothing,0)<-generations]
  economic<-case (cancelled,unresolved,winners,events,active) of
    (True,False,[],[],_)->pure Cancelled
    (False,False,[winner],[event],_)->pure(Settled winner event)
    (False,True,[],[],[generation]) | generation==fromIntegral(length generations)-1->pure(Active $ fromIntegral generation)
    (False,False,[],[],_)->pure Ready
    _->reject "migration_settlement_or_phase_ambiguous"
  -- These are precisely the old intent fields included in approval hashes.
  -- Newly materialized ready roots with no preparation contribute no hash row.
  let resolved=case economic of Active{}->False; _->True
  require (case prior of []->economic `elem` [Ready,Cancelled]; [row]->resolved==(S.intentResolved row==1); _->False)
    "migration_work_hash_preimage_changed"
  let (state,generation,winner,event)=encodePaymentPhase economic
      common=case prior of [row]->S.intentCommon row; _->Nothing
      result=S.PaymentRoot key obligation withdrawal receipt chain common state generation winner event
  _<-either reject pure $ decodePaymentPhase (state,generation,winner,event)
  pure result

saveRoot :: PG.Connection -> S.PaymentRoot -> IO ()
saveRoot c row = do
  let fields=S.PaymentRoot (text $ S.rootId row) (nullable $ S.rootObligation row) (nullable $ S.rootWithdrawal row)
        (nullable $ S.rootDeposit row) (text $ S.rootChain row) (nullable $ S.rootCommon row) (text $ S.rootPhase row)
        (maybe O.null (O.toNullable.num) $ S.rootGeneration row) (nullable $ S.rootWinner row) (nullable $ S.rootSettlementEvent row)
  count<-O.runUpdate c O.Update {O.uTable=S.paymentRoots,O.uUpdateWith=const fields,
    O.uWhere= \current->S.rootId current O..== text(S.rootId row),O.uReturning=O.rCount}
  if count==0 then one "migration_root_insert_failed" $ O.runInsert c O.Insert
    {O.iTable=S.paymentRoots,O.iRows=[fields],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    else require (count==1) "migration_duplicate_root"

admissionRows :: PG.Connection -> Text -> Text -> IO Int
admissionRows c identity after = do
  rows<-O.runSelect c $ O.limit 1000 $ O.orderBy (O.asc S.orderId) $ do
    row<-O.selectTable S.orders
    O.where_ (S.orderId row O..> text after)
    pure row
    :: IO [S.Order]
  forM_ rows $ \row->do
    request<-decode (S.requestJson row) :: IO W.OrderRequest
    savedQuote<-decode (S.quoteJson row) :: IO Quote
    policy<-decode (S.policyJson row) :: IO W.PolicySnapshot
    require (W.input request==gross savedQuote && W.deploymentFingerprint policy==identity) "migration_invalid_order_terms"
    state<-case S.status row of
      saved | saved `elem` ["Provisioning","AwaitingDeposit","ExpiredUnfunded","NeedsReview"]->pure saved
      saved | saved `elem` ["Ready","Preparing","Paying","Refunding","Refunded","Paid"]->pure "AwaitingDeposit"
      _->reject "migration_unknown_order_state"
    one "migration_admission_update_failed" $ O.runUpdate c O.Update {O.uTable=admissions,
      O.uUpdateWith= \(key,_)->(key,text state),O.uWhere= \(key,_)->key O..== text(S.orderId row),O.uReturning=O.rCount}
  case reverse rows of
    row:_ | length rows==1000->(length rows+) <$> admissionRows c identity (S.orderId row)
    _->pure(length rows)
 where
  admissions=O.table "orders" $ p2 (O.requiredTableField "id",O.requiredTableField "admission_state")

validateRoots :: PG.Connection -> Text -> IO ()
validateRoots c after = do
  rows<-O.runSelect c $ O.limit 1000 $ O.orderBy (O.asc fst) $ do
    root<-O.selectTable S.paymentRoots
    O.where_ (S.rootId root O..> text after)
    pure (S.rootId root,Column (Expr.FunExpr "public.bridge_validate_payment" [unColumn $ S.rootId root]) :: O.Field O.SqlBool)
    :: IO [(Text,Bool)]
  require (all snd rows) "migration_payment_constraint_failed"
  case reverse rows of
    (key,_):_ | length rows==1000->validateRoots c key
    _->pure ()

phase :: S.PaymentRoot -> IO PaymentPhase
phase row=either reject pure $ decodePaymentPhase (S.rootPhase row,S.rootGeneration row,S.rootWinner row,S.rootSettlementEvent row)
text :: Text -> S.TextField
text=O.sqlStrictText
num :: Int64 -> S.IntField
num=O.sqlInt8
nullable :: Maybe Text -> O.FieldNullable O.SqlText
nullable=maybe O.null (O.toNullable.text)
decode :: FromJSON a => Text -> IO a
decode=either (const $ reject "migration_corrupt_saved_record") pure . eitherDecodeStrict' . TE.encodeUtf8
one :: Text -> IO Int64 -> IO ()
one message action=action >>= \count->require (count==1) message
