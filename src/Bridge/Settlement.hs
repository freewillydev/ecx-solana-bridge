{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Settlement
  ( PaymentTransport(..), realPaymentTransport, paymentPass, settleAttemptWith, reconcilePayments, reconcilePaymentsWith
  , recheckSourceWith, observeNativePayment, observeSolanaPayment, solanaExpiryEvidence, PaymentObservation(..)
  , approveSolanaRetry, approveSolanaRetryWith
  , SavedPayment(..), readSavedPayment, readNativePayment, activeNativeBlock
  , paymentAttemptGroups, readSavedNativeFamily, activeFamilyPayment
  ) where

import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Observer (collectSignatures,SignatureInfo(..))
import Bridge.Payment
import Bridge.RPC
import Bridge.Solana
import Bridge.SolanaDeposit
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Types
import Control.Exception (IOException,catch,onException,try)
import Control.Monad (forM,forM_,when,unless)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)
import Text.Read (readMaybe)

-- RPC seams are for contract tests. The worker always supplies these two real
-- chain adapters; there is no configurable alternate or simulated network.
data PaymentTransport = PaymentTransport
  { paymentNative :: NativeRPC, paymentSolana :: SolanaRPC
  , paymentVerifier :: Maybe SolanaRPC, paymentIdentity :: IO ()
  , paymentBackup :: Int64 -> IO ()
  }
realPaymentTransport :: Manager -> Config -> (Int64 -> IO ()) -> PaymentTransport
realPaymentTransport manager c backup = PaymentTransport
  (nativeCall manager c) (solanaCall manager c)
  (fmap (\url -> rpc manager url Nothing) $ solanaVerifierRpc c)
  (nativeIdentity manager c >> solanaIdentity manager c >> pure ()) backup

json :: ToJSON a => a -> Text
json=TE.decodeUtf8 . LBS.toStrict . encode
stored :: FromJSON a => Text -> IO a
stored=either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8
zero :: Amount
zero=either (error . T.unpack) id (amount 0)

data PaymentObservation
  = PaymentUnseen | PaymentWaiting
  | PaymentConfirmed PaymentCosts Text | PaymentFailed Amount Text
  deriving (Eq,Show)

-- The wallet proof must match the saved bytes, outputs, fee and active block.
-- Neither a successful RPC send nor mempool membership settles a payment.
observeNativePayment :: NativeRPC -> NativeSigned -> IO PaymentObservation
observeNativePayment call signed = do
  found <- readNativePayment call signed
  case found of
    Nothing -> pure PaymentUnseen
    Just (confirmations,value) -> do
      let plan=signedNativePlan signed
      if confirmations<planDepth plan then pure PaymentWaiting else do
        anchor <- fieldValue "blockhash" value
        height <- activeNativeBlock call anchor (planDepth plan)
        pure $ PaymentConfirmed (PaymentCosts (signedNativeFee signed) zero) $ json $ object
          ["txid" .= nativeTxid (signedNativeTransaction signed),"blockhash" .= anchor,"height" .= height,"requiredDepth" .= planDepth plan]

-- Shared by settlement and custody reconciliation; even an unconfirmed wallet
-- effect must match the immutable signed bytes and exact economic template.
readNativePayment :: NativeRPC -> NativeSigned -> IO (Maybe (Int,Value))
readNativePayment call signed = do
  let tx=signedNativeTransaction signed; plan=signedNativePlan signed
  found <- try (call True "gettransaction" [toJSON $ nativeTxid tx,Bool False,Bool True])
  case found of
    Left (BridgeError "rpc_error_-5") -> pure Nothing
    Left (BridgeError code) -> reject code
    Right value -> do
      raw <- fieldValue "hex" value
      actual <- fieldValue "decoded" value >>= either reject pure . decodeNativeTx
      actualId <- fieldValue "txid" value
      fee <- fieldValue "fee" value >>= either reject pure . nativeAmount . negate
      require (raw==signedNativeBytes signed && actual==tx && actualId==nativeTxid tx && fee==signedNativeFee signed) "native_settlement_evidence_mismatch"
      either reject pure (validateNativeTx plan (signedNativePrevouts signed) fee actual)
      conflicts <- fieldValue "walletconflicts" value :: IO [Text]
      confirmations <- fieldValue "confirmations" value :: IO Int
      require (confirmations>=0 && null conflicts) "native_conflict_requires_review"
      pure (Just (confirmations,value))

