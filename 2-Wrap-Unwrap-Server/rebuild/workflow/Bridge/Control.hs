{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables #-}
-- Private operator transport: a closed command becomes a typed DSL plan.
module Bridge.Control (runControl,callControl) where
import Bridge.Error
import Bridge.Operation.Internal (Plan,Caller(Operator),OperatorRead(..),OperatorWrite(..),operator,operatorRead)
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

controlPlan :: Value -> Parser ControlPlan
controlPlan=withObject "operator command" $ \o->do
  command<-o .: "operation" :: Parser Text
  let fields expected=if all (`elem` expected) (KM.keys o) then pure () else fail "unknown field"
  case command of
    "status"->fields ["operation"] >> pure (ControlPlan $ operatorRead ServiceState)
    "pause"->fields ["operation","reason"] >> (ControlPlan . operator . PauseService <$> o .: "reason")
    "cancel-preparation"->do
      fields ["operation","payment","generation","reason"]
      ControlPlan . operator <$> (CancelPreparation <$> o .: "payment" <*> o .: "generation" <*> o .: "reason")
    "refund"->fields ["operation","deposit"] >> (ControlPlan . operator . RefundDeposit <$> o .: "deposit")
    "resume"->fields ["operation"] >> pure (ControlPlan $ operator ResumeService)
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
runControl :: FilePath -> (forall a. Plan Operator a -> IO a) -> IO ()
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

callControl :: FilePath -> Value -> IO Value
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
