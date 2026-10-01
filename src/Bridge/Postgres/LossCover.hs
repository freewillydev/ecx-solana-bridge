module Bridge.Postgres.LossCover (decision,record) where
import Bridge.Types
import Bridge.Ledger (LossCapital(..),Deposit(..))
import Bridge.RPC (fieldValue)
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Data.Aeson (Value,ToJSON,encode,object,(.=))
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as M
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

rowsC :: PG.Connection -> Text -> Int64 -> IO [SourceLossCovers]
rowsC c did recovery=O.runSelect c $ do
  r <- O.selectTable sourcelosscoversTable
  O.where_(sourcelosscoversDepositId r O..== text did O..&& sourcelosscoversRecoverySequence r O..== num recovery)
  pure r
capitalOf :: SourceLossCovers -> IO LossCapital
capitalOf row=LossCapital <$> quantity(sourcelosscoversFloatAmount row) <*> quantity(sourcelosscoversEarnedAmount row)
 where quantity=either reject pure . amount . toInteger
decision :: Ledger -> Text -> Int64 -> IO (Maybe(LossCapital,Text))
decision ledger did recovery=ledgerAction ledger $ \c->do
  rows <- rowsC c did recovery
  case rows of
    []->pure Nothing
    [r]->do
      capital <- capitalOf r
      pure(Just(capital,sourcelosscoversReason r))
    _->reject "duplicate_source_loss_cover"

record :: Ledger -> Deposit -> Int64 -> Int64 -> LossCapital -> Text -> Value -> Value -> IO ()
record ledger source recovery now capital reason sourceProof custodyProof=ledgerAction ledger $ \c->do
  require (recovery>0 && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_source_loss_cover"
  state <- O.runSelect c $ fmap deploymentPaused $ O.selectTable deploymentTable :: IO [Int64]
  require (state==[1]) "pause_before_operator_action"
  let did=depositId source
      fromFloat=units(lossFloat capital)
      fromEarned=units(lossEarned capital)
      quantity=units(depositAmount source)
  old <- rowsC c did recovery
  case old of
    [r]->do saved <- capitalOf r; require (saved==capital && sourcelosscoversReason r==reason) "source_loss_cover_conflict"
    []->do
      require (depositAsset source==Native && not(depositEligible source)) "source_loss_not_proven"
      deposits <- O.runSelect c $ do
        row <- O.selectTable depositsTable
        O.where_(depositsId row O..== text did O..&& depositsAsset row O..== text "Native" O..&& depositsEligible row O..== num 0)
        pure row
        :: IO [Deposits]
      history <- O.runSelect c $ O.limit 1 $ O.orderBy (O.desc sourcerecoveriesId) $ do
        row <- O.selectTable sourcerecoveriesTable
        O.where_(sourcerecoveriesDepositId row O..== text did)
        pure row
        :: IO [SourceRecoveries]
      require (toInteger fromFloat+toInteger fromEarned==toInteger quantity) "source_loss_allocation_mismatch"
      require (case (deposits,history) of
        ([d],[r])->depositsOrderId d==depositOrder source && depositsAmount d==quantity && depositsAnchor d==depositAnchor source &&
          depositsConfirmations d==fromIntegral(depositConfirmations source) && depositsFirstSeen d==depositSeenAt source &&
          sourcerecoveriesState r=="missing" && sourcerecoveriesShortfall r==quantity && sourcerecoveriesCriticalSequence r==recovery
        _->False) "source_loss_not_proven"
      covers <- O.runSelect c $ do
        row <- O.selectTable sourcelosscoversTable
        O.where_(sourcelosscoversDepositId row O..== text did)
        pure row
        :: IO [SourceLossCovers]
      returns <- O.runSelect c $ do
        row <- O.selectTable sourcelossreturnsTable
        cover <- O.selectTable sourcelosscoversTable
        O.where_(sourcelossreturnsCoverSequence row O..== sourcelosscoversCriticalSequence cover O..&& sourcelosscoversDepositId cover O..== text did)
        pure(sourcelossreturnsCoverSequence row)
        :: IO [Int64]
      require (all ((`elem` returns).sourcelosscoversCriticalSequence) covers) "source_loss_already_covered"
      txid <- fieldValue "transaction" sourceProof :: IO Text
      index <- fieldValue "output" sourceProof :: IO Int64
      observationHash <- fieldValue "observationHash" sourceProof :: IO Text
      depth <- fieldValue "confirmations" sourceProof :: IO Int64
      require (depth<0 && index>=0 && did=="native:"<>txid<>":"<>T.pack(show index)) "source_loss_not_proven"
      observed <- O.runSelect c $ do
        e <- O.selectTable chaineventsTable
        O.where_(chaineventsChain e O..== text "Native" O..&& chaineventsEventId e O..== text txid O..&& chaineventsNeedsReview e O..== num 0)
        pure(chaineventsEvidenceHash e)
        :: IO [Text]
      require (observed==[observationHash]) "source_recovery_scan_not_current"
      revision <- fieldValue "revision" custodyProof :: IO Int64
      checked <- fieldValue "checkedAt" custodyProof :: IO Int64
      report <- fieldValue "report" custodyProof :: IO Value
      matched <- fieldValue "matches" report :: IO Bool
      block <- fieldValue "nativeBlock" report :: IO Text
      height <- fieldValue "nativeHeight" report :: IO Int64
      sourceBlock <- fieldValue "nodeBlock" sourceProof :: IO Text
      sourceHeight <- fieldValue "nodeHeight" sourceProof :: IO Int64
      require (block==sourceBlock && height==sourceHeight) "source_loss_custody_view_changed"
      current <- O.runSelect c $ fmap custodycheckRevision $ O.selectTable custodycheckTable :: IO [Int64]
      require (matched && current==[revision] && checked>=0 && checked<=now && toInteger now-toInteger checked<=60) "source_loss_custody_not_current"
      bs <- balances c
      held <- O.runSelect c $ do
        r <- O.selectTable reservationsTable
        O.where_(reservationsAsset r O..== text "Native" O..&& reservationsPhase r O../= text "released")
        pure(reservationsAmount r)
        :: IO [Int64]
      let free=M.findWithDefault 0 ("Native","float") bs-sum(map toInteger held)
          earned=M.findWithDefault 0 ("Native","earned") bs
      require (free>=toInteger fromFloat && earned>=toInteger fromEarned) "insufficient_loss_capital"
      let proof=json $ object["source" .= sourceProof,"custody" .= custodyProof]
      require (T.length proof<=32768) "source_loss_evidence_too_large"
      sequenceNo <- criticalSequence c
      count <- O.runInsert c O.Insert {O.iTable=sourcelosscoversTable,O.iRows=[SourceLossCovers (num sequenceNo) (text did) (num recovery) (num quantity) (num fromFloat) (num fromEarned) (text reason) (text proof)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "source_loss_cover_insert_failed"
      posting c ("source-loss-cover:"<>T.pack(show sequenceNo)) "operator capital covers verified source shortfall" [(Native,"float",negate $ toInteger fromFloat),(Native,"earned",negate $ toInteger fromEarned),(Native,"source_deficit",toInteger quantity)]
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "source_loss_covered") (text did)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    _->reject "duplicate_source_loss_cover"

json :: ToJSON a => a -> Text
json=TE.decodeUtf8 . LBS.toStrict . encode
text :: Text -> O.Field O.SqlText
text=O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num=O.sqlInt8
