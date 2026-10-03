module Bridge.PaymentObservation
  ( PaymentObservation(..), observeNativePayment, readNativePayment, activeNativeBlock
  , observeSolanaPayment, solanaExpiryEvidence ) where
import Bridge.Domain (Amount,amount)
import Bridge.Error
import Bridge.Identity (digest)
import Bridge.Native (nativeAmount)
import Bridge.NativePayment
import Bridge.Solana (solanaGenesis,collectSignatures,SignatureInfo(..))
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Wire (PaymentCosts(..),Profile(..))
import Bridge.RPC (fieldValue,parseValue)
import Control.Exception (try)
import Data.Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data PaymentObservation = PaymentUnseen | PaymentWaiting
  | PaymentConfirmed PaymentCosts Text | PaymentFailed Amount Text deriving (Eq,Show)

observeNativePayment :: NativeRPC -> NativeSigned -> IO PaymentObservation
observeNativePayment call signed = do
  found<-readNativePayment call signed
  case found of
    Nothing->pure PaymentUnseen
    Just (confirmations,value)
      | confirmations<planDepth(signedNativePlan signed)->pure PaymentWaiting
      | otherwise->do
          anchor<-fieldValue "blockhash" value
          height<-activeNativeBlock call anchor (planDepth $ signedNativePlan signed)
          zero<-either reject pure (amount 0)
          pure $ PaymentConfirmed (PaymentCosts (signedNativeFee signed) zero) $ encoded $ object
            ["txid" .= nativeTxid(signedNativeTransaction signed),"blockhash" .= anchor
            ,"height" .= height,"requiredDepth" .= planDepth(signedNativePlan signed)]

-- Wallet effects must match the saved bytes, even before sufficient depth.
-- Only the node's explicit missing-transaction result means unseen.
readNativePayment :: NativeRPC -> NativeSigned -> IO (Maybe (Int,Value))
readNativePayment call signed = do
  let tx=signedNativeTransaction signed; plan=signedNativePlan signed
  found<-try (call True "gettransaction" [toJSON $ nativeTxid tx,Bool False,Bool True])
  case found of
    Left (BridgeError "rpc_error_-5")->pure Nothing
    Left (BridgeError code)->reject code
    Right value->do
      raw<-fieldValue "hex" value
      actual<-fieldValue "decoded" value >>= either reject pure . decodeNativeTx
      actualId<-fieldValue "txid" value
      fee<-fieldValue "fee" value >>= either reject pure . nativeAmount . negate
      require (raw==signedNativeBytes signed && actual==tx && actualId==nativeTxid tx && fee==signedNativeFee signed) "native_settlement_evidence_mismatch"
      either reject pure (validateNativeTx plan (signedNativePrevouts signed) fee actual)
      conflicts<-fieldValue "walletconflicts" value :: IO [Text]
      confirmations<-fieldValue "confirmations" value :: IO Int
      require (confirmations>=0 && null conflicts) "native_conflict_requires_review"
      pure (Just (confirmations,value))

activeNativeBlock :: NativeRPC -> Text -> Int -> IO Int64
activeNativeBlock call anchor depth = do
  require (T.length anchor==64 && T.all (`elem` ("0123456789abcdef"::String)) anchor && depth>0) "invalid_native_settlement_anchor"
  header<-call False "getblockheader" [toJSON anchor]
  actual<-fieldValue "hash" header
  confirmations<-fieldValue "confirmations" header :: IO Int
  height<-fieldValue "height" header :: IO Int64
  canonical<-call False "getblockhash" [toJSON height] >>= parseValue parseJSON
  require (actual==anchor && canonical==anchor && height>=0 && confirmations>=depth) "native_settlement_not_canonical"
  pure height

observeSolanaPayment :: SolanaRPC -> SolanaPolicy -> SolanaSigned -> IO PaymentObservation
observeSolanaPayment call config signed = do
  signature<-maybe (reject "helper_signature_missing") pure (replySignature $ signedSolanaReply signed)
  proof<-call "getTransaction" [toJSON signature,object
    ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
  if proof/=Null then do
    outcome<-either reject pure (verifySolanaOutcome config signed proof)
    let evidence=encoded $ object ["signature" .= signature,"outcome" .= outcome,"transactionHash" .= digest(BL.toStrict $ encode proof)]
    pure $ if outcomeSucceeded outcome
      then PaymentConfirmed (PaymentCosts (outcomeFee outcome) (outcomeRent outcome)) evidence
      else PaymentFailed (outcomeFee outcome) evidence
  else do
    response<-call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]]
    (_,value)<-contextValue (recentSlot $ solPlanRecent $ signedSolanaPlan signed) response
    statuses<-parseValue parseJSON value :: IO [Value]
    case statuses of
      [Null]->pure PaymentUnseen
      [status]->do
        finality<-fieldValue "confirmationStatus" status :: IO Text
        require (finality `elem` ["processed","confirmed"]) "finalized_solana_evidence_unavailable"
        pure PaymentWaiting
      _->reject "invalid_signature_status_response"

