module Bridge.PaymentObservation
  ( PaymentObservation(..), observeNativePayment, readNativePayment, activeNativeBlock
  , observeSolanaPayment ) where
import Bridge.Domain (Amount,amount)
import Bridge.Error
import Bridge.Identity (digest)
import Bridge.Native (nativeAmount)
import Bridge.NativePayment
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Wire (PaymentCosts(..))
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
