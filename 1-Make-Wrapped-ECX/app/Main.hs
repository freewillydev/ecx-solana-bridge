module Main (main) where
import Token
import qualified Token.Operation as O
import Data.Text (Text)
import qualified Data.Text as T
import qualified Token.Network as Network
import Text.Read (readMaybe)
import Data.Word (Word64)
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
  ["keygen",output]->(O.runCritical . O.Request) (GenerateKey output) >>= L.putStrLn . encode
  ["associated-address",recipient,key]->(O.runSafe . O.Request) (AssociatedAddress sdkLibraryPath (T.pack recipient) (T.pack key)) >>= L.putStrLn . encode
  ["metadata-address",key]->(O.runSafe . O.Request) (MetadataAddress sdkLibraryPath $ T.pack key) >>= L.putStrLn . encode
  ["address",owner,label]->(O.runSafe . O.Request) (MintAddress (T.pack owner) (T.pack label)) >>= L.putStrLn . encode
  ["prepare",path]->do
    bytes<-readBounded path
    request<-either die pure (eitherDecodeStrict' bytes)
    transaction<-(O.runSafe . O.Request) (Prepare sdkLibraryPath request)
    L.putStrLn $ encode $ object ["request" .= request,"unsignedTransaction" .= transaction]
  ["check",network,endpoint,limit,prepared]->do
    selected<-case network of "devnet"->pure Network.Devnet; "mainnet"->pure Network.Mainnet; _->die "Choose devnet or mainnet"
    feeLimit<-readFee limit
    (request,unsigned)<-readPrepared prepared
    fee<-(O.runSafe . O.Request) (Network.Check selected endpoint feeLimit request unsigned)
    L.putStrLn $ encode $ object ["feeLamports" .= fee,"simulationOnly" .= True]
  ["submit",network,endpoint,limit,attempt]->do
    selected<-case network of "devnet"->pure Network.Devnet; "mainnet"->pure Network.Mainnet; _->die "Choose devnet or mainnet"
    feeLimit<-readFee limit
    result<-(O.runCritical . O.Request) (Network.Submit selected endpoint feeLimit attempt)
    L.putStrLn (encode result)
  ["sign",prepared,keyfile,output]->do
    (request,unsigned)<-readPrepared prepared
    identifier<-(O.runCritical . O.Request) (Sign keyfile output request unsigned)
    L.putStrLn $ encode $ object ["signature" .= identifier,"saved" .= output]
  _->die "Usage: ecx-token keygen NEW_PRIVATE_KEY.json | associated-address OWNER MINT | metadata-address MINT | address AUTHORITY SEED | prepare REQUEST.json | check devnet|mainnet HTTPS_RPC MAX_FEE PREPARED.json | submit devnet|mainnet HTTPS_RPC MAX_FEE ATTEMPT.json | sign PREPARED.json AUTHORITY_KEY.json NEW_ATTEMPT.json (prepare/check/sign never broadcast; submit sends saved bytes)"

readFee :: String -> IO Word64
readFee raw=case readMaybe raw :: Maybe Integer of
  Just n | n>0 && n<=toInteger(maxBound::Word64) && show n==raw->pure(fromInteger n)
  _->die "Invalid fee ceiling"

readBounded :: FilePath -> IO B.ByteString
readBounded path=do
  bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
  if B.length bytes>8192 then die "Request exceeds 8192 bytes" else pure bytes

readPrepared :: FilePath -> IO (Request,Text)
readPrepared path=do
  bytes<-readBounded path
  value<-either die pure (eitherDecodeStrict' bytes)
  either die pure $ parseEither (withObject "prepared token operation" $ \o->do
    unless (length o==2) (fail "Unexpected prepared-operation fields")
    (,) <$> o .: "request" <*> o .: "unsignedTransaction") value
