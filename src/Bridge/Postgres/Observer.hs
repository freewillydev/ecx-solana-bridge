module Bridge.Postgres.Observer (observeOnce) where

import Bridge.Config
import Bridge.Postgres.Ledger (Ledger,ledgerAction)
import qualified Bridge.Postgres.Observation as Store
import Bridge.Postgres.Schema
import qualified Bridge.Observer as Chain
import Control.Monad (forM_)
import Data.Aeson
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Bridge.Types (reject)
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client (Manager)
import qualified Opaleye as O

newtype PostgresObserver = PostgresObserver Ledger
instance Chain.ObserverLedger PostgresObserver where
  observerReadCheckpoint (PostgresObserver ledger) = Store.readCheckpoint ledger
  observerMaximumNativeDepth (PostgresObserver ledger) = Store.maximumNativeDepth ledger
  observerCommitScan (PostgresObserver ledger) = Store.commitScan ledger
  observerLookupInstruction (PostgresObserver ledger) = Store.lookupInstruction ledger
  observerLookupReferences (PostgresObserver ledger) keys = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable ordersTable
      O.where_ (O.matchNullable (O.sqlBool False) (\instruction->foldr (O..||) (O.sqlBool False) [instruction O..== O.sqlStrictText ("solana-pay:"<>key) | key<-keys]) (ordersInstruction row))
      pure(ordersId row,ordersRequestJson row,ordersPolicyJson row,ordersInstruction row)
      :: IO [(Text,Text,Text,Maybe Text)]
    case rows of
      [(oid,request,policy,Just instruction)] | Just reference<-T.stripPrefix "solana-pay:" instruction->do
        req <- either (const $ reject "corrupt_ledger_json") pure(eitherDecodeStrict' $ TE.encodeUtf8 request)
        saved <- either (const $ reject "corrupt_ledger_json") pure(eitherDecodeStrict' $ TE.encodeUtf8 policy)
        pure(Just(oid,req,saved,reference))
      _->pure Nothing
  observerRecordScanFailure (PostgresObserver ledger) = Store.recordScanFailure ledger
  observerPendingVerification (PostgresObserver ledger) = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable chaineventsTable
      O.where_ (chaineventsChain row O..== O.sqlStrictText "Solana" O..&& chaineventsKind row O..== O.sqlStrictText "awaiting_verifier")
      pure (chaineventsFirstSeen row,chaineventsEventId row)
      :: IO [(Int64,Text)]
    pure (map snd (take 1000 (sortOn fst rows)))
  observerPromoteObserved (PostgresObserver ledger) = do
    candidates <- ledgerAction ledger $ \connection->O.runSelect connection $ do
      deposit <- O.selectTable depositsTable
      order <- O.selectTable ordersTable
      O.where_ (O.matchNullable (O.sqlBool False) (\oid->oid O..== ordersId order) (depositsOrderId deposit) O..&&
        depositsEligible deposit O..== O.sqlInt8 1 O..&& depositsAllocated deposit O..== O.sqlInt8 0 O..&&
        (ordersStatus order O..== O.sqlStrictText "Provisioning" O..|| ordersStatus order O..== O.sqlStrictText "AwaitingDeposit"))
      pure (depositsFirstSeen deposit,depositsId deposit)
      :: IO [(Int64,Text)]
    now <- Chain.epochSeconds
    forM_ (take 1000 (sortOn id candidates)) $ \(_,did)->Store.promoteDeposit ledger now did >> pure ()
  observerScannerHealth (PostgresObserver ledger) = ledgerAction ledger $ \connection->do
    health <- O.runSelect connection (O.selectTable scanhealthTable) :: IO [ScanHealth]
    checkpoints <- O.runSelect connection (O.selectTable checkpointsTable) :: IO [Checkpoints]
    reviews <- O.runSelect connection $ do
      row <- O.selectTable chaineventsTable
      O.where_ (chaineventsNeedsReview row O..== O.sqlInt8 1)
      pure (chaineventsFirstSeen row,chaineventsChain row,chaineventsEventId row,chaineventsKind row)
      :: IO [(Int64,Text,Text,Text)]
    let cursor chain=lookup chain [(checkpointsChain row,checkpointsAnchor row) | row<-checkpoints]
        scanners=[object ["chain" .= scanhealthChain row,"lastSuccess" .= scanhealthLastSuccess row,"lastError" .= scanhealthLastError row,"checkedAt" .= scanhealthCheckedAt row,"cursor" .= cursor (scanhealthChain row)] | row<-sortOn scanhealthChain health]
        reviewed=[object ["chain" .= chain,"event" .= event,"kind" .= kind] | (_,chain,event,kind)<-take 100 (sortOn (\(time,_,_,_)->time) reviews)]
    pure (object ["scanners" .= scanners,"review" .= reviewed])

-- Same real chain adapter implementation, a different durable store.
observeOnce :: Manager -> Config -> Ledger -> IO Value
observeOnce manager cfg ledger = Chain.observeOnce manager cfg (PostgresObserver ledger)
