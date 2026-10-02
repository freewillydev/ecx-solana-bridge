{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Reorg (reconcileNativeSettlementsWith,reconcileNativeSourcesWith,inspectNativeSourceWith) where

import qualified Bridge.Postgres.Ledger as PgLedger
import qualified Bridge.Postgres.NativeRecovery as PgNativeRecovery
import qualified Bridge.Postgres.Source as PgSource
import Bridge.Config
import Bridge.Ledger.Model
import Bridge.Native (nativeAmount)
import Bridge.NativePayment (ownedScript,transactionId,signedNativePlan,planDepth,signedNativeFee)
import Bridge.RPC
import Bridge.Settlement
import Bridge.Types
import Bridge.Postgres.Ledger (Ledger)
import Bridge.Postgres.PaymentStore
import Control.Exception (IOException,catch,try)
import Control.Monad (when,filterM)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Text.Read (readMaybe)

-- A missing RPC response cannot prove that credited source value disappeared.
-- Only a canonical native wallet conflict creates a financial deficit here.
reconcileNativeSourcesWith :: PaymentTransport -> Config -> Ledger -> IO Value
reconcileNativeSourcesWith transport c ledger=do
  sources <- PgSource.candidates ledger
  when (length sources>1000) $ PgLedger.pause ledger "source_recovery_backlog"
  require (length sources<=1000) "source_recovery_backlog"
  reports <- mapM reconcile sources
  pure $ object ["sources" .= reports,"signedOrSent" .= False]
 where
  unavailable code=SourceUnavailable $ object ["reason" .= code]
  reconcile source=do
    checked <- try (inspectNativeSourceWith transport c ledger source `catch` (\(_::IOException)->reject "source_recovery_io_unavailable")) :: IO (Either BridgeError SourceCheck)
    let result=either (\(BridgeError code)->unavailable code) id checked
    committed <- try (PgSource.recordCheck ledger source result) :: IO (Either BridgeError ())
    case committed of
      Right ()->pure $ report source result
      Left (BridgeError code)->do
        saved <- try (PgSource.recordCheck ledger source $ unavailable code) :: IO (Either BridgeError ())
        case saved of
          Right ()->pure ()
          Left (BridgeError changed)->PgLedger.pause ledger ("source_recovery:"<>changed)
        pure $ report source (unavailable code)
  report source check=object ["deposit" .= depositId source,"state" .= (case check of
    SourcePending _->"pending"; SourceMissing _->"missing"; SourceRestored _->"restored"; SourceUnavailable _->"requires_review"::Text)]


inspectNativeSourceWith :: PaymentTransport -> Config -> Ledger -> Deposit -> IO SourceCheck
inspectNativeSourceWith transport c ledger source=do
  paymentIdentity transport
  wallet <- call True "getwalletinfo" []
  name <- fieldValue "walletname" wallet
  descriptors <- fieldValue "descriptors" wallet
  scanning <- fieldValue "scanning" wallet :: IO Value
  require (name==nativeWallet c && descriptors && scanning==Bool False) "native_wallet_not_ready"
  position <- fieldValue "lastprocessedblock" wallet
  nodeAnchor <- fieldValue "hash" position
  nodeHeight <- fieldValue "height" position :: IO Int64
  actualHeight <- activeNativeBlock call nodeAnchor 1
  require (actualHeight==nodeHeight && nodeHeight>=nativeCheckpointHeight c) "native_source_wallet_behind"
  (txid,index)<-case T.splitOn ":" (depositId source) of
    ["native",tx,n] | transactionId tx,Just i<-readMaybe (T.unpack n),i>=0->pure(tx,i::Int)
    _->reject "invalid_native_deposit_id"
  value <- call True "gettransaction" [toJSON txid,Bool False,Bool True]
  actual <- fieldValue "txid" value
  processed <- fieldValue "lastprocessedblock" value
  decoded <- fieldValue "decoded" value
  decodedId <- fieldValue "txid" decoded
  outputs <- fieldValue "vout" decoded :: IO [Value]
  details <- fieldValue "details" value :: IO [Value]
  require (actual==txid && decodedId==txid && processed==position && index<length outputs
    && length outputs<=1000 && length details<=1000) "native_source_binding_mismatch"
  matched <- filterM (\detail->(==index) <$> (fieldValue "vout" detail :: IO Int)) details
  detail <- case matched of [d]->pure d; _->reject "native_source_receipt_ambiguous"
  category <- fieldValue "category" detail :: IO Text
  address <- fieldValue "address" detail
  detailAmount <- fieldValue "amount" detail >>= either reject pure . nativeAmount
  require (category `elem` ["receive","generate","immature","orphan"] && detailAmount==depositAmount source) "native_source_binding_mismatch"
  let output=outputs!!index
  number <- fieldValue "n" output :: IO Int
  quantity <- fieldValue "value" output >>= either reject pure . nativeAmount
  script <- fieldValue "scriptPubKey" output >>= fieldValue "hex"
  owned <- ownedScript call address
  require (number==index && quantity==depositAmount source && owned==script) "native_source_binding_mismatch"
  needed <- case depositOrder source of
    Nothing->pure $ if category=="receive" then nativeConfirmations c else max 101 (nativeConfirmations c)
    Just oid->do
      (instruction,saved)<-PgSource.orderBinding ledger oid
      policy<-either (const $ reject "native_source_policy_invalid") pure (eitherDecodeStrict' $ TE.encodeUtf8 saved)
      require (category=="receive" && instruction==address && deploymentFingerprint policy==fingerprint c) "native_source_binding_mismatch"
      pure (nativeDepth policy)
  confirmations <- fieldValue "confirmations" value :: IO Int
  anchor <- parseValue (withObject "source" (.:? "blockhash")) value :: IO (Maybe Text)
  conflicts <- fieldValue "walletconflicts" value :: IO [Text]
  require (length conflicts<=100 && all transactionId conflicts) "invalid_native_source_conflicts"
  (observationHash,old)<-PgSource.eventEvidence ledger txid
  event <- either (const $ reject "source_recovery_scan_not_current") pure (eitherDecodeStrict' $ TE.encodeUtf8 old)
  recordedDepth <- fieldValue "proof" event >>= fieldValue "confirmations"
  recordedAnchor <- fieldValue "anchor" event
  require (recordedDepth==confirmations && recordedAnchor==maybe "unconfirmed" id anchor
    && depositConfirmations source==max 0 confirmations && depositAnchor source==recordedAnchor) "source_recovery_scan_not_current"
  let proof=object ["transaction" .= txid,"output" .= index,"confirmations" .= confirmations,"block" .= anchor
        ,"nodeBlock" .= nodeAnchor,"nodeHeight" .= nodeHeight,"conflicts" .= conflicts,"observationHash" .= observationHash]
  result <- if confirmations<0 then do
    mempool <- try (call False "getmempoolentry" [toJSON txid]) :: IO (Either BridgeError Value)
    require (case mempool of Left (BridgeError "rpc_error_-5")->True; _->False) "native_source_conflict_not_proven"
    unspent <- call False "gettxout" [toJSON txid,toJSON index,Bool True]
    require (unspent==Null) "native_source_conflict_not_proven"
    pure (SourceMissing proof)
   else do
    require (null conflicts && category/="orphan") "native_source_conflict_requires_review"
    if confirmations==0 then do
      mempool <- call False "getmempoolentry" [toJSON txid]
      size <- fieldValue "vsize" mempool :: IO Int
      require (size>0) "native_source_mempool_invalid"
     else do
      block <- maybe (reject "native_source_block_missing") pure anchor
      _ <- activeNativeBlock call block 1
      pure ()
    pure $ if confirmations>=needed then SourceRestored proof else SourcePending proof
  -- A wallet catching up or a changing source cannot authorize a bookkeeping
  -- transition. The ledger separately fences changes to its saved observation.
  again <- call True "gettransaction" [toJSON txid,Bool False,Bool True]
  require (again==value) "native_source_view_changed"
  pure result
 where call=paymentNative transport

-- Recheck previously settled native bytes when their recorded finality changed.
-- A different proved family winner adjusts its fee only, without a new payment.
reconcileNativeSettlementsWith :: PaymentTransport -> Config -> Ledger -> IO Value
reconcileNativeSettlementsWith transport c ledger=do
  candidates <- PgNativeRecovery.candidates ledger
  when (length candidates>1000) $ PgLedger.pause ledger "native_settlement_recovery_backlog"
  require (length candidates<=1000) "native_settlement_recovery_backlog"
  reports <- mapM reconcile candidates
  pure $ object ["payments" .= map fst reports,"signedOrSent" .= False,"monetaryPostings" .= any snd reports]
 where
  reconcile attempt=do
    previous <- PgNativeRecovery.observation ledger (attemptId attempt)
    checked <- try (inspect attempt `catch` (\(_::IOException)->reject "native_recovery_io_unavailable")) :: IO (Either BridgeError NativeSettlementCheck)
    let result=either (\(BridgeError code)->NativeSettlementUnavailable code) id checked
    committed <- try (PgNativeRecovery.recordCheck ledger attempt previous result) :: IO (Either BridgeError ())
    case committed of
      Left (BridgeError code)->do
        pending <- try (PgNativeRecovery.recordCheck ledger attempt previous (NativeSettlementUnavailable code)) :: IO (Either BridgeError ())
        case pending of
          Right ()->pure $ report attempt "requires_review" (Just code)
          Left (BridgeError changed)->do
            PgLedger.pause ledger ("native_settlement_recovery:"<>changed)
            pure $ report attempt "requires_review" (Just changed)
      Right ()->pure $ case result of
        NativeSettlementConfirming->report attempt "confirming" Nothing
        NativeSettlementUnavailable code->report attempt "requires_review" (Just code)
        NativeSettlementReconfirmed _ _->report attempt "reconfirmed" Nothing
        NativeSettlementReplaced _ winner _ _->(object ["transaction" .= winner,"previousTransaction" .= attemptId attempt
          ,"state" .= ("winner_changed"::Text),"error" .= (Nothing::Maybe Text)],True)
  inspect attempt=do
    paymentIdentity transport
    wallet <- paymentNative transport True "getwalletinfo" []
    name <- fieldValue "walletname" wallet
    descriptors <- fieldValue "descriptors" wallet
    scanning <- fieldValue "scanning" wallet :: IO Value
    require (name==nativeWallet c && descriptors && scanning==Bool False) "native_wallet_not_ready"
    (_,saved) <- readSavedPayment transport c ledger attempt
    payment <- case saved of NativePayment value->pure value; _->reject "wrong_destination_chain"
    family <- paymentNativeFamily ledger (attemptIntent attempt)
    if length family==1 then observeNativePayment (paymentNative transport) payment >>= sameWinner else do
      (members,view) <- readSavedNativeFamily transport c ledger family
      active <- activeFamilyPayment members view
      case active of
        Just (winner,signed,depth,value)->do
          if depth<planDepth (signedNativePlan signed) then pure NativeSettlementConfirming else do
            anchor <- fieldValue "blockhash" value
            height <- activeNativeBlock (paymentNative transport) anchor (planDepth $ signedNativePlan signed)
            noRent <- either reject pure (amount 0)
            let costs=PaymentCosts (signedNativeFee signed) noRent
                proof=TE.decodeUtf8 $ LBS.toStrict $ encode $ object
                  ["txid" .= attemptId winner,"blockhash" .= anchor,"height" .= height,"requiredDepth" .= planDepth (signedNativePlan signed)]
            pure $ if attemptId winner==attemptId attempt then NativeSettlementReconfirmed costs proof
              else NativeSettlementReplaced family (attemptId winner) costs proof
        Nothing->pure $ NativeSettlementUnavailable "native_settled_payment_unseen"
  sameWinner observation=case observation of
      PaymentConfirmed costs proof->pure $ NativeSettlementReconfirmed costs proof
      PaymentWaiting->pure NativeSettlementConfirming
      PaymentUnseen->pure $ NativeSettlementUnavailable "native_settled_payment_unseen"
      PaymentFailed _ _->reject "unexpected_native_payment_failure"
  report attempt state failure=(object ["transaction" .= attemptId attempt,"state" .= (state::Text),"error" .= (failure::Maybe Text)],False)
