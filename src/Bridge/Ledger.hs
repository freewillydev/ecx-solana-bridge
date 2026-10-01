{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
module Bridge.Ledger
  ( Ledger, withLedger, ledgerAction, schemaVersion, sqliteIdentity, readiness, pause, resumeAfterChecks
  , createOrder, readOrder, bindInstruction, criticalSequence, acknowledgeBackup
  , exposeOrder, freeInventory, allocateTreasuryReceipt, recordTreasurySpend, expireQuotes
  , Deposit(..), observeDeposit, refreshDeposit, recordScan, readCheckpoint, promoteDeposit, checkpoint
  , ChainEvent(..), ScanBatch(..), commitScan, recordScanFailure, scannerHealth
  , lookupInstruction, maximumNativeDepth, pendingVerification
  , Obligation(..), readyObligations, Attempt(..), storeAttempt, markBroadcastIntent, authorizeRecordedSend
  , Preparation(..), beginPreparation, storeDraft, pendingPreparations
  , pendingAttempts, PaymentCosts(..), recordSettlement, createRefund, recordFailedSolana, recordSolanaExpiry, recordSolanaRetryApproval, requireBackup, addHint, auditExport, auditExportWithBudget
  ) where

import Bridge.Config
import Bridge.Budget
import Bridge.Types
import Control.Concurrent.MVar
import Control.Exception (bracket)
import Control.Monad (forM_, when)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither,Parser)
import qualified Data.ByteString.Lazy as LBS
import Data.FileEmbed (embedFile)
import Data.Int (Int64)
import Data.List (nub,sortOn)
import qualified Data.Map.Strict as M
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing)
import System.FileLock (SharedExclusive(Exclusive), tryLockFile, unlockFile)
import System.FilePath (takeDirectory)
import System.Posix.Files (setFileMode)
import Text.Read (readMaybe)

-- All financial mutations are serialized and committed before external IO.
newtype Ledger = Ledger (MVar Connection)
schemaVersion :: Int
schemaVersion = 7
sqliteIdentity :: Connection -> IO Value
sqliteIdentity c = do
  versions <- query_ c "SELECT sqlite_version(),sqlite_source_id()" :: IO [(Text,Text)]
  case versions of
    [(version,source)] -> do
      require (version=="3.53.4" && source=="2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc") "unsupported_sqlite_runtime"
      pure $ object ["version" .= version,"sourceId" .= source]
    _ -> reject "sqlite_identity_unavailable"
ledgerAction :: Ledger -> (Connection -> IO a) -> IO a
ledgerAction (Ledger l) action = withMVar l $ \c -> withTransaction c (action c)
withLedger :: FilePath -> Text -> (Ledger -> IO a) -> IO a
withLedger path identity action = do
  createDirectoryIfMissing True (takeDirectory path)
  setFileMode (takeDirectory path) 0o700
  bracket acquire unlockFile $ \_ -> bracket (open path) close $ \c -> do
    setFileMode path 0o600
    _ <- sqliteIdentity c
    execute_ c "PRAGMA journal_mode=DELETE"
    execute_ c "PRAGMA synchronous=EXTRA"
    execute_ c "PRAGMA foreign_keys=ON"
    execute_ c "PRAGMA busy_timeout=5000"
    modes <- query_ c "PRAGMA journal_mode" :: IO [Only Text]
    sync <- query_ c "PRAGMA synchronous" :: IO [Only Int]
    fk <- query_ c "PRAGMA foreign_keys" :: IO [Only Int]
    require (modes == [Only "delete"] && sync == [Only 3] && fk == [Only 1]) "sqlite_durability_unavailable"
    integrity <- query_ c "PRAGMA quick_check" :: IO [Only Text]
    require (integrity == [Only "ok"]) "ledger_integrity_failed"
    tables <- query_ c "SELECT name FROM sqlite_master WHERE type='table' AND name='deployment'" :: IO [Only Text]
    when (null tables) $ withTransaction c $ do
      existing <- query_ c "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'" :: IO [Only Text]
      require (null existing) "unknown_database"
      forM_ (T.splitOn "-- @statement" (TE.decodeUtf8 $(embedFile "migrations/001.sql"))) $ execute_ c . fromString . T.unpack
      execute c "INSERT INTO deployment(singleton,schema_version,fingerprint) VALUES(1,1,?)" (Only identity)
    meta <- query_ c "SELECT schema_version,fingerprint FROM deployment" :: IO [(Int,Text)]
    require (meta `elem` [[(v,identity)] | v<-[1..schemaVersion]]) "ledger_profile_or_schema_mismatch"
    when (meta==[(1,identity)]) $ withTransaction c $
      forM_ (T.splitOn "-- @statement" (TE.decodeUtf8 $(embedFile "migrations/002.sql"))) $ execute_ c . fromString . T.unpack
    when (meta `elem` [[(v,identity)] | v<-[1,2]]) $ withTransaction c $
      forM_ (T.splitOn "-- @statement" (TE.decodeUtf8 $(embedFile "migrations/003.sql"))) $ execute_ c . fromString . T.unpack
    when (meta `elem` [[(v,identity)] | v<-[1..3]]) $ withTransaction c $
      forM_ (T.splitOn "-- @statement" (TE.decodeUtf8 $(embedFile "migrations/004.sql"))) $ execute_ c . fromString . T.unpack
    when (meta `elem` [[(v,identity)] | v<-[1..4]]) $ withTransaction c $
      forM_ (T.splitOn "-- @statement" (TE.decodeUtf8 $(embedFile "migrations/005.sql"))) $ execute_ c . fromString . T.unpack
    when (meta `elem` [[(v,identity)] | v<-[1..5]]) $ withTransaction c $
      forM_ (T.splitOn "-- @statement" (TE.decodeUtf8 $(embedFile "migrations/006.sql"))) $ execute_ c . fromString . T.unpack
    when (meta/=[(schemaVersion,identity)]) $ withTransaction c $
      forM_ (T.splitOn "-- @statement" (TE.decodeUtf8 $(embedFile "migrations/007.sql"))) $ execute_ c . fromString . T.unpack
    -- Restart is quarantined until external identities and unresolved attempts are checked.
    execute_ c "UPDATE deployment SET paused=1,pause_reason='restart_requires_reconciliation'"
    newMVar c >>= action . Ledger
 where
  acquire = tryLockFile (path<>".lock") Exclusive >>= maybe (reject "worker_already_running") pure

jsonText :: ToJSON a => a -> Text
jsonText = TE.decodeUtf8 . LBS.toStrict . encode
fromText :: FromJSON a => Text -> IO a
fromText = either (const $ reject "corrupt_ledger_json") pure . eitherDecodeStrict' . TE.encodeUtf8
readiness :: Ledger -> IO Availability
readiness l = ledgerAction l $ \c -> do
  xs <- query_ c "SELECT paused,pause_reason FROM deployment" :: IO [(Bool,Text)]
  case xs of [(p,r)] -> pure (Availability (not p) r); _ -> reject "corrupt_deployment"
pause :: Ledger -> Text -> IO ()
pause l why = ledgerAction l $ \c -> do
  execute c "UPDATE deployment SET paused=1,pause_reason=?" (Only why)
  execute c "INSERT INTO audit(action,detail) VALUES('pause',?)" (Only why)
-- Only the private worker calls this after actual identity/solvency/recovery checks.
resumeAfterChecks :: Ledger -> IO ()
resumeAfterChecks l = ledgerAction l $ \c -> do
  unresolved <- query_ c "SELECT id FROM intents WHERE resolved=0" :: IO [Only Text]
  require (null unresolved) "unresolved_intents_require_review"
  reviews <- query_ c "SELECT event_id FROM chain_events WHERE needs_review=1 LIMIT 1" :: IO [Only Text]
  require (null reviews) "chain_observations_require_review"
  legacy <- query_ c "SELECT q.id FROM orders q LEFT JOIN order_cost_limits p ON p.order_id=q.id WHERE p.order_id IS NULL AND (q.status NOT IN('Paid','Refunded','ExpiredUnfunded') OR EXISTS(SELECT 1 FROM obligations o WHERE o.order_id=q.id AND o.status NOT IN('paid','cancelled'))) LIMIT 1" :: IO [Only Text]
  require (null legacy) "legacy_order_cost_review_required"
  execute_ c "UPDATE deployment SET paused=0,pause_reason='ready'"
  execute_ c "INSERT INTO audit(action,detail) VALUES('resume','checks_complete')"

