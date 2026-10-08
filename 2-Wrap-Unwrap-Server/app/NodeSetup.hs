-- One-time local node provisioning, never a worker/signer runtime capability.
module NodeSetup (credentials,checkConfig,serviceName,provision) where
import Bridge.AdminKey (savePrivate,readPrivate,withFamily)
import Bridge.File (withHandle)
import System.IO (hFlush)
import Bridge.Error
import Bridge.RPC (fieldValue)
import Bridge.SolanaMessage (base58)
import Crypto.Random (getRandomBytes)
import Crypto.MAC.HMAC (hmac,HMAC)
import Crypto.Hash (SHA256)
import qualified Data.ByteArray.Encoding as Hex
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as T
import Data.Aeson (Value,eitherDecodeStrict')
import Control.Exception (bracket)
import System.Posix.IO (openFd,closeFd,OpenMode(ReadOnly,WriteOnly),defaultFileFlags,OpenFileFlags(..))
import System.Posix.Unistd (fileSynchronise)
import Control.Monad (forM,unless,when)
import System.Directory (doesFileExist,renameFile)
import System.FilePath ((</>),takeDirectory)
import System.Posix.Files
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))
import Data.Bits ((.&.))

serviceName :: String -> IO String
serviceName name=do
  require (not(null name) && take 1 name/="-" && length name<128
    && all (`elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@"::String)) name) "invalid_node_service"
  pure name

checkConfig :: FilePath -> IO ()
checkConfig path=do
  status<-getSymbolicLinkStatus path
  parent<-getFileStatus (takeDirectory path)
  require (isRegularFile status && linkCount status==1 && fileMode status .&. 0o022==0
    && isDirectory parent && fileMode parent .&. 0o022==0 && fileSize status<=8192) "unsafe_node_configuration"

credentials :: FilePath -> IO (FilePath,FilePath,FilePath)
credentials directory=do
  rows<-forM [("admin",adminMethods),("worker",workerMethods),("signer",signerMethods)] $ \(role,methods)->do
    password<-base58 <$> getRandomBytes 32
    salt<-base58 <$> getRandomBytes 16
    suffix<-base58 <$> getRandomBytes 8
    let user="ecx_"<>role<>"_"<>T.unpack suffix
        credential=directory</>"native-"<>role<>".auth"
        digest=B8.unpack (Hex.convertToBase Hex.Base16 (hmac (B8.pack $ T.unpack salt) (B8.pack $ T.unpack password)::HMAC SHA256))
        rule="rpcauth="<>user<>":"<>T.unpack salt<>"$"<>digest<>"\nrpcwhitelist="<>user<>":"<>methods<>"\n"
    savePrivate credential (B8.pack $ user<>":"<>T.unpack password)
    pure (credential,rule)
  savePrivate (directory</>"native-rpc.conf") (B8.pack $ concatMap snd rows)
  case map fst rows of
    [admin,worker,signer]->pure(admin,worker,signer)
    _->reject "invalid_generated_credentials"

-- Preserve the node's existing configuration and authority defaults. Refuse
-- complex include trees instead of silently changing another RPC user's rights.
provision :: FilePath -> IO ()
provision directory=do
  setup<-decode =<< readPrivate (directory</>"setup.json")
  generated<-doesFileExist (directory</>"native-rpc.conf")
  when generated $ withFamily (directory</>"node-provision") $ do
    path<-fieldValue "nodeConfig" setup
    service<-fieldValue "nodeService" setup >>= serviceName
    checkConfig path
    (loaded,_,_)<-readProcessWithExitCode "systemctl" ["cat",service] ""
    require (loaded==ExitSuccess) "node_service_not_found_edit_setup_before_start"
    let original=directory</>"node-config.before"
    saved<-doesFileExist original
    unless saved $ do
      bytes<-B.readFile path
      require (not $ any ((=="includeconf") . option) $ B8.lines bytes) "node_include_tree_requires_advanced_configuration"
      savePrivate original bytes
    before<-readPrivate original
    rules<-readPrivate (directory</>"native-rpc.conf")
    let settings=map option $ B8.lines before
        priorWhitelist="rpcwhitelist" `elem` settings
        explicitDefault="rpcwhitelistdefault" `elem` settings
        -- Without any prior whitelist the old node allowed authenticated users;
        -- preserve that default while explicitly restricting all three new users.
        preserve=if not priorWhitelist && not explicitDefault then "rpcwhitelistdefault=0\n" else ""
        expected="# Generated ECX bridge RPC roles\n"<>preserve<>rules<>"\n"<>before
    current<-B.readFile path
    require (current==before || current==expected) "node_configuration_changed_review_before_retry"
    let candidate=directory</>"node-config.after"
    candidateExists<-doesFileExist candidate
    if candidateExists then readPrivate candidate >>= \bytes->require (bytes==expected) "node_configuration_candidate_changed"
      else savePrivate candidate expected
    when (current/=expected) $ do
      status<-getFileStatus path
      nonce<-base58 <$> getRandomBytes 8
      let staging=path<>".ecx-bridge-"<>T.unpack nonce
      bracket (openFd staging WriteOnly defaultFileFlags {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True}) closeFd $ \fd->do
        withHandle fd $ \handle->B.hPut handle expected >> hFlush handle
        setFdOwnerAndGroup fd (fileOwner status) (fileGroup status)
        setFdMode fd (fileMode status .&. 0o777)
        fileSynchronise fd
      renameFile staging path
      sync (takeDirectory path)
    let marker=directory</>"node-rpc-installed"
    restarted<-doesFileExist marker
    unless restarted $ do
      putStrLn "Installing distinct node RPC roles; restarting the configured ECX node service."
      (result,_,_)<-readProcessWithExitCode "systemctl" ["restart",service] ""
      require (result==ExitSuccess) "node_restart_failed_original_configuration_preserved"
      savePrivate marker "installed\n"
 where
  sync path=bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise
  option=B8.strip . B8.takeWhile (/='=')
  decode bytes=either (const $ reject "invalid_setup_json") pure (eitherDecodeStrict' bytes::Either String Value)

readMethods,workerMethods,signerMethods,adminMethods :: String
readMethods="getblockchaininfo,getblockhash,getblockheader,getnetworkinfo,getconnectioncount,getwalletinfo,getbalances,getaddressinfo,gettransaction,gettxout,gettxspendingprevout,getmempoolentry,listsinceblock,listunspent,listlockunspent,decodepsbt,decoderawtransaction,decodescript,estimatesmartfee,getmempoolinfo"
workerMethods=readMethods<>",getnewaddress,getaddressesbylabel,getrawchangeaddress,walletcreatefundedpsbt,lockunspent,createpsbt,testmempoolaccept,sendrawtransaction"
signerMethods=readMethods<>",walletcreatefundedpsbt,createpsbt,walletprocesspsbt,finalizepsbt,walletpassphrase,walletlock,backupwallet,listdescriptors"
adminMethods=readMethods<>",getdescriptorinfo,deriveaddresses,listwalletdir,createwallet,importdescriptors,listdescriptors,getnewaddress,walletpassphrase,walletlock"
