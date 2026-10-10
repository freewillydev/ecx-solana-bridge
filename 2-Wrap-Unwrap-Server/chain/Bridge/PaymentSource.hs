-- Focused source reads never advance scanner checkpoints or invent receipts.
module Bridge.PaymentSource (verifyPaymentSource,inspectNativeSource) where
import Bridge.Domain (Asset(..))
import Bridge.Error
import Bridge.Native (nativeAmount)
import qualified Bridge.Native as N
import Control.Exception (try)
import Control.Monad (filterM)
import Data.Int (Int64)
import Bridge.NativePayment (NativeRPC,transactionId,ownedScript)
import Bridge.PaymentObservation (activeNativeBlock)
import Bridge.RPC (fieldValue,parseValue)
import Bridge.SolanaPayment (SolanaRPC)
import Bridge.SolanaDeposit
import qualified Bridge.SolanaHelper as H
import qualified Bridge.Wire as W
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

verifyPaymentSource :: NativeRPC -> SolanaRPC -> Maybe SolanaRPC -> W.Profile -> H.SolanaPolicy -> W.PaymentSource -> IO W.Deposit
verifyPaymentSource native solana independent profile config binding = do
  let deposit=W.sourceDeposit binding; policy=W.sourcePolicy binding
      instruction=W.sourceInstruction binding; request=W.sourceRequest binding
  require (W.deploymentFingerprint policy==H.fingerprint config && W.solanaCommitment policy=="finalized"
    && W.nativeDepth policy>0) "payment_profile_mismatch"
  case W.depositAsset deposit of
    Native->do
      (txid,index)<-case T.splitOn ":" (W.depositId deposit) of
        ["native",tx,n] | T.length tx==64,T.all (`elem` ("0123456789abcdef"::String)) tx,
          Just i<-readMaybe (T.unpack n),i>=0->pure(tx,i::Int)
        _->reject "invalid_native_deposit_id"
      value<-native True "gettransaction" [toJSON txid,Bool False,Bool True]
      actual<-fieldValue "txid" value
      decoded<-fieldValue "decoded" value
      decodedId<-fieldValue "txid" decoded
      outputs<-fieldValue "vout" decoded :: IO [Value]
      require (actual==txid && decodedId==txid && index<length outputs) "source_binding_mismatch"
      let output=outputs!!index
      actualIndex<-fieldValue "n" output :: IO Int
      quantity<-fieldValue "value" output >>= either reject pure . nativeAmount
      script<-fieldValue "scriptPubKey" output >>= fieldValue "hex"
      address<-native True "getaddressinfo" [toJSON instruction]
      owned<-fieldValue "ismine" address
      ownedScript<-fieldValue "scriptPubKey" address :: IO Text
      require (owned && actualIndex==index && quantity==W.depositAmount deposit && script==ownedScript) "source_binding_mismatch"
      depth<-fieldValue "confirmations" value
      conflicts<-fieldValue "walletconflicts" value :: IO [Text]
      if depth<W.nativeDepth policy || not(null conflicts)
        then pure deposit {W.depositAnchor="unconfirmed",W.depositConfirmations=max 0 depth,W.depositEligible=False}
        else do
          anchor<-fieldValue "blockhash" value
          _<-activeNativeBlock native anchor (W.nativeDepth policy)
          pure deposit {W.depositAnchor=anchor,W.depositConfirmations=depth,W.depositEligible=True}
    Wrapped->do
      signature<-maybe (reject "invalid_solana_deposit_id") pure (T.stripPrefix "solana:" $ W.depositId deposit)
      verify<-case T.stripPrefix "solana-pay:" instruction of
        Just reference->pure (verifyPay $ PayBinding signature (H.mint config) (H.custodyAta config) (H.custodyOwner config) reference)
        Nothing->do
          owner<-maybe (reject "source_owner_missing") pure (W.sourceOwner request)
          pure (verifyDeposit $ DepositBinding signature owner (H.mint config) (H.custodyAta config) (H.custodyOwner config) instruction)
      let proof call=call "getTransaction" [toJSON signature,object
            ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (1::Int)]] >>= either reject pure . verify
      verified<-proof solana
      require (verifiedAmount verified==W.depositAmount deposit && T.pack(show $ verifiedSlot verified)==W.depositAnchor deposit) "source_binding_mismatch"
      case independent of
        Nothing->require (profile/=W.CanonicalBeta) "independent_rpc_required"
        Just call->proof call >>= \other->require (other==verified) "source_verifier_disagreement"
      pure deposit {W.depositConfirmations=1,W.depositEligible=True}
    Sol->reject "unsupported_source_asset"