criticalSequence :: Connection -> IO Int64
criticalSequence c = do
  execute_ c "UPDATE deployment SET critical_sequence=critical_sequence+1"
  xs <- query_ c "SELECT critical_sequence FROM deployment" :: IO [Only Int64]
  case xs of [Only n] -> pure n; _ -> reject "corrupt_sequence"
acknowledgeBackup :: Ledger -> Int64 -> Text -> IO ()
acknowledgeBackup l seqNo snapshot = ledgerAction l $ \c -> do
  xs <- query_ c "SELECT critical_sequence,backup_sequence FROM deployment" :: IO [(Int64,Int64)]
  case xs of
    [(current,covered)] -> do
      require (seqNo >= covered && seqNo <= current && not (T.null snapshot)) "invalid_backup_coverage"
      execute c "UPDATE deployment SET backup_sequence=?" (Only seqNo)
      execute c "INSERT INTO audit(action,detail) VALUES('backup',?)" (Only (T.pack (show seqNo)<>":"<>snapshot))
    _ -> reject "corrupt_sequence"
requireBackup :: Connection -> Bool -> Int64 -> IO ()
requireBackup _ False _ = pure ()
requireBackup c True needed = do
  xs <- query_ c "SELECT backup_sequence FROM deployment" :: IO [Only Int64]
  require (case xs of [Only n] -> n>=needed; _ -> False) "backup_pending"

balances :: Connection -> IO (M.Map (Text,Text) Integer)
balances c = do
  fold_ c "SELECT asset,account,delta FROM postings ORDER BY id" M.empty $ \m (a,b,n :: Int64) ->
    pure $! M.insertWith (+) (a,b) (toInteger n) m
posting :: Connection -> Text -> Text -> [(Asset,Text,Integer)] -> IO ()
posting c event note rows = do
  let totals = M.fromListWith (+) [(a,n) | (a,_,n) <- rows]
  require (all (==0) (M.elems totals)) "unbalanced_journal"
  require (all (\(_,_,n) -> abs n <= toInteger (maxBound::Int64)) rows) "posting_overflow"
  execute c "INSERT INTO events(id,description) VALUES(?,?)" (event,note)
  forM_ rows $ \(asset,account,n) -> when (n/=0) $ execute c "INSERT INTO postings(event_id,asset,account,delta) VALUES(?,?,?,?)" (event,T.pack (show asset),account,fromInteger n::Int64)
freeInventory :: Connection -> Asset -> IO Integer
freeInventory c asset = do
  bs <- balances c
  holds <- query c "SELECT amount FROM reservations WHERE asset=? AND phase<>'released'" (Only (T.pack (show asset))) :: IO [Only Int64]
  pure $ M.findWithDefault 0 (T.pack (show asset),"float") bs - sum [toInteger n | Only n <- holds]
-- The operator's verified funding workflow supplies the ownership evidence.
-- Move an existing observed receipt; never credit the same on-chain value twice.
allocateTreasuryReceipt :: Ledger -> Text -> [(Text,Amount)] -> Value -> IO ()
allocateTreasuryReceipt l did allocation evidence = ledgerAction l $ \c -> do
  let entries=sortOn fst allocation
      names=map fst entries
      allocationJSON=jsonText entries
      proofJSON=jsonText evidence
  require (not (null entries) && length entries<=4 && length (nub names)==length names
    && all (`elem` ["float","backing","operating","lp"]) names && all ((>0) . units . snd) entries
    && evidence/=Null && T.length proofJSON<=8192) "invalid_treasury_allocation"
  old <- query c "SELECT allocation_json,proof_json FROM treasury_allocations WHERE deposit_id=?" (Only did) :: IO [(Text,Text)]
  case old of
    [(a,p)] -> require (a==allocationJSON && p==proofJSON) "treasury_allocation_conflict"
    [] -> do
      paused <- query_ c "SELECT paused FROM deployment" :: IO [Only Bool]
      require (paused==[Only True]) "treasury_allocation_requires_pause"
      rows <- query c "SELECT order_id,asset,amount,eligible,allocated FROM deposits WHERE id=?" (Only did) :: IO [(Maybe Text,Text,Int64,Bool,Bool)]
      (asset,quantity) <- case rows of
        [(Nothing,name,n,True,False)] -> case name of
          "Native" -> pure (Native,n)
          "Wrapped" -> pure (Wrapped,n)
          "Sol" -> pure (Sol,n)
          _ -> reject "invalid_treasury_asset"
        _ -> reject "receipt_not_available_for_treasury"
      require (sum (map (toInteger . units . snd) entries)==toInteger quantity) "treasury_allocation_amount_mismatch"
      require (asset/=Sol || names==["operating"]) "sol_reserved_for_operating"
      linked <- query c "SELECT id FROM obligations WHERE deposit_id=?" (Only did) :: IO [Only Text]
      require (null linked) "receipt_has_customer_obligation"
      sequenceNumber <- criticalSequence c
      posting c ("treasury:"<>did) "operator allocation of verified treasury receipt"
        ((asset,"unallocated",negate $ toInteger quantity):[(asset,account,toInteger $ units n) | (account,n)<-entries])
      execute c "INSERT INTO treasury_allocations(deposit_id,allocation_json,proof_json,critical_sequence) VALUES(?,?,?,?)"
        (did,allocationJSON,proofJSON,sequenceNumber)
      execute c "UPDATE deposits SET allocated=1,state='treasury' WHERE id=?" (Only did)
    _ -> reject "duplicate_treasury_allocation"

scanAssets :: [(Text,Asset)]
scanAssets=[("Native",Native),("Solana",Wrapped),("SolanaOperating",Sol)]

-- Only already-observed, verified operator spends can be classified here.
-- A customer attempt must settle through its own obligation, never this path.
recordTreasurySpend :: Ledger -> Text -> Text -> Value -> IO ()
recordTreasurySpend l stream txid proof = ledgerAction l $ \c -> do
  let proofJSON=jsonText proof
  require (proof/=Null && T.length proofJSON<=16384) "invalid_treasury_spend_proof"
  rows <- query c "SELECT e.kind,e.anchor,o.evidence_json FROM chain_events e JOIN observation_evidence o ON o.hash=e.evidence_hash WHERE e.chain=? AND e.event_id=?"
    (stream,txid) :: IO [(Text,Text,Text)]
  (anchor,evidence) <- case rows of
    [("outgoing",a,e)] -> do
      value <- fromText e
      nested <- either (const $ reject "invalid_observation_evidence") pure $ parseEither (withObject "observation" (.: "proof")) value
      pure (a,nested)
    _ -> reject "treasury_spend_not_observed"
  economic@(asset,outflow,networkFee) <- either reject pure (economicOutflow stream evidence)
  let economicJSON=jsonText economic
  old <- query c "SELECT anchor,economic_json,proof_json FROM treasury_spends WHERE chain=? AND event_id=?" (stream,txid) :: IO [(Text,Text,Text)]
  case old of
    [(a,e,p)] -> require ((a,e,p)==(anchor,economicJSON,proofJSON)) "treasury_spend_conflict"
    [] -> do
      state <- query_ c "SELECT paused FROM deployment" :: IO [Only Bool]
      require (state==[Only True]) "treasury_spend_requires_pause"
      attempts <- query c "SELECT txid FROM attempts WHERE txid=?" (Only txid) :: IO [Only Text]
      require (null attempts) "customer_attempt_cannot_be_treasury_spend"
      let costs | asset==Native = [("float",toInteger (units outflow)-toInteger (units networkFee)),("operating",toInteger $ units networkFee)]
                | asset==Wrapped = [("float",toInteger $ units outflow)]
                | otherwise = [("operating",toInteger $ units outflow)]
      forM_ costs $ \(account,cost) -> do
        usable <- if account=="float" then freeInventory c asset else freeOperating c (T.pack $ show asset)
        require (cost>=0 && usable>=cost) "treasury_spend_exceeds_free_allocation"
      sequenceNumber <- criticalSequence c
      posting c ("treasury-spend:"<>stream<>":"<>txid) "verified operator spend and network costs"
        ([(asset,account,negate cost) | (account,cost)<-costs]<>[(asset,"external",toInteger $ units outflow)])
      execute c "INSERT INTO treasury_spends(chain,event_id,anchor,economic_json,proof_json,critical_sequence) VALUES(?,?,?,?,?,?)"
        (stream,txid,anchor,economicJSON,proofJSON,sequenceNumber)
      execute c "UPDATE chain_events SET needs_review=0 WHERE chain=? AND event_id=?" (stream,txid)
    _ -> reject "duplicate_treasury_spend"

