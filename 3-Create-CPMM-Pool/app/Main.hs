module Main (main) where
import Pool
import Bridge.SDKBuild (sdkLibraryPath)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.Text as T
import System.Environment (getArgs)
import Text.Read (readMaybe)
import Data.Word (Word16)
import System.Exit (die)
main :: IO ()
main=getArgs >>= \args->case args of
  ["address",network,a,b,index]->do
    selected<-choose network
    tier<-case readMaybe index :: Maybe Integer of
      Just n | n>=0 && n<=65535 && show n==index->pure(fromInteger n :: Word16)
      _->die "Invalid fee-tier index"
    evalSafe (Address sdkLibraryPath selected (T.pack a) (T.pack b) tier) >>= L.putStrLn . encode
  ["inspect",network,endpoint,pool,a,b]->choose network >>= \selected->evalSafe (Inspect sdkLibraryPath selected endpoint (Expected (T.pack pool) (T.pack a) (T.pack b))) >>= L.putStrLn . encode
  _->die "Usage: ecx-pool address devnet|mainnet MINT_A MINT_B FEE_TIER_INDEX | inspect devnet|mainnet HTTPS_RPC POOL MINT_A MINT_B (mints in byte order; read-only)"
choose :: String -> IO Network
choose "devnet"=pure Devnet
choose "mainnet"=pure Mainnet
choose _=die "Choose devnet or mainnet explicitly"
