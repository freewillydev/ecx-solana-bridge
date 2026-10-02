-- Database-only contract; fixture observations are not live-chain evidence.
module Main where
import Bridge.Types
import qualified Bridge.Postgres.Ledger as L
import qualified Bridge.Postgres.Treasury as Treasury
import qualified Database.PostgreSQL.Simple as PG
import Data.Aeson
import qualified Data.ByteString.Lazy as B
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import System.Posix.User
import Control.Exception
import Control.Monad

main :: IO ()
main = do
  user<-getEffectiveUserName
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase="ecx_treasury_contract"}
  bracket (PG.connect settings) PG.close $ \c->do
    _<-PG.execute_ c "INSERT INTO deployment(singleton,schema_version,fingerprint) VALUES(1,18,'treasury-contract')"
    _<-PG.execute_ c "INSERT INTO custody_check(singleton) VALUES(1)"
    pure ()
  L.withLedger settings "treasury-contract" $ \ledger->do
    let fresh=L.ledgerAction ledger $ \c->void(PG.execute_ c "UPDATE custody_check SET checked_revision=revision,checked_at=100,last_error=NULL")
        fixture = L.ledgerAction ledger $ \c->do
          let evidence=object["proof" .= object["delta" .= ("10000"::Text),"failed" .= False]]
              raw=TE.decodeUtf8 $ B.toStrict $ encode evidence
          _<-PG.execute c "INSERT INTO observation_evidence VALUES('fixture','SolanaOperating','fixture',?)" (PG.Only raw)
          _<-PG.execute_ c "INSERT INTO chain_events VALUES('SolanaOperating','fixture','unmatched_incoming','slot','fixture',100,100,0)"
          _<-PG.execute_ c "INSERT INTO deposits(id,asset,amount,anchor,first_seen,confirmations,eligible) VALUES('sol-operating:fixture','Sol',10000,'slot',100,1,1)"
          L.posting c "fixture" "database-only fixture" [(Sol,"external",-10000),(Sol,"unallocated",10000)]
        allocate split reason=void(Treasury.allocate ledger 100 "sol-operating:fixture" split reason)
        expect code action=do
          result<-try action :: IO(Either BridgeError ())
          require(case result of Left(BridgeError actual)->actual==code;_->False) ("expected:"<>code)
    n<-either reject pure(amount 10000)
    fixture
    expect "custody_not_reconciled" (allocate [("operating",n)] "operator capital")
    fresh
    expect "sol_reserved_for_operating" (allocate [("float",n)] "operator capital")
    allocate [("operating",n)] "operator capital"
    before<-L.ledgerAction ledger L.balances
    allocate [("operating",n)] "operator capital"
    expect "treasury_allocation_conflict" (allocate [("operating",n)] "different owner")
    after<-L.ledgerAction ledger L.balances
    require(before==after) "treasury_replay_changed_balances"
    putStrLn "PostgreSQL treasury contract passed: fresh custody, SOL restriction, allocation, replay and conflict; no chain calls."