economicOutflow :: Text -> Value -> Either Text (Asset,Amount,Amount)
economicOutflow stream = either (const $ Left "invalid_treasury_outflow") Right . parseEither parseFlow
 where
  property key = withObject "economic evidence" (.: key)
  signed value = do
    text <- parseJSON value :: Parser Text
    case readMaybe (T.unpack text) of
      Just n | T.length text<=21 && T.pack(show (n::Integer))==text -> pure n
      _ -> fail "invalid signed units"
  quantity = either (fail . T.unpack) pure . amount
  parseFlow value = do
    (asset,delta,fee) <- case stream of
      "Native" -> do
        net <- property "walletNetUnits" value >>= signed
        fee <- property "feeUnits" value :: Parser Amount
        pure (Native,net-toInteger (units fee),fee)
      "Solana" -> do
        delta <- property "delta" value >>= signed
        zero <- quantity 0
        pure (Wrapped,delta,zero)
      "SolanaOperating" -> (,,) Sol <$> (property "delta" value >>= signed) <*> property "feeUnits" value
      _ -> fail "invalid observation stream"
    requireP (delta<0 && negate delta>=toInteger (units fee))
    outflow <- quantity (negate delta)
    pure (asset,outflow,fee)
  requireP ok=if ok then pure () else fail "invalid outgoing value"

createOrder :: Ledger -> Config -> Int64 -> Text -> OrderRequest -> IO OrderView
createOrder l cfg now capability req = do
  cap <- either reject pure (capabilityHash capability)
  require (validIdentifier (idempotencyKey req)) "invalid_idempotency_key"
  q <- either reject pure (makeQuote (direction req) (input req))
  oid <- randomId
  ledgerAction l $ \c -> do
    let rh = digest . TE.encodeUtf8 $ fingerprint cfg <> jsonText req
    previous <- query c "SELECT id,request_hash FROM orders WHERE capability_hash=? AND idempotency_key=?" (cap,idempotencyKey req) :: IO [(Text,Text)]
    case previous of
      [(old,h)] -> require (h==rh) "idempotency_conflict" >> readOrderC c cap old
      [] -> do
        health <- query_ c "SELECT paused FROM deployment" :: IO [Only Bool]
        require (health == [Only False]) "intake_paused"
        require (input req >= minInput cfg && input req <= maxInput cfg) "amount_outside_limits"
        when (direction req == WrappedToNative) $ require (sourceOwner req==Just (refund req)) "refund_owner_mismatch"
        require (not (T.null (recipient req)) && not (T.null (refund req)) && T.length (recipient req)<=128 && T.length (refund req)<=128) "invalid_destination"
        pending <- query_ c "SELECT count(*) FROM orders q WHERE status NOT IN('Paid','Refunded','ExpiredUnfunded') OR EXISTS(SELECT 1 FROM obligations o WHERE o.order_id=q.id AND o.status NOT IN('paid','cancelled'))" :: IO [Only Int]
        require (case pending of [Only n] -> n < maxQueued cfg; _ -> False) "queue_full"
        inventory <- freeInventory c (destinationAsset (direction req))
        require (inventory >= toInteger (units (net q))) "insufficient_inventory"
        require (now>=0 && toInteger now+toInteger (quoteSeconds cfg)+toInteger (confirmationGraceSeconds cfg)<=toInteger (maxBound::Int64)) "invalid_order_time"
        let end = now+quoteSeconds cfg
        execute c "INSERT INTO orders(id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,status,deadline,grace_deadline) VALUES(?,?,?,?,?,?,?,'Provisioning',?,?)" (oid,cap,idempotencyKey req,rh,jsonText req,jsonText q,jsonText (PolicySnapshot (nativeConfirmations cfg) "finalized" (fingerprint cfg)),end,end+confirmationGraceSeconds cfg)
        execute c "INSERT INTO reservations(order_id,asset,amount,phase) VALUES(?,?,?,'quote')" (oid,T.pack (show (destinationAsset (direction req))),units (net q))
        reserveOrderCosts c cfg oid (direction req)
        readOrderC c cap oid
      _ -> reject "duplicate_idempotency"
readOrderC :: Connection -> Text -> Text -> IO OrderView
readOrderC c cap oid = do
  rows <- query c "SELECT request_json,quote_json,status,deadline,instruction,payout_tx,policy_json FROM orders WHERE id=? AND capability_hash=?" (oid,cap) :: IO [(Text,Text,Text,Int64,Maybe Text,Maybe Text,Text)]
  case rows of
    [(r,q,s,d,i,t,p)] -> OrderView oid <$> fromText r <*> fromText q <*> pure s <*> pure d <*> pure i <*> pure t <*> fromText p
    _ -> reject "order_not_found"
readOrder :: Ledger -> Text -> Text -> IO OrderView
readOrder l capability oid = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction l $ \c -> readOrderC c cap oid
bindInstruction :: Ledger -> Text -> Text -> IO ()
bindInstruction l oid instruction = ledgerAction l $ \c -> do
  require (not (T.null instruction) && T.length instruction<=160) "invalid_instruction"
  rows <- query c "SELECT instruction,status FROM orders WHERE id=?" (Only oid) :: IO [(Maybe Text,Text)]
  case rows of
    [(Nothing,"Provisioning")] -> do
      n <- criticalSequence c
      execute c "UPDATE orders SET instruction=?,instruction_sequence=?,status='AwaitingDeposit' WHERE id=?" (instruction,n,oid)
    [(Just old,_)] -> require (old==instruction) "instruction_is_immutable"
    [(Nothing,_)] -> reject "order_no_longer_provisioning"
    _ -> reject "order_not_found"
exposeOrder :: Ledger -> Bool -> Text -> Text -> IO OrderView
exposeOrder l remote capability oid = do
  cap <- either reject pure (capabilityHash capability)
  ledgerAction l $ \c -> do
    view <- readOrderC c cap oid
    ns <- query c "SELECT instruction_sequence FROM orders WHERE id=?" (Only oid) :: IO [Only (Maybe Int64)]
    case ns of [Only (Just n)] -> requireBackup c remote n; _ -> pure ()
    pure view
expireQuotes :: Ledger -> Int64 -> IO ()
expireQuotes l now = ledgerAction l $ \c -> do
  execute c "UPDATE reservations SET phase='released' WHERE phase='quote' AND order_id IN (SELECT id FROM orders WHERE grace_deadline<?)" (Only now)
  execute c "UPDATE operating_reservations SET phase='released' WHERE phase='quote' AND order_id IN (SELECT id FROM orders WHERE grace_deadline<?)" (Only now)
  execute c "UPDATE orders SET status='ExpiredUnfunded' WHERE grace_deadline<? AND status IN('Provisioning','AwaitingDeposit') AND NOT EXISTS (SELECT 1 FROM deposits WHERE deposits.order_id=orders.id)" (Only now)

data Deposit = Deposit { depositId :: !Text, depositOrder :: !(Maybe Text), depositAsset :: !Asset, depositAmount :: !Amount, depositAnchor :: !Text, depositConfirmations :: !Int, depositEligible :: !Bool, depositSeenAt :: !Int64 } deriving (Eq,Show)
observeDeposit :: Ledger -> Deposit -> Text -> IO ()
observeDeposit l deposit cursor = ledgerAction l $ \c -> do
  observeDepositC c deposit
  checkpoint c (case depositAsset deposit of Native->"Native"; Wrapped->"Solana"; Sol->"SolanaOperating") cursor

