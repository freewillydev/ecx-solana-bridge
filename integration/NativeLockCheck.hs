{-# LANGUAGE ScopedTypeVariables #-}
-- Real Signet/PostgreSQL acceptance driver. Excluded from installed release.
-- Stage a real eligible obligation and interrupt before signing. Never sends.
module Main (main) where
import Bridge.Config
import Bridge.Types
import Bridge.Native (nativeIdentity)
import Bridge.Payment
import Bridge.Recovery
import Bridge.Settlement
import qualified Bridge.Ledger as D
import Bridge.Postgres.Ledger
import Bridge.Postgres.PaymentStore (Store(..))
import Bridge.RPC
import Control.Exception (try,finally)
import qualified Bridge.Postgres.Observer as Observer
import qualified Bridge.Postgres.Reconciliation as Reconciliation
import qualified Bridge.Postgres.Startup as Startup
import Bridge.Observer (epochSeconds)
import Data.Aeson (encode,object,(.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import System.Environment (getArgs,getEnv)
import System.Exit (die)
import System.Posix.User (getEffectiveUserName)
import qualified Database.PostgreSQL.Simple as PG
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  (mode,path,intent) <- case args of
    ["stage",cfg,oid]->pure("stage"::String,cfg,T.pack oid)
    ["verify",cfg,oid]->pure("verify"::String,cfg,T.pack oid)
    _->die "Usage: ecx-postgres-native-lock-check stage|verify PRIVATE_CONFIG OBLIGATION_ID (PG*; exclusive stopped worker)"
  cfg <- loadConfig path
  require (profile cfg==L2LSignetDevnet && not(backupRequired cfg)) "public_test_profile_required"
  database <- getEnv "PGDATABASE"
  require (database=="ecx_bridge_runtime") "actual_test_runtime_database_required"
  host <- getEnv "PGHOST"
  require (host=="/tmp/ecx-pg-seam") "private_test_socket_required"
  port <- getEnv "PGPORT" >>= maybe (reject "invalid_postgres_port") pure . readMaybe
  require (port==29436) "private_test_port_required"
  user <- getEffectiveUserName
  manager <- newRpcManager
  let settings=PG.defaultConnectInfo {PG.connectHost=host,PG.connectPort=port,PG.connectDatabase=database,PG.connectUser=user}
      fullTransport=realPaymentTransport manager cfg (const $ reject "unexpected_acceptance_backup")
      transport=fullTransport {paymentIdentity=nativeIdentity manager cfg >> pure ()}
      -- Fault injection is confined to the pre-sign boundary. Every permitted
      -- identity, planning, funding, decoding and prevout call is a real RPC.
      unsignedCall wallet method params
        | method=="walletprocesspsbt" = reject "acceptance_stopped_before_signing"
        | method `elem` ["sendrawtransaction","signrawtransactionwithwallet","signrawtransactionwithkey"] = reject "acceptance_signing_or_send_forbidden"
        | otherwise = paymentNative transport wallet method params
  withLedger settings (fingerprint cfg) $ \ledger->do
    let store=Store ledger
    case mode of
      "stage"->(do
        ob <- paymentObligation store intent
        require (D.obligationAsset ob=="Native") "native_obligation_required"
        attempts <- preparationAttempts store
        require (null [a | a<-attempts,D.attemptIntent a==intent]) "acceptance_attempt_already_exists"
        pending <- preparationPending store
        require (null pending) "acceptance_other_preparation_exists"
        paymentIdentity fullTransport
        _ <- Observer.observeOnce manager cfg ledger
        _ <- reconcilePaymentsWith fullTransport cfg store
        _ <- Reconciliation.reconcileCustodyWith epochSeconds fullTransport cfg ledger
        now <- epochSeconds
        Startup.resumeAfterChecks cfg ledger now
        recheckSourceWith fullTransport cfg store ob
        result <- try (prepareNativeWith unsignedCall cfg store ob) :: IO(Either BridgeError T.Text)
        case result of
          Left(BridgeError "acceptance_stopped_before_signing")->pure ()
          Left(BridgeError code)->reject code
          Right _->reject "acceptance_unexpected_signed_attempt"
        saved <- preparationPending store
        require (case saved of [p]->D.obligationId(D.preparationObligation p)==intent && D.preparationChain p=="Native" && D.preparationDraft p/=Nothing; _->False) "acceptance_draft_not_preserved"
        after <- preparationAttempts store
        require (null [a | a<-after,D.attemptIntent a==intent]) "acceptance_unexpected_attempt"
        state <- readiness ledger
        require (not(available state)) "acceptance_not_paused"
        LBS.putStrLn(encode(object["obligation" .= intent,"unsignedDraftSaved" .= True,"paused" .= True,"signedOrSent" .= False]))) `finally` pause ledger "acceptance_native_draft_review"
      _->do
        pending <- preparationPending store
        require (case pending of [p]->D.obligationId(D.preparationObligation p)==intent && D.preparationChain p=="Native" && D.preparationDraft p/=Nothing; _->False) "acceptance_draft_not_preserved"
        before <- preparationAttempts store
        state <- readiness ledger
        require (not(available state)) "pause_before_acceptance"
        result <- reconcileNativeLocksWith transport cfg store
        failure <- fieldValue "error" result :: IO(Maybe T.Text)
        maybe (pure ()) reject failure
        after <- preparationAttempts store
        require (before==after) "acceptance_attempt_changed"
        require (null [a | a<-after,D.attemptIntent a==intent]) "acceptance_unexpected_attempt"
        LBS.putStrLn(encode result)
