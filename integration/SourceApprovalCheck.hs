-- Database-only recovery contract. No chain transport, signer or broadcast.
module Main (main) where
import Bridge.Types
import qualified Bridge.Postgres.Ledger as L
import qualified Bridge.Postgres.Source as Source
import Bridge.Ledger (SourceCheck(..),Deposit(..))
import qualified Data.Text as T
import Control.Exception (bracket,try)
import Control.Monad (forM_)
import Data.Aeson (object,(.=))
import Data.Int (Int64)
import Data.Text (Text)
import qualified Database.PostgreSQL.Simple as PG
import System.Posix.User (getEffectiveUserName)

settings :: String -> PG.ConnectInfo
settings user = PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectDatabase="ecx_source_approval_contract",PG.connectUser=user}
identity :: Text
identity = "isolated-source-approval-contract"

expectError :: Text -> IO () -> IO ()
expectError expected action = do
  result <- try action :: IO(Either BridgeError ())
  require (case result of Left(BridgeError code)->code==expected; _->False) ("contract_expected:"<>expected)

-- Fixtures model ledger state only; they are never chain evidence. Raw INSERTs
-- are maintenance/test setup, not a runtime database implementation.
fixture :: L.Ledger -> Text -> Text -> IO Int64
fixture ledger oid prior = L.ledgerAction ledger $ \c->do
  _ <- PG.execute c "INSERT INTO orders(id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,status,deadline,grace_deadline) VALUES(?,?,?,'contract','{}','{}','{}','NeedsReview',100,200)" (oid,oid,oid)
  _ <- PG.execute c "INSERT INTO deposits(id,order_id,asset,amount,anchor,first_seen,confirmations,eligible,allocated) VALUES(?,?,'Native',10000,'database-contract-anchor',100,1,1,1)" (oid,oid)
  _ <- PG.execute c "INSERT INTO obligations(id,order_id,deposit_id,kind,asset,amount,recipient,status) VALUES(?,?,?,'conversion','Wrapped',9900,'database-contract-recipient',?)" (oid,oid,oid,prior)
  work <- Source.sourceWorkHashC c oid
  _ <- PG.execute c "UPDATE deposits SET eligible=0 WHERE id=?" (PG.Only oid)
  Source.recordSourceCheckC c oid $ SourceUnavailable $ object
    ["reason" .= ("source_eligibility_lost"::Text),"reviewedObligations" .= [object["intent" .= oid,"previousStatus" .= prior,"workHash" .= work]]]
  _ <- PG.execute c "UPDATE obligations SET status='review' WHERE id=?" (PG.Only oid)
  _ <- PG.execute c "UPDATE deposits SET eligible=1 WHERE id=?" (PG.Only oid)
  Source.recordSourceCheckC c oid $ SourceRestored $ object["anchor" .= ("database-contract-restoration"::Text)]
  rows <- PG.query c "SELECT critical_sequence FROM source_recoveries WHERE deposit_id=? ORDER BY id DESC LIMIT 1" (PG.Only oid) :: IO[PG.Only Int64]
  case rows of [PG.Only n]->pure n; _->reject "contract_restoration_missing"

fresh :: L.Ledger -> IO ()
fresh ledger = L.ledgerAction ledger $ \c->do
  _ <- PG.execute_ c "UPDATE custody_check SET checked_revision=revision,checked_at=100,last_error=NULL,report_json='{}'"
  pure ()

snapshot :: L.Ledger -> IO (Int64,Int64,Text)
snapshot ledger = L.ledgerAction ledger $ \c->do
  [PG.Only sequenceNo] <- PG.query_ c "SELECT critical_sequence FROM deployment"
  [PG.Only count] <- PG.query_ c "SELECT count(*) FROM source_recovery_approvals"
  [PG.Only states] <- PG.query_ c "SELECT jsonb_agg(to_jsonb(o) ORDER BY id)::text FROM obligations o"
  pure(sequenceNo,count,states)