activeNativeBlock :: NativeRPC -> Text -> Int -> IO Int64
activeNativeBlock call anchor depth = do
  require (transactionId anchor && depth>0) "invalid_native_settlement_anchor"
  header <- call False "getblockheader" [toJSON anchor]
  actual <- fieldValue "hash" header
  confirmations <- fieldValue "confirmations" header :: IO Int
  height <- fieldValue "height" header :: IO Int64
  canonical <- call False "getblockhash" [toJSON height] >>= parseValue parseJSON
  require (actual==anchor && canonical==anchor && height>=0 && confirmations>=depth) "native_settlement_not_canonical"
  pure height

solanaProof :: SolanaRPC -> Text -> IO Value
solanaProof call signature=call "getTransaction" [toJSON signature,object
  ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]

observeSolanaPayment :: SolanaRPC -> Config -> SolanaSigned -> IO PaymentObservation
observeSolanaPayment call c signed = do
  signature <- maybe (reject "helper_signature_missing") pure (replySignature $ signedSolanaReply signed)
  proof <- solanaProof call signature
  if proof/=Null then do
    outcome <- either reject pure (verifySolanaOutcome c signed proof)
    let evidence=json $ object ["signature" .= signature,"outcome" .= outcome
          ,"transactionHash" .= digest (LBS.toStrict $ encode proof)]
    pure $ if outcomeSucceeded outcome
      then PaymentConfirmed (PaymentCosts (outcomeFee outcome) (outcomeRent outcome)) evidence
      else PaymentFailed (outcomeFee outcome) evidence
  else do
    response <- call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]]
    (_,value) <- contextValue (recentSlot $ solPlanRecent $ signedSolanaPlan signed) response
    statuses <- parseValue parseJSON value :: IO [Value]
    case statuses of
      [Null] -> pure PaymentUnseen
      [status] -> do
        finality <- fieldValue "confirmationStatus" status :: IO Text
        require (finality `elem` ["processed","confirmed"]) "finalized_solana_evidence_unavailable"
        pure PaymentWaiting
      _ -> reject "invalid_signature_status_response"

