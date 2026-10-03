{-# LANGUAGE ScopedTypeVariables #-}
-- Offline protocol contracts. They do not emulate a network or prove live flows.
module ChainCheck (checks) where
import Bridge.Domain
import Bridge.Error
import Bridge.Native
import qualified Bridge.Solana as Solana
import Bridge.Identity (publicKey)
import Bridge.RPC
import Bridge.Wire (Profile(..))
import Control.Exception (try)
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
checks = sequence
  [ check "Solana token account accepts only the saved mint/owner and supported layout" $ once $ property $
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
