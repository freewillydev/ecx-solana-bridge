{-# LANGUAGE DataKinds, GADTs, RankNTypes #-}
-- Actual WAI/Servant boundary; the closed evaluator returns public fixture data.
-- Only a public zero-seed key vector; no chain RPC or funds are used here.
module SigningTransportCheck (checks) where
import Bridge.Critical (runWorkerLoop)
import System.Timeout (timeout)
import Bridge.Signer (verifySigningKey)
import Bridge.SigningTransport
import qualified Bridge.Fence as Fence
import qualified Data.Text as T
import System.Posix.Process (forkProcess,getProcessStatus,exitImmediately,ProcessStatus(..))
import System.Exit (ExitCode(..))
import Bridge.Web (customerApplication)
import qualified Bridge.Wire as W
import qualified Bridge.Domain as D
import qualified Data.Map.Strict as M
import Bridge.Operation.Internal
import Bridge.Error
import Bridge.Wire (SignedAttempt(..))
import Control.Exception (bracket,try,throwIO,AsyncException(..))
import Data.Aeson (encode,eitherDecode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.IORef
import Data.Text (Text)
import Network.HTTP.Types
import Network.Wai (defaultRequest,requestMethod,requestHeaders)
import Network.Wai.Test
import Servant.API (BasicAuthData(..))
import System.Directory (removeFile,createDirectory,removeDirectoryRecursive,renameFile)
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode,createSymbolicLink)
import Test.QuickCheck

checks :: IO [Result]
checks=sequence
  [ check "worker loop backs off after policy errors and propagates shutdown" $ once $ ioProperty $ do
      calls<-newIORef (0::Int)
      let refuse :: forall a. Request 'Worker 'Critical a -> IO a
          refuse request=case resolve request of
            WorkerDSL RunWorkerCycle->modifyIORef' calls (+1) >> reject "offline_loop_contract"
            _->fail "loop dispatched unexpected operation"
          stop :: forall a. Request 'Worker 'Critical a -> IO a
          stop _=throwIO ThreadKilled
      waited<-timeout 100000 (runWorkerLoop refuse)
      count<-readIORef calls
      stopped<-try (runWorkerLoop stop) :: IO (Either AsyncException ())
      pure (waited==Nothing && count==1 && stopped==Left ThreadKilled)
  , check "host fence persists monotonic ownership and refuses competing or retired workers" $ once $ ioProperty $
      bracket temporary removeDirectoryRecursive $ \directory->do
        let identity=T.replicate 64 "a"; file=directory</>"sequence.json"
        missing<-refuses (Fence.withFence directory identity $ const $ pure ())
        Fence.initializeFence directory identity 7
        original<-BS.readFile file
        reset<-refuses (Fence.initializeFence directory identity 0)
        before<-BS.readFile file
        locked<-Fence.withFence directory identity $ \advance->do
          sameProcess<-refuses (Fence.withFence directory identity $ const $ pure ())
          child<-forkProcess $ do
            result<-try (Fence.withFence directory identity $ const $ pure ())
            exitImmediately $ case result of Left (BridgeError "worker_fence_locked")->ExitSuccess; _->ExitFailure 1
          childResult<-getProcessStatus True False child
          advance 8
          persisted<-BS.readFile file
          stale<-refuses (advance 7)
          pure (sameProcess && childResult==Just (Exited ExitSuccess) && persisted/=original && stale)
        latest<-BS.readFile file
        Fence.withFence directory identity ($ 8)
        unchanged<-BS.readFile file
        wrong<-refuses (Fence.withFence directory (T.replicate 64 "b") $ const $ pure ())
        setFileMode file 0o644
        public<-refuses (Fence.withFence directory identity $ const $ pure ())
        setFileMode file 0o600
        renameFile file (directory</>"saved.json")
        createSymbolicLink (directory</>"saved.json") file
        linked<-refuses (Fence.withFence directory identity $ const $ pure ())
        removeFile file
        renameFile (directory</>"saved.json") file
        setFileMode directory 0o770
        writable<-refuses (Fence.withFence directory identity $ const $ pure ())
        setFileMode directory 0o700
        Fence.retireFence directory identity 8
        retired<-refuses (Fence.withFence directory identity $ const $ pure ())
        Fence.retireFence directory identity 8
        reactivate<-refuses (Fence.initializeFence directory identity 8)
        pure (missing && reset && before==original && locked && unchanged==latest && wrong && public && linked && writable && retired && reactivate)
  , check "customer Servant routes resolve all four existential requests and reject invalid bodies" $ once $ ioProperty $ do
      calls<-newIORef ([]::[Text])
      let amount=either (error . show) id (D.amount 100)
          quote=either (error . show) id (D.quote amount)
          request=W.OrderRequest D.NativeToWrapped amount "recipient" "refund" Nothing "key"
          order=W.OrderView "order" request quote "AwaitingDeposit" 200 (Just "instruction") Nothing (W.PolicySnapshot 2 "finalized" "deployment")
          config=W.PublicConfiguration W.L2LSignetDevnet "devnet" (W.InterfaceConfig Nothing Nothing Nothing Nothing Nothing)
            "deployment" "mint" "owner" 8 amount amount M.empty False False (W.Availability False "paused")
          instruction=W.PaymentInstruction "solana:fixture" "reference" "mint" amount "verified_source_owner"
          evaluate :: forall a. Plan 'Customer a -> IO a
          evaluate (SafePlan value)=case resolve value of
            ReadCustomer PublicConfig->modifyIORef' calls (<>["config"]) >> pure config
            ReadCustomer (OrderStatus header identifier)->do
              require (header=="Bearer fixture" && identifier=="order") "order_not_found"
              modifyIORef' calls (<>["read"]) >> pure order
            ReadCustomer (PaymentInstructions _ _)->modifyIORef' calls (<>["instructions"]) >> pure instruction
          evaluate (CriticalPlan value)=case resolve value of
            WriteCustomer (CreateOrder _ input)->require (input==request) "invalid_request" >> modifyIORef' calls (<>["create"]) >> pure order
          send method path headers body=srequest $ SRequest
            ((setPath defaultRequest path) {requestMethod=method,requestHeaders=headers}) body
          auth=[("Authorization","Bearer fixture"),("Content-Type","application/json")]
      app<-customerApplication evaluate
      responses<-runSession (sequence
        [send "GET" "/api/v1/config" [] ""
        ,send "POST" "/api/v1/orders" auth (encode request)
        ,send "GET" "/api/v1/orders/order" auth ""
        ,send "POST" "/api/v1/orders/order/transaction" auth ""
        ,send "GET" "/api/v1/orders/order" [] ""
        ,send "GET" "/api/v1/orders/missing" auth ""
        ,send "POST" "/api/v1/orders" auth "not-json"
        ,send "POST" "/api/v1/orders" auth (encode $ replicate 4097 'x')
        ,send "POST" "/api/v1/orders" (("Sec-Fetch-Site","cross-site"):auth) (encode request)
        ,send "POST" "/sign-preparation" auth "{}"
        ,send "GET" "/api/v1/audit" auth ""] ) app
      seen<-readIORef calls
      pure (map (statusCode . simpleStatus) responses==[200,200,200,200,400,409,400,413,403,404,404]
        && seen==["config","create","read","instructions"]
        && all ((==Just "no-store") . lookup "Cache-Control" . simpleHeaders) responses)
  , check "signer HTTP authenticates before evaluating and bounds all request bodies" $ once $ ioProperty $ do
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
  , check "signer startup binds protected keypair seed and public half to the custody owner" $ once $ ioProperty $
      bracket temporary removeDirectoryRecursive $ \directory->do
        let file=directory</>"key.json"; owner="4zvwRjXUKGfvwnParsHAS3HuSVzV5cA4McphgmoCtajS"
            key=replicate 32 (0::Int)<>[59, 106, 39, 188, 206, 182, 164, 45, 98, 163, 168, 208, 42, 111, 13, 115, 101, 50, 21, 119, 29, 226, 67, 166, 58, 192, 72, 161, 139, 89, 218, 41]
        BL.writeFile file (encode key)
        setFileMode file 0o600
        verifySigningKey owner file
        wrongOwner<-refuses (verifySigningKey (T.replicate 32 "1") file)
        BL.writeFile file (encode (1:drop 1 key))
        wrongSeed<-refuses (verifySigningKey owner file)
        BL.writeFile file (encode (take 32 key<>replicate 32 (0::Int)))
        wrongPublic<-refuses (verifySigningKey owner file)
        BL.writeFile file (encode (replicate 64 (256::Int)))
        outOfRange<-refuses (verifySigningKey owner file)
        BL.writeFile file (encode (take 32 key))
        short<-refuses (verifySigningKey owner file)
        BS.writeFile file (BS.replicate 4097 32)
        oversized<-refuses (verifySigningKey owner file)
        BL.writeFile file (encode key)
        setFileMode file 0o640
        sharedKey<-refuses (verifySigningKey owner file)
        setFileMode file 0o600
        createSymbolicLink file (directory</>"key-link")
        linkedKey<-refuses (verifySigningKey owner (directory</>"key-link"))
        pure (wrongOwner && wrongSeed && wrongPublic && outOfRange && short && oversized && sharedKey && linkedKey)
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