-- A focused source recheck must not advance the history scanner's cursor.
refreshDeposit :: Ledger -> Deposit -> IO ()
refreshDeposit l deposit = ledgerAction l $ \c -> do
  existing <- query c "SELECT id FROM deposits WHERE id=?" (Only $ depositId deposit) :: IO [Only Text]
  require (existing==[Only $ depositId deposit]) "source_deposit_missing"
  observeDepositC c deposit

-- The whole page and its continuation commit together. A stale scanner cannot
-- advance a newer cursor, and one invalid receipt rolls back the complete page.
recordScan :: Ledger -> Text -> Maybe Text -> Text -> [Deposit] -> IO ()
recordScan l chain previous next deposits = ledgerAction l $ \c -> do
  require (chain `elem` map fst scanAssets && not (T.null next) && T.length next<=128 && length deposits<=1000) "invalid_scan_batch"
  require (all (\d -> Just (depositAsset d)==lookup chain scanAssets) deposits) "scan_asset_mismatch"
  actual <- readCheckpointC c chain
  require (actual==previous) "stale_scan_cursor"
  mapM_ (observeDepositC c) deposits
  checkpoint c chain next

-- Immutable evidence is separate from the latest observation's classification.
-- Neither an unknown receipt nor a provider's history cursor authorizes spending.
data ChainEvent = ChainEvent
  { chainEventId :: !Text, chainEventKind :: !Text, chainEventAnchor :: !Text
  , chainEventEvidence :: !Value
  } deriving (Eq,Show)
data ScanBatch = ScanBatch
  { scanChain :: !Text, scanOrigin :: !Text, scanPrevious :: !(Maybe Text)
  , scanNext :: !Text, scanTime :: !Int64, scanDeposits :: ![Deposit]
  , scanEvents :: ![ChainEvent]
  } deriving (Eq,Show)

commitScan :: Ledger -> ScanBatch -> IO ()
commitScan l ScanBatch{..} = ledgerAction l $ \c -> do
  require (scanChain `elem` map fst scanAssets && scanTime>=0 && length scanDeposits<=1000 && length scanEvents<=1000) "invalid_scan_batch"
  require (all (\t -> not (T.null t) && T.length t<=128) [scanOrigin,scanNext]) "invalid_scan_anchor"
  require (all (\d -> Just (depositAsset d)==lookup scanChain scanAssets) scanDeposits) "scan_asset_mismatch"
  actual <- readCheckpointC c scanChain
  require (actual==scanPrevious) "stale_scan_cursor"
  origins <- query c "SELECT anchor FROM scan_origins WHERE chain=?" (Only scanChain) :: IO [Only Text]
  case origins of
    [] -> execute c "INSERT INTO scan_origins(chain,anchor) VALUES(?,?)" (scanChain,scanOrigin)
    [Only origin] -> require (origin==scanOrigin) "scan_origin_mismatch"
    _ -> reject "duplicate_scan_origin"
  mapM_ (observeDepositC c) scanDeposits
  forM_ scanEvents $ \ChainEvent{..} -> do
    require (not (T.null chainEventId) && T.length chainEventId<=128 && T.length chainEventAnchor<=128) "invalid_observation_identity"
    require (chainEventKind `elem` ["incoming","unmatched_incoming","outgoing","failed","reference","unsupported","unclassified","awaiting_verifier","disputed"]) "invalid_observation_kind"
    let evidence = jsonText $ object ["chain" .= scanChain,"id" .= chainEventId,"anchor" .= chainEventAnchor,"kind" .= chainEventKind,"proof" .= chainEventEvidence]
        hash = digest (TE.encodeUtf8 evidence)
    require (T.length evidence<=8192) "observation_evidence_too_large"
    let paymentChain=if scanChain=="SolanaOperating" then "Solana" else scanChain
    known <- query c "SELECT a.txid FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE a.txid=? AND i.chain=? AND a.state IN('broadcast_intent','settled','failed')" (chainEventId,paymentChain) :: IO [Only Text]
    treasury <- query c "SELECT anchor,economic_json FROM treasury_spends WHERE chain=? AND event_id=?" (scanChain,chainEventId) :: IO [(Text,Text)]
    let approved = case economicOutflow scanChain chainEventEvidence of
          Right economic -> treasury==[(chainEventAnchor,jsonText economic)]
          Left _ -> False
        review = chainEventKind `elem` ["unsupported","unclassified","disputed"] || chainEventKind=="outgoing" && null known && not approved
    execute c "INSERT OR IGNORE INTO observation_evidence(hash,chain,event_id,evidence_json) VALUES(?,?,?,?)" (hash,scanChain,chainEventId,evidence)
    execute c "INSERT INTO chain_events(chain,event_id,kind,anchor,evidence_hash,first_seen,last_seen,needs_review) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(chain,event_id) DO UPDATE SET kind=excluded.kind,anchor=excluded.anchor,evidence_hash=excluded.evidence_hash,last_seen=excluded.last_seen,needs_review=MAX(chain_events.needs_review,excluded.needs_review)"
      (scanChain,chainEventId,chainEventKind,chainEventAnchor,hash,scanTime,scanTime,review)
    when review $ execute c "UPDATE deployment SET paused=1,pause_reason=?" (Only ("chain_review:"<>scanChain<>":"<>chainEventKind))
  checkpoint c scanChain scanNext
  execute c "INSERT INTO scan_health(chain,last_success,last_error,checked_at) VALUES(?,?,NULL,?) ON CONFLICT(chain) DO UPDATE SET last_success=excluded.last_success,last_error=NULL,checked_at=excluded.checked_at" (scanChain,scanTime,scanTime)

recordScanFailure :: Ledger -> Text -> Int64 -> Text -> IO ()
recordScanFailure l chain now code = ledgerAction l $ \c -> do
  require (chain `elem` map fst scanAssets && T.length code<=160) "invalid_scan_failure"
  previous <- query c "SELECT last_error FROM scan_health WHERE chain=?" (Only chain) :: IO [Only (Maybe Text)]
  when (previous/=[Only (Just code)]) $ execute c "INSERT INTO audit(action,detail) VALUES('scanner_failure',?)" (Only (chain<>":"<>code))
  execute c "INSERT INTO scan_health(chain,last_error,checked_at) VALUES(?,?,?) ON CONFLICT(chain) DO UPDATE SET last_error=excluded.last_error,checked_at=excluded.checked_at" (chain,code,now)
  execute c "UPDATE deployment SET paused=1,pause_reason=?" (Only ("scanner_unavailable:"<>chain))

scannerHealth :: Ledger -> IO Value
scannerHealth l = ledgerAction l $ \c -> do
  rows <- query_ c "SELECT h.chain,h.last_success,h.last_error,h.checked_at,p.anchor FROM scan_health h LEFT JOIN checkpoints p ON p.chain=h.chain ORDER BY h.chain" :: IO [(Text,Maybe Int64,Maybe Text,Int64,Maybe Text)]
  reviews <- query_ c "SELECT chain,event_id,kind FROM chain_events WHERE needs_review=1 ORDER BY first_seen LIMIT 100" :: IO [(Text,Text,Text)]
  pure $ object ["scanners" .= [object ["chain" .= chain,"lastSuccess" .= ok,"lastError" .= err,"checkedAt" .= checked,"cursor" .= cursor] | (chain,ok,err,checked,cursor)<-rows],"review" .= reviews]

lookupInstruction :: Ledger -> Text -> IO (Maybe (Text,OrderRequest,PolicySnapshot))
lookupInstruction l instruction = ledgerAction l $ \c -> do
  rows <- query c "SELECT id,request_json,policy_json FROM orders WHERE instruction=?" (Only instruction) :: IO [(Text,Text,Text)]
  case rows of
    [] -> pure Nothing
    [(oid,r,p)] -> Just <$> ((,,) oid <$> fromText r <*> fromText p)
    _ -> reject "duplicate_deposit_instruction"

maximumNativeDepth :: Ledger -> Int -> IO Int
maximumNativeDepth l minimumDepth = ledgerAction l $ \c -> do
  rows <- query_ c "SELECT MAX(json_extract(policy_json,'$.nativeDepth')) FROM orders" :: IO [Only (Maybe Int)]
  case rows of [Only depth] -> pure (max minimumDepth (maybe 1 id depth)); _ -> reject "invalid_confirmation_policy"

