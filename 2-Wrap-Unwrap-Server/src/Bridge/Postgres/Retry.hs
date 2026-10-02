module Bridge.Postgres.Retry (reasons,candidates,recordApproval) where
import Bridge.Types
import Bridge.Ledger.Model (Attempt(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Opaleye as O
import qualified Database.PostgreSQL.Simple as PG

reasons :: Ledger -> Text -> IO [Text]
reasons ledger txid = ledgerAction ledger $ \c->O.runSelect c $ do
  r <- O.selectTable solanaretryapprovalsTable
  O.where_(solanaretryapprovalsExpiredTxid r O..== O.sqlStrictText txid)
  pure(solanaretryapprovalsReason r)

context :: PG.Connection -> Text -> IO (Attempts,Intents,Obligations,Deposits)
context c txid = do
  rows <- O.runSelect c $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    ob <- O.selectTable obligationsTable
    d <- O.selectTable depositsTable
    e <- O.selectTable solanaexpiriesTable
    O.where_(attemptsTxid a O..== O.sqlStrictText txid O..&& attemptsTxid a O..== solanaexpiriesTxid e O..&& attemptsIntentId a O..== intentsId i O..&& intentsObligationId i O..== obligationsId ob O..&& obligationsDepositId ob O..== depositsId d)
    pure(a,i,ob,d)
    :: IO [(Attempts,Intents,Obligations,Deposits)]
  case rows of
    [(a,i,ob,d)]->do
      p <- O.runSelect c $ do
        r <- O.selectTable preparationsTable
        O.where_(preparationsIntentId r O..== O.sqlStrictText(intentsId i))
        pure(preparationsGeneration r)
        :: IO [Int64]
      latest <- O.runSelect c $ do
        r <- O.selectTable attemptsTable
        O.where_(attemptsIntentId r O..== O.sqlStrictText(intentsId i) O..&& attemptsPreparationGeneration r O..== O.sqlInt8(maximum(-1:p)))
        pure(attemptsTxid r)
        :: IO [Text]
      require (intentsChain i=="Solana" && intentsResolved i==1 && obligationsStatus ob=="review" && attemptsState a=="review" && latest==[txid]) "solana_retry_not_expected"
      pure(a,i,ob,d)
    _->reject "solana_retry_not_expected"

candidates :: Ledger -> Text -> IO [Attempt]
candidates ledger txid = ledgerAction ledger $ \c->do
  (a,i,_,_) <- context c txid
  pure[Attempt (attemptsTxid a) (attemptsIntentId a) (intentsChain i) (attemptsSignedBytes a) (attemptsPolicyJson a) (attemptsFeeLimit a) (attemptsState a) (attemptsCriticalSequence a)]

recordApproval :: Ledger -> Text -> Text -> Text -> IO ()
recordApproval ledger txid reason proof = ledgerAction ledger $ \c->do
  require (not(T.null $ T.strip reason) && T.length reason<=512 && not(T.null proof) && T.length proof<=200000) "invalid_retry_approval"
  old <- O.runSelect c $ do
    r <- O.selectTable solanaretryapprovalsTable
    O.where_(solanaretryapprovalsExpiredTxid r O..== O.sqlStrictText txid)
    pure(solanaretryapprovalsReason r)
    :: IO [Text]
  case old of
    [previous]->require(previous==reason) "retry_approval_conflict"
    []->do
      health <- O.runSelect c(fmap deploymentPaused $ O.selectTable deploymentTable) :: IO [Int64]
      require(health==[1]) "pause_before_operator_action"
      (_,i,ob,d) <- context c txid
      require(depositsEligible d==1) "solana_retry_not_expected"
      sequenceNo <- criticalSequence c
      _ <- O.runInsert c O.Insert {O.iTable=solanaretryapprovalsTable,O.iRows=[SolanaRetryApprovals (O.sqlStrictText txid) (O.sqlStrictText reason) (O.sqlStrictText proof) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=O.sqlStrictText "ready"},O.uWhere= \r->obligationsId r O..== O.sqlStrictText(obligationsId ob),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=O.sqlStrictText "Ready"},O.uWhere= \r->ordersId r O..== O.sqlStrictText(obligationsOrderId ob),O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "solana_retry_approved") (O.sqlStrictText txid)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require(intentsId i==obligationsId ob) "intent_binding_mismatch"
    _->reject "duplicate_retry_approval"
