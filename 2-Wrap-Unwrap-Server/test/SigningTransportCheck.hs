{-# LANGUAGE DataKinds, GADTs, RankNTypes #-}
-- Actual WAI/Servant boundary; the closed evaluator returns public fixture data.
-- Public/generated test keys only; no chain RPC or funds are used here.
module SigningTransportCheck (checks) where
import Bridge.Critical (runWorkerLoop)
import Bridge.Identity (digest)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Bits (xor)
import Data.Word (Word8)
import Control.Monad (forM_)
import Bridge.SDKBuild (sdkSourceDirectory,sdkTargetDirectory)
import Data.Default (def)
import Data.PEM (pemParseBS,pemContent)
import Data.X509 (decodeSignedCertificate,CertificateChain(..))
import Data.X509.Validation (validateDefault,FailedReason(..))
import Data.X509.CertificateStore (makeCertificateStore)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Bridge.Signer
import qualified Bridge.Fence as Fence
import qualified Data.Text as T
import System.Posix.Process (forkProcess,getProcessStatus,exitImmediately,ProcessStatus(..))
import System.Exit (ExitCode(..))
import Bridge.Web (customerApplication,publicApplication)
import qualified Bridge.Wire as W
import qualified Bridge.Domain as D
import qualified Data.Map.Strict as M
import Bridge.Operation.Internal hiding (Result)
import Bridge.Critical ()
import Bridge.Error
import Bridge.Wire (SignedAttempt(..))
import Control.Exception (bracket,try,throwIO,AsyncException(..))
import Data.Aeson (encode,eitherDecode)
import Data.Either (isLeft)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.IORef
import Data.Text (Text)
import Network.HTTP.Types
import Network.Wai (defaultRequest,requestMethod,requestHeaders)
import Network.Wai.Test
import Servant.API (BasicAuthData(..))
import System.Directory (removeFile,createDirectory,removeDirectoryRecursive,renameFile,doesPathExist)
import System.FilePath ((</>),takeDirectory)
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode,createSymbolicLink)
import Test.QuickCheck

