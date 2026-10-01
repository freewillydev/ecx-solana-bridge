module Bridge.Postgres.Source (recordSourceCheckC, sourceWorkHashC) where

import Bridge.Types
import Bridge.Ledger (SourceCheck(..))
import Bridge.Postgres.Schema
import Bridge.Postgres.Ledger (criticalSequence, posting)
import Control.Monad (when, forM_)
import Data.Aeson (Value(..), ToJSON, encode)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as LBS
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

recordSourceCheckC :: PG.Connection -> Text -> SourceCheck -> IO ()
recordSourceCheckC connection did check = do
  sources <- O.runSelect connection $ do
    row <- O.selectTable depositsTable
    O.where_ (depositsId row O..== O.sqlStrictText did)
    pure row
    :: IO [Deposits]
  source <- case sources of [row]->pure row; _->reject "source_deposit_missing"
  asset <- case depositsAsset source of "Native"->pure Native; "Wrapped"->pure Wrapped; "Sol"->pure Sol; _->reject "invalid_source_asset"
  history <- O.runSelect connection $ do
    row <- O.selectTable sourcerecoveriesTable
    O.where_ (sourcerecoveriesDepositId row O..== O.sqlStrictText did)
    pure row
    :: IO [SourceRecoveries]
  let old=case reverse (sortOn sourcerecoveriesId history) of row:_->Just row; []->Nothing
      previousLoss=maybe 0 sourcerecoveriesShortfall old
      eligible=depositsEligible source==1
  (state,loss,proof) <- case check of
    SourcePending proof->require (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure ("pending",0,proof)
    SourceMissing proof->require (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure ("missing",depositsAmount source,proof)
    SourceRestored proof->require eligible "source_recovery_scan_not_current" >> pure ("restored",0,proof)
    SourceUnavailable proof->pure ("unavailable",previousLoss,proof)
  let evidence=TE.decodeUtf8 (LBS.toStrict (encode proof))
      ordinary=old==Nothing && depositsAllocated source==0 && state=="pending"
      unchanged=case old of Just row->sourcerecoveriesState row==state && sourcerecoveriesShortfall row==loss && (state/="unavailable" || sourcerecoveriesEvidenceJson row==evidence); _->False
  require (proof/=Null && T.length evidence<=16384) "invalid_source_recovery_evidence"
  when (not ordinary && not unchanged) $ do
    sequenceNo <- criticalSequence connection
    _ <- O.runInsert connection O.Insert
      {O.iTable=sourcerecoveriesTable,O.iRows=[SourceRecoveries Nothing (O.sqlStrictText did) (O.sqlStrictText state) (O.sqlInt8 loss) (O.sqlStrictText evidence) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    let delta=toInteger loss-toInteger previousLoss
    when (delta/=0) $ posting connection ("source-recovery:"<>T.pack (show sequenceNo)) "change in verified missing source value"
      [(asset,"source_deficit",negate delta),(asset,"external",delta)]
    when (delta<0) $ do
      covers <- O.runSelect connection $ do
        row <- O.selectTable sourcelosscoversTable
        O.where_ (sourcelosscoversDepositId row O..== O.sqlStrictText did)
        pure row
        :: IO [SourceLossCovers]
      returns <- O.runSelect connection $ fmap sourcelossreturnsCoverSequence (O.selectTable sourcelossreturnsTable)
      forM_ (filter (\row->sourcelosscoversCriticalSequence row `notElem` returns) covers) $ \row->do
        require (toInteger (sourcelosscoversAmount row)==negate delta) "source_loss_return_mismatch"
        let covered=sourcelosscoversCriticalSequence row
        _ <- O.runInsert connection O.Insert
          {O.iTable=sourcelossreturnsTable,O.iRows=[SourceLossReturns (O.sqlInt8 covered) (O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        posting connection ("source-loss-return:"<>T.pack (show covered)) "restored source returns its operator loss allocation"
          [(asset,"float",toInteger (sourcelosscoversFloatAmount row)),(asset,"earned",toInteger (sourcelosscoversEarnedAmount row)),(asset,"source_deficit",negate (toInteger (sourcelosscoversAmount row)))]
    _ <- O.runUpdate connection O.Update
      {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 1,deploymentPauseReason=O.sqlStrictText "source_recovery_review"},O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount}
    _ <- O.runInsert connection O.Insert
      {O.iTable=auditTable,O.iRows=[Audit Nothing (O.sqlStrictText "source_recovery") (O.sqlStrictText (did<>":"<>state))],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()

sourceWorkHashC :: PG.Connection -> Text -> IO Text
sourceWorkHashC connection intent = do
  obligations <- O.runSelect connection $ matching (\row->obligationsId row O..== O.sqlStrictText intent) (O.selectTable obligationsTable) :: IO [Obligations]
  work <- O.runSelect connection $ matching (\row->intentsId row O..== O.sqlStrictText intent) (O.selectTable intentsTable) :: IO [Intents]
  preparations <- O.runSelect connection $ matching (\row->preparationsIntentId row O..== O.sqlStrictText intent) (O.selectTable preparationsTable) :: IO [Preparations]
  attempts <- O.runSelect connection $ matching (\row->attemptsIntentId row O..== O.sqlStrictText intent) (O.selectTable attemptsTable) :: IO [Attempts]
  cancellations <- O.runSelect connection $ matching (\row->preparationcancellationsIntentId row O..== O.sqlStrictText intent) (O.selectTable preparationcancellationsTable) :: IO [PreparationCancellations]
  fees <- O.runSelect connection $ matching (\row->feereservationsIntentId row O..== O.sqlStrictText intent) (O.selectTable feereservationsTable) :: IO [FeeReservations]
  let obligationRows=[(obligationsId r,obligationsOrderId r,obligationsDepositId r,obligationsKind r,obligationsAsset r,obligationsAmount r,obligationsRecipient r) | r<-obligations]
      workRows=[(intentsChain r,intentsResolved r==1,intentsCommonInput r) | r<-work]
      preparationRows=[(preparationsGeneration r,preparationsPolicyJson r,preparationsDraftJson r,preparationsRetiredTxid r,preparationsCancelled r==1) | r<-sortOn preparationsGeneration preparations]
      attemptRows=[(attemptsTxid r,attemptsState r,attemptsPreparationGeneration r,attemptsCriticalSequence r,attemptsObservationJson r) | r<-sortOn (\r->(attemptsPreparationGeneration r,attemptsTxid r)) attempts]
      cancellationRows=[(preparationcancellationsGeneration r,preparationcancellationsReason r,preparationcancellationsCleanupJson r,preparationcancellationsCompleted r==1) | r<-sortOn preparationcancellationsGeneration cancellations]
      feeRows=[(feereservationsAsset r,feereservationsAmount r,feereservationsReleased r==1) | r<-fees]
      base=hashJson (obligationRows,workRows,preparationRows,attemptRows,cancellationRows,feeRows)
  drafts <- O.runSelect connection $ do
    draft <- O.selectTable nativereplacementdraftsTable
    attempt <- O.selectTable attemptsTable
    O.where_ (nativereplacementdraftsParentTxid draft O..== attemptsTxid attempt O..&& attemptsIntentId attempt O..== O.sqlStrictText intent)
    pure draft
    :: IO [NativeReplacementDrafts]
  cancelled <- O.runSelect connection $ do
    decision <- O.selectTable nativereplacementcancellationsTable
    draft <- O.selectTable nativereplacementdraftsTable
    attempt <- O.selectTable attemptsTable
    O.where_ (nativereplacementcancellationsDraftSequence decision O..== nativereplacementdraftsCriticalSequence draft O..&& nativereplacementdraftsParentTxid draft O..== attemptsTxid attempt O..&& attemptsIntentId attempt O..== O.sqlStrictText intent)
    pure decision
    :: IO [NativeReplacementCancellations]
  let draftRows=[(nativereplacementdraftsCriticalSequence r,nativereplacementdraftsParentTxid r,nativereplacementdraftsFee r,nativereplacementdraftsDraftJson r,nativereplacementdraftsWorkHash r,nativereplacementdraftsReason r) | r<-sortOn nativereplacementdraftsCriticalSequence drafts]
      cancelledRows=[(nativereplacementcancellationsDraftSequence r,nativereplacementcancellationsReason r,nativereplacementcancellationsCriticalSequence r) | r<-sortOn nativereplacementcancellationsCriticalSequence cancelled]
  pure (if null drafts && null cancelled then base else hashJson (base,draftRows,cancelledRows))

matching :: (a -> O.Field O.SqlBool) -> O.Select a -> O.Select a
matching predicate query = do
  row <- query
  O.where_ (predicate row)
  pure row

hashJson :: ToJSON a => a -> Text
hashJson = digest . LBS.toStrict . encode
