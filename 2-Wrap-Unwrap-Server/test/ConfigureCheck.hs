module ConfigureCheck (contract,walletProperty) where
import qualified Bridge.Config as C
import Bridge.AdminKey (savePrivate)
import Bridge.Wallet (mnemonic,walletKey,nativeDescriptors)
import qualified Bridge.Native as N
import Bridge.Wire (Profile(..))
import Bridge.Error (BridgeError(..))
import Data.IORef
import Control.Monad (unless)
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
import Data.Bits ((.&.))
import System.Directory
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
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
      run input=readCreateProcessWithExitCode ((proc executable ["configure"]) {cwd=Just directory}) input
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
    expectedKey<-either (const $ fail "fixture mnemonic") pure (walletKey phrase)
    let expectedSetup=object ["existing" .= False,"method" .= ("source"::String),"sourceRoot" .= directory,"restic" .= worker]
    pure(nativeChecked && C.fingerprint config==C.fingerprint other && C.nativeCookie config/=C.nativeCookie other
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
          ,conjoin [counterexample "BIP39/SLIP10 known vector mismatch" $
             mnemonic (B.replicate 16 byte)==Right phrase &&
             fmap (Hex.convertToBase Hex.Base16 . B.take 32) (walletKey phrase)==Right expected
            | (byte,phrase,expected)<-vectors]
          ,property (nativeDescriptors False (unwords $ replicate 11 "abandon"<>["about"])==Right
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

-- Closed native setup protocol: real-node descriptor compatibility is checked
-- separately; these fixtures exercise interruption/refusal without chain effects.
nativeSeedContract :: FilePath -> IO Bool
nativeSeedContract directory=do
  let phrase=unwords (replicate 11 "abandon"<>["about"])
      seedFile=directory</>"native-seed.txt"
      settings=N.NativeSettings L2LSignetDevnet "http://127.0.0.1:29432" (directory</>"worker.auth") "seed-test"
        16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
      public=["public-receive#checksum","public-change#checksum"]::[T.Text]
  private<-either (const $ fail "fixture native mnemonic") pure (nativeDescriptors True phrase)
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
