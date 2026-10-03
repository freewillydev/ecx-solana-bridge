-- Read-only evidence for uncertain administration attempts. Never authorizes retry.
module Bridge.AdminStatus (Status(..),inspectStatus,classifyStatus) where
import Bridge.Error (require,reject)
import Bridge.RPC
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (parseEither,Parser)
import Data.Text (Text)
import Network.HTTP.Client (parseRequest,secure,closeManager)

data Status = Pending | Finalized | Failed | Unseen | ExpiredUnseen deriving (Eq,Show)
instance ToJSON Status where toJSON=String . name
name :: Status -> Text
name Pending="pending"
name Finalized="finalized"
name Failed="failed"
name Unseen="unseen"
name ExpiredUnseen="expired-unseen"

-- Callers first verify the archived signatures and their closed operation intent.
inspectStatus :: Text -> String -> Text -> Text -> Text -> IO Status
inspectStatus genesis endpoint signature bytes blockhash=do
  transport<-parseRequest endpoint
  require (secure transport) "administration_requires_https"
  bracket newRpcManager closeManager $ \manager->do
    let call=rpc manager endpoint Nothing
    actual<-call "getGenesisHash" [] >>= parseValue parseJSON
    require (actual==genesis) "wrong_administration_network"
    values<-call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]] >>= fieldValue "value"
    status<-case values of [value]->pure value; _->reject "invalid_administration_status"
    transaction<-call "getTransaction" [toJSON signature,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
    valid<-if status==Null && transaction==Null then
      call "isBlockhashValid" [toJSON blockhash,object ["commitment" .= ("finalized"::Text)]] >>= fieldValue "value"
      else pure True
    either (const $ reject "administration_status_mismatch") pure (classifyStatus bytes status transaction valid)

-- Absence can reflect pruned/unavailable history: ExpiredUnseen is not nonexecution proof.
classifyStatus :: Text -> Value -> Value -> Bool -> Either String Status
classifyStatus bytes status transaction valid
  | status==Null = if transaction/=Null then Left "inconsistent transaction history"
      else Right (if valid then Unseen else ExpiredUnseen)
  | otherwise = parseEither (withObject "signature status" $ \s->do
      commitment<-s .: "confirmationStatus" :: Parser Text
      failure<-s .: "err" :: Parser Value
      case commitment of
        "finalized"->withObject "finalized transaction" (\t->do
          encoded<-t .: "transaction"
          unless (encoded==[bytes,"base64"]) (fail "saved bytes mismatch")
          metadata<-t .: "meta"
          actual<-withObject "metadata" (.: "err") metadata
          unless (actual==failure) (fail "status disagreement")
          pure (if failure==Null then Finalized else Failed)) transaction
        "processed"->pending
        "confirmed"->pending
        _->fail "unknown commitment") status
 where
  pending=if transaction==Null then pure Pending else fail "history changed during read; inspect again"
