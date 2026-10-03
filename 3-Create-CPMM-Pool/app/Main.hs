module Main (main) where
import Pool
import qualified Pool.Operation as O
import qualified Pool.Signing as S
import qualified Pool.Position as P
import qualified Pool.Liquidity as Q
import Bridge.SDKBuild (sdkLibraryPath)
import Data.Aeson (FromJSON,encode,eitherDecode,object,(.=),withObject,(.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.Text as T
import System.Environment (getArgs)
import Text.Read (readMaybe)
import Data.Word (Word16,Word64)
import System.Exit (die)
import System.IO (withBinaryFile,IOMode(ReadMode))
main :: IO ()
main=getArgs >>= \args->case args of
  ["quote-mainnet",poolKey,a,b,inputA,inputB]->do
    x<-amount inputA; y<-amount inputB
    quotes<-mapM (O.runSafe . O.Request)
      [QuoteMainnet (Expected (T.pack poolKey) (T.pack a) (T.pack b)) x
      ,QuoteMainnet (Expected (T.pack poolKey) (T.pack b) (T.pack a)) y]
    L.putStrLn (encode quotes)
  ["sign-liquidity",endpoint,fee,cost,path,key,output]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    (O.runCritical . O.Request) (S.Sign sdkLibraryPath selected endpoint feeLimit costLimit (S.Liquidity request prepared) [key] output) >>= L.putStrLn . encode
  ["check-liquidity",endpoint,fee,cost,path]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    (O.runSafe . O.Request) (Q.Check sdkLibraryPath selected endpoint feeLimit costLimit request prepared) >>= L.putStrLn . encode
  ["prepare-liquidity",network,path]->do
    _<-choose network
    request<-readJSON path
    prepared<-(O.runSafe . O.Request) (Q.Prepare sdkLibraryPath request)
    L.putStrLn $ encode $ object ["network" .= network,"request" .= request,"prepared" .= prepared]
  ["prepare-position",network,path]->do
    _<-choose network
    request<-readJSON path
    prepared<-(O.runSafe . O.Request) (P.Prepare sdkLibraryPath request)
    L.putStrLn $ encode $ object ["network" .= network,"request" .= request,"prepared" .= prepared]
  ["check-position",endpoint,fee,cost,path]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    (O.runSafe . O.Request) (P.Check sdkLibraryPath selected endpoint feeLimit costLimit request prepared) >>= \debit->L.putStrLn $ encode $ object ["maximumDebit" .= show debit]
  ["sign-position",endpoint,fee,cost,path,payerKey,mintKey,output]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    (O.runCritical . O.Request) (S.Sign sdkLibraryPath selected endpoint feeLimit costLimit (S.Opening request prepared) [payerKey,mintKey] output) >>= L.putStrLn . encode
  ["sign",endpoint,fee,cost,path,payerKey,vaultAKey,vaultBKey,output]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    (O.runCritical . O.Request) (S.Sign sdkLibraryPath selected endpoint feeLimit costLimit (S.Creation request prepared) [payerKey,vaultAKey,vaultBKey] output) >>= L.putStrLn . encode
  ["submit",endpoint,path]->(O.runCritical . O.Request) (S.Submit sdkLibraryPath endpoint path) >>= L.putStrLn . encode
  ["check",endpoint,fee,cost,path]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    (O.runSafe . O.Request) (Check sdkLibraryPath selected endpoint feeLimit costLimit request prepared) >>= L.putStrLn . encode
  ["prepare",network,path]->do
    selected<-choose network
    request<-readJSON path
    prepared<-(O.runSafe . O.Request) (Prepare sdkLibraryPath selected request)
    L.putStrLn $ encode $ object ["network" .= network,"request" .= request,"prepared" .= prepared]
  ["address",network,a,b,index]->do
    selected<-choose network
    tier<-case readMaybe index :: Maybe Integer of
      Just n | n>=0 && n<=65535 && show n==index->pure(fromInteger n :: Word16)
      _->die "Invalid fee-tier index"
    (O.runSafe . O.Request) (Address sdkLibraryPath selected (T.pack a) (T.pack b) tier) >>= L.putStrLn . encode
  ["inspect",network,endpoint,pool,a,b]->choose network >>= \selected->(O.runSafe . O.Request) (Inspect sdkLibraryPath selected endpoint (Expected (T.pack pool) (T.pack a) (T.pack b))) >>= L.putStrLn . encode
  _->die "Usage: ecx-pool quote-mainnet POOL MINT_A MINT_B AMOUNT_A AMOUNT_B | sign-liquidity HTTPS_RPC MAX_FEE MAX_COST PREPARED.json OWNER_KEY NEW_ATTEMPT.json | check-liquidity HTTPS_RPC MAX_FEE MAX_COST PREPARED.json | prepare-liquidity devnet|mainnet REQUEST.json | sign-position HTTPS_RPC MAX_FEE MAX_COST PREPARED.json PAYER_KEY POSITION_MINT_KEY NEW_ATTEMPT.json | prepare-position devnet|mainnet REQUEST.json | check-position HTTPS_RPC MAX_FEE MAX_COST PREPARED.json | sign HTTPS_RPC MAX_FEE MAX_COST PREPARED.json PAYER_KEY VAULT_A_KEY VAULT_B_KEY NEW_ATTEMPT.json | submit HTTPS_RPC ATTEMPT.json | check HTTPS_RPC MAX_FEE MAX_COST PREPARED.json | prepare devnet|mainnet REQUEST.json | address devnet|mainnet MINT_A MINT_B FEE_TIER_INDEX | inspect devnet|mainnet HTTPS_RPC POOL MINT_A MINT_B (mints in byte order; read-only)"
choose :: String -> IO Network
choose "devnet"=pure Devnet
choose "mainnet"=pure Mainnet
choose _=die "Choose devnet or mainnet explicitly"

amount :: String -> IO Word64
amount text=case readMaybe text :: Maybe Integer of
  Just n | n>0 && n<=toInteger(maxBound::Word64) && show n==text->pure(fromInteger n)
  _->die "Expected canonical positive base-unit quantity"

readPrepared :: (FromJSON r,FromJSON p) => FilePath -> IO (Network,r,p)
readPrepared path=do
  value<-readJSON path
  (network,request,prepared)<-either die pure $ parseEither (withObject "preparation" $ \o->do
    if length o/=3 then fail "Unexpected preparation fields" else pure ()
    (,,) <$> o .: "network" <*> o .: "request" <*> o .: "prepared") value
  selected<-choose network
  pure(selected,request,prepared)

readJSON :: FromJSON a => FilePath -> IO a
readJSON path=do
  bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
  if B.length bytes>8192 then die "Input too large" else pure ()
  either die pure $ eitherDecode (L.fromStrict bytes)
