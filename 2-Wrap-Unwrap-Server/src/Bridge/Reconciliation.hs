{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Reconciliation (View(..), reconcileCustodyWith, inspectCustodyWith, inspectSourceLossCustodyWith) where

import qualified Bridge.Postgres.Custody as PgCustody
import qualified Bridge.Postgres.Observation as PgObservation
import qualified Bridge.Postgres.PaymentStore as PgPaymentStore
import Bridge.Config
import Bridge.Ledger.Model
import Bridge.Native
import Bridge.NativePayment
import Bridge.Observer (SignatureInfo(..))
import Bridge.RPC
import Bridge.Settlement
import Bridge.Solana
import Bridge.SolanaPayment
import Bridge.Types
import Bridge.Postgres.Ledger (Ledger)
import Bridge.Postgres.PaymentStore
import Control.Exception (IOException,catch,try)
import qualified Bridge.Postgres.Custody as C
import Control.Monad (forM_,when)
import Data.Aeson hiding (decode)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T

-- Read-only on both chains: a check cannot authorize a payout, allocate a
-- receipt, clear a review flag, or resume a paused deployment.
headFor :: View -> Text -> IO Text
headFor v stream=maybe (reject "custody_history_anchor_missing") pure (lookup stream $ viewHeads v)

-- No RPC holds a database transaction. Concurrent observations or settlements
-- invalidate this revision before it can be certified. A newer history head
-- requires a fresh scan; other failures also impose an operator pause.
inspectSourceLossCustodyWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> IO Value
inspectSourceLossCustodyWith clock transport c ledger=do
  (revision,at,matches,report) <- inspectCustodyWith clock transport c ledger True
    `catch` (\(_::IOException)->reject "custody_rpc_unavailable")
  require matches "custody_balance_mismatch"
  pure $ object ["revision" .= revision,"checkedAt" .= at,"report" .= report]

inspectCustodyWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> Bool -> IO (Int64,Int64,Bool,Value)
inspectCustodyWith clock transport c ledger inspectLosses=do
  at <- clock
  view <- custodyView c ledger at inspectLosses
  paymentIdentity transport
  before <- nativeBalance native
  attempts <- PgPaymentStore.pendingAttempts ledger
  groups <- either (const $ reject "custody_attempt_bounds") pure (paymentAttemptGroups attempts)
  effects <- concat <$> mapM (pendingFamilyEffect transport c ledger) groups
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
  current <- custodyRevision ledger
  require (current==viewRevision view) "custody_ledger_changed"
  pure (viewRevision view,at,matches,report)
 where native=paymentNative transport

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

nativeFence :: NativeRPC -> Config -> Ledger -> View -> IO ()
nativeFence call c ledger view=do
  cursor <- headFor view "Native"
  depth <- PgObservation.maximumNativeDepth ledger (nativeConfirmations c)
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
    (_,savedAnchor,proof) <- PgCustody.eventProof ledger "Native" txid
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
    (_,anchor,_) <- PgCustody.eventProof ledger stream headSignature
    require (historySignature h==headSignature && T.pack(show $ historySlot h)==anchor && historySlot h<=slot) "custody_solana_history_advanced"
  pure (slot,toInteger $ units wrapped,toInteger $ units sol)

-- Normalize only verified effects of the immutable saved payment. Unsigned
-- preparations and unseen signatures have no outgoing effect.
pendingFamilyEffect :: PaymentTransport -> Config -> Ledger -> [Attempt] -> IO [(Text,Text,Integer)]
pendingFamilyEffect transport c ledger [attempt]=pendingEffect transport c ledger attempt
pendingFamilyEffect transport c ledger attempts=do
  (members,view) <- readSavedNativeFamily transport c ledger attempts
  active <- activeFamilyPayment members view
  case active of
    Nothing->pure []
    Just (attempt,signed,depth,value)->nativeObservedEffect ledger attempt signed depth value

nativeObservedEffect :: Ledger -> Attempt -> NativeSigned -> Int -> Value -> IO [(Text,Text,Integer)]
nativeObservedEffect ledger attempt signed confirmations value=do
  require (attemptState attempt=="broadcast_intent") "unrecorded_broadcast_observed"
  let txid=attemptId attempt
  (kind,anchor,proof) <- PgCustody.eventProof ledger "Native" txid
  actualAnchor <- parseValue (withObject "transaction" (.:? "blockhash")) value
  oldDepth <- fieldValue "confirmations" proof
  net <- fieldValue "walletNetUnits" proof
  fee <- fieldValue "feeUnits" proof
  let n=toInteger $ units $ planAmount $ signedNativePlan signed
      cost=toInteger $ units $ signedNativeFee signed
  require (kind=="outgoing" && anchor==maybe "unconfirmed" id actualAnchor && oldDepth==confirmations
    && net==T.pack(show $ negate n) && fee==signedNativeFee signed) "custody_payment_observation_mismatch"
  pure [(txid,"Native",negate $ n+cost)]

pendingEffect :: PaymentTransport -> Config -> Ledger -> Attempt -> IO [(Text,Text,Integer)]
pendingEffect transport c ledger attempt=do
  (_,payment) <- readSavedPayment transport c ledger attempt
  let txid=attemptId attempt
      recorded=require (attemptState attempt=="broadcast_intent") "unrecorded_broadcast_observed"
      native=paymentNative transport
      requireUnseen=do
        seen <- custodyHasEvent ledger txid (attemptChain attempt)
        require (not seen) "custody_payment_evidence_unavailable"
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
          nativeObservedEffect ledger attempt signed confirmations value
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
          (kind,observedAnchor,evidence) <- PgCustody.eventProof ledger stream txid
          actual <- fieldValue "delta" evidence
          require (observedAnchor==anchor && actual==T.pack(show delta)
            && kind==(if stream=="Solana" && n==0 then "failed" else "outgoing")) "custody_payment_observation_mismatch"
        pure [(txid,"Wrapped",negate n),(txid,"Sol",negate cost)]

-- One custody inspection/recording path for scanning, cancellation, source
-- recovery and replacement. Callers cannot inject a different recording action.
reconcileCustodyWith :: IO Int64 -> PaymentTransport -> Config -> Ledger -> IO Value
reconcileCustodyWith clock transport cfg ledger = do
  expected <- custodyRevision ledger
  result <- try (inspectCustodyWith clock transport cfg ledger False `catch` (\(_::IOException)->reject "custody_rpc_unavailable")) :: IO (Either BridgeError (Int64,Int64,Bool,Value))
  case result of
    Right (revision,at,matches,report)->do
      C.recordCheck ledger revision at (if matches then Nothing else Just "custody_balance_mismatch") (Just report)
      pure(object["matches" .= matches,"revision" .= revision,"report" .= report])
    Left (BridgeError code)->do
      at <- clock
      C.recordCheck ledger expected at (Just code) Nothing
      pure(object["matches" .= False,"error" .= code])
