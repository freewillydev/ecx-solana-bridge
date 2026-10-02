{-# LANGUAGE GADTs, LambdaCase #-}
-- Database-only recovery contract. No chain transport, signer or broadcast.
module SourceApprovalCheck (run) where
import Bridge.Types hiding (deploymentFingerprint)
import Bridge.Config (Config,fingerprint)
import qualified Bridge.Postgres.Replacement as Replacement
import qualified Bridge.Postgres.Settlement as Settlement
import Bridge.NativePayment
import Bridge.RPC (fieldValue,PaymentTransport(..))
import qualified Bridge.Settlement as Workflow
import Data.IORef (newIORef,modifyIORef',readIORef)
import qualified Data.ByteString as BS
import qualified Bridge.Postgres.Ledger as L
import qualified Bridge.Postgres.Source as Source
import qualified Bridge.Postgres.NativeRecovery as NativeRecovery
import qualified Bridge.Postgres.LossCover as LossCover
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)
import Bridge.Ledger.Model (LossCapital(..),SourceCheck(..),Deposit(..),Attempt(..),PaymentCosts(..),NativeSettlementCheck(..))
import qualified Data.Text as T
import Control.Exception (bracket,try)
import Control.Monad (forM_,void)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Bridge.Postgres.Schema
import qualified Opaleye as O
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

-- Fixtures model ledger state only; they never provide chain evidence.
-- Every row access uses the closed Opaleye fixture interpreter below.
fixture :: L.Ledger -> Text -> Text -> IO Int64
fixture ledger oid prior = L.ledgerAction ledger $ \c->do
  fixtureOperation c (ContractOrder oid "NeedsReview" "{}" Nothing)
  fixtureOperation c (ContractDeposit $ Deposits oid (Just oid) "Native" 10000 "database-contract-anchor" 100 1 1 1 "observed")
  fixtureOperation c (ContractObligation $ Obligations oid oid oid "conversion" "Wrapped" 9900 "database-contract-recipient" prior)
  work <- Source.sourceWorkHashC c oid
  fixtureOperation c (DepositEligibility oid 0)
  Source.recordSourceCheckC c oid $ SourceUnavailable $ object
    ["reason" .= ("source_eligibility_lost"::Text),"reviewedObligations" .= [object["intent" .= oid,"previousStatus" .= prior,"workHash" .= work]]]
  fixtureOperation c (ObligationStatus oid "review")
  fixtureOperation c (DepositEligibility oid 1)
  Source.recordSourceCheckC c oid $ SourceRestored $ object["anchor" .= ("database-contract-restoration"::Text)]
  fixtureOperation c (SourceSequence oid)

fresh :: L.Ledger -> IO ()
fresh ledger = L.ledgerAction ledger $ \c->do
  fixtureOperation c FreshCustody
  pure ()

snapshot :: L.Ledger -> IO RecoverySnapshot
snapshot ledger = L.ledgerAction ledger (\c->fixtureOperation c RecoveryState)

run :: IO ()
run = do
  user <- getEffectiveUserName
  database <- fromMaybe "ecx_source_approval_contract" <$> lookupEnv "ECX_SOURCE_CONTRACT_DATABASE"
  require ("ecx_source_approval_contract" `T.isPrefixOf` T.pack database) "disposable_contract_database_required"
  let connectionSettings=(settings user) {PG.connectDatabase=database}
  bracket (PG.connect connectionSettings) PG.close $ \c->do
    rows <- fixtureOperation c DeploymentRows
    require (null rows) "fresh_contract_database_required"
    PG.withTransaction c $ do
      fixtureOperation c Initialize
  L.withLedger connectionSettings identity $ \ledger->do
    forM_ ["ready","paying"] $ \prior->do
      let oid="restore-"<>prior
      restoration <- fixture ledger oid prior
      expectError "custody_not_reconciled" $ Source.recoveryRecord ledger oid restoration 100 "verified contract restoration"
      fresh ledger
      Source.recoveryRecord ledger oid restoration 100 "verified contract restoration"
      L.ledgerAction ledger $ \c->do
        state <- fixtureOperation c (ReadObligationStatus oid)
        require (state==[prior]) "contract_wrong_restored_state"
      before <- snapshot ledger
      Source.recoveryRecord ledger oid restoration 100 "verified contract restoration"
      expectError "source_approval_conflict" $ Source.recoveryRecord ledger oid restoration 100 "changed reason"
      after <- snapshot ledger
      require (before==after) "contract_replay_mutated_state"
    changed <- fixture ledger "changed-work" "ready"
    L.ledgerAction ledger $ \c->do
      fixtureOperation c (ContractIntent $ Intents "changed-work" "changed-work" "Solana" Nothing 0)
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
      fixtureOperation c (ContractDeposit $ Deposits did Nothing "Native" 10000 "unconfirmed" 100 0 0 0 "observed")
      fixtureOperation c (NativeEvidence "contract-hash" sourceTxid "{}")
      fixtureOperation c (NativeEvent sourceTxid "incoming" "unconfirmed" "contract-hash")
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
      history <- fixtureOperation c (SourceHistory did)
      require (null history) "contract_ordinary_pending_journaled"

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
      fixtureOperation c (ContractOrder oid "Paid" "{}" Nothing)
      fixtureOperation c (ContractDeposit $ Deposits oid (Just oid) "Wrapped" 10000 "database-contract" 100 1 1 1 "observed")
      fixtureOperation c (ContractObligation $ Obligations oid oid oid "conversion" "Native" 9900 "contract-recipient" "paid")
      fixtureOperation c (ContractIntent $ Intents oid oid "Native" Nothing 0)
      fixtureOperation c (ContractPreparation oid "{}")
      fixtureOperation c (ContractAttempt $ Attempts txid oid "database-fixture-not-signed" "{}" 1000 "settled" (Just 1) (Just old) 0)
      fixtureOperation c (ResolveIntent oid)
      fixtureOperation c (NativeEvidence "finality-contract-hash" txid (jsonText $ object["proof" .= object["confirmations" .= (2::Int)]]))
      fixtureOperation c (NativeEvent txid "outgoing" "block-a" "finality-contract-hash")
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
      fixtureOperation c (NativeAnchor txid "block-b")
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
      posts <- fixtureOperation c WinnerPosts
      require (null posts) "contract_unapproved_winner_money_posted"
    winnerContract ledger
    lossCoverContract ledger
    coveredObligationContract ledger
  L.withLedger connectionSettings identity $ \ledger->do
    L.ledgerAction ledger $ \c->do
      rows <- fixtureOperation c ObligationStates
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
    fixtureOperation c (ContractOrder oid "Paid" (jsonText policy) (Just oldId))
    fixtureOperation c (ContractDeposit $ Deposits oid (Just oid) "Wrapped" 101010 "database-contract" 100 1 1 1 "observed")
    fixtureOperation c (ContractObligation $ Obligations oid oid oid "conversion" "Native" (units $ planAmount plan) (planRecipient plan) "paying")
    fixtureOperation c (ContractIntent $ Intents oid oid "Native" (Just common) 0)
    fixtureOperation c (ContractPreparation oid $ jsonText plan)
    fixtureOperation c (ContractFeeReservation $ FeeReservations oid "Native" (units $ planFeeLimit plan) 0)
    oldSequence <- L.criticalSequence c
    fixtureOperation c (ContractAttempt $ Attempts oldId oid raw (jsonText original) (units $ planFeeLimit plan) "broadcast_intent" (Just oldSequence) Nothing 0)
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
  pendingFamily <- Settlement.pendingAttempts ledger
  canonicalFamily <- L.ledgerAction ledger (\c->Replacement.familyC c $ attemptIntent signedMember)
  require (filter ((==attemptIntent signedMember).attemptIntent) pendingFamily==canonicalFamily) "contract_pending_family_lineage_order"
  expectError "native_replacement_already_signed" $ Replacement.cancel ledger draftSequence "cannot cancel signature"
  snapshot ledger >>= \after->require (beforeSignedReplay==after) "contract_replacement_signed_replay_mutated"
  Replacement.member ledger draftSequence >>= \a->require (a==Just signedMember) "contract_replacement_member_missing"
  -- Inject an identity failure before any RPC. Every pending family must still
  -- be inspected, reported as a typed error, and leave the worker paused.
  calls <- newIORef (0::Int)
  groups <- either reject pure (Workflow.paymentAttemptGroups pendingFamily)
  let unavailable=PaymentTransport (\_ _ _->reject "unexpected_contract_rpc")
        (\_ _->reject "unexpected_contract_rpc") Nothing
        (modifyIORef' calls (+1) >> reject "contract_identity_unavailable")
        (\_->reject "unexpected_contract_backup")
  failures <- Workflow.reconcilePaymentsWith unavailable cfg ledger
  require (failures==replicate (length groups) "contract_identity_unavailable") "contract_reconciliation_errors_lost"
  readIORef calls >>= \n->require (n==length groups) "contract_reconciliation_skipped_family"
  L.readiness ledger >>= \state->require (state==Availability False "payment_recovery:contract_identity_unavailable") "contract_reconciliation_not_paused"
  beforeRepeat <- snapshot ledger
  _ <- Workflow.reconcilePaymentsWith unavailable cfg ledger
  snapshot ledger >>= \after->require (beforeRepeat==after) "contract_reconciliation_repeat_mutated"
  L.ledgerAction ledger $ \c->do
    broadcastSequence <- L.criticalSequence c
    fixtureOperation c (AttemptSequence newId broadcastSequence)
    fixtureOperation c (AttemptState newId "broadcast_intent" Nothing)
    fixtureOperation c (AttemptState oldId "settled" (Just previous))
    fixtureOperation c (ResolveIntent oid)
    fixtureOperation c (ObligationStatus oid "paid")
    fixtureOperation c (ReleaseFee oid)
    fixtureOperation c (NativeEvidence "winner-contract-evidence" newId (jsonText $ object["proof" .= object["confirmations" .= (2::Int),"walletNetUnits" .= ("-100000"::Text),"feeUnits" .= draftFee draft]]))
    fixtureOperation c (NativeEvent newId "outgoing" "winner-contract-anchor" "winner-contract-evidence")
    pure ()
  family <- L.ledgerAction ledger $ \c->Replacement.familyC c oid
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
    states <- fixtureOperation c (AttemptStates oid)
    require (lookup oldId states==Just "review" && lookup newId states==Just "settled") "contract_winner_not_moved"
    [Just link] <- fixtureOperation c (ReadPrimaryLink oid)
    require (link==newId) "contract_winner_link_not_moved"
    [delta] <- fixtureOperation c WinnerDeltas
    require (delta==units(draftFee draft)-units oldFee) "contract_winner_delta_wrong"
    posts <- fixtureOperation c WinnerPosts
    require (posts==[("external",delta),("operating",negate delta)]) "contract_winner_principal_changed"
    pure ()
  -- Re-read through the same validator after the prior winner becomes reviewed.
  L.ledgerAction ledger (\c->Replacement.familyC c oid) >>= \current->require (length current==2) "contract_winner_lineage_not_preserved"
  -- A later reorg can restore the older winner. Charge/refund the delta once
  -- while preserving an unrelated primary conversion link (e.g. extra refund).
  L.ledgerAction ledger $ \c->do
    fixtureOperation c (PrimaryLink oid "other-primary-link")
    fixtureOperation c (NativeEvidence "older-winner-contract-evidence" oldId (jsonText $ object["proof" .= object["confirmations" .= (2::Int),"walletNetUnits" .= ("-100000"::Text),"feeUnits" .= oldFee]]))
    fixtureOperation c (NativeEvent oldId "outgoing" "winner-contract-anchor" "older-winner-contract-evidence")
    pure ()
  current <- L.ledgerAction ledger $ \c->Replacement.familyC c oid
  new <- case filter ((==newId).attemptId) current of [a]->pure a; _->reject "contract_new_winner_missing"
  saved <- NativeRecovery.observation ledger newId
  NativeRecovery.recordCheck ledger new saved (NativeSettlementReplaced current oldId oldCosts $ proof oldId)
  L.ledgerAction ledger $ \c->do
    [Just link] <- fixtureOperation c (ReadPrimaryLink oid)
    require (link=="other-primary-link") "contract_additional_refund_replaced_primary"
    changes <- fixtureOperation c WinnerDeltas
    require (length changes==2) "contract_older_winner_missing"
    total <- sum . map (toInteger . snd) . filter ((=="operating").fst) <$> fixtureOperation c WinnerPosts
    require (total==0) "contract_older_winner_fee_not_returned"
    states <- fixtureOperation c (AttemptStates oid)
    require (lookup oldId states==Just "settled" && lookup newId states==Just "review") "contract_older_winner_not_canonical"
    pure ()
  rebroadcastContract ledger oid oldId

-- Storage-only acceptance: existing typed fixture family, no chain transport.
rebroadcastContract :: L.Ledger -> Text -> Text -> IO ()
rebroadcastContract ledger oid txid = do
  family <- L.ledgerAction ledger $ \c->Replacement.familyC c oid
  saved <- case filter ((==txid).attemptId) family of [a]->pure a; _->reject "contract_rebroadcast_winner_missing"
  old <- NativeRecovery.observation ledger txid
  NativeRecovery.recordCheck ledger saved old NativeSettlementConfirming
  anchor <- L.ledgerAction ledger $ \c->do
    fixtureOperation c (NativeSequence txid)
  let proof=object["transaction" .= txid,"bytesHash" .= digest(TE.encodeUtf8 $ attemptBytes saved),"fixtureOnly" .= True]
      reason="database-only exact-byte repair contract"
      economicSnapshot=L.ledgerAction ledger (\c->fixtureOperation c EconomicState)
  economicBefore <- economicSnapshot
  before <- snapshot ledger
  expectError "native_rebroadcast_review_changed" $ NativeRecovery.recordRebroadcast ledger saved family (anchor+1) reason proof >> pure ()
  expectError "native_rebroadcast_proof_mismatch" $ NativeRecovery.recordRebroadcast ledger saved family anchor reason (object["transaction" .= txid,"bytesHash" .= ("wrong"::Text)]) >> pure ()
  snapshot ledger >>= \after->require (before==after) "contract_rebroadcast_refusal_mutated"
  approved <- NativeRecovery.recordRebroadcast ledger saved family anchor reason proof
  L.ledgerAction ledger NativeRecovery.reviewSequences >>= \reviews->require ((txid,"confirming",approved) `elem` reviews) "contract_rebroadcast_diagnostic_anchor_missing"
  NativeRecovery.rebroadcastDecision ledger txid anchor reason >>= \value->require (value==Just approved) "contract_rebroadcast_decision_missing"
  recorded <- snapshot ledger
  NativeRecovery.recordRebroadcast ledger saved family anchor reason proof >>= \value->require (value==approved) "contract_rebroadcast_replay_changed_sequence"
  NativeRecovery.recordCheck ledger saved old NativeSettlementConfirming
  snapshot ledger >>= \after->require (recorded==after) "contract_rebroadcast_repeat_scan_erased_decision"
  expectError "native_rebroadcast_conflict" $ NativeRecovery.recordRebroadcast ledger saved family anchor "different operator reason" proof >> pure ()
  expectError "backup_pending" $ NativeRecovery.authorizeRebroadcast ledger True saved family approved
  L.acknowledgeBackup ledger identity approved (T.replicate 64 "d")
  NativeRecovery.authorizeRebroadcast ledger True saved family approved
  expectError "native_rebroadcast_payment_changed" $ NativeRecovery.authorizeRebroadcast ledger True saved{attemptBytes="changed"} family approved
  L.ledgerAction ledger $ \c->fixtureOperation c Unpause
  expectError "pause_before_operator_action" $ NativeRecovery.authorizeRebroadcast ledger True saved family approved
  L.pause ledger "database-only repair stays paused"
  NativeRecovery.recordCheck ledger saved old (NativeSettlementUnavailable "contract uncertain RPC")
  expectError "native_rebroadcast_not_missing" $ NativeRecovery.authorizeRebroadcast ledger True saved family approved
  economicSnapshot >>= \after->require (economicBefore==after) "contract_rebroadcast_changed_economic_records"
  L.ledgerAction ledger $ \c->do
    rows <- fixtureOperation c (PrincipalState oid)
    require (rows==[(1,"paid")]) "contract_rebroadcast_reopened_principal"
    total <- sum . map (toInteger . snd) . filter ((=="operating").fst) <$> fixtureOperation c WinnerPosts
    require (total==0) "contract_rebroadcast_reposted_money"

lossCoverContract :: L.Ledger -> IO ()
lossCoverContract ledger = do
  let txid=T.replicate 64 "a"
      did="native:"<>txid<>":0"
      sourceProof=object["transaction" .= txid,"output" .= (0::Int),"observationHash" .= ("contract-hash"::Text),"confirmations" .= (-1::Int),"nodeBlock" .= ("loss-contract-block"::Text),"nodeHeight" .= (100::Int)]
  (source,recovery) <- L.ledgerAction ledger $ \c->do
    Source.recordSourceCheckC c did (SourceMissing sourceProof)
    sequenceNo <- fixtureOperation c (SourceSequence did)
    quantity <- either reject pure(amount 10000)
    L.posting c "contract-loss-capital" "synthetic database fixture only" [(Native,"float",5000),(Native,"earned",4000),(Native,"external",-9000)]
    pure(Deposit did Nothing Native quantity "unconfirmed" 0 False 100,sequenceNo)
  fromFloat <- either reject pure(amount 6000)
  fromEarned <- either reject pure(amount 4000)
  let capital=LossCapital fromFloat fromEarned
      reason="contract capital coverage"
      custody revision=object["revision" .= revision,"checkedAt" .= (100::Int),"report" .= object["matches" .= True,"nativeBlock" .= ("loss-contract-block"::Text),"nativeHeight" .= (100::Int)]]
  revision <- L.ledgerAction ledger $ \c->do
    fixtureOperation c CustodyRevision
  before <- snapshot ledger
  expectError "insufficient_loss_capital" $ LossCover.record ledger source recovery 100 capital reason sourceProof (custody revision)
  expectError "source_loss_custody_not_current" $ LossCover.record ledger source recovery 100 capital reason sourceProof (custody $ revision+1)
  expectError "source_loss_not_proven" $ LossCover.record ledger source (recovery+1) 100 capital reason sourceProof (custody revision)
  snapshot ledger >>= \after->require (before==after) "contract_loss_refusal_mutated"
  L.ledgerAction ledger $ \c->L.posting c "contract-extra-loss-capital" "synthetic database fixture only" [(Native,"float",1000),(Native,"external",-1000)]
  coverRevision <- L.ledgerAction ledger $ \c->do
    fixtureOperation c CustodyRevision
  LossCover.record ledger source recovery 100 capital reason sourceProof (custody coverRevision)
  LossCover.decision ledger did recovery >>= \saved->require (saved==Just(capital,reason)) "contract_loss_decision_missing"
  beforeReplay <- snapshot ledger
  LossCover.record ledger source recovery 100 capital reason sourceProof (custody coverRevision)
  expectError "source_loss_cover_conflict" $ LossCover.record ledger source recovery 100 capital "changed allocation reason" sourceProof (custody coverRevision)
  snapshot ledger >>= \after->require (beforeReplay==after) "contract_loss_cover_repeated"
  L.ledgerAction ledger $ \c->do
    deficit <- M.findWithDefault 0 "source_deficit" <$> fixtureOperation c NativeCapital
    require (deficit==0) "contract_loss_deficit_not_covered"
    fixtureOperation c (DepositEligibility did 1)
    Source.recordSourceCheckC c did (SourceRestored $ object["contractRestored" .= True])
    returns <- fixtureOperation c LossReturns
    require (length returns==1) "contract_loss_capital_not_returned"
    posts <- M.toAscList <$> fixtureOperation c NativeCapital
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
    fixtureOperation c (ContractOrder oid "NeedsReview" "{}" Nothing)
    fixtureOperation c (ContractDeposit $ Deposits did (Just oid) "Native" 10000 "unconfirmed" 100 0 0 1 "observed")
    fixtureOperation c (ContractObligation $ Obligations oid oid did "conversion" "Wrapped" 9900 "database-contract-recipient" prior)
    oldSequence <- L.criticalSequence c
    if prior=="paying" then do
      -- Earlier changed-work fixture has no attempts or signed bytes. Retire
      -- that isolated fixture's slot before testing a different Solana intent.
      fixtureOperation c (ResolveIntent "changed-work")
      fixtureOperation c (ContractIntent $ Intents oid oid "Solana" Nothing 0)
      fixtureOperation c (ContractPreparation oid "{}")
      fixtureOperation c (ContractFeeReservation $ FeeReservations oid "Sol" 5000 0)
      fixtureOperation c (ContractAttempt $ Attempts savedTx oid "database-fixture-not-signed" "{}" 5000 "broadcast_intent" (Just oldSequence) Nothing 0)
      pure ()
    else pure ()
    work <- Source.sourceWorkHashC c oid
    Source.recordSourceCheckC c did $ SourceUnavailable $ object["reason" .= ("source_eligibility_lost"::Text),"reviewedObligations" .= [object["intent" .= oid,"previousStatus" .= prior,"workHash" .= work]]]
    fixtureOperation c (ObligationStatus oid "review")
    fixtureOperation c (NativeEvidence eventHash txid "{}")
    fixtureOperation c (NativeEvent txid "incoming" "unconfirmed" eventHash)
    L.posting c (oid<>"-original-deposit") "isolated database fixture only" [(Native,"float",10000),(Native,"external",-10000)]
    Source.recordSourceCheckC c did (SourceMissing proof)
    loss <- fixtureOperation c (SourceSequence did)
    quantity <- either reject pure(amount 10000)
    pure(loss,Deposit did (Just oid) Native quantity "unconfirmed" 0 False 100,oldSequence)
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "uncovered_source_authorized"
  expectError "source_loss_not_covered" $ Source.coveredObligation ledger oid recovery >> pure ()
  capital <- LossCapital <$> either reject pure(amount 10000) <*> either reject pure(amount 0)
  revision <- L.ledgerAction ledger $ \c->do
    fixtureOperation c CustodyRevision
  LossCover.record ledger source recovery 100 capital "isolated cover contract" proof (object["revision" .= revision,"checkedAt" .= (100::Int),"report" .= report])
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "capital_cover_implicitly_authorized_payment"
  expectError "custody_not_reconciled" $ Source.coveredRecord ledger oid recovery 100 "explicit covered contract" proof
  fresh ledger
  L.ledgerAction ledger $ \c->fixtureOperation c (CustodyReport $ jsonText report)
  Source.coveredRecord ledger oid recovery 100 "explicit covered contract" proof
  before <- snapshot ledger
  Source.coveredRecord ledger oid recovery 100 "explicit covered contract" proof
  expectError "source_approval_conflict" $ Source.coveredRecord ledger oid recovery 100 "changed approval" proof
  after <- snapshot ledger
  require (before==after) "covered_approval_replay_mutated_state"
  Source.coveredAuthorized ledger oid >>= \yes->require yes "approved_covered_source_not_authorized"
  L.ledgerAction ledger $ \c->fixtureOperation c (NativeReview txid 1)
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "ambiguous_covered_source_authorized"
  L.ledgerAction ledger $ \c->fixtureOperation c (NativeReview txid 0)
  L.ledgerAction ledger $ \c->do
    states <- fixtureOperation c (CoveredState oid)
    require (states==[(prior,0)]) "covered_approval_changed_physical_eligibility_or_prior_state"
  if prior=="paying" then do
    L.ledgerAction ledger $ \c->fixtureOperation c Unpause
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
    fixtureOperation c (DepositEligibility did 1)
    Source.recordSourceCheckC c did (SourceRestored $ object["contractRestored" .= True])
    fixtureOperation c (DepositEligibility did 0)
    Source.recordSourceCheckC c did (SourceMissing proof)
  Source.coveredAuthorized ledger oid >>= \yes->require (not yes) "returned_cover_authorized_later_loss"

-- Closed database-only vocabulary. Callers cannot supply SQL, tables, query
-- callbacks or arbitrary IO; these fixtures never sign or contact either chain.
data Fixture a where
  Initialize :: Fixture ()
  DeploymentRows :: Fixture [Deployment]
  ContractOrder :: Text -> Text -> Text -> Maybe Text -> Fixture ()
  ContractDeposit :: Deposits -> Fixture ()
  ContractObligation :: Obligations -> Fixture ()
  ContractIntent :: Intents -> Fixture ()
  ContractPreparation :: Text -> Text -> Fixture ()
  ContractAttempt :: Attempts -> Fixture ()
  ContractFeeReservation :: FeeReservations -> Fixture ()
  NativeEvidence :: Text -> Text -> Text -> Fixture ()
  NativeEvent :: Text -> Text -> Text -> Text -> Fixture ()
  DepositEligibility :: Text -> Int64 -> Fixture ()
  ObligationStatus :: Text -> Text -> Fixture ()
  ResolveIntent :: Text -> Fixture ()
  NativeAnchor :: Text -> Text -> Fixture ()
  NativeReview :: Text -> Int64 -> Fixture ()
  AttemptSequence :: Text -> Int64 -> Fixture ()
  AttemptState :: Text -> Text -> Maybe Text -> Fixture ()
  ReleaseFee :: Text -> Fixture ()
  PrimaryLink :: Text -> Text -> Fixture ()
  Unpause :: Fixture ()
  FreshCustody :: Fixture ()
  CustodyReport :: Text -> Fixture ()
  RecoveryState :: Fixture RecoverySnapshot
  EconomicState :: Fixture EconomicSnapshot
  SourceHistory :: Text -> Fixture [SourceRecoveries]
  SourceSequence :: Text -> Fixture Int64
  NativeSequence :: Text -> Fixture Int64
  ReadObligationStatus :: Text -> Fixture [Text]
  ObligationStates :: Fixture [(Text,Text)]
  AttemptStates :: Text -> Fixture [(Text,Text)]
  ReadPrimaryLink :: Text -> Fixture [Maybe Text]
  WinnerDeltas :: Fixture [Int64]
  WinnerPosts :: Fixture [(Text,Int64)]
  PrincipalState :: Text -> Fixture [(Int64,Text)]
  CoveredState :: Text -> Fixture [(Text,Int64)]
  CustodyRevision :: Fixture Int64
  NativeCapital :: Fixture (M.Map Text Integer)
  LossReturns :: Fixture [SourceLossReturns]

-- Whole typed rows retain all columns formerly compared through jsonb_agg.
-- Explicit sorting makes equality independent of PostgreSQL's scan order.
data RecoverySnapshot = RecoverySnapshot [Deployment] [SourceRecoveryApprovals]
  [Obligations] [Attempts] [NativePaymentRecoveries] [Postings] deriving (Eq,Show)
data EconomicSnapshot = EconomicSnapshot [Orders] [Intents] [Obligations]
  [Attempts] [Postings] [FeeReservations] deriving (Eq,Show)

fixtureOperation :: PG.Connection -> Fixture a -> IO a
fixtureOperation c = \case
  Initialize -> do
    void $ O.runInsert c O.Insert
      {O.iTable=deploymentTable,O.iRows=[O.toFields (Deployment 1 18 identity 0 0 1 "initialization" :: Deployment)]
      ,O.iReturning=O.rCount,O.iOnConflict=Nothing}
    void $ O.runInsert c O.Insert
      {O.iTable=custodycheckTable,O.iRows=[O.toFields (CustodyCheck 1 0 Nothing Nothing Nothing Nothing :: CustodyCheck)]
      ,O.iReturning=O.rCount,O.iOnConflict=Nothing}
  DeploymentRows -> O.runSelect c (O.selectTable deploymentTable)
  ContractOrder oid status policy link -> void $ O.runInsert c O.Insert
    {O.iTable=ordersTable,O.iRows=[O.toFields (Orders oid oid oid "contract" "{}" "{}" policy status 100 200 Nothing Nothing link 0 :: Orders)]
    ,O.iReturning=O.rCount,O.iOnConflict=Nothing}
  ContractDeposit row -> void $ O.runInsert c O.Insert
    {O.iTable=depositsTable,O.iRows=[O.toFields row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  ContractObligation row -> void $ O.runInsert c O.Insert
    {O.iTable=obligationsTable,O.iRows=[O.toFields row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  ContractIntent row -> void $ O.runInsert c O.Insert
    {O.iTable=intentsTable,O.iRows=[O.toFields row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  ContractPreparation oid policy -> void $ O.runInsert c O.Insert
    {O.iTable=preparationsTable,O.iRows=[O.toFields (Preparations oid 0 policy Nothing Nothing 0 :: Preparations)]
    ,O.iReturning=O.rCount,O.iOnConflict=Nothing}
  ContractAttempt row -> void $ O.runInsert c O.Insert
    {O.iTable=attemptsTable,O.iRows=[O.toFields row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  ContractFeeReservation row -> void $ O.runInsert c O.Insert
    {O.iTable=feereservationsTable,O.iRows=[O.toFields row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  NativeEvidence hash txid evidence -> void $ O.runInsert c O.Insert
    {O.iTable=observationevidenceTable,O.iRows=[O.toFields (ObservationEvidence hash "Native" txid evidence :: ObservationEvidence)]
    ,O.iReturning=O.rCount,O.iOnConflict=Nothing}
  NativeEvent txid kind anchor hash -> void $ O.runInsert c O.Insert
    {O.iTable=chaineventsTable,O.iRows=[O.toFields (ChainEvents "Native" txid kind anchor hash 100 100 0 :: ChainEvents)]
    ,O.iReturning=O.rCount,O.iOnConflict=Nothing}
  DepositEligibility did value -> void $ O.runUpdate c O.Update
    {O.uTable=depositsTable,O.uUpdateWith= \row->row{depositsEligible=O.sqlInt8 value}
    ,O.uWhere= \row->depositsId row O..== O.sqlStrictText did,O.uReturning=O.rCount}
  ObligationStatus oid status -> void $ O.runUpdate c O.Update
    {O.uTable=obligationsTable,O.uUpdateWith= \row->row{obligationsStatus=O.sqlStrictText status}
    ,O.uWhere= \row->obligationsId row O..== O.sqlStrictText oid,O.uReturning=O.rCount}
  ResolveIntent oid -> void $ O.runUpdate c O.Update
    {O.uTable=intentsTable,O.uUpdateWith= \row->row{intentsResolved=O.sqlInt8 1}
    ,O.uWhere= \row->intentsId row O..== O.sqlStrictText oid,O.uReturning=O.rCount}
  NativeAnchor txid anchor -> void $ O.runUpdate c O.Update
    {O.uTable=chaineventsTable,O.uUpdateWith= \row->row{chaineventsAnchor=O.sqlStrictText anchor}
    ,O.uWhere= \row->chaineventsChain row O..== O.sqlStrictText "Native" O..&& chaineventsEventId row O..== O.sqlStrictText txid
    ,O.uReturning=O.rCount}
  NativeReview txid value -> void $ O.runUpdate c O.Update
    {O.uTable=chaineventsTable,O.uUpdateWith= \row->row{chaineventsNeedsReview=O.sqlInt8 value}
    ,O.uWhere= \row->chaineventsChain row O..== O.sqlStrictText "Native" O..&& chaineventsEventId row O..== O.sqlStrictText txid
    ,O.uReturning=O.rCount}
  AttemptSequence txid n -> void $ O.runUpdate c O.Update
    {O.uTable=attemptsTable,O.uUpdateWith= \row->row{attemptsCriticalSequence=O.toNullable $ O.sqlInt8 n}
    ,O.uWhere= \row->attemptsTxid row O..== O.sqlStrictText txid,O.uReturning=O.rCount}
  AttemptState txid state observation -> void $ O.runUpdate c O.Update
    {O.uTable=attemptsTable,O.uUpdateWith= \row->row{attemptsState=O.sqlStrictText state
      ,attemptsObservationJson=maybe (attemptsObservationJson row) (O.toNullable . O.sqlStrictText) observation}
    ,O.uWhere= \row->attemptsTxid row O..== O.sqlStrictText txid,O.uReturning=O.rCount}
  ReleaseFee oid -> void $ O.runUpdate c O.Update
    {O.uTable=feereservationsTable,O.uUpdateWith= \row->row{feereservationsReleased=O.sqlInt8 1}
    ,O.uWhere= \row->feereservationsIntentId row O..== O.sqlStrictText oid,O.uReturning=O.rCount}
  PrimaryLink oid link -> void $ O.runUpdate c O.Update
    {O.uTable=ordersTable,O.uUpdateWith= \row->row{ordersPayoutTx=O.toNullable $ O.sqlStrictText link}
    ,O.uWhere= \row->ordersId row O..== O.sqlStrictText oid,O.uReturning=O.rCount}
  Unpause -> void $ O.runUpdate c O.Update
    {O.uTable=deploymentTable,O.uUpdateWith= \row->row{deploymentPaused=O.sqlInt8 0}
    ,O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
  FreshCustody -> void $ O.runUpdate c O.Update
    {O.uTable=custodycheckTable,O.uUpdateWith= \row->row
      {custodycheckCheckedRevision=O.toNullable $ custodycheckRevision row
      ,custodycheckCheckedAt=O.toNullable $ O.sqlInt8 100,custodycheckLastError=O.null
      ,custodycheckReportJson=O.toNullable $ O.sqlStrictText "{}"}
    ,O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
  CustodyReport report -> void $ O.runUpdate c O.Update
    {O.uTable=custodycheckTable,O.uUpdateWith= \row->row{custodycheckReportJson=O.toNullable $ O.sqlStrictText report}
    ,O.uWhere=const(O.sqlBool True),O.uReturning=O.rCount}
  RecoveryState -> RecoverySnapshot
    <$> (sortOn deploymentSingleton <$> O.runSelect c (O.selectTable deploymentTable))
    <*> (sortOn (\row->(sourcerecoveryapprovalsObligationId row,sourcerecoveryapprovalsRestorationSequence row,sourcerecoveryapprovalsLossSequence row)) <$> O.runSelect c (O.selectTable sourcerecoveryapprovalsTable))
    <*> (sortOn obligationsId <$> O.runSelect c (O.selectTable obligationsTable))
    <*> (sortOn attemptsTxid <$> O.runSelect c (O.selectTable attemptsTable))
    <*> (sortOn nativepaymentrecoveriesId <$> O.runSelect c (O.selectTable nativepaymentrecoveriesTable))
    <*> (sortOn postingsId <$> O.runSelect c (O.selectTable postingsTable))
  EconomicState -> EconomicSnapshot
    <$> (sortOn ordersId <$> O.runSelect c (O.selectTable ordersTable))
    <*> (sortOn intentsId <$> O.runSelect c (O.selectTable intentsTable))
    <*> (sortOn obligationsId <$> O.runSelect c (O.selectTable obligationsTable))
    <*> (sortOn attemptsTxid <$> O.runSelect c (O.selectTable attemptsTable))
    <*> (sortOn postingsId <$> O.runSelect c (O.selectTable postingsTable))
    <*> (sortOn feereservationsIntentId <$> O.runSelect c (O.selectTable feereservationsTable))
  SourceHistory did -> O.runSelect c $ do
    row <- O.selectTable sourcerecoveriesTable
    O.where_ (sourcerecoveriesDepositId row O..== O.sqlStrictText did)
    pure row
  SourceSequence did -> do
    rows <- fixtureOperation c (SourceHistory did)
    case reverse (sortOn sourcerecoveriesId rows) of
      row:_ -> pure (sourcerecoveriesCriticalSequence row)
      _ -> reject "contract_restoration_missing"
  NativeSequence txid -> do
    rows <- (O.runSelect c $ O.limit 1 $ O.orderBy (O.desc fst) $ do
      row <- O.selectTable nativepaymentrecoveriesTable
      O.where_ (nativepaymentrecoveriesTxid row O..== O.sqlStrictText txid)
      pure (nativepaymentrecoveriesId row,nativepaymentrecoveriesCriticalSequence row)) :: IO [(Int64,Int64)]
    case rows of [(_,n)] -> pure n; _ -> reject "contract_native_recovery_missing"
  ReadObligationStatus oid -> O.runSelect c $ do
    row <- O.selectTable obligationsTable
    O.where_ (obligationsId row O..== O.sqlStrictText oid)
    pure (obligationsStatus row)
  ObligationStates -> O.runSelect c $ O.orderBy (O.asc fst) $ do
    row <- O.selectTable obligationsTable
    pure (obligationsId row,obligationsStatus row)
  AttemptStates oid -> O.runSelect c $ do
    row <- O.selectTable attemptsTable
    O.where_ (attemptsIntentId row O..== O.sqlStrictText oid)
    pure (attemptsTxid row,attemptsState row)
  ReadPrimaryLink oid -> O.runSelect c $ do
    row <- O.selectTable ordersTable
    O.where_ (ordersId row O..== O.sqlStrictText oid)
    pure (ordersPayoutTx row)
  WinnerDeltas -> O.runSelect c $ nativewinnerchangesFeeDelta <$> O.selectTable nativewinnerchangesTable
  WinnerPosts -> O.runSelect c $ O.orderBy (O.asc fst) $ do
    row <- O.selectTable postingsTable
    O.where_ (postingsEventId row `O.like` O.sqlStrictText "native-winner-fee:%")
    pure (postingsAccount row,postingsDelta row)
  PrincipalState oid -> O.runSelect c $ do
    intent <- O.selectTable intentsTable
    obligation <- O.selectTable obligationsTable
    O.where_ (intentsId intent O..== O.sqlStrictText oid O..&& obligationsId obligation O..== intentsObligationId intent)
    pure (intentsResolved intent,obligationsStatus obligation)
  CoveredState oid -> O.runSelect c $ do
    obligation <- O.selectTable obligationsTable
    deposit <- O.selectTable depositsTable
    O.where_ (obligationsId obligation O..== O.sqlStrictText oid O..&& depositsId deposit O..== obligationsDepositId obligation)
    pure (obligationsStatus obligation,depositsEligible deposit)
  CustodyRevision -> do
    rows <- O.runSelect c $ custodycheckRevision <$> O.selectTable custodycheckTable
    case rows of [n] -> pure n; _ -> reject "contract_custody_missing"
  NativeCapital -> do
    posts <- (O.runSelect c $ do
      row <- O.selectTable postingsTable
      O.where_ (postingsAsset row O..== O.sqlStrictText "Native"
        O..&& O.in_ (map O.sqlStrictText ["float","earned","source_deficit"]) (postingsAccount row))
      pure (postingsAccount row,postingsDelta row)) :: IO [(Text,Int64)]
    pure $ M.fromListWith (+) [(account,toInteger value) | (account,value) <- posts]
  LossReturns -> O.runSelect c (O.selectTable sourcelossreturnsTable)
