module Bridge.Budget
  ( CostLimits(..), orderCostLimits, reserveOrderCosts, transferOrderCosts
  , freeOperating, operatingSpent, operatingTime, checkOperatingCapacity, operatingBudget
  ) where

import Bridge.Config
import Bridge.Types
import Bridge.Ledger.Model (CostLimits(..))
import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple


orderCostLimits :: Connection -> Text -> IO CostLimits
orderCostLimits c oid = do
  rows <- query c "SELECT native_fee,solana_fee,solana_rent FROM order_cost_limits WHERE order_id=?" (Only oid) :: IO [(Int64,Int64,Int64)]
  case rows of
    [(n,s,r)] -> CostLimits <$> quantity n <*> quantity s <*> quantity r
    _ -> reject "order_cost_policy_missing"
 where quantity = either reject pure . amount . toInteger

-- Reserve both mutually exclusive outcomes. Keeping the refund allowance also
-- covers a failed conversion's paid network fee followed by a full refund.
reserveOrderCosts :: Connection -> Config -> Text -> Direction -> IO ()
reserveOrderCosts c cfg oid direction = do
  total <- either reject pure $ amount (toInteger (units $ maxSolFee cfg)+toInteger (units $ maxSolAccountRent cfg))
  let costs=[("Native",units $ maxNativeFee cfg),("Sol",units total)]
  checkOperatingCapacity c cfg costs
  execute c "INSERT INTO order_cost_limits VALUES(?,?,?,?)" (oid,units $ maxNativeFee cfg,units $ maxSolFee cfg,units $ maxSolAccountRent cfg)
  forM_ costs $ \(asset,n) -> do
    let conversion = (direction==NativeToWrapped && asset=="Sol") || (direction==WrappedToNative && asset=="Native")
        kind = if conversion then ("conversion"::Text) else "refund"
    execute c "INSERT INTO operating_reservations VALUES(?,?,?,?,'quote')" (oid,kind,asset,n)

-- Caller transfers the allowance and creates the intent in the SAME transaction.
-- A later replacement/extra refund must reacquire funds; it cannot reuse a spent
-- or previously transferred allowance merely because it belongs to the order.
transferOrderCosts :: Connection -> Config -> Text -> Text -> Text -> Int64 -> IO ()
transferOrderCosts c cfg oid kind asset feeLimit = do
  limits <- orderCostLimits c oid
  let costLimit = if asset=="Native" then toInteger (units $ savedNativeFee limits)
                else toInteger (units $ savedSolanaFee limits)+toInteger (units $ savedSolanaRent limits)
  require (feeLimit>0 && toInteger feeLimit<=costLimit) "order_fee_limit_exceeded"
  execute c "UPDATE operating_reservations SET phase='transferred' WHERE order_id=? AND kind=? AND asset=? AND phase IN('quote','obligation')" (oid,kind,asset)
  checkOperatingCapacity c cfg [(asset,feeLimit)]

operatingHolds :: Connection -> Text -> IO Integer
operatingHolds c asset = fold c
  "SELECT amount FROM fee_reservations WHERE asset=? AND released=0 UNION ALL SELECT amount FROM operating_reservations WHERE asset=? AND phase IN('quote','obligation')"
  (asset,asset) 0 $ \n (Only x::Only Int64) -> pure $! n+toInteger x

freeOperating :: Connection -> Text -> IO Integer
freeOperating c asset = do
  balance <- fold c "SELECT delta FROM postings WHERE asset=? AND account='operating'" (Only asset) 0 $ \n (Only x::Only Int64) -> pure $! n+toInteger x
  held <- operatingHolds c asset
  pure (balance-held)

-- A durable high-water time prevents clock rollback/restart from resetting the
-- budget. Future-dated bookings stay counted until this clock catches up.
operatingTime :: Connection -> IO Int64
operatingTime c = do
  execute_ c "UPDATE operating_clock SET last_time=MAX(last_time,unixepoch())"
  rows <- query_ c "SELECT last_time FROM operating_clock" :: IO [Only Int64]
  case rows of [Only n] -> pure n; _ -> reject "operating_clock_missing"

operatingSpent :: Connection -> Text -> Int64 -> IO Integer
operatingSpent c asset now = fold c
  "SELECT p.delta FROM operating_costs t JOIN postings p ON p.id=t.posting_id WHERE p.asset=? AND t.recorded_at>?"
  (asset,now-86400) 0 $ \n (Only x::Only Int64) -> pure $! n-toInteger x

checkOperatingCapacity :: Connection -> Config -> [(Text,Int64)] -> IO ()
checkOperatingCapacity c cfg costs = do
  now <- operatingTime c
  forM_ costs $ \(asset,n) -> do
    require (asset `elem` ["Native","Sol"] && n>=0) "invalid_operating_reservation"
    free <- freeOperating c asset
    require (free>=toInteger n) "insufficient_fee_budget"
    held <- operatingHolds c asset
    spent <- operatingSpent c asset now
    require (spent+held+toInteger n<=toInteger (units $ dailyLimit cfg asset)) "operating_daily_limit"

dailyLimit :: Config -> Text -> Amount
dailyLimit cfg asset = if asset=="Native" then maxNativeDailyCost cfg else maxSolDailyCost cfg

operatingBudget :: Connection -> Config -> IO Value
operatingBudget c cfg = do
  now <- operatingTime c
  rows <- forM ["Native","Sol"] $ \asset -> do
    held <- operatingHolds c asset
    spent <- operatingSpent c asset now
    free <- freeOperating c asset
    pure $ object ["asset" .= asset,"held" .= T.pack(show held),"spent" .= T.pack(show spent)
      ,"freeAllocation" .= T.pack(show free),"dailyLimit" .= dailyLimit cfg asset]
  pure $ object ["windowSeconds" .= (86400::Int),"accountingTime" .= now,"assets" .= rows]
