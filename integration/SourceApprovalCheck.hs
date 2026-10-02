-- Database-only recovery contract. No chain transport, signer or broadcast.
module Main (main) where
import Bridge.Types
import Bridge.Config (Config,fingerprint)
import qualified Bridge.Postgres.Replacement as Replacement
import qualified Bridge.Postgres.PaymentStore as PaymentStore
import Bridge.NativePayment
import Bridge.RPC (fieldValue)
import qualified Bridge.Postgres.NativeFamily as Family
import qualified Data.ByteString as BS
import qualified Bridge.Postgres.Ledger as L
import qualified Bridge.Postgres.Source as Source
import qualified Bridge.Postgres.NativeRecovery as NativeRecovery
import qualified Bridge.Postgres.LossCover as LossCover
import qualified Bridge.Postgres.Settlement as Settlement
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)
import Bridge.Ledger (LossCapital(..),SourceCheck(..),Deposit(..),Attempt(..),PaymentCosts(..),NativeSettlementCheck(..))
import qualified Data.Text as T
import Control.Exception (bracket,try)
import Control.Monad (forM_)
import Data.Aeson (object,(.=),encode,ToJSON,eitherDecodeStrict')
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as TE
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
  [PG.Only states] <- PG.query_ c "SELECT jsonb_build_object('obligations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY id) FROM obligations o),'attempts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY txid) FROM attempts a),'nativeRecoveries',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM native_payment_recoveries r),'postings',(SELECT jsonb_agg(to_jsonb(p) ORDER BY event_id,account) FROM postings p))::text"
  pure(sequenceNo,count,states)

main :: IO ()
main = do
  user <- getEffectiveUserName
  database <- fromMaybe "ecx_source_approval_contract" <$> lookupEnv "ECX_SOURCE_CONTRACT_DATABASE"
  let connectionSettings=(settings user) {PG.connectDatabase=database}
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
    let sourceTxid=T.replicate 64 "a"
        did="native:"<>sourceTxid<>":0"
    L.ledgerAction ledger $ \c->do
      _ <- PG.execute c "INSERT INTO deposits(id,asset,amount,anchor,first_seen,confirmations,eligible) VALUES(?,'Native',10000,'unconfirmed',100,0,0)" (PG.Only did)
      _ <- PG.execute c "INSERT INTO observation_evidence(hash,chain,event_id,evidence_json) VALUES('contract-hash','Native',?,'{}')" (PG.Only sourceTxid)
      _ <- PG.execute c "INSERT INTO chain_events(chain,event_id,kind,anchor,evidence_hash,first_seen,last_seen,needs_review) VALUES('Native',?,'incoming','unconfirmed','contract-hash',100,100,0)" (PG.Only sourceTxid)
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

    -- Finality-only records use synthetic database fixtures, never signed bytes
    -- or transport responses. No principal is posted by these recovery records.
    zero <- either reject pure(amount 0)
    fee <- either reject pure(amount 141)
    let txid=T.replicate 64 "b"
        oid="native-finality"
        proof anchor depth=jsonText $ object["txid" .= txid,"blockhash" .= (anchor::Text),"requiredDepth" .= (depth::Int)]
        costs=PaymentCosts fee zero
        old=jsonText $ object["costs" .= costs,"proof" .= proof "block-a" 1]
        expected=Attempt txid oid "Native" "database-fixture-not-signed" "{}" 1000 "settled" (Just 1)
    L.ledgerAction ledger $ \c->do
      _ <- PG.execute c "INSERT INTO orders(id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,status,deadline,grace_deadline) VALUES(?,?,?,'contract','{}','{}','{}','Paid',100,200)" (oid,oid,oid)
      _ <- PG.execute c "INSERT INTO deposits(id,order_id,asset,amount,anchor,first_seen,confirmations,eligible,allocated) VALUES(?,?,'Wrapped',10000,'database-contract',100,1,1,1)" (oid,oid)
      _ <- PG.execute c "INSERT INTO obligations(id,order_id,deposit_id,kind,asset,amount,recipient,status) VALUES(?,?,?,'conversion','Native',9900,'contract-recipient','paid')" (oid,oid,oid)
      _ <- PG.execute c "INSERT INTO intents(id,obligation_id,chain,resolved) VALUES(?,?,'Native',0)" (oid,oid)
      _ <- PG.execute c "INSERT INTO preparations(intent_id,generation,policy_json) VALUES(?,0,'{}')" (PG.Only oid)
      _ <- PG.execute c "INSERT INTO attempts(txid,intent_id,signed_bytes,policy_json,fee_limit,state,critical_sequence,observation_json) VALUES(?,?,'database-fixture-not-signed','{}',1000,'settled',1,?)" (txid,oid,old)
      _ <- PG.execute c "UPDATE intents SET resolved=1 WHERE id=?" (PG.Only oid)
      _ <- PG.execute c "INSERT INTO observation_evidence(hash,chain,event_id,evidence_json) VALUES('finality-contract-hash','Native',?,?)" (txid,jsonText $ object["proof" .= object["confirmations" .= (2::Int)]])
      _ <- PG.execute c "INSERT INTO chain_events(chain,event_id,kind,anchor,evidence_hash,first_seen,last_seen,needs_review) VALUES('Native',?,'outgoing','block-a','finality-contract-hash',100,100,0)" (PG.Only txid)
      pure ()
    NativeRecovery.candidates ledger >>= \rows->require (null rows) "contract_healthy_finality_candidate"
    NativeRecovery.recordCheck ledger expected old NativeSettlementConfirming
    beforeReplay <- snapshot ledger
    NativeRecovery.recordCheck ledger expected old NativeSettlementConfirming
    afterReplay <- snapshot ledger
    require (beforeReplay==afterReplay) "contract_finality_replay_mutated_state"
    NativeRecovery.candidates ledger >>= \rows->require (rows==[expected]) "contract_finality_review_missing"
    NativeRecovery.recordCheck ledger expected old (NativeSettlementUnavailable "contract RPC unavailable")
    NativeRecovery.observation ledger txid >>= \saved->require (saved==old) "contract_uncertainty_changed_payment"
    L.ledgerAction ledger $ \c->do
      _ <- PG.execute c "UPDATE chain_events SET anchor='block-b' WHERE chain='Native' AND event_id=?" (PG.Only txid)
      pure ()
    NativeRecovery.recordCheck ledger expected old (NativeSettlementReconfirmed costs $ proof "block-b" 1)
    updated <- NativeRecovery.observation ledger txid
    beforeConfirmedReplay <- snapshot ledger
    expectError "native_settlement_changed" $ NativeRecovery.recordCheck ledger expected old NativeSettlementConfirming
    NativeRecovery.recordCheck ledger expected updated (NativeSettlementReconfirmed costs $ proof "block-b" 1)
    expectError "native_recovery_policy_changed" $ NativeRecovery.recordCheck ledger expected updated (NativeSettlementReconfirmed costs $ proof "block-b" 2)
    afterConfirmedReplay <- snapshot ledger
    require (beforeConfirmedReplay==afterConfirmedReplay) "contract_finality_refusal_mutated_state"
    NativeRecovery.candidates ledger >>= \rows->require (null rows) "contract_reconfirmed_candidate_not_closed"
    L.ledgerAction ledger $ \c->do
      [PG.Only count] <- PG.query_ c "SELECT count(*) FROM postings WHERE event_id LIKE 'native-winner-fee:%'" :: IO[PG.Only Int64]
      require (count==0) "contract_unapproved_winner_money_posted"
    winnerContract ledger
    lossCoverContract ledger
    coveredObligationContract ledger
  L.withLedger connectionSettings identity $ \ledger->do
    L.ledgerAction ledger $ \c->do
      rows <- PG.query_ c "SELECT id,status FROM obligations ORDER BY id" :: IO[(Text,Text)]
      require (lookup "restore-ready" rows==Just "ready" && lookup "restore-paying" rows==Just "paying" && lookup "changed-work" rows==Just "review" && lookup "stale-restoration" rows==Just "review") "contract_restart_changed_state"
  putStrLn "PostgreSQL source approval: ready/paying restoration, freshness, replay, conflict, changed-work/stale refusal, candidate view, source/evidence fences and reopen plus native finality and replacement draft/sign/cancel, older/newer winner fees, loss cover/return, covered ready/paying approvals, exact backup coverage and fences passed; database-only contract"

jsonText :: ToJSON a => a -> Text
jsonText = TE.decodeUtf8 . LBS.toStrict . encode

-- Captured real-chain template, with an explicitly non-sendable replacement
-- byte stub. This exercises PostgreSQL accounting, never network replacement.
winnerContract :: L.Ledger -> IO ()
winnerContract ledger = do
  cfg <- BS.readFile "config/l2l-devnet.example.json" >>= either fail pure . eitherDecodeStrict' :: IO Config
  captured <- BS.readFile "test/fixtures/native-signet-payment.json" >>= either fail pure . eitherDecodeStrict'
  plan <- fieldValue "plan" captured
  prevouts <- fieldValue "previous" captured
  oldFee <- fieldValue "fee" captured
  tx <- fieldValue "decoded" captured >>= either reject pure . decodeNativeTx
  raw <- fieldValue "raw" captured
  replacement <- BS.readFile "test/fixtures/native-signet-replacement-draft.json" >>= either fail pure . eitherDecodeStrict'
  draft <- fieldValue "draft" replacement
  point <- case nativeInputs tx of input:_->pure(nativeOutpoint input); _->reject "contract_native_inputs_missing"
  let original=NativeSigned raw tx plan prevouts oldFee
      newer=original {signedNativeBytes="00",signedNativeTransaction=draftTransaction draft,signedNativePrevouts=draftPrevouts draft,signedNativeFee=draftFee draft}
      oldId=nativeTxid tx
      newId=nativeTxid(signedNativeTransaction newer)
      oid="native-winner-contract"
      policy=PolicySnapshot (planDepth plan) "finalized" (fingerprint cfg)
      common=outpointTxid point<>":"<>T.pack(show $ outpointVout point)
      proof tid=jsonText $ object["txid" .= tid,"blockhash" .= ("winner-contract-anchor"::Text),"requiredDepth" .= planDepth plan]
  zero <- either reject pure(amount 0)
  let oldCosts=PaymentCosts oldFee zero
      newCosts=PaymentCosts (draftFee draft) zero
      previous=jsonText $ object["costs" .= oldCosts,"proof" .= proof oldId]
  L.ledgerAction ledger $ \c->do
    _ <- PG.execute c "INSERT INTO orders(id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,status,deadline,grace_deadline,payout_tx) VALUES(?,?,?,'contract','{}','{}',?,'Paid',100,200,?)" (oid,oid,oid,jsonText policy,oldId)
    _ <- PG.execute c "INSERT INTO deposits(id,order_id,asset,amount,anchor,first_seen,confirmations,eligible,allocated) VALUES(?,?,'Wrapped',101010,'database-contract',100,1,1,1)" (oid,oid)
    _ <- PG.execute c "INSERT INTO obligations(id,order_id,deposit_id,kind,asset,amount,recipient,status) VALUES(?,?,?,'conversion','Native',?,?,'paying')" (oid,oid,oid,units $ planAmount plan,planRecipient plan)
    _ <- PG.execute c "INSERT INTO intents(id,obligation_id,chain,common_input) VALUES(?,?,'Native',?)" (oid,oid,common)
    _ <- PG.execute c "INSERT INTO preparations(intent_id,generation,policy_json) VALUES(?,0,?)" (oid,jsonText plan)
    _ <- PG.execute c "INSERT INTO fee_reservations(intent_id,asset,amount,released) VALUES(?,'Native',?,0)" (oid,units $ planFeeLimit plan)
    oldSequence <- L.criticalSequence c
    _ <- PG.execute c "INSERT INTO attempts(txid,intent_id,signed_bytes,policy_json,fee_limit,state,critical_sequence) VALUES(?,?,?,?,?,'broadcast_intent',?)" (oldId,oid,raw,jsonText original,units $ planFeeLimit plan,oldSequence)
    pure ()
  expected <- Replacement.parent ledger cfg oldId
  fresh ledger
  cancelled <- Replacement.recordDraft ledger cfg expected draft "cancelled database contract" 100
  Replacement.decision ledger oldId (draftFee draft) "cancelled database contract" >>= \saved->require (saved==Just(cancelled,False)) "contract_replacement_decision_missing"
  Replacement.cancel ledger cancelled "cancel before signing"
  beforeCancelledReplay <- snapshot ledger
  Replacement.cancel ledger cancelled "cancel before signing"
  expectError "native_replacement_cancellation_conflict" $ Replacement.cancel ledger cancelled "other reason"
  expectError "native_replacement_not_unsigned" $ Replacement.signingContext ledger cfg cancelled >> pure ()
  snapshot ledger >>= \after->require (beforeCancelledReplay==after) "contract_replacement_cancel_replay_mutated"
  fresh ledger
  draftSequence <- Replacement.recordDraft ledger cfg expected draft "signed database contract" 100
  (expectedFamily,savedDraft) <- Replacement.signingContext ledger cfg draftSequence
  require (expectedFamily==[expected] && savedDraft==draft) "contract_replacement_signing_context_changed"
  fresh ledger
  signedMember <- Replacement.recordMember ledger cfg draftSequence expectedFamily newer 100
  beforeSignedReplay <- snapshot ledger
  Replacement.recordMember ledger cfg draftSequence expectedFamily newer 100 >>= \a->require (a==signedMember) "contract_replacement_signed_replay_changed"
  pendingFamily <- PaymentStore.pendingAttempts (PaymentStore.Store ledger)
  canonicalFamily <- L.ledgerAction ledger (\c->Family.familyC c $ attemptIntent signedMember)
  require (filter ((==attemptIntent signedMember).attemptIntent) pendingFamily==canonicalFamily) "contract_pending_family_lineage_order"
  expectError "native_replacement_already_signed" $ Replacement.cancel ledger draftSequence "cannot cancel signature"
  snapshot ledger >>= \after->require (beforeSignedReplay==after) "contract_replacement_signed_replay_mutated"
  Replacement.member ledger draftSequence >>= \a->require (a==Just signedMember) "contract_replacement_member_missing"
  L.ledgerAction ledger $ \c->do
    broadcastSequence <- L.criticalSequence c
    _ <- PG.execute c "UPDATE attempts SET critical_sequence=? WHERE txid=?" (broadcastSequence,newId)
    _ <- PG.execute c "UPDATE attempts SET state='broadcast_intent' WHERE txid=?" (PG.Only newId)
    _ <- PG.execute c "UPDATE attempts SET state='settled',observation_json=? WHERE txid=?" (previous,oldId)
    _ <- PG.execute c "UPDATE intents SET resolved=1 WHERE id=?" (PG.Only oid)
    _ <- PG.execute c "UPDATE obligations SET status='paid' WHERE id=?" (PG.Only oid)
    _ <- PG.execute c "UPDATE fee_reservations SET released=1 WHERE intent_id=?" (PG.Only oid)
    _ <- PG.execute c "INSERT INTO observation_evidence(hash,chain,event_id,evidence_json) VALUES('winner-contract-evidence','Native',?,?)" (newId,jsonText $ object["proof" .= object["confirmations" .= (2::Int),"walletNetUnits" .= ("-100000"::Text),"feeUnits" .= draftFee draft]])
    _ <- PG.execute c "INSERT INTO chain_events(chain,event_id,kind,anchor,evidence_hash,first_seen,last_seen,needs_review) VALUES('Native',?,'outgoing','winner-contract-anchor','winner-contract-evidence',100,100,0)" (PG.Only newId)
    pure ()
  family <- L.ledgerAction ledger $ \c->Family.familyC c oid
  old <- case filter ((==oldId).attemptId) family of [a]->pure a; _->reject "contract_old_winner_missing"
  before <- snapshot ledger
  expectError "native_recovery_cost_changed" $ NativeRecovery.recordCheck ledger old previous (NativeSettlementReplaced family newId oldCosts $ proof newId)
  expectError "native_replacement_family_changed" $ NativeRecovery.recordCheck ledger old previous (NativeSettlementReplaced (drop 1 family) newId newCosts $ proof newId)
  expectError "native_recovery_policy_changed" $ NativeRecovery.recordCheck ledger old previous (NativeSettlementReplaced family newId newCosts $ jsonText $ object["txid" .= newId,"blockhash" .= ("winner-contract-anchor"::Text),"requiredDepth" .= (2::Int)])
  expectError "native_recovery_scan_not_current" $ NativeRecovery.recordCheck ledger old previous (NativeSettlementReplaced family newId newCosts $ jsonText $ object["txid" .= newId,"blockhash" .= ("wrong-anchor"::Text),"requiredDepth" .= planDepth plan])
  snapshot ledger >>= \after->require (before==after) "contract_winner_refusal_mutated_state"
  NativeRecovery.recordCheck ledger old previous (NativeSettlementReplaced family newId newCosts $ proof newId)
  after <- snapshot ledger
  expectError "native_settlement_changed" $ NativeRecovery.recordCheck ledger old previous (NativeSettlementReplaced family newId newCosts $ proof newId)
  snapshot ledger >>= \replayed->require (after==replayed) "contract_winner_replay_mutated_state"
  L.ledgerAction ledger $ \c->do
    states <- PG.query c "SELECT txid,state FROM attempts WHERE intent_id=? ORDER BY txid" (PG.Only oid) :: IO [(Text,Text)]
    require (lookup oldId states==Just "review" && lookup newId states==Just "settled") "contract_winner_not_moved"
    [PG.Only link] <- PG.query c "SELECT payout_tx FROM orders WHERE id=?" (PG.Only oid) :: IO [PG.Only Text]
    require (link==newId) "contract_winner_link_not_moved"
    [PG.Only delta] <- PG.query_ c "SELECT fee_delta FROM native_winner_changes" :: IO [PG.Only Int64]
    require (delta==units(draftFee draft)-units oldFee) "contract_winner_delta_wrong"
    posts <- PG.query_ c "SELECT account,delta FROM postings WHERE event_id LIKE 'native-winner-fee:%' ORDER BY account" :: IO [(Text,Int64)]
    require (posts==[("external",delta),("operating",negate delta)]) "contract_winner_principal_changed"
    pure ()
  -- Re-read through the same validator after the prior winner becomes reviewed.
  L.ledgerAction ledger (\c->Family.familyC c oid) >>= \current->require (length current==2) "contract_winner_lineage_not_preserved"
  -- A later reorg can restore the older winner. Charge/refund the delta once
  -- while preserving an unrelated primary conversion link (e.g. extra refund).
  L.ledgerAction ledger $ \c->do
    _ <- PG.execute c "UPDATE orders SET payout_tx='other-primary-link' WHERE id=?" (PG.Only oid)
    _ <- PG.execute c "INSERT INTO observation_evidence(hash,chain,event_id,evidence_json) VALUES('older-winner-contract-evidence','Native',?,?)" (oldId,jsonText $ object["proof" .= object["confirmations" .= (2::Int),"walletNetUnits" .= ("-100000"::Text),"feeUnits" .= oldFee]])
    _ <- PG.execute c "INSERT INTO chain_events(chain,event_id,kind,anchor,evidence_hash,first_seen,last_seen,needs_review) VALUES('Native',?,'outgoing','winner-contract-anchor','older-winner-contract-evidence',100,100,0)" (PG.Only oldId)
    pure ()
  current <- L.ledgerAction ledger $ \c->Family.familyC c oid
  new <- case filter ((==newId).attemptId) current of [a]->pure a; _->reject "contract_new_winner_missing"
  saved <- NativeRecovery.observation ledger newId
  NativeRecovery.recordCheck ledger new saved (NativeSettlementReplaced current oldId oldCosts $ proof oldId)
  L.ledgerAction ledger $ \c->do
    [PG.Only link] <- PG.query c "SELECT payout_tx FROM orders WHERE id=?" (PG.Only oid) :: IO [PG.Only Text]
    require (link=="other-primary-link") "contract_additional_refund_replaced_primary"
    [PG.Only count] <- PG.query_ c "SELECT count(*) FROM native_winner_changes" :: IO [PG.Only Int64]
    require (count==2) "contract_older_winner_missing"
    [PG.Only total] <- PG.query_ c "SELECT sum(delta)::bigint FROM postings WHERE event_id LIKE 'native-winner-fee:%' AND account='operating'" :: IO [PG.Only Int64]
    require (total==0) "contract_older_winner_fee_not_returned"
    states <- PG.query c "SELECT txid,state FROM attempts WHERE intent_id=?" (PG.Only oid) :: IO [(Text,Text)]
    require (lookup oldId states==Just "settled" && lookup newId states==Just "review") "contract_older_winner_not_canonical"
    pure ()

lossCoverContract :: L.Ledger -> IO ()
lossCoverContract ledger = do
  let txid=T.replicate 64 "a"
      did="native:"<>txid<>":0"
      sourceProof=object["transaction" .= txid,"output" .= (0::Int),"observationHash" .= ("contract-hash"::Text),"confirmations" .= (-1::Int),"nodeBlock" .= ("loss-contract-block"::Text),"nodeHeight" .= (100::Int)]
  (source,recovery) <- L.ledgerAction ledger $ \c->do
    Source.recordSourceCheckC c did (SourceMissing sourceProof)
    [PG.Only sequenceNo] <- PG.query c "SELECT critical_sequence FROM source_recoveries WHERE deposit_id=? ORDER BY id DESC LIMIT 1" (PG.Only did) :: IO [PG.Only Int64]
    quantity <- either reject pure(amount 10000)
    L.posting c "contract-loss-capital" "synthetic database fixture only" [(Native,"float",5000),(Native,"earned",4000),(Native,"external",-9000)]
    pure(Deposit did Nothing Native quantity "unconfirmed" 0 False 100,sequenceNo)
  fromFloat <- either reject pure(amount 6000)
  fromEarned <- either reject pure(amount 4000)
  let capital=LossCapital fromFloat fromEarned
      reason="contract capital coverage"
      custody revision=object["revision" .= revision,"checkedAt" .= (100::Int),"report" .= object["matches" .= True,"nativeBlock" .= ("loss-contract-block"::Text),"nativeHeight" .= (100::Int)]]
  revision <- L.ledgerAction ledger $ \c->do
    [PG.Only current] <- PG.query_ c "SELECT revision FROM custody_check" :: IO [PG.Only Int64]
    pure current
  before <- snapshot ledger
  expectError "insufficient_loss_capital" $ LossCover.record ledger source recovery 100 capital reason sourceProof (custody revision)
  expectError "source_loss_custody_not_current" $ LossCover.record ledger source recovery 100 capital reason sourceProof (custody $ revision+1)
  expectError "source_loss_not_proven" $ LossCover.record ledger source (recovery+1) 100 capital reason sourceProof (custody revision)
  snapshot ledger >>= \after->require (before==after) "contract_loss_refusal_mutated"
  L.ledgerAction ledger $ \c->L.posting c "contract-extra-loss-capital" "synthetic database fixture only" [(Native,"float",1000),(Native,"external",-1000)]
  coverRevision <- L.ledgerAction ledger $ \c->do
    [PG.Only current] <- PG.query_ c "SELECT revision FROM custody_check" :: IO [PG.Only Int64]
    pure current
  LossCover.record ledger source recovery 100 capital reason sourceProof (custody coverRevision)
  LossCover.decision ledger did recovery >>= \saved->require (saved==Just(capital,reason)) "contract_loss_decision_missing"
  beforeReplay <- snapshot ledger
  LossCover.record ledger source recovery 100 capital reason sourceProof (custody coverRevision)
  expectError "source_loss_cover_conflict" $ LossCover.record ledger source recovery 100 capital "changed allocation reason" sourceProof (custody coverRevision)
  snapshot ledger >>= \after->require (beforeReplay==after) "contract_loss_cover_repeated"
  L.ledgerAction ledger $ \c->do
    [PG.Only deficit] <- PG.query_ c "SELECT sum(delta)::bigint FROM postings WHERE asset='Native' AND account='source_deficit'" :: IO [PG.Only Int64]
    require (deficit==0) "contract_loss_deficit_not_covered"
    _ <- PG.execute c "UPDATE deposits SET eligible=1 WHERE id=?" (PG.Only did)
    Source.recordSourceCheckC c did (SourceRestored $ object["contractRestored" .= True])
    [PG.Only count] <- PG.query_ c "SELECT count(*) FROM source_loss_returns" :: IO [PG.Only Int64]
    require (count==1) "contract_loss_capital_not_returned"
    posts <- PG.query_ c "SELECT account,sum(delta)::bigint FROM postings WHERE asset='Native' AND account IN('float','earned','source_deficit') GROUP BY account ORDER BY account" :: IO [(Text,Int64)]
    require (posts==[("earned",4000),("float",6000),("source_deficit",0)]) "contract_loss_return_changed_capital"
    pure ()


-- Only database fixtures and non-sendable byte stubs. This never supplies fake
-- chain responses, calls a signer or broadcasts a transaction.
coveredObligationContract :: L.Ledger -> IO ()
coveredObligationContract ledger = forM_ ["ready","paying"] $ \prior->do
  let oid="covered-"<>prior
      txid=T.replicate 64 (if prior=="ready" then "c" else "d")
      did="native:"<>txid<>":0"
      eventHash=oid<>"-database-evidence"
      proof=object["transaction" .= txid,"output" .= (0::Int),"confirmations" .= (-1::Int),"observationHash" .= eventHash,"nodeBlock" .= ("covered-contract-block"::Text),"nodeHeight" .= (100::Int)]
      report=object["matches" .= True,"nativeBlock" .= ("covered-contract-block"::Text),"nativeHeight" .= (100::Int)]
      savedTx=oid<>"-non-sendable-payment"
  (recovery,source,oldSendSequence) <- L.ledgerAction ledger $ \c->do
    _ <- PG.execute c "INSERT INTO orders(id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,status,deadline,grace_deadline) VALUES(?,?,?,'contract','{}','{}','{}','NeedsReview',100,200)" (oid,oid,oid)
    _ <- PG.execute c "INSERT INTO deposits(id,order_id,asset,amount,anchor,first_seen,confirmations,eligible,allocated) VALUES(?,?,'Native',10000,'unconfirmed',100,0,0,1)" (did,oid)
    _ <- PG.execute c "INSERT INTO obligations(id,order_id,deposit_id,kind,asset,amount,recipient,status) VALUES(?,?,?,'conversion','Wrapped',9900,'database-contract-recipient',?)" (oid,oid,did,prior)
    oldSequence <- L.criticalSequence c
    if prior=="paying" then do
      -- Earlier changed-work fixture has no attempts or signed bytes. Retire
      -- that isolated fixture's slot before testing a different Solana intent.
      _ <- PG.execute_ c "UPDATE intents SET resolved=1 WHERE id='changed-work'"
      _ <- PG.execute c "INSERT INTO intents(id,obligation_id,chain) VALUES(?,?,'Solana')" (oid,oid)
      _ <- PG.execute c "INSERT INTO preparations(intent_id,generation,policy_json) VALUES(?,0,'{}')" (PG.Only oid)
      _ <- PG.execute c "INSERT INTO fee_reservations(intent_id,asset,amount,released) VALUES(?,'Sol',5000,0)" (PG.Only oid)
      _ <- PG.execute c "INSERT INTO attempts(txid,intent_id,signed_bytes,policy_json,fee_limit,state,critical_sequence) VALUES(?,?,'database-fixture-not-signed','{}',5000,'broadcast_intent',?)" (savedTx,oid,oldSequence)
      pure ()
    else pure ()
    work <- Source.sourceWorkHashC c oid
    Source.recordSourceCheckC c did $ SourceUnavailable $ object["reason" .= ("source_eligibility_lost"::Text),"reviewedObligations" .= [object["intent" .= oid,"previousStatus" .= prior,"workHash" .= work]]]
    _ <- PG.execute c "UPDATE obligations SET status='review' WHERE id=?" (PG.Only oid)
    _ <- PG.execute c "INSERT INTO observation_evidence(hash,chain,event_id,evidence_json) VALUES(?,'Native',?,'{}')" (eventHash,txid)
    _ <- PG.execute c "INSERT INTO chain_events(chain,event_id,kind,anchor,evidence_hash,first_seen,last_seen,needs_review) VALUES('Native',?,'incoming','unconfirmed',?,100,100,0)" (txid,eventHash)
    L.posting c (oid<>"-original-deposit") "isolated database fixture only" [(Native,"float",10000),(Native,"external",-10000)]
    Source.recordSourceCheckC c did (SourceMissing proof)
    [PG.Only loss] <- PG.query c "SELECT critical_sequence FROM source_recoveries WHERE deposit_id=? ORDER BY id DESC LIMIT 1" (PG.Only did) :: IO [PG.Only Int64]
    quantity <- either reject pure(amount 10000)
    pure(loss,Deposit did (Just oid) Native quantity "unconfirmed" 0 False 100,oldSequence)
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "uncovered_source_authorized"
  expectError "source_loss_not_covered" $ Source.coveredObligation ledger oid recovery >> pure ()
  capital <- LossCapital <$> either reject pure(amount 10000) <*> either reject pure(amount 0)
  revision <- L.ledgerAction ledger $ \c->do
    [PG.Only r] <- PG.query_ c "SELECT revision FROM custody_check" :: IO [PG.Only Int64]
    pure r
  LossCover.record ledger source recovery 100 capital "isolated cover contract" proof (object["revision" .= revision,"checkedAt" .= (100::Int),"report" .= report])
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "capital_cover_implicitly_authorized_payment"
  expectError "custody_not_reconciled" $ Source.coveredRecord ledger oid recovery 100 "explicit covered contract" proof
  fresh ledger
  L.ledgerAction ledger $ \c->PG.execute c "UPDATE custody_check SET report_json=?" (PG.Only $ jsonText report) >> pure ()
  Source.coveredRecord ledger oid recovery 100 "explicit covered contract" proof
  before <- snapshot ledger
  Source.coveredRecord ledger oid recovery 100 "explicit covered contract" proof
  expectError "source_approval_conflict" $ Source.coveredRecord ledger oid recovery 100 "changed approval" proof
  after <- snapshot ledger
  require (before==after) "covered_approval_replay_mutated_state"
  Source.coveredAuthorized ledger oid >>= \yes->require yes "approved_covered_source_not_authorized"
  L.ledgerAction ledger $ \c->PG.execute c "UPDATE chain_events SET needs_review=1 WHERE chain='Native' AND event_id=?" (PG.Only txid) >> pure ()
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "ambiguous_covered_source_authorized"
  L.ledgerAction ledger $ \c->PG.execute c "UPDATE chain_events SET needs_review=0 WHERE chain='Native' AND event_id=?" (PG.Only txid) >> pure ()
  L.ledgerAction ledger $ \c->do
    states <- PG.query c "SELECT o.status,d.eligible FROM obligations o JOIN deposits d ON d.id=o.deposit_id WHERE o.id=?" (PG.Only oid) :: IO [(Text,Int64)]
    require (states==[(prior,0)]) "covered_approval_changed_physical_eligibility_or_prior_state"
  if prior=="paying" then do
    L.ledgerAction ledger $ \c->PG.execute_ c "UPDATE deployment SET paused=0" >> pure ()
    L.acknowledgeBackup ledger identity oldSendSequence (T.replicate 64 "e")
    needed <- Settlement.markBroadcastIntent ledger savedTx
    require (needed>oldSendSequence) "covered_approval_not_included_in_send_coverage"
    expectError "backup_pending" $ Settlement.authorizeRecordedSend ledger True savedTx >> pure ()
    L.acknowledgeBackup ledger identity needed (T.replicate 64 "f")
    saved <- Settlement.authorizeRecordedSend ledger True savedTx
    require (attemptId saved==savedTx && attemptBytes saved=="database-fixture-not-signed") "covered_approval_created_different_payment"
    L.pause ledger "isolated-contract-finished"
  else pure ()
  -- Returning the source retires the cover. If it is lost again, its previous
  -- capital allocation/approval cannot authorize another uncovered loss.
  L.ledgerAction ledger $ \c->do
    _ <- PG.execute c "UPDATE deposits SET eligible=1 WHERE id=?" (PG.Only did)
    Source.recordSourceCheckC c did (SourceRestored $ object["contractRestored" .= True])
    _ <- PG.execute c "UPDATE deposits SET eligible=0 WHERE id=?" (PG.Only did)
    Source.recordSourceCheckC c did (SourceMissing proof)
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "returned_cover_authorized_later_loss"