pendingVerification :: Ledger -> IO [Text]
pendingVerification l = ledgerAction l $ \c -> do
  rows <- query_ c "SELECT event_id FROM chain_events WHERE chain='Solana' AND kind='awaiting_verifier' ORDER BY first_seen LIMIT 1000" :: IO [Only Text]
  pure [sig | Only sig<-rows]

readCheckpoint :: Ledger -> Text -> IO (Maybe Text)
readCheckpoint l chain = ledgerAction l (\c -> readCheckpointC c chain)
readCheckpointC :: Connection -> Text -> IO (Maybe Text)
readCheckpointC c chain = do
  rows <- query c "SELECT anchor FROM checkpoints WHERE chain=?" (Only chain) :: IO [Only Text]
  case rows of [] -> pure Nothing; [Only anchor] -> pure (Just anchor); _ -> reject "duplicate_checkpoint"

observeDepositC :: Connection -> Deposit -> IO ()
observeDepositC c Deposit{..} = do
  require (units depositAmount>0 && depositConfirmations>=0 && depositSeenAt>=0) "invalid_deposit"
  case depositOrder of
    Nothing -> pure () -- Unknown receipts remain separate from spendable float.
    Just oid -> do
      orders <- query c "SELECT request_json,policy_json FROM orders WHERE id=?" (Only oid) :: IO [(Text,Text)]
      case orders of
        [(r,p)] -> do
          req <- fromText r
          policy <- fromText p
          require (sourceAsset (direction req)==depositAsset) "deposit_asset_mismatch"
          when (depositAsset==Native && depositEligible) $ require (depositConfirmations>=nativeDepth policy) "deposit_confirmation_policy_mismatch"
        _ -> reject "deposit_order_missing"
  rows <- query c "SELECT order_id,asset,amount FROM deposits WHERE id=?" (Only depositId) :: IO [(Maybe Text,Text,Int64)]
  case rows of
    [] -> do
      execute c "INSERT INTO deposits(id,order_id,asset,amount,anchor,confirmations,eligible,first_seen) VALUES(?,?,?,?,?,?,?,?)" (depositId,depositOrder,T.pack (show depositAsset),units depositAmount,depositAnchor,depositConfirmations,depositEligible,depositSeenAt)
      let account = maybe "unallocated" (const "principal") depositOrder
      posting c ("deposit:"<>depositId) "observed customer value" [(depositAsset,account,toInteger (units depositAmount)),(depositAsset,"external",negate $ toInteger $ units depositAmount)]
    [(oid,a,n)] -> do
      require (oid==depositOrder && a==T.pack (show depositAsset) && n==units depositAmount) "conflicting_deposit_evidence"
      execute c "UPDATE deposits SET anchor=?,confirmations=?,eligible=? WHERE id=?" (depositAnchor,depositConfirmations,depositEligible,depositId)
      when (not depositEligible) $ do
        allocated <- query c "SELECT allocated FROM deposits WHERE id=?" (Only depositId) :: IO [Only Bool]
        when (allocated == [Only True]) $ do
          execute_ c "UPDATE deployment SET paused=1,pause_reason='source_reorg_review'"
          execute c "UPDATE obligations SET status='review' WHERE deposit_id=? AND status<>'paid'" (Only depositId)
    _ -> reject "duplicate_deposit"
checkpoint :: Connection -> Text -> Text -> IO ()
checkpoint c chain anchor = execute c "INSERT INTO checkpoints(chain,anchor) VALUES(?,?) ON CONFLICT(chain) DO UPDATE SET anchor=excluded.anchor" (chain,anchor)
promoteDeposit :: Ledger -> Int64 -> Text -> IO Bool
promoteDeposit l now did = ledgerAction l $ \c -> do
  ds <- query c "SELECT order_id,asset,amount,eligible,allocated,first_seen FROM deposits WHERE id=?" (Only did) :: IO [(Maybe Text,Text,Int64,Bool,Bool,Int64)]
  case ds of
    [(Nothing,_,_,_,_,_)] -> pure False
    [(Just oid,a,n,True,False,seen)] -> do
      os <- query c "SELECT request_json,quote_json,deadline,grace_deadline FROM orders WHERE id=?" (Only oid) :: IO [(Text,Text,Int64,Int64)]
      case os of
        [(r,q,depositEnd,end)] -> do
          req <- fromText r; qt <- fromText q
          previous <- query c "SELECT id FROM obligations WHERE order_id=? AND kind='conversion'" (Only oid) :: IO [Only Text]
          let exact = n==units (gross qt) && a==T.pack (show $ sourceAsset $ direction req)
          if not exact || not (null previous) || now>end || seen>depositEnd
            then execute c "UPDATE orders SET status='NeedsReview' WHERE id=? AND status<>'Paid'" (Only oid) >> pure False
            else do
              holds <- query c "SELECT phase FROM reservations WHERE order_id=?" (Only oid) :: IO [Only Text]
              require (holds == [Only "quote"]) "reservation_not_provisional"
              execute c "INSERT INTO obligations(id,order_id,deposit_id,kind,asset,amount,recipient,status) VALUES(?,?,?,'conversion',?,?,?,'ready')" ("convert:"<>oid,oid,did,T.pack (show (destinationAsset (direction req))),units (net qt),recipient req)
              execute c "UPDATE deposits SET allocated=1 WHERE id=?" (Only did)
              execute c "UPDATE reservations SET phase='obligation' WHERE order_id=?" (Only oid)
              execute c "UPDATE operating_reservations SET phase='obligation' WHERE order_id=? AND phase='quote'" (Only oid)
              execute c "UPDATE orders SET status='Ready' WHERE id=?" (Only oid)
              pure True
        _ -> reject "order_not_found"
    [(_,_,_,_,True,_)] -> pure False
    [(_,_,_,False,_,_)] -> pure False
    _ -> reject "deposit_not_found"

data Obligation = Obligation { obligationId :: !Text, obligationOrder :: !Text, obligationDeposit :: !Text, obligationKind :: !Text, obligationAsset :: !Text, obligationAmount :: !Int64, obligationRecipient :: !Text } deriving (Eq,Show)
instance FromRow Obligation where fromRow = Obligation <$> field <*> field <*> field <*> field <*> field <*> field <*> field
readyObligations :: Ledger -> IO [Obligation]
readyObligations l = ledgerAction l $ \c -> query_ c "SELECT id,order_id,deposit_id,kind,asset,amount,recipient FROM obligations WHERE status='ready' ORDER BY rowid LIMIT 100"
data Attempt = Attempt { attemptId :: !Text, attemptIntent :: !Text, attemptChain :: !Text, attemptBytes :: !Text, attemptPolicy :: !Text, attemptFeeLimit :: !Int64, attemptState :: !Text, attemptSequence :: !(Maybe Int64) } deriving (Eq,Show)
instance FromRow Attempt where fromRow = Attempt <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

-- Reserve the chain and its fee budget before the wallet/helper is invoked.
-- A crash during preparation leaves an intent even if no signed bytes exist.
data Preparation = Preparation
  { preparationObligation :: !Obligation, preparationChain :: !Text
  , preparationFeeLimit :: !Int64, preparationPolicy :: !Text
  , preparationDraft :: !(Maybe Text)
  } deriving (Eq,Show)
instance FromRow Preparation where fromRow = Preparation <$> fromRow <*> field <*> field <*> field <*> field

checkObligation :: Connection -> Obligation -> Text -> IO ()
checkObligation c obligation chain = do
  stored <- query c "SELECT id,order_id,deposit_id,kind,asset,amount,recipient FROM obligations WHERE id=?" (Only $ obligationId obligation)
  require (stored==[obligation]) "obligation_mismatch"
  require (chain == if obligationAsset obligation=="Native" then "Native" else "Solana") "wrong_destination_chain"