-- Expiry uses finalized height, never wall time or a missing status alone.
-- Each configured provider must supply both complete, anchored account histories.
-- The original signature must be absent from all of them, including failed rows.
solanaExpiryEvidence :: PaymentTransport -> Config -> SolanaSigned -> IO (Maybe Text)
solanaExpiryEvidence transport c signed = do
  height <- paymentSolana transport "getBlockHeight" [options minimumSlot] >>= parseValue parseJSON
  require (height>=0) "expiry_provider_behind"
  if height<=recentLastValidHeight recent then pure Nothing else do
    sourceOrigin <- maybe (reject "solana_expiry_history_required") pure (solanaHistoryStart c)
    ownerOrigin <- maybe (reject "solana_expiry_history_required") pure (solanaOperatingHistoryStart c)
    signature <- maybe (reject "helper_signature_missing") pure (replySignature $ signedSolanaReply signed)
    primary <- evidence (paymentSolana transport) sourceOrigin ownerOrigin signature
    independent <- case paymentVerifier transport of
      Nothing -> do
        require (profile c/=CanonicalBeta && solanaVerifierRpc c==Nothing) "independent_rpc_required"
        pure Nothing
      Just verifier -> Just <$> evidence verifier sourceOrigin ownerOrigin signature
    pure $ Just $ json $ object ["signature" .= signature,"blockhash" .= recentHash recent
      ,"lastValidBlockHeight" .= recentLastValidHeight recent,"primary" .= primary,"independent" .= independent]
 where
  recent=solPlanRecent $ signedSolanaPlan signed
  minimumSlot=recentSlot recent
  options slot=object ["commitment" .= ("finalized"::Text),"minContextSlot" .= slot]
  evidence call sourceOrigin ownerOrigin signature=do
    genesis <- call "getGenesisHash" [] >>= parseValue parseJSON
    require (genesis==solanaGenesis (profile c)) "expiry_wrong_genesis"
    height <- call "getBlockHeight" [options minimumSlot] >>= parseValue parseJSON :: IO Int64
    require (height>recentLastValidHeight recent) "expiry_provider_behind"
    slot <- call "getSlot" [options minimumSlot] >>= parseValue parseJSON :: IO Int64
    require (slot>=minimumSlot) "expiry_provider_behind"
    (_,valid) <- call "isBlockhashValid" [toJSON $ recentHash recent,options slot] >>= contextValue slot
    require (valid==Bool False) "blockhash_still_valid"
    history <- mapM (\(address,origin)->do
      rows <- collectSignatures origin Nothing $ \before -> call "getSignaturesForAddress"
        [toJSON address,object $ ["commitment" .= ("finalized"::Text),"minContextSlot" .= slot,"limit" .= (100::Int)]
          <> maybe [] (\sig->["before" .= sig]) before] >>= parseValue parseJSON
      require (all ((/=signature).historySignature) rows) "expired_signature_in_history"
      pure $ object ["address" .= address,"origin" .= origin
        ,"signatures" .= [object ["signature" .= historySignature row,"slot" .= historySlot row,"failed" .= historyFailed row] | row<-rows]])
      [(custodyAta c,sourceOrigin),(custodyOwner c,ownerOrigin)]
    proof <- solanaProof call signature
    require (proof==Null) "expired_transaction_observed"
    (_,statuses) <- call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]] >>= contextValue slot
    require (statuses==toJSON [Null]) "expired_signature_observed"
    pure $ object ["genesis" .= genesis,"finalizedHeight" .= height,"minimumFinalizedSlot" .= slot
      ,"blockhashValid" .= False,"histories" .= history,"transaction" .= Null,"signatureStatuses" .= statuses]

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

-- Read the exact original transaction immediately before send, including after
-- a backup wait. A focused read never changes a scanner's global checkpoint.
recheckSourceWith :: PaymentTransport -> Config -> Ledger -> Obligation -> IO ()
recheckSourceWith transport c ledger ob = do
  (deposit,request,policy,instruction) <- sourceContext ledger ob
  require (deploymentFingerprint policy==fingerprint c && solanaCommitment policy=="finalized") "payment_profile_mismatch"
  refreshed <- case depositAsset deposit of
    Native -> do
      (txid,index) <- case T.splitOn ":" (depositId deposit) of
        ["native",tx,n] | transactionId tx,Just i<-readMaybe (T.unpack n),i>=0 -> pure (tx,i::Int)
        _ -> reject "invalid_native_deposit_id"
      let call=paymentNative transport
      value <- call True "gettransaction" [toJSON txid,Bool False,Bool True]
      actual <- fieldValue "txid" value
      decoded <- fieldValue "decoded" value
      decodedId <- fieldValue "txid" decoded
      outputs <- fieldValue "vout" decoded :: IO [Value]
      require (actual==txid && decodedId==txid && index<length outputs) "source_binding_mismatch"
      let output=outputs!!index
      actualIndex <- fieldValue "n" output :: IO Int
      quantity <- fieldValue "value" output >>= either reject pure . nativeAmount
      script <- fieldValue "scriptPubKey" output >>= fieldValue "hex"
      owned <- ownedScript call instruction
      require (actualIndex==index && quantity==depositAmount deposit && script==owned) "source_binding_mismatch"
      depth <- fieldValue "confirmations" value :: IO Int
      if depth<nativeDepth policy then pure deposit{depositConfirmations=max 0 depth,depositEligible=False}
      else do
        anchor <- fieldValue "blockhash" value
        _ <- activeNativeBlock call anchor (nativeDepth policy)
        pure deposit{depositAnchor=anchor,depositConfirmations=depth,depositEligible=True}
    Wrapped -> do
      signature <- maybe (reject "invalid_solana_deposit_id") pure (T.stripPrefix "solana:" $ depositId deposit)
      owner <- maybe (reject "source_owner_missing") pure (sourceOwner request)
      let binding=DepositBinding signature owner (mint c) (custodyAta c) (custodyOwner c) instruction
      proof <- solanaProof (paymentSolana transport) signature
      verified <- either reject pure (verifyDeposit binding proof)
      require (verifiedAmount verified==depositAmount deposit && T.pack(show $ verifiedSlot verified)==depositAnchor deposit) "source_binding_mismatch"
      case paymentVerifier transport of
        Nothing -> require (profile c/=CanonicalBeta && solanaVerifierRpc c==Nothing) "independent_rpc_required"
        Just verifier -> do
          independent <- solanaProof verifier signature >>= either reject pure . verifyDeposit binding
          require (independent==verified) "source_verifier_disagreement"
      pure deposit{depositConfirmations=1,depositEligible=True}
    Sol -> reject "unsupported_source_asset"
  refreshDeposit ledger refreshed
  require (depositEligible refreshed) "source_not_eligible"

