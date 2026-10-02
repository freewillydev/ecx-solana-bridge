module Bridge.Postgres.PaymentStore
  ( pendingAttempts, paymentObligation, paymentSourceContext, paymentNativeFamily, settlementWinner, settlementReady, settlementBusy, settlementCoveredSource, custodyView, custodyRevision, custodyHasEvent, nativeLockAudit ) where

import Bridge.Types
import qualified Bridge.Postgres.Source as Source
import Bridge.Config (Config)
import Bridge.Ledger.Model
import qualified Bridge.Postgres.Custody as C
import Data.Int (Int64)
import qualified Bridge.Postgres.NativeFamily as NativeFamily
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Data.Aeson (FromJSON,eitherDecodeStrict')
import Data.List (sortOn,nub)
import Control.Monad (forM)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Opaleye as O


paymentObligation :: Ledger -> Text -> IO Obligation
paymentObligation ledger oid = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable obligationsTable
    O.where_ (obligationsId row O..== O.sqlStrictText oid)
    pure row
    :: IO [Obligations]
  case rows of [row]->pure (obligation row); _->reject "obligation_not_found"
paymentSourceContext :: Ledger -> Obligation -> IO (Deposit,OrderRequest,PolicySnapshot,Text)
paymentSourceContext ledger expected = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    ob <- O.selectTable obligationsTable
    order <- O.selectTable ordersTable
    deposit <- O.selectTable depositsTable
    O.where_ (obligationsId ob O..== O.sqlStrictText (obligationId expected) O..&&
      obligationsOrderId ob O..== ordersId order O..&& obligationsDepositId ob O..== depositsId deposit)
    pure (ob,order,deposit)
    :: IO [(Obligations,Orders,Deposits)]
  (ob,order,deposit) <- case rows of [row]->pure row; _->reject "source_deposit_missing"
  require (obligation ob==expected) "obligation_mismatch"
  request <- stored (ordersRequestJson order)
  policy <- stored (ordersPolicyJson order)
  instruction <- maybe (reject "source_instruction_missing") pure (ordersInstruction order)
  let asset=sourceAsset (direction request)
  require (depositsOrderId deposit==Just (obligationOrder expected) && depositsAsset deposit==T.pack(show asset)) "source_binding_mismatch"
  quantity <- either reject pure (amount $ toInteger $ depositsAmount deposit)
  require (depositsConfirmations deposit>=0 && toInteger (depositsConfirmations deposit)<=toInteger(maxBound::Int)) "source_depth_overflow"
  pure (Deposit (depositsId deposit) (depositsOrderId deposit) asset quantity (depositsAnchor deposit)
    (fromIntegral $ depositsConfirmations deposit) (depositsEligible deposit==1) (depositsFirstSeen deposit),request,policy,instruction)
paymentNativeFamily :: Ledger -> Text -> IO [Attempt]
paymentNativeFamily ledger intent = ledgerAction ledger $ \connection->NativeFamily.familyC connection intent

pendingAttempts :: Ledger -> IO [Attempt]
pendingAttempts ledger = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_ (attemptsIntentId a O..== intentsId i O..&& intentsResolved i O..== O.sqlInt8 0)
    pure (a,intentsChain i)
    :: IO [(Attempts,Text)]
  expired <- O.runSelect connection (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
  native <- fmap concat $ forM (nub [attemptsIntentId a | (a,chain)<-rows,chain=="Native"]) (NativeFamily.familyC connection)
  -- A newly signed replacement has no broadcast sequence yet. Sorting on that
  -- nullable field puts it before its parent; lineage readers require fee order.
  -- Use the same verified family order as signing, settlement and recovery.
  pure $ native <> [attempt a chain | (a,chain)<-sortOn (\(a,_)->(attemptsPreparationGeneration a,attemptsCriticalSequence a,attemptsTxid a)) rows,chain/="Native",not(any ((==attemptsTxid a).solanaexpiriesTxid) expired)]

obligation :: Obligations -> Obligation
obligation row = Obligation (obligationsId row) (obligationsOrderId row) (obligationsDepositId row) (obligationsKind row) (obligationsAsset row) (obligationsAmount row) (obligationsRecipient row)
attempt :: Attempts -> Text -> Attempt
attempt row chain = Attempt (attemptsTxid row) (attemptsIntentId row) chain (attemptsSignedBytes row) (attemptsPolicyJson row) (attemptsFeeLimit row) (attemptsState row) (attemptsCriticalSequence row)
stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8

custodyView :: Config -> Ledger -> Int64 -> Bool -> IO View
custodyView cfg ledger now losses = do
  snapshot <- C.readSnapshot cfg ledger now losses
  pure (View (C.revision snapshot) (C.totals snapshot) (C.heads snapshot) (C.slot snapshot))
custodyRevision :: Ledger -> IO Int64
custodyRevision ledger = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection (fmap custodycheckRevision $ O.selectTable custodycheckTable) :: IO [Int64]
  case rows of [revision]->pure revision; _->reject "custody_check_missing"
custodyHasEvent :: Ledger -> Text -> Text -> IO Bool
custodyHasEvent ledger txid chain = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable chaineventsTable
    O.where_ (chaineventsEventId row O..== O.sqlStrictText txid O..&&
      (chaineventsChain row O..== O.sqlStrictText chain O..|| chaineventsChain row O..== O.sqlStrictText (if chain=="Solana" then "SolanaOperating" else "Native")))
    pure (chaineventsEventId row)
    :: IO [Text]
  pure (not $ null rows)



settlementWinner :: Ledger -> Text -> IO Text
settlementWinner ledger intent = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable attemptsTable
    O.where_(attemptsIntentId row O..== O.sqlStrictText intent O..&& attemptsState row O..== O.sqlStrictText "settled")
    pure(attemptsTxid row)
    :: IO [Text]
  case rows of [winner]->pure winner; _->reject "settled_payment_missing"
settlementReady :: Ledger -> IO [Obligation]
settlementReady ledger = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ O.limit 100 $ do
    row <- O.selectTable obligationsTable
    O.where_ (obligationsStatus row O..== O.sqlStrictText "ready")
    pure row
    :: IO [Obligations]
  pure(map obligation rows)
settlementBusy :: Ledger -> Text -> IO Bool
settlementBusy ledger chain = ledgerAction ledger $ \c->do
  rows <- O.runSelect c $ do
    row <- O.selectTable intentsTable
    O.where_ (intentsChain row O..== O.sqlStrictText chain O..&& intentsResolved row O..== O.sqlInt8 0)
    pure(intentsId row)
    :: IO [Text]
  pure(not $ null rows)
settlementCoveredSource :: Ledger -> Obligation -> IO Bool
settlementCoveredSource ledger ob = Source.coveredAuthorized ledger (obligationId ob)


nativeLockAudit :: Ledger -> Text -> IO ()
nativeLockAudit ledger subject = ledgerAction ledger $ \connection->do
  _ <- O.runInsert connection O.Insert
    {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "native_locks_restored") (O.sqlStrictText subject)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  pure ()
