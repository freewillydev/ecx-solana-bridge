-- Independent accounting oracle for lifecycle extraction. Expected values never
-- call Domain.settlement. PostgreSQL contracts cover the durable replay gate;
-- the pure decision adapter will replace the baseline adapter during extraction.
module LifecycleCheck (checks) where

import Bridge.Domain
import Data.Int (Int64)
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import qualified Data.Text as T
import Test.QuickCheck

data FundingCase = Convert Direction Integer Integer | Return Asset Integer | Revenue Asset Integer
  deriving (Eq,Show)
data History = History [FundingCase] [Int] deriving Show
type Balances = M.Map (Asset,Account) Integer

checks :: IO [Result]
checks = sequence
  [ check "lifecycle accounting agrees with an independent funding model" $
      forAllShrink fundingCases shrinkFunding $ \funding ->
        aggregate (settlement $ outgoing 0 funding) === expected funding
  , check "bounded delivery histories preserve principal identity and protected accounts" $
      forAllShrink histories shrinkHistory $ \history ->
        let actual=baseline history; wanted=model history
        in conjoin [actual===wanted, property $ all (==0)
             [M.findWithDefault 0 (asset,account) actual | asset<-[Native,Wrapped,Sol],account<-[Backing,Liquidity,SourceDeficit]]]
  , check "model rejects deliberately duplicated principal" $ expectFailure $ once $
      let funding=Convert NativeToWrapped 100 1; history=History [funding] [0,0]
      in aggregate (concatMap (const $ settlement $ outgoing 0 funding) [0::Int,0]) === model history
  , check "model rejects deliberately altered fee accounting" $ expectFailure $ once $
      let funding=Convert WrappedToNative 100 1
      in M.adjust (+1) (Wrapped,Earned) (aggregate $ settlement $ outgoing 0 funding) === expected funding
  ]
 where
  check name test=putStrLn name >> quickCheckWithResult stdArgs {maxSuccess=300} test

fundingCases :: Gen FundingCase
fundingCases = do
  n<-frequency [(8,chooseInteger (2,100000000)),(1,pure 2),(1,pure $ toInteger(maxBound::Int64))]
  oneof
    [ Convert <$> elements [NativeToWrapped,WrappedToNative] <*> pure n <*> chooseInteger (0,n-1)
    , Return <$> elements [Native,Wrapped] <*> pure n
    , Revenue <$> elements [Native,Wrapped] <*> pure n ]

shrinkFunding :: FundingCase -> [FundingCase]
shrinkFunding (Convert direction n f) =
  [Convert direction smaller (min f $ smaller-1) | smaller<-shrink n,smaller>=2]
  <>[Convert direction n smaller | smaller<-shrink f,smaller>=0,smaller<n]
shrinkFunding (Return asset n) = [Return asset smaller | smaller<-shrink n,smaller>0]
shrinkFunding (Revenue asset n) = [Revenue asset smaller | smaller<-shrink n,smaller>0]

histories :: Gen History
histories = do
  count<-chooseInt (1,6)
  payments<-vectorOf count fundingCases
  lengthOfTrace<-chooseInt (0,24)
  deliveries<-vectorOf lengthOfTrace (chooseInt (0,count-1))
  -- Include every payment and at least one exact redelivery. Shrinking below
  -- can isolate the minimal delivery while keeping all indices well formed.
  pure $ History payments (take 24 deliveries<>[0..count-1]<>[0])

shrinkHistory :: History -> [History]
shrinkHistory (History payments deliveries) =
  [History payments fewer | fewer<-shrinkList (const []) deliveries]
  <>[History (before<>(smaller:after)) deliveries
     | index<-[0..length payments-1],(before,current:after)<-[splitAt index payments]
     ,smaller<-shrinkFunding current]

outgoing :: Int -> FundingCase -> Payment
outgoing index funding = good $ do
  source<-case funding of
    Convert direction n f -> historicalQuote (money n) (money f) >>= conversion order receipt direction
    Return asset n -> refund order receipt asset (money n)
    Revenue asset n -> earnedFees order asset (money n)
  payment key source "unchanged-recipient"
 where
  key="payment-"<>T.pack(show index); order="order-"<>key; receipt="receipt-"<>key

-- Only this adapter uses production accounting. Deduplication here is the
-- baseline Store contract, not a new production implementation of replay.
baseline :: History -> Balances
baseline (History payments deliveries) = aggregate $
  concat [settlement(outgoing index $ payments!!index) | index<-nub deliveries]

-- The model owns its paid set and independently calculates account changes.
model :: History -> Balances
model (History payments deliveries) = snd $ foldl step (Set.empty,M.empty) deliveries
 where
  step prior@(paid,balances) index
    | Set.member index paid = prior
    | otherwise = (Set.insert index paid,normalize $ M.unionWith (+) balances (expected $ payments!!index))

expected :: FundingCase -> Balances
expected funding = normalize $ M.fromListWith (+) $ case funding of
  Convert direction n f ->
    let (source,destination)=case direction of NativeToWrapped->(Native,Wrapped); WrappedToNative->(Wrapped,Native)
    in [((source,Principal),-n),((source,Float),n-f),((source,Earned),f)
       ,((destination,Float),f-n),((destination,External),n-f)]
  Return asset n -> [((asset,Principal),-n),((asset,External),n)]
  Revenue asset n -> [((asset,FeePending),-n),((asset,External),n)]

aggregate :: [Posting] -> Balances
aggregate = normalize . M.fromListWith (+) . map (\p->((postingAsset p,postingAccount p),postingDelta p))
normalize :: Balances -> Balances
normalize = M.filter (/=0)
money :: Integer -> Amount
money = good . amount
good :: Show e => Either e a -> a
good = either (error . show) id