-- The caller verifies network identity and supplies a closed ledger snapshot.
-- Negative wallet confirmation alone is insufficient to book a missing source.
inspectNativeSource :: NativeRPC -> N.NativeSettings -> Int -> Text -> W.Deposit -> Maybe (Text,W.PolicySnapshot) -> (Text,Value) -> IO W.SourceCheck
inspectNativeSource call c minimumDepth identity source binding observation=do
  require (W.depositAsset source==Native && minimumDepth>0) "invalid_native_source_receipt"
  wallet <- N.nativeWalletInfoWith call c
  position <- fieldValue "lastprocessedblock" wallet
  nodeAnchor <- fieldValue "hash" position
  nodeHeight <- fieldValue "height" position :: IO Int64
  actualHeight <- activeNativeBlock call nodeAnchor 1
  require (actualHeight==nodeHeight && nodeHeight>=N.nativeCheckpointHeight c) "native_source_wallet_behind"
  (txid,index)<-case T.splitOn ":" (W.depositId source) of
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
  require (category `elem` ["receive","generate","immature","orphan"] && detailAmount==W.depositAmount source) "native_source_binding_mismatch"
  let output=outputs!!index
  number <- fieldValue "n" output :: IO Int
  quantity <- fieldValue "value" output >>= either reject pure . nativeAmount
  script <- fieldValue "scriptPubKey" output >>= fieldValue "hex"
  owned <- ownedScript call address
  require (number==index && quantity==W.depositAmount source && owned==script) "native_source_binding_mismatch"
  needed <- case W.depositOrder source of
    Nothing->pure $ if category=="receive" then minimumDepth else max 101 (minimumDepth)
    Just _->do
      (instruction,policy)<-maybe (reject "native_source_policy_invalid") pure binding
      require (category=="receive" && instruction==address && W.deploymentFingerprint policy==identity
        && W.nativeDepth policy>0 && W.nativeDepth policy<=1008) "native_source_binding_mismatch"
      pure (W.nativeDepth policy)
  confirmations <- fieldValue "confirmations" value :: IO Int
  anchor <- parseValue (withObject "source" (.:? "blockhash")) value :: IO (Maybe Text)
  conflicts <- fieldValue "walletconflicts" value :: IO [Text]
  require (length conflicts<=100 && all transactionId conflicts) "invalid_native_source_conflicts"
  let (observationHash,event)=observation
  recordedDepth <- fieldValue "proof" event >>= fieldValue "confirmations"
  recordedAnchor <- fieldValue "anchor" event
  require (recordedDepth==confirmations && recordedAnchor==maybe "unconfirmed" id anchor
    && W.depositConfirmations source==max 0 confirmations && W.depositAnchor source==recordedAnchor) "source_recovery_scan_not_current"
  let proof=object ["transaction" .= txid,"output" .= index,"confirmations" .= confirmations,"block" .= anchor
        ,"nodeBlock" .= nodeAnchor,"nodeHeight" .= nodeHeight,"conflicts" .= conflicts,"observationHash" .= observationHash]
  result <- if confirmations<0 then do
    mempool <- try (call False "getmempoolentry" [toJSON txid]) :: IO (Either BridgeError Value)
    require (case mempool of Left (BridgeError "rpc_error_-5")->True; _->False) "native_source_conflict_not_proven"
    unspent <- call False "gettxout" [toJSON txid,toJSON index,Bool True]
    require (unspent==Null) "native_source_conflict_not_proven"
    pure (W.SourceMissing proof)
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
    pure $ if confirmations>=needed then W.SourceRestored proof else W.SourcePending proof
  -- A wallet catching up or a changing source cannot authorize a bookkeeping
  -- transition. The ledger separately fences changes to its saved observation.
  again <- call True "gettransaction" [toJSON txid,Bool False,Bool True]
  require (again==value) "native_source_view_changed"
  pure result
