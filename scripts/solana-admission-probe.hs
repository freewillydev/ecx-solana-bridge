{-# LANGUAGE OverloadedStrings #-}
-- Real Devnet admission only. The temporary helper configuration has no signer.
-- Stop this deployment's worker first; the ledger lock excludes other workers.
import Bridge.Admission
import Bridge.Config
import Bridge.Ledger
import Bridge.RPC
import Bridge.Solana
import Bridge.SolanaHelper
import Bridge.SolanaMessage (Transaction(..),decodeTransaction,base58)
import Bridge.SolanaPayment (contextValue,systemLamports)
import Bridge.Types
import Control.Exception (bracket,try)
import Control.Monad (forM)
import Crypto.Error (CryptoFailable(..))
import Crypto.Random (getRandomBytes)
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client (Manager)
import System.Directory (createDirectory,getTemporaryDirectory,removePathForcibly)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

main :: IO ()
main=do
  args<-getArgs
  path<-case args of [p]->pure p; _->fail "solana-admission-probe CONFIG"
  configured<-loadConfig path
  require (profile configured==L2LSignetDevnet
    && fingerprint configured=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "dedicated_public_devnet_test_only"
  withUnsignedConfig configured $ \c -> withLedger (dbPath c) (fingerprint c) $ \ledger -> do
    pendingAttempts ledger >>= \xs->require (null xs) "pending_payment_must_resolve_first"
    pendingPreparations ledger >>= \xs->require (null xs) "pending_payment_must_resolve_first"
    manager<-newRpcManager
    _<-solanaIdentity manager c
    before<-balances manager c
    calls<-newIORef ([]::[Text])
    simulations<-newIORef (0::Int)
    -- Only an unfunded simulation destination; no key is written and the
    -- RPC allowlist cannot send value to it. The SDK checks it is on-curve.
    seed<-getRandomBytes 32 :: IO BS.ByteString
    newAtaOwner<-case Ed.secretKey seed of
      CryptoPassed key -> pure (base58 $ BA.convert $ Ed.toPublic key)
      CryptoFailed _ -> reject "probe_public_key_generation_failed"
    let call method params=do
          require (method `elem` ["getLatestBlockhash","getBlockHeight","getMultipleAccounts","getFeeForMessage","getMinimumBalanceForRentExemption","simulateTransaction"]) "unexpected_admission_rpc"
          case (method,params) of
            ("simulateTransaction",String bytes:_) -> do
              Transaction signatures _ _<-either reject pure (decodeTransaction bytes)
              require (case signatures of [sig]->BS.all (==0) sig; _->False) "preview_has_signature"
              modifyIORef' simulations (+1)
            _->pure ()
          modifyIORef' calls (<>[method])
          solanaCall manager c method params
        amt n=either (error . T.unpack) id (amount n)
        wallet="HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg"
        native="tb1q8frp8q5wu4lpr8f6426ndxwuagymygl9w0nn3m"
        wrap=OrderRequest NativeToWrapped (amt 10000) wallet native Nothing "admission-wrap"
        redeem=OrderRequest WrappedToNative (amt 10000) native wallet (Just wallet) "admission-redeem"
        cases=[("wrapped-net-existing-ata",wrap,Right (amt 9980,False,Nothing))
              ,("redemption-full-refund",redeem,Right (amt 10000,False,Just $ amt 5000))
              ,("wrapped-net-new-ata",wrap{recipient=newAtaOwner},Right (amt 9980,True,Nothing))
              ,("custody-wallet-refused",wrap{recipient=custodyOwner c},Left "bridge_owned_destination")
              ,("custody-account-refused",wrap{recipient=custodyAta c},Left "bridge_owned_destination")
              ,("mint-refused",wrap{recipient=mint c},Left "bridge_owned_destination")
              ,("token-account-as-wallet-refused",wrap{recipient="GQnRnfs2B9j6pymrbY4KmX9WnAQ6czPAdt2u6XpWZSjQ"},Left "subprocess_failed")]
    results<-forM cases $ \(name,request,expected)->do
      result<-try (checkSolanaQuoteWith call (invokeUnsignedHelper c) c request) :: IO (Either BridgeError SolanaQuoteCheck)
      case (expected,result) of
        (Right (quantity,newAta,depositFee),Right proof)->do
          require (checkedSolanaAmount proof==quantity && (units (checkedSolanaRent proof)>0)==newAta
            && checkedSolanaDepositFee proof==depositFee) ("admission_probe_"<>name<>"_result_mismatch")
          pure $ object ["case" .= (name::Text),"accepted" .= True,"evidence" .= proof]
        (Left code,Left (BridgeError actual))->do
          require (actual==code) "admission_probe_refusal_mismatch"
          pure $ object ["case" .= name,"accepted" .= False,"error" .= actual]
        (_,Left (BridgeError code))->reject ("admission_probe_"<>name<>"_"<>code)
        _->reject "admission_probe_unexpected_acceptance"
    after<-balances manager c
    require (before==after) "admission_probe_changed_balances"
    methods<-readIORef calls
    count<-readIORef simulations
    recorded<-getCurrentTime
    LBS.putStrLn $ encode $ object ["recordedUtc" .= recorded,"network" .= ("solana-devnet"::Text)
      ,"genesis" .= solanaGenesis (profile c),"mint" .= mint c,"checks" .= results,"rpcMethods" .= methods
      ,"simulationsWithZeroSignature" .= count,"helperHasSignerConfigured" .= False
      ,"balancesUnchanged" .= True,"balances" .= before,"broadcast" .= False,"ordersCreated" .= (0::Int)
      ,"ledgerSchema" .= schemaVersion
      ,"scope" .= ("Actual Devnet account/fee/rent reads and unsigned simulation; no account creation, order or transaction sent. The new-ATA case is simulation only. Browser signing remains a separate gate."::Text)]

-- This configuration cannot authorize custody signing even if the probe calls
-- the wrong helper verb. It contains public deployment identities only.
withUnsignedConfig :: Config -> (Config -> IO a) -> IO a
withUnsignedConfig c action=bracket acquire removePathForcibly $ \dir -> do
  let path=dir</>"helper.json"
  LBS.writeFile path $ encode $ object ["deployment_id" .= deploymentId c,"mint" .= mint c
    ,"custody_owner" .= custodyOwner c,"signer_path" .= Null]
  setFileMode path 0o600
  action c{helperConfig=path}
 where
  acquire=do
    base<-getTemporaryDirectory
    ident<-randomId
    let dir=base</>("ecx-unsigned-admission-"<>T.unpack ident)
    createDirectory dir
    setFileMode dir 0o700
    pure dir

balances :: Manager -> Config -> IO Value
balances manager c=do
  (_,values)<-solanaCall manager c "getMultipleAccounts"
    [toJSON [custodyAta c,custodyOwner c,"GQnRnfs2B9j6pymrbY4KmX9WnAQ6czPAdt2u6XpWZSjQ"::Text
      ,"HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg","3psSKHRPopKXPcBajcm2crjoKzrUtWyfsqeprTRMxAqZ"]
    ,object ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]] >>= contextValue 0
  accounts<-parseValue parseJSON values
  case accounts of
    [custody,payer,tester,owner,setup]->do
      tokens<-either reject pure $ inspectTokenAccount (mint c) (custodyOwner c) custody
      sol<-systemLamports payer
      testerTokens<-either reject pure $ inspectTokenAccount (mint c) "HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg" tester
      testerSol<-systemLamports owner
      setupSol<-systemLamports setup
      pure $ object ["custodyTokens" .= tokens,"custodySol" .= sol,"testerTokens" .= testerTokens
        ,"testerSol" .= testerSol,"setupSol" .= setupSol]
    _->reject "admission_balance_snapshot_incomplete"
