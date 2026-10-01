module Main (main) where

import Bridge.Config
import Bridge.RPC (newRpcManager)
import Bridge.Types (require)
import Bridge.Postgres.Ledger (withLedger, readiness)
import qualified Bridge.Postgres.Observer as Observer
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Database.PostgreSQL.Simple as PG
import System.Environment (getArgs)
import System.Exit (die)
import System.Posix.User (getEffectiveUserName)

-- Read real chains and mutate only the imported PostgreSQL journal. No payment
-- engine, signer, address allocation or broadcast function is invoked here.
main :: IO ()
main = getArgs >>= \case
  [configPath,database]->do
    require (database=="ecx_bridge_import") "isolated_import_database_required"
    cfg <- loadConfig configPath
    user <- getEffectiveUserName
    let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectDatabase=database,PG.connectUser=user}
    manager <- newRpcManager
    withLedger settings (fingerprint cfg) $ \ledger->do
      health <- Observer.observeOnce manager cfg ledger
      paused <- readiness ledger
      LBS.putStrLn (encode (object ["scannerHealth" .= health,"readiness" .= paused,"paymentsEnabled" .= False]))
  _->die "Usage: ecx-postgres-scan-check PRIVATE_CONFIG ecx_bridge_import"
