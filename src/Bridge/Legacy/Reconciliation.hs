{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Bridge.Legacy.Reconciliation (reconcileCustody,reconcileCustodyWith) where
import Bridge.Legacy.PaymentLifecycle ()
import Bridge.Reconciliation
import Bridge.Ledger
import Bridge.Config
import Bridge.Types
import Bridge.Settlement
import Bridge.Observer (epochSeconds)
import Bridge.RPC (fieldValue)
import Control.Exception (IOException,catch,try)
import Control.Monad (when)
import Data.Aeson hiding (decode)
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)
import Text.Read (readMaybe)

json :: ToJSON a => a -> Text
json=TE.decodeUtf8 . LBS.toStrict . encode
decode :: FromJSON a => Text -> IO a
decode=either (const $ reject "invalid_reconciliation_evidence") pure . eitherDecodeStrict' . TE.encodeUtf8

reconcileCustody :: Manager -> Config -> Ledger -> IO Value
reconcileCustody manager c = reconcileCustodyWith epochSeconds
  (realPaymentTransport manager c (const $ reject "unexpected_reconciliation_backup")) c

readView :: Config -> Ledger -> Int64 -> Bool -> IO View
readView c ledger now inspectLosses=ledgerAction ledger $ \db -> do
  revisions <- query_ db "SELECT revision FROM custody_check" :: IO [Only Int64]
  revision <- case revisions of [Only r]->pure r; _->reject "custody_check_missing"
  scans <- query_ db "SELECT h.chain,h.last_success,h.last_error,p.anchor FROM scan_health h JOIN checkpoints p ON p.chain=h.chain ORDER BY h.chain" :: IO [(Text,Maybe Int64,Maybe Text,Text)]
  require (now>=0 && map (\(s,_,_,_)->s) scans==["Native","Solana","SolanaOperating"]
    && all (\(_,at,err,anchor)->err==Nothing && not (T.null anchor)
      && maybe False (\t->t>=0 && t<=now && toInteger now-toInteger t<=60) at) scans) "scanners_not_fresh"
  origins <- query_ db "SELECT chain,anchor FROM scan_origins ORDER BY chain" :: IO [(Text,Text)]
  require (map (\(s,a)->(s,Just a)) origins==[("Native",Just $ nativeCheckpointHash c)
    ,("Solana",solanaHistoryStart c),("SolanaOperating",solanaOperatingHistoryStart c)]) "custody_scan_origin_mismatch"
  reviews <- query_ db "SELECT event_id FROM chain_events WHERE needs_review=1 LIMIT 1" :: IO [Only Text]
  require (null reviews) "chain_observations_require_review"
  lost <- query db "SELECT id FROM deposits WHERE allocated=1 AND eligible=0 AND id NOT IN(SELECT deposit_id FROM accounted_source_losses) AND (?=0 OR id NOT IN(SELECT deposit_id FROM proven_source_losses)) LIMIT 1" (Only inspectLosses) :: IO [Only Text]
  require (null lost) "source_reorg_requires_review"
  sourceReviews <- query db "SELECT deposit_id FROM source_recovery_state WHERE state<>'restored' AND deposit_id NOT IN(SELECT deposit_id FROM accounted_source_losses) AND (?=0 OR deposit_id NOT IN(SELECT deposit_id FROM proven_source_losses)) LIMIT 1" (Only inspectLosses) :: IO [Only Text]
  require (null sourceReviews) "source_recovery_requires_review"
  nativeReviews <- query_ db "SELECT txid FROM native_payment_recovery_state WHERE state<>'reconfirmed' LIMIT 1" :: IO [Only Text]
  require (null nativeReviews) "native_settlement_requires_review"
  -- A changed settlement needs explicit recovery even when offsetting
  -- transfers leave the custody total equal. Reconfirmation updates its proof.
  changed <- query_ db "SELECT a.txid FROM attempts a JOIN intents i ON i.id=a.intent_id LEFT JOIN chain_events e ON e.chain=i.chain AND e.event_id=a.txid WHERE a.state='settled' AND (e.event_id IS NULL OR e.kind<>'outgoing' OR CASE i.chain WHEN 'Native' THEN e.anchor IS NOT json_extract(json_extract(a.observation_json,'$.proof'),'$.blockhash') OR COALESCE(json_extract((SELECT evidence_json FROM observation_evidence WHERE hash=e.evidence_hash),'$.proof.confirmations'),-1)<json_extract(json_extract(a.observation_json,'$.proof'),'$.requiredDepth') ELSE e.anchor IS NOT CAST(json_extract(json_extract(a.observation_json,'$.proof'),'$.outcome.outcomeSlot') AS TEXT) END) LIMIT 1" :: IO [Only Text]
  require (null changed) "settled_payment_observation_changed"
  operatingChanged <- query_ db "SELECT a.txid FROM attempts a JOIN intents i ON i.id=a.intent_id LEFT JOIN chain_events e ON e.chain='SolanaOperating' AND e.event_id=a.txid LEFT JOIN chain_events t ON t.chain='Solana' AND t.event_id=a.txid WHERE i.chain='Solana' AND a.state IN('settled','failed') AND (e.kind IS NOT 'outgoing' OR e.anchor IS NOT CAST(CASE a.state WHEN 'settled' THEN json_extract(json_extract(a.observation_json,'$.proof'),'$.outcome.outcomeSlot') ELSE json_extract(a.observation_json,'$.outcome.outcomeSlot') END AS TEXT) OR t.anchor IS NOT e.anchor OR t.kind IS NOT CASE a.state WHEN 'settled' THEN 'outgoing' ELSE 'failed' END) LIMIT 1" :: IO [Only Text]
  require (null operatingChanged) "booked_solana_observation_changed"
  totals <- fold_ db "SELECT asset,account,delta FROM postings ORDER BY id" M.empty $ \m (asset,account,n::Int64) ->
    pure $! M.insertWith add asset (if account==("external"::Text) then 0 else toInteger n,toInteger n) m
  require (all (\(asset,(owned,total))->asset `elem` ["Native","Wrapped","Sol"] && owned>=0 && total==0) (M.toList totals)) "invalid_custody_journal"
  slots <- query_ db "SELECT e.anchor FROM checkpoints p JOIN chain_events e ON e.chain=p.chain AND e.event_id=p.anchor WHERE p.chain IN('Solana','SolanaOperating') ORDER BY p.chain" :: IO [Only Text]
  numbers <- mapM (\(Only s)->maybe (reject "custody_history_anchor_missing") pure (readMaybe $ T.unpack s)) slots
  require (length numbers==2 && all (>=0) numbers) "custody_history_anchor_missing"
  pure $ View revision (M.fromList [(asset,maybe 0 fst $ M.lookup asset totals) | asset<-["Native","Wrapped","Sol"]])
    [(stream,anchor) | (stream,_,_,anchor)<-scans] (maximum numbers)
 where add (a,b) (c',d)=let x=a+c'; y=b+d in x `seq` y `seq` (x,y)

reconcileCustodyWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> IO Value
reconcileCustodyWith clock transport c ledger=do
  result <- try (work `catch` (\(_::IOException)->reject "custody_rpc_unavailable")) :: IO (Either BridgeError ())
  case result of
    Right ()->pure ()
    Left (BridgeError code)->do
      at <- clock
      ledgerAction ledger $ \db -> do
        recordError db code
        execute db "UPDATE custody_check SET checked_revision=NULL,checked_at=?,last_error=?,report_json=NULL" (at,code)
  custodyHealth ledger
 where
  work=do
    (revision,at,matches,report) <- inspectCustodyWith clock transport c ledger False
    ledgerAction ledger $ \db -> do
      current <- query_ db "SELECT revision FROM custody_check" :: IO [Only Int64]
      require (current==[Only $ revision]) "custody_ledger_changed"
      let err=if matches then Nothing else Just ("custody_balance_mismatch"::Text)
      mapM_ (recordError db) err
      execute db "UPDATE custody_check SET checked_revision=?,checked_at=?,last_error=?,report_json=?"
        (revision,at,err,json report)

-- This inspection checks physical custody including proved deficits, but never
-- certifies the ordinary custody gate or ignores unavailable/unknown history.

recordError :: Connection -> Text -> IO ()
recordError db code=do
  old <- query_ db "SELECT last_error FROM custody_check" :: IO [Only (Maybe Text)]
  when (old/=[Only (Just code)]) $ execute db "INSERT INTO audit(action,detail) VALUES('custody_failure',?)" (Only code)
  -- These snapshots grant no spending permission: checked_revision is cleared
  -- below. Let the next scan retry, without turning routine chain progress
  -- into a permanent operator pause. Never clear an existing pause.
  when (code `notElem` ["custody_native_history_advanced","custody_solana_history_advanced","custody_ledger_changed"]) $
    execute db "UPDATE deployment SET paused=1,pause_reason=?" (Only $ "custody:"<>code)

eventProof :: Ledger -> Text -> Text -> IO (Text,Text,Value)
eventProof ledger stream txid=ledgerAction ledger $ \db -> do
  rows <- query db "SELECT e.kind,e.anchor,o.evidence_json FROM chain_events e JOIN observation_evidence o ON o.hash=e.evidence_hash WHERE e.chain=? AND e.event_id=? AND e.needs_review=0" (stream,txid) :: IO [(Text,Text,Text)]
  case rows of
    [(kind,anchor,saved)]->do
      proof <- decode saved >>= fieldValue "proof"
      pure (kind,anchor,proof)
    _->reject "custody_history_not_current"

instance CustodyStore Ledger where
  custodyView = readView
  custodyPending = pendingAttempts
  custodyProof = eventProof
  custodyDepth = maximumNativeDepth
  custodyRevision ledger = ledgerAction ledger $ \db->do
    rows <- query_ db "SELECT revision FROM custody_check" :: IO [Only Int64]
    case rows of [Only revision]->pure revision; _->reject "custody_check_missing"
  custodyHasEvent ledger txid chain = ledgerAction ledger $ \db->do
    rows <- query db "SELECT event_id FROM chain_events WHERE event_id=? AND chain IN(?,?) LIMIT 1"
      (txid,chain,if chain=="Solana" then "SolanaOperating"::Text else "Native") :: IO [Only Text]
    pure (not $ null rows)