checks :: IO [Result]
checks=sequence
  [ check "release authentication binds exact artifacts, trusted key and install arguments" $ withMaxSuccess 5 $
      forAll (vectorOf 32 arbitrary) $ \seed->ioProperty $
        and <$> sequence [releaseAuthentication fault seed arch | fault<-[minBound..maxBound],arch<-["aarch64","x86_64"]]
  , check "TLS validator enforces permitted and excluded issuer names" $ once $ ioProperty $
      bracket temporary removeDirectoryRecursive $ \directory->do
        validate<-constrainedIssuer directory
        exactExcluded<-validate "blocked.allowed.example"
        let invalidName (InvalidName _)=True; invalidName _=False
        result<-quickCheckWithResult stdArgs{maxSuccess=20} $
          forAll (chooseInt (1,12) >>= \n->vectorOf n (elements ['a'..'z'])) $ \label->ioProperty $ do
            valid<-validate ("ok-"<>label<>".allowed.example")
            outside<-validate (label<>".other.example")
            excluded<-validate (label<>".blocked.allowed.example")
            pure (null valid && all (any invalidName) [outside,excluded,exactExcluded])
        pure (isSuccess result)
  , check "pinned Solana SDK passes its own codec and FFI contracts" $ once $ ioProperty $ do
      result<-timeout 120000000 (readProcessWithExitCode "cargo"
        ["test","--locked","--offline","--manifest-path",sdkSourceDirectory</>"Cargo.toml",
         "--target-dir",sdkTargetDirectory,"--lib","-j1"] "")
      pure $ case result of
        Just (ExitSuccess,_,_)->property True
        Just (code,_,err)->counterexample (show code<>"\n"<>take 4000 err) False
        Nothing->counterexample "SDK contract check exceeded 120 seconds" False
  , check "worker loop backs off after policy errors and propagates shutdown" $ once $ ioProperty $ do
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
  , check "public server serves only fixed assets with browser security headers" $ once $ ioProperty $
      bracket temporary removeDirectoryRecursive $ \directory->do
        createDirectory (directory</>"dist")
        mapM_ (\(file,bytes)->BS.writeFile (directory</>file) bytes)
          [("index.html","html-fixture"),("style.css","css-fixture"),("dist/wallet.js","js-fixture"),(".env","never-public")]
        let forbid :: forall a. Plan 'Customer a -> IO a
            forbid _=fail "static request reached DSL"
            get path=srequest $ SRequest ((setPath defaultRequest path)
              {requestHeaders=[("Sec-Fetch-Site","cross-site")]}) ""
        app<-publicApplication directory forbid
        replies<-runSession (mapM get ["/","/style.css","/wallet.js","/.env","/dist/wallet.js","/../.env"]) app
        removeFile (directory</>"style.css")
        missing<-refuses (publicApplication directory forbid)
        pure (map (statusCode.simpleStatus) replies==[200,200,200,404,404,404]
          && map simpleBody (take 3 replies)==["html-fixture","css-fixture","js-fixture"] && missing
          && all (\reply->lookup "Referrer-Policy" (simpleHeaders reply)==Just "no-referrer"
            && lookup "X-Content-Type-Options" (simpleHeaders reply)==Just "nosniff"
            && lookup "Content-Security-Policy" (simpleHeaders reply)/=Nothing) replies)
  , check "signer HTTP authenticates before evaluating and bounds all request bodies" $ once $ ioProperty $ do
      calls<-newIORef ([]::[(Text,Text,Int)])
      let token=BS.replicate 64 97
          credentials=BasicAuthData "worker" token
          result=SignedAttempt "fixture-id" "fixture-bytes" "fixture-proof" Nothing
          quantity=either (error . T.unpack) id (D.amount 2)
          unsigned=W.NativeDraft "fixture-psbt" (W.NativeTx "fixture-id" 2 0 [] []) [] quantity
          evaluate :: forall a. Request 'Signer 'Critical a -> IO a
          evaluate request=case resolve request of
            SigningDSL (CheckpointSigning (CheckpointCustody identity sequenceNo))->do
              modifyIORef' calls (<>[(identity,"checkpoint",fromIntegral sequenceNo)])
              pure $ CheckpointResult $ W.BackupReceipt identity sequenceNo (T.replicate 64 "a") (T.replicate 64 "b")
            SigningDSL (DraftSigning (DraftReplacement identity parent fee))->do
              modifyIORef' calls (<>[(identity,parent,fromIntegral $ D.units fee)])
              pure $ DraftResult unsigned
            SigningDSL (ReplacementSigning (SignReplacement identity decision))->do
              modifyIORef' calls (<>[(identity,"replacement",fromIntegral decision)])
              pure $ ReplacementResult result
            SigningDSL (PreparedSigning (SignPrepared identity identifier generation))->do
              modifyIORef' calls (<>[(identity,identifier,generation)])
              require (identifier/="refused") "signing_backup_required"
              pure $ PreparedResult result
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
        ,send "/broadcast" auth (body "payment")
        ,send "/sign-replacement" [] (encode ("deployment"::Text,7::Int))
        ,send "/sign-replacement" auth (encode ("deployment"::Text,7::Int))
        ,send "/sign-replacement" auth (body "wrong-shape")
        ,send "/draft-replacement" [] (encode ("deployment"::Text,"parent"::Text,quantity))
        ,send "/draft-replacement" auth (encode ("deployment"::Text,"parent"::Text,quantity))
        ,send "/draft-replacement" auth (body "numeric-fee-forbidden")
        ,send "/checkpoint-custody" [] (encode ("deployment"::Text,9::Int))
        ,send "/checkpoint-custody" auth (encode ("deployment"::Text,9::Int))
        ,send "/checkpoint-custody" auth (body "wrong-shape")]) app
      observed<-readIORef calls
      pure $ counterexample (show (map (statusCode . simpleStatus) responses,observed,map simpleBody responses)) $ map (statusCode . simpleStatus) responses==[401,403,200,409,400,413,403,404,401,200,400,401,200,400,401,200,400]
        && observed==[("deployment","payment",0),("deployment","refused",0),("deployment","replacement",7),("deployment","parent",2),("deployment","checkpoint",9)]
        && eitherDecode (simpleBody $ responses!!9)==Right (ReplacementResult result)
        && let outputs=map (simpleBody . (responses!!)) [2,9,12,15]
               decoders=[isLeft . (eitherDecode :: BL.ByteString -> Either String PreparedResult)
                        ,isLeft . (eitherDecode :: BL.ByteString -> Either String ReplacementResult)
                        ,isLeft . (eitherDecode :: BL.ByteString -> Either String DraftResult)
                        ,isLeft . (eitherDecode :: BL.ByteString -> Either String CheckpointResult)]
           in and [decode bytes == (i/=j) | (i,decode)<-zip [0::Int ..] decoders,(j,bytes)<-zip [0..] outputs]
        && eitherDecode (simpleBody $ responses!!12)==Right (DraftResult unsigned)
        && eitherDecode (simpleBody $ responses!!15)==Right (CheckpointResult $ W.BackupReceipt "deployment" 9 (T.replicate 64 "a") (T.replicate 64 "b"))
        && case drop 2 responses of
          accepted:_->eitherDecode (simpleBody accepted)==Right (PreparedResult result)
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

