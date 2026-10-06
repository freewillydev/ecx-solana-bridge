{-# LANGUAGE ScopedTypeVariables #-}
-- Offline protocol contracts. They do not emulate a network or prove live flows.
module ChainCheck (checks) where
import qualified Bridge.Config as Config
import qualified Bridge.Store as Store
import qualified Bridge.SolanaHelper as Helper
import qualified Bridge.Wire as W
import qualified Bridge.AdminKey as AdminKey
import qualified Bridge.AdminStatus as Admin
import qualified Bridge.SolanaMessage as Message
import Paths_ecx_bridge (getDataFileName)
import System.Directory (removeFile,removeDirectoryRecursive,listDirectory)
import qualified System.Posix.Directory as PD
import System.Posix.Files (setFileMode,createSymbolicLink,createLink)
import System.Posix.Process (forkProcess,getProcessStatus,exitImmediately,ProcessStatus(..))
import System.Posix.Signals (signalProcess,sigKILL)
import System.Exit (ExitCode(..))
import System.Timeout (timeout)
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
import qualified ObservationCheck
import qualified SolanaPaymentCheck
import qualified NativePaymentCheck
import Bridge.Domain
import Bridge.Error
import Bridge.Native
import qualified Bridge.Solana as Solana
import Bridge.Identity (publicKey)
import Bridge.RPC
import Bridge.Wire (Profile(..))
import Control.Exception (try,bracket,SomeException,throwIO)
import Control.Concurrent (forkFinally,killThread)
import Control.Concurrent.MVar
import Control.Monad (unless)
import Data.Aeson hiding (Result)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.Text.Encoding as TE
import Data.IORef
import Data.Int (Int64)
import Data.Word (Word64)
import Data.Scientific (scientific)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Network.HTTP.Client as HTTP
import Test.QuickCheck hiding (label)

checks :: IO [Result]
checks = (\deployment native solana identity observation administration common->deployment<>native<>solana<>identity<>observation<>administration<>common) <$> deploymentChecks <*> NativePaymentCheck.checks <*> SolanaPaymentCheck.checks <*> solanaIdentityChecks <*> ObservationCheck.checks <*> administrationChecks <*> sequence
  [ check "native observation requires the correct ready descriptor wallet, without signing authority" $ \(sameName::Bool) (descriptors::Bool) (scanning::Bool)->ioProperty $ do
      let wallet=object ["walletname" .= (if sameName then nativeWallet settings else "other"),"descriptors" .= descriptors,"scanning" .= scanning]
          call scoped method args=if (scoped,method,args)==(True,"getwalletinfo",[]) then pure wallet else fail "unexpected wallet RPC"
          expected=sameName && descriptors && not scanning
      result<-try (nativeWalletInfoWith call settings) :: IO (Either BridgeError Value)
      pure $ case result of Right value->expected && value==wallet; Left (BridgeError code)->not expected && code=="native_wallet_not_ready"
  , check "native address readiness permits locked local keys; signing requires a current unlock" $ \(keys::Bool) (external::Bool)->
      forAll (elements [Nothing,Just 0,Just 99,Just 100,Just 101]) $ \unlocked->ioProperty $ do
        let wallet=object (["walletname" .= nativeWallet settings,"descriptors" .= True,"scanning" .= False,
              "private_keys_enabled" .= keys,"external_signer" .= external]<>maybe [] (\n->["unlocked_until" .= (n::Int64)]) unlocked)
            call scoped method args=if (scoped,method,args)==(True,"getwalletinfo",[]) then pure wallet else fail "unexpected wallet RPC"
            expected=keys && not external && maybe True (>100) unlocked
        receiving<-try (nativeWalletKeysWith call settings) :: IO (Either BridgeError Value)
        result<-try (nativeWalletReadyWith call settings 100) :: IO (Either BridgeError ())
        let receivingOK=case receiving of Right value->keys && not external && value==wallet; Left (BridgeError code)->not(keys && not external) && code=="native_wallet_not_ready"
        pure $ receivingOK && case result of Right ()->expected; Left (BridgeError code)->not expected && code=="native_wallet_not_ready"
  , check "native worker credentials must explicitly deny every signing/export method" $ once $ ioProperty $ do
      calls<-newIORef ([]::[Text])
      verifyNativeBoundaryWith $ \wallet method args->do
        if wallet && null args then modifyIORef' calls (method:) else fail "unexpected boundary request"
        reject "rpc_method_forbidden"
      methods<-readIORef calls
      refusals<-mapM (\method->rejects "native_signing_authority_not_separated" $
        verifyNativeBoundaryWith $ \_ name _->if name==method then pure Null else reject "rpc_method_forbidden") methods
      unknown<-rejects "native_signing_authority_not_separated" (verifyNativeBoundaryWith $ \_ _ _->reject "rpc_transport_unknown_outcome")
      pure (length methods==14 && "walletlock" `elem` methods && and refusals && unknown)
  , check "Solana token account accepts only the saved mint/owner and supported layout" $ once $ property $
      let key=T.replicate 32 "1"
          info=object ["owner" .= key,"mint" .= key,"state" .= ("initialized"::Text),"isNative" .= False,
            "tokenAmount" .= object ["decimals" .= (8::Int),"amount" .= ("123"::Text)]]
          parsed=object ["type" .= ("account"::Text),"info" .= info]
          account=object ["owner" .= Solana.tokenProgram,"executable" .= False,
            "data" .= object ["space" .= (165::Int),"parsed" .= parsed]]
          changes=[(["owner"],String "wrong-program"),(["executable"],Bool True),(["data","space"],Number 166),
            (["data","parsed","info","owner"],String "wrong-owner"),(["data","parsed","info","mint"],String "wrong-mint"),
            (["data","parsed","info","state"],String "frozen"),(["data","parsed","info","isNative"],Bool True),
            (["data","parsed","info","delegate"],String key),(["data","parsed","info","closeAuthority"],String key),
            (["data","parsed","info","tokenAmount","decimals"],Number 9),(["data","parsed","info","tokenAmount","amount"],String "-1")]
      in Solana.inspectTokenAccount key key account==amount 123 &&
         all (\(path,value)->isLeft $ Solana.inspectTokenAccount key key $ replace path value account) changes
  , check "Solana settings require TLS independent providers and bounded keys" $ once $ ioProperty $ do
      let key=T.replicate 32 "1"
          config=Solana.SolanaSettings L2LSignetDevnet "https://api.devnet.solana.com" Nothing key key key
      Solana.validateSolanaSettings config
      insecure <- rejects "solana_requires_https" (Solana.validateSolanaSettings config {Solana.solanaRpc="http://api.devnet.solana.com"})
      alias <- rejects "independent_rpc_required" (Solana.validateSolanaSettings config {Solana.solanaVerifierRpc=Just "https://API.DEVNET.SOLANA.COM./"})
      pure (insecure && alias && isLeft(publicKey $ T.replicate 100000 "1"))
  , check "native amounts preserve exact base units including extremes" $ forAll (chooseInteger (0,toInteger(maxBound::Int64))) $ \n ->
      let a=amount n in case a of
        Left _->property False
        Right value->case nativeNumber value of Number decimal->property(nativeAmount decimal==Right value); _->property False
  , check "native decimal exponent and precision bounds" $ once $ property $
      all isLeft [nativeAmount(scientific 1 minBound),nativeAmount(scientific 1 maxBound),nativeAmount(scientific 1 (-9)),nativeAmount(scientific (-1) 0)]
  , check "canonical unsigned parsers retain each ledger/SPL/liquidity bound" $
      forAll (elements [toInteger(maxBound::Int64),toInteger(maxBound::Word64),2^(128::Int)-1]) $ \bound->
      forAll (chooseInteger (0,bound)) $ \n->
        let text=T.pack(show n)
        in parseNatural bound text==Just n && parseNatural bound (T.pack(show(bound+1)))==Nothing
          && all ((==Nothing) . parseNatural bound)
            ["", "00", "01", "-1", "+1", " 1", "1 ", "1.0", "1e2", "１２", T.replicate 100000 "9"]
  , check "bridge amount refusals keep canonical syntax distinct from ledger overflow" $ once $ property $
      parseUnits "9223372036854775807"==amount (toInteger(maxBound::Int64))
      && parseUnits "9223372036854775808"==Left "amount_out_of_range"
      && parseUnits "18446744073709551615"==Left "invalid_base_units"
  , check "SPL account facts retain u64 balances while custody narrows to Int64" $
      forAll (chooseInteger (0,toInteger(maxBound::Word64))) $ \n->
        let key=T.replicate 32 "1"
            account=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object
              ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::Text),"info" .= object
                ["owner" .= key,"mint" .= key,"state" .= ("initialized"::Text),"isNative" .= False
                ,"tokenAmount" .= object ["decimals" .= (8::Int),"amount" .= T.pack(show n)]]]]]
            expected=if n<=toInteger(maxBound::Int64) then amount n else Left "token_account_policy_mismatch"
        in parseEither Solana.inspectClassicAccount account==Right(key,fromInteger n,key)
          && Solana.inspectTokenAccount key key account==expected
  , check "base64 bounds preserve exact binary bytes and reject oversized or malformed input" $
      forAll (chooseInt (0,1232)) $ \n->forAll (vectorOf n arbitrary) $ \bytes->
        let raw=BS.pack bytes; encoded=TE.decodeUtf8(B64.encode raw)
        in Message.boundedBase64 n encoded==Right raw
          && (n==0 || isLeft(Message.boundedBase64 (n-1) encoded))
          && all (isLeft . Message.boundedBase64 1232) ["?", "Z", "Zm9v!", T.replicate 100000 "A"]
  , check "shared RPC setup rejects insecure transport and aliased independent providers before action" $ once $ ioProperty $ do
      called<-newIORef False
      insecure<-rejects "transport-refused" $ withSolanaRpc "http://127.0.0.1:1" "expected" ("transport-refused","identity-refused") $ \_->writeIORef called True
      aliases<-mapM (rejects "independent_https_providers_required" . independentHttps "https://rpc.example.invalid/a?key=first")
        ["https://RPC.EXAMPLE.INVALID./b?key=second","https://rpc.example.invalid:8443/","http://different.invalid"]
      independentHttps "https://one.invalid/" "https://two.invalid/"
      ran<-readIORef called
      pure (insecure && not ran && and aliases)
  , check "RPC bodies enforce byte bounds across chunks" $ once $ ioProperty $ do
      chunks <- newIORef ["abc","def",""]
      let readChunk=atomicModifyIORef' chunks $ \xs->case xs of []->([],BS.empty); x:rest->(rest,x)
      body <- boundedBody 6 readChunk
      writeIORef chunks ["abc","defg"]
      oversized <- rejects "rpc_response_too_large" (boundedBody 6 readChunk)
      pure (body=="abcdef" && oversized)
  , check "read rate limits retry twice with bounded waits" $ once $ ioProperty $ do
      calls <- newIORef (0::Int); waits <- newIORef []
      let action=do
            n<-atomicModifyIORef' calls (\i->(i+1,i))
            pure $ case n of 0->Left(Just 5); 1->Left Nothing; _->Right True
      result <- retryRpcRead (\n->modifyIORef' waits (<>[n])) "getTransaction" action
      count <- readIORef calls; delays <- readIORef waits
      pure (result && count==3 && delays==[5000000,8000000])
  , check "closed read connections and rate limits share one retry budget" $ forAll (elements [HTTP.NoResponseDataReceived,HTTP.ConnectionClosed]) $ \failure->ioProperty $ do
      calls<-newIORef (0::Int); waits<-newIORef []
      let action=do
            n<-atomicModifyIORef' calls (\i->(i+1,i))
            case n of
              0->throwIO (HTTP.HttpExceptionRequest HTTP.defaultRequest failure)
              1->pure (Left $ Just 1)
              _->pure (Right True)
      result<-retryRpcRead (\n->modifyIORef' waits (<>[n])) "getTransaction" action
      count<-readIORef calls; delays<-readIORef waits
      pure (result && count==3 && delays==[250000,1000000])
  , check "unavailable Solana history shares the bounded read retry budget" $ forAll (elements
      ["getTransaction","getSignatureStatuses","getSignaturesForAddress"]) $ \method->ioProperty $ do
      calls<-newIORef (0::Int); waits<-newIORef []
      let action=do
            n<-atomicModifyIORef' calls (\i->(i+1,i))
            if n==0 then pure (Left $ Just 1) else reject "rpc_error_-32019"
      stopped<-rejects "rpc_error_-32019" (retryRpcRead (\n->modifyIORef' waits (<>[n])) method action :: IO ())
      count<-readIORef calls; delays<-readIORef waits
      pure (stopped && count==3 && delays==[1000000,250000])
  , check "storage failures never retry other methods or other RPC errors" $ forAll (elements
      [("sendTransaction","rpc_error_-32019"),("getAccountInfo","rpc_error_-32019"),
       ("futureMethod","rpc_error_-32019"),("getTransaction","rpc_error_-32016")]) $ \(method,code)->ioProperty $
      rejects code (retryRpcRead (\_->fail "unexpected retry") method (reject code) :: IO ())
  , check "repeated closed reads stop; timeouts never retry" $ forAll (elements
      [(HTTP.NoResponseDataReceived,3),(HTTP.ConnectionClosed,3),(HTTP.ResponseTimeout,1),(HTTP.ConnectionTimeout,1)]) $ \(failure,expected)->ioProperty $ do
      calls<-newIORef (0::Int); waits<-newIORef (0::Int)
      result<-try $ retryRpcRead (\_->modifyIORef' waits (+1)) "getTransaction"
        (modifyIORef' calls (+1) >> throwIO (HTTP.HttpExceptionRequest HTTP.defaultRequest failure)) :: IO (Either HTTP.HttpException ())
      count<-readIORef calls; delays<-readIORef waits
      pure (either (const True) (const False) result && count==expected && delays==expected-1)
  , check "RPC admission shares normalized hosts, isolates providers and permits no idle burst" $ once $ ioProperty $ do
      clock<-newIORef 0; waits<-newIORef []
      let wait micros=modifyIORef' waits (<>[micros]) >> modifyIORef' clock (+toInteger micros*1000)
          request=HTTP.defaultRequest {HTTP.secure=True,HTTP.host="rpc.example"}
      settings'<-rpcManagerSettings 2 (readIORef clock) wait
      let admit r=HTTP.managerWrapException settings' r (readIORef clock)
      first<-admit request
      alias<-admit request {HTTP.host="RPC.EXAMPLE.",HTTP.path="/other-key",HTTP.queryString="?apikey=private"}
      verifier<-admit request {HTTP.host="verifier.example"}
      sameHost<-admit request {HTTP.port=8443}
      native<-admit request {HTTP.secure=False,HTTP.host="127.0.0.1"}
      writeIORef clock 20000000000
      idle<-admit request
      next<-admit request
      separate<-rpcManagerSettings 2 (readIORef clock) wait
      independent<-HTTP.managerWrapException separate request (readIORef clock)
      delays<-readIORef waits
      pure ([first,alias,verifier,sameHost,native,idle,next,independent]==
        [0,500000000,500000000,1000000000,1000000000,20000000000,20500000000,20500000000]
        && delays==[500000,500000,500000])
  , check "RPC admission rounds spacing upward and rechecks delayed wakes" $ forAll (chooseInt (1,1000)) $ \rate->ioProperty $ do
      clock<-newIORef 0
      let wait micros=modifyIORef' clock (+(toInteger micros*1000+1234567))
          request=HTTP.defaultRequest {HTTP.secure=True,HTTP.host="rpc.example"}
          minimumGap=(1000000000+toInteger rate-1) `div` toInteger rate
      settings'<-rpcManagerSettings rate (readIORef clock) wait
      times<-sequence $ replicate 5 $ HTTP.managerWrapException settings' request (readIORef clock)
      pure (head times==0 && all (>=minimumGap) (zipWith (-) (tail times) times))
  , check "RPC admission rejects invalid limits" $ forAll (elements [minBound,0,1001,maxBound]) $ \rate->ioProperty $
      rejects "invalid_rpc_rate" (rpcManagerSettings rate (pure 0) (\_->fail "invalid policy waited"))
  , check "cancelling an RPC waiter releases its host without blocking independent providers" $ once $ ioProperty $ do
      clock<-newIORef 0; entered<-newEmptyMVar; blocked<-newEmptyMVar; finished<-newEmptyMVar
      let request=HTTP.defaultRequest {HTTP.secure=True,HTTP.host="rpc.example"}
      settings'<-rpcManagerSettings 2 (readIORef clock) (\_->putMVar entered () >> takeMVar blocked)
      let admit r=HTTP.managerWrapException settings' r (readIORef clock)
      _<-admit request
      result<-timeout 3000000 $ bracket
        (forkFinally (admit request) (\_->putMVar finished ())) killThread $ \thread->do
          takeMVar entered
          other<-admit request {HTTP.host="verifier.example"}
          killThread thread
          takeMVar finished
          writeIORef clock 1000000000
          restored<-admit request
          pure (other==0 && restored==1000000000)
      pure (result==Just True)
  , check "mutations and unknown methods never retry" $ forAll (elements ["sendTransaction","sendrawtransaction","walletprocesspsbt","walletpassphrase","walletlock","getnewaddress","backupwallet","restorewallet","futureMethod"]) $ \method -> ioProperty $ do
      calls <- newIORef (0::Int); waits <- newIORef (0::Int)
      refused <- rejects "rpc_rate_limited" $ retryRpcRead (\_->modifyIORef' waits (+1)) method
        (modifyIORef' calls (+1) >> pure (Left Nothing :: Either (Maybe Int) ()))
      closed<-try $ retryRpcRead (\_->modifyIORef' waits (+1)) method
        (modifyIORef' calls (+1) >> throwIO (HTTP.HttpExceptionRequest HTTP.defaultRequest HTTP.NoResponseDataReceived)) :: IO (Either HTTP.HttpException ())
      count <- readIORef calls; delays <- readIORef waits
      pure (refused && either (const True) (const False) closed && count==2 && delays==0)
  , check "invalid Retry-After values refuse immediate retry" $ forAll (elements [-1,16,maxBound]) $ \delay -> ioProperty $
      rejects "rpc_rate_limited" (retryRpcRead (\_->fail "unexpected wait") "getTransaction" (pure $ Left $ Just delay) :: IO ())
  , check "native settings bind loopback wallet and checkpoint" $ once $ ioProperty $ do
      validateNativeSettings settings
      badHost <- rejects "invalid_native_rpc_endpoint" $ validateNativeSettings settings {nativeRpc="http://example.com:29432"}
      badWallet <- rejects "invalid_native_wallet" $ validateNativeSettings settings {nativeWallet="../wallet"}
      badECX <- rejects "wrong_ecx_checkpoint" $ validateNativeSettings settings {profile=ECXBetanetDevnet}
      pure (badHost && badWallet && badECX)
  , check "L2L identity requires checkpoint challenge peers and synchronization" $ once $ ioProperty $ do
      let call challenge syncing checkpoint peers _ method _ = case method of
            "getblockchaininfo"->pure $ object ["chain" .= ("signet"::Text),"initialblockdownload" .= syncing,"blocks" .= (16000::Int),"signet_challenge" .= challenge]
            "getblockhash"->pure $ String checkpoint
            "getconnectioncount"->pure $ toJSON (peers::Int)
            _->fail "unexpected identity method"
          run challenge syncing checkpoint peers=nativeIdentityWith (call (challenge::Text) (syncing::Bool) checkpoint peers) settings
      _ <- run signetChallenge False (nativeCheckpointHash settings) 1
      sequence [rejects "wrong_signet" (run "wrong" False (nativeCheckpointHash settings) 1)
        ,rejects "native_synchronizing" (run signetChallenge True (nativeCheckpointHash settings) 1)
        ,rejects "native_checkpoint_mismatch" (run signetChallenge False "wrong" 1)
        ,rejects "native_no_peers" (run signetChallenge False (nativeCheckpointHash settings) 0)] >>= pure . and
  , check "native recovery binds immutable private backup and refuses existing wallets" $ once $ ioProperty $
      bracket (do (file,h)<-openTempFile "/tmp" "ecx-wallet-contract"; hClose h; removeFile file; PD.createDirectory file 0o700; pure file)
        removeDirectoryRecursive $ \directory->do
        nextIndex<-newIORef (1::Int); changed<-newIORef False; rangeEnd<-newIORef (999::Int); exists<-newIORef False; backups<-newIORef (0::Int); restores<-newIORef (0::Int)
        let path=directory </> "wallet.bak"
            target=settings {nativeWallet="restored"}
            call config _ method args=case method of
              "getblockchaininfo"->pure $ object ["chain" .= ("signet"::Text),"initialblockdownload" .= False,"blocks" .= (16000::Int),"signet_challenge" .= signetChallenge]
              "getblockhash"->pure $ String (nativeCheckpointHash settings)
              "getconnectioncount"->pure $ Number 1
              "getwalletinfo"->pure $ object ["walletname" .= nativeWallet config,"descriptors" .= True,"scanning" .= False,"private_keys_enabled" .= True,"external_signer" .= False]
              "listdescriptors"->do
                if args==[Bool False] then pure () else fail "private descriptors requested"
                altered<-readIORef changed
                end<-readIORef rangeEnd
                next<-readIORef nextIndex
                pure $ object ["wallet_name" .= nativeWallet config,"descriptors" .= [object ["desc" .= (if altered then "changed-descriptor" else "public-descriptor"::Text),"next" .= next,"next_index" .= next,"range" .= [0,end]]]]
              "backupwallet"->do
                if args==[toJSON path] then pure () else fail "unexpected backup destination"
                BS.writeFile path "private wallet fixture"; setFileMode path 0o600
                modifyIORef' backups (+1); pure Null
              "listwalletdir"->do
                present<-readIORef exists
                pure $ object ["wallets" .= [object ["name" .= nativeWallet target] | present]]
              "restorewallet"->do
                if args==[toJSON $ nativeWallet target,toJSON path,Bool False] then pure () else fail "unexpected restore request"
                modifyIORef' restores (+1); pure $ object ["name" .= nativeWallet target]
              _->fail "unexpected recovery request"
            run config=evalNativeRecoveryWith (call config) config
        backup<-run settings (BackupNativeWallet path)
        manifestBytes<-BS.readFile backup
        manifest<-either fail pure (eitherDecodeStrict' manifestBytes)
        invalidManifests<-mapM (\(code,keys,value)->do
          BL.writeFile backup (encode $ replace keys value manifest)
          rejects code (run target $ RestoreNativeWallet backup))
          [("invalid_native_backup_manifest",["archive"],String "../wallet.bak")
          ,("invalid_native_backup_manifest",["extra"],Bool True)
          ,("native_backup_network_mismatch",["checkpointHeight"],Number 16001)
          ,("native_backup_hash_mismatch",["sha256"],String $ T.replicate 64 "0")]
        BS.writeFile backup (BS.replicate 1048577 32)
        oversized<-rejects "native_backup_manifest_too_large" (run target $ RestoreNativeWallet backup)
        BS.writeFile backup manifestBytes
        setFileMode backup 0o644
        exposedManifest<-rejects "unsafe_native_backup_file" (run target $ RestoreNativeWallet backup)
        setFileMode backup 0o600
        duplicate<-rejects "native_backup_destination_exists" (run settings $ BackupNativeWallet path)
        setFileMode path 0o644
        exposed<-rejects "unsafe_native_backup_file" (run target $ RestoreNativeWallet backup)
        setFileMode path 0o600
        BS.appendFile path "changed"
        corrupt<-rejects "native_backup_hash_mismatch" (run target $ RestoreNativeWallet backup)
        BS.writeFile path "private wallet fixture"
        writeIORef exists True
        occupied<-rejects "native_restore_wallet_exists" (run target $ RestoreNativeWallet backup)
        writeIORef exists False
        writeIORef rangeEnd 1000
        run target (RestoreNativeWallet backup)
        writeIORef rangeEnd 998
        shrunk<-rejects "native_restore_descriptors_mismatch" (run target $ RestoreNativeWallet backup)
        writeIORef rangeEnd 1000
        writeIORef nextIndex 3
        run target (RestoreNativeWallet backup)
        writeIORef nextIndex 0
        backwards<-rejects "native_restore_descriptors_mismatch" (run target $ RestoreNativeWallet backup)
        writeIORef nextIndex 1002
        outside<-rejects "native_restore_descriptors_mismatch" (run target $ RestoreNativeWallet backup)
        writeIORef nextIndex 1
        writeIORef changed True
        mismatch<-rejects "native_restore_descriptors_mismatch" (run target $ RestoreNativeWallet backup)
        removeFile path
        existingManifest<-rejects "native_backup_destination_exists" (run settings $ BackupNativeWallet path)
        removeFile backup
        writeIORef changed False
        let changing wallet method args=do
              result<-call settings wallet method args
              if method=="backupwallet" then writeIORef changed True else pure ()
              pure result
        race<-rejects "native_wallet_changed_during_backup" (evalNativeRecoveryWith changing settings $ BackupNativeWallet path)
        counts<-(,) <$> readIORef backups <*> readIORef restores
        pure (and (invalidManifests<>[oversized,exposedManifest,duplicate,existingManifest,exposed,corrupt,occupied,shrunk,backwards,outside,mismatch,race])
          && not ("/unused/credential" `BS.isInfixOf` manifestBytes) && counts==(2,6))
  , check "locked-wallet allocation never repeats getnewaddress after a lost claim" $ once $ ioProperty $ do
      saved <- newIORef False; allocations <- newIORef (0::Int)
      let label="ecx-bridge:v1:contract:order:known"
          address="tb1q9vl0cpvddncs78537mrpxawydzsgkz7k5hgj7w"
          call _ method _=case method of
            "getwalletinfo"->pure $ object ["walletname" .= nativeWallet settings,"descriptors" .= True,"scanning" .= False,"private_keys_enabled" .= True,"external_signer" .= False,"unlocked_until" .= (0::Int)]
            "getaddressesbylabel"->do
              exists<-readIORef saved
              if exists then pure $ object [K.fromText address .= object ["purpose" .= ("receive"::Text)]] else reject "rpc_error_-11"
            "getnewaddress"->writeIORef saved True >> modifyIORef' allocations (+1) >> pure (String address)
            "getaddressinfo"->pure $ object ["address" .= address,"ismine" .= True,"solvable" .= True,"ischange" .= False,"labels" .= [label],"scriptPubKey" .= ("0014"<>T.replicate 40 "0")]
            _->fail "unexpected allocation method"
      unresolved <- rejects "native_allocation_unresolved" (recoverNativeAddressWith call settings False label)
      first <- recoverNativeAddressWith call settings True label
      retry <- recoverNativeAddressWith call settings False label
      count <- readIORef allocations
      pure (unresolved && first==address && retry==address && count==1)
  ]
 where
  check description p=putStrLn description >> quickCheckWithResult stdArgs {maxSuccess=100} p

settings :: NativeSettings
settings=NativeSettings L2LSignetDevnet "http://127.0.0.1:29432" "/unused/credential" "ecx-bridge-test"
  16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
rejects :: Text -> IO a -> IO Bool
rejects code action=do
  outcome<-try action
  pure $ case outcome of Left(BridgeError actual)->actual==code; Right _->False
isLeft :: Either a b -> Bool
isLeft (Left _)=True
isLeft _=False

replace :: [Key] -> Value -> Value -> Value
replace [] replacement _=replacement
replace (key:rest) replacement (Object fields)=Object $ KM.insert key
  (replace rest replacement $ maybe Null id $ KM.lookup key fields) fields
replace _ _ value=value

solanaIdentityChecks :: IO [Result]
solanaIdentityChecks=sequence
  [ check "classic SPL mint policy validates optional authority and the full unsigned supply range" $
      forAll (chooseInteger (0,toInteger(maxBound::Word64))) $ \quantity->
        let withSupply=replace ["data","parsed","info","supply"] (String $ T.pack $ show quantity)
            parse=parseEither (Solana.inspectMint $ Just 8)
            revoked=replace ["data","parsed","info","mintAuthority"] Null
            otherDecimals=replace ["data","parsed","info","decimals"] (Number 6) mintAccount
        in parse(withSupply mintAccount)==Right(Just owner,fromInteger quantity)
          && parse(revoked $ withSupply mintAccount)==Right(Nothing,fromInteger quantity)
          && parse(replace ["data","parsed","info","supply"] (String "0") mintAccount)==Right(Just owner,0)
          && parseEither (Solana.inspectMint Nothing) otherDecimals==Right(Just owner,100)
          && all (isLeft . parseEither (Solana.inspectMint Nothing))
            [replace ["data","parsed","info","decimals"] (Number n) mintAccount | n<-[-1,256]]
  , check "both Solana providers must supply the supported mint layout and canonical policy fields" $ once $ ioProperty $ do
      primary<-mapM (\bad->rejects "unsupported_mint_policy" $ inspect bad mintAccount) badMints
      secondary<-mapM (\bad->rejects "unsupported_mint_policy" $ inspect mintAccount bad) badMints
      missing<-rejects "mint_not_found" $ inspect mintAccount Null
      wrongProgram<-rejects "wrong_token_program" $ inspect mintAccount (replace ["owner"] (String owner) mintAccount)
      pure (and primary && and secondary && missing && wrongProgram)
  , check "Solana identity corroborates authority while allowing supply movement and preserving primary info" $ once $ ioProperty $ do
      let changed field=replace ["data","parsed","info",field]
          revoked=changed "mintAuthority" Null mintAccount
      original<-inspect mintAccount (changed "supply" (String "18446744073709551615") mintAccount)
      absentAuthority<-inspect revoked revoked
      changedAuthority<-rejects "mint_verifier_policy_mismatch" $
        inspect mintAccount (changed "mintAuthority" (String Solana.tokenProgram) mintAccount)
      revokedAuthority<-rejects "mint_verifier_policy_mismatch" $ inspect mintAccount revoked
      wrongGenesis<-rejects "verifier_wrong_genesis" $ Solana.solanaIdentityWith (reply mintAccount)
        (Just $ \method args->if method=="getGenesisHash" then pure(String "wrong") else reply mintAccount method args) config
      unavailable<-rejects "rpc_unavailable" $ Solana.solanaIdentityWith (reply mintAccount)
        (Just $ \method args->if method=="getAccountInfo" then reject "rpc_unavailable" else reply mintAccount method args) config
      pure (original==mintInfo && absentAuthority==replace ["mintAuthority"] Null mintInfo
        && changedAuthority && revokedAuthority && wrongGenesis && unavailable)
  ]
 where
  check description p=putStrLn description >> quickCheckWithResult stdArgs p
  owner=T.replicate 32 "1"
  config=Solana.SolanaSettings CanonicalBeta "https://primary.example" (Just "https://verifier.example")
    "EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq" owner owner
  mintInfo=object ["decimals" .= (8::Int),"isInitialized" .= True,"freezeAuthority" .= Null
    ,"mintAuthority" .= owner,"supply" .= ("100"::Text)]
  mintAccount=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object
    ["space" .= (82::Int),"parsed" .= object ["type" .= ("mint"::Text),"info" .= mintInfo]]]
  tokenAccount=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object
    ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::Text),"info" .= object
      ["owner" .= owner,"mint" .= Solana.mint config,"state" .= ("initialized"::Text),"isNative" .= False
      ,"tokenAmount" .= object ["decimals" .= (8::Int),"amount" .= ("10"::Text)]]]]]
  badMints=[replace path value mintAccount | (path,value)<-
    [(["executable"],Bool True),(["data","space"],Number 83),(["data","parsed","type"],String "account")]
    <>[(["data","parsed","info",field],value) | (field,value)<-
      [("decimals",Number 9),("isInitialized",Bool False),("freezeAuthority",String owner)
      ,("mintAuthority",String "invalid"),("supply",Number 100),("supply",Null)]
      <>[("supply",String n) | n<-["","-1","+1","01","1.0","18446744073709551616"]]]]
    <>[replace ["data","parsed","info"] (Object $ KM.delete field fields) mintAccount
      | Object fields<-[mintInfo],field<-["mintAuthority","supply","freezeAuthority"]]
  inspect primary secondary=Solana.solanaIdentityWith (reply primary) (Just $ reply secondary) config
  reply value method args=case (method,args) of
    ("getGenesisHash",[])->pure $ toJSON $ Solana.solanaGenesis CanonicalBeta
    ("getAccountInfo",[String address,options])
      | options==object ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]
        && address `elem` [Solana.mint config,owner]->pure $ object ["value" .= if address==Solana.mint config then value else tokenAccount]
    _->fail "unexpected Solana mint identity RPC"

-- Scripted RPC responses exercise the production evidence collector. They are
-- deliberately offline and make no assertion about real provider completeness.
administrationChecks :: IO [Result]
administrationChecks=sequence
  [ check "administration anchors finalized history before acquiring and verifying its exact fresh blockhash" $ once $ ioProperty $ do
      actual<-adminScript fresh $ \call->Admin.newRecoveryWith call genesis payer 50 root
      badBlock<-rejects "administration_blockhash_origin_mismatch" $ adminScript
        (take 3 fresh<>[("getBlock",blockArgs,replace ["blockhash"] (String otherHash) block)]) $ \call->
          Admin.newRecoveryWith call genesis payer 50 root
      wrongGenesis<-rejects "wrong_administration_network" $ adminScript
        [("getGenesisHash",[],String "another genesis")] $ \call->Admin.newRecoveryWith call genesis payer 50 root
      missingOrigin<-rejects "administration_history_origin_required" $ adminScript
        [head fresh,("getSignaturesForAddress",originArgs,toJSON ([]::[Value]))] $ \call->
          Admin.newRecoveryWith call genesis payer 50 root
      staleOrigin<-rejects "invalid_administration_recovery_context" $ adminScript
        (take 2 fresh<>[let (method,args,value)=fresh!!2 in (method,args,replace ["context","slot"] (Number 89) value)]) $ \call->
          Admin.newRecoveryWith call genesis payer 50 root
      pure (actual==recovery && badBlock && wrongGenesis && missingOrigin && staleOrigin)
  , check "administration replacement requires exact finalized failure and a bounded verified fee" $ once $ ioProperty $ do
      proof<-adminScript (prefix<>terminal failedStatus failedTransaction) $ \call->Admin.retirementWith call signature bytes recovery
      let mutations=
            [("administration_attempt_not_retryable",pending,Null)
            ,("administration_attempt_not_retryable",replace ["err"] Null failedStatus,replace ["meta","err"] Null failedTransaction)
            ,("administration_status_mismatch",failedStatus,replace ["transaction"] (toJSON ["different"::Text,"base64"]) failedTransaction)
            ,("administration_status_mismatch",failedStatus,replace ["meta","err"] Null failedTransaction)
            ,("administration_failed_evidence_mismatch",failedStatus,replace ["slot"] (Number 109) failedTransaction)
            ,("administration_failed_evidence_mismatch",replace ["slot"] (Number 100) failedStatus,replace ["slot"] (Number 100) failedTransaction)
            ,("administration_failed_evidence_mismatch",failedStatus,replace ["meta","fee"] (Number 0) failedTransaction)
            ,("administration_failed_evidence_mismatch",failedStatus,replace ["meta","fee"] (Number 51) failedTransaction)]
      refused<-mapM (\(code,status,transaction)->rejects code $ adminScript (prefix<>terminal status transaction) $ \call->
        Admin.retirementWith call signature bytes recovery) mutations
      outcome<-fieldValue "outcome" proof :: IO Text
      pure (outcome=="failed" && and refused)
  , check "expired administration attempts require finalized expiry, complete anchored history and a final absence recheck" $ once $ ioProperty $ do
      proof<-adminScript expired $ \call->Admin.retirementWith call signature bytes recovery
      outcome<-fieldValue "outcome" proof :: IO Text
      invalidExpiry<-mapM (\(valid,slot,height)->rejects "administration_attempt_not_expired" $
        adminScript (prefix<>terminal Null Null<>expiry valid slot height) $ \call->Admin.retirementWith call signature bytes recovery)
        [(True,120,200),(False,100,200),(False,120,160)]
      invalidHistory<-mapM (\(code,values)->rejects code $ adminScript (beforeHistory<>[("getSignaturesForAddress",historyArgs,toJSON values)]) $ \call->
        Admin.retirementWith call signature bytes recovery)
        [("solana_history_gap",[])
        ,("solana_history_repeated_page",[history otherSignature 110,history otherSignature 110,history origin 90])
        ,("solana_history_order_invalid",[history otherSignature 80,history origin 90])
        ,("administration_history_disagrees",[history signature 110,history origin 90])
        ,("administration_history_disagrees",[history origin 89])]
      gap<-rejects "solana_history_gap" $ adminScript (beforeHistory<>
        [("getSignaturesForAddress",historyArgs,toJSON [history otherSignature 110])
        ,("getSignaturesForAddress",[toJSON payer,object ["commitment" .= ("finalized"::Text),"minContextSlot" .= (120::Int)
          ,"limit" .= (100::Int),"before" .= otherSignature]],toJSON ([]::[Value]))]) $ \call->Admin.retirementWith call signature bytes recovery
      changed<-rejects "administration_history_changed" $ adminScript (take (length expired-2) expired<>terminal pending Null) $ \call->
        Admin.retirementWith call signature bytes recovery
      pure (outcome=="expired-unseen" && and invalidExpiry && and invalidHistory && gap && changed)
  , check "administration recovery bounds generations and binds root, parent, payer, fee cap and fresh hash" $
      forAll (chooseInt (0,8)) $ \generation->
        let child=recovery {Admin.recoveryGeneration=generation,Admin.recoveryParent=Just parent
              ,Admin.recoveryEvidence=Just(object []),Admin.recoveryBlockhash=otherHash,Admin.recoverySlot=101}
            valid=Admin.validateRecovery genesis payer 50 otherHash child
            wrong=[child {Admin.recoveryRoot="relative"},child {Admin.recoveryParent=Nothing},child {Admin.recoveryParent=Just "invalid"}
              ,child {Admin.recoveryEvidence=Nothing},child {Admin.recoveryFeeLimit=51}
              ,child {Admin.recoveryPayer=otherHash},child {Admin.recoveryGenesis="wrong"}
              ,child {Admin.recoveryBlockhash=recent},child {Admin.recoveryOriginSlot=102}]
            successor=child {Admin.recoveryGeneration=1}
        in (not(isLeft valid)==(generation>0 && generation<8))
          && all (isLeft . Admin.validateRecovery genesis payer 50 otherHash) wrong
          && Admin.validateSuccessor recovery parent successor==Right ()
          && all (isLeft . Admin.validateSuccessor recovery parent)
            [successor {Admin.recoveryRoot="/tmp/other-attempt"},successor {Admin.recoveryParent=Just(T.replicate 64 "b")}
            ,successor {Admin.recoveryGeneration=2},successor {Admin.recoveryBlockhash=recent},successor {Admin.recoverySlot=100}]
          && Admin.attemptPath successor==root<>".retry"
  , check "private administration records publish exclusively and survive refused writes unchanged" $ once $ ioProperty $
      withPrivateDirectory $ \directory->do
        let path=directory </> "attempt"; symbolic=directory </> "symbolic"; hard=directory </> "hard"
        AdminKey.savePrivate path "saved exact transaction bytes"
        duplicate<-failsIO (AdminKey.savePrivate path "overwrite")
        createSymbolicLink path symbolic
        symlinkRead<-failsIO (AdminKey.readPrivate symbolic)
        symlinkWrite<-failsIO (AdminKey.savePrivate symbolic "overwrite")
        createLink path hard
        hardlinkRead<-rejects "unsafe_administration_file" (AdminKey.readPrivate path)
        hardlinkWrite<-failsIO (AdminKey.savePrivate hard "overwrite")
        removeFile hard
        setFileMode path 0o644
        permission<-rejects "unsafe_administration_file" (AdminKey.readPrivate path)
        setFileMode path 0o600
        saved<-AdminKey.readPrivate path
        writeBound<-rejects "administration_attempt_too_large" (AdminKey.savePrivate (directory </> "oversized") (BS.replicate 8193 32))
        BS.writeFile (directory </> "oversized") (BS.replicate 8193 32)
        setFileMode (directory </> "oversized") 0o600
        bound<-rejects "administration_attempt_too_large" (AdminKey.readPrivate $ directory </> "oversized")
        names<-listDirectory directory
        pure (and [duplicate,symlinkRead,symlinkWrite,hardlinkRead,hardlinkWrite,permission,writeBound,bound]
          && saved=="saved exact transaction bytes" && all (not . T.isInfixOf ".pending-" . T.pack) names)
  , check "administration family locks exclude another process and release after failure" $ once $ ioProperty $
      withPrivateDirectory $ \directory->do
        let path=directory </> "attempt"
        excluded<-AdminKey.withFamily path $ do
          child<-forkProcess $ do
            refused<-failsIO (AdminKey.withFamily path $ pure ())
            exitImmediately (if refused then ExitSuccess else ExitFailure 1)
          status<-timeout 5000000 (getProcessStatus True False child)
          case status of
            Just result->pure (result==Just(Exited ExitSuccess))
            Nothing->signalProcess sigKILL child >> getProcessStatus True False child >> pure False
        failed<-failsIO (AdminKey.withFamily path $ fail "interrupted administration operation")
        released<-AdminKey.withFamily path (pure True)
        pure (excluded && failed && released)
  ]
 where
  check description p=putStrLn description >> quickCheckWithResult stdArgs p
  genesis="fixture genesis"; root="/tmp/ecx-administration-contract/attempt"
  payer=Message.base58(BS.replicate 32 1); recent=Message.base58(BS.replicate 32 2); otherHash=Message.base58(BS.replicate 32 3)
  origin=Message.base58(BS.replicate 64 1); signature=Message.base58(BS.replicate 64 2); otherSignature=Message.base58(BS.replicate 64 3)
  bytes="archived base64 transaction"; parent=T.replicate 64 "a"
  recovery=Admin.Recovery genesis payer 50 root 0 Nothing recent origin 90 100 160 Nothing
  history sig slot=object ["signature" .= sig,"slot" .= (slot::Int),"confirmationStatus" .= ("finalized"::Text),"err" .= Null]
  originArgs=[toJSON payer,object ["commitment" .= ("finalized"::Text),"limit" .= (1::Int)]]
  blockArgs=[Number 100,object ["commitment" .= ("finalized"::Text),"transactionDetails" .= ("none"::Text),"rewards" .= False]]
  block=object ["blockhash" .= recent,"blockHeight" .= (100::Int)]
  fresh=[("getGenesisHash",[],String genesis),("getSignaturesForAddress",originArgs,toJSON [history origin 90])
    ,("getLatestBlockhash",[object ["commitment" .= ("finalized"::Text),"minContextSlot" .= (90::Int)]],
      object ["context" .= object ["slot" .= (100::Int)],"value" .= object ["blockhash" .= recent,"lastValidBlockHeight" .= (160::Int)]])
    ,("getBlock",blockArgs,block)]
  prefix=[head fresh,last fresh]
  terminal status transaction=
    [("getSignatureStatuses",[toJSON [signature],object ["searchTransactionHistory" .= True]],object ["value" .= [status]])
    ,("getTransaction",[toJSON signature,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"maxSupportedTransactionVersion" .= (0::Int)]],transaction)]
  failure=object ["InstructionError" .= [Number 0,String "InsufficientFunds"]]
  pending=object ["confirmationStatus" .= ("confirmed"::Text),"err" .= Null,"slot" .= (110::Int)]
  failedStatus=object ["confirmationStatus" .= ("finalized"::Text),"err" .= failure,"slot" .= (110::Int)]
  failedTransaction=object ["transaction" .= [bytes,"base64"],"slot" .= (110::Int),"meta" .= object ["err" .= failure,"fee" .= (5::Int)]]
  validity valid slot=object ["value" .= valid,"context" .= object ["slot" .= (slot::Int)]]
  expiry valid slot height=
    [("isBlockhashValid",[toJSON recent,object ["commitment" .= ("finalized"::Text),"minContextSlot" .= (100::Int)]],validity valid slot)
    ,("getBlockHeight",[object ["commitment" .= ("finalized"::Text),"minContextSlot" .= slot]],toJSON (height::Int))]
  beforeHistory=prefix<>terminal Null Null<>expiry False 120 200
  historyArgs=[toJSON payer,object ["commitment" .= ("finalized"::Text),"minContextSlot" .= (120::Int),"limit" .= (100::Int)]]
  expired=beforeHistory<>[("getSignaturesForAddress",historyArgs,toJSON [history otherSignature 110,history origin 90])]<>terminal Null Null

adminScript :: [(Text,[Value],Value)] -> ((Text -> [Value] -> IO Value) -> IO a) -> IO a
adminScript responses action=do
  remaining<-newIORef responses
  result<-action $ \method arguments->do
    pending<-readIORef remaining
    case pending of
      (expected,args,value):rest | method==expected && arguments==args->writeIORef remaining rest >> pure value
      _->fail ("unexpected administration RPC: "<>T.unpack method<>" "<>show arguments)
  pending<-readIORef remaining
  unless (null pending) (fail "administration evidence skipped a required read")
  pure result

withPrivateDirectory :: (FilePath -> IO a) -> IO a
withPrivateDirectory=bracket (do
  (path,handle)<-openTempFile "/tmp" "ecx-admin-contract"; hClose handle; removeFile path
  PD.createDirectory path 0o700; pure path) removeDirectoryRecursive

failsIO :: IO a -> IO Bool
failsIO action=do
  outcome<-try (action >> pure ()) :: IO (Either SomeException ())
  pure (isLeft outcome)

-- Public configuration vector matches the retained executable's check-config
-- output and captured Devnet payment identity. No RPC or keys are used here.
deploymentChecks :: IO [Result]
deploymentChecks = do
  path<-getDataFileName "test/fixtures/deployment-config.json"
  config<-Config.loadConfig path
  let identity="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8"
      money=either (error . T.unpack) id . amount
      links=Config.defaultInterface (Config.profile config)
      check description p=putStrLn description >> quickCheckWithResult stdArgs p
      invalid value=isLeft (eitherDecode (encode value) :: Either String Config.Config)
  sequence
    [ check "configuration preserves the baseline deployment fingerprint across operational changes" $ once $
        Config.fingerprint config==identity && all ((==identity).Config.fingerprint)
          [config {Config.serverPort=8123,Config.signerPort=8124,Config.fenceDirectory="/new/fence"}
          ,config {Config.nativeCookie="/new/auth",Config.solanaRpc="https://other.example",Config.maxNativeFee=money 2000}]
        && all ((/=identity).Config.fingerprint)
          [config {Config.deploymentId="another"},config {Config.nativeWallet="another"},config {Config.nativeCheckpointHeight=16001}]
    , check "one config derives coherent ledger signer and public customer settings" $ once $
        let store=Config.storePolicy config; solana=Config.solanaPolicy config
            public=Config.publicConfiguration config links True
            terms=Store.executionTerms store
        in W.deploymentFingerprint(W.paymentPolicy terms)==identity && Helper.fingerprint solana==identity
          && W.savedSolanaFee(W.paymentLimits terms)==Helper.maxSolFee solana
          && Store.orderMinimum(Store.admissionLimits store)==W.pubMinInput public
          && W.pubMint public==Helper.mint solana && W.pubCustodyOwner public==Helper.custodyOwner solana
          && W.pubIntakeEnabled public && not(W.pubImplementationReady public)
    , check "configuration rejects missing histories obsolete socket fields and unknown keys" $ once $
        invalid (replace ["solanaHistoryStart"] Null $ toJSON config)
        && invalid (replace ["customerSocket"] (String "/old.sock") $ toJSON config)
        && invalid (replace ["unknown"] (Bool True) $ toJSON config)
    , check "configuration catches impossible limits endpoints and history anchors before startup" $ once $ ioProperty $
        and <$> mapM (\(code,value)->rejects code $ Config.validateConfig value)
          [("invalid_server_endpoints",config {Config.serverPort=Config.signerPort config})
          ,("invalid_server_endpoints",config {Config.signerPort=0})
          ,("absolute_paths_required",config {Config.fenceDirectory="relative"})
          ,("invalid_limits",config {Config.minInput=money 1})
          ,("invalid_policy",config {Config.nativeConfirmations=1009})
          ,("invalid_daily_budget",config {Config.maxNativeDailyCost=money 1})
          ,("invalid_signature",config {Config.solanaOperatingHistoryStart=""})]
    , check "real ECX profile checkpoint and canonical backup requirements are preserved" $ once $ ioProperty $ do
        let beta=config {Config.profile=ECXBetanetDevnet,Config.nativeCheckpointHeight=967680,
              Config.nativeCheckpointHash="00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042"}
            canonical=beta {Config.profile=CanonicalBeta,Config.mint="EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq",
              Config.solanaRpc="https://api.mainnet-beta.solana.com",Config.solanaVerifierRpc=Just "https://independent.example"}
        Config.validateConfig beta
        refused<-rejects "canonical_backup_required" (Config.validateConfig canonical)
        Config.validateConfig canonical {Config.backupRequired=True}
        missingVerifier<-rejects "canonical_identity_or_verifier_required" $
          Config.validateConfig canonical {Config.backupRequired=True,Config.solanaVerifierRpc=Nothing}
        wrongMint<-rejects "canonical_identity_or_verifier_required" $
          Config.validateConfig canonical {Config.backupRequired=True,Config.mint=Config.mint config}
        let public=Config.publicConfiguration canonical (Config.defaultInterface CanonicalBeta) True
        pure (refused && missingVerifier && wrongMint && W.pubIntakeEnabled public
          && W.pubProfile public==CanonicalBeta && W.pubSolanaCluster public=="mainnet-beta")
    , check "presentation rejects unsafe URLs and mainnet trading links on devnet" $ once $ ioProperty $ do
        Config.validateInterface config links
        script<-rejects "invalid_support_url" (Config.validateInterface config links {W.supportUrl=Just "javascript:alert(1)"})
        trading<-rejects "trading_links_require_mainnet" (Config.validateInterface config links {W.jupiterUrl=Just "https://jup.ag/swap"})
        pure (script && trading)
    , check "configuration loader bounds bytes before parsing" $ once $ ioProperty $
        bracket (do (file,h)<-openTempFile "/tmp" "ecx-config-contract"; hClose h; pure file) removeFile $ \file->do
          BS.writeFile file (BS.replicate 32769 32)
          rejects "config_too_large" (Config.loadConfig file)
    ]
