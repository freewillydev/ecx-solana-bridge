module Main (main) where
import Pool
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
  ["check-liquidity",endpoint,fee,cost,path]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    Q.evalSafe (Q.Check sdkLibraryPath selected endpoint feeLimit costLimit request prepared) >>= L.putStrLn . encode
  ["prepare-liquidity",network,path]->do
    _<-choose network
    request<-readJSON path
    prepared<-Q.evalSafe (Q.Prepare sdkLibraryPath request)
    L.putStrLn $ encode $ object ["network" .= network,"request" .= request,"prepared" .= prepared]
  ["prepare-position",network,path]->do
    _<-choose network
    request<-readJSON path
    prepared<-P.evalSafe (P.Prepare sdkLibraryPath request)
    L.putStrLn $ encode $ object ["network" .= network,"request" .= request,"prepared" .= prepared]
  ["check-position",endpoint,fee,cost,path]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    P.evalSafe (P.Check sdkLibraryPath selected endpoint feeLimit costLimit request prepared) >>= \cost->L.putStrLn $ encode $ object ["maximumDebit" .= show cost]
  ["sign-position",endpoint,fee,cost,path,payerKey,mintKey,output]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    S.evalCritical (S.Sign sdkLibraryPath selected endpoint feeLimit costLimit (S.Opening request prepared) [payerKey,mintKey] output) >>= L.putStrLn . encode
  ["sign",endpoint,fee,cost,path,payerKey,vaultAKey,vaultBKey,output]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    S.evalCritical (S.Sign sdkLibraryPath selected endpoint feeLimit costLimit (S.Creation request prepared) [payerKey,vaultAKey,vaultBKey] output) >>= L.putStrLn . encode
  ["submit",endpoint,path]->S.evalCritical (S.Submit sdkLibraryPath endpoint path) >>= L.putStrLn . encode
  ["check",endpoint,fee,cost,path]->do
    (selected,request,prepared)<-readPrepared path
    feeLimit<-amount fee; costLimit<-amount cost
    evalSafe (Check sdkLibraryPath selected endpoint feeLimit costLimit request prepared) >>= L.putStrLn . encode
  ["prepare",network,path]->do
    selected<-choose network
    request<-readJSON path
    prepared<-evalSafe (Prepare sdkLibraryPath selected request)
    L.putStrLn $ encode $ object ["network" .= network,"request" .= request,"prepared" .= prepared]
  ["address",network,a,b,index]->do
    selected<-choose network
    tier<-case readMaybe index :: Maybe Integer of
      Just n | n>=0 && n<=65535 && show n==index->pure(fromInteger n :: Word16)
      _->die "Invalid fee-tier index"
    evalSafe (Address sdkLibraryPath selected (T.pack a) (T.pack b) tier) >>= L.putStrLn . encode
  ["inspect",network,endpoint,pool,a,b]->choose network >>= \selected->evalSafe (Inspect sdkLibraryPath selected endpoint (Expected (T.pack pool) (T.pack a) (T.pack b))) >>= L.putStrLn . encode
  _->die "Usage: ecx-pool check-liquidity HTTPS_RPC MAX_FEE MAX_COST PREPARED.json | prepare-liquidity devnet|mainnet REQUEST.json | sign-position HTTPS_RPC MAX_FEE MAX_COST PREPARED.json PAYER_KEY POSITION_MINT_KEY NEW_ATTEMPT.json | prepare-position devnet|mainnet REQUEST.json | check-position HTTPS_RPC MAX_FEE MAX_COST PREPARED.json | sign HTTPS_RPC MAX_FEE MAX_COST PREPARED.json PAYER_KEY VAULT_A_KEY VAULT_B_KEY NEW_ATTEMPT.json | submit HTTPS_RPC ATTEMPT.json | check HTTPS_RPC MAX_FEE MAX_COST PREPARED.json | prepare devnet|mainnet REQUEST.json | address devnet|mainnet MINT_A MINT_B FEE_TIER_INDEX | inspect devnet|mainnet HTTPS_RPC POOL MINT_A MINT_B (mints in byte order; read-only)"
choose :: String -> IO Network
choose "devnet"=pure Devnet
choose "mainnet"=pure Mainnet
choose _=die "Choose devnet or mainnet explicitly"

amount :: String -> IO Word64
amount text=case readMaybe text :: Maybe Integer of
  Just n | n>0 && n<=toInteger(maxBound::Word64) && show n==text->pure(fromInteger n)
  _->die "Expected canonical positive lamport limit"

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
