{-# LANGUAGE GADTs, ScopedTypeVariables #-}
module Main (main) where
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),CostLimits(..),PolicySnapshot(..))
import Bridge.Store
import qualified Bridge.Store.Schema as S
import Control.Exception
import Data.IORef
import Test.QuickCheck (quickCheckWithResult,stdArgs,maxSuccess,forAll,chooseInteger,ioProperty,isSuccess)
import Control.Monad (unless,void,when)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import System.Environment (getEnv)

main :: IO ()
main = do
  database <- getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user <- getEnv "USER"
  readRole <- getEnv "ECX_REBUILD_CONTRACT_READER"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      readerSettings=settings {PG.connectUser=readRole}
      policy=PaymentTerms (PolicySnapshot 2 "finalized" "contract") (CostLimits (money 10) (money 10) (money 10))
      key=T.replicate 64 "a"
      reserve=ReserveFees 100 key Native (money 100) "recipient" "test owned revenue"
      check ok=unless ok (fail "store contract failed")
  bracket (PG.connect settings) PG.close $ \fixtures -> do
    fixture fixtures Initialize
    withReader readerSettings "contract" $ \reader -> do
      expectStore "unsafe_read_database_role" (withReader settings "contract" $ const $ pure ())
      expectStore "ledger_profile_or_schema_mismatch" (withReader readerSettings "wrong" $ const $ pure ())
      withWriter settings policy (money 1000) (const $ pure ()) $ \writer -> do
        expectStore "worker_already_running" (withWriter settings policy (money 1000) (const $ pure ()) $ const $ pure ())
        initial <- evalRead reader ReadBalances
        first <- evalWrite writer reserve
        replay <- evalWrite writer reserve
        check (first==replay && withdrawalSequence first==1)
        booked <- evalRead reader ReadBalances
        check (M.lookup (Native,Earned) booked==Just 900 && M.lookup (Native,FeePending) booked==Just 100)
        expectStore "fee_withdrawal_conflict" (evalWrite writer $ ReserveFees 100 key Native (money 101) "recipient" "test owned revenue")
        expectStore "custody_not_reconciled" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "b") Native (money 100) "recipient" "test owned revenue")
        fixture fixtures RefreshCustody
        expectStore "insufficient_earned_fees" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "b") Native (money 1000) "recipient" "test owned revenue")
        cancelled <- evalWrite writer (CancelFees key "cancel")
        replayCancelled <- evalWrite writer (CancelFees key "cancel")
        check (cancelled==replayCancelled && withdrawalCancellation cancelled==Just("cancel",2))
        restored <- evalRead reader ReadBalances
        check (M.filter (/=0) restored==M.filter (/=0) initial)
        expectStore "fee_withdrawal_cancellation_conflict" (evalWrite writer (CancelFees key "changed"))
        resumed <- evalWrite writer reserve
        check (withdrawalCancellation resumed==Just("cancel",2))
        counter <- newIORef (0::Int)
        result <- quickCheckWithResult stdArgs {maxSuccess=25} $ forAll (chooseInteger (1,1000)) $ \n -> ioProperty $ do
          index <- atomicModifyIORef' counter (\i->(i+1,i+1))
          let identifier=T.justifyRight 64 '0' (T.pack $ show index)
          fixture fixtures RefreshCustody
          before <- evalRead reader ReadBalances
          reserved <- evalWrite writer (ReserveFees 100 identifier Native (money n) "recipient" "property")
          afterReserve <- evalRead reader ReadBalances
          _ <- evalWrite writer (CancelFees identifier "property cancel")
          afterCancel <- evalRead reader ReadBalances
          pure (units(paymentAmount $ withdrawalPayment reserved)==fromInteger n &&
            M.findWithDefault 0 (Native,Earned) afterReserve==1000-n &&
            M.findWithDefault 0 (Native,FeePending) afterReserve==n &&
            M.filter (/=0) before==M.filter (/=0) afterCancel)
        check (isSuccess result)
      -- A failed durable checkpoint rolls back money and permanently fences the
      -- writer. Reader checks use separate SELECT-only credentials throughout.
      fixture fixtures RefreshCustody
      beforeFailure <- evalRead reader ReadState
      let failCheckpoint n=when (n>ledgerSequence beforeFailure) (ioError $ userError "injected checkpoint failure")
      withWriter settings policy (money 1000) failCheckpoint $ \writer -> do
        failure <- try (evalWrite writer $ ReserveFees 100 (T.replicate 64 "c") Native (money 100) "recipient" "test rollback") :: IO (Either IOException WithdrawalView)
        check (case failure of Left _->True; Right _->False)
        expectStore "ledger_connection_fenced" (evalWrite writer (Pause "must fail"))
      rolledBack <- evalRead reader (ReadWithdrawal $ T.replicate 64 "c")
      state <- evalRead reader ReadState
      check (rolledBack==Nothing && ledgerSequence state==ledgerSequence beforeFailure)
  putStrLn "PASS: PostgreSQL role isolation, profile binding, exclusive writer, replay, conflicts, custody freshness, earned funds, cancellation and checkpoint rollback/fencing"

money :: Integer -> Amount
money = either (error . T.unpack) id . amount
expectStore :: T.Text -> IO a -> IO ()
expectStore expected action = do
  result <- try action
  case result of
    Left (StoreError actual) | expected==actual -> pure ()
    Left err -> fail ("unexpected rejection: "<>show err)
    Right _ -> fail ("expected rejection: "<>T.unpack expected)

-- Fixture operations are closed and use Opaleye. They exist only in this test
-- component; no arbitrary SQL or connection callback is available to handlers.
data Fixture = Initialize | RefreshCustody
fixture :: PG.Connection -> Fixture -> IO ()
fixture c Initialize = PG.withTransaction c $ do
  void $ O.runInsert c O.Insert {O.iTable=S.deployment,O.iRows=[S.Deployment (O.sqlInt8 1) (O.sqlInt8 18) (O.sqlStrictText "contract") (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "test")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.custody,O.iRows=[(O.sqlInt8 1,O.sqlInt8 0,O.null,O.null,O.null)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(O.sqlStrictText "fixture",O.sqlStrictText "contract balances")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=[(Nothing,O.sqlStrictText "fixture",O.sqlStrictText "Native",O.sqlStrictText account,O.sqlInt8 delta)| (account,delta)<-[("external",-1000),("earned",1000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  fixture c RefreshCustody
fixture c RefreshCustody = do
  n <- O.runUpdate c O.Update {O.uTable=S.custody,O.uUpdateWith= \(key,revision,_,_,_)->(key,revision,O.toNullable revision,O.toNullable $ O.sqlInt8 100,O.null),O.uWhere= \(key,_,_,_,_)->key O..== O.sqlInt8 1,O.uReturning=O.rCount}
  unless (n==1) (fail "custody fixture missing")
