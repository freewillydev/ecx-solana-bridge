module Main (main) where
import Pool
import Bridge.SDKBuild (sdkLibraryPath)
import Data.Aeson (encode,eitherDecode,object,(.=),withObject,(.:))
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
  ["check",endpoint,fee,cost,path]->do
    bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
    if B.length bytes>8192 then die "Preparation too large" else pure ()
    (network,request,prepared)<-either die pure $ eitherDecode (L.fromStrict bytes) >>= parseEither (withObject "preparation" $ \o->(,,) <$> o .: "network" <*> o .: "request" <*> o .: "prepared")
    selected<-choose network
    feeLimit<-amount fee; costLimit<-amount cost
    evalSafe (Check sdkLibraryPath selected endpoint feeLimit costLimit request prepared) >>= L.putStrLn . encode
  ["prepare",network,path]->do
    selected<-choose network
    request<-L.readFile path >>= either die pure . eitherDecode
    prepared<-evalSafe (Prepare sdkLibraryPath selected request)
    L.putStrLn $ encode $ object ["network" .= network,"request" .= request,"prepared" .= prepared]
  ["address",network,a,b,index]->do
    selected<-choose network
    tier<-case readMaybe index :: Maybe Integer of
      Just n | n>=0 && n<=65535 && show n==index->pure(fromInteger n :: Word16)
      _->die "Invalid fee-tier index"
    evalSafe (Address sdkLibraryPath selected (T.pack a) (T.pack b) tier) >>= L.putStrLn . encode
  ["inspect",network,endpoint,pool,a,b]->choose network >>= \selected->evalSafe (Inspect sdkLibraryPath selected endpoint (Expected (T.pack pool) (T.pack a) (T.pack b))) >>= L.putStrLn . encode
  _->die "Usage: ecx-pool check HTTPS_RPC MAX_FEE MAX_COST PREPARED.json | prepare devnet|mainnet REQUEST.json | address devnet|mainnet MINT_A MINT_B FEE_TIER_INDEX | inspect devnet|mainnet HTTPS_RPC POOL MINT_A MINT_B (mints in byte order; read-only)"
choose :: String -> IO Network
choose "devnet"=pure Devnet
choose "mainnet"=pure Mainnet
choose _=die "Choose devnet or mainnet explicitly"

amount :: String -> IO Word64
amount text=case readMaybe text :: Maybe Integer of
  Just n | n>0 && n<=toInteger(maxBound::Word64) && show n==text->pure(fromInteger n)
  _->die "Expected canonical positive lamport limit"
