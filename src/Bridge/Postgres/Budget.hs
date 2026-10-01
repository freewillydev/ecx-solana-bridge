module Bridge.Postgres.Budget
  ( reserveOrderCosts, freeOperating, checkOperatingCapacity, transferOrderCosts ) where

import Bridge.Config
import Bridge.Types
import Bridge.Postgres.Schema
import Control.Monad (forM_)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

operatingHolds :: PG.Connection -> Text -> IO Integer
operatingHolds connection asset = do
  fees <- O.runSelect connection $ fmap feereservationsAmount $ selectWhere
    (\row->feereservationsAsset row O..== O.sqlStrictText asset O..&& feereservationsReleased row O..== O.sqlInt8 0)
    (O.selectTable feereservationsTable) :: IO [Int64]
  orders <- O.runSelect connection $ fmap operatingreservationsAmount $ selectWhere
    (\row->operatingreservationsAsset row O..== O.sqlStrictText asset O..&&
      (operatingreservationsPhase row O..== O.sqlStrictText "quote" O..|| operatingreservationsPhase row O..== O.sqlStrictText "obligation"))
    (O.selectTable operatingreservationsTable) :: IO [Int64]
  pure (sum (map toInteger (fees<>orders)))

freeOperating :: PG.Connection -> Text -> IO Integer
freeOperating connection asset = do
  rows <- O.runSelect connection $ fmap postingsDelta $ selectWhere
    (\row->postingsAsset row O..== O.sqlStrictText asset O..&& postingsAccount row O..== O.sqlStrictText "operating")
    (O.selectTable postingsTable) :: IO [Int64]
  held <- operatingHolds connection asset
  pure (sum (map toInteger rows)-held)

operatingTime :: PG.Connection -> IO Int64
operatingTime connection = do
  now <- floor <$> getPOSIXTime
  times <- O.runUpdate connection O.Update
    { O.uTable=operatingclockTable
    , O.uUpdateWith= \row->row {operatingclockLastTime=O.ifThenElse (operatingclockLastTime row O..> O.sqlInt8 now) (operatingclockLastTime row) (O.sqlInt8 now)}
    , O.uWhere= \row->operatingclockSingleton row O..== O.sqlInt8 1
    , O.uReturning=O.rReturning operatingclockLastTime }
  case times of [time]->pure time; _->reject "operating_clock_missing"

operatingSpent :: PG.Connection -> Text -> Int64 -> IO Integer
operatingSpent connection asset now = do
  rows <- O.runSelect connection $ fmap (postingsDelta . fst) $ selectWhere
    (\(posting,cost)->postingsId posting O..== operatingcostsPostingId cost O..&&
      postingsAsset posting O..== O.sqlStrictText asset O..&& operatingcostsRecordedAt cost O..> O.sqlInt8 (now-86400)) $ do
        posting <- O.selectTable postingsTable
        cost <- O.selectTable operatingcostsTable
        pure (posting,cost)
    :: IO [Int64]
  pure (negate (sum (map toInteger rows)))

checkOperatingCapacity :: PG.Connection -> Config -> [(Text,Int64)] -> IO ()
checkOperatingCapacity connection cfg costs = do
  now <- operatingTime connection
  forM_ costs $ \(asset,n)->do
    require (asset `elem` ["Native","Sol"] && n>=0) "invalid_operating_reservation"
    free <- freeOperating connection asset
    require (free>=toInteger n) "insufficient_fee_budget"
    held <- operatingHolds connection asset
    spent <- operatingSpent connection asset now
    let limit=if asset=="Native" then maxNativeDailyCost cfg else maxSolDailyCost cfg
    require (spent+held+toInteger n<=toInteger (units limit)) "operating_daily_limit"

reserveOrderCosts :: PG.Connection -> Config -> Text -> Direction -> IO ()
reserveOrderCosts connection cfg oid direction = do
  total <- either reject pure $ amount (toInteger (units (maxSolFee cfg))+toInteger (units (maxSolAccountRent cfg)))
  let costs=[("Native",units (maxNativeFee cfg)),("Sol",units total)]
  checkOperatingCapacity connection cfg costs
  _ <- O.runInsert connection O.Insert
    { O.iTable=ordercostlimitsTable
    , O.iRows=[OrderCostLimits (O.sqlStrictText oid) (O.sqlInt8 (units (maxNativeFee cfg))) (O.sqlInt8 (units (maxSolFee cfg))) (O.sqlInt8 (units (maxSolAccountRent cfg)))]
    , O.iReturning=O.rCount,O.iOnConflict=Nothing }
  forM_ costs $ \(asset,n)->do
    let conversion=(direction==NativeToWrapped && asset=="Sol") || (direction==WrappedToNative && asset=="Native")
        kind=if conversion then "conversion" else "refund"
    _ <- O.runInsert connection O.Insert
      { O.iTable=operatingreservationsTable
      , O.iRows=[OperatingReservations (O.sqlStrictText oid) (O.sqlStrictText kind) (O.sqlStrictText asset) (O.sqlInt8 n) (O.sqlStrictText "quote")]
      , O.iReturning=O.rCount,O.iOnConflict=Nothing }
    pure ()

transferOrderCosts :: PG.Connection -> Config -> Text -> Text -> Text -> Int64 -> IO ()
transferOrderCosts connection cfg oid kind asset feeLimit = do
  limits <- O.runSelect connection $ selectWhere (\row->ordercostlimitsOrderId row O..== O.sqlStrictText oid) (O.selectTable ordercostlimitsTable) :: IO [OrderCostLimits]
  limit <- case limits of
    [row]->pure $ if asset=="Native" then toInteger (ordercostlimitsNativeFee row) else toInteger (ordercostlimitsSolanaFee row)+toInteger (ordercostlimitsSolanaRent row)
    _->reject "order_cost_policy_missing"
  require (feeLimit>0 && toInteger feeLimit<=limit) "order_fee_limit_exceeded"
  _ <- O.runUpdate connection O.Update
    { O.uTable=operatingreservationsTable
    , O.uUpdateWith= \row->row {operatingreservationsPhase=O.sqlStrictText "transferred"}
    , O.uWhere= \row->operatingreservationsOrderId row O..== O.sqlStrictText oid O..&&
        operatingreservationsKind row O..== O.sqlStrictText kind O..&& operatingreservationsAsset row O..== O.sqlStrictText asset O..&&
        (operatingreservationsPhase row O..== O.sqlStrictText "quote" O..|| operatingreservationsPhase row O..== O.sqlStrictText "obligation")
    , O.uReturning=O.rCount }
  checkOperatingCapacity connection cfg [(asset,feeLimit)]

selectWhere :: (a -> O.Field O.SqlBool) -> O.Select a -> O.Select a
selectWhere predicate query = do
  row <- query
  O.where_ (predicate row)
  pure row
