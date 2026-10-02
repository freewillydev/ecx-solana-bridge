module Bridge.Postgres.Cancellation (readCancellation,checkFresh,freshC,begin,finish) where
import Bridge.Types
import Bridge.Ledger.Model (Preparation(..),Obligation(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Bridge.Postgres.Custody (freshC)
import qualified Bridge.Postgres.Preparation as P
import Data.Aeson (Value(..),encode)
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Opaleye as O
import qualified Database.PostgreSQL.Simple as PG

rows :: PG.Connection -> Text -> Int -> IO [PreparationCancellations]
rows c intent generation = O.runSelect c $ do
  r <- O.selectTable preparationcancellationsTable
  O.where_(preparationcancellationsIntentId r O..== text intent O..&& preparationcancellationsGeneration r O..== num(fromIntegral generation))
  pure r
readCancellation :: Ledger -> Text -> Int -> IO (Maybe(Text,Text,Bool))
readCancellation ledger intent generation = ledgerAction ledger $ \c->do
  saved <- rows c intent generation :: IO [PreparationCancellations]
  case saved of
    []->pure Nothing
    [r]->pure(Just(preparationcancellationsReason r,preparationcancellationsCleanupJson r,preparationcancellationsCompleted r==1))
    _->reject "duplicate_preparation_cancellation"

checkFresh :: Ledger -> Int64 -> IO ()
checkFresh ledger now = ledgerAction ledger(\c->freshC c now)
paused :: PG.Connection -> IO ()
paused c = do
  state <- O.runSelect c(fmap deploymentPaused $ O.selectTable deploymentTable) :: IO [Int64]
  require(state==[1]) "pause_before_operator_action"

begin :: Ledger -> Preparation -> Int64 -> Text -> Value -> IO ()
begin ledger preparation now reason cleanup = ledgerAction ledger $ \c->do
  let intent=obligationId(preparationObligation preparation); generation=preparationGeneration preparation
      encoded=TE.decodeUtf8(LBS.toStrict $ encode cleanup)
  require(not(T.null $ T.strip reason) && T.length reason<=512 && cleanup/=Null && T.length encoded<=32768) "invalid_preparation_cancellation"
  paused c
  old <- rows c intent generation :: IO [PreparationCancellations]
  case old of
    [r]->require ((preparationcancellationsReason r,preparationcancellationsCleanupJson r)==(reason,encoded)) "preparation_cancellation_conflict"
    []->do
      freshC c now
      current <- P.pendingC c
      require(preparation `elem` current) "preparation_cancellation_not_expected"
      seqNo <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=preparationcancellationsTable,O.iRows=[PreparationCancellations (text intent) (num $ fromIntegral generation) (text reason) (text encoded) (num seqNo) (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      audit c "preparation_cancellation_requested" intent generation
    _->reject "duplicate_preparation_cancellation"

finish :: Ledger -> Preparation -> IO ()
finish ledger preparation = ledgerAction ledger $ \c->do
  let ob=preparationObligation preparation;intent=obligationId ob;generation=preparationGeneration preparation
  paused c
  saved <- rows c intent generation :: IO [PreparationCancellations]
  case map preparationcancellationsCompleted saved of
    [1]->pure ()
    [0]->do
      current <- P.pendingC c
      require(preparation `elem` current) "preparation_cancellation_not_expected"
      fees <- O.runSelect c $ do
        r <- O.selectTable feereservationsTable
        O.where_(feereservationsIntentId r O..== text intent)
        pure(feereservationsAmount r,feereservationsReleased r)
        :: IO [(Int64,Int64)]
      require(fees==[(preparationFeeLimit preparation,0)]) "preparation_fee_hold_missing"
      source <- O.runSelect c $ do
        r <- O.selectTable depositsTable
        O.where_(depositsId r O..== text(obligationDeposit ob))
        pure(depositsEligible r)
        :: IO [Int64]
      eligible <- case source of [r] | r `elem` [0,1]->pure(r==1);_->reject "deposit_not_found"
      _ <- criticalSequence c
      _ <- O.runUpdate c O.Update {O.uTable=preparationcancellationsTable,O.uUpdateWith= \r->r {preparationcancellationsCompleted=num 1},O.uWhere= \r->preparationcancellationsIntentId r O..== text intent O..&& preparationcancellationsGeneration r O..== num(fromIntegral generation),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=preparationsTable,O.uUpdateWith= \r->r {preparationsCancelled=num 1},O.uWhere= \r->preparationsIntentId r O..== text intent O..&& preparationsGeneration r O..== num(fromIntegral generation),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=intentsTable,O.uUpdateWith= \r->r {intentsResolved=num 1},O.uWhere= \r->intentsId r O..== text intent,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=text(if eligible then "ready" else "review")},O.uWhere= \r->obligationsId r O..== text intent,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text(if eligible then "Ready" else "NeedsReview")},O.uWhere= \r->ordersId r O..== text(obligationOrder ob) O..&& ordersStatus r O../= text "Paid",O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=reservationsTable,O.uUpdateWith= \r->r {reservationsPhase=text "obligation"},O.uWhere= \r->reservationsOrderId r O..== text(obligationOrder ob) O..&& reservationsPhase r O..== text "payment",O.uReturning=O.rCount}
      audit c "preparation_cancellation_completed" intent generation
    _->reject "preparation_cancellation_not_expected"
text :: Text -> O.Field O.SqlText
text=O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num=O.sqlInt8
audit :: PG.Connection -> Text -> Text -> Int -> IO ()
audit c action intent generation = do
  _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text action) (text $ intent<>":"<>T.pack(show generation))],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  pure ()