beginPreparation :: Ledger -> Config -> Obligation -> Text -> Int64 -> Text -> IO ()
beginPreparation l cfg obligation chain feeLimit policy = ledgerAction l $ \c -> do
  checkObligation c obligation chain
  require (feeLimit>=0 && not (T.null policy) && T.length policy<=16384) "invalid_preparation"
  existing <- query c "SELECT i.chain,f.amount,p.policy_json FROM intents i JOIN preparations p ON p.intent_id=i.id JOIN fee_reservations f ON f.intent_id=i.id WHERE i.id=? AND i.resolved=0 AND p.retired_txid IS NULL" (Only $ obligationId obligation) :: IO [(Text,Int64,Text)]
  case existing of
    [(oldChain,oldLimit,oldPolicy)] -> require ((oldChain,oldLimit,oldPolicy)==(chain,feeLimit,policy)) "preparation_conflict"
    [] -> do
      health <- query_ c "SELECT paused FROM deployment" :: IO [Only Bool]
      require (health==[Only False]) "payouts_paused"
      ds <- query c "SELECT eligible FROM deposits WHERE id=?" (Only $ obligationDeposit obligation) :: IO [Only Bool]
      require (ds==[Only True]) "source_not_eligible"
      state <- query c "SELECT status FROM obligations WHERE id=?" (Only $ obligationId obligation) :: IO [Only Text]
      require (state==[Only "ready"]) "obligation_not_ready"
      busy <- query c "SELECT id FROM intents WHERE chain=? AND resolved=0" (Only chain) :: IO [Only Text]
      require (null busy) "destination_payment_unresolved"
      let feeAsset = if chain=="Native" then "Native" else "Sol"
      transferOrderCosts c cfg (obligationOrder obligation) (obligationKind obligation) feeAsset feeLimit
      old <- query c "SELECT chain,resolved FROM intents WHERE id=?" (Only $ obligationId obligation) :: IO [(Text,Bool)]
      generation <- case old of
        [] -> do
          execute c "INSERT INTO intents(id,obligation_id,chain) VALUES(?,?,?)" (obligationId obligation,obligationId obligation,chain)
          execute c "INSERT INTO fee_reservations(intent_id,asset,amount) VALUES(?,?,?)" (obligationId obligation,feeAsset,feeLimit)
          pure (0::Int)
        [("Solana",True)] | chain=="Solana" -> do
          prior <- query c "SELECT generation,retired_txid FROM preparations WHERE intent_id=? ORDER BY generation" (Only $ obligationId obligation) :: IO [(Int,Maybe Text)]
          unresolved <- query c "SELECT a.txid FROM attempts a LEFT JOIN solana_expiries e ON e.txid=a.txid WHERE a.intent_id=? AND e.txid IS NULL" (Only $ obligationId obligation) :: IO [Only Text]
          require (not (null prior) && length prior<8 && all ((/=Nothing).snd) prior && null unresolved) "solana_retry_not_authorized"
          approved <- query c "SELECT expired_txid FROM solana_retry_approvals WHERE expired_txid=?" (Only $ snd $ last prior) :: IO [Only Text]
          require (map (\(Only tx)->Just tx) approved==[snd $ last prior]) "solana_retry_not_authorized"
          released <- query c "SELECT released FROM fee_reservations WHERE intent_id=?" (Only $ obligationId obligation) :: IO [Only Bool]
          require (released==[Only True]) "solana_retry_fee_hold_conflict"
          execute c "UPDATE intents SET resolved=0 WHERE id=?" (Only $ obligationId obligation)
          execute c "UPDATE fee_reservations SET amount=?,released=0 WHERE intent_id=?" (feeLimit,obligationId obligation)
          pure (1+maximum (map fst prior))
        _ -> reject "previous_intent_not_resolved"
      execute c "INSERT INTO preparations(intent_id,generation,policy_json) VALUES(?,?,?)" (obligationId obligation,generation,policy)
      execute c "UPDATE obligations SET status='paying' WHERE id=?" (Only $ obligationId obligation)
      execute c "UPDATE reservations SET phase='payment' WHERE order_id=? AND phase='obligation'" (Only $ obligationOrder obligation)
      execute c "UPDATE orders SET status='Preparing' WHERE id=? AND status<>'Paid'" (Only $ obligationOrder obligation)
    _ -> reject "duplicate_preparation"

storeDraft :: Ledger -> Text -> Text -> IO ()
storeDraft l intent draft = ledgerAction l $ \c -> do
  require (not (T.null draft) && T.length draft<=200000) "invalid_preparation_draft"
  rows <- query c "SELECT p.draft_json FROM preparations p JOIN intents i ON i.id=p.intent_id WHERE p.intent_id=? AND i.resolved=0 AND p.retired_txid IS NULL" (Only intent) :: IO [Only (Maybe Text)]
  case rows of
    [Only Nothing] -> execute c "UPDATE preparations SET draft_json=? WHERE intent_id=? AND retired_txid IS NULL" (draft,intent)
    [Only (Just old)] -> require (draft==old) "preparation_draft_conflict"
    _ -> reject "preparation_not_found"

pendingPreparations :: Ledger -> IO [Preparation]
pendingPreparations l = ledgerAction l $ \c -> query_ c "SELECT o.id,o.order_id,o.deposit_id,o.kind,o.asset,o.amount,o.recipient,i.chain,f.amount,p.policy_json,p.draft_json FROM preparations p JOIN intents i ON i.id=p.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN fee_reservations f ON f.intent_id=i.id WHERE i.resolved=0 AND p.retired_txid IS NULL AND NOT EXISTS (SELECT 1 FROM attempts a WHERE a.intent_id=i.id AND a.preparation_generation=p.generation) ORDER BY i.rowid"

storeAttempt :: Ledger -> Obligation -> Text -> Text -> Text -> Text -> Int64 -> Maybe Text -> IO ()
storeAttempt l obligation chain txid bytes policy feeLimit commonInput = ledgerAction l $ \c -> do
  checkObligation c obligation chain
  require (not (T.null bytes) && T.length bytes <= 200000 && not (T.null policy) && T.length policy<=32768 && feeLimit>=0) "invalid_attempt"
  prepared <- query c "SELECT f.amount,p.generation FROM intents i JOIN preparations p ON p.intent_id=i.id JOIN fee_reservations f ON f.intent_id=i.id WHERE i.id=? AND i.resolved=0 AND f.released=0 AND p.retired_txid IS NULL" (Only $ obligationId obligation) :: IO [(Int64,Int)]
  generation <- case prepared of [(limit,g)] | limit==feeLimit -> pure g; _ -> reject "payment_not_prepared"
  ds <- query c "SELECT eligible FROM deposits WHERE id=?" (Only $ obligationDeposit obligation) :: IO [Only Bool]
  require (ds==[Only True]) "source_not_eligible"
  state <- query c "SELECT status FROM obligations WHERE id=?" (Only $ obligationId obligation) :: IO [Only Text]
  require (state==[Only "paying"]) "obligation_not_preparing"
  previous <- query c "SELECT txid FROM attempts WHERE intent_id=? AND preparation_generation=?" (obligationId obligation,generation) :: IO [Only Text]
  require (null previous) "attempt_already_recorded"
  execute c "UPDATE intents SET common_input=? WHERE id=?" (commonInput,obligationId obligation)
  execute c "INSERT INTO attempts(txid,intent_id,signed_bytes,policy_json,fee_limit,state,preparation_generation) VALUES(?,?,?,?,?,'signed',?)" (txid,obligationId obligation,bytes,policy,feeLimit,generation)
  execute c "UPDATE orders SET status='Paying' WHERE id=? AND status<>'Paid'" (Only $ obligationOrder obligation)
markBroadcastIntent :: Ledger -> Text -> IO Int64
markBroadcastIntent l txid = ledgerAction l $ \c -> do
  rows <- query c "SELECT a.state,a.critical_sequence,d.eligible FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN deposits d ON d.id=o.deposit_id WHERE a.txid=?" (Only txid) :: IO [(Text,Maybe Int64,Bool)]
  case rows of
    [("broadcast_intent",Just n,_)] -> pure n
    [("signed",_,True)] -> do
      health <- query_ c "SELECT paused FROM deployment" :: IO [Only Bool]
      require (health==[Only False]) "payouts_paused"
      n <- criticalSequence c
      execute c "UPDATE attempts SET state='broadcast_intent',critical_sequence=? WHERE txid=?" (n,txid)
      pure n
    _ -> reject "attempt_not_sendable"
