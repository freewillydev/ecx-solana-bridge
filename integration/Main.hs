{-# LANGUAGE DataKinds, GADTs, KindSignatures, MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies, FlexibleInstances, TypeOperators #-}
module Main (main) where

import Bridge.API (PauseRequest(..))
import Bridge.Types (Availability(..))
import Bridge.Web (runUnix, asHandler)
import Control.Exception (bracket)
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import qualified Opaleye as O
import Servant
import System.Environment (getArgs)
import System.Exit (die)

-- This integration executable has no chain transport or signer capability.
-- The status record is real PostgreSQL state, not a simulated financial ledger.
data Severity = Safe | Critical
class Operation (s :: Severity) (op :: Type -> Type) | op -> s where
  command :: op a -> DSL s a

data SafeOperation a where
  ReadReadiness :: SafeOperation Availability

data CriticalOperation a where
  SetPause :: Text -> CriticalOperation Availability

data DSL (s :: Severity) a where
  Readiness :: DSL 'Safe Availability
  Pause :: Text -> DSL 'Critical Availability

instance Operation 'Safe SafeOperation where
  command ReadReadiness = Readiness
instance Operation 'Critical CriticalOperation where
  command (SetPause reason) = Pause reason

data Request (s :: Severity) a where
  Request :: Operation s op => op a -> Request s a
resolve :: Request s a -> DSL s a
resolve (Request op) = command op

-- No arbitrary IO, callbacks, SQL or customer-supplied worker commands.
data AdminDSL a where
  SafeCommand :: DSL 'Safe a -> AdminDSL a
  PauseCommand :: DSL 'Critical Availability -> AdminDSL Availability

type API = "health" :> Get '[JSON] Availability
      :<|> "pause" :> ReqBody '[JSON] PauseRequest :> Post '[JSON] Availability

server :: ServerT API AdminDSL
server = SafeCommand (resolve (Request ReadReadiness))
    :<|> (\request -> PauseCommand (resolve (Request (SetPause (T.take 120 (pauseReason request))))))

-- Constructors stay private to this executable. The safe transaction is also
-- enforced read-only by PostgreSQL; it cannot update even this status row.
newtype SafeContext = SafeContext PG.Connection
newtype CriticalContext = CriticalContext PG.Connection

statusTable :: O.Table (O.Field O.SqlText) (O.Field O.SqlText)
statusTable = O.table "bridge_integration_status" (O.requiredTableField "reason")

readStatus :: PG.Connection -> IO Availability
readStatus connection = do
  reasons <- O.runSelect connection (O.selectTable statusTable) :: IO [Text]
  case reasons of
    [reason] -> pure (Availability (T.null reason) reason)
    _ -> die "integration status requires exactly one row"

evalSafe :: SafeContext -> DSL 'Safe a -> IO a
evalSafe (SafeContext connection) Readiness =
  Tx.withTransactionMode (Tx.TransactionMode Tx.ReadCommitted Tx.ReadOnly) connection (readStatus connection)

evalCritical :: CriticalContext -> DSL 'Critical a -> IO a
evalCritical (CriticalContext connection) (Pause reason) = PG.withTransaction connection $ do
  count <- O.runUpdate connection O.Update
    { O.uTable = statusTable, O.uUpdateWith = const (O.sqlStrictText reason)
    , O.uWhere = const (O.sqlBool True), O.uReturning = O.rCount }
  if count == 1 then readStatus connection else die "integration status update failed"

-- Sole critical evaluation site. Handlers have already produced DSL values.
interpret :: AdminDSL a -> Handler a
interpret plan = asHandler $ bracket (PG.connectPostgreSQL "") PG.close $ \connection ->
  case plan of
    SafeCommand operation -> evalSafe (SafeContext connection) operation
    PauseCommand operation -> evalCritical (CriticalContext connection) operation

main :: IO ()
main = getArgs >>= \case
  [socketPath] -> bracket (PG.connectPostgreSQL "") PG.close $ \connection -> do
    -- Isolated development schema; DDL belongs to maintenance, not DSL routes.
    _ <- PG.execute_ connection "CREATE TABLE IF NOT EXISTS bridge_integration_status (singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), reason text NOT NULL)"
    _ <- PG.execute_ connection "INSERT INTO bridge_integration_status (reason) VALUES ('integration_pending') ON CONFLICT (singleton) DO NOTHING"
    -- A fresh connection per evaluation prevents overlapping transactions.
    runUnix socketPath 0o600 (serve (Proxy :: Proxy API) (hoistServer (Proxy :: Proxy API) interpret server))
  _ -> die "Usage: ecx-postgres-seam PRIVATE_SOCKET (libpq PG* settings; dedicated integration database)"
