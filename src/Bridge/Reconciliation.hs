{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Reconciliation (reconcileCustody, reconcileCustodyWith) where

import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment
import Bridge.Observer (epochSeconds,SignatureInfo(..))
import Bridge.RPC
import Bridge.Settlement
import Bridge.Solana
import Bridge.SolanaPayment
import Bridge.Types
import Control.Exception (IOException,catch,try)
import Control.Monad (forM_,when)
import Data.Aeson hiding (decode)
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)
import Text.Read (readMaybe)

-- Read-only on both chains: a check cannot authorize a payout, allocate a
-- receipt, clear a review flag, or resume a paused deployment.
reconcileCustody :: Manager -> Config -> Ledger -> IO Value
reconcileCustody manager c = reconcileCustodyWith epochSeconds
  (realPaymentTransport manager c (const $ reject "unexpected_reconciliation_backup")) c

data View = View
  { viewRevision :: !Int64, viewTotals :: !(M.Map Text Integer)
  , viewHeads :: ![(Text,Text)], viewSlot :: !Int64
  }
json :: ToJSON a => a -> Text
json=TE.decodeUtf8 . LBS.toStrict . encode
decode :: FromJSON a => Text -> IO a
decode=either (const $ reject "invalid_reconciliation_evidence") pure . eitherDecodeStrict' . TE.encodeUtf8

-- Integer totals avoid SQLite SUM's overflow on a valid append-only journal.
readView :: Config -> Ledger -> Int64 -> IO View
readView c ledger now=ledgerAction ledger $ \db -> do
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
  lost <- query_ db "SELECT id FROM deposits WHERE allocated=1 AND eligible=0 LIMIT 1" :: IO [Only Text]
  require (null lost) "source_reorg_requires_review"
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

headFor :: View -> Text -> IO Text
headFor v stream=maybe (reject "custody_history_anchor_missing") pure (lookup stream $ viewHeads v)

-- No RPC holds a database transaction. Concurrent observations or settlements
-- invalidate this revision before it can be certified. Failed reads also pause.
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
  native=paymentNative transport
  work=do
    at <- clock
    view <- readView c ledger at
    paymentIdentity transport
    before <- nativeBalance native
    attempts <- pendingAttempts ledger
    require (length attempts<=2 && length (nub $ map attemptChain attempts)==length attempts) "custody_attempt_bounds"
    effects <- concat <$> mapM (pendingEffect transport c ledger) attempts
    (slot,wrapped,sol) <- solanaBalances (paymentSolana transport) c ledger view
    case paymentVerifier transport of
      Nothing->require (profile c/=CanonicalBeta && solanaVerifierRpc c==Nothing) "independent_rpc_required"
      Just verifier->do
        (_,w,s) <- solanaBalances verifier c ledger view
        require ((w,s)==(wrapped,sol)) "custody_verifier_disagreement"
    nativeFence native c ledger view
    after <- nativeBalance native
    require (before==after) "custody_native_view_changed"
    let (nativeUnits,block,height)=after
    active <- native False "getblockhash" [toJSON height] >>= parseValue parseJSON
    require (active==block) "custody_native_view_changed"
    end <- clock
    require (end>=at && toInteger end-toInteger at<=60) "custody_check_timed_out"
    let observed=M.fromList [("Native",nativeUnits),("Wrapped",wrapped),("Sol",sol)]
        adjustments=M.fromListWith (+) [(asset,delta) | (_,asset,delta)<-effects]
        rows=[(asset,n,M.findWithDefault 0 asset adjustments,M.findWithDefault 0 asset observed) | (asset,n)<-M.toList $ viewTotals view]
        matches=all (\(_,booked,delta,actual)->booked+delta>=0 && booked+delta==actual) rows
        report=object ["matches" .= matches,"nativeBlock" .= block,"nativeHeight" .= height,"solanaSlot" .= slot
          ,"assets" .= [object ["asset" .= asset,"booked" .= T.pack(show booked),"inFlight" .= T.pack(show delta)
            ,"expected" .= T.pack(show $ booked+delta),"observed" .= T.pack(show actual),"difference" .= T.pack(show $ actual-booked-delta)] | (asset,booked,delta,actual)<-rows]
          ,"inFlightEffects" .= [object ["transaction" .= txid,"asset" .= asset,"units" .= T.pack(show n)] | (txid,asset,n)<-effects]]
    ledgerAction ledger $ \db -> do
      current <- query_ db "SELECT revision FROM custody_check" :: IO [Only Int64]
      require (current==[Only $ viewRevision view]) "custody_ledger_changed"
      let err=if matches then Nothing else Just ("custody_balance_mismatch"::Text)
      mapM_ (recordError db) err
      execute db "UPDATE custody_check SET checked_revision=?,checked_at=?,last_error=?,report_json=?"
        (viewRevision view,at,err,json report)

