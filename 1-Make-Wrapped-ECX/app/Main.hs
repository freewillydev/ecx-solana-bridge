module Main (main) where
import Token
import Bridge.SDKBuild (sdkLibraryPath)
import Data.Aeson (eitherDecodeStrict',encode,object,(.=))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as L
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (withBinaryFile,IOMode(ReadMode))

main :: IO ()
main=getArgs >>= \args->case args of
  ["prepare",path]->do
    bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
    if B.length bytes>8192 then die "Request exceeds 8192 bytes" else pure ()
    request<-either die pure (eitherDecodeStrict' bytes)
    transaction<-evalSafe (Prepare sdkLibraryPath request)
    L.putStrLn $ encode $ object ["request" .= request,"unsignedTransaction" .= transaction]
  _->die "Usage: ecx-token prepare REQUEST.json (unsigned mint/burn preview; no network or keys)"
