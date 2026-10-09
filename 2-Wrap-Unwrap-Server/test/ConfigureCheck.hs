module ConfigureCheck (contract,walletProperty) where
import qualified Bridge.Config as C
import qualified NodeSetup
import qualified Bootstrap
import System.Environment (getEnv,setEnv)
import System.Info (os)
import System.Timeout (timeout)
import Control.Exception (evaluate,finally)
import qualified Data.ByteString.Char8 as B8
import Crypto.MAC.HMAC (hmac,HMAC)
import Crypto.Hash (SHA256)
import Bridge.AdminKey (savePrivate)
import Bridge.Wallet (mnemonic,walletKey,nativeDescriptors)
import Bridge.NativeKey (deriveChild)
import qualified Bridge.Native as N
import Bridge.Wire (Profile(..))
import Bridge.Error (BridgeError(..))
import qualified Data.Aeson.KeyMap as KM
import Data.IORef
import Control.Monad (unless,forM)
import qualified Data.ByteArray.Encoding as Hex
import Data.Word (Word8)
import Test.QuickCheck hiding ((.&.))
import Bridge.SolanaMessage (base58)
import Control.Exception (bracket,try)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import Data.Aeson (encode,eitherDecodeStrict',Value(..),object,(.=),toJSON)
import qualified Data.Map.Strict as M
import Data.List (sort,isInfixOf)
import Data.Bits ((.&.),shiftR)
import System.Directory
import System.FilePath ((</>))
import System.IO (openTempFile,hClose,hPutStrLn,hFlush,hGetChar,hGetContents)
import System.Posix.Files (setFileMode,getFileStatus,fileMode)
import System.Process
import System.Exit (ExitCode(..))

-- Real executable, disposable private keys, no network/database/service changes.
contract :: IO Bool
contract=bracket temporary removeDirectoryRecursive $ \directory->do
  Just executable<-findExecutable "ecx-bridge"
  let seed=B.replicate 32 7
  secret<-case Ed.secretKey seed of CryptoPassed key->pure key; _->fail "test key"
  let public=BA.convert(Ed.toPublic secret)::B.ByteString
      owner=T.unpack(base58 public)
      history=T.unpack(base58 $ B.replicate 64 1)
      run input=readCreateProcessWithExitCode ((proc executable ["configure","--advanced"]) {cwd=Just directory}) input
      key=directory</>"key.json"; worker=directory</>"worker.auth"; signer=directory</>"signer.auth"
      invalidUnlock=directory</>"invalid-unlock"; unlock=directory</>"unlock"
  savePrivate key (L.toStrict $ encode $ B.unpack(seed<>public))
  savePrivate worker "worker:password";savePrivate signer "signer:password"
  savePrivate invalidUnlock (B.singleton 255);savePrivate unlock " exact unlock secret "
  -- Field order is explicitly sorted, and booleans/numbers retain their JSON types.
  let fields=["false","1200",owner,owner,"test-deployment","100000","10000","1000"
        ,"invalid-number","4","2100000","10000000","10000","10000",owner
        ,"00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
        ,"16000","1","http://127.0.0.1:29432","test-wallet","300","8080","8081"
        ,history,history,"https://api.devnet.solana.com","-"]
      answers=["","L2LSignetDevnet","import"]<>fields<>["no","yes","release","installer","release.pem","candidate",key,"existing",worker,signer,"-","-","-","-","-","-","no"]
  (code,_,_)<-run (unlines answers)
  if code/=ExitSuccess then pure False else do
    let out=directory</>".ecx-bridge"
    config<-C.loadConfig(out</>"worker.json")
    other<-C.loadConfig(out</>"signer.json")
    modes<-mapM (fmap ((.&. 0o777) . fileMode) . getFileStatus . (out</>)) ["worker.json","signer.json","setup.json","sources.json"]
    entries<-listDirectory out
    sources<-either fail pure . (eitherDecodeStrict' :: B.ByteString -> Either String (M.Map String FilePath)) =<< B.readFile(out</>"sources.json")
    originalKey<-B.readFile key
    originalWorker<-B.readFile worker
    originalSigner<-B.readFile signer
    before<-B.readFile(out</>"worker.json")
    (again,_,_)<-run "\n"
    after<-B.readFile(out</>"worker.json")
    (cancelled,_,_)<-run ((directory</>"cancelled")<>"\n")
    partial<-doesDirectoryExist(directory</>"cancelled")
    let local=directory</>"source-setup"
        sourceAnswers=[local,"L2LSignetDevnet","import"]<>fields<>["no","yes","invalid-mode","source",directory,worker,key,"existing",worker,signer,invalidUnlock,unlock,"-","-","-","-","-","no"]
    (sourceCode,sourceOutput,_)<-run (unlines sourceAnswers)
    sourceSetup<-either fail pure . (eitherDecodeStrict' :: B.ByteString -> Either String Value) =<< B.readFile(local</>"setup.json")
    sourceWorker<-C.loadConfig(local</>"worker.json")
    sourceSigner<-C.loadConfig(local</>"signer.json")
    let phrase=unwords (replicate 11 "abandon"<>["about"])
        restored=directory</>"restored-setup"
        wallet=directory</>"recovered-wallet"
        phraseFile=directory</>"recovery.txt"
    savePrivate phraseFile (B.pack $ map (fromIntegral . fromEnum) phrase)
    (restoredCode,restoredOutput,_)<-run $ unlines $
      [restored,"L2LSignetDevnet","restore",phraseFile,wallet]
      <>take 3 fields<>drop 4 fields<>["no","yes","source",directory,worker,"existing",worker,signer,"-","-","-","-","-","-","no"]
    restoredConfig<-C.loadConfig(restored</>"signer.json")
    recovered<-B.readFile(wallet</>"solana.keypair.json")
    recoveredPhrase<-B.readFile(wallet</>"solana-recovery.txt")
    secretModes<-mapM (fmap ((.&. 0o777) . fileMode) . getFileStatus . (wallet</>)) ["solana-recovery.txt","solana.keypair.json"]
    (pipeCode,_,pipeOutput)<-run $ unlines [directory</>"pipe","L2LSignetDevnet","generate"]
    let interrupted=directory</>"interrupted-setup"
        retained=directory</>"retained-wallet"
    (interruptedCode,_,_)<-run $ unlines [interrupted,"L2LSignetDevnet","restore",phraseFile,retained]
    retainedKey<-B.readFile(retained</>"solana.keypair.json")
    settingsRemain<-doesDirectoryExist interrupted
    nativeChecked<-nativeSeedContract directory
    simplifiedChecked<-simpleContract directory executable
    expectedKey<-either (const $ fail "fixture mnemonic") pure (walletKey phrase)
    let expectedSetup=object ["existing" .= False,"method" .= ("source"::String),"sourceRoot" .= directory,"restic" .= worker]
    pure(simplifiedChecked && nativeChecked && C.fingerprint config==C.fingerprint other && C.nativeCookie config/=C.nativeCookie other
      && sort entries==["interface.json","setup.json","signer.json","sources.json","worker.json"]
      && sources==M.fromList [("solana.keypair.json",key),("native-worker.auth",worker),("native-signer.auth",signer)]
      && originalKey==L.toStrict(encode $ B.unpack(seed<>public)) && originalWorker=="worker:password" && originalSigner=="signer:password"
      && sourceCode==ExitSuccess && sourceSetup==expectedSetup && not ("PUBLIC key file" `isInfixOf` sourceOutput) && not ("signed installer directory" `isInfixOf` sourceOutput)
      && C.nativeUnlockFile sourceWorker==Nothing && C.nativeUnlockFile sourceSigner==Just unlock
      && "invalid_native_unlock_file" `isInfixOf` sourceOutput && not (" exact unlock secret " `isInfixOf` sourceOutput)
      && restoredCode==ExitSuccess && C.custodyOwner restoredConfig==base58(B.drop 32 expectedKey)
      && recovered==L.toStrict(encode $ B.unpack expectedKey) && recoveredPhrase==B.pack(map (fromIntegral . fromEnum) (phrase<>"\n"))
      && not (phrase `isInfixOf` restoredOutput) && all (==0o600) secretModes
      && pipeCode/=ExitSuccess && "wallet_generation_requires_interactive_terminal" `isInfixOf` pipeOutput
      && interruptedCode/=ExitSuccess && not settingsRemain && retainedKey==recovered
      && all(==0o600)modes && before==after && again/=ExitSuccess && cancelled/=ExitSuccess && not partial)
 where
  temporary=do
    parent<-getTemporaryDirectory
    (path,h)<-openTempFile parent "ecx-configure-test"
    hClose h;removeFile path;createDirectory path;setFileMode path 0o700
    pure path

-- Published BIP-39 entropy/phrase vectors; SLIP-0010 Solana seeds independently
-- cross-checked with Python hashlib/hmac (empty passphrase, m/44'/501'/0'/0').
walletProperty :: Property
walletProperty=forAll (vectorOf 16 arbitrary) $ \(entropy::[Word8])->
  conjoin [case mnemonic (B.pack entropy) >>= walletKey of
             Right key->property (B.length key==64)
             Left _->property False
          ,ioProperty (nativeScalarContract entropy)
          ,conjoin [counterexample "BIP39/SLIP10 known vector mismatch" $
             mnemonic (B.replicate 16 byte)==Right phrase &&
             fmap (Hex.convertToBase Hex.Base16 . B.take 32) (walletKey phrase)==Right expected
            | (byte,phrase,expected)<-vectors]
          ,ioProperty $ do
             actual<-nativeDescriptors False (unwords $ replicate 11 "abandon"<>["about"])
             pure (actual==Right
              ["wpkh([73c5da0a/84h/0h/0h]xprv9ybY78BftS5UGANki6oSifuQEjkpyAC8ZmBvBNTshQnCBcxnefjHS7buPMkkqhcRzmoGZ5bokx7GuyDAiktd5HemohAU4wV1ZPMDRmLpBMm/0/*)","wpkh([73c5da0a/84h/0h/0h]xprv9ybY78BftS5UGANki6oSifuQEjkpyAC8ZmBvBNTshQnCBcxnefjHS7buPMkkqhcRzmoGZ5bokx7GuyDAiktd5HemohAU4wV1ZPMDRmLpBMm/1/*)"])
          ,property (case walletKey (unwords $ replicate 12 "abandon") of Left _->True; _->False)
          ,property (case mnemonic (B.replicate 15 0) of Left _->True; _->False)]
 where
  vectors :: [(Word8,String,B.ByteString)]
  vectors=
    [(0,unwords (replicate 11 "abandon"<>["about"]),"37df573b3ac4ad5b522e064e25b63ea16bcbe79d449e81a0268d1047948bb445")
    ,(127,"legal winner thank year wave sausage worth useful legal winner thank yellow","6987bdb06aa8a243a3019f41489ffa8e609c953a885a748d1849a8df760aa479")
    ,(128,"letter advice cage absurd amount doctor acoustic avoid letter advice cage above","8ab69a9cd074a86f71fea02a807dac8cc5d498f292844417640946f497117746")
    ,(255,unwords (replicate 11 "zoo"<>["wrong"]),"0b69a88e057a6ff3299f4adac3b04b0b24df114b3f3c21c5cefe0b89664b3bcf")]

-- Integer arithmetic is an independent TEST oracle, never production key math.
nativeScalarContract :: [Word8] -> IO Bool
nativeScalarContract entropy=do
  let order=0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141 :: Integer
      bytes :: Integer -> B.ByteString
      bytes value=B.pack [fromIntegral (value `shiftR` offset) | offset<-[248,240..0]]
      randomScalar=1+B.foldl' (\n b->256*n+fromIntegral b) 0 (B.pack entropy)
      generator="0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" :: B.ByteString
      cases=[(1,0,Just 1),(order-1,0,Just (order-1)),(0,1,Nothing),(order,0,Nothing)
            ,(1,order,Nothing),(1,order-1,Nothing),(order-1,2,Just 1)
            ,(randomScalar,order-randomScalar+1,Just 1)]
  results<-forM cases $ \(parent,tweak,expected)->do
    result<-deriveChild (bytes parent) (bytes tweak)
    pure $ fmap fst result==fmap bytes expected && case result of
      Just (_,public)->B.length public==33 && (parent/=1 || Hex.convertToBase Hex.Base16 public==generator)
      Nothing->True
  short<-deriveChild (B.replicate 31 0) (bytes 0)
  long<-deriveChild (bytes 1) (B.replicate 33 0)
  pure (and results && short==Nothing && long==Nothing)

-- Closed native setup protocol: real-node descriptor compatibility is checked
-- separately; these fixtures exercise interruption/refusal without chain effects.
nativeSeedContract :: FilePath -> IO Bool
nativeSeedContract directory=do
  let phrase=unwords (replicate 11 "abandon"<>["about"])
      seedFile=directory</>"native-seed.txt"
      settings=N.NativeSettings L2LSignetDevnet "http://127.0.0.1:29432" (directory</>"worker.auth") "seed-test"
        16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
      public=["public-receive#checksum","public-change#checksum"]::[T.Text]
  private<-nativeDescriptors True phrase >>= either (const $ fail "fixture native mnemonic") pure
  savePrivate seedFile (B.pack $ map (fromIntegral . fromEnum) phrase)
  exists<-newIORef False;imports<-newIORef (0::Int);creates<-newIORef (0::Int)
  broken<-newIORef False;failImport<-newIORef False;restoring<-newIORef False
  let call _ method args=do
        unless (not $ phrase `isInfixOf` show (encode args)) (fail "phrase leaked into RPC")
        case (method,args) of
          ("getblockchaininfo",[])->pure $ object ["chain" .= ("signet"::T.Text),"initialblockdownload" .= False,"blocks" .= (17000::Int),"pruned" .= False,"signet_challenge" .= N.signetChallenge]
          ("getblockhash",_)->pure $ String $ N.nativeCheckpointHash settings
          ("getconnectioncount",[])->pure $ Number 1
          ("getdescriptorinfo",[String descriptor])->case lookup descriptor (zip private public) of
            Just pub->pure $ object ["descriptor" .= pub,"checksum" .= ("checksum"::T.Text)]
            Nothing->fail "unexpected descriptor"
          ("deriveaddresses",_)->pure $ toJSON (["fixture-funding-address"]::[T.Text])
          ("listwalletdir",[])->do
            present<-readIORef exists
            pure $ object ["wallets" .= [object ["name" .= N.nativeWallet settings] | present]]
          ("createwallet",[String name,Bool False,Bool True,String "",Bool False,Bool True,Bool True,Bool False])->do
            modifyIORef' creates (+1);writeIORef exists True
            pure $ object ["name" .= name]
          ("importdescriptors",[requests])->do
            recovering<-readIORef restoring
            let expected=toJSON [object ["desc" .= (descriptor<>"#checksum"),"active" .= True,"internal" .= internal
                    ,"range" .= ([0,999]::[Int]),"next_index" .= (0::Int),"timestamp" .= (if recovering then Number 0 else String "now")]
                    | (descriptor,internal)<-zip private [False,True]]
            unless (requests==expected) (fail "incorrect import contract")
            modifyIORef' imports (+1);bad<-readIORef failImport
            pure $ toJSON [object ["success" .= not bad],object ["success" .= not bad]]
          ("getwalletinfo",[])->pure $ object ["walletname" .= N.nativeWallet settings,"descriptors" .= True,"scanning" .= False
            ,"private_keys_enabled" .= True,"external_signer" .= False]
          ("listdescriptors",[Bool False])->do
            bad<-readIORef broken
            pure $ object ["descriptors" .= [object ["desc" .= (if bad then "changed" else descriptor),"active" .= True,"internal" .= internal]
                  | (descriptor,internal)<-zip public [False,True]]]
          ("getnewaddress",[String "bridge-initial-funding",String "bech32"])->pure $ String "fixture-funding-address"
          _->fail "unexpected native initialization RPC"
      run=N.evalNativeRecoveryWith call settings
  address<-run (N.InitializeNativeWallet seedFile Nothing False 999)
  repeated<-run (N.InitializeNativeWallet seedFile Nothing False 999)
  firstImports<-readIORef imports;firstCreates<-readIORef creates
  writeIORef broken True
  changed<-try (run $ N.InitializeNativeWallet seedFile Nothing False 999) :: IO (Either BridgeError T.Text)
  writeIORef broken False;writeIORef exists False;writeIORef failImport True;writeIORef restoring True
  let failedSeed=directory</>"failed-native-seed.txt"
  savePrivate failedSeed (B.pack $ map (fromIntegral . fromEnum) phrase)
  failed<-try (run $ N.InitializeNativeWallet failedSeed Nothing True 999) :: IO (Either BridgeError T.Text)
  checkpoint<-doesFileExist (failedSeed<>".initialized.json")
  retried<-try (run $ N.InitializeNativeWallet failedSeed Nothing True 999) :: IO (Either BridgeError T.Text)
  finalImports<-readIORef imports;finalCreates<-readIORef creates
  let refused code result=case result of Left (BridgeError actual)->actual==code; _->False
  pure (address==repeated && firstImports==1 && firstCreates==1 && finalImports==2 && finalCreates==2 && not checkpoint
    && refused "native_seed_wallet_mismatch" changed && refused "native_seed_import_or_rescan_failed" failed
    && refused "native_seed_wallet_exists_requires_review" retried)

-- Real wizard on a disposable terminal; script writes to /dev/null, never a
-- transcript. Recovery words are read only in memory and never printed by tests.
simpleContract :: FilePath -> FilePath -> IO Bool
simpleContract parent executable=do
  let directory=parent</>"simple"
      commands=directory</>"commands"
      node=directory</>"bitcoin.conf"
  createDirectory directory;setFileMode directory 0o700
  createDirectory commands;setFileMode commands 0o700
  savePrivate node "server=1\n"
  savePrivate (commands</>"restic") "#!/bin/sh\nexit 0\n"
  savePrivate (commands</>"systemctl") "#!/bin/sh\ncase \"$1\" in cat|restart) exit 0;; *) exit 1;; esac\n"
  mapM_ (\name->setFileMode (commands</>name) 0o700) ["restic","systemctl"]
  old<-getEnv "PATH"
  let run=do
        setEnv "PATH" (commands<> ":"<>old)
        let args=if os=="darwin" then ["-q","/dev/null",executable,"configure"]
                 else ["-q","-c","'"<>concatMap (\c->if c=='\'' then "'\\''" else [c]) executable<>"' configure","/dev/null"]
        result<-timeout (45*1000000) $ withCreateProcess ((proc "script" args)
          {cwd=Just directory,std_in=CreatePipe,std_out=CreatePipe,std_err=NoStream,create_group=True}) $ \input output _ process->do
            let Just writer=input; Just reader=output
                await needle=go "" (0::Int)
                 where
                  go found count=do
                    unless (count<65536) (fail "wizard_output_bound")
                    char<-hGetChar reader
                    let next=drop (max 0 (length found+1-length needle)) (found<>[char])
                    if next==needle then pure () else go next (count+1)
                answer label value=await label >> await ": " >> hPutStrLn writer value >> hFlush writer
                ack=await "Type saved once you have backed up the phrase:" >> hPutStrLn writer "saved" >> hFlush writer
            answer "Solana Mainnet RPC URL" "https://primary.example.invalid/"
            answer "Independent Mainnet RPC URL" "https://verifier.example.invalid/"
            answer "NEW HTTPS restic repository URL" "rest:https://backup.example.invalid/repository"
            answer "Public HTTPS origin" "-"
            ack;ack
            -- EOF can make script terminate the child before setup saves.
            await "Saved private setup"
            hClose writer
            remaining<-hGetContents reader
            _<-evaluate(length remaining)
            code<-waitForProcess process
            pure(code==ExitSuccess)
        case result of
          Just True->verify directory node
          _->pure False
  run `finally` setEnv "PATH" old
 where
  verify directory node=do
    let setup=directory</>".ecx-bridge"
    c<-Bootstrap.setupConfig setup
    runtimeExists<-doesFileExist(setup</>"worker.json")
    rejected<-try(C.loadConfig(setup</>"bootstrap.json")) :: IO(Either BridgeError C.Config)
    phraseA<-B8.strip <$> B.readFile(directory</>".ecx-bridge-solana-wallet/solana-recovery.txt")
    phraseB<-B8.strip <$> B.readFile(directory</>".ecx-bridge-ecx-wallet/ecx-recovery.txt")
    solana<-either (const $ fail "generated_phrase_invalid") pure (walletKey $ B8.unpack phraseA)
    rules<-B8.lines <$> B.readFile(setup</>"native-rpc.conf")
    valid<-forM ["admin","worker","signer"] $ \role->do
      let path=setup</>"native-"<>role<>".auth"
      auth<-B8.strip <$> B.readFile path
      mode<-fileMode <$> getFileStatus path
      let (user,tailBytes)=B8.break (==':') auth
          password=B.drop 1 tailBytes
          match=[B.drop (B.length user+9) line | line<-rules,("rpcauth="<>user<>":") `B.isPrefixOf` line]
          whitelist=[B.drop (B.length user+14) line | line<-rules,("rpcwhitelist="<>user<>":") `B.isPrefixOf` line]
      pure $ mode .&. 0o777==0o600 && B.length password>=40 && case (match,whitelist) of
        ([value],[methods])->
          let (salt,hashValue)=B8.break (=='$') value
              expected=Hex.convertToBase Hex.Base16 (hmac salt password::HMAC SHA256)::B.ByteString
          in B.drop 1 hashValue==expected
                                && (role/="worker" || all (`notElem` B8.split ',' methods) ["walletprocesspsbt","dumpprivkey","listdescriptors","backupwallet"])
                                && (role/="signer" || "sendrawtransaction" `notElem` B8.split ',' methods)
        _->False
    -- Default setup selects the managed node. Exercise existing-node provisioning
    -- separately against a disposable fixture, without installing a real service.
    setupValue<-either fail pure . eitherDecodeStrict' =<< B.readFile(setup</>"setup.json")
    managedSelected<-case setupValue of
      Object fields->do
        let selected=KM.lookup "managedNode" fields==Just(Bool True)
            changed=KM.insert "managedNode" (Bool False) $ KM.insert "nodeConfig" (toJSON node) $
              KM.insert "nodeService" (String "fixture.service") fields
        B.writeFile (setup</>"setup.json") (L.toStrict $ encode $ Object changed)
        pure selected
      _->pure False
    Bootstrap.bind setup
    NodeSetup.provision setup
    first<-B.readFile node
    NodeSetup.provision setup
    second<-B.readFile node
    prior<-B.readFile(setup</>"node-config.before")
    -- Changing settings after any bootstrap begins cannot silently change identity.
    B.appendFile (setup</>"interface.json") " "
    Bootstrap.bind setup -- whitespace is not a semantic change
    B.writeFile (setup</>"interface.json") "{}"
    changed<-try(Bootstrap.bind setup) :: IO(Either BridgeError ())
    historyChecked<-originContract
    B.appendFile node "# unexpected operator edit\n"
    nodeChanged<-try(NodeSetup.provision setup) :: IO(Either BridgeError ())
    pure(managedSelected && historyChecked && either (const True) (const False) nodeChanged && all id valid && not runtimeExists && either (const True) (const False) rejected
      && C.profile c==CanonicalBeta && C.mint c==Bootstrap.canonicalMint && C.custodyOwner c==base58(B.drop 32 solana)
      && phraseA/=phraseB && first==second && prior=="server=1\n" && "rpcwhitelistdefault=0" `B.isInfixOf` first
      && either (const True) (const False) changed)

-- Read-only RPC fixtures, not claims of real Mainnet acceptance.
originContract :: IO Bool
originContract=do
  let address=base58(B.replicate 32 7)
      signature=base58(B.replicate 64 1)
      other=base58(B.replicate 64 2)
      entry sig=object ["signature" .= sig,"slot" .= (12::Int),"err" .= Null,"confirmationStatus" .= String "finalized"]
      request variant provider method args=case (method,args) of
        ("getSignaturesForAddress",[_,Object options])->
          if KM.member "before" options && variant/="repeat" then pure(toJSON ([]::[Value]))
          else pure(toJSON [entry $ if variant=="disagree" && provider=="second" then other else signature])
        ("getTransaction",_)->if variant=="missing" then pure Null else pure $ object
          ["meta" .= object [],"transaction" .= object ["signatures" .= [signature],"message" .= object
            ["accountKeys" .= [if variant=="wrong-account" then base58(B.replicate 32 8) else address]]]]
        _->fail "unexpected_bootstrap_read"
      run variant=try(Bootstrap.agreedOrigin ["first","second"] (request variant) address) :: IO(Either BridgeError T.Text)
  good<-run "ok"
  refused<-mapM run ["repeat","disagree","missing","wrong-account"]
  pure(either (const False) (==signature) good && all (either (const True) (const False)) refused)
