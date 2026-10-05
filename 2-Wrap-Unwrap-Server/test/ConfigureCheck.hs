module ConfigureCheck (contract) where
import qualified Bridge.Config as C
import Bridge.AdminKey (savePrivate)
import Bridge.SolanaMessage (base58)
import Control.Exception (bracket)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import Data.Aeson (encode)
import Data.Bits ((.&.))
import System.Directory
import System.FilePath ((</>))
import System.IO (openTempFile,hClose)
import System.Posix.Files (setFileMode,getFileStatus,fileMode)
import System.Process
import System.Exit (ExitCode(..))

-- Real executable, disposable private keys, no network/database/service changes.
contract :: IO Bool
contract=bracket temporary removeDirectoryRecursive $ \directory->do
  Just executable<-findExecutable "ecx-bridge"
  let seed=B.replicate 32 7
  secret<-case Ed.secretKey seed of CryptoPassed key->pure key; _->fail "test key"
  let public=BA.convert(Ed.toPublic secret)::B.ByteString
      owner=T.unpack(base58 public)
      history=T.unpack(base58 $ B.replicate 64 1)
      run input=readCreateProcessWithExitCode ((proc executable ["configure"]) {cwd=Just directory}) input
      key=directory</>"key.json"; worker=directory</>"worker.auth"; signer=directory</>"signer.auth"
  savePrivate key (L.toStrict $ encode $ B.unpack(seed<>public))
  savePrivate worker "worker:password";savePrivate signer "signer:password"
  -- Field order is explicitly sorted, and booleans/numbers retain their JSON types.
  let fields=["false","1200",owner,owner,"test-deployment","100000","10000","1000"
        ,"invalid-number","4","2100000","10000000","10000","10000",owner
        ,"00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
        ,"16000","1","http://127.0.0.1:29432","test-wallet","300","8080","8081"
        ,history,history,"https://api.devnet.solana.com","-"]
      answers=["","L2LSignetDevnet"]<>fields<>["no","yes","installer","release.pem","candidate",key,worker,signer,"-","-","-","-","-","-","no"]
  (code,_,_)<-run (unlines answers)
  if code/=ExitSuccess then pure False else do
    let out=directory</>".ecx-bridge"
    config<-C.loadConfig(out</>"worker.json")
    other<-C.loadConfig(out</>"signer.json")
    modes<-mapM (fmap ((.&. 0o777) . fileMode) . getFileStatus . (out</>)) ["worker.json","signer.json","setup.json","solana.keypair.json"]
    before<-B.readFile(out</>"worker.json")
    (again,_,_)<-run "\n"
    after<-B.readFile(out</>"worker.json")
    (cancelled,_,_)<-run ((directory</>"cancelled")<>"\n")
    partial<-doesDirectoryExist(directory</>"cancelled")
    pure(C.fingerprint config==C.fingerprint other && C.nativeCookie config/=C.nativeCookie other
      && all(==0o600)modes && before==after && again/=ExitSuccess && cancelled/=ExitSuccess && not partial)
 where
  temporary=do
    parent<-getTemporaryDirectory
    (path,h)<-openTempFile parent "ecx-configure-test"
    hClose h;removeFile path;createDirectory path;setFileMode path 0o700
    pure path
