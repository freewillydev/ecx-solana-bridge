module Main (main) where

import Bridge.Config
import Bridge.RPC (newRpcManager)
import Bridge.Native (nativeIdentity)
import Bridge.Recovery (reconcileNativeLocksWith)
import Bridge.Types (require)
import Bridge.Postgres.Ledger (withLedger, readiness)
import qualified Bridge.Postgres.Observer as Observer
import qualified Bridge.Postgres.Custody as Custody
import Bridge.Observer (epochSeconds)
import Bridge.Settlement (realPaymentTransport,readSavedPayment,PaymentTransport(..))
import Bridge.Ledger (Attempt(..),PaymentCosts)
import Bridge.Postgres.PaymentStore (Store(..))
import qualified Bridge.Postgres.Settlement as Settlement
import Bridge.Postgres.Schema
import Bridge.Postgres.Ledger (ledgerAction)
import Bridge.RPC (fieldValue)
import Data.Aeson (eitherDecodeStrict')
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Opaleye as O
import Control.Monad (forM_)
import qualified Bridge.Postgres.Reconciliation as Reconciliation
import Bridge.Types (reject)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Database.PostgreSQL.Simple as PG
import System.Environment (getArgs)
import System.Exit (die)
import System.Posix.User (getEffectiveUserName)

-- Read real chains and mutate only the imported PostgreSQL journal. No payment
-- engine, signer, address allocation or broadcast function is invoked here.
-- Native lock recovery may restore advisory locks from durable saved records.
main :: IO ()
main = getArgs >>= \case
  ["native-locks",configPath,database]->do
    require (database=="ecx_bridge_import") "isolated_import_database_required"
    cfg <- loadConfig configPath
    user <- getEffectiveUserName
    let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectDatabase=database,PG.connectUser=user}
    manager <- newRpcManager
    withLedger settings (fingerprint cfg) $ \ledger->do
      let transport=(realPaymentTransport manager cfg (const $ reject "unexpected_lock_backup"))
            {paymentIdentity=nativeIdentity manager cfg >> pure ()}
      result <- reconcileNativeLocksWith transport cfg (Store ledger)
      LBS.putStrLn (encode result)
      failure <- fieldValue "error" result :: IO (Maybe Text)
      require (failure==Nothing) "native_lock_acceptance_failed"
  [configPath,database]->do
    require (database=="ecx_bridge_import") "isolated_import_database_required"
    cfg <- loadConfig configPath
    user <- getEffectiveUserName
    let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectDatabase=database,PG.connectUser=user}
    manager <- newRpcManager
    withLedger settings (fingerprint cfg) $ \ledger->do
      health <- Observer.observeOnce manager cfg ledger
      now <- epochSeconds
      snapshot <- Custody.readSnapshot cfg ledger now False
      let transport=realPaymentTransport manager cfg (const $ reject "unexpected_reconciliation_backup")
      historical <- ledgerAction ledger $ \connection->do
        rows <- O.runSelect connection $ do
          a <- O.selectTable attemptsTable
          i <- O.selectTable intentsTable
          O.where_ (attemptsIntentId a O..== intentsId i O..&& attemptsState a O..== O.sqlStrictText "settled")
          pure(a,intentsChain i)
          :: IO [(Attempts,Text)]
        pure rows
      forM_ historical $ \(a,chain)->do
        let attempt=Attempt (attemptsTxid a) (attemptsIntentId a) chain (attemptsSignedBytes a) (attemptsPolicyJson a) (attemptsFeeLimit a) (attemptsState a) (attemptsCriticalSequence a)
        _ <- readSavedPayment transport cfg (Store ledger) attempt
        saved <- maybe (reject "missing_settlement") (either (const $ reject "invalid_settlement") pure . eitherDecodeStrict' . TE.encodeUtf8) (attemptsObservationJson a)
        costs <- fieldValue "costs" saved :: IO PaymentCosts
        proof <- fieldValue "proof" saved
        Settlement.recordSettlement ledger (attemptsTxid a) costs proof
      nativeLocks <- reconcileNativeLocksWith transport {paymentIdentity=nativeIdentity manager cfg >> pure ()} cfg (Store ledger)
      lockError <- fieldValue "error" nativeLocks :: IO (Maybe Text)
      require (lockError==Nothing) "native_lock_acceptance_failed"
      reconciliation <- Reconciliation.reconcileCustodyWith epochSeconds transport cfg ledger
      paused <- readiness ledger
      LBS.putStrLn (encode (object ["nativeLocks" .= nativeLocks,"scannerHealth" .= health,"readiness" .= paused,"paymentsEnabled" .= False,"custodyRevision" .= Custody.revision snapshot,"bookedCustody" .= Custody.totals snapshot,"custodyReconciliation" .= reconciliation,"verifiedHistoricalSettlements" .= length historical]))
  _->die "Usage: ecx-postgres-scan-check PRIVATE_CONFIG ecx_bridge_import"