pendingAttempts :: Ledger -> IO [Attempt]
pendingAttempts l = ledgerAction l $ \c -> query_ c "SELECT a.txid,a.intent_id,i.chain,a.signed_bytes,a.policy_json,a.fee_limit,a.state,a.critical_sequence FROM attempts a JOIN intents i ON i.id=a.intent_id LEFT JOIN solana_expiries e ON e.txid=a.txid WHERE i.resolved=0 AND e.txid IS NULL ORDER BY a.rowid"

-- Called only after the chain adapter proves finalized expiry and complete
-- absence. No principal or destination reservation is released. The old bytes
-- and preparation remain immutable; a new generation must reserve its own fees.
recordSolanaExpiry :: Ledger -> Attempt -> Text -> IO ()
recordSolanaExpiry l attempt proof = ledgerAction l $ \c -> do
  require (attemptChain attempt=="Solana" && attemptState attempt `elem` ["signed","broadcast_intent"]
    && not (T.null proof) && T.length proof<=200000) "invalid_solana_expiry"
  prior <- query c "SELECT proof_json FROM solana_expiries WHERE txid=?" (Only $ attemptId attempt) :: IO [Only Text]
  case prior of
    [Only old] -> require (old==proof) "expiry_evidence_conflict"
    [] -> do
      current <- query c "SELECT a.txid,a.intent_id,i.chain,a.signed_bytes,a.policy_json,a.fee_limit,a.state,a.critical_sequence FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE i.id=? AND i.resolved=0 AND NOT EXISTS(SELECT 1 FROM solana_expiries e WHERE e.txid=a.txid)" (Only $ attemptIntent attempt)
      require (current==[attempt]) "expiry_attempt_changed"
      generation <- query c "SELECT p.generation FROM preparations p JOIN attempts a ON a.intent_id=p.intent_id AND a.preparation_generation=p.generation WHERE a.txid=? AND p.retired_txid IS NULL" (Only $ attemptId attempt) :: IO [Only Int]
      require (length generation==1) "expiry_preparation_missing"
      seqNo <- criticalSequence c
      execute c "INSERT INTO solana_expiries(txid,proof_json,critical_sequence) VALUES(?,?,?)" (attemptId attempt,proof,seqNo)
      execute c "UPDATE preparations SET retired_txid=? WHERE intent_id=? AND retired_txid IS NULL" (attemptId attempt,attemptIntent attempt)
      execute c "UPDATE attempts SET state='review',observation_json=? WHERE txid=?" (proof,attemptId attempt)
      execute c "UPDATE fee_reservations SET released=1 WHERE intent_id=?" (Only $ attemptIntent attempt)
      execute c "UPDATE intents SET resolved=1 WHERE id=?" (Only $ attemptIntent attempt)
      execute c "UPDATE obligations SET status='review' WHERE id=? AND status='paying'" (Only $ attemptIntent attempt)
      execute c "UPDATE orders SET status='NeedsReview' WHERE id=(SELECT order_id FROM obligations WHERE id=?) AND status<>'Paid'" (Only $ attemptIntent attempt)
      execute c "INSERT INTO audit(action,detail) VALUES('solana_expiry_verified',?)" (Only $ attemptId attempt)
    _ -> reject "duplicate_expiry"

-- This is a separate, explicit private operator action. An expiry observation
-- never gives the scheduler permission to sign a replacement on its own.
recordSolanaRetryApproval :: Ledger -> Text -> Text -> Text -> IO ()
recordSolanaRetryApproval l txid reason proof = ledgerAction l $ \c -> do
  require (not (T.null $ T.strip reason) && T.length reason<=512 && not (T.null proof) && T.length proof<=200000) "invalid_retry_approval"
  old <- query c "SELECT reason FROM solana_retry_approvals WHERE expired_txid=?" (Only txid) :: IO [Only Text]
  case old of
    [Only previous] -> require (reason==previous) "retry_approval_conflict"
    [] -> do
      health <- query_ c "SELECT paused FROM deployment" :: IO [Only Bool]
      require (health==[Only True]) "pause_before_operator_action"
      rows <- query c "SELECT i.id,i.resolved,o.status,d.eligible,a.state FROM attempts a JOIN solana_expiries e ON e.txid=a.txid JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN deposits d ON d.id=o.deposit_id WHERE a.txid=? AND i.chain='Solana'" (Only txid) :: IO [(Text,Bool,Text,Bool,Text)]
      intent <- case rows of [(i,True,"review",True,"review")]->pure i; _->reject "solana_retry_not_expected"
      latest <- query c "SELECT txid FROM attempts WHERE intent_id=? AND preparation_generation=(SELECT MAX(generation) FROM preparations WHERE intent_id=?)" (intent,intent) :: IO [Only Text]
      require (latest==[Only txid]) "solana_retry_not_latest"
      seqNo <- criticalSequence c
      execute c "INSERT INTO solana_retry_approvals(expired_txid,reason,proof_json,critical_sequence) VALUES(?,?,?,?)" (txid,reason,proof,seqNo)
      execute c "UPDATE obligations SET status='ready' WHERE id=?" (Only intent)
      execute c "UPDATE orders SET status='Ready' WHERE id=(SELECT order_id FROM obligations WHERE id=?)" (Only intent)
      execute c "INSERT INTO audit(action,detail) VALUES('solana_retry_approved',?)" (Only txid)
    _ -> reject "duplicate_retry_approval"

-- Recheck after a backup wait, even when BroadcastIntent was already recorded.
-- Returning its sequence alone never grants permission to send old signed data.
authorizeRecordedSend :: Ledger -> Bool -> Text -> IO Attempt
authorizeRecordedSend l remote txid = ledgerAction l $ \c -> do
  attempts <- query c "SELECT a.txid,a.intent_id,i.chain,a.signed_bytes,a.policy_json,a.fee_limit,a.state,a.critical_sequence FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE a.txid=? AND i.resolved=0" (Only txid)
  attempt <- case attempts of [a] -> pure a; _ -> reject "attempt_not_sendable"
  require (attemptState attempt=="broadcast_intent") "broadcast_intent_required"
  sequenceNumber <- maybe (reject "broadcast_intent_required") pure (attemptSequence attempt)
  requireBackup c remote sequenceNumber
  source <- query c "SELECT d.eligible,o.status FROM intents i JOIN obligations o ON o.id=i.obligation_id JOIN deposits d ON d.id=o.deposit_id WHERE i.id=?" (Only $ attemptIntent attempt) :: IO [(Bool,Text)]
  require (source==[(True,"paying")]) "source_not_eligible"
  health <- query_ c "SELECT paused FROM deployment" :: IO [Only Bool]
  require (health==[Only False]) "payouts_paused"
  pure attempt

data PaymentCosts = PaymentCosts { networkFee :: !Amount, accountRent :: !Amount }
  deriving (Eq,Show,Generic,ToJSON,FromJSON)

