{-# LANGUAGE ScopedTypeVariables #-}
-- Offline protocol contracts. They do not emulate a network or prove live flows.
module ChainCheck (checks) where
import qualified Bridge.Config as Config
import qualified Bridge.Store as Store
import qualified Bridge.SolanaHelper as Helper
import qualified Bridge.Wire as W
import Paths_ecx_bridge_rebuild (getDataFileName)
import System.Directory (removeFile)
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
import Control.Exception (try,bracket)
import Data.Aeson hiding (Result)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import qualified Data.ByteString as BS
import Data.IORef
import Data.Int (Int64)
import Data.Scientific (scientific)
import Data.Text (Text)
import qualified Data.Text as T
import Test.QuickCheck hiding (label)

checks :: IO [Result]
checks = (\deployment native solana observation common->deployment<>native<>solana<>observation<>common) <$> deploymentChecks <*> NativePaymentCheck.checks <*> SolanaPaymentCheck.checks <*> ObservationCheck.checks <*> sequence
  [ check "native worker credentials must explicitly deny every signing/export method" $ once $ ioProperty $ do
      calls<-newIORef ([]::[Text])
      verifyNativeBoundaryWith $ \wallet method args->do
        if wallet && null args then modifyIORef' calls (method:) else fail "unexpected boundary request"
        reject "rpc_method_forbidden"
      methods<-readIORef calls
      refusals<-mapM (\method->rejects "native_signing_authority_not_separated" $
        verifyNativeBoundaryWith $ \_ name _->if name==method then pure Null else reject "rpc_method_forbidden") methods
      unknown<-rejects "native_signing_authority_not_separated" (verifyNativeBoundaryWith $ \_ _ _->reject "rpc_transport_unknown_outcome")
      pure (length methods==13 && and refusals && unknown)
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
      result <- retryRateLimitedRead (\n->modifyIORef' waits (<>[n])) "getTransaction" action
      count <- readIORef calls; delays <- readIORef waits
      pure (result && count==3 && delays==[5000000,8000000])
  , check "mutations and unknown methods never retry" $ forAll (elements ["sendTransaction","sendrawtransaction","walletprocesspsbt","getnewaddress","futureMethod"]) $ \method -> ioProperty $ do
      calls <- newIORef (0::Int); waits <- newIORef (0::Int)
      refused <- rejects "rpc_rate_limited" $ retryRateLimitedRead (\_->modifyIORef' waits (+1)) method
        (modifyIORef' calls (+1) >> pure (Left Nothing :: Either (Maybe Int) ()))
      count <- readIORef calls; delays <- readIORef waits
      pure (refused && count==1 && delays==0)
  , check "invalid Retry-After values refuse immediate retry" $ forAll (elements [-1,16,maxBound]) $ \delay -> ioProperty $
      rejects "rpc_rate_limited" (retryRateLimitedRead (\_->fail "unexpected wait") "getTransaction" (pure $ Left $ Just delay) :: IO ())
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
  , check "native allocation never repeats getnewaddress after a lost claim" $ once $ ioProperty $ do
      saved <- newIORef False; allocations <- newIORef (0::Int)
      let label="ecx-bridge:v1:contract:order:known"
          address="tb1q9vl0cpvddncs78537mrpxawydzsgkz7k5hgj7w"
          call _ method _=case method of
            "getwalletinfo"->pure $ object ["walletname" .= nativeWallet settings,"descriptors" .= True,"scanning" .= False,"private_keys_enabled" .= True,"external_signer" .= False]
            "getaddressesbylabel"->do
              exists<-readIORef saved
              if exists then pure $ object [K.fromText address .= object ["purpose" .= ("receive"::Text)]] else reject "rpc_error_-11"
            "getnewaddress"->writeIORef saved True >> modifyIORef' allocations (+1) >> pure (String address)
            "getaddressinfo"->pure $ object ["address" .= address,"ismine" .= True,"solvable" .= True,"ischange" .= False,"labels" .= [label],"scriptPubKey" .= ("0014"<>T.replicate 40 "0")]
            _->fail "unexpected allocation method"
      unresolved <- rejects "native_allocation_unresolved" (recoverNativeAddressWith call settings 100 False label)
      first <- recoverNativeAddressWith call settings 100 True label
      retry <- recoverNativeAddressWith call settings 100 False label
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
        pure refused
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