data SavedPayment = NativePayment NativeSigned | SolanaPayment SolanaSigned
readSavedPayment :: PaymentTransport -> Config -> Ledger -> Attempt -> IO (Obligation,SavedPayment)
readSavedPayment transport c ledger attempt = do
  rows <- ledgerAction ledger $ \db -> query db "SELECT id,order_id,deposit_id,kind,asset,amount,recipient FROM obligations WHERE id=?" (Only $ attemptIntent attempt)
  ob <- case rows of [o] -> pure o; _ -> reject "obligation_not_found"
  (_,_,policy,_) <- sourceContext ledger ob
  require (deploymentFingerprint policy==fingerprint c) "payment_profile_mismatch"
  payment <- case attemptChain attempt of
    "Native" -> do
      signed <- stored (attemptPolicy attempt)
      let plan=signedNativePlan signed; tx=signedNativeTransaction signed
      require (obligationAsset ob=="Native" && planProfile plan==profile c && planDepth plan==nativeDepth policy
        && planRecipient plan==obligationRecipient ob && units (planAmount plan)==obligationAmount ob
        && units (planFeeLimit plan)==attemptFeeLimit attempt && nativeTxid tx==attemptId attempt
        && signedNativeBytes signed==attemptBytes attempt) "saved_native_policy_mismatch"
      decoded <- paymentNative transport False "decoderawtransaction" [toJSON $ attemptBytes attempt] >>= either reject pure . decodeNativeTx
      require (decoded==tx) "native_signed_bytes_mismatch"
      either reject pure (validateNativeTx plan (signedNativePrevouts signed) (signedNativeFee signed) tx)
      pure (NativePayment signed)
    "Solana" -> do
      signed <- stored (attemptPolicy attempt)
      let plan=signedSolanaPlan signed; reply=signedSolanaReply signed
      limit <- either reject pure (solanaOperatingLimit plan)
      require (obligationAsset ob=="Wrapped" && solPlanFingerprint plan==fingerprint c
        && solPlanRecipient plan==obligationRecipient ob && units (solPlanAmount plan)==obligationAmount ob
        && solPlanReference plan==payoutReference c ob && units limit==attemptFeeLimit attempt
        && replyTransaction reply==attemptBytes attempt && replySignature reply==Just (attemptId attempt)) "saved_solana_policy_mismatch"
      _ <- either reject pure (validateHelperReply c (solanaPayoutRequest c plan) reply)
      pure (SolanaPayment signed)
    _ -> reject "wrong_destination_chain"
  pure (ob,payment)

-- Capacity is one intent per chain. Mutually exclusive native members share
-- that slot, but independent native intents and multiple Solana attempts do not.
paymentAttemptGroups :: [Attempt] -> Either Text [[Attempt]]
paymentAttemptGroups attempts=do
  let chains=nub $ map attemptChain attempts
      groups=[filter ((==chain).attemptChain) attempts | chain<-chains]
  unless (length attempts<=9 && all (`elem` ["Native","Solana"]) chains
    && length (nub $ map attemptId attempts)==length attempts
    && all (\xs->length (nub $ map attemptIntent xs)==1
      && case xs of a:_->length xs<=if attemptChain a=="Native" then 8 else 1; []->False) groups) (Left "recovery_attempt_bounds")
  pure groups

