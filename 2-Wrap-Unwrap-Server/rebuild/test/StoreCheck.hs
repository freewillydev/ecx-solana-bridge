{-# LANGUAGE DataKinds, GADTs, ScopedTypeVariables #-}
module Main (main) where
import qualified Bridge.Config as Config
import Paths_ecx_bridge_rebuild (getDataFileName)
import qualified Network.HTTP.Client as HTTP
import qualified Network.Socket as NS
import qualified System.Process as Process
import System.FilePath (takeDirectory,isAbsolute,(</>))
import qualified System.Posix.Directory as PD
import System.IO.Error (isDoesNotExistError)
import qualified Bridge.Store.Backup as Backup
import Crypto.Random (getRandomBytes)
import Control.Concurrent (threadDelay,forkIO,killThread)
import Bridge.Identity (capabilityHash,payInstruction,digest,publicKey)
import qualified Bridge.Wire as W
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson (encode,object,(.=),toJSON,Value(..),eitherDecodeStrict')
import Data.Profunctor.Product (p5,p6,p8,p9)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),CostLimits(..),PolicySnapshot(..))
import Bridge.Store
import Bridge.Signer
import Bridge.Recovery
import Bridge.Payment (payoutReference)
import qualified Bridge.Control as Control
import Bridge.Critical
import Bridge.Web (customerApplication)
import qualified Bridge.Operation.Internal as Op
import qualified Network.Wai as Wai
import qualified Network.Wai.Test as WaiTest
import Network.HTTP.Types (statusCode,status200)
import Bridge.Order
import qualified Bridge.Fence as Fence
import System.Directory (createDirectory,removeDirectoryRecursive,removeFile,findExecutable,listDirectory,renameFile,renameDirectory)
import System.IO (openTempFile,hClose,withFile,IOMode(WriteMode))
import System.Posix.Files (setFileMode)
import qualified System.Posix.Files as Posix
import Data.Bits ((.&.))
import qualified Bridge.NativePayment as NP
import Bridge.Error (BridgeError(..),reject)
import Bridge.Observer (ObserverSettings(..))
import Bridge.Reconciliation (inspectCustodyWith,nativeBalance)
import Bridge.RPC (fieldValue,newRpcManager)
import Bridge.SigningTransport (SigningEndpoint(..),runSigningServer)
import qualified Bridge.SolanaPayment as SP
import qualified Network.Wai.Handler.Warp as Warp
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import Bridge.Operation.Internal (Request(..),SigningOperation(..),WorkerOperation(..))
import qualified Bridge.Native as N
import qualified Bridge.Solana as Solana
import qualified Bridge.SolanaHelper as H
import Network.HTTP.Client (newManager,closeManager,defaultManagerSettings,managerModifyRequest)
import qualified Bridge.Store.Schema as S
import Control.Exception
import Data.Int (Int64)
import Data.List (sort)
import Data.IORef
import GHC.Stack (HasCallStack,callStack,prettyCallStack)
import Test.QuickCheck (quickCheckWithResult,stdArgs,maxSuccess,forAll,chooseInteger,ioProperty,isSuccess)
import Control.Monad (unless,void,when,forM_)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import System.Exit (ExitCode(..))
import System.Environment (getEnv,lookupEnv,getEnvironment)

main :: IO ()
main = do
  live<-lookupEnv "ECX_REBUILD_LIVE_OBSERVER_CONFIG"
  setup<-lookupEnv "ECX_REBUILD_SETUP_ONLY"
  fence<-lookupEnv "ECX_REBUILD_FENCE_ONLY"
  server<-lookupEnv "ECX_REBUILD_SERVER_ONLY"
  tls<-lookupEnv "ECX_REBUILD_TLS_ONLY"
  native<-lookupEnv "ECX_REBUILD_NATIVE_RECOVERY_ONLY"
  case live of
    Just path->liveObserverMain path
    Nothing->if setup==Just "1" then setupMain else if native==Just "1" then nativeRecoveryMain else if tls==Just "1" then tlsMain else if fence==Just "1" then fenceMain else if server==Just "1" then serverMain else ledgerMain

-- Actual chain history, isolated ledger, and observation-only DSL authority.
-- No signer, customer deposit or treasury transfer is invoked by this contract.
liveObserverMain :: FilePath -> IO ()
liveObserverMain path=do
  supplied<-Config.loadConfig path
  unless (Config.profile supplied==W.L2LSignetDevnet) (reject "live_test_profile_required")
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  user<-getEnv "USER"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      check ok=unless ok (fail "live observer contract failed")
      temporary=do
        (directory,handle)<-openTempFile "/tmp" "ecx-live-observer"
        hClose handle; removeFile directory; PD.createDirectory directory 0o700
        pure directory
  bracket temporary removeDirectoryRecursive $ \directory->do
    let config=supplied {Config.fenceDirectory=directory </> "fence"}
        identity=Config.fingerprint config
        policy=Config.storePolicy config
        public=Config.publicConfiguration config (Config.defaultInterface $ Config.profile config) False
        customer=CustomerSettings public policy (Config.solanaSdkLibrary config)
    evalSetup settings (InitializeLedger identity)
    _<-evalRestore settings (AdoptLedger (Config.fenceDirectory config) identity 0)
    withReader settings {PG.connectUser=role} identity (Config.backupRequired config) $ \reader->
      withFencedWriter settings policy (Config.fenceDirectory config) $ \writer->
        bracket newRpcManager closeManager $ \manager->do
          N.verifyNativeBoundaryWith (N.nativeCall manager $ Config.nativeSettings config)
          decoded<-N.nativeCall manager (Config.nativeSettings config) False "decodescript" [String "00140000000000000000000000000000000000000000"]
          fieldValue "type" decoded >>= check . (==("witness_v0_keyhash"::T.Text))
          withRuntime manager (Config.observerSettings config) (Config.solanaPolicy config) (Just customer)
            (SigningEndpoint 1 "/unavailable-signer-credentials") reader writer $ \worker _ _->do
              let scan=do
                    worker (Request ObserveChains)
                    health<-bracket (PG.connect settings) PG.close (\c->fixture c LiveScanHealth)
                    check (map (\(chain,_,_)->chain) health==["Native","Solana","SolanaOperating"])
                    forM_ health $ \(_,at,problem)->do
                      maybe (pure ()) reject problem
                      check (at/=Nothing)
              scan
              balances<-evalRead reader ReadBalances
              scan
              evalRead reader ReadBalances >>= check . (==balances)
              evalRead reader PendingAttempts >>= check . null
              evalRead reader ReadState >>= check . ledgerPaused
              expectStore "observation_only" (worker $ Request $ SignPreparedPayment "forbidden")
              expectStore "observation_only" (worker $ Request $ BroadcastPayment "forbidden")
  putStrLn "PASS: real L2L Signet restricted RPC authority and Solana Devnet scans through rebuild DSL, persisted cursors, repeat accounting, paused ledger and signing/send refusal; no funds moved"

-- Production initialization on a fresh migrated database, with no seeded funds.
setupMain :: IO ()
setupMain=do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  user<-getEnv "USER"
  configPath<-getDataFileName "test/fixtures/deployment-config.json"
  config<-Config.loadConfig configPath
  binary<-getEnv "ECX_REBUILD_EXECUTABLE"
  environment<-getEnvironment
  residue<-lookupEnv "ECX_REBUILD_SETUP_RESIDUE"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      identity=Config.fingerprint config
      initialize=evalSetup settings (InitializeLedger identity)
      check ok=unless ok (fail "fresh initialization contract failed")
      run=do
        let overrides=[("PGHOST","/tmp/ecx-pg-seam"),("PGPORT","29436"),("PGDATABASE",database),("PGUSER",user),("PGPASSWORD","")]
        (code,_,_)<-Process.readCreateProcessWithExitCode (Process.proc binary ["initialize-ledger",configPath])
          {Process.env=Just $ overrides<>filter (not . T.isPrefixOf "PG" . T.pack . fst) environment} ""
        check (code==ExitSuccess)
  if residue==Just "1" then bracket (PG.connect settings) PG.close $ \fixtures->do
    fixture fixtures SetupResidue
    expectStore "initialization_requires_empty_ledger" initialize
    (rows,attempts,postings)<-fixture fixtures ArchiveRecords
    check (null rows && null attempts && null postings)
   else do
    expectStore "invalid_deployment_identity" (evalSetup settings $ InitializeLedger "invalid")
    run
    withReader settings {PG.connectUser=role} identity True $ \reader->do
      before<-evalRead reader ReadState
      check (before==LedgerState 0 0 True "installation_requires_reconciliation")
      evalRead reader ReadBalances >>= check . M.null
      evalRead reader PendingAttempts >>= check . null
      expectStore "intake_paused" (evalRead reader $ CheckIntake 100)
      run
      evalRead reader ReadState >>= check . (==before)
      expectStore "ledger_profile_or_schema_mismatch" (evalSetup settings $ InitializeLedger (T.replicate 64 "a"))
      withWriter settings (Config.storePolicy config) (const $ pure ()) $ \writer->do
        evalWrite writer (Pause "retained operator pause")
        expectStore "worker_already_running" initialize
      initialize
      after<-evalRead reader ReadState
      check (after==before {ledgerReason="retained operator pause"})
  putStrLn "PASS: production ledger setup, zero balances, paused intake, unchanged repeat, identity/worker conflict and residual-state refusal (selected mode)"

-- Real L2L Signet, using only fresh empty test-owned wallets. No funded wallet
-- is unloaded, changed or copied; the node remains running after this check.
nativeRecoveryMain :: IO ()
nativeRecoveryMain = do
  binary<-getEnv "ECX_REBUILD_EXECUTABLE"
  base<-getDataFileName "test/fixtures/deployment-config.json" >>= Config.loadConfig
  cookie<-getEnv "ECX_REBUILD_NATIVE_RECOVERY_COOKIE"
  walletDirectory<-getEnv "ECX_REBUILD_NATIVE_WALLET_DIRECTORY"
  unless (isAbsolute walletDirectory) (fail "absolute node wallet directory required")
  suffix<-digest <$> (getRandomBytes 16 :: IO BS.ByteString)
  let sourceName="ecx-recovery-"<>T.take 20 suffix
      targetName=sourceName<>"-restored"
      source=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" cookie sourceName
        16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
      target=source {N.nativeWallet=targetName}
      check ok=unless ok (fail "real native wallet recovery failed")
  bracket newRpcManager closeManager $ \manager->do
    let call config=N.nativeCall manager config
        cleanup name=do
          void (call source False "unloadwallet" [toJSON name,Bool False]) `catch` (\e@(BridgeError code)->
            if code=="rpc_error_-18" then pure () else throwIO e)
          removeDirectoryRecursive (walletDirectory </> T.unpack name) `catch` (\(e::IOException)->
            if isDoesNotExistError e then pure () else throwIO e)
        allocate label kind=call source True "getnewaddress" [String label,String kind] >>= \v->case v of
          String address->pure address; _->fail "expected native address"
    _<-N.nativeIdentity manager source
    bracket_ (void $ call source False "createwallet" [toJSON sourceName,Bool False,Bool False,String "",Bool False,Bool True,Bool False])
      (cleanup sourceName) $
      bracket (do (path,h)<-openTempFile "/tmp" "ecx-native-recovery"; hClose h; removeFile path; PD.createDirectory path 0o700; pure path)
        removeDirectoryRecursive $ \directory->do
        address<-allocate "recovery-label" "bech32"
        legacy<-allocate "recovery-signing-proof" "legacy"
        let sourceConfig=base {Config.nativeWallet=sourceName,Config.nativeCookie=cookie}
            targetConfig=sourceConfig {Config.nativeWallet=targetName}
            sourceFile=directory </> "source.json"
            targetFile=directory </> "target.json"
            moved=directory </> "moved"
            runCommand command config file=do
              (code,out,_)<-Process.readProcessWithExitCode binary [command,config,file] ""
              check (code==ExitSuccess)
              either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack out)
        BL.writeFile sourceFile (encode sourceConfig)
        BL.writeFile targetFile (encode targetConfig)
        output<-runCommand "backup-native-wallet" sourceFile (directory </> "wallet.bak")
        original<-fieldValue "manifest" output
        check (original==directory </> "wallet.bak.json")
        PD.createDirectory moved 0o700
        renameFile original (moved </> "wallet.bak.json")
        renameFile (directory </> "wallet.bak") (moved </> "wallet.bak")
        bundled<-lookupEnv "ECX_REBUILD_CUSTODY_ONLY"
        nativeManifest<-if bundled==Just "1" then custodyBundleContract binary manager sourceConfig directory
          else pure (moved </> "wallet.bak.json")
        expectedNext<-allocate "next-label" "bech32"
        void $ call source False "unloadwallet" [toJSON sourceName,Bool False]
        bracket_ (pure ()) (cleanup targetName) $ do
          result<-runCommand "restore-native-wallet" targetFile nativeManifest
          fieldValue "wallet" result >>= check . (==targetName)
          recovered<-N.recoverNativeAddressWith (call target) target 0 False "recovery-label"
          check (recovered==address)
          next<-call target True "getnewaddress" [String "next-label",String "bech32"]
          check (next==String expectedNext)
          signature<-call target True "signmessage" [String legacy,String "ECX empty-wallet recovery acceptance"]
          verified<-call target False "verifymessage" [String legacy,signature,String "ECX empty-wallet recovery acceptance"]
          check (verified==Bool True)
    putStrLn "Real L2L Signet wallet backup/restore in separate executable processes with relocated durable manifest: descriptor state, labels, next address and private-key signing PASS; test wallets removed."

-- Real PostgreSQL and native node; the Solana key is a public, never-funded
-- vector. No Solana RPC is needed to verify recovery of its private identity.
custodyBundleContract :: FilePath -> HTTP.Manager -> Config.Config -> FilePath -> IO FilePath
custodyBundleContract binary manager base directory=withTestSigningKey $ \key->do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user<-getEnv "USER"
  role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  environment<-getEnvironment
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      readerSettings=settings {PG.connectUser=role}
      config=base {Config.custodyOwner="4zvwRjXUKGfvwnParsHAS3HuSVzV5cA4McphgmoCtajS",Config.fenceDirectory=directory </> "fence"}
      identity=Config.fingerprint config
      file=directory </> "custody-config.json"
      offlineFile=directory </> "offline-config.json"
      overrides=[("PGHOST","/tmp/ecx-pg-seam"),("PGPORT","29436"),("PGDATABASE",database),
        ("PGUSER",user),("PGPASSWORD",""),("PGREADUSER",role),("PGREADPASSWORD","")]
      noPG=filter (not . T.isPrefixOf "PG" . T.pack . fst) environment
      check ok=unless ok (fail "custody bundle contract failed")
      run env args=do
        (code,out,_)<-Process.readCreateProcessWithExitCode (Process.proc binary args) {Process.env=Just env} ""
        check (code==ExitSuccess)
        either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack out)
      export=evalCustodyRecovery manager config (ExportCustody settings readerSettings key directory)
  Config.validateConfig config
  BL.writeFile file (encode config)
  BL.writeFile offlineFile (encode config {Config.nativeRpc="http://127.0.0.1:1",Config.nativeCookie="/unavailable-cookie"})
  bracket (PG.connect settings) PG.close $ \fixtures->do
    fixture fixtures (InitializeIdentity identity)
    Fence.initializeFence (Config.fenceDirectory config) identity 0
    beforeFiles<-listDirectory directory
    withFencedWriter settings (Config.storePolicy config) (Config.fenceDirectory config) $ \_->do
      expectStore "worker_fence_locked" export
      -- The signer has only SELECT authority and can checkpoint while the
      -- worker retains exclusive ownership. Both use the same bundle format.
      withReader readerSettings identity (Config.backupRequired config) $ \reader->do
        expectStore "invalid_custody_checkpoint" (evalCustodyRecovery manager config $ ExportCheckpoint reader key directory 1)
        bracket (evalCustodyRecovery manager config $ ExportCheckpoint reader key directory 0)
          (removeDirectoryRecursive . takeDirectory . fst) $ \(checkpoint,n)->do
            check (n==0)
            evalCustodyRecovery manager config (InspectCustody checkpoint n) >>= check . (==n)
    withWriter settings (Config.storePolicy config) (const $ pure ()) $ \_->
      expectStore "worker_already_running" export
    failedBackups<-newIORef (0::Int)
    let interrupt request=case HTTP.requestBody request of
          HTTP.RequestBodyLBS body | Right (Object value)<-eitherDecodeStrict' (BL.toStrict body)
            , KM.lookup "method" value==Just (String "backupwallet")->
                modifyIORef' failedBackups (+1) >> reject "injected_backup_failure"
          _->pure request
    bracket (newManager $ HTTP.managerSetProxy HTTP.noProxy defaultManagerSettings {managerModifyRequest=interrupt}) closeManager $ \faulty->
      expectStore "injected_backup_failure" (evalCustodyRecovery faulty config $ ExportCustody settings readerSettings key directory)
    readIORef failedBackups >>= check . (==1)
    expectStore "custody_backup_database_mismatch" (evalCustodyRecovery manager config $
      ExportCustody settings readerSettings {PG.connectDatabase="other"} key directory)
    listDirectory directory >>= check . (==sort beforeFiles) . sort
    output<-run (overrides<>noPG) ["backup-custody",file,key,directory]
    original<-fieldValue "manifest" output
    fieldValue "criticalSequence" output >>= check . (==(0::Int))
    let relocated=directory </> "relocated-custody"
        manifest=relocated </> "custody.json"
    renameDirectory (takeDirectory original) relocated
    -- Neither the original signing file nor a DB/RPC connection is available
    -- to the next process. Only the relocated bundle remains for inspection.
    removeFile key
    inspected<-run noPG ["check-custody",offlineFile,manifest,"0"]
    fieldValue "fingerprint" inspected >>= check . (==identity)
    fieldValue "criticalSequence" inspected >>= check . (==(0::Int))
    bracket (newManager defaultManagerSettings {managerModifyRequest= \_->fail "offline custody inspection reached network"}) closeManager $ \offline->do
      let inspect=evalCustodyRecovery offline config
      inspect (InspectCustody manifest 0) >>= check . (==0)
      expectStore "backup_snapshot_too_old" (inspect $ InspectCustody manifest 1)
      expectStore "invalid_restore_policy" (inspect $ InspectCustody manifest (-1))
      expectStore "backup_identity_mismatch" (evalCustodyRecovery offline config {Config.deploymentId="wrong"} $ InspectCustody manifest 0)
      saved<-BS.readFile (relocated </> "deployment.json")
      BS.appendFile (relocated </> "deployment.json") " "
      expectStore "custody_backup_hash_mismatch" (inspect $ InspectCustody manifest 0)
      BS.writeFile (relocated </> "deployment.json") saved
      setFileMode (relocated </> "solana-key.json") 0o644
      expectStore "unsafe_custody_backup_file" (inspect $ InspectCustody manifest 0)
      setFileMode (relocated </> "solana-key.json") 0o600
      inspect (InspectCustody manifest 0) >>= check . (==0)
    recoveredManifest<-encryptedCustodyContract binary manager config offlineFile noPG manifest directory
    let recoveredDirectory=takeDirectory recoveredManifest
    value<-BS.readFile recoveredManifest >>= either fail pure . eitherDecodeStrict'
    ledger<-fieldValue "ledgerManifest" value
    records<-fixture fixtures ArchiveRecords
    let restore=do
          result<-run (overrides<>noPG) ["restore-ledger",file,recoveredDirectory </> ledger,"0"]
          fieldValue "database" result
    bracket restore (\name->Backup.discardRestore settings {PG.connectDatabase=T.unpack name}) $ \name->
      bracket (PG.connect settings {PG.connectDatabase=T.unpack name}) PG.close $ \restored->do
        (rows,attempts,postings)<-fixture restored ArchiveRecords
        let (_,savedAttempts,savedPostings)=records
        check (attempts==savedAttempts && postings==savedPostings && not(null postings)
          && case rows of [row]->S.fingerprint row==identity && S.paused row==1 && S.criticalSequence row==0; _->False)
    fixture fixtures ArchiveRecords >>= check . (==records)
    verifySigningKey (Config.custodyOwner config) (recoveredDirectory </> "solana-key.json")
    putStrLn "PASS: exclusive custody export, six bound files, relocated offline inspection without original key/DB/RPC, integrity/minimum/identity/permissions refusal, exact journal restore and unchanged source ledger"
    pure (recoveredDirectory </> "native-wallet.json")

-- Local encrypted-repository seam only. Production still requires off-host HTTPS;
-- the same transfer code and full semantic inspector verify this downloaded set.
encryptedCustodyContract :: FilePath -> HTTP.Manager -> Config.Config -> FilePath -> [(String,String)] -> FilePath -> FilePath -> IO FilePath
encryptedCustodyContract binary manager config offlineFile environment manifest directory=do
  (program,repository,password,configuration)<-testRepository directory
  let identity=Config.fingerprint config
      check ok=unless ok (fail "encrypted custody contract failed")
      download snapshot expected minimumSequence=Backup.downloadCustodyArchive program repository password snapshot expected minimumSequence directory
  archive<-evalRestore PG.defaultConnectInfo (InspectCustodyFiles manifest identity 0)
  expected<-BS.readFile manifest
  expectStore "https_backup_repository_required" (evalCustodyRecovery manager config $ UploadCustody configuration manifest 0)
  receipt<-Backup.uploadCustodyArchive program repository password archive
  let snapshot=receiptSnapshot receipt
  check (receiptIdentity receipt==identity && receiptSequence receipt==0 && receiptArchiveHash receipt==digest expected)
  expectStore "https_backup_repository_required" (evalCustodyRecovery manager config $ RecoverCustody configuration snapshot directory 0)
  before<-sort <$> listDirectory directory
  expectStore "invalid_backup_snapshot" (download "latest" identity 0)
  expectStore "backup_identity_mismatch" (download snapshot "wrong" 0)
  expectStore "backup_snapshot_too_old" (download snapshot identity 1)
  -- A valid encrypted ledger-only snapshot cannot substitute for custody keys.
  ledger<-evalRestore PG.defaultConnectInfo (InspectLedger (takeDirectory manifest </> custodyLedger archive) identity 0)
  ledgerReceipt<-Backup.uploadArchive program repository password ledger
  expectStore "backup_snapshot_mismatch" (download (receiptSnapshot ledgerReceipt) identity 0)
  secret<-BS.readFile password
  BS.writeFile password "wrong-passphrase"
  expectStore "backup_process_failed" (download snapshot identity 0)
  BS.writeFile password secret
  (sort <$> listDirectory directory) >>= check . (==before)
  -- No plaintext bundle remains. Restore all seven files from real restic.
  removeDirectoryRecursive (takeDirectory manifest)
  recovered<-download snapshot identity 0
  let path=custodyManifest recovered
  BS.readFile path >>= check . (==expected)
  forM_ (path:map (takeDirectory path </>) (M.keys $ custodyFiles recovered)) $ \file->do
    status<-Posix.getSymbolicLinkStatus file
    check (Posix.isRegularFile status && Posix.fileMode status .&. 0o077==0)
  evalCustodyRecovery manager config (InspectCustody path 0) >>= check . (==0)
  (code,out,_)<-Process.readCreateProcessWithExitCode
    (Process.proc binary ["check-custody",offlineFile,path,"0"]) {Process.env=Just environment} ""
  check (code==ExitSuccess)
  value<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack out)
  fieldValue "fingerprint" value >>= check . (==identity)
  putStrLn "PASS: real restic full-custody encryption/download after plaintext removal, seven private files, ledger-only/latest/stale/identity/password refusal, production HTTPS restriction and independent CLI inspection"
  pure path

testRepository :: FilePath -> IO (FilePath,FilePath,FilePath,FilePath)
testRepository directory=do
  program<-findExecutable "restic" >>= maybe (fail "restic required for encrypted archive contract") pure
  let repository=directory</>"repository"; password=directory</>"password"; configuration=directory</>"backup.json"
      protected path contents=BS.writeFile path contents >> setFileMode path 0o600
  secret<-TE.encodeUtf8 . digest <$> (getRandomBytes 32 :: IO BS.ByteString)
  protected password secret
  protected repository (TE.encodeUtf8 $ T.pack(directory</>"encrypted-repository"))
  protected configuration $ BL.toStrict $ encode $ object ["restic" .= program,"repositoryFile" .= repository,"passwordFile" .= password]
  Process.callProcess program ["--no-cache","--repository-file",repository,"--password-file",password,"init","--quiet"]
  pure (program,repository,password,configuration)

