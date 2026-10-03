module Main (main) where
import Token
import Token.Signing
import Control.Monad (unless)
import Bridge.SDKBuild (sdkLibraryPath)
import Data.Aeson (eitherDecodeStrict',encode,object,(.=),withObject,(.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as L
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (withBinaryFile,IOMode(ReadMode))

main :: IO ()
main=getArgs >>= \args->case args of
  ["prepare",path]->do
    bytes<-readBounded path
    request<-either die pure (eitherDecodeStrict' bytes)
    transaction<-evalSafe (Prepare sdkLibraryPath request)
    L.putStrLn $ encode $ object ["request" .= request,"unsignedTransaction" .= transaction]
  ["sign",prepared,keyfile,output]->do
    bytes<-readBounded prepared
    value<-either die pure (eitherDecodeStrict' bytes)
    (request,unsigned)<-either die pure $ parseEither (withObject "prepared token operation" $ \o->do
      unless (length o==2) (fail "Unexpected prepared-operation fields")
      (,) <$> o .: "request" <*> o .: "unsignedTransaction") value
    identifier<-evalCritical (Sign keyfile output request unsigned)
    L.putStrLn $ encode $ object ["signature" .= identifier,"saved" .= output]
  _->die "Usage: ecx-token prepare REQUEST.json | sign PREPARED.json AUTHORITY_KEY.json NEW_ATTEMPT.json (offline; never broadcasts)"

readBounded :: FilePath -> IO B.ByteString
readBounded path=do
  bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
  if B.length bytes>8192 then die "Request exceeds 8192 bytes" else pure bytes
