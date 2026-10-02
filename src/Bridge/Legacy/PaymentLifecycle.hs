{-# OPTIONS_GHC -Wno-orphans #-}
-- Legacy SQLite adapters; shared payment/reorg/deposit algorithms stay generic.
module Bridge.Legacy.PaymentLifecycle () where
import Bridge.Legacy.ObservationPreparation ()
import Bridge.Ledger
import Bridge.Config
import Bridge.Types
import Bridge.Settlement
import Bridge.Reorg
import Bridge.Deposit
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple

stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8

sourceContext :: Ledger -> Obligation -> IO (Deposit,OrderRequest,PolicySnapshot,Text)
sourceContext ledger ob=ledgerAction ledger $ \db -> do
  obligations <- query db "SELECT id,order_id,deposit_id,kind,asset,amount,recipient FROM obligations WHERE id=?" (Only $ obligationId ob)
  require (obligations==[ob]) "obligation_mismatch"
  orders <- query db "SELECT request_json,policy_json,instruction FROM orders WHERE id=?" (Only $ obligationOrder ob) :: IO [(Text,Text,Maybe Text)]
  (request,policy,instruction) <- case orders of
    [(r,p,Just i)] -> (,,) <$> stored r <*> stored p <*> pure i
    _ -> reject "source_instruction_missing"
  rows <- query db "SELECT order_id,asset,amount,anchor,confirmations,eligible,first_seen FROM deposits WHERE id=?" (Only $ obligationDeposit ob) :: IO [(Maybe Text,Text,Int64,Text,Int,Bool,Int64)]
  deposit <- case rows of
    [(Just oid,asset,n,anchor,depth,eligible,seen)] -> do
      require (oid==obligationOrder ob && asset==T.pack(show $ sourceAsset $ direction request)) "source_binding_mismatch"
      quantity <- either reject pure (amount $ toInteger n)
      pure $ Deposit (obligationDeposit ob) (Just oid) (sourceAsset $ direction request) quantity anchor depth eligible seen
    _ -> reject "source_deposit_missing"
  pure (deposit,request,policy,instruction)

instance PaymentStore Ledger where
  paymentObligation ledger oid = do
    rows <- ledgerAction ledger $ \db -> query db "SELECT id,order_id,deposit_id,kind,asset,amount,recipient FROM obligations WHERE id=?" (Only oid)
    case rows of [ob]->pure ob; _->reject "obligation_not_found"
  paymentSourceContext = sourceContext
  paymentNativeFamily = nativeFamilyAttempts

instance SettlementStore Ledger where
  settlementRetryReasons ledger txid = ledgerAction ledger $ \db -> map fromOnly <$> (query db "SELECT reason FROM solana_retry_approvals WHERE expired_txid=?" (Only txid) :: IO [Only Text])
  settlementRetryAttempts ledger txid = ledgerAction ledger $ \db -> query db "SELECT a.txid,a.intent_id,i.chain,a.signed_bytes,a.policy_json,a.fee_limit,a.state,a.critical_sequence FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN solana_expiries e ON e.txid=a.txid WHERE a.txid=? AND i.resolved=1 AND a.state='review' AND o.status='review' AND a.preparation_generation=(SELECT MAX(generation) FROM preparations WHERE intent_id=i.id)" (Only txid)
  settlementRecordRetry = recordSolanaRetryApproval
  settlementWinner ledger intent = ledgerAction ledger $ \db->do
    rows <- query db "SELECT txid FROM attempts WHERE intent_id=? AND state='settled'" (Only intent) :: IO [Only Text]
    case rows of [Only winner]->pure winner; _->reject "settled_payment_missing"
  settlementReady = readyObligations
  settlementBusy ledger chain = ledgerAction ledger $ \db->do
    rows <- query db "SELECT id FROM intents WHERE chain=? AND resolved=0" (Only chain) :: IO [Only Text]
    pure(not $ null rows)
  settlementRefresh = refreshDeposit
  settlementRecord = recordSettlement
  settlementFailed = recordFailedSolana
  settlementExpiry = recordSolanaExpiry
  settlementExpiryOrigins = checkExpiryOrigins
  settlementBroadcast = markBroadcastIntent
  settlementAuthorize = authorizeRecordedSend

checkExpiryOrigins :: Ledger -> Config -> IO ()
checkExpiryOrigins ledger c=do
  origins <- ledgerAction ledger $ \db -> query_ db "SELECT chain,anchor FROM scan_origins WHERE chain IN('Solana','SolanaOperating') ORDER BY chain" :: IO [(Text,Text)]
  require (map (\(chain,anchor)->(chain,Just anchor)) origins==[("Solana",solanaHistoryStart c),("SolanaOperating",solanaOperatingHistoryStart c)]) "expiry_scan_origin_mismatch"

instance NativeSourceStore Ledger where
  sourceCandidates = nativeSourceCandidates
  sourcePause = pause
  sourceRecordCheck = recordSourceCheck
  sourceOrderBinding ledger oid = do
    rows <- ledgerAction ledger $ \db->query db "SELECT instruction,policy_json FROM orders WHERE id=?" (Only oid)
    case rows of [binding]->pure binding; _->reject "native_source_binding_missing"
  sourceEventEvidence ledger txid = do
    rows <- ledgerAction ledger $ \db->query db "SELECT e.evidence_hash,o.evidence_json FROM chain_events e JOIN observation_evidence o ON o.hash=e.evidence_hash WHERE e.chain='Native' AND e.event_id=? AND e.kind IN('incoming','unmatched_incoming') AND e.needs_review=0" (Only txid)
    case rows of [evidence]->pure evidence; _->reject "source_recovery_scan_not_current"

instance NativeSettlementStore Ledger where
  recoveryCandidates = nativeSettlementCandidates
  recoveryPause = pause
  recoveryObservation ledger txid = do
    rows <- ledgerAction ledger $ \db->query db "SELECT observation_json FROM attempts WHERE txid=?" (Only txid)
    case rows of [Only saved]->pure saved; _->reject "native_settlement_missing"
  recoveryCheck = recordNativeSettlementCheck

instance DepositStore Ledger where
  depositRead = readOrder
  depositExpose = exposeOrder
  depositPause = pause
  depositReadiness = readiness