-- Real temporary certificate chain; no network, wallet or fixed expiry fixture.
constrainedIssuer :: FilePath -> IO (String -> IO [FailedReason])
constrainedIssuer dir = do
  setFileMode dir 0o700
  let file name=dir</>name
      openssl args=do
        result <- timeout 30000000 (readProcessWithExitCode "openssl" args "")
        case result of Just (ExitSuccess,_,_) -> pure (); _ -> fail "certificate fixture generation failed"
      key name=openssl ["genpkey","-algorithm","EC","-pkeyopt","ec_paramgen_curve:prime256v1","-out",file (name<>".key")]
      csr name subject=openssl ["req","-new","-key",file (name<>".key"),"-out",file (name<>".csr"),"-subj","/CN="<>subject]
      sign name issuer=openssl ["x509","-req","-in",file (name<>".csr"),"-CA",file (issuer<>".pem"),"-CAkey",file (issuer<>".key")
        ,"-CAcreateserial","-out",file (name<>".pem"),"-days","1","-extfile",file (name<>".ext")]
      certificate name=do
        bytes <- BS.readFile (file $ name<>".pem")
        pems <- either fail pure (pemParseBS bytes)
        case pems of [pem]->either fail pure (decodeSignedCertificate $ pemContent pem); _->fail "one fixture certificate required"
  key "root"
  openssl ["req","-x509","-new","-key",file "root.key","-out",file "root.pem","-days","1","-subj","/CN=Temporary fixture root"
    ,"-addext","basicConstraints=critical,CA:TRUE","-addext","keyUsage=critical,keyCertSign,cRLSign"]
  key "issuer"
  csr "issuer" "Temporary constrained issuer"
  writeFile (file "issuer.ext") "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nnameConstraints=critical,permitted;DNS:allowed.example,excluded;DNS:blocked.allowed.example\n"
  sign "issuer" "root"
  root <- certificate "root"
  issuer <- certificate "issuer"
  key "leaf"
  pure $ \name->do
    csr "leaf" name
    writeFile (file "leaf.ext") ("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:"<>name<>"\n")
    sign "leaf" "issuer"
    leaf <- certificate "leaf"
    validateDefault (makeCertificateStore [root]) def (name,BS.empty) (CertificateChain [leaf,issuer])

-- Exercise the release command itself on generated bytes. No installer is run.
data ReleaseFault = OriginalRelease | ChangedIndex | ChangedSignature | ChangedArtifact
  | WrongTrustKey | PublicSigningKey | UnexpectedInstallArguments
  | SingleArchitectureRelease | UnavailableArchitecture | NoArtifacts
  deriving (Eq,Show,Enum,Bounded)

releaseAuthentication :: ReleaseFault -> [Word8] -> String -> IO Bool
releaseAuthentication fault seed arch = bracket temporary removeDirectoryRecursive $ \dir->do
  let key=dir</>"key.pem"
      public=dir</>"public.pem"
      index=dir</>"release-index.json"
      signature=dir</>"release-index.sig"
      bytes=BS.pack seed
      privatePrefix=BS.pack [0x30,0x2e,0x02,0x01,0x00,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x04,0x22,0x04,0x20]
      publicPrefix=BS.pack [0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00]
      pem tag content="-----BEGIN "<>tag<>"-----\n"<>B64.encode content<>"\n-----END "<>tag<>"-----\n"
      publicBytes inputBytes=case Ed.secretKey inputBytes of
        CryptoPassed secret->BA.convert (Ed.toPublic secret)
        CryptoFailed _->error "generated seed must have 32 bytes"
      call args=do
        (code,_,_) <- readProcessWithExitCode (takeDirectory sdkSourceDirectory</>"scripts/release-auth") args ""
        pure code
  BS.writeFile key (pem "PRIVATE KEY" (privatePrefix<>bytes))
  setFileMode key (if fault==PublicSigningKey then 0o644 else 0o600)
  BS.writeFile public (pem "PUBLIC KEY" (publicPrefix<>publicBytes bytes))
  let architectures=case fault of
        SingleArchitectureRelease->[arch]
        UnavailableArchitecture->filter (/=arch) ["aarch64","x86_64"]
        NoArtifacts->[]
        _->["aarch64","x86_64"]
  forM_ architectures $ \cpu->do
    let name="ecx-bridge-ubuntu-24.04-"<>cpu<>".run"
    BS.writeFile (dir</>name) bytes
    writeFile (dir</>(name<>".sha256")) (T.unpack (digest bytes)<>"  "<>name<>"\n")
  signed <- call ["sign",key,dir]
  if fault `elem` [PublicSigningKey,NoArtifacts] then do
    indexExists <- doesPathExist index
    signatureExists <- doesPathExist signature
    pure (signed/=ExitSuccess && not indexExists && not signatureExists)
  else do
    require (signed==ExitSuccess) "release_fixture_signing_failed"
    case fault of
      ChangedIndex->BS.appendFile index " "
      ChangedSignature->BS.readFile signature >>= \original->BS.writeFile signature
        (BS.cons (BS.head original `xor` 1) (BS.tail original))
      ChangedArtifact->BS.appendFile (dir</>("ecx-bridge-ubuntu-24.04-"<>arch<>".run")) "changed"
      WrongTrustKey->BS.writeFile public (pem "PUBLIC KEY" (publicPrefix<>
        publicBytes (BS.cons (BS.head bytes `xor` 1) (BS.tail bytes))))
      _->pure ()
    verified <- call (["verify",public,dir,arch]<>
      if fault==UnexpectedInstallArguments then ["--","--test-worker"] else [])
    pure ((verified==ExitSuccess)==(fault `elem` [OriginalRelease,SingleArchitectureRelease]))

 where
  temporary=do
    (path,handle)<-openTempFile "/tmp" "ecx-release-contract"
    hClose handle
    removeFile path
    createDirectory path
    setFileMode path 0o700
    pure path
