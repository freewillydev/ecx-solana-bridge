module Bridge.SolanaHelper where

import Bridge.Config
import Bridge.Process
import Bridge.SolanaMessage
import Bridge.Types
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

data HelperRequest = HelperRequest
  { helperPayout :: !Bool, helperOwner :: !Text, helperRecipient :: !Text
  , helperAmount :: !Amount, helperBlockhash :: !Text, helperReference :: !Text
  } deriving (Eq,Show,Generic)
instance ToJSON HelperRequest where
  toJSON HelperRequest{..} = object
    ["protocol" .= (1::Int),"verb" .= (if helperPayout then "payout" else "deposit"::Text)
    ,"owner" .= helperOwner,"recipient" .= helperRecipient,"amount" .= helperAmount
    ,"blockhash" .= helperBlockhash,"order_id" .= helperReference,"create_ata" .= helperPayout]
instance FromJSON HelperRequest where
  parseJSON = withObject "helper request" $ \o -> do
    protocol <- o .: "protocol" :: Parser Int
    verb <- o .: "verb" :: Parser Text
    createAta <- o .: "create_ata"
    unless (protocol==1 && verb `elem` ["deposit","payout"] && createAta==(verb=="payout")) (fail "unsupported helper request")
    HelperRequest (verb=="payout") <$> o .: "owner" <*> o .: "recipient" <*> o .: "amount" <*> o .: "blockhash" <*> o .: "order_id"

data HelperReply = HelperReply
  { replyProtocol :: !Int, replyTransaction :: !Text, replyMessage :: !Text
  , replySignature :: !(Maybe Text), replySource :: !Text
  , replyDestination :: !Text, replyMemo :: !Text
  } deriving (Eq,Show)
instance FromJSON HelperReply where
  parseJSON = withObject "helper reply" $ \o -> HelperReply <$> o .: "protocol"
    <*> o .: "transaction" <*> o .: "message" <*> o .: "signature"
    <*> o .: "source_ata" <*> o .: "destination_ata" <*> o .: "memo"
instance ToJSON HelperReply where
  toJSON HelperReply{..} = object ["protocol" .= replyProtocol,"transaction" .= replyTransaction
    ,"message" .= replyMessage,"signature" .= replySignature,"source_ata" .= replySource
    ,"destination_ata" .= replyDestination,"memo" .= replyMemo]

helperMemo :: Config -> HelperRequest -> Text
helperMemo c request = "ecx-bridge:v1:"<>deploymentId c<>":"<>
  (if helperPayout request then "payout" else "deposit")<>":"<>helperReference request

validateHelperRequest :: Config -> HelperRequest -> Either Text ()
validateHelperRequest c HelperRequest{..} = do
  unless (validIdentifier helperReference && units helperAmount>0
    && helperOwner/=helperRecipient
    && (if helperPayout then helperOwner==custodyOwner c else helperRecipient==custodyOwner c))
    (Left "invalid_helper_request")
  mapM_ (\key -> unless (T.length key<=44) (Left "invalid_public_key") >> publicKey key >> pure ())
    [helperOwner,helperRecipient,helperBlockhash]

validateHelperReply :: Config -> HelperRequest -> HelperReply -> Either Text Transaction
validateHelperReply c request@HelperRequest{..} HelperReply{..} = do
  validateHelperRequest c request
  unless (replyProtocol==1 && replyMemo==helperMemo c request
    && (if helperPayout then replySource==custodyAta c else replyDestination==custodyAta c))
    (Left "helper_identity_mismatch")
  mapM_ (\key -> unless (T.length key<=44) (Left "invalid_public_key")) [replySource,replyDestination]
  let expected=Expected helperOwner helperRecipient (mint c) replySource replyDestination helperBlockhash
        helperAmount (helperMemo c request) helperPayout helperPayout
  tx@(Transaction signatures _ message) <- validateTransaction expected replyTransaction
  encodedMessage <- either (const $ Left "invalid_helper_message") Right (B64.decode $ TE.encodeUtf8 replyMessage)
  unless (encodedMessage==message) (Left "helper_message_mismatch")
  let expectedSignature=if helperPayout then case signatures of [sig]->Just (base58 sig); _->Nothing else Nothing
  unless (replySignature==expectedSignature) (Left "helper_signature_mismatch")
  pure tx

invokeHelper :: Config -> HelperRequest -> IO HelperReply
invokeHelper c request = do
  either reject pure (validateHelperRequest c request)
  output <- runBounded 10 8192 (helperPath c) ["--config",helperConfig c] (LBS.toStrict $ encode request)
  reply <- either (const $ reject "invalid_helper_reply") pure (eitherDecodeStrict' output)
  _ <- either reject pure (validateHelperReply c request reply)
  pure reply

-- The SDK's exact message is unchanged. A zero signature cannot authorize a
-- payment, even if a simulation provider attempts to relay this transaction.
-- The real signature was verified locally by validateHelperReply above.
unsignedSimulation :: Transaction -> Text
unsignedSimulation (Transaction _ _ message) = TE.decodeUtf8 $ B64.encode
  (BS.singleton 1<>BS.replicate 64 0<>message)