main :: IO ()
main = do
  user <- getEffectiveUserName
  let connectionSettings=settings user
  bracket (PG.connect connectionSettings) PG.close $ \c->do
    [PG.Only count] <- PG.query_ c "SELECT count(*) FROM deployment" :: IO[PG.Only Int64]
    require (count==0) "fresh_contract_database_required"
    PG.withTransaction c $ do
      _ <- PG.execute c "INSERT INTO deployment(singleton,schema_version,fingerprint) VALUES(1,18,?)" (PG.Only identity)
      _ <- PG.execute_ c "INSERT INTO custody_check(singleton) VALUES(1)"
      pure ()
  L.withLedger connectionSettings identity $ \ledger->do
    forM_ ["ready","paying"] $ \prior->do
      let oid="restore-"<>prior
      restoration <- fixture ledger oid prior
      expectError "custody_not_reconciled" $ Source.recoveryRecord ledger oid restoration 100 "verified contract restoration"
      fresh ledger
      Source.recoveryRecord ledger oid restoration 100 "verified contract restoration"
      L.ledgerAction ledger $ \c->do
        state <- PG.query c "SELECT status FROM obligations WHERE id=?" (PG.Only oid) :: IO[PG.Only Text]
        require (state==[PG.Only prior]) "contract_wrong_restored_state"
      before <- snapshot ledger
      Source.recoveryRecord ledger oid restoration 100 "verified contract restoration"
      expectError "source_approval_conflict" $ Source.recoveryRecord ledger oid restoration 100 "changed reason"
      after <- snapshot ledger
      require (before==after) "contract_replay_mutated_state"
    changed <- fixture ledger "changed-work" "ready"
    L.ledgerAction ledger $ \c->do
      _ <- PG.execute_ c "INSERT INTO intents(id,obligation_id,chain) VALUES('changed-work','changed-work','Solana')"
      pure ()
    fresh ledger
    beforeChanged <- snapshot ledger
    expectError "source_review_work_changed" $ Source.recoveryRecord ledger "changed-work" changed 100 "refuse changed work"
    afterChanged <- snapshot ledger
    require (beforeChanged==afterChanged) "contract_changed_work_mutated_state"
    stale <- fixture ledger "stale-restoration" "ready"
    L.ledgerAction ledger $ \c->Source.recordSourceCheckC c "stale-restoration" $ SourceUnavailable $ object["reason" .= ("later unavailable source"::Text)]
    fresh ledger
    beforeStale <- snapshot ledger
    expectError "source_approval_not_expected" $ Source.recoveryRecord ledger "stale-restoration" stale 100 "refuse obsolete restoration"
    afterStale <- snapshot ledger
    require (beforeStale==afterStale) "contract_stale_restoration_mutated_state"
    candidateRows <- Source.candidates ledger
    require (map depositId candidateRows==["stale-restoration"]) "contract_source_candidate_view_failed"
    let txid=T.replicate 64 "a"
        did="native:"<>txid<>":0"
    L.ledgerAction ledger $ \c->do
      _ <- PG.execute c "INSERT INTO deposits(id,asset,amount,anchor,first_seen,confirmations,eligible) VALUES(?,'Native',10000,'unconfirmed',100,0,0)" (PG.Only did)
      _ <- PG.execute c "INSERT INTO observation_evidence(hash,chain,event_id,evidence_json) VALUES('contract-hash','Native',?,'{}')" (PG.Only txid)
      _ <- PG.execute c "INSERT INTO chain_events(chain,event_id,kind,anchor,evidence_hash,first_seen,last_seen,needs_review) VALUES('Native',?,'incoming','unconfirmed','contract-hash',100,100,0)" (PG.Only txid)
      pure ()
    pendingSources <- Source.candidates ledger
    source <- case filter ((==did).depositId) pendingSources of [row]->pure row; _->reject "contract_native_source_missing"
    beforeFence <- snapshot ledger
    expectError "source_recovery_changed" $ Source.recordCheck ledger source {depositAnchor="changed snapshot"} (SourceUnavailable $ object["reason" .= ("contract"::Text)])
    expectError "source_recovery_scan_not_current" $ Source.recordCheck ledger source (SourcePending $ object["observationHash" .= ("wrong-hash"::Text)])
    Source.recordCheck ledger source (SourcePending $ object["observationHash" .= ("contract-hash"::Text)])
    afterFence <- snapshot ledger
    require (beforeFence==afterFence) "contract_source_fence_mutated_financial_state"
    L.ledgerAction ledger $ \c->do
      history <- PG.query c "SELECT count(*) FROM source_recoveries WHERE deposit_id=?" (PG.Only did) :: IO[PG.Only Int64]
      require (history==[PG.Only 0]) "contract_ordinary_pending_journaled"

  L.withLedger connectionSettings identity $ \ledger->do
    L.ledgerAction ledger $ \c->do
      rows <- PG.query_ c "SELECT id,status FROM obligations ORDER BY id" :: IO[(Text,Text)]
      require (lookup "restore-ready" rows==Just "ready" && lookup "restore-paying" rows==Just "paying" && lookup "changed-work" rows==Just "review" && lookup "stale-restoration" rows==Just "review") "contract_restart_changed_state"
  putStrLn "PostgreSQL source approval: ready/paying restoration, freshness, replay, conflict, changed-work/stale refusal, candidate view, source/evidence fences and reopen passed; database-only contract"