recordError :: Connection -> Text -> IO ()
recordError db code=do
  old <- query_ db "SELECT last_error FROM custody_check" :: IO [Only (Maybe Text)]
  when (old/=[Only (Just code)]) $ execute db "INSERT INTO audit(action,detail) VALUES('custody_failure',?)" (Only code)
  execute db "UPDATE deployment SET paused=1,pause_reason=?" (Only $ "custody:"<>code)

nativeBalance :: NativeRPC -> IO (Integer,Text,Int64)
nativeBalance call=do
  value <- call True "getbalances" []
  mine <- fieldValue "mine" value
  values <- mapM (\key->fieldValue key mine >>= either reject pure . nativeAmount) ["trusted","untrusted_pending","immature"]
  reused <- parseValue (withObject "balance" (.:? "used")) mine
  reusedAmount <- mapM (either reject pure . nativeAmount) reused
  require (maybe True ((==0).units) reusedAmount) "native_reused_balance_requires_review"
  block <- fieldValue "lastprocessedblock" value
  hash <- fieldValue "hash" block
  height <- fieldValue "height" block
  require (transactionId hash && height>=0) "custody_native_anchor_missing"
  pure (sum $ map (toInteger.units) values,hash,height)

eventProof :: Ledger -> Text -> Text -> IO (Text,Text,Value)
eventProof ledger stream txid=ledgerAction ledger $ \db -> do
  rows <- query db "SELECT e.kind,e.anchor,o.evidence_json FROM chain_events e JOIN observation_evidence o ON o.hash=e.evidence_hash WHERE e.chain=? AND e.event_id=? AND e.needs_review=0" (stream,txid) :: IO [(Text,Text,Text)]
  case rows of
    [(kind,anchor,saved)]->do
      proof <- decode saved >>= fieldValue "proof"
      pure (kind,anchor,proof)
    _->reject "custody_history_not_current"

nativeFence :: NativeRPC -> Config -> Ledger -> View -> IO ()
nativeFence call c ledger view=do
  cursor <- headFor view "Native"
  depth <- maximumNativeDepth ledger (nativeConfirmations c)
  history <- call True "listsinceblock" [toJSON cursor,toJSON depth,Bool False,Bool True]
  next <- fieldValue "lastblock" history
  require (next==cursor) "custody_native_history_advanced"
  current <- fieldValue "transactions" history
  removed <- fieldValue "removed" history
  let entries=current<>removed :: [Value]
  require (length entries<=1000) "native_history_batch_too_large"
  forM_ entries $ \entry -> do
    txid <- fieldValue "txid" entry
    confirmations <- fieldValue "confirmations" entry :: IO Int
    anchor <- parseValue (withObject "transaction" (.:? "blockhash")) entry
    (_,savedAnchor,proof) <- eventProof ledger "Native" txid
    old <- fieldValue "confirmations" proof
    require (old==confirmations && savedAnchor==maybe "unconfirmed" id anchor) "custody_native_history_changed"

