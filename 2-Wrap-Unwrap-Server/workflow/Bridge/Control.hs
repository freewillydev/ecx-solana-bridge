{-# LANGUAGE ConstraintKinds, DataKinds, GADTs, RankNTypes, ScopedTypeVariables #-}
-- Private operator transport: a closed command becomes a typed DSL plan.
module Bridge.Control (runControl,callControl) where
import Bridge.Error
import Bridge.Operation.Internal (Plan,Caller(Operator),OperatorOperations,OperatorRead(..),OperatorWrite(..),operator,operatorRead)
import Control.Exception (bracket,catch,IOException)
import Control.Monad (forever)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser,parseEither)
import Data.Binary.Get (runGet,getWord32be)
import Data.Binary.Put (runPut,putWord32be)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as S
import System.Directory (removeFile)
import System.FilePath ((</>),isAbsolute,normalise)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data ControlPlan where
  ControlPlan :: ToJSON a => Plan Operator a -> ControlPlan

controlPlan :: OperatorOperations => Value -> Parser ControlPlan
controlPlan=withObject "operator command" $ \o->do
  command<-o .: "operation" :: Parser Text
  let fields expected=if all (`elem` expected) (KM.keys o) then pure () else fail "unknown field"
  case command of
    "native-reviews"->fields ["operation"] >> pure (ControlPlan $ operatorRead NativeReviews)
    "rebroadcast-native"->do
      fields ["operation","transaction","recovery","reason"]
      (\transaction recovery reason -> ControlPlan $ operator $ \cap -> rebroadcastNative cap transaction recovery reason) <$> o .: "transaction" <*> o .: "recovery" <*> o .: "reason"
    "repair-completed-order"->fields ["operation","order"] >> ((\order -> ControlPlan $ operator $ \cap -> repairCompletedOrder cap order) <$> o .: "order")
    "treasury-receipts"->fields ["operation"] >> pure (ControlPlan $ operatorRead TreasuryReceipts)
    "status"->fields ["operation"] >> pure (ControlPlan $ operatorRead ServiceState)
    "pause"->fields ["operation","reason"] >> ((\reason -> ControlPlan $ operator $ \cap -> pauseService cap reason) <$> o .: "reason")
    "cover-source-loss"->do
      fields ["operation","deposit","recovery","float","earned","reason"]
      (\deposit recovery float earned reason -> ControlPlan $ operator $ \cap -> coverLostSource cap deposit recovery float earned reason) <$> o .: "deposit" <*> o .: "recovery" <*> o .: "float" <*> o .: "earned" <*> o .: "reason"
    "approve-covered-source"->do
      fields ["operation","payment","recovery","reason"]
      (\payment recovery reason -> ControlPlan $ operator $ \cap -> approveCovered cap payment recovery reason) <$> o .: "payment" <*> o .: "recovery" <*> o .: "reason"
    "approve-source-recovery"->do
      fields ["operation","payment","restoration","reason"]
      (\payment restoration reason -> ControlPlan $ operator $ \cap -> restoreSource cap payment restoration reason) <$> o .: "payment" <*> o .: "restoration" <*> o .: "reason"
    "classify-spend"->do
      fields ["operation","chain","transaction","reason"]
      (\chain transaction reason -> ControlPlan $ operator $ \cap -> classifySpend cap chain transaction reason) <$> o .: "chain" <*> o .: "transaction" <*> o .: "reason"
    "allocate-treasury"->do
      fields ["operation","deposit","split","reason"]
      (\deposit split reason -> ControlPlan $ operator $ \cap -> allocateReceipt cap deposit split reason) <$> o .: "deposit" <*> o .: "split" <*> o .: "reason"
    "withdraw-fees"->do
      fields ["operation","id","asset","amount","recipient","reason"]
      (\id asset amount recipient reason -> ControlPlan $ operator $ \cap -> withdrawFees cap id asset amount recipient reason) <$> o .: "id" <*> o .: "asset" <*> o .: "amount" <*> o .: "recipient" <*> o .: "reason"
    "cancel-fees"->do
      fields ["operation","id","reason"]
      (\id reason -> ControlPlan $ operator $ \cap -> cancelFeeWithdrawal cap id reason) <$> o .: "id" <*> o .: "reason"
    "draft-replacement"->do
      fields ["operation","parent","fee","reason"]
      (\parent fee reason -> ControlPlan $ operator $ \cap -> draftNativeReplacement cap parent fee reason) <$> o .: "parent" <*> o .: "fee" <*> o .: "reason"
    "sign-replacement"->do
      fields ["operation","decision"]
      (\decision -> ControlPlan $ operator $ \cap -> signNativeReplacement cap decision) <$> o .: "decision"
    "cancel-replacement"->do
      fields ["operation","decision","reason"]
      (\decision reason -> ControlPlan $ operator $ \cap -> cancelNativeReplacement cap decision reason) <$> o .: "decision" <*> o .: "reason"
    "retry-solana"->do
      fields ["operation","transaction","reason"]
      (\transaction reason -> ControlPlan $ operator $ \cap -> retrySolanaPayment cap transaction reason) <$> o .: "transaction" <*> o .: "reason"
    "cancel-preparation"->do
      fields ["operation","payment","generation","reason"]
      (\payment generation reason -> ControlPlan $ operator $ \cap -> cancelPreparation cap payment generation reason) <$> o .: "payment" <*> o .: "generation" <*> o .: "reason"
    "refund"->fields ["operation","deposit"] >> ((\deposit -> ControlPlan $ operator $ \cap -> refundDeposit cap deposit) <$> o .: "deposit")
    "resume"->fields ["operation"] >> pure (ControlPlan $ operator resumeService)
    _->fail "unknown operation"