-- Lineage is checked in the ledger before the RPC reader accepts any conflict
-- as belonging to this family. An arbitrary same-intent row is not authority.
readSavedNativeFamily :: PaymentTransport -> Config -> Ledger -> [Attempt] -> IO ([(Attempt,NativeSigned)],NativeFamilyView)
readSavedNativeFamily transport c ledger expected=do
  first <- case expected of a:_->pure a; _->reject "native_replacement_family_bounds"
  family <- nativeFamilyAttempts ledger (attemptIntent first)
  require (family==expected) "native_replacement_family_changed"
  signed <- forM family $ \attempt->do
    (_,payment) <- readSavedPayment transport c ledger attempt
    case payment of NativePayment s->pure(attempt,s); _->reject "wrong_destination_chain"
  view <- readNativeFamilyWith (paymentNative transport) c (map snd signed)
  forM_ (familyWallet view) $ \(txid,seen)->when (seen/=Nothing) $ do
    require (any (\a->attemptId a==txid && attemptState a `elem` ["broadcast_intent","settled","review"]
      && maybe False (>0) (attemptSequence a)) family) "unrecorded_broadcast_observed"
  pure(signed,view)

activeFamilyPayment :: [(Attempt,NativeSigned)] -> NativeFamilyView -> IO (Maybe (Attempt,NativeSigned,Int,Value))
activeFamilyPayment family view=case familyActive view of
  Nothing->pure Nothing
  Just (txid,depth,value)->case [(a,s) | (a,s)<-family,attemptId a==txid] of
    [(attempt,signed)]->pure $ Just (attempt,signed,depth,value)
    _->reject "native_family_spender_unavailable"

-- Reconcile only already-recorded attempts. This path never invokes signing,
-- backup or send, even if the deployment happens to be available.
reconcilePayments :: Manager -> Config -> Ledger -> IO Value
reconcilePayments manager c = reconcilePaymentsWith
  (realPaymentTransport manager c (const $ reject "unexpected_recovery_backup")) c

reconcilePaymentsWith :: PaymentTransport -> Config -> Ledger -> IO Value
reconcilePaymentsWith transport c ledger = do
  attempts <- pendingAttempts ledger
  groups <- case paymentAttemptGroups attempts of
    Left code->pause ledger code >> reject code
    Right groups->pure groups
  reports <- mapM (reconcile.last) groups
  pure $ object ["attempts" .= reports,"signedOrSent" .= False]
 where
  reconcile attempt = do
    outcome <- try (reconcileRecordedAttempt transport c ledger attempt
      `catch` (\(_::IOException)->reject "payment_observation_io_unavailable")) :: IO (Either BridgeError (Either Text (Obligation,SavedPayment)))
    case outcome of
      Right result -> do
        txid <- case result of
          Left "settled"->do
            winners <- ledgerAction ledger $ \db->query db "SELECT txid FROM attempts WHERE intent_id=? AND state='settled'" (Only $ attemptIntent attempt) :: IO [Only Text]
            case winners of [Only winner]->pure winner; _->reject "settled_payment_missing"
          _->pure $ attemptId attempt
        pure $ report txid attempt (either id (const "unseen") result) Nothing
      Left (BridgeError code) -> do
        health <- readiness ledger
        let reason="payment_recovery:"<>code
        when (health/=Availability False reason) $ pause ledger reason
        pure $ report (attemptId attempt) attempt "requires_review" (Just code)
  report txid attempt state failure = object ["transaction" .= txid,"chain" .= attemptChain attempt
    ,"outcome" .= (state::Text),"error" .= (failure::Maybe Text)]

