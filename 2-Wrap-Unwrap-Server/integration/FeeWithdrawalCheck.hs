-- PostgreSQL accounting contract only; no simulated chains or signing.
module Main where
import Bridge.Types
import Bridge.Config
import qualified Bridge.Postgres.Ledger as L
import qualified Bridge.Postgres.FeeWithdrawal as W
import qualified Database.PostgreSQL.Simple as PG
import qualified Data.ByteString as B
import Data.Aeson
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import System.Environment
import System.Posix.User
import Control.Exception
import Control.Monad

main :: IO ()
main=do
 [database]<-getArgs
 user<-getEffectiveUserName
 cfg<-B.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict'
 let settings=PG.defaultConnectInfo{PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
 bracket(PG.connect settings) PG.close $ \c->do
   _<-PG.execute c "INSERT INTO deployment(singleton,schema_version,fingerprint) VALUES(1,18,?)" (PG.Only $ fingerprint cfg)
   _<-PG.execute_ c "INSERT INTO custody_check(singleton) VALUES(1)"
   pure ()
 L.withLedger settings (fingerprint cfg) $ \ledger->do
   let fresh=L.ledgerAction ledger $ \c->void(PG.execute_ c "UPDATE custody_check SET checked_revision=revision,checked_at=100,last_error=NULL")
       a n=either (error . T.unpack) id(amount n)
       key=T.replicate 64 "a"
       reserve k currency n destination=void(W.reserve ledger cfg 100 k currency (a n) destination "dedicated accounting contract")
       expect code action=do
         r<-try action :: IO(Either BridgeError ())
         require(case r of Left(BridgeError e)->e==code;_->False) ("expected:"<>code)
       check earned pending=L.ledgerAction ledger $ \c->do
         bs<-L.balances c
         require(M.lookup("Native","earned") bs==Just earned && M.lookup("Native","fee_pending") bs==Just pending) "fee_reservation_balance_mismatch"
   L.ledgerAction ledger $ \c->L.posting c "fixture" "database-only earned fee fixture" [(Native,"earned",1000),(Native,"external",-1000)]
   expect "custody_not_reconciled" (reserve key Native 600 "test-recipient")
   fresh
   expect "fee_withdrawal_profile_mismatch" (void(W.reserve ledger cfg{deploymentId="another-deployment"} 100 key Native (a 600) "test-recipient" "dedicated accounting contract"))
   expect "invalid_fee_withdrawal" (reserve key Sol 600 "test-recipient")
   expect "invalid_fee_withdrawal" (reserve key Native 0 "test-recipient")
   expect "invalid_fee_withdrawal" (reserve key Native (toInteger(units $ maxInput cfg)+1) "test-recipient")
   expect "insufficient_earned_fees" (reserve key Native 1001 "test-recipient")
   reserve key Native 600 "test-recipient"
   check 400 600
   before<-L.ledgerAction ledger L.balances
   reserve key Native 600 "test-recipient"
   expect "fee_withdrawal_conflict" (reserve key Native 600 "changed-recipient")
   after<-L.ledgerAction ledger L.balances
   require(before==after) "fee_reservation_replay_changed_balances"
   expect "custody_not_reconciled" (reserve (T.replicate 64 "b") Native 600 "test-recipient")
   fresh
   expect "insufficient_earned_fees" (reserve (T.replicate 64 "b") Native 600 "test-recipient")
   void(W.cancel ledger key "unsigned cancellation")
   check 1000 0
   beforeCancel<-L.ledgerAction ledger L.balances
   void(W.cancel ledger key "unsigned cancellation")
   expect "fee_withdrawal_cancellation_conflict" (void(W.cancel ledger key "changed reason"))
   afterCancel<-L.ledgerAction ledger L.balances
   require(beforeCancel==afterCancel) "fee_cancellation_replay_changed_balances"
   fresh
   L.ledgerAction ledger $ \c->void(PG.execute_ c "UPDATE deployment SET paused=0")
   expect "fee_withdrawal_requires_pause" (reserve (T.replicate 64 "c") Native 1 "test-recipient")
 putStrLn "Fee funding contract passed: freshness/pause, asset/capital bounds, immutable terms, no double reservation, cancellation and exact replay; no chain calls."