privatePath :: Bool -> FilePath -> IO ()
privatePath directory path=do
  status<-getSymbolicLinkStatus path
  uid<-getEffectiveUserID
  require ((if directory then isDirectory status else isSocket status) &&
    fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_operator_permissions"

controlPath :: FilePath -> IO FilePath
controlPath directory=do
  require (isAbsolute directory && normalise directory==directory) "invalid_operator_directory"
  privatePath True directory
  pure (directory </> "operator.sock")

-- Caller holds the writer's host fence for this listener's entire lifetime.
runControl :: OperatorOperations => FilePath -> (forall a. Plan Operator a -> IO a) -> IO ()
runControl directory evaluate=do
  path<-controlPath directory
  (privatePath False path >> removeFile path) `catch` (\(e::IOException)->
    if isDoesNotExistError e then pure () else ioError e)
  bracket (S.socket S.AF_UNIX S.Stream S.defaultProtocol) S.close $ \listener->do
    S.bind listener (S.SockAddrUnix path)
    bracket (setFileMode path 0o600 >> pure ()) (const $ removeFile path) $ \()->do
      S.listen listener 8
      forever $ bracket (fst <$> S.accept listener) S.close $ \socket->
        (do
          _<-timeout 120000000 $ do
            reply<-(do
              bytes<-receive 4096 socket
              value<-either (const $ reject "invalid_operator_request") pure (eitherDecodeStrict' bytes)
              ControlPlan plan<-either (const $ reject "invalid_operator_operation") pure (parseEither controlPlan value)
              toJSON <$> evaluate plan) `catch` (\(BridgeError code)->pure $ object ["error" .= code])
            send 524288 socket (L.toStrict $ encode reply)
          pure ()) `catch` (\(_::IOException)->pure ())

callControl :: OperatorOperations => FilePath -> Value -> IO Value
callControl directory command=do
  _<-either (const $ reject "invalid_operator_operation") pure (parseEither controlPlan command)
  path<-controlPath directory
  privatePath False path
  bracket (S.socket S.AF_UNIX S.Stream S.defaultProtocol) S.close $ \socket->do
    result<-timeout 130000000 $ do
      S.connect socket (S.SockAddrUnix path)
      send 4096 socket (L.toStrict $ encode command)
      reply<-receive 524288 socket
      either (const $ reject "invalid_operator_reply") pure (eitherDecodeStrict' reply)
    maybe (reject "operator_outcome_unknown") pure result

send :: Int -> S.Socket -> B.ByteString -> IO ()
send limit socket bytes=do
  require (not(B.null bytes) && B.length bytes<=limit) "operator_message_too_large"
  S.sendAll socket (L.toStrict (runPut $ putWord32be $ fromIntegral $ B.length bytes) <> bytes)

receive :: Int -> S.Socket -> IO B.ByteString
receive limit socket=do
  header<-exactly 4 []
  let size=toInteger $ runGet getWord32be $ L.fromStrict header
  require (size>0 && size<=toInteger limit) "operator_message_too_large"
  exactly (fromInteger size) []
 where
  exactly 0 chunks=pure (B.concat $ reverse chunks)
  exactly n chunks=do
    bytes<-S.recv socket n
    require (not $ B.null bytes) "operator_connection_closed"
    exactly (n-B.length bytes) (bytes:chunks)