-- A Right result means the same saved transaction is unseen and has no proven
-- expiry. Only the separate authorized send path may act on those bytes.
reconcileRecordedAttempt :: PaymentTransport -> Config -> Ledger -> Attempt -> IO (Either Text (Obligation,SavedPayment))
reconcileRecordedAttempt transport c ledger attempt = do
  paymentIdentity transport
  (ob,payment) <- readSavedPayment transport c ledger attempt
  family <- if attemptChain attempt=="Native" then nativeFamilyAttempts ledger (attemptIntent attempt) else pure [attempt]
  if length family>1 then do
    require (attempt `elem` family) "native_replacement_family_changed"
    (members,view) <- readSavedNativeFamily transport c ledger family
    current <- activeFamilyPayment members view
    case current of
      Just (winner,signed,depth,value) | depth>=planDepth (signedNativePlan signed)->do
        anchor <- fieldValue "blockhash" value
        height <- activeNativeBlock (paymentNative transport) anchor (planDepth $ signedNativePlan signed)
        require (attemptState winner=="broadcast_intent") "unrecorded_broadcast_observed"
        recordSettlement ledger (attemptId winner) (PaymentCosts (signedNativeFee signed) zero) $ json $ object
          ["txid" .= attemptId winner,"blockhash" .= anchor,"height" .= height,"requiredDepth" .= planDepth (signedNativePlan signed)]
        pure (Left "settled")
      Just (active,_,depth,_) | depth>0 || attemptId active==attemptId attempt->pure (Left "confirming")
      _ | last family/=attempt->pure (Left "superseded")
      _->pure (Right (ob,payment))
   else do
    observation <- case payment of
      NativePayment signed -> observeNativePayment (paymentNative transport) signed
      SolanaPayment signed -> observeSolanaPayment (paymentSolana transport) c signed
    case observation of
      PaymentConfirmed costs proof -> recorded >> recordSettlement ledger (attemptId attempt) costs proof >> pure (Left "settled")
      PaymentFailed fee proof -> recorded >> recordFailedSolana ledger (attemptId attempt) (units fee) proof >> pure (Left "failed")
      PaymentWaiting -> recorded >> pure (Left "confirming")
      PaymentUnseen -> do
        expiry <- case payment of
          NativePayment _ -> pure Nothing
          SolanaPayment signed -> solanaExpiryEvidence transport c signed
        case expiry of
          Just proof -> do
            checkExpiryOrigins ledger c
            recordSolanaExpiry ledger attempt proof
            pure (Left "expired")
          Nothing -> pure (Right (ob,payment))
 where
  recorded=require (attemptState attempt=="broadcast_intent") "unrecorded_broadcast_observed"

