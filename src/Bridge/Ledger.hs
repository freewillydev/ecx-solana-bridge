{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
module Bridge.Ledger
  ( Ledger, withLedger, ledgerAction, sqliteIdentity, readiness, pause, resumeAfterChecks
  , createOrder, readOrder, bindInstruction, criticalSequence, acknowledgeBackup
  , exposeOrder, freeInventory, fundAllocation, expireQuotes
  , Deposit(..), observeDeposit, recordScan, readCheckpoint, promoteDeposit, checkpoint
  , Obligation(..), readyObligations, Attempt(..), storeAttempt, markBroadcastIntent
  , pendingAttempts, recordSettlement, createRefund, recordFailedSolana, requireBackup, addHint, auditExport
  ) where

import Bridge.Config
import Bridge.Types
import Control.Concurrent.MVar
import Control.Exception (bracket)
import Control.Monad (forM_, when)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.FileEmbed (embedFile)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FileLock (SharedExclusive(Exclusive), tryLockFile, unlockFile)
import System.FilePath (takeDirectory)
import System.Posix.Files (setFileMode)

-- All financial mutations are serialized and committed before external IO.
newtype Ledger = Ledger (MVar Connection)
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
    require (meta == [(1,identity)]) "ledger_profile_or_schema_mismatch"
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
fundAllocation :: Ledger -> Text -> Asset -> Text -> Amount -> IO ()
fundAllocation l proof asset account a = ledgerAction l $ \c -> do
  require (account `elem` ["float","backing","operating","lp"] && units a > 0) "invalid_allocation"
  posting c ("fund:"<>proof) "verified treasury receipt" [(asset,account,toInteger (units a)),(asset,"external",negate $ toInteger $ units a)]

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
        pending <- query_ c "SELECT count(*) FROM orders WHERE status NOT IN('Paid','Refunded','ExpiredUnfunded')" :: IO [Only Int]
        require (case pending of [Only n] -> n < maxQueued cfg; _ -> False) "queue_full"
        inventory <- freeInventory c (destinationAsset (direction req))
        require (inventory >= toInteger (units (net q))) "insufficient_inventory"
        let end = now+quoteSeconds cfg
        execute c "INSERT INTO orders(id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,status,deadline,grace_deadline) VALUES(?,?,?,?,?,?,?,'Provisioning',?,?)" (oid,cap,idempotencyKey req,rh,jsonText req,jsonText q,jsonText (PolicySnapshot (nativeConfirmations cfg) "finalized" (fingerprint cfg)),end,end+confirmationGraceSeconds cfg)
        execute c "INSERT INTO reservations(order_id,asset,amount,phase) VALUES(?,?,?,'quote')" (oid,T.pack (show (destinationAsset (direction req))),units (net q))
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
  execute c "UPDATE orders SET status='ExpiredUnfunded' WHERE grace_deadline<? AND status IN('Provisioning','AwaitingDeposit') AND NOT EXISTS (SELECT 1 FROM deposits WHERE deposits.order_id=orders.id)" (Only now)

data Deposit = Deposit { depositId :: !Text, depositOrder :: !(Maybe Text), depositAsset :: !Asset, depositAmount :: !Amount, depositAnchor :: !Text, depositConfirmations :: !Int, depositEligible :: !Bool, depositSeenAt :: !Int64 } deriving (Eq,Show)
observeDeposit :: Ledger -> Deposit -> Text -> IO ()
observeDeposit l deposit cursor = ledgerAction l $ \c -> do
  observeDepositC c deposit
  checkpoint c (T.pack (show (depositAsset deposit))) cursor

-- The whole page and its continuation commit together. A stale scanner cannot
-- advance a newer cursor, and one invalid receipt rolls back the complete page.
recordScan :: Ledger -> Text -> Maybe Text -> Text -> [Deposit] -> IO ()
recordScan l chain previous next deposits = ledgerAction l $ \c -> do
  require (chain `elem` ["Native","Solana"] && not (T.null next) && T.length next<=128 && length deposits<=1000) "invalid_scan_batch"
  require (all (\d -> depositAsset d == if chain=="Native" then Native else Wrapped) deposits) "scan_asset_mismatch"
  actual <- readCheckpointC c chain
  require (actual==previous) "stale_scan_cursor"
  mapM_ (observeDepositC c) deposits
  checkpoint c chain next

readCheckpoint :: Ledger -> Text -> IO (Maybe Text)
readCheckpoint l chain = ledgerAction l (\c -> readCheckpointC c chain)
readCheckpointC :: Connection -> Text -> IO (Maybe Text)
readCheckpointC c chain = do
  rows <- query c "SELECT anchor FROM checkpoints WHERE chain=?" (Only chain) :: IO [Only Text]
  case rows of [] -> pure Nothing; [Only anchor] -> pure (Just anchor); _ -> reject "duplicate_checkpoint"

observeDepositC :: Connection -> Deposit -> IO ()
observeDepositC c Deposit{..} = do
  require (units depositAmount>0 && depositConfirmations>=0 && depositSeenAt>=0 && depositAsset `elem` [Native,Wrapped]) "invalid_deposit"
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
storeAttempt :: Ledger -> Obligation -> Text -> Text -> Text -> Text -> Int64 -> Maybe Text -> IO ()
storeAttempt l obligation chain txid bytes policy feeLimit commonInput = ledgerAction l $ \c -> do
  stored <- query c "SELECT id,order_id,deposit_id,kind,asset,amount,recipient FROM obligations WHERE id=?" (Only $ obligationId obligation)
  require (stored==[obligation]) "obligation_mismatch"
  require (chain == if obligationAsset obligation=="Native" then "Native" else "Solana") "wrong_destination_chain"
  require (not (T.null bytes) && T.length bytes <= 200000 && feeLimit>=0) "invalid_attempt"
  ds <- query c "SELECT eligible FROM deposits WHERE id=?" (Only $ obligationDeposit obligation) :: IO [Only Bool]
  require (ds==[Only True]) "source_not_eligible"
  state <- query c "SELECT status FROM obligations WHERE id=?" (Only $ obligationId obligation) :: IO [Only Text]
  require (state==[Only "ready"]) "obligation_not_ready"
  execute c "INSERT INTO intents(id,obligation_id,chain,common_input) VALUES(?,?,?,?)" (obligationId obligation,obligationId obligation,chain,commonInput)
  let feeAsset = if chain=="Native" then "Native" else "Sol"
  bs <- balances c
  reserved <- query c "SELECT amount FROM fee_reservations WHERE asset=? AND released=0" (Only feeAsset) :: IO [Only Int64]
  require (M.findWithDefault 0 (feeAsset,"operating") bs - sum [toInteger n | Only n <- reserved] >= toInteger feeLimit) "insufficient_fee_budget"
  execute c "INSERT INTO fee_reservations(intent_id,asset,amount) VALUES(?,?,?)" (obligationId obligation,feeAsset,feeLimit)
  execute c "INSERT INTO attempts(txid,intent_id,signed_bytes,policy_json,fee_limit,state) VALUES(?,?,?,?,?,'signed')" (txid,obligationId obligation,bytes,policy,feeLimit)
  execute c "UPDATE obligations SET status='paying' WHERE id=?" (Only $ obligationId obligation)
  execute c "UPDATE reservations SET phase='payment' WHERE order_id=? AND phase='obligation'" (Only $ obligationOrder obligation)
  execute c "UPDATE orders SET status='Paying' WHERE id=?" (Only $ obligationOrder obligation)
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
pendingAttempts l = ledgerAction l $ \c -> query_ c "SELECT a.txid,a.intent_id,i.chain,a.signed_bytes,a.policy_json,a.fee_limit,a.state,a.critical_sequence FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE i.resolved=0 ORDER BY a.rowid"
recordSettlement :: Ledger -> Text -> Int64 -> Text -> IO ()
recordSettlement l txid actualFee evidence = ledgerAction l $ \c -> do
  rows <- query c "SELECT a.state,a.fee_limit,o.id,o.order_id,d.asset,d.amount,o.asset,o.amount,q.quote_json,o.kind FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN deposits d ON d.id=o.deposit_id JOIN orders q ON q.id=o.order_id WHERE a.txid=?" (Only txid) :: IO [(Text,Int64,Text,Text,Text,Int64,Text,Int64,Text,Text)]
  case rows of
    [("settled",_,_,_,_,_,_,_,_,_)] -> pure ()
    [("broadcast_intent",limit,intent,oid,src,g,dst,n,qj,kind)] -> do
      require (actualFee>=0 && actualFee<=limit && not (T.null evidence)) "settlement_fee_or_evidence_invalid"
      q <- fromText qj
      source <- parseAsset src; dest <- parseAsset dst
      let feeAsset = if dest==Native then Native else Sol
      let flow = if kind=="refund"
            then [(source,"principal",negate $ toInteger g),(source,"external",toInteger g)]
            else [(source,"principal",negate $ toInteger g),(source,"float",toInteger $ units $ net q),(source,"earned",toInteger $ units $ fee q)
                 ,(dest,"float",negate $ toInteger n),(dest,"external",toInteger n)]
      posting c ("settlement:"<>txid) "successful finalized payout" (flow<>
        [(feeAsset,"operating",negate $ toInteger actualFee),(feeAsset,"external",toInteger actualFee)])
      execute c "UPDATE attempts SET state='settled',observation_json=? WHERE txid=?" (evidence,txid)
      execute c "UPDATE fee_reservations SET released=1 WHERE intent_id=?" (Only intent)
      execute c "UPDATE intents SET resolved=1 WHERE id=?" (Only intent)
      execute c "UPDATE obligations SET status='paid' WHERE id=?" (Only intent)
      if kind=="refund"
        then execute c "UPDATE orders SET status='Refunded',payout_tx=? WHERE id=? AND status<>'Paid'" (txid,oid)
        else execute c "UPDATE orders SET status='Paid',payout_tx=? WHERE id=?" (txid,oid)
      execute c "UPDATE reservations SET phase='released' WHERE order_id=?" (Only oid)
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
auditExport l = ledgerAction l $ \c -> do
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
          execute c "UPDATE orders SET status='Refunding' WHERE id=? AND status<>'Paid'" (Only oid)
          execute c "INSERT INTO audit(action,detail) VALUES('refund_authorized',?)" (Only did)
          pure ob
        _ -> reject "refundable_deposit_not_found"
    _ -> reject "duplicate_refund"

recordFailedSolana :: Ledger -> Text -> Int64 -> Text -> IO ()
recordFailedSolana l txid actualFee evidence = ledgerAction l $ \c -> do
  rows <- query c "SELECT a.state,a.fee_limit,a.intent_id,i.chain FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE txid=?" (Only txid) :: IO [(Text,Int64,Text,Text)]
  case rows of
    [("failed",_,_,"Solana")] -> pure ()
    [("broadcast_intent",limit,intent,"Solana")] -> do
      require (actualFee>=0 && actualFee<=limit && not (T.null evidence)) "invalid_failure_evidence"
      posting c ("failed-fee:"<>txid) "finalized Solana failure network fee" [(Sol,"operating",negate $ toInteger actualFee),(Sol,"external",toInteger actualFee)]
      execute c "UPDATE attempts SET state='failed',observation_json=? WHERE txid=?" (evidence,txid)
      execute c "UPDATE intents SET resolved=1 WHERE id=?" (Only intent)
      execute c "UPDATE fee_reservations SET released=1 WHERE intent_id=?" (Only intent)
      execute c "UPDATE obligations SET status='review' WHERE id=?" (Only intent)
      execute c "UPDATE orders SET status='NeedsReview' WHERE id=(SELECT order_id FROM obligations WHERE id=?)" (Only intent)
    _ -> reject "failure_not_proven"