encoded :: ToJSON a => a -> Text
encoded=TE.decodeUtf8 . BL.toStrict . encode

-- Finalized height alone is insufficient: every configured provider must prove
-- absence from transaction/status lookup and both complete anchored histories.
solanaExpiryEvidence :: SolanaRPC -> Maybe SolanaRPC -> Profile -> SolanaPolicy -> (Text,Text) -> SolanaSigned -> IO (Maybe Text)
solanaExpiryEvidence primary independent profile config (tokenOrigin,operatingOrigin) signed=do
  require (solPlanFingerprint(signedSolanaPlan signed)==fingerprint config && minimumSlot>=0 && recentLastValidHeight recent>0) "saved_solana_policy_mismatch"
  height<-primary "getBlockHeight" [options minimumSlot] >>= parseValue parseJSON :: IO Int64
  require (height>=0) "expiry_provider_behind"
  if height<=recentLastValidHeight recent then pure Nothing else do
    require (not(T.null tokenOrigin) && not(T.null operatingOrigin)) "solana_expiry_history_required"
    signature<-maybe (reject "helper_signature_missing") pure (replySignature $ signedSolanaReply signed)
    proof<-evidence primary signature
    other<-case independent of
      Nothing->require (profile/=CanonicalBeta) "independent_rpc_required" >> pure Nothing
      Just call->Just <$> evidence call signature
    pure $ Just $ encoded $ object ["signature" .= signature,"blockhash" .= recentHash recent,
      "lastValidBlockHeight" .= recentLastValidHeight recent,"primary" .= proof,"independent" .= other]
 where
  recent=solPlanRecent $ signedSolanaPlan signed
  minimumSlot=recentSlot recent
  options slot=object ["commitment" .= ("finalized"::Text),"minContextSlot" .= slot]
  evidence call signature=do
    genesis<-call "getGenesisHash" [] >>= parseValue parseJSON
    require (genesis==solanaGenesis profile) "expiry_wrong_genesis"
    height<-call "getBlockHeight" [options minimumSlot] >>= parseValue parseJSON :: IO Int64
    require (height>recentLastValidHeight recent) "expiry_provider_behind"
    slot<-call "getSlot" [options minimumSlot] >>= parseValue parseJSON :: IO Int64
    require (slot>=minimumSlot) "expiry_provider_behind"
    (_,valid)<-call "isBlockhashValid" [toJSON $ recentHash recent,options slot] >>= contextValue slot
    require (valid==Bool False) "blockhash_still_valid"
    histories<-mapM (\(address,origin)->do
      rows<-collectSignatures origin Nothing $ \before->call "getSignaturesForAddress"
        [toJSON address,object $ ["commitment" .= ("finalized"::Text),"minContextSlot" .= slot,"limit" .= (100::Int)]
          <> maybe [] (\sig->["before" .= sig]) before] >>= parseValue parseJSON
      require (all ((/=signature).historySignature) rows) "expired_signature_in_history"
      pure $ object ["address" .= address,"origin" .= origin,"signatures" .=
        [object ["signature" .= historySignature row,"slot" .= historySlot row,"failed" .= historyFailed row] | row<-rows]])
      [(custodyAta config,tokenOrigin),(custodyOwner config,operatingOrigin)]
    transaction<-call "getTransaction" [toJSON signature,object ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
    require (transaction==Null) "expired_transaction_observed"
    (_,statuses)<-call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]] >>= contextValue slot
    require (statuses==toJSON [Null]) "expired_signature_observed"
    pure $ object ["genesis" .= genesis,"finalizedHeight" .= height,"minimumFinalizedSlot" .= slot,
      "blockhashValid" .= False,"histories" .= histories,"transaction" .= Null,"signatureStatuses" .= statuses]