recordSettlement :: Ledger -> Text -> PaymentCosts -> Text -> IO ()
recordSettlement l txid costs evidence = ledgerAction l $ \c -> do
  require (not (T.null evidence) && T.length evidence<=32768) "settlement_fee_or_evidence_invalid"
  let saved=jsonText $ object ["costs" .= costs,"proof" .= evidence]
      actualCost=toInteger (units $ networkFee costs)+toInteger (units $ accountRent costs)
  rows <- query c "SELECT a.state,a.fee_limit,o.id,o.order_id,d.asset,d.amount,o.asset,o.amount,q.quote_json,o.kind FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN deposits d ON d.id=o.deposit_id JOIN orders q ON q.id=o.order_id WHERE a.txid=?" (Only txid) :: IO [(Text,Int64,Text,Text,Text,Int64,Text,Int64,Text,Text)]
  case rows of
    [("settled",_,_,_,_,_,_,_,_,_)] -> do
      old <- query c "SELECT observation_json FROM attempts WHERE txid=?" (Only txid) :: IO [Only Text]
      require (old==[Only saved]) "settlement_evidence_conflict"
    [("broadcast_intent",limit,intent,oid,src,g,dst,n,qj,kind)] -> do
      require (units (networkFee costs)>0 && actualCost<=toInteger limit && (dst/="Native" || units (accountRent costs)==0)) "settlement_fee_or_evidence_invalid"
      q <- fromText qj
      source <- parseAsset src; dest <- parseAsset dst
      let feeAsset = if dest==Native then Native else Sol
      let flow = if kind=="refund"
            then [(source,"principal",negate $ toInteger g),(source,"external",toInteger g)]
            else [(source,"principal",negate $ toInteger g),(source,"float",toInteger $ units $ net q),(source,"earned",toInteger $ units $ fee q)
                 ,(dest,"float",negate $ toInteger n),(dest,"external",toInteger n)]
      posting c ("settlement:"<>txid) "successful finalized payout" flow
      forM_ [("network-fee",networkFee costs),("account-rent",accountRent costs)] $ \(label,cost) ->
        when (units cost>0) $ posting c (label<>":"<>txid) label
          [(feeAsset,"operating",negate $ toInteger $ units cost),(feeAsset,"external",toInteger $ units cost)]
      execute c "UPDATE attempts SET state='settled',observation_json=? WHERE txid=?" (saved,txid)
      execute c "UPDATE fee_reservations SET released=1 WHERE intent_id=?" (Only intent)
      execute c "UPDATE intents SET resolved=1 WHERE id=?" (Only intent)
      execute c "UPDATE obligations SET status='paid' WHERE id=?" (Only intent)
      if kind=="refund"
        then execute c "UPDATE orders SET status='Refunded',payout_tx=? WHERE id=? AND status<>'Paid'" (txid,oid)
        else execute c "UPDATE orders SET status='Paid',payout_tx=? WHERE id=?" (txid,oid)
      execute c "UPDATE reservations SET phase='released' WHERE order_id=?" (Only oid)
      execute c "UPDATE operating_reservations SET phase='released' WHERE order_id=? AND phase IN('quote','obligation')" (Only oid)
    _ -> reject "settlement_not_expected"
 where
  parseAsset "Native" = pure Native
  parseAsset "Wrapped" = pure Wrapped
  parseAsset _ = reject "invalid_payout_asset"
addHint :: Ledger -> Text -> Text -> Text -> IO ()
addHint l capability oid sig = do
  cap <- either reject pure (capabilityHash capability)
  require (T.length sig >= 64 && T.length sig <= 88) "invalid_signature_hint"
  ledgerAction l $ \c -> do
    _ <- readOrderC c cap oid
    counts <- query c "SELECT count(*) FROM hints WHERE order_id=?" (Only oid) :: IO [Only Int]
    require (case counts of [Only n] -> n<8; _ -> False) "hint_limit"
    execute c "INSERT OR IGNORE INTO hints(order_id,signature) VALUES(?,?)" (oid,sig)
auditExport :: Ledger -> IO Value
auditExport l = ledgerAction l auditExportC
auditExportWithBudget :: Ledger -> Config -> IO Value
auditExportWithBudget l cfg = ledgerAction l $ \c -> do
  audit <- auditExportC c
  budget <- operatingBudget c cfg
  case audit of Object fields -> pure $ Object (KM.insert "operatingBudget" budget fields); _ -> reject "invalid_audit_export"
auditExportC :: Connection -> IO Value
auditExportC c = do
  bs <- balances c
  events <- query_ c "SELECT id,description FROM events ORDER BY rowid" :: IO [(Text,Text)]
  pending <- query_ c "SELECT id,status FROM obligations WHERE status<>'paid' ORDER BY rowid" :: IO [(Text,Text)]
  pure $ object ["balances" .= [object ["asset" .= a,"allocation" .= account,"units" .= T.pack(show n)] | ((a,account),n) <- M.toList bs],"events" .= events,"unresolved" .= pending]

-- Refunds use the immutable native refund address or the bound Solana owner.
-- They consume source principal, never a second reservation of payout float.
createRefund :: Ledger -> Text -> IO Obligation
createRefund l did = ledgerAction l $ \c -> do
  existing <- query c "SELECT id,order_id,deposit_id,kind,asset,amount,recipient FROM obligations WHERE deposit_id=? AND kind='refund'" (Only did)
  case existing of
    [ob] -> pure ob
    [] -> do
      rows <- query c "SELECT d.order_id,d.asset,d.amount,d.eligible,o.request_json FROM deposits d JOIN orders o ON o.id=d.order_id WHERE d.id=?" (Only did) :: IO [(Text,Text,Int64,Bool,Text)]
      case rows of
        [(oid,asset,n,True,r)] -> do
          pending <- query c "SELECT i.id FROM intents i JOIN obligations o ON o.id=i.obligation_id WHERE o.order_id=? AND i.resolved=0" (Only oid) :: IO [Only Text]
          require (null pending) "refund_would_race_payment"
          others <- query c "SELECT id FROM obligations WHERE order_id=? AND deposit_id<>? AND status NOT IN('paid','cancelled')" (oid,did) :: IO [Only Text]
          require (null others) "other_obligation_must_resolve_before_refund"
          old <- query c "SELECT id,status FROM obligations WHERE deposit_id=? AND status<>'cancelled'" (Only did) :: IO [(Text,Text)]
          case old of
            [] -> pure ()
            [(oldId,state)] -> do
              require (state `elem` ["ready","review"]) "principal_already_resolved"
              -- Preserve the cancelled conversion and its source binding. A partial
              -- unique index allows exactly one active allocation of the deposit.
              execute c "UPDATE obligations SET status='cancelled' WHERE id=?" (Only oldId)
            _ -> reject "duplicate_obligation"
          req <- fromText r
          require (asset==T.pack (show $ sourceAsset $ direction req)) "unsupported_refund_asset"
          let recipient = refund req
              ob = Obligation ("refund:"<>did) oid did "refund" asset n recipient
          execute c "INSERT INTO obligations(id,order_id,deposit_id,kind,asset,amount,recipient,status) VALUES(?,?,?,'refund',?,?,?,'ready')" (obligationId ob,oid,did,asset,n,recipient)
          execute c "UPDATE deposits SET allocated=1 WHERE id=?" (Only did)
          execute c "UPDATE reservations SET phase='released' WHERE order_id=?" (Only oid)
          execute c "UPDATE operating_reservations SET phase='released' WHERE order_id=? AND kind='conversion' AND phase IN('quote','obligation')" (Only oid)
          execute c "UPDATE operating_reservations SET phase='obligation' WHERE order_id=? AND kind='refund' AND phase='quote'" (Only oid)
          execute c "UPDATE orders SET status='Refunding' WHERE id=? AND status<>'Paid'" (Only oid)
          execute c "INSERT INTO audit(action,detail) VALUES('refund_authorized',?)" (Only did)
          pure ob
        _ -> reject "refundable_deposit_not_found"
    _ -> reject "duplicate_refund"

recordFailedSolana :: Ledger -> Text -> Int64 -> Text -> IO ()
recordFailedSolana l txid actualFee evidence = ledgerAction l $ \c -> do
  rows <- query c "SELECT a.state,a.fee_limit,a.intent_id,i.chain FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE txid=?" (Only txid) :: IO [(Text,Int64,Text,Text)]
  case rows of
    [("failed",_,_,"Solana")] -> do
      old <- query c "SELECT observation_json FROM attempts WHERE txid=?" (Only txid) :: IO [Only Text]
      charged <- query c "SELECT delta FROM postings WHERE event_id=? AND account='external'" (Only $ "failed-fee:"<>txid) :: IO [Only Int64]
      require (old==[Only evidence] && charged==[Only actualFee]) "failure_evidence_conflict"
    [("broadcast_intent",limit,intent,"Solana")] -> do
      require (actualFee>0 && actualFee<=limit && not (T.null evidence) && T.length evidence<=32768) "invalid_failure_evidence"
      posting c ("failed-fee:"<>txid) "finalized Solana failure network fee" [(Sol,"operating",negate $ toInteger actualFee),(Sol,"external",toInteger actualFee)]
      execute c "UPDATE attempts SET state='failed',observation_json=? WHERE txid=?" (evidence,txid)
      execute c "UPDATE intents SET resolved=1 WHERE id=?" (Only intent)
      execute c "UPDATE fee_reservations SET released=1 WHERE intent_id=?" (Only intent)
      execute c "UPDATE obligations SET status='review' WHERE id=?" (Only intent)
      execute c "UPDATE orders SET status='NeedsReview' WHERE id=(SELECT order_id FROM obligations WHERE id=?)" (Only intent)
    _ -> reject "failure_not_proven"
