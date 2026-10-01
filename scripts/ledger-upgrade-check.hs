{-# LANGUAGE OverloadedStrings #-}
-- Private maintenance diagnostic. Stop the worker and retain a verified backup
-- first. Opening applies the embedded migrations and leaves intake paused.
-- There are no chain, wallet, signing, treasury or resume calls in this program.
import Bridge.Config
import Bridge.Ledger
import Bridge.Types
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Database.SQLite.Simple
import System.Directory (doesFileExist)
import System.Environment (getArgs)

main :: IO ()
main=do
  path<-getArgs >>= \args->case args of [p]->pure p; _->fail "ledger-upgrade-check CONFIG"
  c<-loadConfig path
  exists<-doesFileExist (dbPath c)
  require exists "existing_ledger_required"
  withLedger (dbPath c) (fingerprint c) $ \ledger->do
    meta<-ledgerAction ledger $ \db->query_ db "SELECT schema_version,critical_sequence,backup_sequence,paused FROM deployment" :: IO [(Int,Int64,Int64,Bool)]
    states<-ledgerAction ledger $ \db->query_ db "SELECT status,COUNT(*) FROM orders GROUP BY status ORDER BY status" :: IO [(Text,Int)]
    LBS.putStrLn $ encode $ object ["deployment" .= meta,"ordersByStatus" .= states,"chainCalls" .= (0::Int)]