ledgerMain :: IO ()
ledgerMain = do
  database <- getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user <- getEnv "USER"
  readRole <- getEnv "ECX_REBUILD_CONTRACT_READER"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      readerSettings=settings {PG.connectUser=readRole}
      policy=PaymentTerms (PolicySnapshot 2 "finalized" "contract") (CostLimits (money 10) (money 10) (money 10))
      limits=OrderLimits (money 2) (money 1000) 100 100 100 (money 100000) (money 100000)
      store terms config=StorePolicy terms config "contract" True
      key=T.replicate 64 "a"
      reserve=ReserveFees 100 key Native (money 100) "recipient" "test owned revenue"
      check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "store contract failed\n"<>prettyCallStack callStack)
  bracket (PG.connect settings) PG.close $ \fixtures -> do
    fixture fixtures Initialize
    withReader readerSettings "contract" True $ \reader -> do
      expectStore "unsafe_read_database_role" (withReader settings "contract" True $ const $ pure ())
      expectStore "ledger_profile_or_schema_mismatch" (withReader readerSettings "wrong" True $ const $ pure ())
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        expectStore "worker_already_running" (withWriter settings (store policy limits) (const $ pure ()) $ const $ pure ())
        evalRead reader ReadNativeLockWork >>= check . (==Nothing)
        evalRead reader PendingAttempts >>= check . null
        evalRead reader PaymentCandidates >>= check . null
        initial <- evalRead reader ReadBalances
        first <- evalWrite writer reserve
        replay <- evalWrite writer reserve
        check (first==replay && withdrawalSequence first==1)
        evalRead reader PaymentCandidates >>= check . (==["fee:"<>key])
        feeView<-evalRead reader (ReadPayment $ "fee:"<>key)
        check (savedPayment feeView==withdrawalPayment first && savedTerms feeView==policy && savedStatus feeView==PaymentReady)
        expectStore "payment_not_found" (evalRead reader $ ReadPayment "absent")
        booked <- evalRead reader ReadBalances
        check (M.lookup (Native,Earned) booked==Just 900 && M.lookup (Native,FeePending) booked==Just 100)
        expectStore "fee_withdrawal_conflict" (evalWrite writer $ ReserveFees 100 key Native (money 101) "recipient" "test owned revenue")
        expectStore "custody_not_reconciled" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "b") Native (money 100) "recipient" "test owned revenue")
        fixture fixtures RefreshCustody
        expectStore "insufficient_earned_fees" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "b") Native (money 1000) "recipient" "test owned revenue")
        cancelled <- evalWrite writer (CancelFees key "cancel")
        replayCancelled <- evalWrite writer (CancelFees key "cancel")
        check (cancelled==replayCancelled && withdrawalCancellation cancelled==Just("cancel",2))
        restored <- evalRead reader ReadBalances
        check (M.filter (/=0) restored==M.filter (/=0) initial)
        cancelledView<-evalRead reader (ReadPayment $ "fee:"<>key)
        check (savedStatus cancelledView==PaymentCancelled)
        evalRead reader PaymentCandidates >>= check . null
        expectStore "fee_withdrawal_cancellation_conflict" (evalWrite writer (CancelFees key "changed"))
        resumed <- evalWrite writer reserve
        check (withdrawalCancellation resumed==Just("cancel",2))
        counter <- newIORef (0::Int)
        result <- quickCheckWithResult stdArgs {maxSuccess=25} $ forAll (chooseInteger (1,1000)) $ \n -> ioProperty $ do
          index <- atomicModifyIORef' counter (\i->(i+1,i+1))
          let identifier=T.justifyRight 64 '0' (T.pack $ show index)
          fixture fixtures RefreshCustody
          before <- evalRead reader ReadBalances
          reserved <- evalWrite writer (ReserveFees 100 identifier Native (money n) "recipient" "property")
          afterReserve <- evalRead reader ReadBalances
          _ <- evalWrite writer (CancelFees identifier "property cancel")
          afterCancel <- evalRead reader ReadBalances
          pure (units(paymentAmount $ withdrawalPayment reserved)==fromInteger n &&
            M.findWithDefault 0 (Native,Earned) afterReserve==1000-n &&
            M.findWithDefault 0 (Native,FeePending) afterReserve==n &&
            M.filter (/=0) before==M.filter (/=0) afterCancel)
        check (isSuccess result)
      -- A failed durable checkpoint rolls back money and permanently fences the
      -- writer. Reader checks use separate SELECT-only credentials throughout.
      fixture fixtures RefreshCustody
      beforeFailure <- evalRead reader ReadState
      let failCheckpoint n=when (n>ledgerSequence beforeFailure) (ioError $ userError "injected checkpoint failure")
      withWriter settings (store policy limits) failCheckpoint $ \writer -> do
        failure <- try (evalWrite writer $ ReserveFees 100 (T.replicate 64 "c") Native (money 100) "recipient" "test rollback") :: IO (Either IOException WithdrawalView)
        check (case failure of Left _->True; Right _->False)
        expectStore "ledger_connection_fenced" (evalWrite writer (Pause "must fail"))
      rolledBack <- evalRead reader (ReadWithdrawal $ T.replicate 64 "c")
      state <- evalRead reader ReadState
      check (rolledBack==Nothing && ledgerSequence state==ledgerSequence beforeFailure)
      -- A checkpoint can use the same error type as policy refusal. Its origin,
      -- not just its type, must determine whether the writer is fenced.
      withWriter settings (store policy limits)
        (\n->when (n>ledgerSequence beforeFailure) $ throwIO $ BridgeError "checkpoint_rejected") $ \writer -> do
          expectStore "checkpoint_rejected" (evalWrite writer $ ReserveFees 100 (T.replicate 64 "c") Native (money 100) "recipient" "test typed checkpoint failure")
          expectStore "ledger_connection_fenced" (evalWrite writer $ Pause "must stay fenced")
      rolledBackAgain<-evalRead reader (ReadWithdrawal $ T.replicate 64 "c")
      check (rolledBackAgain==Nothing)
      fixture fixtures SeedIntake
      let origins=[("Native","scan-origin"),("Solana","sol-origin"),("SolanaOperating","opening-signature")]
      expectStore "custody_scan_origin_mismatch" (evalRead reader $ ReadCustodySnapshot 100 origins False)
      fixture fixtures SeedCustodyHeads
      withWriter settings (store policy limits) (const $ pure ()) $ \writer->do
        fixture fixtures RefreshCustody
        beforeResume<-evalRead reader ReadBalances
        evalWrite writer (ResumeLedger 100 origins [])
        evalRead reader ReadState >>= check . not . ledgerPaused
        expectStore "pause_before_operator_action" (evalWrite writer $ ResumeLedger 100 origins [])
        evalWrite writer (Pause "resume contract")
        expectStore "scanners_not_fresh" (evalWrite writer $ ResumeLedger 161 origins [])
        evalRead reader ReadState >>= check . ledgerPaused
        evalRead reader ReadBalances >>= check . (==beforeResume)
      fixture fixtures SeedOrders
      let auth="Bearer "<>T.replicate 64 "0"
      hidden <- evalRead reader (ReadOrder auth "hidden")
      check (W.depositInstruction hidden==Nothing && units(net $ W.quote hidden)==93)
      expectStore "order_not_found" (evalRead reader $ ReadOrder ("Bearer "<>T.replicate 64 "1") "hidden")
      expectStore "authorization_required" (evalRead reader $ ReadOrder "" "hidden")
      expectStore "invalid_capability" (evalRead reader $ ReadOrder "Bearer invalid" "hidden")
      expectStore "backup_pending" (evalRead reader $ ReadOrder auth "visible")
      expectStore "saved_order_terms_mismatch" (evalRead reader $ ReadOrder auth "mismatch")
      expectStore "corrupt_ledger_json" (evalRead reader $ ReadOrder auth "corrupt")
      fixture fixtures CoverBackup
      visible <- evalRead reader (ReadOrder auth "visible")
      check (W.depositInstruction visible==Just "instruction-visible" && W.status visible=="AwaitingDeposit")
      withWriter settings (store policy limits) (const $ pure ()) $ \writer->do
        fixture fixtures RefreshCustody
        expectStore "legacy_order_cost_review_required" (evalWrite writer $ ResumeLedger 100 origins [])
        evalRead reader ReadState >>= check . ledgerPaused
      fixture fixtures SeedReview
      reviewed <- evalRead reader (ReadOrder auth "visible")
      check (W.status reviewed=="NeedsReview")
      withWriter settings (store policy limits) (const $ pure ()) $ \writer->do
        fixture fixtures RefreshCustody
        expectStore "obligations_require_review" (evalWrite writer $ ResumeLedger 100 origins [])
        evalRead reader ReadState >>= check . ledgerPaused
      snapshot<-evalRead reader (ReadCustodySnapshot 100 origins False)
      check (custodyTotals snapshot==M.fromList [(Native,2100),(Wrapped,1000),(Sol,100)]
        && custodySlot snapshot==42 && null(custodyPending snapshot))
      expectStore "scanners_not_fresh" (evalRead reader $ ReadCustodySnapshot 161 origins False)
      expectStore "scanners_not_fresh" (evalRead reader $ ReadCustodySnapshot 99 origins False)
      expectStore "custody_scan_origin_mismatch" (evalRead reader $ ReadCustodySnapshot 100 (drop 1 origins) False)
      known<-evalRead reader (HasCustodyEvent "Solana" (T.replicate 64 "1"))
      unknown<-evalRead reader (HasCustodyEvent "Native" (T.replicate 64 "1"))
      check (known && not unknown)
      evidence<-evalRead reader (ReadCustodyEvent "SolanaOperating" (T.replicate 64 "1"))
      check (evidence==("reference","42",object []))
      expectStore "custody_history_not_current" (evalRead reader $ ReadCustodyEvent "Native" (T.replicate 64 "1"))
      fixture fixtures (CustodyHeadReview 1)
      expectStore "chain_observations_require_review" (evalRead reader $ ReadCustodySnapshot 100 origins False)
      expectStore "custody_history_not_current" (evalRead reader $ ReadCustodyEvent "Solana" (T.replicate 64 "1"))
      fixture fixtures (CustodyHeadReview 0)
      custodyContract fixtures reader
      let newRequest=W.OrderRequest NativeToWrapped (money 100) "recipient" "refund" Nothing "new-wrap"
          create request=CreateOrder 100 auth request
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        revision<-evalRead reader ReadCustodyRevision
        let good=Just(object ["matches" .= True])
        check (revision>custodyRevision snapshot)
        expectStore "custody_ledger_changed" (evalWrite writer $ RecordCustody (custodyRevision snapshot) 100 Nothing good)
        beforeCustody<-evalRead reader ReadBalances
        expectStore "custody_ledger_changed" (evalWrite writer $ RecordCustody (revision+1) 100 Nothing good)
        expectStore "invalid_custody_report" (evalWrite writer $ RecordCustody revision 100 Nothing Nothing)
        expectStore "invalid_custody_report" (evalWrite writer $ RecordCustody revision 100 Nothing (Just $ object ["matches" .= False]))
        evalWrite writer (RecordCustody revision 100 Nothing good)
        certified<-fixture fixtures ReadCustodyCheck
        check (certified==(Just revision,Just 100,Nothing))
        evalRead reader ReadState >>= check . ledgerPaused
        fixture fixtures ReadyIntake
        evalWrite writer (RecordCustody revision 100 (Just "custody_native_history_advanced") Nothing)
        evalRead reader ReadState >>= check . not . ledgerPaused
        evalWrite writer (RecordCustody revision 100 (Just "balance_mismatch") (Just $ object ["matches" .= False]))
        evalRead reader ReadState >>= check . ledgerPaused
        evalWrite writer (RecordCustody revision 100 Nothing good)
        evalRead reader ReadState >>= check . ledgerPaused
        afterCustody<-evalRead reader ReadBalances
        afterRevision<-evalRead reader ReadCustodyRevision
        check (beforeCustody==afterCustody && afterRevision==revision)
        expectStore "intake_paused" (evalWrite writer $ create newRequest)
        fixture fixtures ReadyIntake
        before <- fixture fixtures OrderSnapshot
        identifier <- evalWrite writer (create newRequest)
        replay <- evalWrite writer (create newRequest)
        after <- fixture fixtures OrderSnapshot
        check (identifier==replay && zipWith (-) after before==[1,1,1,2])
        view <- evalRead reader (ReadOrder auth identifier)
        check (W.request view==newRequest && gross(W.quote view)==money 100 && fee(W.quote view)==money 1 && net(W.quote view)==money 99 && W.status view=="Provisioning" && W.depositInstruction view==Nothing && W.deadline view==200)
        expectStore "idempotency_conflict" (evalWrite writer $ create newRequest {W.input=money 101})
        -- Each rejection must leave orders, inventory holds, saved cost limits
        -- and operating reservations exactly unchanged.
        let rejected expected request=do
              prior <- fixture fixtures OrderSnapshot
              expectStore expected (evalWrite writer $ create request)
              following <- fixture fixtures OrderSnapshot
              check (prior==following)
        fixture fixtures StaleCustody
        rejected "custody_not_reconciled" newRequest {W.idempotencyKey="stale"}
        fixture fixtures ReadyIntake
        rejected "amount_outside_limits" newRequest {W.idempotencyKey="small",W.input=money 1}
        rejected "invalid_connection_free_order" newRequest {W.idempotencyKey="connected",W.sourceOwner=Just "owner"}
        rejected "insufficient_inventory" newRequest {W.idempotencyKey="large",W.input=money 1000}
        let unwrap=newRequest {W.idempotencyKey="new-unwrap",W.direction=WrappedToNative,W.refund="",W.input=money 201}
        other <- evalWrite writer (create unwrap)
        fixture fixtures (CheckHolds identifier NativeToWrapped 99) >>= check
        fixture fixtures (CheckHolds other WrappedToNative 198) >>= check
        otherView <- evalRead reader (ReadOrder auth other)
        check (fee(W.quote otherView)==money 3 && net(W.quote otherView)==money 198)
        fixture fixtures ReadyIntake
        expectStore "scanners_not_fresh" (evalWrite writer $ CreateOrder 161 auth newRequest {W.idempotencyKey="old-scan"})
      let failedAdmission config terms expected=withWriter settings (store terms config) (const $ pure ()) $ \writer -> do
            fixture fixtures ReadyIntake
            before <- fixture fixtures OrderSnapshot
            expectStore expected (evalWrite writer $ create newRequest {W.idempotencyKey="reject"})
            after <- fixture fixtures OrderSnapshot
            check (before==after)
      failedAdmission limits {maximumQueued=1} policy "queue_full"
      failedAdmission limits {nativeDaily=money 1} policy "operating_daily_limit"
      failedAdmission limits policy {paymentLimits=CostLimits (money 1000) (money 10) (money 10)} "insufficient_fee_budget"
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        fixture fixtures ReadyIntake
        native <- evalWrite writer (create newRequest {W.idempotencyKey="provision-native"})
        solana <- evalWrite writer (create newRequest {W.idempotencyKey="provision-solana",W.direction=WrappedToNative,W.refund=""})
        late <- evalWrite writer (create newRequest {W.idempotencyKey="provision-late"})
        claim <- evalWrite writer (ClaimNative 100 auth native)
        retryClaim <- evalWrite writer (ClaimNative 100 auth native)
        check (mayAllocate claim && not(mayAllocate retryClaim) && allocationLabel claim==allocationLabel retryClaim)
        lateClaim <- evalWrite writer (ClaimNative 100 auth late)
        let address="tb1q9vl0cpvddncs78537mrpxawydzsgkz7k5hgj7w"
        nativeSequence <- evalWrite writer (RecordNative auth native (allocationLabel claim) address)
        replaySequence <- evalWrite writer (RecordNative auth native (allocationLabel claim) address)
        check (nativeSequence==replaySequence)
        expectStore "instruction_is_immutable" (evalWrite writer $ RecordNative auth native (allocationLabel claim) "different-address")
        expectStore "invalid_native_allocation_result" (evalWrite writer $ RecordNative auth native "wrong-label" address)
        expectStore "invalid_solana_provisioning_order" (evalWrite writer $ BindSolana 100 auth native)
        solanaSequence <- evalWrite writer (BindSolana 100 auth solana)
        solanaReplay <- evalWrite writer (BindSolana 100 auth solana)
        check (solanaSequence==solanaReplay)
        beforeExposure <- evalRead reader (ReadOrder auth native)
        check (W.depositInstruction beforeExposure==Nothing)
        expectStore "backup_pending" (evalWrite writer $ IssueInstruction 100 auth native)
        let cover=do
              stateNow <- evalRead reader ReadState
              evalWrite writer (AcknowledgeBackup "contract" (ledgerSequence stateNow) (T.replicate 64 "0"))
        stateNow <- evalRead reader ReadState
        expectStore "invalid_backup_coverage" (evalWrite writer $ AcknowledgeBackup "contract" (ledgerSequence stateNow+1) (T.replicate 64 "0"))
        expectStore "ledger_profile_or_schema_mismatch" (evalWrite writer $ AcknowledgeBackup "wrong" 0 (T.replicate 64 "0"))
        cover
        expectStore "invalid_backup_coverage" (evalWrite writer $ AcknowledgeBackup "contract" 0 (T.replicate 64 "0"))
        nativeView <- evalWrite writer (IssueInstruction 100 auth native)
        solanaView <- evalWrite writer (IssueInstruction 100 auth solana)
        check (W.depositInstruction nativeView==Just address && Right (W.depositInstruction solanaView)==(Just <$> payInstruction solana))
        let reference=either (error . T.unpack) id (payInstruction solana)
            bare=T.drop (T.length "solana-pay:") reference
        matched<-evalRead reader (LookupReferences [bare,"unused-key"])
        missing<-evalRead reader (LookupReferences [])
        expectStore "too_many_reference_keys" (evalRead reader $ LookupReferences $ replicate 257 bare)
        check (fmap (\(identifier,_,_,ref)->(identifier,ref)) matched==Just(solana,bare) && missing==Nothing)
        fixture fixtures (ProtectHolds solana)
        evalWrite writer (ExpireQuotes 301)
        lateSequence <- evalWrite writer (RecordNative auth late (allocationLabel lateClaim) "late-native-address-fixture")
        check (lateSequence>solanaSequence)
        cover
        lateView <- evalRead reader (ReadOrder auth late)
        check (W.status lateView=="ExpiredUnfunded" && W.depositInstruction lateView==Nothing)
        expectStore "scanners_not_fresh" (evalWrite writer $ IssueInstruction 301 auth late)
        fixture fixtures ReadyIntake
        expectStore "deposit_window_closed" (evalWrite writer $ IssueInstruction 100 auth late)
        historical <- evalWrite writer (IssueInstruction 301 auth native)
        check (W.status historical=="ExpiredUnfunded" && W.depositInstruction historical==Just address)
        fixture fixtures (CheckPhases native "released") >>= check
        fixture fixtures (CheckPhases solana "obligation") >>= check
        evalWrite writer (ExpireQuotes 301)
        fixture fixtures (CheckPhases solana "obligation") >>= check
      fixture fixtures PromotionFunds
      (promoted,failedPayment) <- withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        let make name direction=do
              fixture fixtures ReadyIntake
              oid<-evalWrite writer (create newRequest {W.idempotencyKey=name,W.input=money 10,W.direction=direction,W.refund=if direction==NativeToWrapped then "refund" else ""})
              if direction==NativeToWrapped then do
                claim<-evalWrite writer (ClaimNative 100 auth oid)
                _<-evalWrite writer (RecordNative auth oid (allocationLabel claim) ("fixture-address-"<>name))
                pure ()
              else evalWrite writer (BindSolana 100 auth oid) >> pure ()
              pure oid
            seed did oid asset quantity depth eligible seen=fixture fixtures (SeedReceipt did (Just oid) asset quantity depth eligible seen)
        native<-make "promote-native" NativeToWrapped
        seed "promote-source" native Native 10 2 True 100
        candidates<-evalRead reader PromotionCandidates
        check ("promote-source" `elem` candidates)
        before<-evalRead reader ReadBalances
        first<-evalWrite writer (PromoteDeposit 100 "promote-source")
        replay<-evalWrite writer (PromoteDeposit 100 "promote-source")
        after<-evalRead reader ReadBalances
        check (first && not replay && before==after)
        fixture fixtures (CheckPromotion native "promote-source" Wrapped 9 "Ready") >>= check
        conversionView<-evalRead reader (ReadPayment $ "convert:"<>native)
        check (paymentAmount(savedPayment conversionView)==money 9 && savedStatus conversionView==PaymentReady)
        bound<-evalRead reader (ReadPaymentSource $ "convert:"<>native)
        source<-maybe (fail "missing payment source") (pure . W.sourceDeposit) bound
        cursorBeforeRefresh<-evalRead reader (ReadCheckpoint "Native")
        expectStore "source_binding_changed" (evalWrite writer $ RefreshPaymentSource source source {W.depositAmount=money 11})
        evalWrite writer (RefreshPaymentSource source source {W.depositConfirmations=3})
        expectStore "source_binding_changed" (evalWrite writer $ RefreshPaymentSource source source)
        evalRead reader ReadBalances >>= check . (==after)
        evalRead reader (ReadCheckpoint "Native") >>= check . (==cursorBeforeRefresh)
        fixture fixtures (CheckPhases native "obligation") >>= check
        candidatesAfter<-evalRead reader PromotionCandidates
        check ("promote-source" `notElem` candidatesAfter)
        -- A second exact receipt remains a protected liability, never a second conversion.
        seed "extra-source" native Native 10 2 True 100
        extra<-evalWrite writer (PromoteDeposit 100 "extra-source")
        check (not extra)
        fixture fixtures (CheckPromotion native "promote-source" Wrapped 9 "NeedsReview") >>= check
        forM_ [("wrong-amount",9,2,100,100),("shallow",10,1,100,100),
               ("late-seen",10,2,201,201),("late-confirmed",10,2,100,301)] $ \(name,n,depth,seen,now)->do
          oid<-make name NativeToWrapped
          seed name oid Native n depth True seen
          result<-evalWrite writer (PromoteDeposit now name)
          check (not result)
          view<-evalRead reader (ReadOrder auth oid)
          check (W.status view=="NeedsReview")
          fixture fixtures (CheckPhases oid "quote") >>= check
        waiting<-make "unconfirmed" NativeToWrapped
        seed "unconfirmed" waiting Native 10 0 False 100
        evalWrite writer (PromoteDeposit 100 "unconfirmed") >>= check . not
        waitView<-evalRead reader (ReadOrder auth waiting)
        check (W.status waitView=="AwaitingDeposit")
        unwrap<-make "promote-unwrap" WrappedToNative
        seed "wrapped-source" unwrap Wrapped 10 1 True 100
        evalWrite writer (PromoteDeposit 100 "wrapped-source") >>= check
        fixture fixtures (CheckPromotion unwrap "wrapped-source" Native 9 "Ready") >>= check
        fixture fixtures (CheckPhases unwrap "obligation") >>= check
        missing<-make "missing-allowance" NativeToWrapped
        seed "missing-allowance" missing Native 10 2 True 100
        fixture fixtures (OperatingPhase missing "released")
        expectStore "operating_reservation_not_provisional" (evalWrite writer $ PromoteDeposit 100 "missing-allowance")
        pending<-evalRead reader PromotionCandidates
        check ("missing-allowance" `elem` pending)
        pendingView<-evalRead reader (ReadOrder auth missing)
        check (W.status pendingView=="AwaitingDeposit")
        fixture fixtures (OperatingPhase missing "quote")
        evalWrite writer (PromoteDeposit 100 "missing-allowance") >>= check
        fixture fixtures (CheckPromotion missing "missing-allowance" Wrapped 9 "Ready") >>= check
        let historical="historical-promotion"
        fixture fixtures (HistoricalHolds historical)
        seed "historical-fee" historical Native 100 2 True 100
        evalWrite writer (PromoteDeposit 100 "historical-fee") >>= check
        fixture fixtures (CheckPromotion historical "historical-fee" Wrapped 93 "Ready") >>= check
        historicalView<-evalRead reader (ReadPayment $ "convert:"<>historical)
        check (paymentAmount(savedPayment historicalView)==money 93)
        fixture fixtures ReadyIntake
        let intent="convert:"<>historical
        (readyWork,noPreparation,noAttempts)<-evalRead reader (ReadPaymentWork intent)
        check (savedStatus readyWork==PaymentReady && noPreparation==Nothing && null noAttempts)
        prepared<-evalWrite writer (PreparePayment 100 intent (money 10) "{}")
        selected<-evalRead reader PaymentCandidates
        check (intent `elem` selected && length selected<=2)
        sequenceBefore<-evalRead reader ReadState
        replayPrepared<-evalWrite writer (PreparePayment 100 intent (money 10) "{}")
        sequenceAfter<-evalRead reader ReadState
        check (prepared==replayPrepared && ledgerSequence sequenceBefore==ledgerSequence sequenceAfter && savedStatus(preparedView prepared)==PaymentPaying)
        expectStore "preparation_conflict" (evalWrite writer $ PreparePayment 100 intent (money 9) "{}")
        expectStore "order_fee_limit_exceeded" (evalWrite writer $ PreparePayment 100 intent (money 21) "{}")
        fixture fixtures ReadyIntake
        expectStore "destination_payment_unresolved" (evalWrite writer $ PreparePayment 100 ("convert:"<>missing) (money 10) "{}")
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        expectStore "payment_not_prepared" (evalRead reader $ ReadSigningDecision 100 intent 0)
        evalWrite writer (SaveDraft intent 0 "{\"draft\":1}")
        savedDraft<-evalRead reader (ReadPreparation intent)
        (activeWork,activePreparation,unsignedHistory)<-evalRead reader (ReadPaymentWork intent)
        check (activeWork==preparedView savedDraft && activePreparation==Just savedDraft && null unsignedHistory)
        draftSequence<-evalRead reader ReadState
        evalWrite writer (SaveDraft intent 0 "{\"draft\":1}")
        replaySequence<-evalRead reader ReadState
        check (preparedDraft savedDraft==Just "{\"draft\":1}" && ledgerSequence draftSequence==ledgerSequence replaySequence)
        expectStore "preparation_draft_conflict" (evalWrite writer $ SaveDraft intent 0 "{\"draft\":2}")
        expectStore "preparation_generation_changed" (evalWrite writer $ SaveDraft intent 1 "{}")
        expectStore "signing_backup_required" (evalRead reader $ ReadSigningDecision 100 intent 0)
        -- Exercise the real signer evaluator's refusal path; the manager forbids
        -- network access, so no identity RPC or signing can hide behind the test.
        let publicKey="4zvwRjXUKGfvwnParsHAS3HuSVzV5cA4McphgmoCtajS"
            native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused/credential" "ecx-bridge-test"
              16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
            solana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing publicKey publicKey publicKey
            signing=SignerSettings native solana (H.SolanaPolicy "contract" "contract" publicKey publicKey publicKey (money 10) (money 10))
              "/unused/sdk" "/unused/key" Nothing
        bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> fail "unauthorized signer reached network"}) closeManager $ \manager -> do
          withTestSigningKey $ \keyFile->withSigner manager reader signing {signingKey=keyFile} $ \interpret -> do
            expectStore "custody_checkpoint_not_configured" (interpret $ Request $ CheckpointCustody "contract" 0)
            expectStore "invalid_custody_checkpoint" (interpret $ Request $ CheckpointCustody "other" 0)
            expectStore "signer_profile_mismatch" (interpret $ Request $ SignPrepared "other" intent 0)
            expectStore "invalid_signing_decision" (interpret $ Request $ SignPrepared "contract" intent 8)
            expectStore "signing_backup_required" (interpret $ Request $ SignPrepared "contract" intent 0)
          withRuntime manager (ObserverSettings native solana 2 "sol-origin" "opening-signature") (signingPolicy signing) Nothing (SigningEndpoint 9443 "/unused/auth") reader writer $ \interpret _customer _operator -> do
            expectStore "invalid_saved_payment" (interpret $ Request $ SignPreparedPayment intent)
            expectStore "intake_paused" (interpret $ Request $ PrepareOutgoing intent)
          pausedAfterRefusal<-evalRead reader ReadState
          check (ledgerPaused pausedAfterRefusal)
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        decision<-evalRead reader (ReadSigningDecision 100 intent 0)
        check (decision==savedDraft)
        expectStore "preparation_generation_changed" (evalRead reader $ ReadSigningDecision 100 intent 1)
        let signed=SignedAttempt "fixture-signed-solana" "exact-fixture-bytes" "{\"signed\":true}" Nothing
        expectStore "preparation_changed" (evalWrite writer $ RecordAttempt decision {preparedPolicy="{\"changed\":true}"} signed)
        expectStore "attempt_common_input_mismatch" (evalWrite writer $ RecordAttempt decision signed {commonInput=Just "unexpected:0"})
        fixture fixtures (SourceEligibility "historical-fee" False)
        fixture fixtures ReadyIntake
        expectStore "source_not_eligible" (evalRead reader $ ReadSigningDecision 100 intent 0)
        expectStore "source_not_eligible" (evalWrite writer $ RecordAttempt decision signed)
        fixture fixtures (SourceEligibility "historical-fee" True)
        beforeSignature<-evalRead reader ReadBalances
        recorded<-evalWrite writer (RecordAttempt decision signed)
        firstSequence<-evalRead reader ReadState
        repeated<-evalWrite writer (RecordAttempt decision signed)
        secondSequence<-evalRead reader ReadState
        afterSignature<-evalRead reader ReadBalances
        check (recorded==repeated && recordedSigned recorded==signed && recordedState recorded=="signed" &&
          recordedSequence recorded==Nothing && ledgerSequence firstSequence==ledgerSequence secondSequence && beforeSignature==afterSignature)
        evalRead reader PendingAttempts >>= check . (==["fixture-signed-solana"])
        expectStore "attempt_identity_conflict" (evalWrite writer $ RecordAttempt decision signed {signedBytes="different"})
        expectStore "attempt_already_recorded" (evalWrite writer $ RecordAttempt decision signed {signedId="another-signature"})
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        expectStore "attempt_already_recorded" (evalRead reader $ ReadSigningDecision 100 intent 0)
        expectStore "preparation_already_signed" (evalRead reader $ ReadUnsignedPreparation intent)
        fixture fixtures (ImmutableAttempt "fixture-signed-solana") >>= check
        earnedCancellationContract fixtures reader writer
        let withdrawalKey=T.replicate 64 "d"
        evalWrite writer (Pause "reserve earned")
        fixture fixtures RefreshCustody
        _<-evalWrite writer (ReserveFees 100 withdrawalKey Native (money 10) "owner-address" "test earned payment")
        fixture fixtures ReadyIntake
        earnedPrepared<-evalWrite writer (PreparePayment 100 ("fee:"<>withdrawalKey) (money 5) "{}")
        check (paymentAsset(savedPayment $ preparedView earnedPrepared)==Native && savedStatus(preparedView earnedPrepared)==PaymentPaying)
        evalRead reader ReadNativeLockWork >>= check . (==Just(NativeLockWork earnedPrepared False []))
        expectStore "native_lock_work_changed" (evalWrite writer $ RecordNativeLockRestore (NativeLockWork earnedPrepared False []) 1)
        evalRead reader (ReadPaymentSource $ "fee:"<>withdrawalKey) >>= check . (==Nothing)
        expectStore "fee_withdrawal_payment_exists" (evalWrite writer $ CancelFees withdrawalKey "must retain")
        fixture fixtures (CheckFundingBinding ("fee:"<>withdrawalKey) withdrawalKey) >>= check
        evalWrite writer (SaveDraft ("fee:"<>withdrawalKey) 0 "{\"nativeDraft\":true}")
        earnedDraft<-evalRead reader (ReadPreparation $ "fee:"<>withdrawalKey)
        let lockWork=NativeLockWork earnedDraft False []
        evalRead reader ReadNativeLockWork >>= check . (==Just lockWork)
        beforeLockAudit<-evalRead reader ReadState
        beforeLockBalances<-evalRead reader ReadBalances
        evalWrite writer (RecordNativeLockRestore lockWork 1)
        evalRead reader ReadState >>= check . (==beforeLockAudit)
        evalRead reader ReadBalances >>= check . (==beforeLockBalances)
        fixture fixtures LockRestoreAudits >>= check . (==["fee:"<>withdrawalKey<>"@0:1"])
        expectStore "native_lock_work_changed" (evalWrite writer $ RecordNativeLockRestore lockWork 0)
        expectStore "native_lock_work_changed" (evalWrite writer $ RecordNativeLockRestore lockWork {lockCancelling=True} 1)
        let nativeSigned=SignedAttempt (T.replicate 64 "f") "native-fixture-bytes" "{\"nativeSigned\":true}" (Just "fixture-prevout:0")
        nativeRecorded<-evalWrite writer (RecordAttempt earnedDraft nativeSigned)
        evalRead reader ReadNativeLockWork >>= check . (==Just lockWork {lockAttempts=[nativeRecorded]})
        check (recordedChain nativeRecorded=="Native" && recordedSigned nativeRecorded==nativeSigned && recordedState nativeRecorded=="signed")
        evalRead reader PaymentCandidates >>= check . (==["fee:"<>withdrawalKey,intent])
        evalRead reader PendingAttempts >>= check . (==sort [signedId nativeSigned,"fixture-signed-solana"])
        let nativeTx=signedId nativeSigned; nativeCosts=W.PaymentCosts (money 3) (money 0)
        expectStore "settlement_attempt_changed" (evalWrite writer $ SettlePayment nativeRecorded nativeCosts "{\"offline\":true}")
        fixture fixtures ReadyIntake
        expectStore "broadcast_intent_required" (evalWrite writer $ AuthorizeSend 100 nativeTx)
        broadcastSequence<-evalWrite writer (MarkBroadcast 100 nativeTx)
        fixture fixtures ReadyIntake
        repeatedSequence<-evalWrite writer (MarkBroadcast 100 nativeTx)
        check (broadcastSequence==repeatedSequence)
        expectStore "backup_pending" (evalWrite writer $ AuthorizeSend 100 nativeTx)
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        authorized<-evalWrite writer (AuthorizeSend 100 nativeTx)
        check (recordedSigned authorized==nativeSigned && recordedSequence authorized==Just broadcastSequence)
        beforeSettlement<-evalRead reader ReadBalances
        expectStore "settlement_fee_or_evidence_invalid" (evalWrite writer $ SettlePayment authorized (W.PaymentCosts (money 3) (money 1)) "{\"offline\":true}")
        expectStore "settlement_attempt_changed" (evalWrite writer $ SettlePayment authorized {recordedSigned=nativeSigned {signedBytes="changed"}} nativeCosts "{\"offline\":true}")
        evalWrite writer (SettlePayment authorized nativeCosts "{\"offline\":true}")
        afterSettlement<-evalRead reader ReadBalances
        let change account=M.findWithDefault 0 (Native,account) afterSettlement-M.findWithDefault 0 (Native,account) beforeSettlement
        check (change FeePending==(-10) && change Operating==(-3) && change External==13 && change Principal==0 && change Float==0 && change Earned==0)
        evalWrite writer (SettlePayment authorized nativeCosts "{\"offline\":true}")
        evalRead reader ReadBalances >>= check . (==afterSettlement)
        expectStore "settlement_evidence_conflict" (evalWrite writer $ SettlePayment authorized nativeCosts "changed-proof")
        completed<-evalRead reader (ReadPayment $ "fee:"<>withdrawalKey)
        check (savedStatus completed==PaymentPaid)
        evalRead reader ReadNativeLockWork >>= check . (==Nothing)
        evalRead reader PendingAttempts >>= check . (notElem nativeTx)
        evalRead reader PaymentCandidates >>= check . (notElem ("fee:"<>withdrawalKey))
        bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> fail "terminal payment must not call RPC"}) closeManager $ \manager ->
          withRuntime manager (ObserverSettings native solana 2 "sol-origin" "opening-signature") (signingPolicy signing) Nothing (SigningEndpoint 9443 "/unused/auth") reader writer $ \interpret _customer _operator ->
            interpret (Request $ ReconcilePayment nativeTx)
        evalRead reader ReadBalances >>= check . (==afterSettlement)
        fixture fixtures (SeedReceipt "unknown-source" Nothing Native 10 2 True 100)
        evalWrite writer (PromoteDeposit 100 "unknown-source") >>= check . not
        expectStore "deposit_not_found" (evalWrite writer $ PromoteDeposit 100 "missing")
        expectStore "invalid_promotion_time" (evalWrite writer $ PromoteDeposit (-1) "promote-source")
        pure ("promote-source",missing)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        evalWrite writer (PromoteDeposit 100 promoted) >>= check . not
        (_,restartedPreparation,restartedHistory)<-evalRead reader (ReadPaymentWork "convert:historical-promotion")
        check (restartedPreparation/=Nothing && restartedHistory==["fixture-signed-solana"])
        persisted<-evalRead reader (ReadAttempt "fixture-signed-solana")
        check (signedBytes(recordedSigned persisted)=="exact-fixture-bytes" && recordedState persisted=="signed")
        fixture fixtures ReadyIntake
        fixture fixtures (SourceEligibility "historical-fee" False)
        fixture fixtures ReadyIntake
        expectStore "source_not_eligible" (evalWrite writer $ MarkBroadcast 100 "fixture-signed-solana")
        fixture fixtures (SourceEligibility "historical-fee" True)
        fixture fixtures ReadyIntake
        _<-evalWrite writer (MarkBroadcast 100 "fixture-signed-solana")
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        authorized<-evalWrite writer (AuthorizeSend 100 "fixture-signed-solana")
        beforeSettlement<-evalRead reader ReadBalances
        evalWrite writer (SettlePayment authorized (W.PaymentCosts (money 3) (money 2)) "offline-conversion-proof")
        afterSettlement<-evalRead reader ReadBalances
        let change asset account=M.findWithDefault 0 (asset,account) afterSettlement-M.findWithDefault 0 (asset,account) beforeSettlement
        check (change Native Principal==(-100) && change Native Float==93 && change Native Earned==7
          && change Wrapped Float==(-93) && change Wrapped External==93 && change Sol Operating==(-5) && change Sol External==5)
        completed<-evalRead reader (ReadPayment "convert:historical-promotion")
        check (savedStatus completed==PaymentPaid)
        paidRefundContract fixtures reader writer
        fixture fixtures ReadyIntake
        _<-evalWrite writer (PreparePayment 100 ("convert:"<>failedPayment) (money 10) "{}")
        evalWrite writer (SaveDraft ("convert:"<>failedPayment) 0 "{}")
        failedDraft<-evalRead reader (ReadPreparation ("convert:"<>failedPayment))
        _<-evalWrite writer (RecordAttempt failedDraft $ SignedAttempt "fixture-failed-solana" "failure-fixture-bytes" "{}" Nothing)
        fixture fixtures ReadyIntake
        _<-evalWrite writer (MarkBroadcast 100 "fixture-failed-solana")
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        failedAttempt<-evalWrite writer (AuthorizeSend 100 "fixture-failed-solana")
        beforeFailure<-evalRead reader ReadBalances
        evalWrite writer (FailSolana failedAttempt (money 2) "offline-failure-proof")
        afterFailure<-evalRead reader ReadBalances
        let expected=M.insertWith (+) (Sol,External) 2 $ M.insertWith (+) (Sol,Operating) (-2) beforeFailure
        check (afterFailure==expected)
        evalWrite writer (FailSolana failedAttempt (money 2) "offline-failure-proof")
        evalRead reader ReadBalances >>= check . (==afterFailure)
        expectStore "failure_evidence_conflict" (evalWrite writer $ FailSolana failedAttempt (money 3) "offline-failure-proof")
        failedView<-evalRead reader (ReadPayment ("convert:"<>failedPayment))
        check (savedStatus failedView==PaymentReview)
        evalRead reader PendingAttempts >>= check . null
        evalRead reader PaymentCandidates >>= check . (notElem ("convert:"<>failedPayment))
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        nativeReplacementContract fixtures reader writer
        let tx=T.replicate 64 "d"; did="native:"<>tx<>":0"; hash=T.replicate 64 "e"
            proof=object ["observationHash" .= hash]
            record decision=do snapshot<-evalRead reader (ReadSource did); evalWrite writer (RecordSourceCheck snapshot decision)
        fixture fixtures (SeedReceipt did Nothing Native 50 0 False 100)
        fixture fixtures (SeedSourceEvidence tx hash)
        (savedHash,_)<-evalRead reader (ReadSourceEvidence tx)
        check (savedHash==hash)
        before<-evalRead reader ReadBalances
        initial<-evalRead reader ReadState
        record (W.SourcePending proof)
        candidates<-evalRead reader NativeSourceCandidates
        check (did `elem` map W.depositId candidates)
        (_,evidence)<-evalRead reader (ReadNativeSourceInspection did)
        check (fst evidence==hash)
        ordinary<-evalRead reader ReadState
        check (ledgerSequence ordinary==ledgerSequence initial)
        snapshot<-evalRead reader (ReadSource did)
        expectStore "source_recovery_changed" (evalWrite writer $ RecordSourceCheck snapshot {W.depositAmount=money 49} $ W.SourceMissing proof)
        expectStore "source_recovery_scan_not_current" (record $ W.SourceMissing $ object ["observationHash" .= ("wrong"::T.Text)])
        fixture fixtures ReadyIntake
        record (W.SourceMissing proof)
        missing<-evalRead reader ReadBalances
        missingState<-evalRead reader ReadState
        check (M.findWithDefault 0 (Native,SourceDeficit) missing == M.findWithDefault 0 (Native,SourceDeficit) before-50 && ledgerPaused missingState)
        record (W.SourceMissing proof)
        replay<-evalRead reader ReadState
        check (ledgerSequence replay==ledgerSequence missingState)
        record (W.SourceUnavailable $ object ["reason" .= ("offline"::T.Text)])
        unavailable<-evalRead reader ReadBalances
        check (missing==unavailable)
        unavailableState<-evalRead reader ReadState
        record (W.SourceUnavailable $ object ["reason" .= ("offline"::T.Text)])
        repeated<-evalRead reader ReadState
        check (ledgerSequence repeated==ledgerSequence unavailableState)
        expectStore "invalid_source_recovery_evidence" (record $ W.SourceUnavailable Null)
        expectStore "invalid_source_recovery_evidence" (record $ W.SourceUnavailable $ object ["reason" .= T.replicate 17000 "a"])
        expectStore "source_recovery_scan_not_current" (record $ W.SourceRestored proof)
        fixture fixtures (SourceEligibility did True)
        expectStore "source_recovery_changed" (evalWrite writer $ RecordSourceCheck snapshot $ W.SourceRestored proof)
        record (W.SourceRestored proof)
        restored<-evalRead reader ReadBalances
        check (M.filter (/=0) before==M.filter (/=0) restored)
        restoredState<-evalRead reader ReadState
        record (W.SourceRestored proof)
        restoredReplay<-evalRead reader ReadState
        check (ledgerPaused restoredReplay && ledgerSequence restoredReplay==ledgerSequence restoredState)
        -- A covered loss returns the exact saved capital split only once.
        fixture fixtures (SourceEligibility did False)
        record (W.SourceMissing proof)
        loss<-ledgerSequence <$> evalRead reader ReadState
        source<-evalRead reader (ReadSource did)
        let block=T.replicate 64 "f"
            lossProof=object ["transaction" .= tx,"output" .= (0::Int),"confirmations" .= (-1::Int),"observationHash" .= hash,"nodeBlock" .= block,"nodeHeight" .= (100::Int)]
            report=object ["matches" .= True,"nativeBlock" .= block,"nativeHeight" .= (100::Int)]
            cover capital earned reason=do
              revision<-evalRead reader ReadCustodyRevision
              evalWrite writer (CoverSourceLoss source loss 100 capital earned reason lossProof (revision,100,True,report))
        expectStore "source_loss_allocation_mismatch" (cover (money 29) (money 20) "test cover")
        revision<-evalRead reader ReadCustodyRevision
        expectStore "source_loss_custody_not_current" (evalWrite writer $ CoverSourceLoss source loss 100 (money 30) (money 20) "test cover" lossProof (revision+1,100,True,report))
        expectStore "source_loss_custody_not_current" (evalWrite writer $ CoverSourceLoss source loss 161 (money 30) (money 20) "test cover" lossProof (revision,100,True,report))
        expectStore "source_loss_custody_view_changed" (evalWrite writer $ CoverSourceLoss source loss 100 (money 30) (money 20) "test cover" lossProof (revision,100,True,object ["matches" .= True,"nativeBlock" .= ("other"::T.Text),"nativeHeight" .= (100::Int)]))
        -- Reserved earned withdrawals are not free capital for loss coverage.
        booked<-evalRead reader ReadBalances
        let earned=M.findWithDefault 0 (Native,Earned) booked
            reserved=min 1000 earned; withdrawal=T.replicate 64 "7"
        check (reserved>0 && earned-reserved<50)
        fixture fixtures RefreshCustody
        void $ evalWrite writer (ReserveFees 100 withdrawal Native (money reserved) "recipient" "protect earned fees")
        expectStore "insufficient_loss_capital" (cover (money 0) (money 50) "test cover")
        void $ evalWrite writer (CancelFees withdrawal "restore earned reserve")
        cover (money 30) (money 20) "test cover"
        covered<-evalRead reader ReadBalances
        check (covered==M.unionWith (+) missing (M.fromList [((Native,Float),-30),((Native,Earned),-20),((Native,SourceDeficit),50)]))
        savedCover<-evalRead reader (ReadLossCover did loss)
        check (savedCover==Just(money 30,money 20,"test cover"))
        coveredState<-evalRead reader ReadState
        cover (money 30) (money 20) "test cover"
        replayedCover<-evalRead reader ReadState
        check (ledgerSequence coveredState==ledgerSequence replayedCover && ledgerPaused replayedCover)
        expectStore "source_loss_cover_conflict" (cover (money 30) (money 20) "changed")
        evalRead reader (ReadSource did) >>= check . not . W.depositEligible
        fixture fixtures (SourceEligibility did True)
        record (W.SourceRestored proof)
        returned<-evalRead reader ReadBalances
        check (M.filter (/=0) before==M.filter (/=0) returned)
        record (W.SourceRestored proof)
        returnedAgain<-evalRead reader ReadBalances
        check (returnedAgain==returned)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        fixture fixtures ReadyIntake
        oid<-evalWrite writer (create newRequest {W.idempotencyKey="scanned-order",W.input=money 10})
        claim<-evalWrite writer (ClaimNative 100 auth oid)
        _<-evalWrite writer (RecordNative auth oid (allocationLabel claim) "scan-address-fixture")
        binding<-evalRead reader (LookupInstruction "scan-address-fixture")
        absentBinding<-evalRead reader (LookupInstruction "unused-address")
        historicalDepth<-evalRead reader (MaximumNativeDepth 1)
        check (fmap (\(boundOrder,_,saved)->(boundOrder,W.nativeDepth saved)) binding==Just(oid,2) && absentBinding==Nothing && historicalDepth>=2)
        let tx=T.replicate 64 "b"; did="native:"<>tx<>":0"
            receipt=W.Deposit did (Just oid) Native (money 10) "block-1" 2 True 100
            event=W.ChainEvent tx "incoming" "block-1" (object ["receipt" .= did])
            batch previous next deposits events=W.ScanBatch "Native" "scan-origin" previous next 100 deposits events
            commit b=evalWrite writer (CommitScan b)
        previous<-evalRead reader (ReadCheckpoint "Native")
        before<-evalRead reader ReadBalances
        commit (batch previous "scan-1" [receipt] [event])
        observed<-evalRead reader ReadBalances
        check (M.findWithDefault 0 (Native,Principal) observed==M.findWithDefault 0 (Native,Principal) before+10)
        commit (batch (Just "scan-1") "scan-1" [receipt {W.depositSeenAt=999}] [event])
        replay<-evalRead reader ReadBalances
        saved<-evalRead reader (ReadSource did)
        check (observed==replay && W.depositSeenAt saved==100)
        expectStore "stale_scan_cursor" (commit $ batch previous "stale" [] [])
        expectStore "scan_origin_mismatch" (commit $ (batch (Just "scan-1") "wrong-origin" [] []) {W.scanOrigin="other"})
        expectStore "conflicting_deposit_evidence" (commit $ batch (Just "scan-1") "conflict" [receipt {W.depositAmount=money 11}] [])
        let provisional=receipt {W.depositId="native:rollback:0"}
        expectStore "invalid_observation_kind" (commit $ batch (Just "scan-1") "rollback" [provisional] [event {W.chainEventKind="invalid"}])
        expectStore "source_deposit_missing" (evalRead reader $ ReadSource "native:rollback:0")
        afterFailure<-evalRead reader ReadBalances
        cursor<-evalRead reader (ReadCheckpoint "Native")
        check (afterFailure==observed && cursor==Just "scan-1")
        evalWrite writer (PromoteDeposit 100 did) >>= check
        workHash<-evalRead reader (ReadSourceWorkHash $ "convert:"<>oid)
        let obligation=("convert:"<>oid,oid,did,"conversion"::T.Text,"Wrapped"::T.Text,9::Int64,"recipient"::T.Text)
            expectedHash=digest $ BL.toStrict $ encode (toJSON [obligation]:replicate 5 (toJSON ([]::[Value])))
        check (workHash==expectedHash)
        commit (batch (Just "scan-1") "scan-2" [receipt {W.depositEligible=False,W.depositConfirmations=0,W.depositAnchor="unconfirmed"}] [event {W.chainEventAnchor="unconfirmed"}])
        fixture fixtures (CheckSuspended oid did workHash) >>= check
        lossState<-evalRead reader ReadState
        check (ledgerPaused lossState && ledgerReason lossState=="source_reorg_review")
        unchanged<-evalRead reader ReadBalances
        check (unchanged==observed)
        evalWrite writer (ScanFailed "Native" 101 "provider_down")
        health<-fixture fixtures (ReadScanHealth "Native")
        cursorAfterFailure<-evalRead reader (ReadCheckpoint "Native")
        check (health==(Just 100,Just "provider_down",101) && cursorAfterFailure==Just "scan-2")
        evalWrite writer (ScanFailed "Native" 102 "provider_down")
        commit (batch (Just "scan-2") "scan-3" [] [])
        recoveredHealth<-fixture fixtures (ReadScanHealth "Native")
        check (recoveredHealth==(Just 100,Nothing,100))
        -- A signature alone cannot explain an outflow; a recorded send intent can.
        fixture fixtures (SeedScanAttempts oid)
        hashWithAttempts<-evalRead reader (ReadSourceWorkHash $ "refund:"<>oid)
        refundView<-evalRead reader (ReadPayment $ "refund:"<>oid)
        check (paymentAmount(savedPayment refundView)==money 10 && paymentAsset(savedPayment refundView)==Native)
        let attemptRows=[("saved-intent"::T.Text,"broadcast_intent"::T.Text,0::Int64,Just(1::Int64),Nothing::Maybe T.Text),
              ("saved-signed","signed",0,Nothing,Nothing)]
            expectedWithAttempts=digest $ BL.toStrict $ encode
              [toJSON [("refund:"<>oid,oid,did,"refund"::T.Text,"Native"::T.Text,10::Int64,"refund"::T.Text)],toJSON [("Native"::T.Text,False,Nothing::Maybe T.Text)],
               toJSON [(0::Int64,"{}"::T.Text,Just("{}"::T.Text),Nothing::Maybe T.Text,False)],
               toJSON attemptRows,toJSON ([]::[Value]),toJSON ([]::[Value])]
        check (hashWithAttempts/=workHash && hashWithAttempts==expectedWithAttempts)
        fixture fixtures ReadyIntake
        commit (batch (Just "scan-3") "scan-4" [] [W.ChainEvent "saved-signed" "outgoing" "anchor" (object [])])
        signedReview<-fixture fixtures (ReadEventReview "Native" "saved-signed")
        check (signedReview==1)
        fixture fixtures ReadyIntake
        commit (batch (Just "scan-4") "scan-5" [] [W.ChainEvent "saved-intent" "outgoing" "anchor" (object [])])
        knownReview<-fixture fixtures (ReadEventReview "Native" "saved-intent")
        knownState<-evalRead reader ReadState
        check (knownReview==0 && not(ledgerPaused knownState))
        let spend=W.ChainEvent "operator-spend" "outgoing" "anchor" (object ["walletNetUnits" .= ("-25"::T.Text),"feeUnits" .= money 1])
        commit (batch (Just "scan-5") "scan-6" [] [spend])
        fixture fixtures (ApproveScanSpend spend)
        fixture fixtures ReadyIntake
        commit (batch (Just "scan-6") "scan-7" [] [spend])
        approved<-fixture fixtures (ReadEventReview "Native" "operator-spend")
        approvedState<-evalRead reader ReadState
        check (approved==0 && not(ledgerPaused approvedState))
        commit (batch (Just "scan-7") "scan-8" [] [spend {W.chainEventAnchor="changed"}])
        disputed<-fixture fixtures (ReadEventReview "Native" "operator-spend")
        check (disputed==1)
        commit (batch (Just "scan-8") "scan-9" [] [spend])
        sticky<-fixture fixtures (ReadEventReview "Native" "operator-spend")
        check (sticky==1)
        wrapped<-evalRead reader (ReadSource "wrapped-source")
        solCursor<-evalRead reader (ReadCheckpoint "Solana")
        let solBatch prior next deposit=W.ScanBatch "Solana" "sol-origin" prior next 110 [deposit] []
        expectStore "scan_asset_mismatch" (commit $ solBatch solCursor "wrong-asset" receipt)
        let waiting=W.ChainEvent "waiting-proof" "awaiting_verifier" "slot" (object [])
        commit ((solBatch solCursor "sol-1" wrapped {W.depositEligible=False}) {W.scanEvents=[waiting]})
        pending<-evalRead reader PendingVerification
        check (pending==["waiting-proof"])
        fixture fixtures (LatestSourceState "wrapped-source") >>= check . (=="unavailable")
        commit ((solBatch (Just "sol-1") "sol-2" wrapped) {W.scanEvents=[waiting {W.chainEventKind="incoming"}]})
        cleared<-evalRead reader PendingVerification
        check (null cleared)
        fixture fixtures (LatestSourceState "wrapped-source") >>= check . (=="restored")
        case W.depositOrder wrapped of
          Just order->do view<-evalRead reader (ReadOrder auth order); check (W.status view=="NeedsReview")
          Nothing->fail "bound receipt required"
        fixture fixtures ResetOperatingScan
        beforeSol<-evalRead reader ReadBalances
        let funding=W.Deposit "sol-operating:fixture" Nothing Sol (money 3) "slot" 1 True 110
        commit (W.ScanBatch "SolanaOperating" "opening-signature" Nothing "opening-signature" 110 [funding] [])
        afterSol<-evalRead reader ReadBalances
        check (M.findWithDefault 0 (Sol,Unallocated) afterSol==M.findWithDefault 0 (Sol,Unallocated) beforeSol+3)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer->do
        fixture fixtures OrderWorkflowFunds
        orderWorkflowContract fixtures reader writer (store policy limits)
        restorationContract fixtures reader writer
        refundContract fixtures reader writer
        cancellationContract fixtures reader writer
        expiryContract fixtures reader writer
        treasuryContract fixtures reader writer
        -- Actual runtime cycle with unavailable RPC: retain all money, stay
        -- paused, record scanner failures, and never reach signer credentials.
        let cycleKey=T.replicate 32 "1"
            cycleNative=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused/credential" "ecx-bridge-test"
              16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
            cycleSolana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing cycleKey cycleKey cycleKey
            cyclePolicy=H.SolanaPolicy "contract" "contract" cycleKey cycleKey cycleKey (money 10) (money 10)
        beforeCycle<-evalRead reader ReadBalances
        pendingBeforeCycle<-evalRead reader PendingAttempts
        bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> reject "offline_cycle_rpc"}) closeManager $ \manager ->
          withRuntime manager (ObserverSettings cycleNative cycleSolana 2 "sol-origin" "opening-signature") cyclePolicy Nothing (SigningEndpoint 9443 "/unused/auth") reader writer $ \interpret _customer _operator ->
            do
              interpret (Request $ ReconcilePayment "expiry-signed-0")
              void (try (interpret $ Request RunWorkerCycle) :: IO (Either BridgeError ()))
        evalRead reader ReadBalances >>= check . (==beforeCycle)
        evalRead reader ReadState >>= check . ledgerPaused
        evalRead reader PendingAttempts >>= check . (==pendingBeforeCycle)
        forM_ ["Native","Solana","SolanaOperating"] $ \chain->do
          (_,problem,_)<-fixture fixtures (ReadScanHealth chain)
          check (problem/=Nothing)
      archiveContract settings fixtures reader
      beforeLarge<-evalRead reader ReadBalances
      fixture fixtures LargeBalances
      huge <- evalRead reader ReadBalances
      check (M.lookup (Wrapped,Float) huge==Just (M.findWithDefault 0 (Wrapped,Float) beforeLarge+2*toInteger(maxBound::Int64)))
  putStrLn "PASS: PostgreSQL role isolation, profile binding, exclusive writer, replay, conflicts, custody freshness, earned funds, cancellation, checkpoint rollback/fencing, authorized saved orders, historical terms, backup gating and review overlay"