settleAttemptWith :: PaymentTransport -> Config -> Ledger -> Attempt -> IO Text
settleAttemptWith transport c ledger attempt = work `onException` pause ledger "payment_requires_reconciliation"
 where
  work = reconcileRecordedAttempt transport c ledger attempt >>= either pure (uncurry sendIfAvailable)
  sendIfAvailable ob payment = do
        health <- readiness ledger
        if not (available health) then pure "paused" else do
          recheckSourceWith transport c ledger ob
          sequenceNumber <- markBroadcastIntent ledger (attemptId attempt)
          when (backupRequired c) $ paymentBackup transport sequenceNumber
          paymentIdentity transport
          recheckSourceWith transport c ledger ob
          case payment of
            NativePayment _ -> pure () -- no timeout can make native bytes safe to replace
            SolanaPayment signed -> checkBlockhashWindow (paymentSolana transport) (solPlanRecent $ signedSolanaPlan signed)
          saved <- authorizeRecordedSend ledger (backupRequired c) (attemptId attempt)
          require (attemptBytes saved==attemptBytes attempt && attemptPolicy saved==attemptPolicy attempt) "saved_payment_changed"
          result <- try (send saved `catch` (\(_::IOException) -> reject "broadcast_io_uncertain")) :: IO (Either BridgeError Text)
          case result of
            Left _ -> pure "broadcast_uncertain" -- durable intent still owns all reservations
            Right identifier -> require (identifier==attemptId saved) "broadcast_identifier_mismatch" >> pure "submitted"
  send saved = case attemptChain saved of
    "Native" -> paymentNative transport True "sendrawtransaction" [toJSON $ attemptBytes saved] >>= parseValue parseJSON
    "Solana" -> paymentSolana transport "sendTransaction" [toJSON $ attemptBytes saved,object
      ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("confirmed"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
    _ -> reject "wrong_destination_chain"

checkExpiryOrigins :: Ledger -> Config -> IO ()
checkExpiryOrigins ledger c=do
  origins <- ledgerAction ledger $ \db -> query_ db "SELECT chain,anchor FROM scan_origins WHERE chain IN('Solana','SolanaOperating') ORDER BY chain" :: IO [(Text,Text)]
  require (map (\(chain,anchor)->(chain,Just anchor)) origins==[("Solana",solanaHistoryStart c),("SolanaOperating",solanaOperatingHistoryStart c)]) "expiry_scan_origin_mismatch"

approveSolanaRetry :: Manager -> Config -> Ledger -> Text -> Text -> IO ()
approveSolanaRetry manager c=approveSolanaRetryWith (realPaymentTransport manager c (const $ reject "unexpected_backup_callback")) c

-- Private operator command only. Revalidate the saved signed message, source,
-- immutable origins and complete expiry evidence before journaling permission.
-- It neither signs, broadcasts nor resumes a paused worker.
approveSolanaRetryWith :: PaymentTransport -> Config -> Ledger -> Text -> Text -> IO ()
approveSolanaRetryWith transport c ledger txid reason=do
  prior <- ledgerAction ledger $ \db -> query db "SELECT reason FROM solana_retry_approvals WHERE expired_txid=?" (Only txid) :: IO [Only Text]
  case prior of
    [Only old] -> require (old==reason) "retry_approval_conflict"
    [] -> do
      require (not (T.null $ T.strip reason) && T.length reason<=512) "invalid_retry_approval"
      health <- readiness ledger
      require (not $ available health) "pause_before_operator_action"
      rows <- ledgerAction ledger $ \db -> query db "SELECT a.txid,a.intent_id,i.chain,a.signed_bytes,a.policy_json,a.fee_limit,a.state,a.critical_sequence FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN solana_expiries e ON e.txid=a.txid WHERE a.txid=? AND i.resolved=1 AND a.state='review' AND o.status='review' AND a.preparation_generation=(SELECT MAX(generation) FROM preparations WHERE intent_id=i.id)" (Only txid)
      attempt <- case rows of [a]->pure a; _->reject "solana_retry_not_expected"
      paymentIdentity transport
      (ob,payment) <- readSavedPayment transport c ledger attempt
      signed <- case payment of SolanaPayment s->pure s; _->reject "wrong_destination_chain"
      checkExpiryOrigins ledger c
      recheckSourceWith transport c ledger ob
      proof <- solanaExpiryEvidence transport c signed >>= maybe (reject "solana_expiry_not_proven") pure
      recordSolanaRetryApproval ledger txid reason proof
    _ -> reject "duplicate_retry_approval"

-- One bounded pass; the database owns the queue across restarts. Reconciliation
-- runs even while paused, but only an available deployment may prepare/send.
paymentPass :: Manager -> Config -> Ledger -> (Int64 -> IO ()) -> IO ()
paymentPass manager c ledger backup = work `onException` pause ledger "payment_requires_reconciliation"
 where
  transport=realPaymentTransport manager c backup
  work=do
    attempts <- pendingAttempts ledger
    groups <- either reject pure (paymentAttemptGroups attempts)
    forM_ groups $ \family -> settleAttemptWith transport c ledger (last family) >> pure ()
    ready <- readyObligations ledger
    forM_ ready $ \ob -> do
      health <- readiness ledger
      busy <- ledgerAction ledger $ \db -> query db "SELECT id FROM intents WHERE chain=? AND resolved=0"
        (Only $ if obligationAsset ob=="Native" then ("Native"::Text) else "Solana") :: IO [Only Text]
      when (available health && null busy) $ do
        paymentIdentity transport
        recheckSourceWith transport c ledger ob
        txid <- if obligationAsset ob=="Native" then prepareNativePayment manager c ledger ob else prepareSolanaPayment manager c ledger ob
        fresh <- filter ((==txid) . attemptId) <$> pendingAttempts ledger
        case fresh of
          [attempt] -> settleAttemptWith transport c ledger attempt >> pure ()
          _ -> reject "prepared_attempt_missing"
