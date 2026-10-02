{-# LANGUAGE ScopedTypeVariables,OverloadedStrings #-}
-- Real Signet/Devnet PostgreSQL acceptance driver. Excluded from installed release.
-- Stage a real eligible obligation at an unsigned or signed boundary. Never sends.
module Main (main) where
import Bridge.Config
import Bridge.Types
import Bridge.Native (nativeIdentity)
import Bridge.SolanaHelper (invokeHelper)
import Bridge.Payment
import Bridge.Recovery
import Bridge.Settlement
import qualified Bridge.Ledger as D
import Bridge.Postgres.Ledger
import qualified Bridge.Postgres.Fence as Fence
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
import System.Environment (getArgs,getEnv,lookupEnv)
import System.Exit (die)
import System.Posix.User (getEffectiveUserName)
import qualified Database.PostgreSQL.Simple as PG
import qualified Data.Text.Encoding as TE
import Data.Maybe (fromMaybe)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  (mode,path,intent) <- case args of
    ["stage",cfg,oid]->pure("stage"::String,cfg,T.pack oid)
    ["verify",cfg,oid]->pure("verify"::String,cfg,T.pack oid)
    ["stage-signed",cfg,oid]->pure("stage-signed"::String,cfg,T.pack oid)
    ["verify-signed",cfg,oid]->pure("verify-signed"::String,cfg,T.pack oid)
    ["stage-solana-signed",cfg,oid]->pure("stage-solana-signed"::String,cfg,T.pack oid)
    ["verify-solana-signed",cfg,oid]->pure("verify-solana-signed"::String,cfg,T.pack oid)
    _->die "Usage: ecx-postgres-native-lock-check stage|verify|stage-signed|verify-signed|stage-solana-signed|verify-solana-signed PRIVATE_CONFIG OBLIGATION_ID (PG*; exclusive stopped worker)"
  let solanaMode=mode `elem` ["stage-solana-signed","verify-solana-signed"]
      signedStage=mode `elem` ["stage-signed","stage-solana-signed"]
      signedVerify=mode `elem` ["verify-signed","verify-solana-signed"]
      expectedChain=if solanaMode then "Solana" else "Native"
  cfg <- loadConfig path
  require (profile cfg==L2LSignetDevnet && not(backupRequired cfg)) "public_test_profile_required"
  require (not solanaMode || solanaVerifierRpc cfg/=Nothing) "independent_rpc_required"
  database <- getEnv "PGDATABASE"
  host <- getEnv "PGHOST"
  port <- getEnv "PGPORT" >>= maybe (reject "invalid_postgres_port") pure . readMaybe
  require (port==29436) "private_test_port_required"
  user <- getEffectiveUserName
  pgUser <- fromMaybe user <$> lookupEnv "PGUSER"
  let local = database=="ecx_bridge_runtime" && host=="/tmp/ecx-pg-seam" && pgUser==user
      installed = database=="ecx_bridge" && host=="/run/ecx-postgres" && user=="ecx-worker" && pgUser=="ecx_worker"
        && deploymentId cfg=="fresh-treasury-acceptance" && custodyOwner cfg=="6vKbKHaYS393gQdjKysZFuyvn6cZ5p4vSwK2kMsQFuZY"
  require (local || installed) "dedicated_test_runtime_required"
  manager <- newRpcManager
  let settings=PG.defaultConnectInfo {PG.connectHost=host,PG.connectPort=port,PG.connectDatabase=database,PG.connectUser=pgUser}
      fullTransport=realPaymentTransport manager cfg (const $ reject "unexpected_acceptance_backup")
      transport=fullTransport {paymentIdentity=nativeIdentity manager cfg >> pure ()}
      -- Fault injection is confined to the pre-sign boundary. Every permitted
      -- identity, planning, funding, decoding and prevout call is a real RPC.
      unsignedCall wallet method params
        | method=="walletprocesspsbt" && mode=="stage" = reject "acceptance_stopped_before_signing"
        | method `elem` ["sendrawtransaction","signrawtransactionwithwallet","signrawtransactionwithkey"] = reject "acceptance_signing_or_send_forbidden"
        | otherwise = paymentNative transport wallet method params
  let owns action
        | installed || signedStage || signedVerify = do
            directory <- Fence.fenceDirectory
            Fence.withFence directory (fingerprint cfg) $ \guard->
              withGuardedLedger settings (fingerprint cfg) (Just guard) action
        | otherwise = withLedger settings (fingerprint cfg) action
  owns $ \ledger->do
    let store=Store ledger
    case mode of
      staging | staging=="stage" || signedStage->(do
        paymentIdentity fullTransport
        _ <- Observer.observeOnce manager cfg ledger
        ob <- paymentObligation store intent
        require (D.obligationAsset ob==(if solanaMode then "Wrapped" else "Native")) "acceptance_destination_chain_mismatch"
        attempts <- preparationAttempts store
        require (null [a | a<-attempts,D.attemptIntent a==intent]) "acceptance_attempt_already_exists"
        pending <- preparationPending store
        require (null pending) "acceptance_other_preparation_exists"
        _ <- reconcilePaymentsWith fullTransport cfg store
        _ <- Reconciliation.reconcileCustodyWith epochSeconds fullTransport cfg ledger
        now <- epochSeconds
        Startup.resumeAfterChecks cfg ledger now
        recheckSourceWith fullTransport cfg store ob
        let solanaCall method params
              | method `elem` ["sendTransaction","sendRawTransaction"] = reject "acceptance_send_forbidden"
              | otherwise = paymentSolana fullTransport method params
        result <- try (if solanaMode
          then prepareSolanaWith solanaCall (invokeHelper cfg) cfg store ob
          else prepareNativeWith unsignedCall cfg store ob) :: IO(Either BridgeError T.Text)
        case (mode,result) of
          ("stage",Left(BridgeError "acceptance_stopped_before_signing"))->pure ()
          (_,Right _) | signedStage->pure ()
          (_,Left(BridgeError code))->reject code
          _->reject "acceptance_unexpected_signed_attempt"
        saved <- preparationPending store
        after <- preparationAttempts store
        if mode=="stage" then do
          require (case saved of [p]->D.obligationId(D.preparationObligation p)==intent && D.preparationChain p=="Native" && D.preparationDraft p/=Nothing; _->False) "acceptance_draft_not_preserved"
          require (null [a | a<-after,D.attemptIntent a==intent]) "acceptance_unexpected_attempt"
        else do
          require (null saved) "acceptance_signed_draft_still_pending"
          require (case (result,filter ((==intent) . D.attemptIntent) after) of
            (Right txid,[a])->D.attemptId a==txid && D.attemptChain a==expectedChain && D.attemptState a=="signed" && D.attemptSequence a==Nothing
            _->False) "acceptance_signed_attempt_not_preserved"
          pause ledger "acceptance_signed_native_review"
        state <- readiness ledger
        require (not(available state)) "acceptance_not_paused"
        LBS.putStrLn(encode(object["obligation" .= intent,"unsignedDraftSaved" .= (mode=="stage"),"signedAttemptSaved" .= signedStage,"paused" .= True,"broadcast" .= False]))) `finally` pause ledger "acceptance_native_draft_review"
      _ | signedVerify->do
        state <- readiness ledger
        require (not(available state)) "pause_before_acceptance"
        before <- preparationAttempts store
        ob <- paymentObligation store intent
        attempt <- case filter ((==intent) . D.attemptIntent) before of
          [a] | D.attemptChain a==expectedChain && D.attemptState a=="signed" && D.attemptSequence a==Nothing->pure a
          _->reject "acceptance_signed_attempt_required"
        let snapshot=ledgerAction ledger $ \connection->do
              [PG.Only value] <- PG.query_ connection "SELECT jsonb_build_object('sequence',(SELECT critical_sequence FROM deployment),'attempts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY txid) FROM attempts a),'preparations',(SELECT jsonb_agg(to_jsonb(p) ORDER BY intent_id,generation) FROM preparations p),'intents',(SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM intents i),'obligations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY id) FROM obligations o),'orders',(SELECT jsonb_agg(to_jsonb(o) ORDER BY id) FROM orders o),'reservations',(SELECT jsonb_agg(to_jsonb(r) ORDER BY order_id,asset) FROM reservations r),'operating',(SELECT jsonb_agg(to_jsonb(r) ORDER BY order_id,kind) FROM operating_reservations r),'fees',(SELECT jsonb_agg(to_jsonb(f) ORDER BY intent_id) FROM fee_reservations f),'postings',(SELECT jsonb_agg(to_jsonb(p) ORDER BY event_id,account) FROM postings p))::text"
              pure (value::T.Text)
        prior <- snapshot
        txid <- if solanaMode
          then prepareSolanaWith (\_ _->reject "acceptance_replay_rpc_forbidden")
            (\_->reject "acceptance_replay_signer_forbidden") cfg store ob
          else prepareNativeWith (\_ _ _->reject "acceptance_replay_rpc_forbidden") cfg store ob
        after <- preparationAttempts store
        final <- snapshot
        require (txid==D.attemptId attempt && before==after && prior==final) "acceptance_signed_replay_changed_state"
        LBS.putStrLn(encode(object["transaction" .= txid,"savedBytesSha256" .= digest(TE.encodeUtf8 $ D.attemptBytes attempt),"signedBytesAndFinancialStateUnchanged" .= True,"signerOrRpcCalled" .= False,"broadcast" .= False,"paused" .= True]))
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
