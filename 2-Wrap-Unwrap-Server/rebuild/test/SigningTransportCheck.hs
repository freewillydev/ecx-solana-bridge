{-# LANGUAGE DataKinds, GADTs, RankNTypes #-}
-- Actual WAI/Servant boundary; the closed evaluator returns public fixture data.
-- No signing keys, chain RPC, native listener or funds are used here.
module SigningTransportCheck (checks) where
import Bridge.SigningTransport
import Bridge.Operation.Internal
import Bridge.Error
import Bridge.Wire (SignedAttempt(..))
import Control.Exception (bracket,try)
import Data.Aeson (encode,eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.IORef
import Data.Text (Text)
import Network.HTTP.Types
import Network.Wai (defaultRequest,requestMethod,requestHeaders)
import Network.Wai.Test
import Servant.API (BasicAuthData(..))
import System.Directory (removeFile,createDirectory,removeDirectoryRecursive)
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode,createSymbolicLink)
import Test.QuickCheck

checks :: IO [Result]
checks=sequence
  [ check "signer HTTP authenticates before evaluating and bounds all request bodies" $ once $ ioProperty $ do
      calls<-newIORef ([]::[(Text,Text,Int)])
      let token=BS.replicate 64 97
          credentials=BasicAuthData "worker" token
          result=SignedAttempt "fixture-id" "fixture-bytes" "fixture-proof" Nothing
          evaluate :: forall a. Request 'Signer 'Critical a -> IO a
          evaluate request=case resolve request of
            SigningDSL (SignPrepared identity identifier generation)->do
              modifyIORef' calls (<>[(identity,identifier,generation)])
              require (identifier/="refused") "signing_backup_required"
              pure result
          auth=[("Authorization","Basic "<>B64.encode ("worker:"<>token))]
          body identifier=encode ("deployment"::Text,identifier::Text,0::Int)
          send path headers bytes=srequest $ SRequest
            ((setPath defaultRequest path) {requestMethod="POST",requestHeaders=("Content-Type","application/json"):headers}) bytes
      app<-signingApplication credentials evaluate
      responses<-runSession (sequence
        [send "/sign-preparation" [] (body "payment")
        ,send "/sign-preparation" [("Authorization","Basic "<>B64.encode "worker:wrong")] (body "payment")
        ,send "/sign-preparation" auth (body "payment")
        ,send "/sign-preparation" auth (body "refused")
        ,send "/sign-preparation" auth "not-json"
        ,send "/sign-preparation" auth (encode $ replicate 4097 'x')
        ,send "/sign-preparation" (("Sec-Fetch-Site","cross-site"):auth) (body "payment")
        ,send "/broadcast" auth (body "payment")]) app
      observed<-readIORef calls
      pure $ counterexample (show (map (statusCode . simpleStatus) responses,observed,map simpleBody responses)) $ map (statusCode . simpleStatus) responses==[401,403,200,409,400,413,403,404]
        && observed==[("deployment","payment",0),("deployment","refused",0)]
        && case drop 2 responses of
          accepted:_->eitherDecode (simpleBody accepted)==Right result
            && lookup "Cache-Control" (simpleHeaders accepted)==Just "no-store"
          _->False
  , check "signer credentials reject unsafe modes symlinks parents and token formats" $ once $ ioProperty $
      bracket temporary removeDirectoryRecursive $ \directory->do
        let path=directory</>"auth"; endpoint=SigningEndpoint 9443 path
            token=BS.replicate 64 97
        BS.writeFile path token
        setFileMode path 0o600
        valid<-signerCredentials endpoint
        setFileMode path 0o640
        shared<-signerCredentials endpoint
        setFileMode path 0o644
        public<-refuses (signerCredentials endpoint)
        setFileMode path 0o600
        setFileMode directory 0o770
        writableParent<-refuses (signerCredentials endpoint)
        setFileMode directory 0o700
        BS.writeFile path (token<>"extra")
        malformed<-refuses (signerCredentials endpoint)
        BS.writeFile path token
        createSymbolicLink path (directory</>"link")
        linked<-refuses (signerCredentials endpoint {signerAuthFile=directory</>"link"})
        invalidPort<-refuses (signerCredentials endpoint {signerPort=0})
        pure (basicAuthPassword valid==token && basicAuthPassword shared==token
          && public && writableParent && malformed && linked && invalidPort)
  ]
 where
  check description p=putStrLn description >> quickCheckWithResult stdArgs p
  temporary=do
    (path,handle)<-openTempFile "/tmp" "ecx-signer-contract"
    hClose handle
    removeFile path
    createDirectory path
    setFileMode path 0o700
    pure path
  refuses action=do
    outcome<-try (action >> pure ())
    pure $ case outcome of Left (BridgeError _)->True; Right _->False