money :: Integer -> Amount
money = either (error . T.unpack) id . amount
expectStore :: HasCallStack => T.Text -> IO a -> IO ()
expectStore expected action = do
  result <- try action
  case result of
    Left (BridgeError actual) | expected==actual -> pure ()
    Left err -> fail ("expected "<>T.unpack expected<>", unexpected rejection: "<>show err<>"\n"<>prettyCallStack callStack)
    Right _ -> fail ("expected rejection: "<>T.unpack expected<>"\n"<>prettyCallStack callStack)

-- Fixture operations are closed and use Opaleye. They exist only in this test
-- component; no arbitrary SQL or connection callback is available to handlers.
data Fixture a where
  LiveScanHealth :: Fixture [(T.Text,Maybe Int64,Maybe T.Text)]
  SetupResidue :: Fixture ()
  SetPause :: Bool -> Fixture ()
  RestoreDatabases :: Fixture [T.Text]
  ArchiveRecords :: Fixture ([S.Deployment],[S.Attempt],[(Int64,T.Text,T.Text,T.Text,Int64)])
  SourceRecipient :: T.Text -> T.Text -> Fixture ()
  TLSFunds :: Fixture ()
  FreshAt :: Int64 -> Fixture ()
  ChangeTreasuryAnchor :: T.Text -> T.Text -> Fixture ()
  SeedTreasuryEvidence :: T.Text -> T.Text -> T.Text -> T.Text -> Int64 -> Value -> Fixture ()
  LockRestoreAudits :: Fixture [T.Text]
  OrderWorkflowFunds :: Fixture ()
  CustodyHeadReview :: Int64 -> Fixture ()
  SeedCustodyHeads :: Fixture ()
  ReadCustodyCheck :: Fixture (Maybe Int64,Maybe Int64,Maybe T.Text)
  ImmutableAttempt :: T.Text -> Fixture Bool
  CheckFundingBinding :: T.Text -> T.Text -> Fixture Bool
  ResetOperatingScan :: Fixture ()
  LatestSourceState :: T.Text -> Fixture T.Text
  ReadScanHealth :: T.Text -> Fixture (Maybe Int64,Maybe T.Text,Int64)
  ReadEventReview :: T.Text -> T.Text -> Fixture Int64
  CheckSuspended :: T.Text -> T.Text -> T.Text -> Fixture Bool
  SeedScanAttempts :: T.Text -> Fixture ()
  ApproveScanSpend :: W.ChainEvent -> Fixture ()
  SeedSourceEvidence :: T.Text -> T.Text -> Fixture ()
  SourceEligibility :: T.Text -> Bool -> Fixture ()
  OperatingPhase :: T.Text -> T.Text -> Fixture ()
  HistoricalHolds :: T.Text -> Fixture ()
  PromotionFunds :: Fixture ()
  SeedWrappedRevenue :: Fixture ()
  RejectPreparedFeeRelease :: T.Text -> Fixture Bool
  CheckRefundHolds :: T.Text -> Asset -> Fixture Bool
  RefundProof :: T.Text -> T.Text -> T.Text -> Fixture ()
  SeedReceipt :: T.Text -> Maybe T.Text -> Asset -> Int64 -> Int64 -> Bool -> Int64 -> Fixture ()
  CheckPromotion :: T.Text -> T.Text -> Asset -> Int64 -> T.Text -> Fixture Bool
  Initialize :: Fixture ()
  InitializeIdentity :: T.Text -> Fixture ()
  RefreshCustody :: Fixture ()
  SeedOrders :: Fixture ()
  CoverBackup :: Fixture ()
  SeedReview :: Fixture ()
  SeedIntake :: Fixture ()
  ReadyIntake :: Fixture ()
  OrderSnapshot :: Fixture [Int]
  StaleCustody :: Fixture ()
  LargeBalances :: Fixture ()
  CheckHolds :: T.Text -> Direction -> Int64 -> Fixture Bool
  ProtectHolds :: T.Text -> Fixture ()
  CheckPhases :: T.Text -> T.Text -> Fixture Bool