solanaBalances :: SolanaRPC -> Config -> Ledger -> View -> IO (Int64,Integer,Integer)
solanaBalances call c ledger view=do
  (slot,value) <- call "getMultipleAccounts" [toJSON [custodyAta c,custodyOwner c]
    ,object ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text),"minContextSlot" .= viewSlot view]] >>= contextValue (viewSlot view)
  accounts <- parseValue parseJSON value
  (token,owner) <- case accounts of [a,b]->pure(a,b); _->reject "custody_accounts_missing"
  wrapped <- either reject pure (inspectTokenAccount (mint c) (custodyOwner c) token)
  sol <- systemLamports owner
  forM_ [("Solana",custodyAta c),("SolanaOperating",custodyOwner c)] $ \(stream,address)->do
    headSignature <- headFor view stream
    response <- call "getSignaturesForAddress" [toJSON address,object
      ["commitment" .= ("finalized"::Text),"minContextSlot" .= slot,"limit" .= (1::Int)]] >>= parseValue parseJSON
    h <- case response of [a]->pure a; _->reject "custody_history_head_unavailable"
    (_,anchor,_) <- eventProof ledger stream headSignature
    require (historySignature h==headSignature && T.pack(show $ historySlot h)==anchor && historySlot h<=slot) "custody_solana_history_advanced"
  pure (slot,toInteger $ units wrapped,toInteger $ units sol)

-- Normalize only verified effects of the immutable saved payment. Unsigned
-- preparations and unseen signatures have no outgoing effect.
pendingEffect :: PaymentTransport -> Config -> Ledger -> Attempt -> IO [(Text,Text,Integer)]
pendingEffect transport c ledger attempt=do
  (_,payment) <- readSavedPayment transport c ledger attempt
  let txid=attemptId attempt
      recorded=require (attemptState attempt=="broadcast_intent") "unrecorded_broadcast_observed"
      native=paymentNative transport
      requireUnseen=do
        seen <- ledgerAction ledger $ \db -> query db "SELECT event_id FROM chain_events WHERE event_id=? AND chain IN(?,?) LIMIT 1"
          (txid,attemptChain attempt,if attemptChain attempt=="Solana" then "SolanaOperating"::Text else "Native") :: IO [Only Text]
        require (null seen) "custody_payment_evidence_unavailable"
        pure []
  case payment of
    NativePayment signed->do
      found <- readNativePayment native signed
      case found of
        Nothing->requireUnseen
        Just (confirmations,value)->do
          recorded
          when (confirmations==0) $ do
            mempool <- native False "getmempoolentry" [toJSON txid]
            size <- fieldValue "vsize" mempool :: IO Int
            require (size>0) "native_mempool_evidence_invalid"
          (kind,anchor,proof) <- eventProof ledger "Native" txid
          actualAnchor <- parseValue (withObject "transaction" (.:? "blockhash")) value
          oldDepth <- fieldValue "confirmations" proof
          net <- fieldValue "walletNetUnits" proof
          fee <- fieldValue "feeUnits" proof
          let n=toInteger $ units $ planAmount $ signedNativePlan signed
              cost=toInteger $ units $ signedNativeFee signed
          require (kind=="outgoing" && anchor==maybe "unconfirmed" id actualAnchor && oldDepth==confirmations
            && net==T.pack(show $ negate n) && fee==signedNativeFee signed) "custody_payment_observation_mismatch"
          pure [(txid,"Native",negate $ n+cost)]
    SolanaPayment signed->do
      proof <- paymentSolana transport "getTransaction" [toJSON txid,object
        ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
      if proof==Null then requireUnseen else do
        recorded
        outcome <- either reject pure (verifySolanaOutcome c signed proof)
        let n=if outcomeSucceeded outcome then toInteger (units $ solPlanAmount $ signedSolanaPlan signed) else 0
            cost=toInteger (units $ outcomeFee outcome)+toInteger (units $ outcomeRent outcome)
            anchor=T.pack(show $ outcomeSlot outcome)
        forM_ [("Solana",negate n),("SolanaOperating",negate cost)] $ \(stream,delta)->do
          (kind,observedAnchor,evidence) <- eventProof ledger stream txid
          actual <- fieldValue "delta" evidence
          require (observedAnchor==anchor && actual==T.pack(show delta)
            && kind==(if stream=="Solana" && n==0 then "failed" else "outgoing")) "custody_payment_observation_mismatch"
        pure [(txid,"Wrapped",negate n),(txid,"Sol",negate cost)]
