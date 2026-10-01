module Bridge.Postgres.Observation
  ( recordScan, readCheckpoint, lookupInstruction, maximumNativeDepth ) where

import Bridge.Types
import Bridge.Ledger (Deposit(..), SourceCheck(..))
import Bridge.Postgres.Source (recordSourceCheckC, sourceWorkHashC)
import Bridge.Postgres.Ledger (Ledger, ledgerAction, posting)
import Bridge.Postgres.Schema
import Control.Monad (when, forM)
import Data.Aeson (FromJSON, eitherDecodeStrict', object, (.=))
import Data.List (sortOn)
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

scanAssets :: [(Text,Asset)]
scanAssets=[("Native",Native),("Solana",Wrapped),("SolanaOperating",Sol)]

readCheckpoint :: Ledger -> Text -> IO (Maybe Text)
readCheckpoint ledger chain = ledgerAction ledger (\connection->readCheckpointC connection chain)
readCheckpointC :: PG.Connection -> Text -> IO (Maybe Text)
readCheckpointC connection chain = do
  rows <- O.runSelect connection $ do
    row <- O.selectTable checkpointsTable
    O.where_ (checkpointsChain row O..== O.sqlStrictText chain)
    pure (checkpointsAnchor row)
    :: IO [Text]
  case rows of []->pure Nothing; [anchor]->pure (Just anchor); _->reject "duplicate_checkpoint"

recordScan :: Ledger -> Text -> Maybe Text -> Text -> [Deposit] -> IO ()
recordScan ledger chain previous next deposits = ledgerAction ledger $ \connection->do
  require (chain `elem` map fst scanAssets && not (T.null next) && T.length next<=128 && length deposits<=1000) "invalid_scan_batch"
  require (all (\deposit->Just (depositAsset deposit)==lookup chain scanAssets) deposits) "scan_asset_mismatch"
  current <- readCheckpointC connection chain
  require (current==previous) "stale_scan_cursor"
  mapM_ (observeDepositC connection) deposits
  case current of
    Nothing->do
      _ <- O.runInsert connection O.Insert {O.iTable=checkpointsTable,O.iRows=[Checkpoints (O.sqlStrictText chain) (O.sqlStrictText next)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    Just _->do
      _ <- O.runUpdate connection O.Update
        {O.uTable=checkpointsTable,O.uUpdateWith= \row->row {checkpointsAnchor=O.sqlStrictText next},O.uWhere= \row->checkpointsChain row O..== O.sqlStrictText chain,O.uReturning=O.rCount}
      pure ()

observeDepositC :: PG.Connection -> Deposit -> IO ()
observeDepositC connection Deposit{..} = do
  require (units depositAmount>0 && depositConfirmations>=0 && depositSeenAt>=0) "invalid_deposit"
  case depositOrder of
    Nothing->pure ()
    Just oid->do
      orders <- O.runSelect connection $ do
        row <- O.selectTable ordersTable
        O.where_ (ordersId row O..== O.sqlStrictText oid)
        pure (ordersRequestJson row,ordersPolicyJson row)
        :: IO [(Text,Text)]
      case orders of
        [(requestJson,policyJson)]->do
          req <- decodeSaved requestJson
          savedPolicy <- decodeSaved policyJson
          require (sourceAsset (direction req)==depositAsset) "deposit_asset_mismatch"
          when (depositAsset==Native && depositEligible) $ require (depositConfirmations>=nativeDepth savedPolicy) "deposit_confirmation_policy_mismatch"
        _->reject "deposit_order_missing"
  existing <- O.runSelect connection $ do
    row <- O.selectTable depositsTable
    O.where_ (depositsId row O..== O.sqlStrictText depositId)
    pure row
    :: IO [Deposits]
  let eligible=if depositEligible then 1 else 0
      optionalOrder=maybe O.null (O.toNullable . O.sqlStrictText) depositOrder
  case existing of
    []->do
      _ <- O.runInsert connection O.Insert
        { O.iTable=depositsTable
        , O.iRows=[Deposits (O.sqlStrictText depositId) optionalOrder (O.sqlStrictText (T.pack (show depositAsset)))
            (O.sqlInt8 (units depositAmount)) (O.sqlStrictText depositAnchor) (O.sqlInt8 depositSeenAt)
            (O.sqlInt8 (fromIntegral depositConfirmations)) (O.sqlInt8 eligible) (O.sqlInt8 0) (O.sqlStrictText "observed")]
        , O.iReturning=O.rCount,O.iOnConflict=Nothing }
      let account=maybe "unallocated" (const "principal") depositOrder
      posting connection ("deposit:"<>depositId) "observed customer value"
        [(depositAsset,account,toInteger (units depositAmount)),(depositAsset,"external",negate (toInteger (units depositAmount)))]
    [old]->do
      require (depositsOrderId old==depositOrder && depositsAsset old==T.pack (show depositAsset) && depositsAmount old==units depositAmount) "conflicting_deposit_evidence"
      _ <- O.runUpdate connection O.Update
        { O.uTable=depositsTable
        , O.uUpdateWith= \row->row {depositsAnchor=O.sqlStrictText depositAnchor,depositsConfirmations=O.sqlInt8 (fromIntegral depositConfirmations),depositsEligible=O.sqlInt8 eligible}
        , O.uWhere= \row->depositsId row O..== O.sqlStrictText depositId,O.uReturning=O.rCount }
      when (depositsEligible old==1 && not depositEligible) $ do
        reviewed <- O.runSelect connection $ do
          row <- O.selectTable obligationsTable
          O.where_ (obligationsDepositId row O..== O.sqlStrictText depositId O..&&
            (obligationsStatus row O..== O.sqlStrictText "ready" O..|| obligationsStatus row O..== O.sqlStrictText "paying"))
          pure (obligationsId row,obligationsStatus row)
          :: IO [(Text,Text)]
        work <- forM reviewed $ \(intent,state)->do
          hash <- sourceWorkHashC connection intent
          pure (object ["intent" .= intent,"previousStatus" .= state,"workHash" .= hash])
        recordSourceCheckC connection depositId $ SourceUnavailable $ object
          ["reason" .= ("source_eligibility_lost"::Text),"previousAnchor" .= depositsAnchor old,"anchor" .= depositAnchor,"reviewedObligations" .= work]
      when (depositAsset/=Native && depositEligible) $ do
        history <- O.runSelect connection $ do
          row <- O.selectTable sourcerecoveriesTable
          O.where_ (sourcerecoveriesDepositId row O..== O.sqlStrictText depositId)
          pure row
          :: IO [SourceRecoveries]
        case reverse (sortOn sourcerecoveriesId history) of
          latest:_ | sourcerecoveriesState latest/="restored" && sourcerecoveriesShortfall latest==0 ->
            recordSourceCheckC connection depositId (SourceRestored (object ["anchor" .= depositAnchor,"verifiedBy" .= ("source_observer"::Text)]))
          _->pure ()
      when (not depositEligible && depositsAllocated old==1) $ do
        covered <- O.runSelect connection $ do
          did <- O.selectTable (O.table "accounted_source_losses" (O.requiredTableField "deposit_id"))
          O.where_ (did O..== O.sqlStrictText depositId)
          pure did
          :: IO [Text]
        when (null covered) $ do
          _ <- O.runUpdate connection O.Update
            {O.uTable=deploymentTable,O.uUpdateWith= \row->row {deploymentPaused=O.sqlInt8 1,deploymentPauseReason=O.sqlStrictText "source_reorg_review"},O.uWhere=const (O.sqlBool True),O.uReturning=O.rCount}
          _ <- O.runUpdate connection O.Update
            {O.uTable=obligationsTable,O.uUpdateWith= \row->row {obligationsStatus=O.sqlStrictText "review"},O.uWhere= \row->obligationsDepositId row O..== O.sqlStrictText depositId O..&& obligationsStatus row O../= O.sqlStrictText "paid" O..&& obligationsStatus row O../= O.sqlStrictText "cancelled",O.uReturning=O.rCount}
          pure ()
      pure ()
    _->reject "duplicate_deposit"

lookupInstruction :: Ledger -> Text -> IO (Maybe (Text,OrderRequest,PolicySnapshot))
lookupInstruction ledger instruction = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    row <- O.selectTable ordersTable
    O.where_ (O.matchNullable (O.sqlBool False) (\value->value O..== O.sqlStrictText instruction) (ordersInstruction row))
    pure (ordersId row,ordersRequestJson row,ordersPolicyJson row)
    :: IO [(Text,Text,Text)]
  case rows of
    []->pure Nothing
    [(oid,req,savedPolicy)]->Just <$> ((,,) oid <$> decodeSaved req <*> decodeSaved savedPolicy)
    _->reject "duplicate_deposit_instruction"

maximumNativeDepth :: Ledger -> Int -> IO Int
maximumNativeDepth ledger minimumDepth = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ fmap ordersPolicyJson (O.selectTable ordersTable) :: IO [Text]
  policies <- mapM decodeSaved rows
  pure (maximum (minimumDepth:1:map nativeDepth policies))

decodeSaved :: FromJSON a => Text -> IO a
decodeSaved = either (const $ reject "corrupt_ledger_json") pure . eitherDecodeStrict' . TE.encodeUtf8