fixture :: PG.Connection -> Fixture a -> IO a
fixture c (SetPause paused) = void $ O.runUpdate c O.Update {O.uTable=S.deployment,
  O.uUpdateWith= \row->row {S.paused=O.sqlInt8 (if paused then 1 else 0)},
  O.uWhere= \row->S.singleton row O..== O.sqlInt8 1,O.uReturning=O.rCount}
fixture c RestoreDatabases = O.runSelect c $ O.orderBy (O.asc id) $ do
  name<-O.selectTable $ O.tableWithSchema "pg_catalog" "pg_database" (O.requiredTableField "datname")
  O.where_ (O.like name $ O.sqlStrictText "ecx_restore_%")
  pure name
fixture c LiveScanHealth = O.runSelect c $ O.orderBy (O.asc $ \(chain,_,_)->chain) $ do
  (chain,at,problem,_)<-O.selectTable S.scanHealth
  pure (chain,at,problem)
fixture c SetupResidue = void $ O.runInsert c O.Insert {O.iTable=S.events,
  O.iRows=[(O.sqlStrictText "orphaned-ledger-event",O.sqlStrictText "initialization must refuse surviving history")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c ArchiveRecords = (,,)
  <$> O.runSelect c (O.selectTable S.deployment)
  <*> O.runSelect c (O.orderBy (O.asc S.attemptId) $ O.selectTable S.attempts)
  <*> O.runSelect c (O.orderBy (O.asc $ \(n,_,_,_,_)->n) $ O.selectTable S.postings)
fixture c (SourceRecipient key recipient) = void $ O.runUpdate c O.Update {O.uTable=S.obligations,
  O.uUpdateWith= \row->row {S.obligationRecipient=O.sqlStrictText recipient},
  O.uWhere= \row->S.obligationId row O..== O.sqlStrictText key,O.uReturning=O.rCount}
fixture c TLSFunds = PG.withTransaction c $ do
  let text=O.sqlStrictText
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "tls-funds",text "offline signing contract funds")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=[(Nothing,text "tls-funds",text asset,text account,O.sqlInt8 n) | (asset,account,n)<-[("Wrapped","earned",10),("Wrapped","external",-10),("Sol","operating",10000000),("Sol","external",-10000000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (FreshAt now) = do
  void $ O.runUpdate c O.Update {O.uTable=S.scanHealth,O.uUpdateWith= \(chain,_,_,_)->(chain,O.toNullable $ O.sqlInt8 now,O.null,O.sqlInt8 now),O.uWhere=const $ O.sqlBool True,O.uReturning=O.rCount}
  void $ O.runUpdate c O.Update {O.uTable=S.custody,O.uUpdateWith= \(key,revision,_,_,_)->(key,revision,O.toNullable revision,O.toNullable $ O.sqlInt8 now,O.null),O.uWhere=const $ O.sqlBool True,O.uReturning=O.rCount}
fixture c LockRestoreAudits = O.runSelect c $ do
  (_,kind,subject)<-O.selectTable S.audit
  O.where_ (kind O..== O.sqlStrictText "native_locks_restored")
  pure subject
fixture c Initialize = fixture c (InitializeIdentity "contract")
fixture c (InitializeIdentity identity) = PG.withTransaction c $ do
  void $ O.runInsert c O.Insert {O.iTable=S.deployment,O.iRows=[S.Deployment (O.sqlInt8 1) (O.sqlInt8 21) (O.sqlStrictText identity) (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "test")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.custody,O.iRows=[(O.sqlInt8 1,O.sqlInt8 0,O.null,O.null,O.null)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(O.sqlStrictText "fixture",O.sqlStrictText "contract balances")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=[(Nothing,O.sqlStrictText "fixture",O.sqlStrictText "Native",O.sqlStrictText account,O.sqlInt8 delta)| (account,delta)<-[("external",-1000),("earned",1000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  fixture c RefreshCustody
fixture c RefreshCustody = do
  n <- O.runUpdate c O.Update {O.uTable=S.custody,O.uUpdateWith= \(key,revision,_,_,_)->(key,revision,O.toNullable revision,O.toNullable $ O.sqlInt8 100,O.null),O.uWhere= \(key,_,_,_,_)->key O..== O.sqlInt8 1,O.uReturning=O.rCount}
  unless (n==1) (fail "custody fixture missing")

fixture c SeedOrders = PG.withTransaction c $ do
  sequences <- O.runSelect c (fmap S.criticalSequence $ O.selectTable S.deployment)
  sequenceNumber <- case sequences of [n]->pure n; _->fail "fixture deployment missing"
  let cap=either (error . T.unpack) id (capabilityHash $ T.replicate 64 "0")
      raw value=TE.decodeUtf8 (BL.toStrict $ encode value)
      request=W.OrderRequest NativeToWrapped (money 100) "recipient" "refund" Nothing "placeholder"
      savedQuote=either (error . T.unpack) id (historicalQuote (money 100) (money 7))
  forM_ ["hidden","visible","mismatch","corrupt"] $ \identifier -> do
    let policy=W.PolicySnapshot 2 "finalized" (if identifier=="mismatch" then "wrong" else "contract")
        row=S.Order (O.sqlStrictText identifier) (O.sqlStrictText cap) (O.sqlStrictText identifier)
          (O.sqlStrictText "fixture") (O.sqlStrictText $ raw request {W.idempotencyKey=identifier})
          (O.sqlStrictText $ if identifier=="corrupt" then "{}" else raw savedQuote) (O.sqlStrictText $ raw policy)
          (O.sqlStrictText "AwaitingDeposit") (O.sqlInt8 200) (O.sqlInt8 300)
          (O.toNullable $ O.sqlStrictText $ "instruction-"<>identifier) (O.toNullable $ O.sqlInt8 sequenceNumber)
          O.null (O.sqlInt8 $ if identifier=="visible" then 1 else 0)
    void $ O.runInsert c O.Insert {O.iTable=S.orders,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c CoverBackup = void $ O.runUpdate c O.Update {O.uTable=S.deployment,
  O.uUpdateWith= \r->r {S.backupSequence=S.criticalSequence r},O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
fixture c SeedReview = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.deposits,O.iRows=[S.Deposit (text "review-deposit") (O.toNullable $ text "visible") (text "Native") (num 100) (text "anchor") (num 100) (num 2) (num 1) (num 1) (text "observed")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.obligations,O.iRows=[S.Obligation (text "review-obligation") (text "visible") (text "review-deposit") (text "conversion") (text "Wrapped") (num 93) (text "recipient") (text "review")],O.iReturning=O.rCount,O.iOnConflict=Nothing}

fixture c SeedIntake = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "intake-capital",text "test inventory and operating funds")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text "intake-capital",text asset,text account,num n)| (asset,account,n)<-
      [("Native","external",-1100),("Native","float",1000),("Native","operating",100),
       ("Wrapped","external",-1000),("Wrapped","float",1000),("Sol","external",-100),("Sol","operating",100)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.operatingClock,O.iRows=[(num 1,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.scanHealth,O.iRows=[(text chain,O.toNullable $ num 100,O.null,num 100)|chain<-["Native","Solana","SolanaOperating"]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.checkpoints,O.iRows=[(text chain,text "fixture-anchor")|chain<-["Native","Solana","SolanaOperating"]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c ReadyIntake = PG.withTransaction c $ do
  void $ O.runUpdate c O.Update {O.uTable=S.deployment,O.uUpdateWith= \r->r {S.paused=O.sqlInt8 0},O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
  fixture c RefreshCustody
fixture c OrderSnapshot = do
  orders <- O.runSelect c (fmap S.orderId $ O.selectTable S.orders) :: IO [T.Text]
  holds <- O.runSelect c (fmap (\(key,_,_,_)->key) $ O.selectTable S.reservations) :: IO [T.Text]
  costs <- O.runSelect c (fmap (\(key,_,_,_)->key) $ O.selectTable S.orderCosts) :: IO [T.Text]
  allowances <- O.runSelect c (fmap (\(key,_,_,_,_)->key) $ O.selectTable S.operatingReservations) :: IO [T.Text]
  pure (map length [orders,holds,costs,allowances])

fixture c StaleCustody = void $ O.runUpdate c O.Update {O.uTable=S.custody,
  O.uUpdateWith= \(key,revision,checked,_,problem)->(key,revision,checked,O.toNullable $ O.sqlInt8 39,problem),
  O.uWhere= \(key,_,_,_,_)->key O..== O.sqlInt8 1,O.uReturning=O.rCount}
fixture c (CheckHolds identifier direction quantity) = do
  inventory <- O.runSelect c $ do
    (key,asset,n,phase) <- O.selectTable S.reservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure (asset,n,phase)
    :: IO [(T.Text,Int64,T.Text)]
  costs <- O.runSelect c $ do
    (key,kind,asset,n,phase) <- O.selectTable S.operatingReservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure (kind,asset,n,phase)
    :: IO [(T.Text,T.Text,Int64,T.Text)]
  let nativeKind=if direction==WrappedToNative then "conversion" else "refund"
      solanaKind=if direction==NativeToWrapped then "conversion" else "refund"
  pure (inventory==[(T.pack $ show $ destinationAsset direction,quantity,"quote")] &&
    sort costs==sort [(nativeKind,"Native",10,"quote"),(solanaKind,"Sol",20,"quote")])

fixture c LargeBalances = PG.withTransaction c $ do
  let text=O.sqlStrictText
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "large-balances",text "exact aggregation past Int64")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text "large-balances",text "Wrapped",text account,O.sqlInt8 n)| (account,n)<-
      [("external",negate maxBound),("float",maxBound),("external",negate maxBound),("float",maxBound)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}

fixture c (ProtectHolds identifier) = PG.withTransaction c $ do
  void $ O.runUpdate c O.Update {O.uTable=S.reservations,
    O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlStrictText "obligation"),
    O.uWhere= \(key,_,_,_)->key O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
  void $ O.runUpdate c O.Update {O.uTable=S.operatingReservations,
    O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText "obligation"),
    O.uWhere= \(key,_,_,_,_)->key O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
fixture c (CheckPhases identifier expected) = do
  inventory <- O.runSelect c $ do
    (key,_,_,phase) <- O.selectTable S.reservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure phase
    :: IO [T.Text]
  operating <- O.runSelect c $ do
    (key,_,_,_,phase) <- O.selectTable S.operatingReservations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure phase
    :: IO [T.Text]
  pure (inventory==[expected] && operating==[expected,expected])

fixture c PromotionFunds = PG.withTransaction c $ do
  let text=O.sqlStrictText
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "promotion-funds",text "test operating budget")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text "promotion-funds",text asset,text account,O.sqlInt8 n)|asset<-["Native","Sol"],(account,n)<-[("external",-10000),("operating",10000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c SeedWrappedRevenue = PG.withTransaction c $ do
  let text=O.sqlStrictText
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "expiry-earned",text "offline earned-payment funding")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=[(Nothing,text "expiry-earned",text "Wrapped",text account,O.sqlInt8 n) | (account,n)<-[("external",-10),("earned",10)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (RejectPreparedFeeRelease key) = do
  result<-try $ PG.withTransaction c $ O.runInsert c O.Insert {O.iTable=S.cancellations,
    O.iRows=[(O.sqlStrictText key,O.sqlStrictText "bypass prepared work",O.sqlInt8 1000000)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    :: IO (Either PG.SqlError Int64)
  pure $ case result of Left err->PG.sqlState err=="23514" && PG.sqlErrorMsg err=="fee_withdrawal_cancellation_binding"; _->False
fixture c (CheckRefundHolds oid asset) = do
  rows<-O.runSelect c $ do
    (key,kind,currency,_,phase)<-O.selectTable S.operatingReservations
    O.where_ (key O..== O.sqlStrictText oid)
    pure (kind,currency,phase)
    :: IO [(T.Text,T.Text,T.Text)]
  pure (length rows==2 && ("refund",T.pack(show asset),"obligation") `elem` rows && all (\(kind,_,phase)->kind/="conversion" || phase=="released") rows)
fixture c (RefundProof signature instruction owner) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      hash="refund-proof:"<>signature
      proof=text $ TE.decodeUtf8 $ BL.toStrict $ encode $ object ["proof" .= object ["instruction" .= instruction,"verifiedOwner" .= owner]]
  void $ O.runInsert c O.Insert {O.iTable=S.observationEvidence,O.iRows=[(text hash,text "Solana",text signature,proof)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.chainEvents,O.iRows=[S.ChainEvent (text "Solana") (text signature) (text "incoming") (text "fixture-anchor") (text hash) (num 110) (num 110) (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (SeedReceipt did oid asset quantity depth eligible seen) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      account=maybe "unallocated" (const "principal") oid
  void $ O.runInsert c O.Insert {O.iTable=S.deposits,
    O.iRows=[S.Deposit (text did) (maybe O.null (O.toNullable . text) oid) (text $ T.pack $ show asset)
      (num quantity) (text "fixture-anchor") (num seen) (num depth) (num $ if eligible then 1 else 0) (num 0) (text "observed")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text $ "deposit:"<>did,text "fixture observed value")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,
    O.iRows=[(Nothing,text $ "deposit:"<>did,text $ T.pack $ show asset,text target,num n)| (target,n)<-[(account,quantity),("external",negate quantity)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (CheckPromotion oid did asset quantity status) = do
  obligations<-O.runSelect c $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationOrder row O..== O.sqlStrictText oid)
    pure row
    :: IO [S.Obligation]
  deposits<-O.runSelect c $ do
    row<-O.selectTable S.deposits
    O.where_ (S.depositId row O..== O.sqlStrictText did)
    pure (S.depositAllocated row)
    :: IO [Int64]
  orders<-O.runSelect c $ do
    row<-O.selectTable S.orders
    O.where_ (S.orderId row O..== O.sqlStrictText oid)
    pure (S.status row)
    :: IO [T.Text]
  pure (obligations==[S.Obligation ("convert:"<>oid) oid did "conversion" (T.pack $ show asset) quantity "recipient" "ready"] && deposits==[1] && orders==[status])

fixture c (OperatingPhase oid phase) = void $ O.runUpdate c O.Update {O.uTable=S.operatingReservations,
  O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText phase),
  O.uWhere= \(key,_,_,_,_)->key O..== O.sqlStrictText oid,O.uReturning=O.rCount}
fixture c (HistoricalHolds oid) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      raw value=TE.decodeUtf8 (BL.toStrict $ encode value)
      cap=either (error . T.unpack) id (capabilityHash $ T.replicate 64 "0")
      request=W.OrderRequest NativeToWrapped (money 100) "recipient" "refund" Nothing oid
      saved=either (error . T.unpack) id (historicalQuote (money 100) (money 7))
  void $ O.runInsert c O.Insert {O.iTable=S.orders,
    O.iRows=[S.Order (text oid) (text cap) (text oid) (text "fixture") (text $ raw request) (text $ raw saved)
      (text $ raw $ W.PolicySnapshot 2 "finalized" "contract") (text "AwaitingDeposit") (num 200) (num 300)
      (O.toNullable $ text "historical-native-fixture") (O.toNullable $ num 0) O.null (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.reservations,O.iRows=[(text oid,text "Wrapped",num 93,text "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.orderCosts,O.iRows=[(text oid,num 10,num 10,num 10)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.operatingReservations,
    O.iRows=[(text oid,text kind,text asset,num n,text "quote") | (kind,asset,n)<-[("conversion","Sol",20),("refund","Native",10)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}

fixture c (ChangeTreasuryAnchor chain key) = void $ O.runUpdate c O.Update {O.uTable=S.chainEvents,
  O.uUpdateWith= \row->row {S.eventAnchor=O.sqlStrictText "changed-anchor",S.eventReview=O.sqlInt8 1},
  O.uWhere= \row->S.eventChain row O..== O.sqlStrictText chain O..&& S.eventId row O..== O.sqlStrictText key,O.uReturning=O.rCount}
fixture c (SeedTreasuryEvidence chain key anchor kind review proof) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      raw=TE.decodeUtf8 $ BL.toStrict $ encode $ object ["chain" .= chain,"id" .= key,"anchor" .= anchor,"kind" .= kind,"proof" .= proof]
      hash=digest (TE.encodeUtf8 raw)
  prior<-O.runSelect c $ do
    (h,_,_,_)<-O.selectTable S.observationEvidence
    O.where_ (h O..== text hash)
    pure h
    :: IO [T.Text]
  when (null prior) $ void $ O.runInsert c O.Insert {O.iTable=S.observationEvidence,O.iRows=[(text hash,text chain,text key,text raw)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  changed<-O.runUpdate c O.Update {O.uTable=S.chainEvents,
    O.uUpdateWith= \event->event {S.eventAnchor=text anchor,S.eventKind=text kind,S.eventHash=text hash,S.eventReview=num review},
    O.uWhere= \event->S.eventChain event O..== text chain O..&& S.eventId event O..== text key,O.uReturning=O.rCount}
  when (changed==0) $ void $ O.runInsert c O.Insert {O.iTable=S.chainEvents,O.iRows=[S.ChainEvent (text chain) (text key) (text kind) (text anchor) (text hash) (num 110) (num 110) (num review)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (SeedSourceEvidence tx hash) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
      heads=O.table "chain_events" $ p8 (O.requiredTableField "chain",O.requiredTableField "event_id",O.requiredTableField "kind",O.requiredTableField "anchor",O.requiredTableField "evidence_hash",O.requiredTableField "first_seen",O.requiredTableField "last_seen",O.requiredTableField "needs_review")
  void $ O.runInsert c O.Insert {O.iTable=S.observationEvidence,O.iRows=[(text hash,text "Native",text tx,text "{}")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=heads,O.iRows=[(text "Native",text tx,text "unmatched_incoming",text "fixture-anchor",text hash,num 100,num 100,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (SourceEligibility did eligible) = void $ O.runUpdate c O.Update {O.uTable=S.deposits,
  O.uUpdateWith= \r->r {S.depositEligible=O.sqlInt8 $ if eligible then 1 else 0},
  O.uWhere= \r->S.depositId r O..== O.sqlStrictText did,O.uReturning=O.rCount}
fixture c (ReadScanHealth chain) = do
  rows<-O.runSelect c $ do
    (key,success,failure,at)<-O.selectTable S.scanHealth
    O.where_ (key O..== O.sqlStrictText chain)
    pure (success,failure,at)
  case rows of [row]->pure row; _->fail "missing scan health"
fixture c (ReadEventReview chain identifier) = do
  rows<-O.runSelect c $ do
    row<-O.selectTable S.chainEvents
    O.where_ (S.eventChain row O..== O.sqlStrictText chain O..&& S.eventId row O..== O.sqlStrictText identifier)
    pure (S.eventReview row)
  case rows of [row]->pure row; _->fail "missing chain event"
fixture c (CheckSuspended oid did hash) = do
  obligations<-O.runSelect c $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationOrder row O..== O.sqlStrictText oid)
    pure (S.obligationStatus row)
    :: IO [T.Text]
  proofs<-O.runSelect c $ do
    (_,key,state,_,proof,_)<-O.selectTable S.sourceChecks
    O.where_ (key O..== O.sqlStrictText did)
    pure (state,proof)
    :: IO [(T.Text,T.Text)]
  let expected=object ["reason" .= ("source_eligibility_lost"::T.Text),"previousAnchor" .= ("block-1"::T.Text),
        "anchor" .= ("unconfirmed"::T.Text),"reviewedObligations" .= [object ["intent" .= ("convert:"<>oid),"previousStatus" .= ("ready"::T.Text),"workHash" .= hash]]]
  pure (obligations==["review"] && case proofs of [("unavailable",raw)]->eitherDecodeStrict' (TE.encodeUtf8 raw)==Right expected; _->False)
fixture c (SeedScanAttempts oid) = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8; intent="refund:"<>oid
      intents=O.table "intents" $ p5 (O.requiredTableField "id",O.requiredTableField "obligation_id",O.requiredTableField "chain",O.requiredTableField "common_input",O.requiredTableField "resolved")
      preparations=O.table "preparations" $ p6 (O.requiredTableField "intent_id",O.requiredTableField "generation",O.requiredTableField "policy_json",O.requiredTableField "draft_json",O.requiredTableField "retired_txid",O.requiredTableField "cancelled")
      attempts=O.table "attempts" $ p9 (O.requiredTableField "txid",O.requiredTableField "intent_id",O.requiredTableField "signed_bytes",O.requiredTableField "policy_json",O.requiredTableField "fee_limit",O.requiredTableField "state",O.requiredTableField "critical_sequence",O.requiredTableField "observation_json",O.requiredTableField "preparation_generation")
  sources<-O.runSelect c $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationId row O..== text ("convert:"<>oid))
    pure (S.obligationDeposit row)
  source<-case sources of [did]->pure did; _->fail "missing scan source"
  void $ O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text "cancelled"},
    O.uWhere= \r->S.obligationId r O..== text ("convert:"<>oid),O.uReturning=O.rCount}
  void $ O.runInsert c O.Insert {O.iTable=S.obligations,
    O.iRows=[S.Obligation (text intent) (text oid) (text source) (text "refund") (text "Native") (num 10) (text "refund") (text "review")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=intents,O.iRows=[(text intent,text intent,text "Native",O.null,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=preparations,O.iRows=[(text intent,num 0,text "{}",O.toNullable $ text "{}",O.null,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=attempts,
    O.iRows=[(text tx,text intent,text "fixture-bytes",text "{}",num 1,text state,sequenceNo,O.null,num 0) |
      (tx,state,sequenceNo)<-[("saved-signed","signed",O.null),("saved-intent","broadcast_intent",O.toNullable $ num 1)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c (ApproveScanSpend event) = PG.withTransaction c $ do
  let text=O.sqlStrictText
      spends=O.table "treasury_spends" $ p6 (O.requiredTableField "chain",O.requiredTableField "event_id",O.requiredTableField "anchor",O.requiredTableField "economic_json",O.requiredTableField "proof_json",O.requiredTableField "critical_sequence")
  economic<-either (fail . T.unpack) pure (W.economicOutflow "Native" $ W.chainEventEvidence event)
  void $ O.runInsert c O.Insert {O.iTable=spends,O.iRows=[(text "Native",text $ W.chainEventId event,text $ W.chainEventAnchor event,text $ TE.decodeUtf8 $ BL.toStrict $ encode economic,text "{}",O.sqlInt8 1)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runUpdate c O.Update {O.uTable=S.chainEvents,O.uUpdateWith= \r->r {S.eventReview=O.sqlInt8 0},
    O.uWhere= \r->S.eventChain r O..== text "Native" O..&& S.eventId r O..== text (W.chainEventId event),O.uReturning=O.rCount}

fixture c ResetOperatingScan = void $ O.runDelete c O.Delete {O.dTable=S.checkpoints,
  O.dWhere= \(chain,_)->chain O..== O.sqlStrictText "SolanaOperating",O.dReturning=O.rCount}
fixture c (LatestSourceState did) = do
  rows<-O.runSelect c $ fmap snd $ O.limit 1 $ O.orderBy (O.desc fst) $ do
    (key,source,state,_,_,_)<-O.selectTable S.sourceChecks
    O.where_ (source O..== O.sqlStrictText did)
    pure (key,state)
  case rows of [state]->pure state; _->fail "missing source recovery"

fixture c (CheckFundingBinding identifier withdrawal) = do
  rows<-O.runSelect c $ do
    row<-O.selectTable S.intents
    O.where_ (S.intentId row O..== O.sqlStrictText identifier)
    pure (S.intentObligation row,S.intentWithdrawal row)
    :: IO [(Maybe T.Text,Maybe T.Text)]
  changed<-try (O.runUpdate c O.Update {O.uTable=S.intents,O.uUpdateWith= \r->r {S.intentChain=O.sqlStrictText "Solana"},O.uWhere= \r->S.intentId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}) :: IO (Either PG.SqlError Int64)
  pure (rows==[(Nothing,Just withdrawal)] && case changed of Left err->PG.sqlState err=="23514"; _->False)

fixture c (ImmutableAttempt identifier) = do
  result<-try (O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptBytes=O.sqlStrictText "modified"},
    O.uWhere= \r->S.attemptId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}) :: IO (Either PG.SqlError Int64)
  pure $ case result of Left err->PG.sqlState err=="23514"; _->False

fixture c SeedCustodyHeads = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.scanOrigins,O.iRows=[(text chain,text origin) |
    (chain,origin)<-[("Native","scan-origin"),("Solana","sol-origin"),("SolanaOperating","opening-signature")]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  forM_ ["Solana","SolanaOperating"] $ \chain->do
    void $ O.runUpdate c O.Update {O.uTable=S.checkpoints,O.uUpdateWith= \(key,_)->(key,text $ T.replicate 64 "1"),O.uWhere= \(key,_)->key O..== text chain,O.uReturning=O.rCount}
    let proof=text $ TE.decodeUtf8 $ BL.toStrict $ encode $ object ["proof" .= object []]
    void $ O.runInsert c O.Insert {O.iTable=S.observationEvidence,O.iRows=[(text chain,text chain,text (T.replicate 64 "1"),proof)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    void $ O.runInsert c O.Insert {O.iTable=S.chainEvents,O.iRows=[S.ChainEvent (text chain) (text $ T.replicate 64 "1") (text "reference") (text "42") (text chain) (num 100) (num 100) (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c ReadCustodyCheck = do
  rows<-O.runSelect c $ fmap (\(_,_,revision,at,problem)->(revision,at,problem)) (O.selectTable S.custody)
  case rows of [row]->pure row; _->fail "missing custody check"

fixture c (CustodyHeadReview flag) = void $ O.runUpdate c O.Update {O.uTable=S.chainEvents,
  O.uUpdateWith= \r->r {S.eventReview=O.sqlInt8 flag},O.uWhere= \r->S.eventChain r O..== O.sqlStrictText "Solana"
    O..&& S.eventId r O..== O.sqlStrictText (T.replicate 64 "1"),O.uReturning=O.rCount}

fixture c OrderWorkflowFunds = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text "workflow-funds",text "offline order workflow funds")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=[(Nothing,text "workflow-funds",text asset,text account,num quantity) |
    (asset,account,quantity)<-[("Native","external",-20000),("Native","float",10000),("Native","operating",10000),
      ("Wrapped","external",-10000),("Wrapped","float",10000),("Sol","external",-10000),("Sol","operating",10000)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runUpdate c O.Update {O.uTable=S.scanHealth,O.uUpdateWith= \(chain,_,_,_)->(chain,O.toNullable $ num 110,O.null,num 110),O.uWhere=const $ O.sqlBool True,O.uReturning=O.rCount}
  void $ O.runUpdate c O.Update {O.uTable=S.deployment,O.uUpdateWith= \r->r {S.paused=num 0},O.uWhere=const $ O.sqlBool True,O.uReturning=O.rCount}
  fixture c RefreshCustody

-- Offline RPC contracts over an actual PostgreSQL snapshot. No live-chain claim.
custodyContract :: PG.Connection -> Reader -> IO ()
custodyContract fixtures reader = do
  let key=T.replicate 32 "1"; signature=T.replicate 64 "1"; block=T.replicate 64 "a"
      config=H.SolanaPolicy "contract" "contract" key key key (money 10) (money 10)
      native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused" "test" 1 "scan-origin"
      solana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing key key key
      settings=ObserverSettings native solana 2 "sol-origin" "opening-signature"
      balance=object ["mine" .= object ["trusted" .= (0.000021::Double),"untrusted_pending" .= (0::Int),"immature" .= (0::Int)],
        "lastprocessedblock" .= object ["hash" .= block,"height" .= (100::Int)]]
      nativeCall wallet method params=case (wallet,method,params) of
        (True,"getbalances",[])->pure balance
        (True,"listsinceblock",[String "fixture-anchor",Number 2,Bool False,Bool True])->pure $ object
          ["lastblock" .= ("fixture-anchor"::T.Text),"transactions" .= ([]::[Value]),"removed" .= ([]::[Value])]
        (False,"getblockhash",[Number 100])->pure $ String block
        _->fail "unexpected custody native RPC"
      token n=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object
        ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::T.Text),"info" .= object
          ["mint" .= key,"owner" .= key,"state" .= ("initialized"::T.Text),"isNative" .= False,
           "tokenAmount" .= object ["amount" .= T.pack(show (n::Int)),"decimals" .= (8::Int)]]]]]
      owner=object ["owner" .= key,"executable" .= False,"data" .= ["","base64"::T.Text],"lamports" .= (100::Int)]
      solCall n headSignature method params=case (method,params) of
        ("getMultipleAccounts",[addresses,options])->do
          minimumSlot<-fieldValue "minContextSlot" options :: IO Int
          commitment<-fieldValue "commitment" options :: IO T.Text
          unless (addresses==toJSON [key,key] && minimumSlot==42 && commitment=="finalized") (fail "incorrect custody account request")
          pure $ object ["context" .= object ["slot" .= (42::Int)],"value" .= [token n,owner]]
        ("getSignaturesForAddress",[String address,options])->do
          limit<-fieldValue "limit" options :: IO Int
          minimumSlot<-fieldValue "minContextSlot" options :: IO Int
          unless (address==key && limit==1 && minimumSlot==42) (fail "incorrect custody history request")
          pure $ toJSON [object ["signature" .= headSignature,"slot" .= (42::Int),"err" .= Null,"confirmationStatus" .= ("finalized"::T.Text)]]
        _->fail "unexpected custody Solana RPC"
      inspect clock identity ncall scall verifier cfg=inspectCustodyWith clock identity ncall scall verifier cfg config reader False
      good=solCall 1000 signature
  identities<-newIORef (0::Int)
  (_,at,matches,_)<-inspect (pure 100) (modifyIORef' identities (+1)) nativeCall good Nothing settings
  count<-readIORef identities
  unless (at==100 && matches && count==1) (fail "custody inspection failed")
  (_,_,mismatch,_)<-inspect (pure 100) (pure ()) nativeCall (solCall 999 signature) Nothing settings
  when mismatch (fail "custody accepted unequal balances")
  expectStore "custody_solana_history_advanced" (inspect (pure 100) (pure ()) nativeCall (solCall 1000 $ T.replicate 63 "1"<>"2") Nothing settings)
  expectStore "custody_verifier_disagreement" (inspect (pure 100) (pure ()) nativeCall good (Just $ solCall 999 signature)
    settings {solanaSettings=solana {Solana.solanaVerifierRpc=Just "https://independent.example"}})
  let advanced wallet method params=if method=="listsinceblock" then pure $ object ["lastblock" .= ("advanced"::T.Text)] else nativeCall wallet method params
  expectStore "custody_native_history_advanced" (inspect (pure 100) (pure ()) advanced good Nothing settings)
  samples<-newIORef (0::Int)
  let unstable wallet method params=if method=="getbalances" then do
        count<-atomicModifyIORef' samples (\n->(n+1,n))
        if count==0 then pure balance else pure $ object
          ["mine" .= object ["trusted" .= (0.000022::Double),"untrusted_pending" .= (0::Int),"immature" .= (0::Int)],
           "lastprocessedblock" .= object ["hash" .= block,"height" .= (100::Int)]]
       else nativeCall wallet method params
  expectStore "custody_native_view_changed" (inspect (pure 100) (pure ()) unstable good Nothing settings)
  times<-newIORef [100,161::Int64]
  let clock=atomicModifyIORef' times (\xs->case xs of t:rest->(rest,t); []->([],161))
  expectStore "custody_check_timed_out" (inspect clock (pure ()) nativeCall good Nothing settings)
  let changed wallet method params=do
        value<-nativeCall wallet method params
        when (method=="getblockhash") (fixture fixtures $ CustodyHeadReview 0)
        pure value
  expectStore "custody_ledger_changed" (inspect (pure 100) (pure ()) changed good Nothing settings)
  expectStore "native_reused_balance_requires_review" (nativeBalance $ \_ _ _->pure $ object
    ["mine" .= object ["trusted" .= (0::Int),"untrusted_pending" .= (0::Int),"immature" .= (0::Int),"used" .= (1::Int)]])

orderWorkflowContract :: PG.Connection -> Reader -> Writer -> StorePolicy -> IO ()
orderWorkflowContract fixtures reader writer storePolicy = do
  admissions<-newIORef (0::Int); identities<-newIORef (0::Int); allocations<-newIORef (0::Int)
  label<-newIORef Nothing; loseReply<-newIORef True
  let native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused" "workflow" 1 (T.replicate 64 "0")
      header="Bearer "<>T.replicate 64 "e"
      unwrap=W.OrderRequest WrappedToNative (money 10) "native-recipient" "" Nothing "workflow-unwrap"
      call _ method params=case (method,params) of
        ("getwalletinfo",[])->pure $ object ["walletname" .= ("workflow"::T.Text),"descriptors" .= True,
          "scanning" .= False,"private_keys_enabled" .= True,"external_signer" .= False]
        ("getaddressesbylabel",[String requested])->do
          saved<-readIORef label
          if saved==Just requested then pure $ object ["offline-order-address" .= object ["purpose" .= ("receive"::T.Text)]] else reject "rpc_error_-11"
        ("getnewaddress",[String requested,String "bech32"])->do
          modifyIORef' allocations (+1)
          writeIORef label (Just requested)
          lose<-atomicModifyIORef' loseReply (\old->(False,old))
          if lose then reject "rpc_transport_unknown_outcome" else pure $ String "offline-order-address"
        ("getaddressinfo",[String address])->do
          saved<-readIORef label
          pure $ object ["address" .= address,"ismine" .= True,"solvable" .= True,"ischange" .= False,
            "labels" .= maybe [] pure saved,"scriptPubKey" .= ("0014"<>T.replicate 40 "a")]
        _->fail "unexpected provisioning RPC"
      backup n=evalWrite writer (AcknowledgeBackup "contract" n $ T.replicate 64 "d")
      transport=OrderTransport (pure 110) (const $ modifyIORef' admissions (+1)) (modifyIORef' identities (+1)) call backup
      create=createCustomerOrderWith transport native True reader writer header
      check ok=unless ok (fail "customer workflow contract failed")
  expectStore "invalid_idempotency_key" (create unwrap {W.idempotencyKey=""})
  missing<-evalRead reader (FindOrder header unwrap)
  check (missing==Nothing)
  -- Returning from a backup callback cannot itself authorize exposure.
  expectStore "backup_pending" (createCustomerOrderWith transport {orderBackup=const $ pure ()} native True reader writer header unwrap)
  Just oid<-evalRead reader (FindOrder header unwrap)
  hidden<-evalRead reader (ReadOrder header oid)
  check (W.depositInstruction hidden==Nothing)
  issued<-create unwrap
  check (W.orderId issued==oid && W.status issued=="AwaitingDeposit" && W.depositInstruction issued/=Nothing)
  payable<-evalRead reader (ReadPayableOrder 110 header oid)
  check (payable==issued)
  counts<- (,) <$> readIORef admissions <*> readIORef identities
  fixture fixtures (CustodyHeadReview 0)
  evalWrite writer (Pause "test replay while paused")
  expectStore "intake_paused" (evalRead reader $ ReadPayableOrder 110 header oid)
  replay<-create unwrap
  afterCounts<-(,) <$> readIORef admissions <*> readIORef identities
  check (replay==issued && counts==afterCounts && fst counts==1)
  expectStore "idempotency_conflict" (create unwrap {W.input=money 11})
  expectStore "order_not_found" (evalRead reader $ ReadProvisioning ("Bearer "<>T.replicate 64 "f") oid)
  fixture fixtures ReadyIntake
  let wrapping=unwrap {W.direction=NativeToWrapped,W.recipient="solana-recipient",W.refund="native-refund",W.idempotencyKey="workflow-wrap"}
  expectStore "rpc_transport_unknown_outcome" (create wrapping)
  Just wrapId<-evalRead reader (FindOrder header wrapping)
  recovered<-create wrapping
  expectStore "deposit_window_closed" (evalRead reader $ ReadPayableOrder 110 header wrapId)
  allocated<-readIORef allocations
  check (W.orderId recovered==wrapId && W.depositInstruction recovered==Just "offline-order-address" && allocated==1)
  _<-create wrapping
  readIORef allocations >>= check . (==1)

  let key=T.replicate 32 "1"
      solana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing key key key
      chainSettings=ObserverSettings native solana 2 "sol-origin" "opening-signature"
      config=H.SolanaPolicy "contract" "contract" key key key (money 10) (money 10)
      public=W.PublicConfiguration W.L2LSignetDevnet "devnet" (W.InterfaceConfig Nothing Nothing Nothing Nothing Nothing)
        "contract" key key 8 (money 2) (money 1000) (M.fromList [("NativeToWrapped",100),("WrappedToNative",100)]) False False (W.Availability False "starting")
      customerSettings=CustomerSettings public storePolicy "/unused/sdk"
      endpoint=SigningEndpoint 9443 "/unused/auth"
  bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> fail "runtime replay/read reached network"}) closeManager $ \manager->do
    withRuntime manager chainSettings config (Just customerSettings) endpoint reader writer $ \worker customer operatorControl->do
      service<-operatorControl (Op.operatorRead Op.ServiceState)
      ledgerBefore<-evalRead reader ReadState
      check (W.paused service==ledgerPaused ledgerBefore)
      expectStore "observation_only" (operatorControl $ Op.operator Op.ResumeService)
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.CoverLostSource "missing" 1 (money 1) (money 0) "cover")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.ApproveCovered "missing" 1 "covered")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.RestoreSource "missing" 1 "restored")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.ClassifySpend "Native" "missing" "owned")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.AllocateReceipt "missing" [("float",money 1)] "owned")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.WithdrawFees (T.replicate 64 "a") Native (money 1) "recipient" "test")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.CancelFeeWithdrawal "missing" "test")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.RefundDeposit "missing")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.CancelPreparation "missing" 0 "test")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.RetrySolanaPayment "missing" "test")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.DraftNativeReplacement "missing" (money 1) "test")
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.SignNativeReplacement 1)
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.RebroadcastNative "missing" 1 "test")
      expectedReviews<-evalRead reader ReadNativeReviews
      operatorControl (Op.operatorRead Op.NativeReviews) >>= check . (==expectedReviews)
      expectStore "observation_only" (operatorControl $ Op.operator $ Op.CancelNativeReplacement 1 "test")
      operatorControl (Op.operator $ Op.PauseService "operator contract")
      serviceAfter<-operatorControl (Op.operatorRead Op.ServiceState)
      check (W.paused serviceAfter && W.pauseReason serviceAfter=="operator contract")
      publicView<-customer (Op.safe Op.PublicConfig)
      check (W.pubAvailability publicView==W.Availability False "observation_only")
      saved<-customer (Op.safe $ Op.OrderStatus header wrapId)
      check (saved==recovered)
      expectStore "observation_only" (customer $ Op.customer $ Op.CreateOrder header wrapping)
      expectStore "observation_only" (worker $ Request $ SignPreparedPayment "missing")
      expectStore "observation_only" (worker $ Request $ BroadcastPayment "missing")
      expectStore "deposit_window_closed" (customer $ Op.safe $ Op.PaymentInstructions header oid)
      app<-customerApplication customer
      response<-WaiTest.runSession (WaiTest.srequest $ WaiTest.SRequest
        ((WaiTest.setPath Wai.defaultRequest ("/api/v1/orders/"<>TE.encodeUtf8 wrapId))
          {Wai.requestHeaders=[("Authorization",TE.encodeUtf8 header)]}) "") app
      check (statusCode(WaiTest.simpleStatus response)==200 && eitherDecodeStrict' (BL.toStrict $ WaiTest.simpleBody response)==Right recovered)
    withRuntime manager chainSettings config (Just customerSettings {publicConfiguration=public {W.pubIntakeEnabled=True}}) endpoint reader writer $ \_ customer operatorControl->do
      let withdrawal=T.replicate 64 "a"
      before<-evalRead reader ReadState
      result<-operatorControl (Op.operator $ Op.WithdrawFees withdrawal Native (money 100) "recipient" "test owned revenue")
      cancelled<-operatorControl (Op.operator $ Op.CancelFeeWithdrawal withdrawal "cancel")
      after<-evalRead reader ReadState
      check (result=="fee:"<>withdrawal && cancelled==result && ledgerSequence before==ledgerSequence after)
      expectStore "fee_withdrawal_conflict" (operatorControl $ Op.operator $ Op.WithdrawFees withdrawal Native (money 101) "recipient" "test owned revenue")
      expectStore "fee_withdrawal_cancellation_conflict" (operatorControl $ Op.operator $ Op.CancelFeeWithdrawal withdrawal "changed")
      expectStore "invalid_fee_withdrawal" (operatorControl $ Op.operator $ Op.WithdrawFees withdrawal Sol (money 1) "recipient" "test")
      saved<-customer (Op.customer $ Op.CreateOrder header wrapping)
      check (W.depositInstruction saved==W.depositInstruction recovered && W.quote saved==W.quote recovered)
    expectStore "customer_configuration_mismatch" $ withRuntime manager chainSettings config
      (Just customerSettings {publicConfiguration=public {W.pubMint="wrong"}}) endpoint reader writer (\_ _ _->pure ())

  -- A slow checkpoint neither exposes stale instructions nor renews a quote.
  -- Clock/freshness changes are fixtures; this is a PostgreSQL workflow contract.
  fixture fixtures ReadyIntake
  clock<-newIORef 110
  let slow=unwrap {W.idempotencyKey="workflow-slow-backup"}
      delayed=transport {orderClock=readIORef clock,orderBackup= \n->backup n >> writeIORef clock 180}
      resume=createCustomerOrderWith delayed native True reader writer header slow
  expectStore "scanners_not_fresh" resume
  Just slowId<-evalRead reader (FindOrder header slow)
  pending<-evalRead reader (ReadOrder header slowId)
  check (W.depositInstruction pending==Nothing && W.deadline pending==210)
  balances<-evalRead reader ReadBalances
  beforeAdmissions<-readIORef admissions
  fixture fixtures (FreshAt 180)
  completed<-resume
  check (W.orderId completed==slowId && W.quote completed==W.quote pending
    && W.deadline completed==210 && W.depositInstruction completed/=Nothing)
  readIORef admissions >>= check . (==beforeAdmissions)
  evalRead reader ReadBalances >>= check . (==balances)
  let expired=unwrap {W.idempotencyKey="workflow-expired-backup"}
      expires=delayed {orderBackup= \n->backup n >> writeIORef clock 281 >> fixture fixtures (FreshAt 281)}
  expectStore "deposit_window_closed" (createCustomerOrderWith expires native True reader writer header expired)
  Just expiredId<-evalRead reader (FindOrder header expired)
  evalRead reader (ReadOrder header expiredId) >>= check . (==Nothing) . W.depositInstruction
  fixture fixtures (FreshAt 100)

-- Same schema and closed ledger operations, with a real fsynced host watermark.
fenceMain :: IO ()
fenceMain = do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user<-getEnv "USER"; role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  let identity=T.replicate 64 "a"
      settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      terms=PaymentTerms (PolicySnapshot 2 "finalized" identity) (CostLimits (money 10) (money 10) (money 10))
      limits=OrderLimits (money 2) (money 1000) 100 100 100 (money 100000) (money 100000)
      policy=StorePolicy terms limits "fence-test" True
      key=T.replicate 64 "b"
      temporary=do
        (path,handle)<-openTempFile "/tmp" "ecx-fence-store"
        hClose handle
        removeFile path
        createDirectory path
        setFileMode path 0o700
        pure path
  bracket temporary removeDirectoryRecursive $ \directory->do
    bracket (PG.connect settings) PG.close (\c->fixture c $ InitializeIdentity identity)
    withReader settings {PG.connectUser=role} identity True $ \reader->do
      let adopt minimumSequence=evalRestore settings (AdoptLedger directory identity minimumSequence)
          retire minimumSequence=evalRestore settings (RetireLedger directory identity minimumSequence)
          check ok=unless ok (fail "fence adoption contract failed")
      expectStore "invalid_restore_policy" (adopt (-1))
      expectStore "backup_snapshot_too_old" (adopt 1)
      expectStore "ledger_profile_or_schema_mismatch" (evalRestore settings $ AdoptLedger directory (T.replicate 64 "b") 0)
      bracket (PG.connect settings) PG.close (\c->fixture c $ SetPause False)
      expectStore "pause_before_fence_change" (adopt 0)
      bracket (PG.connect settings) PG.close (\c->fixture c $ SetPause True)
      adopt 0 >>= check . (==(T.pack database,0))
      original<-BS.readFile (directory</>"sequence.json")
      _<-adopt 0
      BS.readFile (directory</>"sequence.json") >>= check . (==original)
      Fence.withFence directory identity $ \_->expectStore "worker_fence_locked" (adopt 0)
      withWriter settings policy (const $ pure ()) $ \_->expectStore "worker_already_running" (adopt 0)
      withFencedWriter settings policy directory $ \writer->do
        expectStore "worker_already_running" (adopt 0)
        expectStore "worker_already_running" (retire 0)
        expectStore "worker_fence_locked" (withFencedWriter settings policy directory $ const $ pure ())
        saved<-evalWrite writer (ReserveFees 100 key Native (money 100) "recipient" "fence test")
        unless (withdrawalSequence saved==1) (fail "unexpected fence sequence")
      before<-evalRead reader ReadState
      unless (ledgerSequence before==1) (fail "missing committed sequence")
      _<-adopt 1
      let other=directory</>"retired"
      Fence.initializeFence other identity 0
      _<-evalRestore settings (AdoptLedger other identity 1)
      Fence.withFence other identity $ \advance->expectStore "stale_ledger_below_worker_fence" (advance 0)
      evalRestore settings (RetireLedger other identity 1) >>= check . (==(T.pack database,1))
      _<-evalRestore settings (RetireLedger other identity 1)
      expectStore "worker_fence_retired" (evalRestore settings $ AdoptLedger other identity 1)
      wrong<-pure (directory</>"wrong")
      Fence.initializeFence wrong (T.replicate 64 "b") 0
      expectStore "worker_fence_identity_mismatch" (evalRestore settings $ AdoptLedger wrong identity 1)
      Fence.withFence directory identity $ \advance->do
        let uncertain n=advance n >> when (n==2) (reject "injected_uncertain_commit")
        withWriter settings policy uncertain $ \writer->do
          expectStore "injected_uncertain_commit" (evalWrite writer $ CancelFees key "fence cancel")
          expectStore "ledger_connection_fenced" (evalWrite writer $ Pause "must remain fenced")
      after<-evalRead reader ReadState
      unless (ledgerSequence after==1) (fail "uncertain commit changed ledger")
      expectStore "stale_ledger_below_worker_fence" (withFencedWriter settings policy directory $ const $ pure ())
      expectStore "stale_ledger_below_worker_fence" (adopt 1)
      expectStore "stale_ledger_below_worker_fence" (retire 1)
      withdrawal<-evalRead reader (ReadWithdrawal key)
      unless (fmap withdrawalCancellation withdrawal==Just Nothing) (fail "uncertain commit changed money")
      Fence.withFence directory identity $ \advance->do
        expectStore "stale_ledger_below_worker_fence" (advance 1)
        advance 2
      Fence.retireFence directory identity 2
      expectStore "worker_fence_retired" (withFencedWriter settings policy directory $ const $ pure ())
  putStrLn "PASS: offline adoption/retirement, pause/identity/sequence/ownership checks, real host fence, durable uncertain-commit watermark, rollback, stale restart refusal"

-- Public all-zero seed vector; never used on a chain or with funds.
withTestSigningKey :: (FilePath -> IO a) -> IO a
withTestSigningKey action=bracket temporary removeDirectoryRecursive $ \directory->do
  let file=directory<>"/key.json"
  BL.writeFile file (encode (replicate 32 (0::Int)<>[59, 106, 39, 188, 206, 182, 164, 45, 98, 163, 168, 208, 42, 111, 13, 115, 101, 50, 21, 119, 29, 226, 67, 166, 58, 192, 72, 161, 139, 89, 218, 41]))
  setFileMode file 0o600
  action file
 where
  temporary=do
    (path,handle)<-openTempFile "/tmp" "ecx-signing-key"
    hClose handle
    removeFile path
    createDirectory path
    setFileMode path 0o700
    pure path

-- Real executable/HTTP/PG lifetime contract. RPC is deliberately unavailable;
-- this verifies startup/refusal/shutdown, never network acceptance or a fake chain.
serverMain :: IO ()
serverMain = do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user<-getEnv "USER"
  role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  binary<-getEnv "ECX_REBUILD_EXECUTABLE"
  environment<-getEnvironment
  base<-getDataFileName "test/fixtures/deployment-config.json" >>= Config.loadConfig
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      check ok=unless ok (fail "server process contract failed")
  -- Reuse the protected temporary-directory lifetime; the public seed is unused.
  withTestSigningKey $ \keyFile->do
    let directory=takeDirectory keyFile
    port<-bracket (NS.socket NS.AF_INET NS.Stream NS.defaultProtocol) NS.close $ \sock->do
      NS.bind sock (NS.SockAddrInet 0 (NS.tupleToHostAddress (127,0,0,1)))
      address<-NS.getSocketName sock
      case address of NS.SockAddrInet n _->pure (fromIntegral n); _->fail "unexpected listener address"
    let config=base {Config.serverPort=port,Config.fenceDirectory=directory<>"/fence",
          Config.nativeCookie=directory<>"/missing-cookie",Config.solanaRpc="https://127.0.0.1:1"}
        identity=Config.fingerprint config
        filename=directory<>"/config.json"
        overrides=[("PGHOST","/tmp/ecx-pg-seam"),("PGPORT","29436"),("PGDATABASE",database),
          ("PGUSER",user),("PGPASSWORD",""),("PGREADUSER",role),("PGREADPASSWORD","")]
        childEnv=overrides<>filter (\(key,_)->key `notElem` (map fst overrides<>["ECX_ASSETS","ECX_INTERFACE_CONFIG"])) environment
    Config.validateConfig config
    BL.writeFile filename (encode config)
    bracket (PG.connect settings) PG.close $ \connection->fixture connection (InitializeIdentity identity)
    (adopted,output,_)<-Process.readCreateProcessWithExitCode
      (Process.proc binary ["adopt-ledger",filename,"0"]) {Process.env=Just childEnv} ""
    check (adopted==ExitSuccess)
    adoptedState<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack output)
    fieldValue "paused" adoptedState >>= check . (==True)
    withReader settings {PG.connectUser=role} identity False $ \reader->do
      before<-evalRead reader ReadBalances
      archive<-evalBackup reader (ExportLedger directory)
      let runRestore minimumSequence=Process.readCreateProcessWithExitCode
            (Process.proc binary ["restore-ledger",filename,manifestPath archive,show (minimumSequence::Int)]) {Process.env=Just childEnv} ""
          acquire=do
            (code,out,_)<-runRestore 0
            check (code==ExitSuccess)
            value<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack out)
            fieldValue "paused" value >>= check . (==True)
            fieldValue "criticalSequence" value >>= check . (==(0::Int))
            fieldValue "database" value
      bracket acquire (\name->Backup.discardRestore settings {PG.connectDatabase=T.unpack name}) $ \name->do
        bracket (PG.connect settings {PG.connectDatabase=T.unpack name}) PG.close $ \connection->do
          (rows,_,_)<-fixture connection ArchiveRecords
          check (case rows of [row]->S.fingerprint row==identity && S.paused row==1; _->False)
      (refused,_,err)<-runRestore 1
      check (refused/=ExitSuccess && "backup_snapshot_too_old" `T.isInfixOf` T.pack err)
      let backupConfig=directory</>"backup.json"
          repositoryFile=directory</>"repository"
          passwordFile=directory</>"password"
      BS.writeFile repositoryFile "/tmp/not-a-remote-repository"
      BS.writeFile passwordFile "offline-test-password"
      BL.writeFile backupConfig $ encode $ object ["restic" .= ("/unused/restic"::T.Text),"repositoryFile" .= repositoryFile,"passwordFile" .= passwordFile]
      mapM_ (\path->setFileMode path 0o600) [backupConfig,repositoryFile,passwordFile]
      (denied,_,message)<-Process.readCreateProcessWithExitCode
        (Process.proc binary ["recover-ledger",filename,backupConfig,replicate 64 'a',directory,"0"]) {Process.env=Just childEnv} ""
      check (denied/=ExitSuccess && "https_backup_repository_required" `T.isInfixOf` T.pack message)
      bracket (HTTP.newManager HTTP.defaultManagerSettings {HTTP.managerResponseTimeout=HTTP.responseTimeoutMicro 1000000}) HTTP.closeManager $ \manager->
        withFile (directory<>"server.log") WriteMode $ \logFile->
          Process.withCreateProcess (Process.proc binary ["observe",filename])
            {Process.env=Just childEnv,Process.std_out=Process.UseHandle logFile,Process.std_err=Process.UseHandle logFile} $ \_ _ _ process->
            flip finally (Process.terminateProcess process >> void (Process.waitForProcess process)) $ do
              let get path=HTTP.parseRequest ("http://127.0.0.1:"<>show port<>path) >>= \request->HTTP.httpLbs request manager
                  wait 0=readFile (directory<>"server.log") >>= fail . ("server did not bind: "<>)
                  wait n=do
                    alive<-Process.getProcessExitCode process
                    check (alive==Nothing)
                    result<-try (get "/api/v1/config") :: IO (Either HTTP.HttpException (HTTP.Response BL.ByteString))
                    case result of Right reply->pure reply; Left _->threadDelay 50000 >> wait (n-1::Int)
              public<-wait 400
              check (statusCode(HTTP.responseStatus public)==200)
              decoded<-either fail pure (eitherDecodeStrict' $ BL.toStrict $ HTTP.responseBody public)
              check (W.pubDeployment decoded==Config.deploymentId config && not(W.pubIntakeEnabled decoded)
                && W.pubAvailability decoded==W.Availability False "observation_only")
              page<-get "/"
              script<-get "/wallet.js"
              style<-get "/style.css"
              removed<-get "/operator"
              check (all ((==200).statusCode.HTTP.responseStatus) [page,script,style]
                && "A direct bridge." `T.isInfixOf` TE.decodeUtf8 (BL.toStrict $ HTTP.responseBody page)
                && BL.length(HTTP.responseBody script)>1000 && statusCode(HTTP.responseStatus removed)==404)
              let control value=Control.callControl (Config.fenceDirectory config) value
              setFileMode (Config.fenceDirectory config<>"/operator.sock") 0o666
              expectStore "unsafe_operator_permissions" (control $ object ["operation" .= ("status"::T.Text)])
              setFileMode (Config.fenceDirectory config<>"/operator.sock") 0o600
              status<-control (object ["operation" .= ("status"::T.Text)])
              service<-either fail pure (eitherDecodeStrict' $ BL.toStrict $ encode status)
              check (W.paused service)
              reviews<-control (object ["operation" .= ("native-reviews"::T.Text)])
              check (reviews==toJSON ([]::[(T.Text,T.Text,Int64)]))
              expectStore "invalid_operator_operation" (control $ object ["operation" .= ("rebroadcast-native"::T.Text),"transaction" .= ("missing"::T.Text),"recovery" .= (1::Int),"reason" .= ("test"::T.Text),"bytes" .= ("attacker"::T.Text)])
              refused<-control (object ["operation" .= ("resume"::T.Text)])
              check (refused==object ["error" .= ("observation_only"::T.Text)])
              forM_ [object ["operation" .= ("withdraw-fees"::T.Text),"id" .= T.replicate 64 "a","asset" .= Native,"amount" .= money 1,"recipient" .= ("recipient"::T.Text),"reason" .= ("test"::T.Text)],
                object ["operation" .= ("cancel-fees"::T.Text),"id" .= ("missing"::T.Text),"reason" .= ("test"::T.Text)],
                object ["operation" .= ("draft-replacement"::T.Text),"parent" .= ("missing"::T.Text),"fee" .= money 2,"reason" .= ("test"::T.Text)],
                object ["operation" .= ("sign-replacement"::T.Text),"decision" .= (1::Int)],
                object ["operation" .= ("rebroadcast-native"::T.Text),"transaction" .= ("missing"::T.Text),"recovery" .= (1::Int),"reason" .= ("test"::T.Text)],
                object ["operation" .= ("cancel-replacement"::T.Text),"decision" .= (1::Int),"reason" .= ("test"::T.Text)]] $ \command->do
                  result<-control command
                  check (result==object ["error" .= ("observation_only"::T.Text)])
              coverRefused<-control (object ["operation" .= ("cover-source-loss"::T.Text),"deposit" .= ("missing"::T.Text),"recovery" .= (1::Int),"float" .= money 1,"earned" .= money 0,"reason" .= ("cover"::T.Text)])
              check (coverRefused==object ["error" .= ("observation_only"::T.Text)])
              restorationRefused<-control (object ["operation" .= ("approve-source-recovery"::T.Text),"payment" .= ("missing"::T.Text),"restoration" .= (1::Int),"reason" .= ("restored"::T.Text)])
              check (restorationRefused==object ["error" .= ("observation_only"::T.Text)])
              spendRefused<-control (object ["operation" .= ("classify-spend"::T.Text),"chain" .= ("Native"::T.Text),"transaction" .= ("missing"::T.Text),"reason" .= ("owned"::T.Text)])
              check (spendRefused==object ["error" .= ("observation_only"::T.Text)])
              allocationRefused<-control (object ["operation" .= ("allocate-treasury"::T.Text),"deposit" .= ("missing"::T.Text),"split" .= [("float"::T.Text,money 1)],"reason" .= ("owned"::T.Text)])
              check (allocationRefused==object ["error" .= ("observation_only"::T.Text)])
              refundRefused<-control (object ["operation" .= ("refund"::T.Text),"deposit" .= ("missing"::T.Text)])
              check (refundRefused==object ["error" .= ("observation_only"::T.Text)])
              retryRefused<-control (object ["operation" .= ("retry-solana"::T.Text),"transaction" .= ("missing"::T.Text),"reason" .= ("test"::T.Text)])
              check (retryRefused==object ["error" .= ("observation_only"::T.Text)])
              expectStore "invalid_operator_operation" (control $ object ["operation" .= ("sign-replacement"::T.Text),"decision" .= (1::Int),"bytes" .= ("attacker"::T.Text)])
              expectStore "invalid_operator_operation" (control $ object ["operation" .= ("draft-replacement"::T.Text),"parent" .= ("missing"::T.Text),"fee" .= (2::Int),"reason" .= ("test"::T.Text)])
              expectStore "invalid_operator_operation" (control $ object ["operation" .= ("refund"::T.Text),"deposit" .= ("missing"::T.Text),"recipient" .= ("attacker"::T.Text)])
              expectStore "invalid_operator_operation" (control $ object ["operation" .= ("resume"::T.Text),"bypass" .= True])
              _<-control (object ["operation" .= ("pause"::T.Text),"reason" .= ("operator process contract"::T.Text)])
              evalRead reader ReadState >>= check . ledgerPaused
              (exit,out,_)<-Process.readCreateProcessWithExitCode (Process.proc binary ["operator",filename])
                ("{\"operation\":\"status\"}")
              check (show exit=="ExitSuccess")
              cliStatus<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack out)
              check (W.paused cliStatus)
              evalRead reader ReadBalances >>= check . (==before)
      -- Explicit termination/wait reaped HTTP and worker together, releasing
      -- the real host fence; no daemon or worker is left behind by this check.
      Fence.withFence (Config.fenceDirectory config) identity (const $ pure ())
      (retired,_,_)<-Process.readCreateProcessWithExitCode
        (Process.proc binary ["retire-ledger",filename,"0"]) {Process.env=Just childEnv} ""
      check (retired==ExitSuccess)
      (readopted,_,problem)<-Process.readCreateProcessWithExitCode
        (Process.proc binary ["adopt-ledger",filename,"0"]) {Process.env=Just childEnv} ""
      check (readopted/=ExitSuccess && "worker_fence_retired" `T.isInfixOf` T.pack problem)
      evalRead reader ReadBalances >>= check . (==before)
  putStrLn "PASS: rebuilt executable, offline adoption/retirement, actual HTTP assets/config, paused unavailable-chain startup, unchanged balances and process/fence cleanup"

paidRefundContract :: PG.Connection -> Reader -> Writer -> IO ()
paidRefundContract fixtures reader writer=do
  let header="Bearer "<>T.replicate 64 "0"
      check ok=unless ok (fail "completed-order refund contract failed")
  paidReceipt<-evalRead reader (ReadSource "historical-fee")
  paidOrder<-maybe (fail "missing paid order") pure (W.depositOrder paidReceipt)
  paidBefore<-evalRead reader (ReadOrder header paidOrder)
  fixture fixtures (SeedReceipt "refund-after-paid" (Just paidOrder) Native 3 2 True 110)
  evalWrite writer (Pause "completed-order refund contract")
  fixture fixtures RefreshCustody
  extra<-evalWrite writer (AuthorizeRefund 110 "refund-after-paid")
  check (W.refundAmount extra==money 3)
  paidAfter<-evalRead reader (ReadOrder header paidOrder)
  check (W.status paidAfter=="Paid" && W.payoutTx paidAfter==W.payoutTx paidBefore)
  fixture fixtures (CheckRefundHolds paidOrder Native) >>= check
  -- Extra-receipt refunds must preserve the completed conversion at every stage.
  let refundKey=W.refundPayment extra
      unchanged=evalRead reader (ReadOrder header paidOrder) >>= check . (==paidBefore)
  fixture fixtures ReadyIntake
  void $ evalWrite writer (PreparePayment 110 refundKey (money 1) "{}")
  unchanged
  evalWrite writer (SaveDraft refundKey 0 "{}")
  fixture fixtures CoverBackup
  fixture fixtures ReadyIntake
  prepared<-evalRead reader (ReadSigningDecision 110 refundKey 0)
  let signed=SignedAttempt "extra-refund-after-paid" "offline-refund-bytes" "{}" (Just "refund-input:0")
  void $ evalWrite writer (RecordAttempt prepared signed)
  unchanged
  fixture fixtures ReadyIntake
  void $ evalWrite writer (MarkBroadcast 110 $ signedId signed)
  fixture fixtures CoverBackup
  fixture fixtures ReadyIntake
  authorized<-evalWrite writer (AuthorizeSend 110 $ signedId signed)
  beforeRefund<-evalRead reader ReadBalances
  evalWrite writer (SettlePayment authorized (W.PaymentCosts (money 1) (money 0)) "{\"offlineExtraRefund\":true}")
  unchanged
  afterRefund<-evalRead reader ReadBalances
  check (M.findWithDefault 0 (Native,Principal) afterRefund==M.findWithDefault 0 (Native,Principal) beforeRefund-3)
  evalRead reader (ReadPayment refundKey) >>= check . (==PaymentPaid) . savedStatus
  evalWrite writer (SettlePayment authorized (W.PaymentCosts (money 1) (money 0)) "{\"offlineExtraRefund\":true}")
  evalRead reader ReadBalances >>= check . (==afterRefund)
  unchanged

refundContract :: PG.Connection -> Reader -> Writer -> IO ()
refundContract fixtures reader writer=do
  let header="Bearer "<>T.replicate 64 "0"
      check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "refund contract failed\n"<>prettyCallStack callStack)
      make name direction=do
        fixture fixtures ReadyIntake
        let request=W.OrderRequest direction (money 10) "recipient" (if direction==NativeToWrapped then "native-refund" else "") Nothing name
        oid<-evalWrite writer (CreateOrder 110 header request)
        if direction==NativeToWrapped then do
          claim<-evalWrite writer (ClaimNative 110 header oid)
          void $ evalWrite writer (RecordNative header oid (allocationLabel claim) ("refund-address-"<>name))
        else void $ evalWrite writer (BindSolana 110 header oid)
        pure oid
      ready=evalWrite writer (Pause "refund contract") >> fixture fixtures RefreshCustody
      receipt did oid asset n=fixture fixtures (SeedReceipt did (Just oid) asset n 2 True 110)
      authorize did=evalWrite writer (AuthorizeRefund 110 did)
  oid<-make "refund-partial" NativeToWrapped
  receipt "refund-partial-source" oid Native 9
  expectStore "pause_before_operator_action" (authorize "refund-partial-source")
  ready
  before<-evalRead reader ReadBalances
  state<-evalRead reader ReadState
  saved<-authorize "refund-partial-source"
  replay<-authorize "refund-partial-source"
  check (saved==W.RefundAuthorization "refund:refund-partial-source" "native-refund" (money 9) && replay==saved)
  evalRead reader ReadBalances >>= check . (==before)
  later<-evalRead reader ReadState
  check (ledgerSequence later==ledgerSequence state+1)
  paymentView<-evalRead reader (ReadPayment $ W.refundPayment saved)
  check (savedStatus paymentView==PaymentReady && paymentAsset(savedPayment paymentView)==Native && paymentAmount(savedPayment paymentView)==money 9)
  source<-evalRead reader (ReadPaymentSource $ W.refundPayment saved)
  check (fmap (W.depositId.W.sourceDeposit) source==Just "refund-partial-source")
  receipt "refund-extra-source" oid Native 3
  ready
  expectStore "other_obligation_must_resolve_before_refund" (authorize "refund-extra-source")
  converted<-make "refund-conversion" NativeToWrapped
  receipt "refund-conversion-source" converted Native 10
  evalWrite writer (PromoteDeposit 110 "refund-conversion-source") >>= check
  ready
  void $ authorize "refund-conversion-source"
  evalRead reader (ReadPayment $ "convert:"<>converted) >>= check . (==PaymentCancelled) . savedStatus
  -- A settled conversion cannot be refunded a second time.
  fixture fixtures (SourceEligibility "historical-fee" True)
  ready
  expectStore "principal_already_resolved" (authorize "historical-fee")
  racing<-make "refund-racing" NativeToWrapped
  receipt "refund-racing-source" racing Native 10
  evalWrite writer (PromoteDeposit 110 "refund-racing-source") >>= check
  fixture fixtures ReadyIntake
  void $ evalWrite writer (PreparePayment 110 ("convert:"<>racing) (money 20) "{}")
  ready
  expectStore "refund_would_race_payment" (authorize "refund-racing-source")
  late<-make "refund-late" NativeToWrapped
  evalWrite writer (ExpireQuotes 500)
  receipt "refund-late-source" late Native 9
  ready
  void $ authorize "refund-late-source"
  checkPhases<-fixture fixtures (CheckRefundHolds late Native)
  check checkPhases
  unwrap<-make "refund-solana" WrappedToNative
  let signature="refund-solana-signature"; did="solana:"<>signature; owner="4zvwRjXUKGfvwnParsHAS3HuSVzV5cA4McphgmoCtajS"
  receipt did unwrap Wrapped 7
  ready
  expectStore "custody_history_not_current" (authorize did)
  instruction<-either (fail . T.unpack) pure (payInstruction unwrap)
  fixture fixtures (RefundProof signature instruction owner)
  ready
  solRefund<-authorize did
  check (W.refundRecipient solRefund==owner && W.refundAmount solRefund==money 7)
  fixture fixtures (CheckRefundHolds unwrap Sol) >>= check
  forM_ [("wrong-reference","solana-pay:wrong",owner,"refund_reference_mismatch"),
         ("wrong-owner","", "invalid", "invalid_public_key")] $ \(name,reference,badOwner,code)->do
    target<-make name WrappedToNative
    let sig="refund-"<>name; sourceId="solana:"<>sig
    receipt sourceId target Wrapped 5
    bound<-either (fail . T.unpack) pure (payInstruction target)
    fixture fixtures (RefundProof sig (if T.null reference then bound else reference) badOwner)
    ready
    beforeRejected<-evalRead reader ReadBalances
    expectStore code (authorize sourceId)
    evalRead reader ReadBalances >>= check . (==beforeRejected)
  expectStore "refundable_deposit_not_found" (ready >> authorize "unknown-source")

cancellationContract :: PG.Connection -> Reader -> Writer -> IO ()
cancellationContract fixtures reader writer=do
  let header="Bearer "<>T.replicate 64 "0"
      request=W.OrderRequest NativeToWrapped (money 10) "recipient" "native-refund" Nothing "refund-racing"
      reason="review unsigned work"; cleanup="{\"nativeInputs\":[]}"
      check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "cancellation contract failed\n"<>prettyCallStack callStack)
  Just oid<-evalRead reader (FindOrder header request)
  let identifier="convert:"<>oid
  before<-evalRead reader ReadBalances
  original<-evalRead reader (ReadUnsignedPreparation identifier)
  forM_ [0..7] $ \generation->do
    prepared<-evalRead reader (ReadUnsignedPreparation identifier)
    check (preparedGeneration prepared==generation)
    fixture fixtures ReadyIntake
    expectStore "pause_before_operator_action" (evalWrite writer $ BeginCancellation prepared 110 reason cleanup)
    evalWrite writer (Pause "cancel contract")
    fixture fixtures RefreshCustody
    expectStore "preparation_cancellation_not_expected" (evalWrite writer $ FinishCancellation prepared reason cleanup)
    evalWrite writer (BeginCancellation prepared 110 reason cleanup)
    recorded<-evalRead reader ReadState
    evalWrite writer (BeginCancellation prepared 110 reason cleanup)
    replay<-evalRead reader ReadState
    check (ledgerSequence replay==ledgerSequence recorded)
    expectStore "preparation_cancellation_pending" (evalRead reader $ ReadPreparation identifier)
    expectStore "preparation_cancellation_conflict" (evalWrite writer $ BeginCancellation prepared 110 "changed" cleanup)
    expectStore "preparation_cancellation_not_expected" (evalWrite writer $ FinishCancellation prepared {preparedFee=money 1} reason cleanup)
    evalWrite writer (FinishCancellation prepared reason cleanup)
    finished<-evalRead reader ReadState
    evalWrite writer (FinishCancellation prepared reason cleanup)
    again<-evalRead reader ReadState
    check (ledgerSequence again==ledgerSequence finished)
    evalRead reader ReadBalances >>= check . (==before)
    saved<-evalRead reader (ReadCancellation identifier generation)
    check (saved==Just(reason,cleanup,True))
    evalRead reader (ReadPayment identifier) >>= check . (==if generation<7 then PaymentReady else PaymentReview) . savedStatus
    when (generation==7) $ evalRead reader PaymentCandidates >>= check . notElem identifier
    fixture fixtures ReadyIntake
    if generation==7 then expectStore "preparation_generation_limit" (evalWrite writer $ PreparePayment 110 identifier (money 20) "{}")
      else do
        next<-evalWrite writer (PreparePayment 110 identifier (money 20) "{}")
        check (preparedGeneration next==generation+1)
        evalWrite writer (Pause "stale callback contract")
        evalWrite writer (FinishCancellation original reason cleanup)
        current<-evalRead reader (ReadUnsignedPreparation identifier)
        check (current==next)
  evalRead reader ReadBalances >>= check . (==before)

earnedCancellationContract :: PG.Connection -> Reader -> Writer -> IO ()
earnedCancellationContract fixtures reader writer=do
  let key=T.replicate 64 "e"; identifier="fee:"<>key; reason="cancel unsigned earned payment"; cleanup="{}"
      check ok=unless ok (fail "earned cancellation contract failed")
  evalWrite writer (Pause "earned cancellation contract")
  fixture fixtures RefreshCustody
  before<-evalRead reader ReadBalances
  void $ evalWrite writer (ReserveFees 100 key Native (money 5) "owner-address" "test retained fees")
  fixture fixtures ReadyIntake
  prepared<-evalWrite writer (PreparePayment 100 identifier (money 5) "{}")
  fixture fixtures (RejectPreparedFeeRelease key) >>= check
  evalWrite writer (Pause "earned cancellation")
  fixture fixtures RefreshCustody
  evalWrite writer (BeginCancellation prepared 100 reason cleanup)
  fixture fixtures (RejectPreparedFeeRelease key) >>= check
  evalWrite writer (FinishCancellation prepared reason cleanup)
  evalRead reader (ReadPayment identifier) >>= check . (==PaymentReady) . savedStatus
  fixture fixtures ReadyIntake
  next<-evalWrite writer (PreparePayment 100 identifier (money 5) "{}")
  check (preparedGeneration next==1)
  evalWrite writer (Pause "earned cancellation retry")
  fixture fixtures RefreshCustody
  evalWrite writer (BeginCancellation next 100 reason cleanup)
  evalWrite writer (FinishCancellation next reason cleanup)
  void $ evalWrite writer (CancelFees key "release cancelled earned work")
  evalRead reader (ReadPayment identifier) >>= check . (==PaymentCancelled) . savedStatus
  evalRead reader PaymentCandidates >>= check . notElem identifier
  after<-evalRead reader ReadBalances
  check (M.filter (/=0) before==M.filter (/=0) after)

expiryContract :: PG.Connection -> Reader -> Writer -> IO ()
expiryContract fixtures reader writer=do
  let header="Bearer "<>T.replicate 64 "0"
      request=W.OrderRequest NativeToWrapped (money 10) "recipient" "native-refund" Nothing "expiry-contract"
      check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "expiry contract failed\n"<>prettyCallStack callStack)
      ready=fixture fixtures ReadyIntake
      paused=evalWrite writer (Pause "expiry contract") >> fixture fixtures RefreshCustody
      prepare identifier=do
        ready
        prepared<-evalWrite writer (PreparePayment 110 identifier (money 20) "{}")
        evalWrite writer (SaveDraft identifier (preparedGeneration prepared) "{\"draft\":1}")
        fixture fixtures CoverBackup
        ready
        evalRead reader (ReadSigningDecision 110 identifier (preparedGeneration prepared))
      sign prepared=evalWrite writer $ RecordAttempt prepared
        (SignedAttempt ("expiry-signed-"<>T.pack(show $ preparedGeneration prepared)) "immutable signed bytes" "{\"signed\":true}" Nothing)
      proof="{\"expiry\":\"offline ledger contract\"}"
  ready
  oid<-evalWrite writer (CreateOrder 110 header request)
  claim<-evalWrite writer (ClaimNative 110 header oid)
  void $ evalWrite writer (RecordNative header oid (allocationLabel claim) "expiry-contract-address")
  fixture fixtures (SeedReceipt "expiry-source" (Just oid) Native 10 2 True 110)
  evalWrite writer (PromoteDeposit 110 "expiry-source") >>= check
  let identifier="convert:"<>oid
  prepared<-prepare identifier
  first<-sign prepared
  evalRead reader (CheckExpiryOrigins ("sol-origin","opening-signature"))
  expectStore "expiry_scan_origin_mismatch" (evalRead reader $ CheckExpiryOrigins ("wrong","opening-signature"))
  before<-evalRead reader ReadBalances
  expectStore "expiry_attempt_changed" (evalWrite writer $ RecordSolanaExpiry first {recordedGeneration=1} proof)
  evalWrite writer (RecordSolanaExpiry first proof)
  recorded<-evalRead reader ReadState
  evalWrite writer (RecordSolanaExpiry first proof)
  replay<-evalRead reader ReadState
  check (ledgerSequence replay==ledgerSequence recorded)
  expectStore "expiry_evidence_conflict" (evalWrite writer $ RecordSolanaExpiry first "{\"changed\":true}")
  expired<-evalRead reader (ReadAttempt "expiry-signed-0")
  check (recordedState expired=="review" && recordedSigned expired==recordedSigned first)
  restored<-evalRead reader (ReadRecordedPreparation "expiry-signed-0")
  check (preparedPolicy restored==preparedPolicy prepared && preparedDraft restored==preparedDraft prepared && preparedFee restored==preparedFee prepared)
  evalRead reader PendingAttempts >>= check . notElem "expiry-signed-0"
  (view,active,attempts)<-evalRead reader (ReadPaymentWork identifier)
  check (savedStatus view==PaymentReview && active==Nothing && null attempts)
  evalRead reader ReadBalances >>= check . (==before)
  ready
  expectStore "preparation_retry_not_authorized" (evalWrite writer $ PreparePayment 110 identifier (money 20) "{}")
  expectStore "pause_before_operator_action" (evalWrite writer $ ApproveSolanaRetry 110 expired "reviewed" proof)
  paused
  expectStore "solana_retry_not_expected" (evalWrite writer $ ApproveSolanaRetry 110 first "reviewed" proof)
  evalWrite writer (ApproveSolanaRetry 110 expired "reviewed" proof)
  approved<-evalRead reader ReadState
  evalWrite writer (ApproveSolanaRetry 110 expired "reviewed" proof)
  repeated<-evalRead reader ReadState
  check (ledgerSequence repeated==ledgerSequence approved)
  expectStore "retry_approval_conflict" (evalWrite writer $ ApproveSolanaRetry 110 expired "different" proof)
  next<-prepare identifier
  check (preparedGeneration next==1 && savedPayment(preparedView next)==savedPayment(preparedView prepared))
  -- A mixed history of proved expiry and unsigned cancellation remains bounded.
  paused
  evalWrite writer (BeginCancellation next 110 "unsigned retry" "{}")
  evalWrite writer (FinishCancellation next "unsigned retry" "{}")
  third<-prepare identifier
  check (preparedGeneration third==2)
  current<-sign third
  evalWrite writer (RecordSolanaExpiry current proof)
  latest<-evalRead reader (ReadAttempt "expiry-signed-2")
  paused
  evalWrite writer (ApproveSolanaRetry 110 latest "reviewed latest" proof)
  fourth<-prepare identifier
  check (preparedGeneration fourth==3)
  lastAttempt<-sign fourth
  saved<-evalRead reader (ReadAttempt "expiry-signed-0")
  check (recordedSigned saved==recordedSigned first)
  evalWrite writer (RecordSolanaExpiry first proof)
  evalWrite writer (ApproveSolanaRetry 110 expired "reviewed" proof)
  activeAgain<-evalRead reader (ReadPreparation identifier)
  check (activeAgain==fourth)
  evalRead reader ReadBalances >>= check . (==before)
  evalWrite writer (RecordSolanaExpiry lastAttempt proof)
  fixture fixtures SeedWrappedRevenue
  paused
  let key=T.replicate 64 "f"; earnedId="fee:"<>key
  void $ evalWrite writer (ReserveFees 110 key Wrapped (money 3) "owner-address" "earned expiry contract")
  earnedBefore<-evalRead reader ReadBalances
  earned<-prepare earnedId
  let signed=SignedAttempt "earned-expiry-signature" "exact earned signed bytes" "{\"signed\":true}" Nothing
  attempt<-evalWrite writer (RecordAttempt earned signed)
  evalWrite writer (RecordSolanaExpiry attempt proof)
  earnedExpired<-evalRead reader (ReadAttempt "earned-expiry-signature")
  evalRead reader (ReadPayment earnedId) >>= check . (==PaymentReview) . savedStatus
  paused
  evalWrite writer (ApproveSolanaRetry 110 earnedExpired "earned retry reviewed" proof)
  evalRead reader (ReadPayment earnedId) >>= check . (==PaymentReady) . savedStatus
  earnedNext<-prepare earnedId
  check (preparedGeneration earnedNext==1 && savedPayment(preparedView earnedNext)==savedPayment(preparedView earned))
  evalRead reader ReadBalances >>= check . (==earnedBefore)

-- Offline observed-receipt fixtures, never an assertion of live-chain funding.
treasuryContract :: PG.Connection -> Reader -> Writer -> IO ()
treasuryContract fixtures reader writer=do
  let check ok=unless ok (fail $ "treasury contract failed\n"<>prettyCallStack callStack)
      ready=evalWrite writer (Pause "treasury contract") >> fixture fixtures RefreshCustody
      allocate did split reason=evalWrite writer (AllocateTreasury 110 did split reason)
      seed did asset=fixture fixtures (SeedReceipt did Nothing asset 10 2 True 110)
      proof did=object ["receipts" .= [object ["id" .= did,"amount" .= money 10,"order" .= (Nothing::Maybe T.Text),"eligible" .= True]]]
      evidence chain key value=fixture fixtures (SeedTreasuryEvidence chain key "fixture-anchor" "unmatched_incoming" 0 value)
      native="native:treasury-ok:0"
      split=[("float",money 4),("operating",money 3),("backing",money 2),("lp",money 1)]
  seed native Native
  evidence "Native" "treasury-ok" (proof native)
  fixture fixtures ReadyIntake
  expectStore "treasury_allocation_requires_pause" (allocate native split "owned treasury")
  ready
  before<-evalRead reader ReadBalances
  first<-allocate native split "owned treasury"
  after<-evalRead reader ReadBalances
  check (M.findWithDefault 0 (Native,Unallocated) after==M.findWithDefault 0 (Native,Unallocated) before-10)
  forM_ [(Float,4),(Operating,3),(Backing,2),(Liquidity,1)] $ \(account,n)->
    check (M.findWithDefault 0 (Native,account) after==M.findWithDefault 0 (Native,account) before+n)
  replay<-allocate native (reverse split) "owned treasury"
  check (replay==first)
  evalRead reader ReadBalances >>= check . (==after)
  expectStore "treasury_allocation_conflict" (allocate native [("float",money 10)] "owned treasury")
  expectStore "treasury_allocation_conflict" (allocate native split "changed owner")
  forM_ [[("principal",money 10)],[("float",money 5),("float",money 5)],[("operating",money 0)],[]] $ \bad->
    expectStore "invalid_treasury_allocation" (allocate native bad "owned")
  let wrapped="solana:treasury-wrapped"; sol="sol-operating:treasury-sol"
  seed wrapped Wrapped
  evidence "Solana" "treasury-wrapped" (object ["delta" .= ("10"::T.Text)])
  expectStore "custody_not_reconciled" (allocate wrapped [("float",money 10)] "owned")
  ready
  expectStore "treasury_allocation_amount_mismatch" (allocate wrapped [("float",money 9)] "owned")
  void $ allocate wrapped [("float",money 10)] "owned"
  seed sol Sol
  evidence "SolanaOperating" "treasury-sol" (object ["delta" .= ("10"::T.Text),"failed" .= False])
  ready
  expectStore "sol_reserved_for_operating" (allocate sol [("float",money 10)] "owned")
  void $ allocate sol [("operating",money 10)] "owned"
  forM_ [("bad-delta",object ["delta" .= ("9"::T.Text),"failed" .= False]),
         ("failed",object ["delta" .= ("10"::T.Text),"failed" .= True])] $ \(key,value)->do
    let did="sol-operating:"<>key
    seed did Sol
    evidence "SolanaOperating" key value
    ready
    beforeFailure<-evalRead reader ReadBalances
    expectStore "verified_treasury_receipt_required" (allocate did [("operating",money 10)] "owned")
    evalRead reader ReadBalances >>= check . (==beforeFailure)
  forM_ [("mismatched", "different-anchor",0,"verified_treasury_receipt_required"),
         ("reviewed","fixture-anchor",1,"custody_history_not_current")] $ \(key,anchor,review,code)->do
    let did="native:"<>key<>":0"
    seed did Native
    fixture fixtures (SeedTreasuryEvidence "Native" key anchor "unmatched_incoming" review (proof did))
    ready
    expectStore code (allocate did [("float",money 10)] "owned")
  fixture fixtures (SeedReceipt "native:shallow:0" Nothing Native 10 1 True 110)
  ready
  expectStore "treasury_receipt_underconfirmed" (allocate "native:shallow:0" [("float",money 10)] "owned")
  fixture fixtures (SourceEligibility "native:shallow:0" False)
  ready
  expectStore "receipt_not_available_for_treasury" (allocate "native:shallow:0" [("float",money 10)] "owned")
  ready
  expectStore "receipt_not_available_for_treasury" (allocate "expiry-source" [("float",money 10)] "not mine")

  let classify chain key reason=evalWrite writer (ClassifyTreasurySpend chain key reason)
      outgoing chain key value=fixture fixtures (SeedTreasuryEvidence chain key "spend-anchor" "outgoing" 1 value)
      tokenDelta n=object ["delta" .= T.pack(show (negate n::Integer))]
  outgoing "Native" "treasury-native-out" (object ["walletNetUnits" .= ("-5"::T.Text),"feeUnits" .= money 1])
  fixture fixtures ReadyIntake
  expectStore "treasury_spend_requires_pause" (classify "Native" "treasury-native-out" "owned spend")
  ready
  nativeBefore<-evalRead reader ReadBalances
  spent<-classify "Native" "treasury-native-out" "owned spend"
  nativeAfter<-evalRead reader ReadBalances
  check (nativeAfter==M.unionWith (+) nativeBefore (M.fromList [((Native,Float),-5),((Native,Operating),-1),((Native,External),6)]))
  fixture fixtures (ReadEventReview "Native" "treasury-native-out") >>= check . (==0)
  revision<-evalRead reader ReadCustodyRevision
  again<-classify "Native" "treasury-native-out" "owned spend"
  check (again==spent)
  evalRead reader ReadCustodyRevision >>= check . (==revision)
  evalRead reader ReadBalances >>= check . (==nativeAfter)
  expectStore "treasury_spend_conflict" (classify "Native" "treasury-native-out" "different ownership")
  fixture fixtures (ChangeTreasuryAnchor "Native" "treasury-native-out")
  expectStore "treasury_spend_conflict" (classify "Native" "treasury-native-out" "owned spend")
  fixture fixtures (ReadEventReview "Native" "treasury-native-out") >>= check . (==1)
  forM_ [("Solana",Wrapped,Float,tokenDelta 3,3),
         ("SolanaOperating",Sol,Operating,object ["delta" .= ("-4"::T.Text),"feeUnits" .= money 1],4)] $ \(chain,asset,account,value,n)->do
    let key="treasury-out-"<>chain
    outgoing chain key value
    beforeSpend<-evalRead reader ReadBalances
    void $ classify chain key "owned spend"
    afterSpend<-evalRead reader ReadBalances
    check (afterSpend==M.unionWith (+) beforeSpend (M.fromList [((asset,account),-n),((asset,External),n)]))
  outgoing "Solana" "expiry-signed-0" (tokenDelta 3)
  expectStore "customer_attempt_cannot_be_treasury_spend" (classify "Solana" "expiry-signed-0" "not operator work")
  outgoing "Solana" "earned-expiry-signature" (tokenDelta 3)
  expectStore "customer_attempt_cannot_be_treasury_spend" (classify "Solana" "earned-expiry-signature" "not an external spend")
  expectStore "treasury_spend_not_observed" (classify "Native" "unseen-spend" "owned")
  protected<-evalRead reader ReadBalances
  -- The existing expiry contract retains customer inventory and fee holds.
  outgoing "Solana" "protected-float" (tokenDelta $ M.findWithDefault 0 (Wrapped,Float) protected)
  expectStore "treasury_spend_exceeds_free_allocation" (classify "Solana" "protected-float" "cannot consume customer holds")
  outgoing "SolanaOperating" "protected-operating" (object ["delta" .= T.pack(show $ negate $ M.findWithDefault 0 (Sol,Operating) protected),"feeUnits" .= money 1])
  expectStore "treasury_spend_exceeds_free_allocation" (classify "SolanaOperating" "protected-operating" "cannot consume fee holds")
  evalRead reader ReadBalances >>= check . (==protected)

-- Real TLS, both production evaluators and SDK signatures over public offline
-- vectors. Only the Solana RPC responses and ledger funding are fixtures.
tlsMain :: IO ()
tlsMain=do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user<-getEnv "USER"; role<-getEnv "ECX_REBUILD_CONTRACT_READER"; sdk<-getEnv "ECX_REBUILD_TEST_SDK"
  vector<-getDataFileName "test/fixtures/signed-three-units.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  workflow<-getDataFileName "test/fixtures/signed-payment-workflow.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  owner<-fieldValue "owner" vector; recipient<-fieldValue "recipient" vector; mint<-fieldValue "mint" vector; hash<-fieldValue "blockhash" vector
  reply<-fieldValue "reply" workflow :: IO H.HelperReply
  identifier<-fieldValue "paymentId" workflow
  let identity="offline-policy"; encoded value=TE.decodeUtf8 (BL.toStrict $ encode value)
      settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      policy=PaymentTerms (PolicySnapshot 1 "finalized" identity) (CostLimits (money 1) (money 10000) (money 2100000))
      store=StorePolicy policy (OrderLimits (money 2) (money 1000) 100 100 100 (money 10000000) (money 10000000)) "codec-fixture" True
      config=H.SolanaPolicy "codec-fixture" identity mint owner (H.replySource reply) (money 10000) (money 2100000)
      plan=SP.SolanaPlan identity recipient (money 3) (payoutReference identity identifier) (SP.RecentBlockhash hash 1000 100) (money 10000) (money 2100000)
      native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:1" "/unused" "ecx-bridge-test" 16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
      solana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing mint owner (H.replySource reply)
      check ok=unless ok (fail "TLS signing contract failed")
      context value=object ["context" .= object ["slot" .= (100::Int)],"value" .= value]
      token=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::T.Text),"info" .= object
        ["mint" .= mint,"owner" .= owner,"state" .= ("initialized"::T.Text),"isNative" .= False,"tokenAmount" .= object ["amount" .= ("10000000"::T.Text),"decimals" .= (8::Int)]]]]]
      mintAccount=object ["owner" .= Solana.tokenProgram,"data" .= object ["parsed" .= object ["type" .= ("mint"::T.Text),"info" .= object ["decimals" .= (8::Int),"isInitialized" .= True,"freezeAuthority" .= Null]]]]
      payer=object ["owner" .= ("11111111111111111111111111111111"::T.Text),"executable" .= False,"data" .= ["","base64"::T.Text],"lamports" .= (10000000::Int)]
  calls<-newIORef ([]::[T.Text])
  let rpcApplication request respond=do
        raw<-Wai.strictRequestBody request
        value<-either fail pure (eitherDecodeStrict' $ BL.toStrict raw)
        method<-fieldValue "method" value; params<-fieldValue "params" value :: IO [Value]; requestId<-fieldValue "id" value :: IO Value
        modifyIORef' calls (<>[method])
        result<-case method of
          "getGenesisHash"->pure $ toJSON (Solana.solanaGenesis W.L2LSignetDevnet)
          "getAccountInfo"->pure $ context $ if take 1 params==[toJSON mint] then mintAccount else token
          "getBlockHeight"->pure $ Number 900
          "getMultipleAccounts"->pure $ context $ toJSON [token,Null,payer]
          "getMinimumBalanceForRentExemption"->pure $ Number 1488440
          "getFeeForMessage"->pure $ context $ Number 5000
          "simulateTransaction"->pure $ context $ object ["err" .= Null]
          _->fail ("unexpected fixture RPC: "<>T.unpack method)
        respond $ Wai.responseLBS status200 [("Content-Type","application/json")] (encode $ object ["jsonrpc" .= ("2.0"::T.Text),"id" .= requestId,"result" .= result])
  bracket (PG.connect settings) PG.close $ \fixtures->do
    fixture fixtures (InitializeIdentity identity); fixture fixtures SeedIntake; fixture fixtures TLSFunds
    withReader settings {PG.connectUser=role} identity True $ \reader->
      withWriter settings store (const $ pure ()) $ \writer->do
        fixture fixtures RefreshCustody
        void $ evalWrite writer (ReserveFees 100 (T.drop 4 identifier) Wrapped (money 3) recipient "TLS contract")
        fixture fixtures ReadyIntake
        _<-evalWrite writer (PreparePayment 100 identifier (money 2110000) (encoded plan))
        evalWrite writer (SaveDraft identifier 0 (encoded $ SP.solanaPayoutRequest config plan))
        fixture fixtures CoverBackup
        fixture fixtures ReadyIntake
        now<-floor <$> getPOSIXTime
        fixture fixtures (FreshAt now)
        withTestSigningKey $ \keyFile->do
          public<-either reject pure (publicKey owner)
          BL.writeFile keyFile (encode $ replicate 32 (1::Int)<>map fromIntegral (BS.unpack public))
          let directory=takeDirectory keyFile; auth=directory<>"/auth"; endpoint port=SigningEndpoint port auth
          writeFile auth (replicate 64 'a'); setFileMode auth 0o600
          let makeCertificate file=do
                (exit,_,err)<-Process.readProcessWithExitCode "openssl" ["req","-x509","-newkey","rsa:2048","-nodes","-keyout",file<>".key","-out",file<>".pem","-days","1","-subj","/CN=127.0.0.1","-addext","subjectAltName=IP:127.0.0.1"] ""
                unless (show exit=="ExitSuccess") (fail err)
                setFileMode (file<>".key") 0o600
          makeCertificate auth
          makeCertificate (directory<>"/untrusted")
          certificate<-BS.readFile (auth<>".pem")
          untrusted<-BS.readFile (directory<>"/untrusted.pem")
          port<-bracket (NS.socket NS.AF_INET NS.Stream NS.defaultProtocol) NS.close $ \socket->do
            NS.bind socket (NS.SockAddrInet 0 (NS.tupleToHostAddress (127,0,0,1)))
            address<-NS.getSocketName socket
            case address of NS.SockAddrInet p _->pure (fromIntegral p); _->fail "unexpected listener"
          Warp.testWithApplication (pure rpcApplication) $ \rpcPort->
            bracket (newManager defaultManagerSettings {managerModifyRequest= \request->pure request {HTTP.secure=False,HTTP.host="127.0.0.1",HTTP.port=rpcPort}}) closeManager $ \manager->
              withSigner manager reader (SignerSettings native solana config sdk keyFile Nothing) $ \signer->do
                -- Receipt fixtures exercise HTTPS and the actual worker's
                -- acknowledgment gate, not off-host backup durability.
                checkpointReply<-newIORef (Nothing :: Maybe W.BackupReceipt)
                checkpoints<-newIORef (0::Int)
                let evaluate :: forall a. Request 'Op.Signer 'Op.Critical a -> IO a
                    evaluate request=case Op.resolve request of
                      Op.SigningDSL CheckpointCustody{}->do
                        modifyIORef' checkpoints (+1)
                        readIORef checkpointReply >>= maybe (reject "checkpoint_fixture_refused") pure
                      _->signer request
                bracket (forkIO $ runSigningServer (endpoint port) evaluate) killThread $ \_thread->do
                  let wait 0=fail "TLS signer did not bind"
                      wait n=do
                        result<-try $ bracket (NS.socket NS.AF_INET NS.Stream NS.defaultProtocol) NS.close $ \socket->NS.connect socket (NS.SockAddrInet (fromIntegral port) (NS.tupleToHostAddress (127,0,0,1)))
                        case (result::Either IOException ()) of Right ()->pure (); Left _->threadDelay 50000 >> wait (n-1::Int)
                  wait 200
                  withRuntime manager (ObserverSettings native solana 1 "origin" "origin") config Nothing (endpoint port) reader writer $ \worker _ _->do
                    writeFile auth (replicate 64 'b')
                    expectStore "signer_outcome_unknown" (worker $ Request $ SignPreparedPayment identifier)
                    readIORef calls >>= check . null
                    evalRead reader PendingAttempts >>= check . null
                    writeFile auth (replicate 64 'a')
                    BS.writeFile (auth<>".pem") untrusted
                    fixture fixtures ReadyIntake
                    clock<-floor <$> getPOSIXTime
                    fixture fixtures (FreshAt clock)
                    expectStore "signer_outcome_unknown" (worker $ Request $ SignPreparedPayment identifier)
                    readIORef calls >>= check . null
                    evalRead reader PendingAttempts >>= check . null
                    BS.writeFile (auth<>".pem") certificate
                    fixture fixtures ReadyIntake
                    later<-floor <$> getPOSIXTime
                    fixture fixtures (FreshAt later)
                    before<-evalRead reader ReadBalances
                    signed<-worker (Request $ SignPreparedPayment identifier)
                    check (Just signed==H.replySignature reply)
                    saved<-evalRead reader (ReadAttempt signed)
                    check (signedBytes(recordedSigned saved)==H.replyTransaction reply && recordedState saved=="signed")
                    sequenceNo<-ledgerSequence <$> evalRead reader ReadState
                    covered<-ledgerBackup <$> evalRead reader ReadState
                    check (sequenceNo>covered)
                    let receipt=W.BackupReceipt identity sequenceNo (T.replicate 64 "a") (T.replicate 64 "b")
                        checkpoint=worker (Request $ CheckpointBackup sequenceNo)
                    expectStore "signer_outcome_unknown" checkpoint
                    forM_ [receipt {W.receiptIdentity="other"},receipt {W.receiptSequence=sequenceNo-1},
                      receipt {W.receiptSequence=sequenceNo+1},receipt {W.receiptSnapshot="latest"},
                      receipt {W.receiptArchiveHash=T.replicate 64 "A"}] $ \bad->do
                        writeIORef checkpointReply (Just bad)
                        expectStore "invalid_custody_checkpoint_receipt" checkpoint
                        evalRead reader ReadState >>= check . (==covered) . ledgerBackup
                    writeIORef checkpointReply (Just receipt)
                    checkpoint
                    evalRead reader ReadState >>= check . (==sequenceNo) . ledgerBackup
                    checkpointCalls<-readIORef checkpoints
                    count<-length <$> readIORef calls
                    removeFile auth
                    checkpoint
                    readIORef checkpoints >>= check . (==checkpointCalls)
                    replay<-worker (Request $ SignPreparedPayment identifier)
                    check (replay==signed)
                    readIORef calls >>= check . (==count) . length
                    evalRead reader ReadBalances >>= check . (==before)
                    methods<-readIORef calls
                    check ("simulateTransaction" `elem` methods && "sendTransaction" `notElem` methods)
  putStrLn "PASS: actual HTTPS worker/signer evaluators, auth/certificate refusal, SDK signature, persisted bytes, checkpoint receipt rejection/acknowledgment/replay; offline RPC and receipt fixtures only"

restorationContract :: PG.Connection -> Reader -> Writer -> IO ()
restorationContract fixtures reader writer=do
  let check ok=unless ok (fail $ "source restoration contract failed\n"<>prettyCallStack callStack)
      header="Bearer "<>T.replicate 64 "8"
      request=W.OrderRequest NativeToWrapped (money 10) "recipient" "refund" Nothing "restoration-contract"
      tx=T.replicate 64 "8"; did="native:"<>tx<>":0"; observationHash=T.replicate 64 "f"
      approve key sequenceNo reason=evalWrite writer (ApproveSourceRestoration 110 key sequenceNo reason)
      restore=do
        source<-evalRead reader (ReadSource did)
        let returned=source {W.depositEligible=True,W.depositConfirmations=2}
        evalWrite writer (RefreshPaymentSource source returned)
        evalWrite writer (RecordSourceCheck returned $ W.SourceRestored $ object ["observationHash" .= observationHash])
        ledgerSequence <$> evalRead reader ReadState
      suspend=do
        source<-evalRead reader (ReadSource did)
        evalWrite writer (RefreshPaymentSource source source {W.depositEligible=False,W.depositConfirmations=0})
  fixture fixtures ReadyIntake
  oid<-evalWrite writer (CreateOrder 110 header request)
  claim<-evalWrite writer (ClaimNative 110 header oid)
  void $ evalWrite writer (RecordNative header oid (allocationLabel claim) "restoration-address")
  fixture fixtures (SeedReceipt did (Just oid) Native 10 2 True 110)
  fixture fixtures (SeedSourceEvidence tx observationHash)
  evalWrite writer (PromoteDeposit 110 did) >>= check
  let key="convert:"<>oid
  savedHash<-evalRead reader (ReadSourceWorkHash key)
  suspend
  evalRead reader (ReadPayment key) >>= check . (==PaymentReview) . savedStatus
  before<-evalRead reader ReadBalances
  restoration<-restore
  evalRead reader (ReadSourceWorkHash key) >>= check . (==savedHash)
  evalRead reader (CheckSourceRestoration key restoration)
  expectStore "source_approval_not_expected" (evalRead reader $ CheckSourceRestoration key (restoration-1))
  expectStore "custody_not_reconciled" (approve key restoration "source reviewed")
  fixture fixtures ReadyIntake
  expectStore "pause_before_operator_action" (approve key restoration "source reviewed")
  evalWrite writer (Pause "source contract")
  fixture fixtures RefreshCustody
  fixture fixtures (SourceRecipient key "changed")
  expectStore "source_review_work_changed" (approve key restoration "source reviewed")
  fixture fixtures (SourceRecipient key "recipient")
  fixture fixtures RefreshCustody
  approve key restoration "source reviewed"
  recorded<-evalRead reader ReadState
  check (ledgerPaused recorded)
  evalRead reader (ReadPayment key) >>= check . (==PaymentReady) . savedStatus
  evalRead reader (ReadSourceApproval key restoration) >>= check . (==Just "source reviewed")
  approve key restoration "source reviewed"
  replay<-evalRead reader ReadState
  check (ledgerSequence replay==ledgerSequence recorded)
  expectStore "source_approval_conflict" (approve key restoration "changed reason")
  evalRead reader ReadBalances >>= check . (==before)
  -- Old approval replay cannot revive a second suspension, even after return.
  suspend
  approve key restoration "source reviewed"
  evalRead reader (ReadPayment key) >>= check . (==PaymentReview) . savedStatus
  second<-restore
  check (second>restoration)
  evalRead reader (CheckSourceRestoration key second)
  fixture fixtures RefreshCustody
  approve key second "second restoration"
  evalRead reader (ReadPayment key) >>= check . (==PaymentReady) . savedStatus
  evalRead reader ReadBalances >>= check . (==before)

  -- Capital cover permits an explicit review decision, never source eligibility.
  suspend
  source<-evalRead reader (ReadSource did)
  let block=T.replicate 64 "a"
      proof=object ["transaction" .= tx,"output" .= (0::Int),"confirmations" .= (-1::Int),"observationHash" .= observationHash,"nodeBlock" .= block,"nodeHeight" .= (100::Int)]
      report=object ["matches" .= True,"nativeBlock" .= block,"nativeHeight" .= (100::Int)]
      certify=do
        revision<-evalRead reader ReadCustodyRevision
        evalWrite writer (RecordCustody revision 110 Nothing $ Just report)
  evalWrite writer (RecordSourceCheck source $ W.SourceMissing proof)
  loss<-ledgerSequence <$> evalRead reader ReadState
  expectStore "source_loss_not_covered" (evalRead reader $ CheckCoveredSource key loss)
  revision<-evalRead reader ReadCustodyRevision
  evalWrite writer (CoverSourceLoss source loss 110 (money 10) (money 0) "replace missing capital" proof (revision,110,True,report))
  evalRead reader (CheckCoveredSource key loss)
  expectStore "source_not_eligible" (evalRead reader $ CheckPaymentSource key)
  expectStore "source_approval_not_expected" (evalRead reader $ CheckSourceRestoration key loss)
  let approveCovered evidence=evalWrite writer (ApproveCoveredSource 110 key loss "covered loss reviewed" evidence)
  expectStore "custody_not_reconciled" (approveCovered proof)
  certify
  expectStore "source_recovery_scan_not_current" (approveCovered $ object ["transaction" .= tx,"output" .= (0::Int),"confirmations" .= (-1::Int),"observationHash" .= ("wrong"::T.Text)])
  expectStore "source_loss_custody_view_changed" (approveCovered $ object ["transaction" .= tx,"output" .= (0::Int),"confirmations" .= (-1::Int),"observationHash" .= observationHash,"nodeBlock" .= ("wrong"::T.Text),"nodeHeight" .= (100::Int)])
  fixture fixtures (SourceRecipient key "changed")
  expectStore "source_review_work_changed" (approveCovered proof)
  fixture fixtures (SourceRecipient key "recipient")
  certify
  coveredBalances<-evalRead reader ReadBalances
  approveCovered proof
  approved<-evalRead reader ReadState
  check (ledgerPaused approved)
  evalRead reader (ReadPayment key) >>= check . (==PaymentReady) . savedStatus
  evalRead reader (ReadSource did) >>= check . not . W.depositEligible
  evalRead reader (ReadCoveredApproval key loss) >>= check . (==Just "covered loss reviewed")
  expectStore "source_approval_kind_mismatch" (evalRead reader $ ReadSourceApproval key loss)
  expectStore "source_approval_kind_mismatch" (evalRead reader $ ReadCoveredApproval key second)
  approveCovered proof
  replayed<-evalRead reader ReadState
  check (ledgerSequence replayed==ledgerSequence approved)
  expectStore "source_approval_conflict" (evalWrite writer $ ApproveCoveredSource 110 key loss "changed" proof)
  evalRead reader ReadBalances >>= check . (==coveredBalances)

  evalRead reader (CheckPaymentSource key)
  evalWrite writer (RecordSourceCheck source $ W.SourceUnavailable $ object ["reason" .= ("offline"::T.Text)])
  expectStore "source_not_eligible" (evalRead reader $ CheckPaymentSource key)
  evalWrite writer (RecordSourceCheck source $ W.SourceMissing proof)
  evalRead reader (CheckPaymentSource key)
  fixture fixtures ReadyIntake
  void $ evalWrite writer (PreparePayment 110 key (money 10) "{}")
  evalWrite writer (SaveDraft key 0 "{}")
  fixture fixtures CoverBackup
  fixture fixtures ReadyIntake
  decision<-evalRead reader (ReadSigningDecision 110 key 0)
  let attempt=SignedAttempt "covered-conversion" "offline-covered-bytes" "{}" Nothing
      evidenceUnavailable=evalWrite writer (RecordSourceCheck source $ W.SourceUnavailable $ object ["reason" .= ("offline"::T.Text)])
      ready=fixture fixtures CoverBackup >> fixture fixtures ReadyIntake
  evidenceUnavailable
  ready
  expectStore "source_not_eligible" (evalRead reader $ ReadSigningDecision 110 key 0)
  expectStore "source_not_eligible" (evalWrite writer $ RecordAttempt decision attempt)
  evalWrite writer (RecordSourceCheck source $ W.SourceMissing proof)
  ready
  expiredAttempt<-evalWrite writer (RecordAttempt decision attempt {signedId="covered-expiry"})
  let expiryProof="{\"expiry\":\"offline covered-source expiry\"}"
  evalWrite writer (RecordSolanaExpiry expiredAttempt expiryProof)
  expired<-evalRead reader (ReadAttempt "covered-expiry")
  evalRead reader (CheckPaymentSource key)
  evalRead reader (ReadPayment key) >>= check . (==PaymentReview) . savedStatus
  ready
  expectStore "preparation_retry_not_authorized" (evalWrite writer $ PreparePayment 110 key (money 10) "{}")
  evidenceUnavailable
  fixture fixtures RefreshCustody
  expectStore "source_not_eligible" (evalWrite writer $ ApproveSolanaRetry 110 expired "covered retry" expiryProof)
  evalWrite writer (RecordSourceCheck source $ W.SourceMissing proof)
  fixture fixtures RefreshCustody
  evalWrite writer (ApproveSolanaRetry 110 expired "covered retry" expiryProof)
  ready
  second<-evalWrite writer (PreparePayment 110 key (money 10) "{}")
  check (preparedGeneration second==1)
  evalWrite writer (SaveDraft key 1 "{}")
  unsigned<-evalRead reader (ReadUnsignedPreparation key)
  evalWrite writer (Pause "cancel covered retry")
  fixture fixtures RefreshCustody
  evalWrite writer (BeginCancellation unsigned 110 "covered cancellation" "{}")
  evalWrite writer (FinishCancellation unsigned "covered cancellation" "{}")
  evalRead reader (ReadPayment key) >>= check . (==PaymentReady) . savedStatus
  ready
  third<-evalWrite writer (PreparePayment 110 key (money 10) "{}")
  check (preparedGeneration third==2)
  evalWrite writer (SaveDraft key 2 "{}")
  ready
  finalDecision<-evalRead reader (ReadSigningDecision 110 key 2)
  check (savedPayment(preparedView finalDecision)==savedPayment(preparedView decision))
  signed<-evalWrite writer (RecordAttempt finalDecision attempt)
  fixture fixtures ReadyIntake
  void $ evalWrite writer (MarkBroadcast 110 $ signedId $ recordedSigned signed)
  fixture fixtures CoverBackup
  fixture fixtures ReadyIntake
  evidenceUnavailable
  ready
  expectStore "source_not_eligible" (evalWrite writer $ AuthorizeSend 110 "covered-conversion")
  evalWrite writer (RecordSourceCheck source $ W.SourceMissing proof)
  ready
  authorized<-evalWrite writer (AuthorizeSend 110 "covered-conversion")
  beforePaid<-evalRead reader ReadBalances
  evalWrite writer (SettlePayment authorized (W.PaymentCosts (money 1) (money 0)) "offline-covered-effect")
  afterPaid<-evalRead reader ReadBalances
  let delta asset account=M.findWithDefault 0 (asset,account) afterPaid-M.findWithDefault 0 (asset,account) beforePaid
  check (delta Native Principal==(-10) && delta Native Float==9 && delta Native Earned==1
    && delta Wrapped Float==(-9) && delta Sol Operating==(-1))
  evalWrite writer (SettlePayment authorized (W.PaymentCosts (money 1) (money 0)) "offline-covered-effect")
  evalRead reader ReadBalances >>= check . (==afterPaid)
  void restore
  returned<-evalRead reader ReadBalances
  check (M.findWithDefault 0 (Native,Float) returned==M.findWithDefault 0 (Native,Float) afterPaid+10)
  suspend
  lostAgain<-evalRead reader (ReadSource did)
  evalWrite writer (RecordSourceCheck lostAgain $ W.SourceMissing proof)
  expectStore "source_not_eligible" (evalRead reader $ CheckPaymentSource key)

-- Deliberately synthetic ledger records: protocol bytes are validated separately
-- against captured Signet fixtures in NativePaymentCheck.
nativeReplacementContract :: PG.Connection -> Reader -> Writer -> IO ()
nativeReplacementContract fixtures reader writer=handle (\(BridgeError code)->fail $ "native replacement ledger contract: "<>T.unpack code) $ do
  captured<-getDataFileName "test/fixtures/native-signet-payment.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  originalPlan<-fieldValue "plan" captured
  originalTx<-fieldValue "decoded" captured >>= either reject pure . NP.decodeNativeTx
  let check ok=unless ok (fail "native replacement ledger contract")
      key=T.replicate 64 "6"; identifier="fee:"<>key
      plan=originalPlan {NP.planAmount=money 10,NP.planDepth=2,NP.planFeeLimit=money 5}
      point=NP.nativeOutpoint $ head $ NP.nativeInputs originalTx
      prevouts=[NP.NativePrevout point (money 100) (NP.planChangeScript plan) 2 False]
      outputs n=[NP.NativeOutput (NP.planChangeScript plan) (money n),NP.NativeOutput (NP.planRecipientScript plan) (money 10)]
      tx=originalTx {NP.nativeTxid=T.replicate 64 "6",NP.nativeOutputs=outputs 89}
      signed=NP.NativeSigned "00" tx plan prevouts (money 1)
      wire=SignedAttempt (NP.nativeTxid tx) "00" (encodeText signed) (Just $ NP.outpointTxid point<>":"<>T.pack(show $ NP.outpointVout point))
      draft=NP.NativeDraft "offline-replacement" tx {NP.nativeTxid=T.replicate 64 "7",NP.nativeOutputs=outputs 88} prevouts (money 2)
      ready=fixture fixtures ReadyIntake
      paused=evalWrite writer (Pause "replacement ledger contract") >> fixture fixtures RefreshCustody
  paused
  void $ evalWrite writer (ReserveFees 110 key Native (money 10) (NP.planRecipient plan) "replacement earnings")
  ready
  void $ evalWrite writer (PreparePayment 110 identifier (money 5) $ encodeText plan)
  evalWrite writer (SaveDraft identifier 0 $ encodeText $ NP.NativeDraft "offline-original" tx prevouts (money 1))
  prepared<-evalRead reader (ReadPreparation identifier)
  void $ evalWrite writer (RecordAttempt prepared wire)
  ready
  void $ evalWrite writer (MarkBroadcast 110 $ signedId wire)
  parent<-evalRead reader (ReadAttempt $ signedId wire)
  evalRead reader (ReadNativeFamily identifier) >>= check . (==[(parent,signed)])
  let save reason=evalWrite writer (SaveReplacementDraft 110 parent draft reason)
  expectStore "pause_before_operator_action" (save "increase fee")
  expectStore "pause_before_operator_action" (evalRead reader $ ReadReplacementDraftContext 110 (signedId wire) (money 2))
  paused
  evalRead reader (ReadReplacementDraftContext 110 (signedId wire) (money 2)) >>= check . (==[(parent,signed)])
  badFee<-try (evalRead reader $ ReadReplacementDraftContext 110 (signedId wire) (money 1)) :: IO (Either BridgeError [(RecordedAttempt,NP.NativeSigned)])
  check (case badFee of Left _->True; Right _->False)
  before<-evalRead reader ReadBalances
  decision<-save "increase fee"
  evalRead reader (ReadReplacementDecision (signedId wire) (money 2) "increase fee") >>= check . (==Just(decision,False))
  n<-ledgerSequence <$> evalRead reader ReadState
  save "increase fee" >>= check . (==decision)
  operate (Op.operator $ Op.DraftNativeReplacement (signedId wire) (money 2) "increase fee") >>= check . (==decision)
  evalRead reader ReadState >>= check . (==n) . ledgerSequence
  expectStore "native_replacement_draft_conflict" (evalWrite writer $ SaveReplacementDraft 110 parent draft {NP.draftPsbt="changed"} "increase fee")
  expectStore "native_replacement_draft_pending" (save "another decision")
  evalRead reader (ReadReplacementPayment decision) >>= check . (==identifier)
  expectStore "native_replacement_draft_pending" (evalRead reader $ ReadReplacementDraftContext 110 (signedId wire) (money 3))
  fixture fixtures CoverBackup
  ready
  expectStore "native_replacement_draft_pending" (evalWrite writer $ AuthorizeSend 110 $ signedId wire)
  paused
  operate (Op.operator $ Op.CancelNativeReplacement decision "abandon unsigned draft")
  operate (Op.operator $ Op.CancelNativeReplacement decision "abandon unsigned draft")
  expectStore "native_replacement_cancellation_conflict" (evalWrite writer $ CancelReplacementDraft decision "different")
  evalRead reader (ReadReplacementDecision (signedId wire) (money 2) "increase fee") >>= check . (==Just(decision,True))
  save "increase fee" >>= check . (==decision)
  expectStore "native_replacement_cancelled" (operate $ Op.operator $ Op.DraftNativeReplacement (signedId wire) (money 2) "increase fee")
  ready
  expectStore "backup_pending" (evalWrite writer $ AuthorizeSend 110 $ signedId wire)
  fixture fixtures CoverBackup
  ready
  restored<-evalWrite writer (AuthorizeSend 110 $ signedId wire)
  check (restored==parent)
  evalRead reader ReadBalances >>= check . (==before)
  paused
  expectStore "native_replacement_not_unsigned" (evalRead reader $ ReadReplacementSigning 110 decision)
  second<-save "reviewed replacement"
  expectStore "signing_backup_required" (evalRead reader $ ReadReplacementSigning 110 second)
  fixture fixtures CoverBackup
  expectStore "custody_not_reconciled" (evalRead reader $ ReadReplacementSigning 110 second)
  fixture fixtures RefreshCustody
  (family,savedDraft)<-evalRead reader (ReadReplacementSigning 110 second)
  check (family==[(parent,signed)] && savedDraft==draft)
  let replacement=signed {NP.signedNativeBytes="02",NP.signedNativeTransaction=NP.draftTransaction draft,NP.signedNativeFee=money 2}
      record expected member=evalWrite writer (RecordReplacement 110 second expected member)
  expectStore "native_replacement_family_changed" (record [] replacement)
  expectStore "native_fee_mismatch" (record family replacement {NP.signedNativeFee=money 3})
  child<-record family replacement
  sequenceNo<-ledgerSequence <$> evalRead reader ReadState
  record family replacement >>= check . (==child)
  operate (Op.operator $ Op.SignNativeReplacement second) >>= check . (==signedId(recordedSigned child))
  evalRead reader ReadState >>= check . (==sequenceNo) . ledgerSequence
  evalRead reader (ReadReplacementMember second) >>= check . (==Just child)
  expectStore "native_replacement_signature_conflict" (record family replacement {NP.signedNativeBytes="04"})
  expectStore "native_replacement_already_signed" (evalWrite writer $ CancelReplacementDraft second "too late")
  evalRead reader (ReadNativeFamily identifier) >>= check . (==[(parent,signed),(child,replacement)])
  evalRead reader ReadNativeLockWork >>= check . (==Just [parent,child]) . fmap lockAttempts
  evalRead reader ReadBalances >>= check . (==before)
  ready
  expectStore "native_replacement_not_current" (evalWrite writer $ AuthorizeSend 110 $ signedId wire)
  void $ evalWrite writer (MarkBroadcast 110 $ signedId $ recordedSigned child)
  fixture fixtures CoverBackup
  ready
  authorized<-evalWrite writer (AuthorizeSend 110 $ signedId $ recordedSigned child)
  let anchor=T.replicate 64 "a"
      proof member block=encodeText $ object ["txid" .= signedId(recordedSigned member),"blockhash" .= block,"height" .= (100::Int),"requiredDepth" .= (2::Int)]
  evalWrite writer (SettlePayment authorized (W.PaymentCosts (money 2) (money 0)) $ proof child anchor)
  evalRead reader PendingAttempts >>= check . all (`notElem` [signedId wire,signedId(recordedSigned child)])
  evalRead reader ReadNativeLockWork >>= check . (==Nothing)
  evaluateOffline (Left $ Request $ ReconcilePayment $ signedId wire)
  evaluateOffline (Left $ Request $ ReconcilePayment $ signedId $ recordedSigned child)
  -- Actual PostgreSQL winner history with synthetic chain evidence: principal
  -- remains paid while either family member becomes the canonical winner.
  settled<-evalRead reader (ReadAttempt $ signedId $ recordedSigned child)
  settledBalances<-evalRead reader ReadBalances
  let record saved result=evalWrite writer (RecordNativeSettlement saved result)
      sequenceNo=ledgerSequence <$> evalRead reader ReadState
      scanned saved block depth fee=fixture fixtures $ SeedTreasuryEvidence "Native" (signedId $ recordedSigned saved) block "outgoing" 0
        (object ["confirmations" .= (depth::Int),"walletNetUnits" .= ("-10"::T.Text),"feeUnits" .= money fee])
      costs fee=W.PaymentCosts (money fee) (money 0)
      candidate saved=elem (signedId $ recordedSigned saved) . map (signedId.recordedSigned) <$> evalRead reader NativeSettlementCandidates
      b=T.replicate 64 "b"; c=T.replicate 64 "c"; d=T.replicate 64 "d"
  record settled NativeConfirming
  n<-sequenceNo
  record settled NativeConfirming
  sequenceNo >>= check . (==n)
  record settled (NativeUnavailable "offline unavailable")
  n2<-sequenceNo
  record settled (NativeUnavailable "offline unavailable")
  sequenceNo >>= check . (==n2)
  candidate settled >>= check
  scanned settled b 1 2
  expectStore "native_recovery_scan_not_current" (record settled $ NativeReconfirmed (costs 2) $ proof settled b)
  expectStore "native_recovery_cost_changed" (record settled $ NativeReconfirmed (costs 3) $ proof settled b)
  scanned settled b 2 2
  record settled (NativeReconfirmed (costs 2) $ proof settled b)
  reconfirmed<-evalRead reader (ReadAttempt $ signedId $ recordedSigned settled)
  n3<-sequenceNo
  record reconfirmed (NativeReconfirmed (costs 2) $ proof reconfirmed b)
  sequenceNo >>= check . (==n3)
  candidate reconfirmed >>= check . not
  evalRead reader ReadBalances >>= check . (==settledBalances)
  familyNow<-map fst <$> evalRead reader (ReadNativeFamily identifier)
  scanned parent c 2 1
  expectStore "native_replacement_family_changed" (record reconfirmed $ NativeWinnerChanged [] (signedId wire) (costs 1) $ proof parent c)
  expectStore "native_recovery_policy_changed" (record reconfirmed $ NativeWinnerChanged familyNow (signedId wire) (costs 2) $ proof parent c)
  record reconfirmed (NativeWinnerChanged familyNow (signedId wire) (costs 1) $ proof parent c)
  changed<-evalRead reader (ReadAttempt $ signedId wire)
  let lowerFee=M.insertWith (+) (Native,Operating) 1 $ M.insertWith (+) (Native,External) (-1) settledBalances
  evalRead reader ReadBalances >>= check . (==lowerFee)
  evalRead reader (ReadPayment identifier) >>= check . (==PaymentPaid) . savedStatus
  expectStore "native_settlement_changed" (record reconfirmed $ NativeWinnerChanged familyNow (signedId wire) (costs 1) $ proof parent c)
  candidate changed >>= check . not
  updatedFamily<-map fst <$> evalRead reader (ReadNativeFamily identifier)
  scanned child d 2 2
  record changed (NativeWinnerChanged updatedFamily (signedId $ recordedSigned child) (costs 2) $ proof child d)
  restoredWinner<-evalRead reader (ReadAttempt $ signedId $ recordedSigned child)
  candidate restoredWinner >>= check . not
  evalRead reader ReadBalances >>= check . (==settledBalances)
  evalRead reader PendingAttempts >>= check . all (`notElem` [signedId wire,signedId(recordedSigned child)])
  evalRead reader ReadState >>= check . ledgerPaused
  -- Same winner/proof after a winner change creates no stale recovery decision.
  n4<-sequenceNo
  record restoredWinner (NativeReconfirmed (costs 2) $ proof restoredWinner d)
  sequenceNo >>= check . (==n4)
  -- Rebroadcast decisions repair the original booked effect; no new signature,
  -- payment, principal posting or fee reservation is produced by authorization.
  let winnerId=signedId(recordedSigned restoredWinner)
  expectStore "native_rebroadcast_review_missing" (evalRead reader $ ReadNativeRebroadcastContext winnerId)
  record restoredWinner (NativeUnavailable "native_settled_payment_unseen")
  (rebroadcast,family,anchorSequence)<-evalRead reader (ReadNativeRebroadcastContext winnerId)
  operate (Op.operatorRead Op.NativeReviews) >>= check . elem (winnerId,"unavailable",anchorSequence)
  let members=map fst family
      reason="repair original settled effect"
      rebroadcastProof bytesHash=object ["transaction" .= winnerId,"bytesHash" .= bytesHash,"nodeBlock" .= d
        ,"family" .= map (signedId.recordedSigned) members,"noActiveFamilyPayment" .= True]
      hash=digest(TE.encodeUtf8 $ signedBytes $ recordedSigned rebroadcast)
      approve expected recovery why evidence=evalWrite writer (RecordNativeRebroadcast expected members recovery why evidence)
      authorize n=evalWrite writer (AuthorizeNativeRebroadcast rebroadcast members n)
  expectStore "native_rebroadcast_review_changed" (approve rebroadcast (anchorSequence-1) reason $ rebroadcastProof hash)
  expectStore "native_rebroadcast_proof_mismatch" (approve rebroadcast anchorSequence reason $ rebroadcastProof "changed")
  expectStore "native_rebroadcast_review_changed" (approve rebroadcast {recordedSigned=(recordedSigned rebroadcast) {signedBytes="different"}} anchorSequence reason $ rebroadcastProof hash)
  approved<-approve rebroadcast anchorSequence reason (rebroadcastProof hash)
  n5<-sequenceNo
  approve rebroadcast anchorSequence reason (rebroadcastProof hash) >>= check . (==approved)
  sequenceNo >>= check . (==n5)
  expectStore "native_rebroadcast_conflict" (evalRead reader $ ReadNativeRebroadcastDecision winnerId anchorSequence "different")
  expectStore "backup_pending" (authorize approved)
  -- Repeated absence must retain the approved journal binding for lost replies.
  record restoredWinner (NativeUnavailable "native_settled_payment_unseen")
  evalRead reader (ReadNativeRebroadcastContext winnerId) >>= \(_,_,n)->check (n==approved)
  fixture fixtures CoverBackup
  authorize approved >>= check . (==rebroadcast)
  authorize approved >>= check . (==rebroadcast)
  fixture fixtures ReadyIntake
  expectStore "pause_before_operator_action" (authorize approved)
  evalWrite writer (Pause "rebroadcast remains paused")
  record restoredWinner NativeConfirming
  expectStore "native_rebroadcast_review_changed" (authorize approved)
  expectStore "native_rebroadcast_review_changed" (operate $ Op.operator $ Op.RebroadcastNative winnerId anchorSequence reason)
  record restoredWinner (NativeUnavailable "rpc_unavailable")
  expectStore "native_rebroadcast_not_missing" (evalRead reader $ ReadNativeRebroadcastContext winnerId)
  record restoredWinner (NativeReconfirmed (costs 2) $ proof restoredWinner d)
  evalRead reader ReadBalances >>= check . (==settledBalances)
  evalRead reader PendingAttempts >>= check . all (`notElem` [signedId wire,winnerId])
 where
  encodeText value=TE.decodeUtf8 (BL.toStrict $ encode value)
  -- These branches must replay/cancel from the ledger alone. Unavailable
  -- credentials and a rejecting manager prove that neither RPC nor signing runs.
  operate :: Op.Plan 'Op.Operator a -> IO a
  operate=evaluateOffline . Right
  evaluateOffline :: Either (Request 'Op.Worker 'Op.Critical a) (Op.Plan 'Op.Operator a) -> IO a
  evaluateOffline operation=do
    let key=T.replicate 32 "1"
        native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused" "workflow" 1 (T.replicate 64 "0")
        solana=Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing key key key
        settings=ObserverSettings native solana 2 "sol-origin" "opening-signature"
        config=H.SolanaPolicy "contract" "contract" key key key (money 10) (money 10)
    bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> fail "replacement replay reached network"}) closeManager $ \manager->
      withRuntime manager settings config Nothing (SigningEndpoint 9443 "/unused/auth") reader writer $ \worker _ operator->either worker operator operation

-- Real pg_dump/pg_restore, disposable database only. All row comparisons use
-- closed Opaleye fixtures; createdb/restore/dropdb are schema infrastructure.
archiveContract :: PG.ConnectInfo -> PG.Connection -> Reader -> IO ()
archiveContract settings fixtures reader = do
  let check ok=unless ok (fail "ledger archive contract failed")
      temporary=do
        (path,handle)<-openTempFile "/tmp" "ecx-ledger-archive"
        hClose handle
        removeFile path
        createDirectory path
        setFileMode path 0o700
        pure path
  bracket temporary removeDirectoryRecursive $ \directory->do
    before<-evalRead reader ReadState
    records<-fixture fixtures ArchiveRecords
    expectStore "invalid_backup_directory" (evalBackup reader $ ExportLedger "relative")
    setFileMode directory 0o755
    expectStore "unsafe_backup_directory" (evalBackup reader $ ExportLedger directory)
    setFileMode directory 0o700
    archive<-evalBackup reader (ExportLedger directory)
    check (archiveSequence archive==ledgerSequence before && archiveIdentity archive=="contract")
    forM_ [archivePath archive,manifestPath archive] $ \path->do
      status<-Posix.getSymbolicLinkStatus path
      check (Posix.isRegularFile status && Posix.fileMode status .&. 0o077==0)
    bytes<-BS.readFile (archivePath archive)
    check (archiveHash archive==digest bytes && BS.take 5 bytes=="PGDMP")
    manifest<-BS.readFile (manifestPath archive) >>= either fail pure . eitherDecodeStrict'
    fieldValue "criticalSequence" manifest >>= check . (==ledgerSequence before)
    fieldValue "sha256" manifest >>= check . (==archiveHash archive)
    fieldValue "remoteDurabilityAcknowledged" manifest >>= check . (==False)
    -- A second archive must not overwrite the first or advance coverage.
    again<-evalBackup reader (ExportLedger directory)
    check (archivePath again/=archivePath archive && manifestPath again/=manifestPath archive)
    evalRead reader ReadState >>= check . (==before)
    role<-getEnv "ECX_REBUILD_CONTRACT_READER"
    let restore manifestFile=bracket (evalRestore settings $ RestoreLedger manifestFile "contract" (archiveSequence archive))
          (\(database,_)->Backup.discardRestore settings {PG.connectDatabase=T.unpack database}) $ \(database,n)->do
            check (n==archiveSequence archive && database/=T.pack(PG.connectDatabase settings))
            let target=settings {PG.connectDatabase=T.unpack database}
                (rows,attempts,postings)=records
                paused=[row {S.paused=1,S.pauseReason="restored_requires_reconciliation"} | row<-rows]
            bracket (PG.connect target) PG.close $ \connection->do
              fixture connection ArchiveRecords >>= check . (==(paused,attempts,postings))
              fixture connection ReadCustodyCheck >>= check . (==(Nothing,Nothing,Just "restored_requires_reconciliation"))
            denied<-try (bracket (PG.connect target {PG.connectUser=role}) PG.close (const $ pure ())) :: IO (Either SomeException ())
            check (case denied of Left err->"permission denied for database" `T.isInfixOf` T.pack(show err); Right ()->False)
    databasesBefore<-fixture fixtures RestoreDatabases
    expectStore "invalid_restore_policy" (evalRestore settings $ RestoreLedger (manifestPath archive) "contract" (-1))
    expectStore "backup_identity_mismatch" (evalRestore settings $ RestoreLedger (manifestPath archive) "wrong" 0)
    expectStore "backup_snapshot_too_old" (evalRestore settings $ RestoreLedger (manifestPath archive) "contract" (archiveSequence archive+1))
    restore (manifestPath archive)
    let tampered=directory</>"tampered.json"
        change key value=case manifest of
          Object fields->BL.writeFile tampered (encode $ Object $ KM.insert key value fields) >> setFileMode tampered 0o600
          _->fail "manifest object required"
    change "criticalSequence" (toJSON $ archiveSequence archive+1)
    expectStore "restored_sequence_mismatch" (evalRestore settings $ RestoreLedger tampered "contract" 0)
    change "schemaVersion" (toJSON (18::Int))
    expectStore "invalid_backup_manifest" (evalRestore settings $ RestoreLedger tampered "contract" 0)
    change "sha256" (toJSON $ T.replicate 64 "0")
    expectStore "backup_archive_mismatch" (evalRestore settings $ RestoreLedger tampered "contract" 0)
    fixture fixtures RestoreDatabases >>= check . (==databasesBefore)
    (program,repository,password,configuration)<-testRepository directory
    let protected path contents=BS.writeFile path contents >> setFileMode path 0o600
        localRepository=TE.encodeUtf8 $ T.pack(directory</>"encrypted-repository")
        upload=Backup.uploadArchive program repository password
    expectStore "https_backup_repository_required" (evalBackup reader $ UploadLedger configuration directory 0)
    expectStore "invalid_backup_coverage" (evalBackup reader $ UploadLedger configuration directory (-1))
    forM_ ["rest:http://example.com/backup","/tmp/local"] $ \url->do
      protected repository url
      expectStore "https_backup_repository_required" (Backup.loadRemoteBackup configuration)
    forM_ ["rest:https://localhost/backup","rest:https://127.0.0.1/backup","rest:https://[::1]/backup","rest:https://[::ffff:127.0.0.1]/backup"] $ \url->do
      protected repository url
      expectStore "off_host_backup_required" (Backup.loadRemoteBackup configuration)
    protected repository localRepository
    setFileMode repository 0o644
    expectStore "unsafe_backup_file" (upload archive)
    setFileMode repository 0o600
    expectStore "backup_archive_mismatch" (upload archive {archiveSequence=archiveSequence archive+1})
    expectStore "backup_archive_mismatch" (upload archive {archiveHash=T.replicate 64 "0"})
    receipt<-upload archive
    check (receiptIdentity receipt==archiveIdentity archive && receiptSequence receipt==archiveSequence archive && receiptArchiveHash receipt==archiveHash archive)
    let download identifier expected minimumSequence=Backup.downloadArchive program repository password identifier expected minimumSequence directory
        snapshot=receiptSnapshot receipt
        clean=removeDirectoryRecursive . takeDirectory . manifestPath
    filesBefore<-sort <$> listDirectory directory
    expectStore "https_backup_repository_required" (evalRestore settings $ RecoverLedger configuration snapshot directory "contract" 0)
    expectStore "invalid_backup_snapshot" (download "latest" "contract" 0)
    expectStore "invalid_restore_policy" (download snapshot "contract" (-1))
    expectStore "backup_identity_mismatch" (download snapshot "other" 0)
    expectStore "backup_snapshot_too_old" (download snapshot "contract" (archiveSequence archive+1))
    -- Production downloader and production restore, with real restic encryption.
    -- The private local-repository seam grants no worker coverage.
    bracket (download snapshot "contract" (archiveSequence archive)) clean $ \recovered->do
      check (takeDirectory(manifestPath recovered)/=directory && archiveHash recovered==archiveHash archive)
      BS.readFile (archivePath recovered) >>= check . (==bytes)
      forM_ [archivePath recovered,manifestPath recovered] $ \path->do
        status<-Posix.getSymbolicLinkStatus path
        check (Posix.isRegularFile status && Posix.fileMode status .&. 0o077==0)
      restore (manifestPath recovered)
    (sort <$> listDirectory directory) >>= check . (==filesBefore)
    fixture fixtures RestoreDatabases >>= check . (==databasesBefore)
    protected password "wrong-passphrase"
    expectStore "backup_process_failed" (upload archive)
    expectStore "backup_process_failed" (download snapshot "contract" 0)
    (sort <$> listDirectory directory) >>= check . (==filesBefore)
    evalRead reader ReadState >>= check . (==before)
    fixture fixtures ArchiveRecords >>= check . (==records)
    putStrLn "PASS: authenticated download, restricted paused restore, stale/identity/schema/hash refusal, failed-stage cleanup, private snapshot, real restic encryption/readback/restore, repository/permission/integrity/password refusal, unchanged coverage, exact signed attempts and every ledger posting"
