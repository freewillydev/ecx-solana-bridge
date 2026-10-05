module Main (main) where
import Token
import qualified Token.Operation as O
import qualified Token.Network as Network
import qualified Data.Text as T
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import Text.Read (readMaybe)
import Data.Word (Word64)
import Token.Signing
import Control.Monad (unless,foldM)
import Control.Exception (bracketOnError,finally,catches,Handler(..))
import Bridge.SDKBuild (sdkLibraryPath)
import Bridge.Error (BridgeError(..))
import Network.HTTP.Client (HttpException)
import Data.Aeson (FromJSON,Key,Object,Value(..),eitherDecodeStrict',encode,object,(.=),withObject,(.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Char8 as L
import System.Directory (makeAbsolute,doesFileExist,renameFile,removeFile)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (withBinaryFile,IOMode(ReadMode),stdout,hFlush,openBinaryTempFile,hClose)

main :: IO ()
main=run `catches`
  [Handler $ \(BridgeError code)->die(T.unpack code)
  ,Handler $ \(_ :: HttpException)->die "rpc_transport_unknown_outcome"]

run :: IO ()
run=getArgs >>= \args->case args of
  ["configure"]->configure
  ["keygen",key]->makeAbsolute key >>= \output->
    (O.runCritical . O.Request) (GenerateKey output) >>= L.putStrLn . encode
  ["sign",key,transaction]->do
    keyfile<-makeAbsolute key
    input<-makeAbsolute transaction
    dispatch "sign" keyfile (Just input)
  [command,key] | command/="sign" && command `elem` map fst commands->makeAbsolute key >>= \keyfile->dispatch command keyfile Nothing
  _->die "Usage: ecx-token configure | ecx-token sign KEYFILE TRANSACTION.json | ecx-token COMMAND KEYFILE (commands: keygen, prepare, check, submit, recover, status, inspect-policy, address, associated-address, metadata-address; settings: ./ecx-token.json)"

commands :: [(String,[Key])]
commands=
  [("prepare",["requestFile"]),("check",["network","rpc","maxFeeLamports","preparedFile"])
  ,("sign",["network","rpc","maxFeeLamports","attemptFile"])
  ,("submit",["network","rpc","maxFeeLamports","attemptFile"])
  ,("recover",["rpc","verifierRpc","attemptFile"]),("status",["network","rpc","attemptFile"])
  ,("inspect-policy",["network","rpc","verifierRpc","mint","owner","custodyAta","mintAuthority"])
  ,("address",["owner","seed"]),("associated-address",["owner","mint"]),("metadata-address",["mint"])]

configure :: IO ()
configure=do
  exists<-doesFileExist "ecx-token.json"
  previous<-if exists then readConfiguration else pure KM.empty
  putStrLn "Configure an operation; existing settings are retained. No keys or transactions are used."
  putStrLn $ "Commands: "<>unwords(map fst commands)
  selected<-prompt "Command" ""
  fields<-maybe (die "Unknown token command") pure (lookup selected commands)
  settings<-foldM (\current name->do
    let old=case KM.lookup name current of
          Just(String text)->T.unpack text
          _->if name=="maxFeeLamports" then "10000" else ""
    let label=if name=="network" then "network (devnet = test coins, mainnet = real SOL/tokens)" else K.toString name
    raw<-prompt label old
    unless (not(null raw)) (die "A value is required")
    case name of
      "network"->choose raw >> pure ()
      "maxFeeLamports"->readFee raw >> pure ()
      _->pure ()
    pure (KM.insert name (String $ T.pack raw) current)) previous fields
  let bytes=encode (Object settings)
  unless (L.length bytes<=8192) (die "Configuration exceeds 8192 bytes")
  bracketOnError (openBinaryTempFile "." ".ecx-token-")
    (\(path,handle)->hClose handle `finally` removeFile path) $ \(path,handle)->do
      L.hPut handle bytes; hClose handle; renameFile path "ecx-token.json"
  putStrLn "Saved ecx-token.json. No transaction was signed or submitted."
  where
    prompt label old=do
      putStr (label<>(if null old then "" else " ["<>old<>"]")<>": ")
      hFlush stdout
      value<-getLine
      pure (if null value then old else value)

readConfiguration :: IO Object
readConfiguration=do
  bytes<-readBounded "ecx-token.json"
  value<-either die pure (eitherDecodeStrict' bytes)
  either die pure $ parseEither (withObject "ecx-token configuration" $ \o->do
    unless (all (`elem` concatMap snd commands) (KM.keys o))
      (fail "Unexpected configuration field; keep the key in KEYFILE")
    pure o) value

dispatch :: String -> FilePath -> Maybe FilePath -> IO ()
dispatch command key transactionFile=do
  config<-readConfiguration
  let field :: FromJSON a => Key -> IO a
      field name=either die pure (parseEither (.: name) config)
      path name=field name >>= makeAbsolute
      network=field "network" >>= choose
      fee=field "maxFeeLamports" >>= readFee
  case command of
    "status"->do
      operation<-Network.InspectSaved <$> network <*> field "rpc" <*> path "attemptFile"
      (O.runSafe . O.Request) operation >>= L.putStrLn . encode
    "inspect-policy"->do
      selected<-network; primary<-field "rpc"; verifier<-field "verifierRpc"
      mintKey<-field "mint"; owner<-field "owner"; custody<-field "custodyAta"; issuer<-field "mintAuthority"
      let expected=if issuer=="revoked" then Nothing else Just issuer
      readings<-(O.runSafe . O.Request) (Network.InspectPolicy selected primary verifier mintKey owner custody expected)
      L.putStrLn $ encode $ object ["network" .= (if selected==Network.Devnet then "devnet"::String else "mainnet"),"mint" .= mintKey,"custodyOwner" .= owner,"custodyAta" .= custody,"mintAuthority" .= expected,
        "readings" .= [object ["finalizedSlot" .= slot,"supplyBaseUnits" .= show supply,"custodyBaseUnits" .= show balance] | (slot,supply,balance)<-readings]]
    "associated-address"->do
      operation<-AssociatedAddress sdkLibraryPath <$> field "owner" <*> field "mint"
      (O.runSafe . O.Request) operation >>= L.putStrLn . encode
    "metadata-address"->field "mint" >>= \mintKey->(O.runSafe . O.Request) (MetadataAddress sdkLibraryPath mintKey) >>= L.putStrLn . encode
    "address"->do
      operation<-MintAddress <$> field "owner" <*> field "seed"
      (O.runSafe . O.Request) operation >>= L.putStrLn . encode
    "prepare"->do
      input<-path "requestFile" >>= readBounded
      request<-either die pure (eitherDecodeStrict' input)
      transaction<-(O.runSafe . O.Request) (Prepare sdkLibraryPath request)
      L.putStrLn $ encode $ object ["request" .= request,"unsignedTransaction" .= transaction]
    "check"->do
      selected<-network; endpoint<-field "rpc"; limit<-fee
      (request,unsigned)<-path "preparedFile" >>= readPrepared
      cost<-(O.runSafe . O.Request) (Network.Check selected endpoint limit request unsigned)
      L.putStrLn $ encode $ object ["feeLamports" .= cost,"simulationOnly" .= True]
    "sign"->do
      selected<-network; endpoint<-field "rpc"; limit<-fee
      input<-maybe (die "sign requires TRANSACTION.json") pure transactionFile
      requestBytes<-readBounded input
      intent<-either die pure (eitherDecodeStrict' requestBytes)
      recent<-(O.runSafe . O.Request) (Network.RecentBlockhash selected endpoint)
      request<-either die pure (parseEither (parseIntent recent) intent)
      unsigned<-(O.runSafe . O.Request) (Prepare sdkLibraryPath request)
      output<-path "attemptFile"
      identifier<-(O.runCritical . O.Request) (Network.Sign sdkLibraryPath selected endpoint limit request unsigned key output)
      L.putStrLn $ encode $ object ["signature" .= identifier,"saved" .= output]
    "submit"->do
      operation<-Network.Submit <$> network <*> field "rpc" <*> fee <*> path "attemptFile"
      (O.runCritical . O.Request) operation >>= L.putStrLn . encode
    "recover"->do
      primary<-field "rpc"; verifier<-field "verifierRpc"; attempt<-path "attemptFile"
      identifier<-(O.runCritical . O.Request) (Network.Recover sdkLibraryPath primary verifier attempt key)
      L.putStrLn $ encode $ object ["signature" .= identifier,"saved" .= (attempt<>".retry")]
    _->die "Unknown token command"

readFee :: String -> IO Word64
readFee raw=case readMaybe raw :: Maybe Integer of
  Just n | n>0 && n<=toInteger(maxBound::Word64) && show n==raw->pure(fromInteger n)
  _->die "Invalid fee ceiling"

readBounded :: FilePath -> IO B.ByteString
readBounded path=do
  bytes<-withBinaryFile path ReadMode (`B.hGet` 8193)
  if B.length bytes>8192 then die "Request exceeds 8192 bytes" else pure bytes

readPrepared :: FilePath -> IO (Request,T.Text)
readPrepared path=do
  bytes<-readBounded path
  value<-either die pure (eitherDecodeStrict' bytes)
  either die pure $ parseEither (withObject "prepared token operation" $ \o->do
    unless (length o==2) (fail "Unexpected prepared-operation fields")
    (,) <$> o .: "request" <*> o .: "unsignedTransaction") value

choose :: String -> IO Network.Network
choose "devnet"=pure Network.Devnet
choose "mainnet"=pure Network.Mainnet
choose _=die "Choose devnet or mainnet"
