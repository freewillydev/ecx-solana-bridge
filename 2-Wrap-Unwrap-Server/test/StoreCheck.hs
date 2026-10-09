{-# LANGUAGE DataKinds, GADTs, ScopedTypeVariables #-}
module Main (main) where
import qualified ProvisionCheck
import qualified Bridge.Config as Config
import qualified Bridge.AdminKey as AdminKey
import qualified Bridge.Credentials as Credentials
import Paths_ecx_bridge (getDataFileName)
import qualified Network.HTTP.Client as HTTP
import qualified Network.Socket as NS
import qualified System.Process as Process
import System.FilePath (takeDirectory,isAbsolute,(</>))
import qualified System.Posix.Directory as PD
import System.IO.Error (isDoesNotExistError)
import qualified Bridge.Store.Backup as Backup
import Bridge.Store.Catalog (exportSnapshot,claimWorker)
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import Crypto.Random (getRandomBytes)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync,wait,cancel,poll,mapConcurrently)
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,tryPutMVar)
import System.Timeout (timeout)
import qualified Opaleye.Internal.Locking as Locking
import Bridge.Identity (capabilityHash,payInstruction,digest,publicKey)
import qualified Bridge.Wire as W
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson (ToJSON,encode,object,(.=),toJSON,Value(..),eitherDecodeStrict')
import Data.Profunctor.Product (p2,p3,p6,p7,p8,p9)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base64 as B64
import qualified Data.Text.Encoding as TE
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),CostLimits(..),PolicySnapshot(..))
import Bridge.Store
import Bridge.Signer
import Bridge.Recovery
import Bridge.Payment (payoutReference)
import qualified Bridge.Control as Control
import Bridge.Critical
import qualified Bridge.Operation.Internal as Op
import qualified Network.Wai as Wai
import Network.HTTP.Types (statusCode,status200,status500)
import Bridge.Order
import qualified Bridge.Fence as Fence
import System.Directory (createDirectory,removeDirectoryRecursive,removeFile,findExecutable,listDirectory,renameFile,renameDirectory)
import System.IO (openTempFile,hClose,withFile,IOMode(WriteMode),stdout,hSetBuffering,BufferMode(LineBuffering))
import System.Posix.Files (setFileMode)
import qualified System.Posix.Files as Posix
import System.Posix.Signals (signalProcess,sigKILL)
import Data.Bits ((.&.))
import qualified Bridge.NativePayment as NP
import Bridge.Error (reject)
import Bridge.Observer (ObserverSettings(..))
import Bridge.Reconciliation (inspectCustodyWith,nativeBalance)
import Bridge.RPC (fieldValue,newRpcManager,rpcManagerSettings,rpc)
import qualified Bridge.SolanaPayment as SP
import qualified Network.Wai.Handler.Warp as Warp
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Clock (getMonotonicTimeNSec)
import Text.Read (readMaybe)
import Servant.API (BasicAuthData(..))
import qualified Bridge.Native as N
import qualified Bridge.Solana as Solana
import qualified Bridge.SolanaHelper as H
import qualified Bridge.SolanaMessage as SolanaMessage
import Network.HTTP.Client (newManager,closeManager,defaultManagerSettings,managerModifyRequest)
import Network.HTTP.Client.TLS (mkManagerSettings)
import qualified Network.Connection as NC
import qualified Network.TLS as TLS
import Network.TLS.Extra.Cipher (ciphersuite_default)
import Data.X509.CertificateStore (makeCertificateStore)
import qualified Bridge.Store.Schema as S
import qualified Bridge.Store.Migration as Legacy
import qualified Bridge.Store.Projection as Projection
import Control.Exception
import Data.Int (Int64)
import Data.List (sort)
import Data.IORef
import GHC.Stack (HasCallStack,callStack,prettyCallStack)
import Test.QuickCheck (quickCheckWithResult,stdArgs,maxSuccess,forAll,chooseInteger,ioProperty,isSuccess)
import Control.Monad (unless,void,when,forM_,filterM)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types (Identifier(..),Query(..))
import qualified Opaleye as O
import System.Exit (ExitCode(..))
import System.Environment (getEnv,lookupEnv,getEnvironment,getExecutablePath)

main :: IO ()
main=lookupEnv "ECX_PROVISION_CHILD" >>= maybe normal ProvisionCheck.child
 where
  normal=lookupEnv "ECX_PROVISION_TEST" >>= \mode->if mode==Just "1" then ProvisionCheck.contract
    else lookupEnv "ECX_FUNDED_RECOVERY_CONFIG" >>= maybe contractMain fundedRecoveryMain

contractMain :: IO ()
contractMain = do
  credentialsContract
  cacheOnly<-lookupEnv "ECX_REPORT_CACHE_ONLY"
  migration<-lookupEnv "ECX_REBUILD_MIGRATION_ONLY"
  roots<-lookupEnv "ECX_REBUILD_PAYMENT_ROOTS_ONLY"
  live<-lookupEnv "ECX_REBUILD_LIVE_OBSERVER_CONFIG"
  setup<-lookupEnv "ECX_REBUILD_SETUP_ONLY"
  fence<-lookupEnv "ECX_REBUILD_FENCE_ONLY"
  server<-lookupEnv "ECX_REBUILD_SERVER_ONLY"
  tls<-lookupEnv "ECX_REBUILD_TLS_ONLY"
  native<-lookupEnv "ECX_REBUILD_NATIVE_RECOVERY_ONLY"
  encrypted<-lookupEnv "ECX_REBUILD_ENCRYPTED_NATIVE_ONLY"
  custody<-lookupEnv "ECX_REBUILD_CUSTODY_ONLY"
  when (encrypted==Just "1" && (native/=Just "1" || custody/=Just "1"))
    (fail "encrypted native acceptance requires native recovery and custody modes")
  if cacheOnly==Just "1" then reportCacheMain else if roots==Just "child" then paymentRootsChild else if roots==Just "1" then paymentRootsMain else if migration==Just "1" then migrationMain else case live of
    Just path->liveObserverMain path
    Nothing->if setup==Just "1" then setupMain else if native==Just "1" then nativeRecoveryMain else if tls==Just "1" then tlsMain else if fence==Just "1" then fenceMain else if server==Just "1" then serverMain else ledgerMain

-- Read-only evidence for the independently provisioned funded acceptance ledger.
-- Financial work now enters the running server's customer/operator interfaces.
-- Stop that worker before inspecting: these reads do not quiesce it or promise
-- a consistent multi-query snapshot while another process is changing the ledger.
fundedRecoveryMain :: FilePath -> IO ()
fundedRecoveryMain path=do
  config<-Config.loadConfig path
  unless (Config.profile config==W.L2LSignetDevnet) (fail "funded inspection requires L2L Signet/Devnet")
  host<-getEnv "PGHOST"; port<-getEnv "PGPORT"; database<-getEnv "PGDATABASE"
  user<-getEnv "PGUSER"; readerUser<-getEnv "PGREADUSER"
  unless (host=="/tmp/ecx-pg-seam" && port=="29436" && user/=readerUser && not(null readerUser)
    && any (`T.isPrefixOf` T.pack database) ["ecx_rebuild_contract_","ecx_restore_"])
    (fail "funded inspection requires the dedicated local acceptance database and reader")
  password<-maybe "" id <$> lookupEnv "PGPASSWORD"
  readerPassword<-maybe password id <$> lookupEnv "PGREADPASSWORD"
  step<-getEnv "ECX_FUNDED_RECOVERY_STEP"
  unless (step=="inspect") (fail "funded staging is retired; use the running server's customer/operator interfaces")
  requestFile<-getEnv "ECX_FUNDED_RECOVERY_REQUEST"
  request<-AdminKey.readPrivate requestFile >>= either (const $ fail "invalid funded inspection request") pure . eitherDecodeStrict'
  case request of
    Object values | KM.keys values==["payment"]->pure ()
    _->fail "unexpected funded inspection fields"
  let readerSettings=PG.defaultConnectInfo {PG.connectHost=host,PG.connectPort=29436,PG.connectDatabase=database
        ,PG.connectUser=readerUser,PG.connectPassword=readerPassword}
  withReader readerSettings (Config.fingerprint config) (Config.backupRequired config) $ \reader->do
    let
      workEvidence identifier=do
        (view,prepared,attempts)<-evalRead reader (ReadPaymentWork identifier)
        source<-evalRead reader (ReadPaymentSource identifier)
        evidence<-case source of
          Just binding | W.depositAsset(W.sourceDeposit binding)==Native->Just . snd <$> evalRead reader (ReadNativeSourceInspection $ W.depositId $ W.sourceDeposit binding)
          _->pure Nothing
        history<-case source of
          Just binding->bracket (PG.connect readerSettings) PG.close (\c->fixture c $ SourceHistory $ W.depositId $ W.sourceDeposit binding)
          _->pure []
        past<-bracket (PG.connect readerSettings) PG.close (\c->fixture c $ PaymentAttemptHistory identifier)
        recorded<-mapM (\txid->do
          saved<-evalRead reader (ReadAttempt txid)
          expiry<-evalRead reader (ReadSolanaExpiry txid)
          pure $ object ["transaction" .= txid,"state" .= recordedState saved,"generation" .= recordedGeneration saved
            ,"sequence" .= recordedSequence saved,"bytesHash" .= digest(TE.encodeUtf8 $ signedBytes $ recordedSigned saved)
            ,"expiryEvidence" .= expiry]) past
        pure $ object ["payment" .= identifier,"paymentStatus" .= show(savedStatus view)
          ,"prepared" .= (prepared/=Nothing),"generation" .= fmap preparedGeneration prepared
          ,"draftSaved" .= maybe False ((/=Nothing).preparedDraft) prepared,"attempts" .= attempts
          ,"source" .= fmap (show . W.sourceDeposit) source,"sourceEvidence" .= evidence,"sourceHistory" .= history,"attemptHistory" .= recorded]
    identifier<-fieldValue "payment" request
    result<-workEvidence identifier
    state<-evalRead reader ReadState
    balances<-evalRead reader ReadBalances
    pending<-evalRead reader PendingAttempts
    payments<-evalRead reader PaymentCandidates
    (health,custody,recovery)<-bracket (PG.connect readerSettings) PG.close $ \connection->
      (,,) <$> fixture connection LiveScanHealth <*> fixture connection ReadCustodyCheck <*> fixture connection NativeRecoveryEvidence
    now<-floor <$> getPOSIXTime :: IO Int64
    BL.putStr $ encode(object ["step" .= step,"result" .= result,"identity" .= Config.fingerprint config
      ,"observedAt" .= now,"scanHealth" .= health,"custodyCheck" .= custody,"nativeRecovery" .= recovery
      ,"criticalSequence" .= ledgerSequence state,"backupSequence" .= ledgerBackup state
      ,"paused" .= ledgerPaused state,"reason" .= ledgerReason state,"pendingAttempts" .= pending
      ,"paymentCandidates" .= payments,"balances" .=
        [object ["asset" .= asset,"account" .= show account,"amount" .= show quantity]
          | ((asset,account),quantity)<-M.toList balances]])<>"\n"

-- Offline credential/RPC contract. The fixture records only method names, never
-- secrets; real encrypted-wallet recovery is exercised separately below.
credentialsContract :: IO ()
credentialsContract=withTestSigningKey $ \key->do
  let file=takeDirectory key </> "native-unlock"
      secret=" exact café passphrase "
      bytes=TE.encodeUtf8 secret
      write value=BS.writeFile file value >> setFileMode file 0o600
      check ok=unless ok (fail "native unlock credential contract failed")
      native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:1" "/unused" "unlock-contract"
        16000 "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47"
  write bytes
  Credentials.readNativeUnlock file >>= check . (==secret)
  write (BS.replicate 1024 97)
  Credentials.readNativeUnlock file >>= check . (==T.replicate 1024 "a")
  forM_ [BS.empty,BS.replicate 1025 97,BS.singleton 255,BS.pack [97,0,98],"a\nb","a\rb"] $ \invalid->do
    write invalid
    expectStore "invalid_native_unlock_file" (Credentials.readNativeUnlock file)
  write bytes
  setFileMode file 0o644
  expectStore "unsafe_signer_file_permissions" (Credentials.readNativeUnlock file)
  setFileMode file 0o600
  bracket_ (Posix.createSymbolicLink file (file<>".link")) (removeFile $ file<>".link") $
    expectStore "unsafe_signer_file_permissions" (Credentials.readNativeUnlock $ file<>".link")
  bracket_ (Posix.createLink file (file<>".hard")) (removeFile $ file<>".hard") $
    expectStore "unsafe_signer_file_permissions" (Credentials.readNativeUnlock file)
  expiry<-newIORef (0::Int64)
  mode<-newIORef ("ok"::T.Text)
  methods<-newIORef ([]::[T.Text])
  let record method=modifyIORef' methods (<>[method])
      call wallet method arguments=do
        check wallet
        record method
        behavior<-readIORef mode
        case (method,arguments) of
          ("getwalletinfo",[])->do
            untilTime<-readIORef expiry
            pure $ object $ ["walletname" .= N.nativeWallet native,"descriptors" .= True,
              "scanning" .= False,"private_keys_enabled" .= True,"external_signer" .= False]
              <>["unlocked_until" .= untilTime | behavior/="unencrypted"]
          ("walletpassphrase",[String supplied,Number lease])->do
            check (lease==120)
            unless (supplied==secret) (reject "rpc_error_-14")
            now<-floor <$> getPOSIXTime
            writeIORef expiry (now+120)
            when (behavior=="ambiguous") (reject "rpc_transport_unknown_outcome")
            pure Null
          ("walletlock",[])->do
            when (behavior=="lock-failure") (reject "rpc_transport_unknown_outcome")
            writeIORef expiry 0
            pure Null
          _->fail "unexpected credential fixture RPC"
      scoped=Credentials.withNativeUnlock call native (Just file)
      reset behavior=writeIORef methods [] >> writeIORef expiry 0 >> writeIORef mode behavior
      finished expected=do
        readIORef methods >>= check . (==expected)
        readIORef expiry >>= check . (==0)
      begin=["getwalletinfo","walletpassphrase"]
      complete=begin<>["getwalletinfo","action","walletlock"]
  scoped (record "action")
  finished complete
  reset "ok"
  write "wrong-passphrase"
  expectStore "rpc_error_-14" (scoped $ record "action")
  finished (begin<>["walletlock"])
  write bytes
  reset "ambiguous"
  expectStore "rpc_transport_unknown_outcome" (scoped $ record "action")
  finished (begin<>["walletlock"])
  reset "ok"
  expectStore "credential_action_failure" (scoped $ record "action" >> reject "credential_action_failure")
  finished complete
  reset "ok"
  interrupted<-try (scoped $ record "action" >> throwIO UserInterrupt) :: IO (Either AsyncException ())
  check (interrupted==Left UserInterrupt)
  finished complete
  reset "lock-failure"
  before<-floor <$> getPOSIXTime
  expectStore "rpc_transport_unknown_outcome" (scoped $ record "action")
  readIORef methods >>= check . (==complete)
  after<-floor <$> getPOSIXTime
  readIORef expiry >>= check . (\n->n>=before+120 && n<=after+120)
  reset "ok"
  expectStore "native_wallet_not_ready" (Credentials.withNativeUnlock call native Nothing $ record "action")
  finished ["getwalletinfo"]
  reset "unencrypted"
  expectStore "native_unlock_requires_encrypted_wallet" (scoped $ record "action")
  finished ["getwalletinfo"]
  reset "unencrypted"
  Credentials.withNativeUnlock call native Nothing (record "action")
  finished ["getwalletinfo","action"]
  putStrLn "PASS: exact private unlock files, bounds/UTF-8/permissions/link refusal, finite unlock lease and cleanup after rejection, ambiguity, action failure and interruption"

-- Restore an offline schema-18 backup into a disposable database and apply any
-- missing baseline migrations through 005 before invoking this mode.
-- Never touch the original ledger or a signer. Optional recovery only reads chains.
migrationMain :: IO ()
migrationMain=do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  user<-getEnv "USER"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      check message ok=unless ok (fail message)
  bracket (PG.connect settings) PG.close $ \connection->do
    (before,attempts,postings)<-fixture connection ArchiveRecords
    history<-fixture connection LegacyMigrationRecords
    original<-case before of
      [row] | S.schemaVersion row==18 -> pure row
      _->fail "populated schema-18 baseline required"
    check "signed financial history required" (not(null attempts) && not(null postings))
    forM_ ["006.sql","007.sql","008.sql"] $ \name->do
      path<-getDataFileName ("migrations/"<>name)
      (code,_,diagnostic)<-Process.readProcessWithExitCode "psql"
        ["-X","-h","/tmp/ecx-pg-seam","-p","29436","-U",user,"-d",database,"-v","ON_ERROR_STOP=1","-f",path] ""
      check ("migration failed: "<>name<>"\n"<>diagnostic) (code==ExitSuccess)
    (after,savedAttempts,savedPostings)<-fixture connection ArchiveRecords
    savedHistory<-fixture connection LegacyMigrationRecords
    check "migration changed financial history" (attempts==savedAttempts && postings==savedPostings && history==savedHistory)
    check "migration changed identity, sequence or pause contract"
      (after==[original {S.schemaVersion=21,S.paused=1,S.pauseReason="payment_funding_migration"}])
    intents<-fixture connection MigratedIntents
    check "migration changed customer funding" (all (\row->Legacy.intentWithdrawal row==Nothing && Legacy.intentObligation row==Just(Legacy.intentId row)) intents)
    legacyRecords<-fixture connection MigrationLegacyPayments
    let legacy=map fst legacyRecords
    check "unfinished legacy payments require explicit cost-policy review" (all snd legacyRecords)
    withTestSigningKey $ \key->do
      archive<-fixture connection (ArchiveLegacy settings $ takeDirectory key)
      void $ evalSetup settings (MigratePaymentRoots (S.fingerprint original) 0 (manifestPath archive))
    withReader (settings {PG.connectUser=role}) (S.fingerprint original) False $ \reader->do
      state<-evalRead reader ReadState
      check "rebuild cannot read migrated sequence" (ledgerSequence state==S.criticalSequence original && ledgerPaused state)
      forM_ intents $ \row->if Legacy.intentId row `elem` legacy
        then expectStore "payment_funding_missing" (evalRead reader $ ReadPaymentWork $ Legacy.intentId row)
        else void $ evalRead reader (ReadPaymentWork $ Legacy.intentId row)
      pending<-evalRead reader PendingAttempts
      let expected=sort [S.attemptId attempt | attempt<-attempts,
            S.attemptState attempt `elem` ["signed","broadcast_intent"],
            any (\intent->Legacy.intentId intent==S.attemptIntent attempt && Legacy.intentResolved intent==0) intents]
      check "migration lost pending attempts" (pending==expected)
      forM_ pending $ \identifier->void $ evalRead reader (ReadAttempt identifier)
      void $ evalRead reader PaymentCandidates
      void $ evalRead reader ReadBalances
      putStrLn ("Pending migrated attempts: "<>show(length pending))
    putStrLn ("Read-only settled legacy payments without complete order cost policy: "<>show(length legacy))
    recovery<-lookupEnv "ECX_REBUILD_MIGRATION_RECOVERY_CONFIG"
    forM_ recovery $ migrationRecovery settings role (S.fingerprint original) connection
    putStrLn ("Populated migration PASS: "<>show(length attempts)<>" signed attempts; "<>show(length postings)<>" postings preserved; executable terms checked; settled legacy history retained")

-- Schema-21 histories use normal closed Store operations and existing offline
-- observation/freshness fixtures. Financial work uses no signer or chain RPC.
paymentRootsChild :: IO ()
paymentRootsChild=do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user<-getEnv "USER"
  manifest<-getEnv "ECX_REBUILD_PAYMENT_ROOTS_ARCHIVE"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
  void $ evalSetup settings (MigratePaymentRoots "contract" 0 manifest)

paymentRootsMain :: IO ()
paymentRootsMain=do
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  user<-getEnv "USER"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "payment-root migration contract failed\n"<>prettyCallStack callStack)
      header="Bearer "<>T.replicate 64 "0"
  bracket (PG.connect settings) PG.close $ \fixtures->do
    fixture fixtures (SetPause True)
    reviewed<-fixture fixtures (ReceiptPayment "root-source-review")
    unexplained<-fixture fixtures (ReceiptPayment "root-unexplained")
    -- A historical review flag must survive even when the payment is already
    -- settled; projection is not permission to discard unexplained old review.
    views<-fixture fixtures CustomerCompatibility
    reviewedOrder<-case [key | (key,"Paid",Just _)<-views] of
      key:_->pure key; _->fail "settled migration fixture missing"
    fixture fixtures (ReviewLegacyOrder reviewedOrder)
    -- An unexplained legacy review must refuse and roll back added columns as
    -- well as data. After restoring the fixture, the identical archive is usable.
    withTestSigningKey $ \key->do
      let directory=takeDirectory key
          migrate file minimumSequence=evalSetup settings (MigratePaymentRoots "contract" minimumSequence file)
      archive<-fixture fixtures (ArchiveLegacy settings directory)
      expectStore "ledger_profile_or_schema_mismatch" $
        withReader settings {PG.connectUser=role} "contract" True (const $ pure ())
      before<-fixture fixtures ArchiveRecords
      history<-fixture fixtures RootRetainedRecords
      ids<-fixture fixtures OldPaymentIds
      oldPayments<-fixture fixtures LegacyPaymentStates
      oldCandidates<-fixture fixtures LegacyCandidates
      oldViews<-fixture fixtures CustomerCompatibility
      hashes<-mapM (\identifier->(,) identifier <$> fixture fixtures (LegacyHash identifier)) ids
      fixture fixtures (SetArchiveSequence $ archiveSequence archive+1)
      expectStore "migration_snapshot_sequence_mismatch" (migrate (manifestPath archive) 0)
      fixture fixtures (SetArchiveSequence $ archiveSequence archive)
      bracket_ (fixture fixtures $ MigrationMalformedOrder True) (fixture fixtures $ MigrationMalformedOrder False) $
        expectStore "migration_corrupt_saved_record" (migrate (manifestPath archive) 0)
      let (_,savedAttempts,_)=before
      settled<-case [S.attemptId row | row<-savedAttempts,S.attemptState row=="settled"] of
        key:_->pure key; _->fail "settled migration fixture missing"
      -- A copy lets an ambiguous winner invalidate custody without resetting any
      -- monotonic revision in the retained baseline or suppressing its triggers.
      bracket (Backup.restoreLedger settings archive) Backup.discardRestore $ \target->
        bracket (PG.connect target) PG.close $ \connection->do
          fixture connection (MigrationLostWinner settled)
          corrupted<-fixture connection ArchiveRecords
          expectStore "migration_settlement_or_phase_ambiguous" $
            evalSetup target (MigratePaymentRoots "contract" 0 $ manifestPath archive)
          fixture connection ArchiveRecords >>= check . (==corrupted)
      fixture fixtures (MigrationReview unexplained True)
      expectStore "migration_execution_state_not_proven" (migrate (manifestPath archive) 0)
      fixture fixtures (MigrationReview unexplained False)
      fixture fixtures ArchiveRecords >>= check . (==before)
      fixture fixtures RootRetainedRecords >>= check . (==history)
      fixture fixtures MigratedIntents >>= check . all ((`elem` [0,1]).Legacy.intentResolved)
      expectStore "backup_identity_mismatch" (evalSetup settings $ MigratePaymentRoots "wrong" 0 (manifestPath archive))
      expectStore "backup_snapshot_too_old" (migrate (manifestPath archive) (archiveSequence archive+1))
      bracket (PG.connect settings) PG.close $ \holder->do
        fixture holder ClaimWorkerLock >>= check
        expectStore "worker_already_running" (migrate (manifestPath archive) 0)
      beforeActivation<-fixture fixtures ArchiveRecords
      -- Hold an orders read lock so activation blocks partway through staging.
      -- Wait for the actual PostgreSQL lock wait, then interrupt the migrator.
      bracket_ (PG.begin fixtures) (PG.rollback fixtures) $ do
        void $ fixture fixtures LegacyOrderSnapshot
        binary<-getExecutablePath
        environment<-getEnvironment
        let overrides=[("ECX_REBUILD_PAYMENT_ROOTS_ONLY","child"),("ECX_REBUILD_PAYMENT_ROOTS_ARCHIVE",manifestPath archive)]
        Process.withCreateProcess (Process.proc binary [])
          {Process.env=Just $ overrides<>filter ((`notElem` map fst overrides).fst) environment} $ \_ _ _ child->do
            ready<-timeout 10000000 $ awaitCondition "migration staging lock" $ do
              Process.getProcessExitCode child >>= \status->check (status==Nothing)
              bracket (PG.connect settings) PG.close (\c->fixture c $ WaitingRootMigration $ T.pack database)
            -- Kill before releasing the blocking lock, including on timeout;
            -- no child can race onward into a successful activation.
            pid<-Process.getPid child >>= maybe (fail "migration child missing") pure
            signalProcess sigKILL pid
            Process.waitForProcess child >>= check . (/=ExitSuccess)
            check (ready==Just ())
      fixture fixtures ArchiveRecords >>= check . (==beforeActivation)
      fixture fixtures RootRetainedRecords >>= check . (==history)
      -- Installing a real trigger failure exercises rollback after conversion
      -- and final DDL, not just input validation before the transaction.
      bracket_ (void $ PG.execute_ fixtures "CREATE FUNCTION ecx_contract_activation_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.schema_version=22 THEN RAISE EXCEPTION USING ERRCODE='53100', MESSAGE='contract activation failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER ecx_contract_activation_failure BEFORE UPDATE ON deployment FOR EACH ROW EXECUTE FUNCTION ecx_contract_activation_failure()")
        (void $ PG.execute_ fixtures "DROP TRIGGER ecx_contract_activation_failure ON deployment; DROP FUNCTION ecx_contract_activation_failure()") $ do
          failed<-try (migrate (manifestPath archive) 0) :: IO (Either PG.SqlError (Int64,Int))
          case failed of
            Left err | PG.sqlState err=="53100"->pure ()
            Left err->throwIO err
            Right _->fail "injected activation failure was bypassed"
      fixture fixtures ArchiveRecords >>= check . (==beforeActivation)
      fixture fixtures RootRetainedRecords >>= check . (==history)
      (sequenceNo,count)<-migrate (manifestPath archive) 0
      check (sequenceNo==archiveSequence archive && count==length oldPayments)
      (after,attempts,postings)<-fixture fixtures ArchiveRecords
      let (original,oldAttempts,oldPostings)=beforeActivation
      check (after==[row {S.schemaVersion=22,S.paused=1,S.pauseReason="payment_root_migration_requires_reconciliation"}|row<-original]
        && attempts==oldAttempts && postings==oldPostings)
      fixture fixtures RootRetainedRecords >>= check . (==history)
      states<-fixture fixtures RootPaymentStates
      check (states==oldPayments && (reviewed,"review") `elem` states)
      fixture fixtures RootCandidates >>= check . (==oldCandidates)
      roots<-fixture fixtures PaymentRoots
      check (length roots==count && all ((`elem` ["ready","active","settled","cancelled"]).S.rootPhase) roots)
      fixture fixtures RootConstraintFailures >>= check
      let compareReads database=withReader database {PG.connectUser=role} "contract" True $ \reader->do
            evalRead reader ReadState >>= check . ledgerPaused
            evalRead reader PaymentCandidates >>= check . (==oldCandidates)
            forM_ hashes $ \(identifier,hash)->evalRead reader (ReadSourceWorkHash identifier) >>= check . (==hash)
            forM_ oldPayments $ \(identifier,status)->do
              view<-evalRead reader (ReadPayment identifier)
              check (T.toLower (T.drop 7 $ T.pack $ show $ savedStatus view)==status)
            forM_ oldViews $ \(identifier,status,payout)->do
              view<-evalRead reader (ReadOrder header identifier)
              check ((W.status view,W.payoutTx view)==(status,payout))
      compareReads settings
      -- The ordinary restore operation upgrades only its new private database.
      -- It keeps exact money/work and deliberately invalidates custody readiness.
      converted<-fixture fixtures MigrationRecords
      bracket (evalRestore settings $ RestoreLedger (manifestPath archive) "contract" sequenceNo)
        (\(name,_)->Backup.discardRestore settings {PG.connectDatabase=T.unpack name}) $ \(name,n)->do
          check (n==sequenceNo && name/=T.pack database)
          let restored=settings {PG.connectDatabase=T.unpack name}
          bracket (PG.connect restored) PG.close $ \connection->do
            void $ PG.execute connection "GRANT CONNECT ON DATABASE ? TO ?" (Identifier name,Identifier $ T.pack role)
            forM_ ["GRANT USAGE ON SCHEMA public TO ?","GRANT SELECT ON ALL TABLES IN SCHEMA public TO ?",
              "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ?"] $ \sql->
                void $ PG.execute connection sql (PG.Only $ Identifier $ T.pack role)
            (deployment,savedAttempts,savedPostings)<-fixture connection ArchiveRecords
            check (deployment==[row {S.pauseReason="restored_requires_reconciliation"}|row<-after]
              && savedAttempts==attempts && savedPostings==postings)
            fixture connection MigrationRecords >>= check . (==converted)
            fixture connection PaymentRoots >>= check . (==roots)
            (checked,at,problem)<-fixture connection ReadCustodyCheck
            check (checked==Nothing && at==Nothing && problem==Just "restored_requires_reconciliation")
            compareReads restored
      fixture fixtures MigrationRecords >>= check . (==converted)
      putStrLn ("PASS: schema-22 closed Opaleye conversion and legacy restore; "<>show count<>" roots, "<>show(length attempts)<>" exact attempts and "<>show(length postings)<>" postings preserved; customer views, work hashes, restrictions, rollback and constraints verified")

-- Observation-only recovery of saved bytes on real public test networks. Never
-- start a signer, prepare a new payment, resume intake or broadcast from a copy.
migrationRecovery :: PG.ConnectInfo -> String -> T.Text -> PG.Connection -> FilePath -> IO ()
migrationRecovery settings role identity fixtures path=do
  config<-Config.loadConfig path
  unless (Config.profile config==W.L2LSignetDevnet && Config.fingerprint config==identity)
    (fail "migration recovery requires matching public-test identity")
  let temporary=do
        (directory,handle)<-openTempFile "/tmp" "ecx-migration-recovery"
        hClose handle; removeFile directory; PD.createDirectory directory 0o700
        pure directory
      check ok=unless ok (fail "migrated payment recovery contract failed")
  bracket temporary removeDirectoryRecursive $ \directory->do
    _<-evalRestore settings (AdoptLedger directory identity 0)
    withFencedWriter settings (Config.storePolicy config) directory $ \writer->
      withReader (settings {PG.connectUser=role}) identity (Config.backupRequired config) $ \reader->
        bracket newRpcManager closeManager $ \manager->do
          pending<-evalRead reader PendingAttempts
          original<-mapM (evalRead reader . ReadAttempt) pending
          (_,previousTime,_)<-fixture fixtures ReadCustodyCheck
          let newCustody previous=do
                (_,at,problem)<-fixture fixtures ReadCustodyCheck
                pure (at/=Nothing && at>previous && problem==Nothing)
          withWorkerProcess manager reader writer (Config.observerSettings config) (Config.solanaPolicy config)
            (Just $ CustomerSettings (Config.publicConfiguration config (Config.defaultInterface $ Config.profile config) False)
              (Config.storePolicy config) (Config.solanaSdkLibrary config))
            (SigningEndpoint 9443 (directory </> "no-signer")) $ \_ _->do
              awaitCondition "migrated custody reconciliation" (newCustody previousTime)
              recovered<-mapM (evalRead reader . ReadAttempt) pending
              check (map recordedSigned recovered==map recordedSigned original)
              first<-fixture fixtures ArchiveRecords
              (_,firstTime,_)<-fixture fixtures ReadCustodyCheck
              awaitCondition "second migrated recovery cycle" (newCustody firstTime)
              after<-fixture fixtures ArchiveRecords
              check (first==after)
              evalRead reader ReadState >>= check . ledgerPaused
              putStrLn "PASS: paused migrated runtime reconciles through real process startup; financial snapshot survives repeated recovery"

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
          withWorkerProcess manager reader writer (Config.observerSettings config) (Config.solanaPolicy config) (Just customer)
            (SigningEndpoint 1 "/unavailable-signer-credentials") $ \_ _->do
              let health=bracket (PG.connect settings) PG.close (\c->fixture c LiveScanHealth)
                  complete rows=map (\(chain,_,_)->chain) rows==["Native","Solana","SolanaOperating"]
                    && all (\(_,at,problem)->at/=Nothing && problem==Nothing) rows
              awaitCondition "first live observation cycle" (complete <$> health)
              first<-health
              balances<-evalRead reader ReadBalances
              awaitCondition "second live observation cycle" $ do
                current<-health
                pure (complete current && and (zipWith (\(chain,at,_) (oldChain,oldAt,_)->chain==oldChain && at>oldAt) current first))
              evalRead reader ReadBalances >>= check . (==balances)
              evalRead reader PendingAttempts >>= check . null
              evalRead reader ReadState >>= check . ledgerPaused
  putStrLn "PASS: real L2L Signet restricted RPC and Solana Devnet scans through the actual observation process, repeated accounting and paused ledger; no funds moved"

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
      run arguments=do
        let overrides=[("PGHOST","/tmp/ecx-pg-seam"),("PGPORT","29436"),("PGDATABASE",database),("PGUSER",user),("PGPASSWORD","")]
        (code,_,_)<-Process.readCreateProcessWithExitCode (Process.proc binary ("initialize-ledger":arguments))
          {Process.env=Just $ overrides<>filter (not . T.isPrefixOf "PG" . T.pack . fst) environment} ""
        check (code==ExitSuccess)
  if residue==Just "1" then bracket (PG.connect settings) PG.close $ \fixtures->do
    fixture fixtures SetupResidue
    expectStore "initialization_requires_empty_ledger" initialize
    (rows,attempts,postings)<-fixture fixtures ArchiveRecords
    check (null rows && null attempts && null postings)
   else do
    expectStore "invalid_deployment_identity" (evalSetup settings $ InitializeLedger "invalid")
    run [configPath]
    withReader settings {PG.connectUser=role} identity True $ \reader->do
      before<-evalRead reader ReadState
      check (before==LedgerState 0 0 True "installation_requires_reconciliation")
      evalRead reader ReadBalances >>= check . M.null
      evalRead reader PendingAttempts >>= check . null
      expectStore "intake_paused" (evalRead reader $ CheckIntake 100)
      run ["--fingerprint",T.unpack identity]
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
  encrypted<-(==Just "1") <$> lookupEnv "ECX_REBUILD_ENCRYPTED_NATIVE_ONLY"
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
        locked wallet=when encrypted $ call wallet True "getwalletinfo" []
          >>= fieldValue "unlocked_until" >>= check . (==(0::Int64))
    _<-N.nativeIdentity manager source
    bracket_ (void $ call source False "createwallet" [toJSON sourceName,Bool False,Bool False,String "",Bool False,Bool True,Bool False])
      (cleanup sourceName) $
      bracket (do (path,h)<-openTempFile "/tmp" "ecx-native-recovery"; hClose h; removeFile path; PD.createDirectory path 0o700; pure path)
        removeDirectoryRecursive $ \directory->do
        address<-allocate "recovery-label" "bech32"
        legacy<-allocate "recovery-signing-proof" "legacy"
        let unlock=directory </> "native-unlock"
            sourceConfig=base {Config.nativeWallet=sourceName,Config.nativeCookie=cookie,
              Config.nativeUnlockFile=if encrypted then Just unlock else Nothing}
            targetConfig=sourceConfig {Config.nativeWallet=targetName}
            sourceFile=directory </> "source.json"
            targetFile=directory </> "target.json"
            moved=directory </> "moved"
            runCommand command config file=do
              (code,out,_)<-Process.readProcessWithExitCode binary [command,config,file] ""
              check (code==ExitSuccess)
              either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack out)
        when encrypted $ do
          -- This wallet was created immediately above under a random name. Do
          -- not encrypt an existing wallet, even if a test environment is wrong.
          balances<-call source True "getbalances" [] >>= fieldValue "mine"
          forM_ ["trusted","untrusted_pending","immature"] $ \name->
            fieldValue name balances >>= check . (==Number 0)
          let secret=" disposable native recovery café passphrase "
          BS.writeFile unlock (TE.encodeUtf8 secret)
          setFileMode unlock 0o600
          void $ call source True "encryptwallet" [String secret]
          locked source
          Credentials.withNativeUnlock (call source) source (Just unlock) $
            void $ call source True "keypoolrefill" [Number 100]
          locked source
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
        locked source
        -- This uses only the encrypted wallet's cached descriptor keypool.
        expectedNext<-allocate "next-label" "bech32"
        void $ call source False "unloadwallet" [toJSON sourceName,Bool False]
        bracket_ (pure ()) (cleanup targetName) $ do
          result<-runCommand "restore-native-wallet" targetFile nativeManifest
          fieldValue "wallet" result >>= check . (==targetName)
          recovered<-N.recoverNativeAddressWith (call target) target False "recovery-label"
          check (recovered==address)
          locked target
          next<-call target True "getnewaddress" [String "next-label",String "bech32"]
          check (next==String expectedNext)
          let restoredUnlock=if encrypted then Just (takeDirectory nativeManifest </> "native-unlock") else Nothing
          signature<-Credentials.withNativeUnlock (call target) target restoredUnlock $
            call target True "signmessage" [String legacy,String "ECX empty-wallet recovery acceptance"]
          locked target
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
      native=Config.nativeSettings config
      call=N.nativeCall manager native
      locked=call True "getwalletinfo" [] >>= fieldValue "unlocked_until" >>= check . (==(0::Int64))
  Config.validateConfig config
  BL.writeFile file (encode config)
  BL.writeFile offlineFile (encode config {Config.nativeRpc="http://127.0.0.1:1",Config.nativeCookie="/unavailable-cookie"})
  bracket (PG.connect settings) PG.close $ \fixtures->do
    fixture fixtures (InitializeIdentity identity)
    Fence.initializeFence (Config.fenceDirectory config) identity 0
    beforeFiles<-listDirectory directory
    forM_ (Config.nativeUnlockFile config) $ \unlock->do
      locked
      let missing=evalCustodyRecovery manager config {Config.nativeUnlockFile=Nothing}
            (ExportCustody settings readerSettings key directory)
      expectStore "encrypted_native_wallet_recovery_material_required" missing
      Credentials.withNativeUnlock call native (Just unlock) $
        expectStore "encrypted_native_wallet_recovery_material_required" missing
      locked
      saved<-BS.readFile unlock
      (BS.writeFile unlock "wrong-passphrase" >> expectStore "rpc_error_-14" export)
        `finally` BS.writeFile unlock saved
      locked
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
    archive<-evalRestore settings (InspectCustodyFiles manifest identity 0)
    metadata<-BS.readFile manifest >>= either fail pure . eitherDecodeStrict'
    let encrypted=case Config.nativeUnlockFile config of Just _->True; Nothing->False
    check (custodyEncrypted archive==encrypted && M.member "native-unlock" (custodyFiles archive)==encrypted)
    fieldValue "format" metadata >>= check . (==(if encrypted then 2 else 1::Int))
    forM_ (Config.nativeUnlockFile config) $ \unlock->do
      expected<-Credentials.readNativeUnlock unlock
      Credentials.readNativeUnlock (relocated </> "native-unlock") >>= check . (==expected)
      locked
      removeFile unlock
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
      when encrypted $ do
        let unlock=relocated </> "native-unlock"
        savedUnlock<-BS.readFile unlock
        BS.appendFile unlock "changed"
        expectStore "custody_backup_hash_mismatch" (inspect $ InspectCustody manifest 0)
        BS.writeFile unlock savedUnlock
        setFileMode unlock 0o644
        expectStore "unsafe_custody_backup_file" (inspect $ InspectCustody manifest 0)
        setFileMode unlock 0o600
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
    putStrLn "PASS: exclusive custody export, bound recovery files, relocated offline inspection without original credentials/DB/RPC, integrity/minimum/identity/permissions refusal, exact journal restore and unchanged source ledger"
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
  -- No plaintext bundle remains. Restore the complete file set from real restic.
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
  putStrLn "PASS: real restic full-custody encryption/download after plaintext removal, private recovery files, ledger-only/latest/stale/identity/password refusal, production HTTPS restriction and independent CLI inspection"
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

-- Actual HTTP handlers and PostgreSQL lock waits exercise the private cache.
-- No evaluator is exported and no fake report function replaces database IO.
reportCacheMain :: IO ()
reportCacheMain=do
  hSetBuffering stdout LineBuffering
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user<-getEnv "USER"; role<-getEnv "ECX_REBUILD_CONTRACT_READER"
  let settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      terms=PaymentTerms (PolicySnapshot 2 "finalized" "contract") (CostLimits (money 10) (money 10) (money 10))
      limits=OrderLimits (money 2) (money 1000) 100 100 100 (money 100000) (money 100000)
      store=StorePolicy terms limits "contract" True
      key=T.replicate 32 "1"
      native=N.NativeSettings W.L2LSignetDevnet "http://127.0.0.1:29432" "/unused" "workflow" 1 (T.replicate 64 "0")
      chain=ObserverSettings native (Solana.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing key key key) 2 "sol-origin" "opening-signature"
      policy=H.SolanaPolicy "contract" "contract" key key key (money 10) (money 10)
      public=W.PublicConfiguration W.L2LSignetDevnet "devnet" (W.InterfaceConfig Nothing Nothing Nothing Nothing Nothing)
        "contract" key key 8 (money 2) (money 1000) (M.fromList [("NativeToWrapped",100),("WrappedToNative",100)]) False False (W.Availability False "starting") Nothing
      check message ok=unless ok (fail message)
  bracket (PG.connect settings) PG.close $ \fixtures->do
    fixture fixtures Initialize
    fixture fixtures SeedIntake
    withReader settings {PG.connectUser=role} "contract" True $ \reader->
      withWriter settings store (const $ pure ()) $ \writer->
      bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> reject "offline_process_rpc"}) closeManager $ \manager->
      withWorkerProcess manager reader writer chain policy (Just $ CustomerSettings public store "/unused/sdk") (SigningEndpoint 9443 "/unused/auth") $ \port _->
      bracket (newManager defaultManagerSettings {HTTP.managerConnCount=16}) closeManager $ \client->
      bracket (PG.connect settings) PG.close $ \lock->do
        let request=do
              wire<-HTTP.parseRequest ("http://127.0.0.1:"<>show port<>"/api/v1/config")
              response<-HTTP.httpLbs wire {HTTP.responseTimeout=HTTP.responseTimeoutMicro 10000000} client
              check "optional report failure broke config" (statusCode(HTTP.responseStatus response)==200)
              either fail pure (eitherDecodeStrict' $ BL.toStrict $ HTTP.responseBody response) :: IO W.PublicConfiguration
            batch=mapConcurrently (const request) [1..8::Int]
            lockReport=PG.begin lock >> void(PG.execute_ lock "LOCK TABLE custody_check IN ACCESS EXCLUSIVE MODE")
            noWaiters=do
              let cleared=fixture fixtures (ReportWaiters $ T.pack role) >>= \n->unless (null n) (threadDelay 50000 >> cleared)
              finished<-timeout 2000000 cleared
              when (finished/=Just ()) $ fixture fixtures (ReportWaiters $ T.pack role) >>= print
              check "report backend still blocked two seconds after cancellation" (finished==Just ())
        before<-evalRead reader ReadState
        currentTime<-floor <$> getPOSIXTime
        initialReport<-evalRead reader (ReadPublicReport currentTime)
        check "fresh empty ledger must report zero completed transfers"
          (W.reportWraps24h initialReport==0 && W.reportUnwraps24h initialReport==0 && W.reportUndatedTransfers initialReport==0
            && all ((=="0").W.reportFees) (W.reportAssets initialReport))
        putStrLn "cache test: direct empty-ledger report succeeded"
        putStrLn "cache test: locking report"
        lockReport
        started<-getMonotonicTimeNSec
        failed<-withAsync batch $ \pending->do
          let waiting=fixture fixtures (ReportWaiters $ T.pack role) >>= \n->when (length n/=1) (threadDelay 50000 >> waiting)
          ready<-timeout 3000000 waiting
          check "one coalesced PostgreSQL refresh not observed" (ready==Just ())
          threadDelay 200000
          fixture fixtures (ReportWaiters $ T.pack role) >>= check "concurrent refreshes were not coalesced" . (==1) . length
          timeout 8000000 (wait pending) >>= maybe (fail "report timeout/cleanup exceeded bound") pure
        elapsed<-(\end->end-started) <$> getMonotonicTimeNSec
        check "failed refresh should return missing reports" (all ((==Nothing).W.pubReport) failed && elapsed<8000000000)
        putStrLn "cache test: timeout returned"
        noWaiters
        putStrLn "cache test: backend cleared"
        cached<-timeout 1000000 batch >>= maybe (fail "failed cache refreshed again") pure
        check "failure cache changed response" (all ((==Nothing).W.pubReport) cached)
        noWaiters
        PG.rollback lock
        -- Expiry is real monotonic time: no test hook or altered production TTL.
        putStrLn "cache test: waiting real TTL"
        threadDelay 31000000
        putStrLn "cache test: refreshing after expiry"
        recovered<-request
        report<-maybe (fail "cache did not recover after timed-out refresh") pure (W.pubReport recovered)
        lockReport
        success<-timeout 1000000 batch >>= maybe (fail "successful cache queried locked database") pure
        check "successful cache changed report" (all ((==Just report).W.pubReport) success)
        noWaiters
        PG.rollback lock
        evalRead reader ReadState >>= check "public cache changed ledger state" . (==before)
        putStrLn "PASS real HTTP report cache: concurrent timeout coalesced, backend canceled, failure cached, TTL recovery, successful cache, unchanged ledger"

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
      -- This is the same SELECT-only privilege boundary used by safe evaluation
      -- and signing. An actual data write must fail, not merely pass a role audit.
      unchanged<-evalRead reader ReadState
      denied<-try (bracket (PG.connect readerSettings) PG.close $ \connection->fixture connection $ SetPause False)
        :: IO (Either PG.SqlError ())
      check (case denied of Left failure->PG.sqlState failure=="42501"; _->False)
      evalRead reader ReadState >>= check . (==unchanged)
      withWriter settings (store policy limits) (const $ pure ()) $ \writer -> do
        expectStore "worker_already_running" (withWriter settings (store policy limits) (const $ pure ()) $ const $ pure ())
        evalRead reader ReadNativeLockWork >>= check . (==Nothing)
        evalRead reader PendingAttempts >>= check . null
        evalRead reader PaymentCandidates >>= check . null
        initial <- evalRead reader ReadBalances
        PG.begin fixtures
        fixture fixtures LockDeployment
        first <- withAsync (evalWrite writer reserve) $ \pending->do
          blocked<-timeout 200000 (wait pending)
          check (blocked==Nothing)
          PG.commit fixtures
          timeout 2000000 (wait pending) >>= maybe (fail "deployment lock not released") pure
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
      -- Interrupt after the financial body but before commit. Rollback must
      -- retain the old state and permanently fence this writer connection.
      interruptedBefore<-evalRead reader ReadBalances
      interruptSequence<-ledgerSequence <$> evalRead reader ReadState
      reached<-newEmptyMVar; hold<-newEmptyMVar
      withWriter settings (store policy limits) (\n->when (n>interruptSequence) (putMVar reached () >> takeMVar hold)) $ \writer->do
        withAsync (evalWrite writer $ ReserveFees 100 (T.replicate 64 "c") Native (money 100) "recipient" "interrupted transaction") $ \pending->do
          timeout 2000000 (takeMVar reached) >>= check . (==Just ())
          cancel pending
        expectStore "ledger_connection_fenced" (evalWrite writer $ Pause "interrupted writer")
      evalRead reader ReadBalances >>= check . (==interruptedBefore)
      -- Fixed DDL injects a genuine deferred PostgreSQL commit failure.
      -- It is test infrastructure, not an application SQL/row-access escape.
      bracket_ (void $ PG.execute_ fixtures "CREATE FUNCTION ecx_contract_commit_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='53100', MESSAGE='contract capacity failure'; END $$; CREATE CONSTRAINT TRIGGER ecx_contract_commit_failure AFTER INSERT ON fee_withdrawals DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ecx_contract_commit_failure()")
        (void $ PG.execute_ fixtures "DROP TRIGGER ecx_contract_commit_failure ON fee_withdrawals; DROP FUNCTION ecx_contract_commit_failure()") $ do
          bodyFinished<-newIORef False
          unchanged<-evalRead reader ReadBalances
          previous<-evalRead reader ReadState
          withWriter settings (store policy limits) (\n->when (n>ledgerSequence previous) (writeIORef bodyFinished True)) $ \writer->do
            failed<-try (evalWrite writer $ ReserveFees 100 (T.replicate 64 "c") Native (money 100) "recipient" "deferred failure") :: IO (Either PG.SqlError WithdrawalView)
            check (case failed of Left problem->PG.sqlState problem=="53100"; _->False)
            readIORef bodyFinished >>= check
            expectStore "ledger_connection_fenced" (evalWrite writer $ Pause "commit failed")
          evalRead reader ReadBalances >>= check . (==unchanged)
          evalRead reader ReadState >>= check . (==ledgerSequence previous) . ledgerSequence
          evalRead reader (ReadWithdrawal $ T.replicate 64 "c") >>= check . (==Nothing)
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
      custodyContract settings (store policy limits) fixtures reader
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
        forM_ [("custody_native_history_advanced",["Native"]),("custody_solana_history_advanced",["Solana","SolanaOperating"])] $ \(code,affected)->do
          before<-evalRead reader ReadCustodyRevision
          evalWrite writer (RecordCustody before 100 (Just code) Nothing)
          evalRead reader ReadState >>= check . not . ledgerPaused
          invalidated<-fixture fixtures ReadCustodyCheck
          check (invalidated==(Nothing,Just 100,Just code))
          -- Discovery of newer history must choose a rescan immediately, even
          -- when the previous scan is less than sixty seconds old.
          expectStore "scanners_not_fresh" (evalRead reader $ CheckIntake 100)
          invalidatedRevision<-evalRead reader ReadCustodyRevision
          evalWrite writer (RecordCustody invalidatedRevision 100 Nothing good)
          expectStore "scanners_not_fresh" (evalRead reader $ CheckIntake 100)
          forM_ origins $ \(chain,origin)->do
            (success,problem,_)<-fixture fixtures (ReadScanHealth chain)
            check (success==Just 100 && problem==if chain `elem` affected then Just code else Nothing)
            when (chain `elem` affected) $ do
              cursor<-evalRead reader (ReadCheckpoint chain) >>= maybe (fail "missing scan cursor") pure
              evalWrite writer (CommitScan $ W.ScanBatch chain origin (Just cursor) cursor 100 [] [])
          expectStore "custody_not_reconciled" (evalRead reader $ CheckIntake 100)
          current<-evalRead reader ReadCustodyRevision
          evalWrite writer (RecordCustody current 100 Nothing good)
          evalRead reader (CheckIntake 100)
        revision<-evalRead reader ReadCustodyRevision
        forM_ ["custody_history_not_current","custody_native_history_changed"] $ \code->do
          fixture fixtures ReadyIntake
          evalWrite writer (RecordCustody revision 100 (Just code) Nothing)
          evalRead reader ReadState >>= check . ledgerPaused
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
        PG.begin fixtures
        fixture fixtures LockDeployment
        (identifier,replay)<-withAsync (evalWrite writer $ create newRequest) $ \first->
          withAsync (evalWrite writer $ create newRequest) $ \second->do
            timeout 200000 (wait first) >>= check . (==Nothing)
            timeout 200000 (wait second) >>= check . (==Nothing)
            PG.commit fixtures
            result<-timeout 3000000 ((,) <$> wait first <*> wait second)
            maybe (fail "same-order requests stayed blocked") pure result
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
          evalWrite writer (ExpireQuotes 301)
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
        -- More confirmations change the observation revision, not customer value.
        source<-evalRead reader (ReadSource "historical-fee")
        revisionBefore<-evalRead reader ReadCustodyRevision
        stateBefore<-evalRead reader ReadState
        balancesBefore<-evalRead reader ReadBalances
        evalWrite writer (RefreshPaymentSource source source {W.depositConfirmations=W.depositConfirmations source+1})
        evalRead reader ReadCustodyRevision >>= check . (>revisionBefore)
        evalRead reader ReadState >>= check . (==stateBefore)
        evalRead reader ReadBalances >>= check . (==balancesBefore)
        expectStore "custody_not_reconciled" (evalWrite writer $ PreparePayment 100 intent (money 10) "{}")
        evalRead reader (ReadPaymentWork intent) >>= check . (==(readyWork,Nothing,[]))
        fixture fixtures RefreshCustody
        fixture fixtures (ReviewAdmission historical)
        evalRead reader (ReadOrder auth historical) >>= check . (=="NeedsReview") . W.status
        prepared<-evalWrite writer (PreparePayment 100 intent (money 10) "{}")
        evalRead reader (ReadOrder auth historical) >>= check . (=="Preparing") . W.status
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
              "/unused/sdk" "/unused/key" Nothing Nothing
        bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> fail "unauthorized signer reached network"}) closeManager $ \manager -> do
          withTestSigningKey $ \keyFile->do
            endpoint<-signingEndpoint (takeDirectory keyFile)
            withProcessListening (runProcess manager reader $ SignerProcess signing {signingKey=keyFile} endpoint)
              (signerPort endpoint) $ withSigningClient endpoint $ \client->do
                let refused :: ToJSON a => T.Text -> String -> a -> IO ()
                    refused code path body=do
                      response<-signerPost client endpoint path body
                      check (statusCode (HTTP.responseStatus response)==409 &&
                        eitherDecodeStrict' (BL.toStrict $ HTTP.responseBody response)==Right (object ["error" .= code]))
                refused "custody_checkpoint_not_configured" "/checkpoint-custody" ("contract"::T.Text,0::Int64)
                refused "invalid_custody_checkpoint" "/checkpoint-custody" ("other"::T.Text,0::Int64)
                refused "invalid_custody_checkpoint" "/checkpoint-custody" ("contract"::T.Text,-1::Int64)
                refused "signer_profile_mismatch" "/draft-replacement" ("other"::T.Text,"missing"::T.Text,money 2)
                refused "signer_profile_mismatch" "/sign-replacement" ("other"::T.Text,1::Int64)
                refused "signer_profile_mismatch" "/sign-preparation" ("other"::T.Text,intent,0::Int)
                refused "invalid_signing_decision" "/sign-preparation" ("contract"::T.Text,intent,8::Int)
                refused "signing_backup_required" "/sign-preparation" ("contract"::T.Text,intent,0::Int)
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
        fixture fixtures (ReviewAdmission historical)
        evalRead reader (ReadOrder auth historical) >>= check . (=="NeedsReview") . W.status
        beforeSignature<-evalRead reader ReadBalances
        recorded<-evalWrite writer (RecordAttempt decision signed)
        evalRead reader (ReadOrder auth historical) >>= check . (=="Paying") . W.status
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
        evalRead reader ReadBalances >>= check . (==afterSettlement)
        fixture fixtures (SeedReceipt "unknown-source" Nothing Native 10 2 True 100)
        evalWrite writer (PromoteDeposit 100 "unknown-source") >>= check . not
        expectStore "deposit_not_found" (evalWrite writer $ PromoteDeposit 100 "missing")
        expectStore "invalid_promotion_time" (evalWrite writer $ PromoteDeposit (-1) "promote-source")
        pure ("promote-source",missing)
      paymentAtomicityContract fixtures settings reader (store policy limits)
      customerProjectionContract fixtures reader
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
        orderedRefundContract fixtures reader writer
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
               toJSON attemptRows,toJSON ([]::[Value]),toJSON [("Native"::T.Text,1::Int64,False)]]
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
        -- Unavailable-chain startup and its retained balances are exercised by
        -- serverMain through the actual executable, HTTP and operator transport.
      customerProjectionContract fixtures reader
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

-- Actual database failures and interleavings for the extracted payment slice.
-- The fixture connection has no application MVar: its deployment lock must block
-- the writer before it reads facts. All data mutation still uses closed Opaleye.
paymentAtomicityContract :: PG.Connection -> PG.ConnectInfo -> Reader -> StorePolicy -> IO ()
paymentAtomicityContract fixtures settings reader policy = do
  let key=digest "payment atomicity contract"; identifier="fee:"<>key
      txid=digest "payment atomicity transaction"
      check ok=unless ok (fail "payment atomicity/interleaving contract failed")
      snapshot=(,) <$> fixture fixtures MigrationRecords <*> fixture fixtures ArchiveRecords
      write :: (Writer -> IO a) -> IO a
      write action=withWriter settings policy (const $ pure ()) action
      fault :: PG.Query -> StoreWrite a -> Bool -> Bool -> IO ()
      fault trigger operation deferred paused = bracket_
        (void $ PG.execute_ fixtures ("CREATE FUNCTION ecx_contract_payment_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='injected payment constraint'; END $$; "<>trigger))
        (void $ PG.execute_ fixtures "DROP FUNCTION ecx_contract_payment_failure() CASCADE") $ do
          checkpoint<-newIORef False
          withWriter settings policy (\_->writeIORef checkpoint True) $ \writer->do
            fixture fixtures ReadyIntake
            when paused (fixture fixtures $ SetPause True)
            before<-snapshot
            writeIORef checkpoint False
            result<-try (void $ evalWrite writer operation) :: IO (Either PG.SqlError ())
            check (case result of Left failure->PG.sqlState failure=="23514"; _->False)
            readIORef checkpoint >>= check . (==deferred)
            snapshot >>= check . (==before)
            expectStore "ledger_connection_fenced" (evalWrite writer $ Pause "failed payment must fence")
      whileLocked action change = do
        started<-newEmptyMVar
        Tx.beginMode (Tx.TransactionMode Tx.ReadCommitted Tx.ReadWrite) fixtures
        (do
          fixture fixtures LockDeployment
          withAsync (putMVar started () >> action) $ \pending->do
            timeout 2000000 (takeMVar started) >>= check . (==Just ())
            timeout 200000 (wait pending) >>= check . (==Nothing)
            change
            PG.commit fixtures
            timeout 3000000 (wait pending) >>= maybe (fail "payment stayed blocked after database commit") pure)
          `onException` PG.rollback fixtures
      reserve writer k=fixture fixtures RefreshCustody >>
        evalWrite writer (ReserveFees 100 k Native (money 10) "atomicity-recipient" "payment transaction contract")
  customer<-write $ \writer->do
    fixture fixtures ReadyIntake
    let header="Bearer "<>T.replicate 64 "0"
    oid<-evalWrite writer (CreateOrder 100 header $ W.OrderRequest NativeToWrapped (money 10) "recipient" "refund" Nothing "customer-atomicity")
    claim<-evalWrite writer (ClaimNative 100 header oid)
    void $ evalWrite writer (RecordNative header oid (allocationLabel claim) "atomicity-native-address")
    fixture fixtures (SeedReceipt "atomicity-source" (Just oid) Native 10 2 True 100)
    pure oid
  fault "CREATE TRIGGER ecx_contract_payment_failure BEFORE UPDATE ON operating_reservations FOR EACH ROW WHEN (NEW.phase='obligation') EXECUTE FUNCTION ecx_contract_payment_failure()"
    (PromoteDeposit 100 "atomicity-source") False False
  write $ \writer->evalWrite writer (PromoteDeposit 100 "atomicity-source") >>= check
  fault "CREATE TRIGGER ecx_contract_payment_failure BEFORE INSERT ON obligations FOR EACH ROW WHEN (NEW.kind='refund') EXECUTE FUNCTION ecx_contract_payment_failure()"
    (AuthorizeRefund 100 "atomicity-source") False True
  write $ \writer->do
    fixture fixtures RefreshCustody
    void $ evalWrite writer (AuthorizeRefund 100 "atomicity-source")
    evalRead reader (ReadPayment $ "convert:"<>customer) >>= check . (==PaymentCancelled) . savedStatus
  write $ \writer->void $ reserve writer key
  fault "CREATE TRIGGER ecx_contract_payment_failure BEFORE INSERT ON preparations FOR EACH ROW EXECUTE FUNCTION ecx_contract_payment_failure()"
    (PreparePayment 100 identifier (money 5) "{}") False False
  write $ \writer->do
    fixture fixtures ReadyIntake
    _<-evalWrite writer (PreparePayment 100 identifier (money 5) "{}")
    evalWrite writer (SaveDraft identifier 0 "{}")
    prepared<-evalRead reader (ReadPreparation identifier)
    fixture fixtures CoverBackup
    fixture fixtures ReadyIntake
    void $ evalWrite writer (RecordAttempt prepared $ SignedAttempt txid "atomicity-fixture-bytes" "{}" (Just "atomicity-prevout:0"))
  fault "CREATE CONSTRAINT TRIGGER ecx_contract_payment_failure AFTER UPDATE ON attempts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ecx_contract_payment_failure()"
    (MarkBroadcast 100 txid) True False
  queued<-write $ \writer->do
    fixture fixtures ReadyIntake
    _<-evalWrite writer (MarkBroadcast 100 txid)
    fixture fixtures CoverBackup
    fixture fixtures ReadyIntake
    evalWrite writer (AuthorizeSend 100 txid)
  let settle=SettlePayment queued (W.PaymentCosts (money 3) (money 0)) "{\"offline\":true}"
  fault "CREATE TRIGGER ecx_contract_payment_failure BEFORE UPDATE ON intents FOR EACH ROW EXECUTE FUNCTION ecx_contract_payment_failure()" settle False False
  write $ \writer->do
    -- Recovery may pause intake while a finalized outcome is arriving. Waiting
    -- for its database commit must retain the economic outcome and exact replay.
    whileLocked (evalWrite writer settle) (fixture fixtures $ SetPause True)
    settled<-snapshot
    evalWrite writer settle
    snapshot >>= check . (==settled)
  let competitor=digest "payment operating race"; competing="fee:"<>competitor
  write $ \writer->do
    void $ reserve writer competitor
    fixture fixtures ReadyIntake
    -- Another connection consumes the available operating capital while holding
    -- the deployment row. The waiting preparation must load the committed budget.
    whileLocked (expectStore "insufficient_fee_budget" $ evalWrite writer $ PreparePayment 100 competing (money 5) "{}")
      (fixture fixtures $ OperatingBudgetRace True)
    evalRead reader (ReadPaymentWork competing) >>= \(view,prepared,attempts)->
      check (savedStatus view==PaymentReady && prepared==Nothing && null attempts)
    fixture fixtures (OperatingBudgetRace False)
    evalWrite writer (Pause "cancel race fixture")
    void $ evalWrite writer (CancelFees competitor "race fixture complete")
  putStrLn "PASS: promotion/refund/preparation/settlement rollback, queue commit failure and fencing, independent-connection budget/recovery interleavings and exact settled replay"

customerProjectionContract :: PG.Connection -> Reader -> IO ()
customerProjectionContract fixtures reader = do
  fixture fixtures CoverBackup
  before<-fixture fixtures MigrationRecords
  expected<-fixture fixtures CurrentCustomerOrders
  forM_ expected $ \identifier->void $ evalRead reader (ReadOrder ("Bearer "<>T.replicate 64 "0") identifier)
  after<-fixture fixtures MigrationRecords
  unless (length expected>=10 && before==after) (fail "customer projection must be read-only and cover retained histories")
  putStrLn ("PASS: "<>show(length expected)<>" customer projections read successfully without changing financial records")

-- Fixture operations are closed and use Opaleye. They exist only in this test
-- component; no arbitrary SQL or connection callback is available to handlers.
data Fixture a where
  ReportWaiters :: T.Text -> Fixture [T.Text]
  ArchiveLegacy :: PG.ConnectInfo -> FilePath -> Fixture LedgerArchive
  ReceiptPayment :: T.Text -> Fixture T.Text
  LegacyPaymentStates :: Fixture [(T.Text,T.Text)]
  LegacyCandidates :: Fixture [T.Text]
  LegacyHash :: T.Text -> Fixture T.Text
  LegacyOrderSnapshot :: Fixture [T.Text]
  LegacyMigrationRecords :: Fixture [String]
  RootRetainedRecords :: Fixture [String]
  PaymentHistoryRecords :: Fixture [String]
  ClaimWorkerLock :: Fixture Bool
  OldPaymentIds :: Fixture [T.Text]
  PaymentRoots :: Fixture [S.PaymentRoot]
  RootPaymentStates :: Fixture [(T.Text,T.Text)]
  RootCandidates :: Fixture [T.Text]
  WaitingRootMigration :: T.Text -> Fixture Bool
  MigrationReview :: T.Text -> Bool -> Fixture ()
  MigrationMalformedOrder :: Bool -> Fixture ()
  MigrationLostWinner :: T.Text -> Fixture ()
  ReviewLegacyOrder :: T.Text -> Fixture ()
  ReviewAdmission :: T.Text -> Fixture ()
  RootConstraintFailures :: Fixture Bool
  CurrentCustomerOrders :: Fixture [T.Text]
  CustomerCompatibility :: Fixture [(T.Text,T.Text,Maybe T.Text)]
  LiveScanHealth :: Fixture [(T.Text,Maybe Int64,Maybe T.Text)]
  NativeRecoveryEvidence :: Fixture [(T.Text,T.Text,T.Text,T.Text,Int64)]
  SetupResidue :: Fixture ()
  SetPause :: Bool -> Fixture ()
  RestoreDatabases :: Fixture [T.Text]
  MigrationRecords :: Fixture [String]
  MigratedIntents :: Fixture [Legacy.Intent]
  MigrationLegacyPayments :: Fixture [(T.Text,Bool)]
  ExportArchiveSnapshot :: Fixture T.Text
  SetArchiveSequence :: Int64 -> Fixture ()
  ArchiveRecords :: Fixture ([S.Deployment],[S.Attempt],[(Int64,T.Text,T.Text,T.Text,Int64)])
  SourceRecipient :: T.Text -> T.Text -> Fixture ()
  SourceAnchor :: T.Text -> T.Text -> Fixture ()
  TLSFunds :: Fixture ()
  FreshAt :: Int64 -> Fixture ()
  ChangeTreasuryAnchor :: T.Text -> T.Text -> Fixture ()
  SeedTreasuryEvidence :: T.Text -> T.Text -> T.Text -> T.Text -> Int64 -> Value -> Fixture ()
  LockDeployment :: Fixture ()
  OperatingBudgetRace :: Bool -> Fixture ()
  RecoveryPauseCount :: Fixture Int
  LockRestoreAudits :: Fixture [T.Text]
  OrderWorkflowFunds :: Fixture ()
  CustodyHeadReview :: Int64 -> Fixture ()
  ReactivatePayment :: T.Text -> Fixture ()
  SeedCustodyHeads :: Fixture ()
  ReadCustodyCheck :: Fixture (Maybe Int64,Maybe Int64,Maybe T.Text)
  ImmutableAttempt :: T.Text -> Fixture Bool
  CheckFundingBinding :: T.Text -> T.Text -> Fixture Bool
  ResetOperatingScan :: Fixture ()
  LatestSourceState :: T.Text -> Fixture T.Text
  SourceHistory :: T.Text -> Fixture [(T.Text,Int64,T.Text,Int64)]
  PaymentAttemptHistory :: T.Text -> Fixture [T.Text]
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
fixture c (ReportWaiters role) = O.runSelect c $ do
    (user,event,query)<-O.selectTable $ O.tableWithSchema "pg_catalog" "pg_stat_activity" $ p3
      (O.requiredTableField "usename",O.requiredTableField "wait_event_type",O.requiredTableField "query")
    O.where_ (user O..== O.sqlStrictText role
      O..&& O.matchNullable (O.sqlBool False) (O..== O.sqlStrictText "Lock") event)
    pure query
    :: IO [T.Text]
fixture c (LegacyHash intent) = do
  let includeReplacements=True
  obligations <- O.runSelect c $ do
    r <- O.selectTable S.obligations
    O.where_ (S.obligationId r O..== O.sqlStrictText intent)
    pure (S.obligationId r,S.obligationOrder r,S.obligationDeposit r,S.obligationKind r,S.obligationAsset r,S.obligationAmount r,S.obligationRecipient r)
    :: IO [(T.Text,T.Text,T.Text,T.Text,T.Text,Int64,T.Text)]
  work <- O.runSelect c $ do
    row <- O.selectTable Legacy.intents
    let key=Legacy.intentId row; chain=Legacy.intentChain row; resolved=Legacy.intentResolved row; common=Legacy.intentCommon row
    O.where_ (key O..== O.sqlStrictText intent)
    pure (chain,resolved O..== O.sqlInt8 1,common)
    :: IO [(T.Text,Bool,Maybe T.Text)]
  preparations <- O.runSelect c $ O.orderBy (O.asc (\(n,_,_,_,_)->n)) $ do
    (key,n,policy,draft,retired,cancelled) <- S.workPreparations
    O.where_ (key O..== O.sqlStrictText intent)
    pure (n,policy,draft,retired,cancelled O..== O.sqlInt8 1)
    :: IO [(Int64,T.Text,Maybe T.Text,Maybe T.Text,Bool)]
  attempts <- O.runSelect c $ O.orderBy (O.asc (\(_,_,n,_,_)->n) <> O.asc (\(tx,_,_,_,_)->tx)) $ do
    (tx,key,state,n,sequenceNo,observation) <- S.workAttempts
    O.where_ (key O..== O.sqlStrictText intent)
    pure (tx,state,n,sequenceNo,observation)
    :: IO [(T.Text,T.Text,Int64,Maybe Int64,Maybe T.Text)]
  cancellations <- O.runSelect c $ O.orderBy (O.asc (\(n,_,_,_)->n)) $ do
    (key,n,reason,cleanup,completed) <- S.workCancellations
    O.where_ (key O..== O.sqlStrictText intent)
    pure (n,reason,cleanup,completed O..== O.sqlInt8 1)
    :: IO [(Int64,T.Text,T.Text,Bool)]
  fees <- O.runSelect c $ do
    (key,asset,n,released) <- S.workFees
    O.where_ (key O..== O.sqlStrictText intent)
    pure (asset,n,released O..== O.sqlInt8 1)
    :: IO [(T.Text,Int64,Bool)]
  drafts <- O.runSelect c $ O.orderBy (O.asc (\(n,_,_,_,_,_)->n)) $ do
    draft@(_,parent,_,_,_,_) <- S.replacementDrafts
    (tx,key,_,_,_,_) <- S.workAttempts
    O.where_ (parent O..== tx O..&& key O..== O.sqlStrictText intent)
    pure draft
    :: IO [(Int64,T.Text,Int64,T.Text,T.Text,T.Text)]
  cancelled <- O.runSelect c $ O.orderBy (O.asc (\(_,_,n)->n)) $ do
    decision@(draft,_,_) <- S.replacementCancellations
    (n,parent,_,_,_,_) <- S.replacementDrafts
    (tx,key,_,_,_,_) <- S.workAttempts
    O.where_ (draft O..== n O..&& parent O..== tx O..&& key O..== O.sqlStrictText intent)
    pure decision
    :: IO [(Int64,T.Text,Int64)]
  let hashJson=digest . BL.toStrict . encode
      base=hashJson (obligations,work,preparations,attempts,cancellations,fees)
  pure (if not includeReplacements || null drafts && null cancelled then base else digest $ BL.toStrict $ encode (base,drafts,cancelled))

fixture c (ArchiveLegacy settings directory) = Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly) c $ do
  (rows,_,_)<-fixture c ArchiveRecords
  row<-case rows of [r] | S.schemaVersion r==21 && S.paused r==1->pure r; _->fail "paused populated schema21 fixture required"
  snapshot<-fixture c ExportArchiveSnapshot
  Backup.archiveLedger settings directory (S.fingerprint row) 21 (S.criticalSequence row) snapshot
fixture c LegacyOrderSnapshot = O.runSelect c (fmap Legacy.orderId $ O.selectTable Legacy.orders)
fixture c (ReviewLegacyOrder key) = void $ O.runUpdate c O.Update {O.uTable=Legacy.orders,
  O.uUpdateWith= \row->row {Legacy.status=O.sqlStrictText "NeedsReview"},
  O.uWhere= \row->Legacy.orderId row O..== O.sqlStrictText key,O.uReturning=O.rCount}
fixture c (ReviewAdmission key) = void $ O.runUpdate c O.Update {O.uTable=S.orders,
  O.uUpdateWith= \row->row {S.admissionState=O.sqlStrictText "NeedsReview"},
  O.uWhere= \row->S.orderId row O..== O.sqlStrictText key,O.uReturning=O.rCount}
fixture c (ReceiptPayment receipt) = do
  ids<-O.runSelect c $ do
    (key,source)<-S.obligationReceipts
    O.where_ (source O..== O.sqlStrictText receipt)
    pure key
  case ids of [key]->pure key; _->fail "baseline receipt payment missing"
fixture c LegacyPaymentStates = do
  customer<-O.runSelect c (fmap (\ob->(Legacy.obligationId ob,Legacy.obligationStatus ob)) $ O.selectTable Legacy.obligations)
  fees<-O.runSelect c (O.selectTable S.withdrawals) :: IO [S.Withdrawal]
  earned<-mapM (\withdrawal->do
    let key="fee:"<>S.withdrawalId withdrawal; text=O.sqlStrictText
    rows<-O.runSelect c $ do
      i<-O.selectTable Legacy.intents
      O.where_ (Legacy.intentId i O..== text key)
      pure (Legacy.intentResolved i)
      :: IO [Int64]
    cancelled<-O.runSelect c $ do
      (id,_,_)<-O.selectTable S.cancellations
      O.where_ (id O..== text(S.withdrawalId withdrawal))
      pure id
      :: IO [T.Text]
    winners<-O.runSelect c $ do
      a<-O.selectTable S.attempts
      O.where_ (S.attemptIntent a O..== text key O..&& S.attemptState a O..== text "settled")
      pure (S.attemptId a)
      :: IO [T.Text]
    retry<-O.runSelect c (Projection.successorReady $ text key) :: IO [Bool]
    pure (key,if not(null cancelled) then "cancelled" else if rows==[0] then "paying" else if length winners==1 then "paid" else if rows==[] || retry==[True] then "ready" else "review")) fees
  pure (sort $ customer<>earned)
fixture c LegacyCandidates = do
  states<-fixture c LegacyPaymentStates
  active<-O.runSelect c $ do
    i<-O.selectTable Legacy.intents
    O.where_ (Legacy.intentResolved i O..== O.sqlInt8 0)
    pure (Legacy.intentId i,Legacy.intentChain i)
    :: IO [(T.Text,T.Text)]
  currencies<-O.runSelect c $ O.unionAll
    (fmap (\o->(Legacy.obligationId o,Legacy.obligationAsset o)) $ O.selectTable Legacy.obligations)
    (fmap (\w->(O.sqlStrictText "fee:" O..++ S.withdrawalId w,S.asset w)) $ O.selectTable S.withdrawals)
    :: IO [(T.Text,T.Text)]
  let ready=[(key,if asset=="Native" then "Native" else "Solana") | (key,"ready")<-states,Just asset<-[lookup key currencies]]
  pure [key | chain<-["Native","Solana"],key<-take 1 [id | (id,currency)<-active<>ready,currency==chain]]
fixture c ClaimWorkerLock = claimWorker c
fixture c OldPaymentIds = sort <$> ((<>)
  <$> O.runSelect c (fmap S.obligationId $ O.selectTable S.obligations)
  <*> O.runSelect c (fmap ((O.sqlStrictText "fee:" O..++).S.withdrawalId) $ O.selectTable S.withdrawals))
fixture c PaymentRoots = O.runSelect c $ O.orderBy (O.asc S.rootId) $ O.selectTable S.paymentRoots
fixture c RootPaymentStates = O.runSelect c $ O.orderBy (O.asc fst) $ do
  (root,state)<-Projection.paymentStates
  pure (S.rootId root,state)
fixture c RootCandidates = do
  active<-O.runSelect c Projection.activePayments :: IO [(T.Text,T.Text)]
  ready<-O.runSelect c Projection.readyPayments :: IO [(T.Text,T.Text)]
  unless (length active<=2 && length ready<=1000) (fail "payment-root queue overflow")
  pure [key | chain<-["Native","Solana"],key<-take 1 [identifier | (identifier,currency)<-active<>ready,currency==chain]]
fixture c (WaitingRootMigration database) = do
  rows<-O.runSelect c $ do
    (name,event,statement)<-O.selectTable $ O.tableWithSchema "pg_catalog" "pg_stat_activity" $ p3
      (O.requiredTableField "datname",O.requiredTableField "wait_event_type",O.requiredTableField "query")
    O.where_ (name O..== O.sqlStrictText database
      O..&& O.matchNullable (O.sqlBool False) (O..== O.sqlStrictText "Lock") event
      O..&& O.like statement (O.sqlStrictText "%ALTER TABLE intents ADD COLUMN deposit_id%"))
    pure name
    :: IO [T.Text]
  pure (not $ null rows)
fixture c (MigrationReview identifier blocked) = void $ O.runUpdate c O.Update {O.uTable=Legacy.obligations,
  O.uUpdateWith= \row->row {Legacy.obligationStatus=O.sqlStrictText $ if blocked then "review" else "ready"},
  O.uWhere= \row->Legacy.obligationId row O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
fixture c (MigrationMalformedOrder present) =
  let text=O.sqlStrictText; key=text "migration-malformed-order" in
  if present then void $ O.runInsert c O.Insert {O.iTable=Legacy.orders,
    O.iRows=[Legacy.Order key key key key (text "{}") (text "{}") (text "{}") (text "AwaitingDeposit")
      (O.sqlInt8 200) (O.sqlInt8 300) O.null O.null O.null (O.sqlInt8 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  else void $ O.runDelete c O.Delete {O.dTable=Legacy.orders,O.dWhere= \row->Legacy.orderId row O..== key,O.dReturning=O.rCount}
fixture c (MigrationLostWinner key) = void $ O.runUpdate c O.Update {O.uTable=S.attempts,
  O.uUpdateWith= \row->row {S.attemptState=O.sqlStrictText "review"},
  O.uWhere= \row->S.attemptId row O..== O.sqlStrictText key,O.uReturning=O.rCount}
fixture c RootConstraintFailures = do
  roots<-fixture c PaymentRoots
  let text=O.sqlStrictText; num=O.sqlInt8
      ready="fee:"<>T.replicate 64 "b"
      settled=[S.rootId root | root<-roots,S.rootPhase root=="settled"]
      update key change=void $ O.runUpdate c O.Update {O.uTable=S.paymentRoots,O.uUpdateWith=change,
        O.uWhere= \row->S.rootId row O..== text key,O.uReturning=O.rCount}
      refuses state action=do
        result<-try (PG.withTransaction c action) :: IO (Either PG.SqlError ())
        pure (case result of Left err->PG.sqlState err==state; _->False)
      recipients=O.table "obligations" $ p2 (O.requiredTableField "id",O.requiredTableField "recipient")
      funding :: O.Table (S.TextField,S.TextField,S.TextField,S.TextField,S.TextField,S.IntField,S.TextField)
                         (S.TextField,S.TextField,S.TextField,S.TextField,S.TextField,S.IntField,S.TextField)
      funding=O.table "obligations" $ p7 (O.requiredTableField "id",O.requiredTableField "order_id",O.requiredTableField "deposit_id",
        O.requiredTableField "kind",O.requiredTableField "asset",O.requiredTableField "amount",O.requiredTableField "recipient")
      duplicateReceipt=do
        rows<-O.runSelect c $ do
          (_,order,receipt,_,asset,n,recipient)<-O.selectTable funding
          O.where_ (receipt O..== text "root-unexplained")
          pure (order,receipt,asset,n,recipient)
        (order,receipt,asset,n,recipient)<-case rows of [row]->pure row; _->fail "receipt uniqueness fixture missing"
        let key="root-duplicate-receipt"
        void $ O.runInsert c O.Insert {O.iTable=funding,
          O.iRows=[(text key,text order,text receipt,text "refund",text asset,num n,text recipient)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        void $ O.runInsert c O.Insert {O.iTable=S.paymentRoots,
          O.iRows=[S.PaymentRoot (text key) (O.toNullable $ text key) O.null (O.toNullable $ text receipt)
            (text "Solana") O.null (text "ready") O.null O.null O.null],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  winner<-case settled of key:_->pure key; _->fail "settled constraint fixture missing"
  checks<-sequence
    [ refuses "23514" $ update winner (\row->row {S.rootPhase=text "ready",S.rootWinner=O.null,S.rootSettlementEvent=O.null})
    , refuses "23514" $ update winner (\row->row {S.rootWinner=O.toNullable $ text "forged-winner"})
    , refuses "23514" $ update winner (\row->row {S.rootSettlementEvent=O.toNullable $ text "settlement:forged"})
    , refuses "23514" $ update ready (\row->row {S.rootChain=text "Solana"})
    , refuses "23514" $ update ready (\row->row {S.rootPhase=text "unknown"})
    , refuses "23505" $ update ready (\row->row {S.rootPhase=text "active",S.rootGeneration=O.toNullable $ num 0})
    , refuses "23505" duplicateReceipt
    , refuses "23514" $ void $ O.runUpdate c O.Update {O.uTable=recipients,
        O.uUpdateWith= \(key,_)->(key,text "changed-recipient"),O.uWhere= \(key,_)->key O..== text winner,O.uReturning=O.rCount}
    , refuses "23514" $ void $ O.runDelete c O.Delete {O.dTable=S.paymentRoots,
        O.dWhere= \row->S.rootId row O..== text ready,O.dReturning=O.rCount}
    ]
  after<-fixture c PaymentRoots
  pure (and checks && roots==after)
-- Test-only schema-21 display oracle. Retain the old recovery overlays and
-- compatibility columns while production derives progress/winner from payments.
fixture c CurrentCustomerOrders = do
  cap<-either (fail . T.unpack) pure (capabilityHash $ T.replicate 64 "0")
  O.runSelect c $ do
    o<-O.selectTable S.orders
    O.where_ (S.capabilityHash o O..== O.sqlStrictText cap
      O..&& O.not (O.in_ (map O.sqlStrictText ["mismatch","corrupt"]) (S.orderId o)))
    pure (S.orderId o)
fixture c CustomerCompatibility = do
  cap<-either (fail . T.unpack) pure (capabilityHash $ T.replicate 64 "0")
  orders<-O.runSelect c $ do
    o<-O.selectTable Legacy.orders
    O.where_ (Legacy.capabilityHash o O..== O.sqlStrictText cap
      O..&& O.not (O.in_ (map O.sqlStrictText ["mismatch","corrupt"]) (Legacy.orderId o)))
    pure (Legacy.orderId o,Legacy.status o,Legacy.payoutTx o)
    :: IO [(T.Text,T.Text,Maybe T.Text)]
  let orderObligations=do
        ob<-O.selectTable Legacy.obligations
        pure (Legacy.obligationId ob,Legacy.obligationOrder ob,Legacy.obligationDeposit ob,Legacy.obligationStatus ob)
  obligations<-O.runSelect c orderObligations :: IO [(T.Text,T.Text,T.Text,T.Text)]
  sources<-O.runSelect c $ do
    (source,state)<-S.sourceRecovery
    (deposit,order)<-S.orderDeposits
    O.where_ (source O..== deposit O..&& state O../= O.sqlStrictText "restored")
    pure (source,order)
    :: IO [(T.Text,Maybe T.Text)]
  accounted<-O.runSelect c S.accountedLosses :: IO [T.Text]
  native<-O.runSelect c $ do
    (tx,state)<-S.nativeRecovery
    (attempt,intent)<-S.attemptIntents
    (intentId,obligation)<-S.intentObligations
    (obligationId,order,_,_)<-orderObligations
    O.where_ (tx O..== attempt O..&& intent O..== intentId O..&& O.matchNullable (O.sqlBool False) (O..== obligationId) obligation
      O..&& state O../= O.sqlStrictText "reconfirmed")
    pure order
    :: IO [T.Text]
  let original (identifier,status,payout)=
        let owned=[(deposit,state) | (_,order,deposit,state)<-obligations,order==identifier]
            lost=[deposit | (deposit,Just order)<-sources,order==identifier]
            review=identifier `elem` native || any ((=="review").snd) owned
              || any (\deposit->deposit `notElem` accounted || (deposit,"paid") `notElem` owned) lost
        in (identifier,if review then "NeedsReview" else status,payout)
  pure (map original orders)
fixture c (SetPause paused) = void $ O.runUpdate c O.Update {O.uTable=S.deployment,
  O.uUpdateWith= \row->row {S.paused=O.sqlInt8 (if paused then 1 else 0)},
  O.uWhere= \row->S.singleton row O..== O.sqlInt8 1,O.uReturning=O.rCount}
-- A settled root cannot be reopened, even by a writer with database credentials.
fixture c (ReactivatePayment identifier) = void $ O.runUpdate c O.Update {O.uTable=S.paymentRoots,
  O.uUpdateWith= \row->row {S.rootPhase=O.sqlStrictText "active",S.rootGeneration=O.toNullable $ O.sqlInt8 0,S.rootWinner=O.null,S.rootSettlementEvent=O.null},
  O.uWhere= \row->S.rootId row O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
fixture c RestoreDatabases = O.runSelect c $ O.orderBy (O.asc id) $ do
  name<-O.selectTable $ O.tableWithSchema "pg_catalog" "pg_database" (O.requiredTableField "datname")
  O.where_ (O.like name $ O.sqlStrictText "ecx_restore_%")
  pure name
fixture c LiveScanHealth = O.runSelect c $ O.orderBy (O.asc $ \(chain,_,_)->chain) $ do
  (chain,at,problem,_)<-O.selectTable S.scanHealth
  pure (chain,at,problem)
fixture c NativeRecoveryEvidence = O.runSelect c S.nativeRecoveryDetails
fixture c SetupResidue = void $ O.runInsert c O.Insert {O.iTable=S.events,
  O.iRows=[(O.sqlStrictText "orphaned-ledger-event",O.sqlStrictText "initialization must refuse surviving history")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c MigrationLegacyPayments = do
  obligations<-O.runSelect c (O.selectTable Legacy.obligations) :: IO [Legacy.Obligation]
  costs<-O.runSelect c (O.selectTable S.orderCosts) :: IO [(T.Text,Int64,Int64,Int64)]
  orders<-O.runSelect c (O.selectTable Legacy.orders) :: IO [Legacy.Order]
  intents<-O.runSelect c (O.selectTable Legacy.intents) :: IO [Legacy.Intent]
  attempts<-O.runSelect c (O.selectTable S.attempts) :: IO [S.Attempt]
  let archived row =
        let matching=[i | i<-intents,Legacy.intentObligation i==Just(Legacy.obligationId row)]
            winners=[a | a<-attempts,S.attemptIntent a `elem` map Legacy.intentId matching,S.attemptState a=="settled"]
        in Legacy.obligationStatus row=="paid" && not(null matching) && all ((==1).Legacy.intentResolved) matching
          && length winners==1 && all ((/=Nothing).S.attemptObservation) winners
          && any (\o->Legacy.orderId o==Legacy.obligationOrder row && Legacy.status o `elem` ["Paid","Refunded"]) orders
  -- Missing historical terms never become executable PaymentTerms. Require a
  -- resolved intent and unique recorded winner; unfinished/review work must fail.
  pure [(Legacy.obligationId row,archived row) | row<-obligations,
    Legacy.obligationOrder row `notElem` [key | (key,_,_,_)<-costs]]
fixture c MigratedIntents = O.runSelect c (O.selectTable Legacy.intents)
fixture c MigrationRecords = do
  original<-sequence
    [ rows (O.runSelect c (O.selectTable S.orders) :: IO [S.Order])
    , rows (O.runSelect c (O.selectTable S.deposits) :: IO [S.Deposit])
    , rows (O.runSelect c (O.selectTable S.obligations) :: IO [S.Obligation])
    , rows (O.runSelect c S.intentObligations :: IO [(T.Text,Maybe T.Text)])
    , rows (O.runSelect c Projection.workIntents :: IO [(T.Text,T.Text,Int64,Maybe T.Text)])]
  retained<-fixture c PaymentHistoryRecords
  pure (original<>retained)
 where
  rows :: Show a => IO [a] -> IO String
  rows action=show . sort . map show <$> action
fixture c LegacyMigrationRecords = do
  original<-sequence
    [ rows (O.runSelect c (O.selectTable Legacy.orders) :: IO [Legacy.Order])
    , rows (O.runSelect c (O.selectTable S.deposits) :: IO [S.Deposit])
    , rows (O.runSelect c (O.selectTable Legacy.obligations) :: IO [Legacy.Obligation])
    , rows (O.runSelect c S.intentObligations :: IO [(T.Text,Maybe T.Text)])
    , rows (O.runSelect c (O.selectTable Legacy.intents) :: IO [Legacy.Intent])]
  retained<-fixture c PaymentHistoryRecords
  pure (original<>retained)
 where
  rows :: Show a => IO [a] -> IO String
  rows action=show . sort . map show <$> action
fixture c RootRetainedRecords = (<>) <$> sequence
  [ rows (O.runSelect c (O.selectTable $ O.table "orders" $ p2
      (p6 (textField "id",textField "capability_hash",textField "idempotency_key",textField "request_hash",textField "request_json",textField "quote_json"),
       p6 (textField "policy_json",numberField "deadline",numberField "grace_deadline",
           nullableText "instruction",nullableNumber "instruction_sequence",numberField "instruction_issued")))
      :: IO [((T.Text,T.Text,T.Text,T.Text,T.Text,T.Text),(T.Text,Int64,Int64,Maybe T.Text,Maybe Int64,Int64))])
  , rows (O.runSelect c (O.selectTable $ O.table "obligations" $ p7
      (textField "id",textField "order_id",textField "deposit_id",textField "kind",textField "asset",numberField "amount",textField "recipient"))
      :: IO [(T.Text,T.Text,T.Text,T.Text,T.Text,Int64,T.Text)])
  , rows (O.runSelect c (O.selectTable S.deposits) :: IO [S.Deposit])
  , rows (O.runSelect c (O.selectTable S.withdrawals) :: IO [S.Withdrawal])
  , rows (O.runSelect c (O.selectTable S.cancellations) :: IO [(T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.events) :: IO [(T.Text,T.Text)])
  , rows (O.runSelect c (O.selectTable S.audit) :: IO [(Int64,T.Text,T.Text)])
  , rows (O.runSelect c (O.selectTable S.custody) :: IO [(Int64,Int64,Maybe Int64,Maybe Int64,Maybe T.Text)])
  , rows (O.runSelect c (O.selectTable S.custodyReport) :: IO [(Int64,Maybe T.Text)])
  , rows (O.runSelect c (O.selectTable S.scanHealth) :: IO [(T.Text,Maybe Int64,Maybe T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.checkpoints) :: IO [(T.Text,T.Text)])
  , rows (O.runSelect c (O.selectTable S.scanOrigins) :: IO [(T.Text,T.Text)])
  , rows (O.runSelect c (O.selectTable S.nativeAllocations) :: IO [(T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.chainEvents) :: IO [S.ChainEvent])
  , rows (O.runSelect c (O.selectTable S.observationEvidence) :: IO [(T.Text,T.Text,T.Text,T.Text)])
  , rows (O.runSelect c (O.selectTable S.treasuryAllocations) :: IO [(T.Text,T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.treasurySpends) :: IO [(T.Text,T.Text,T.Text,T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.legacyHints) :: IO [(T.Text,T.Text)])
  ] <*> fixture c PaymentHistoryRecords
 where
  textField :: String -> O.TableFields S.TextField S.TextField
  textField=O.requiredTableField
  numberField :: String -> O.TableFields S.IntField S.IntField
  numberField=O.requiredTableField
  nullableText :: String -> O.TableFields (O.FieldNullable O.SqlText) (O.FieldNullable O.SqlText)
  nullableText=O.requiredTableField
  nullableNumber :: String -> O.TableFields (O.FieldNullable O.SqlInt8) (O.FieldNullable O.SqlInt8)
  nullableNumber=O.requiredTableField
  rows :: Show a => IO [a] -> IO String
  rows action=show . sort . map show <$> action
fixture c PaymentHistoryRecords = sequence
  [ rows (O.runSelect c (O.selectTable S.preparations) :: IO [(T.Text,Int64,T.Text,Maybe T.Text,Maybe T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.reservations) :: IO [(T.Text,T.Text,Int64,T.Text)])
  , rows (O.runSelect c (O.selectTable S.operatingReservations) :: IO [(T.Text,T.Text,T.Text,Int64,T.Text)])
  , rows (O.runSelect c (O.selectTable S.orderCosts) :: IO [(T.Text,Int64,Int64,Int64)])
  , rows (O.runSelect c (O.selectTable S.feeHolds) :: IO [(T.Text,T.Text,Int64,Int64)])
  , rows (O.runSelect c (O.selectTable S.operatingClock) :: IO [(Int64,Int64)])
  , rows (O.runSelect c (O.selectTable S.operatingCosts) :: IO [(Int64,Int64)])
  , rows (O.runSelect c (O.selectTable S.preparationCancellations) :: IO [(T.Text,Int64,T.Text,T.Text,Int64,Int64)])
  , rows (O.runSelect c (O.selectTable S.solanaExpiries) :: IO [(T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.solanaRetryApprovals) :: IO [(T.Text,T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.replacementDecisions) :: IO [(Int64,T.Text,Int64,T.Text,T.Text,T.Text,T.Text)])
  , rows (O.runSelect c (O.selectTable S.replacementCancellationRows) :: IO [(Int64,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.replacementMemberRows) :: IO [(Int64,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.nativeRecoveryRows) :: IO [(T.Text,T.Text,T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.nativeWinnerChanges) :: IO [(Int64,T.Text,T.Text,T.Text,T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.sourceChecks) :: IO [(Int64,T.Text,T.Text,Int64,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.sourceRecoveryDecisions) :: IO [(T.Text,Int64,Int64,T.Text,T.Text,T.Text,T.Text,Int64)])
  , rows (O.runSelect c (O.selectTable S.sourceLossCovers) :: IO [(Int64,T.Text,Int64,Int64,Int64,Int64,T.Text,T.Text)])
  , rows (O.runSelect c (O.selectTable S.sourceReturns) :: IO [(Int64,Int64)])
  ]
 where
  rows :: Show a => IO [a] -> IO String
  rows action=show . sort . map show <$> action
fixture c ExportArchiveSnapshot = do
  snapshots<-O.runSelect c (pure exportSnapshot)
  case snapshots of [snapshot]->pure snapshot; _->fail "invalid fixture snapshot"
fixture c (SetArchiveSequence n) = void $ O.runUpdate c O.Update
  {O.uTable=S.deployment,O.uUpdateWith= \row->row {S.criticalSequence=O.sqlInt8 n}
  ,O.uWhere= \row->S.singleton row O..== O.sqlInt8 1,O.uReturning=O.rCount}
fixture c ArchiveRecords = (,,)
  <$> O.runSelect c (O.selectTable S.deployment)
  <*> O.runSelect c (O.orderBy (O.asc S.attemptId) $ O.selectTable S.attempts)
  <*> O.runSelect c (O.orderBy (O.asc $ \(n,_,_,_,_)->n) $ O.selectTable S.postings)
fixture c (SourceAnchor key anchor) = void $ O.runUpdate c O.Update {O.uTable=S.deposits,
  O.uUpdateWith= \r->r {S.depositAnchor=O.sqlStrictText anchor},O.uWhere= \r->S.depositId r O..== O.sqlStrictText key,O.uReturning=O.rCount}
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
fixture c (OperatingBudgetRace spend) = do
  changes<-O.runSelect c $ do
    (_,event,asset,account,n)<-O.selectTable S.postings
    O.where_ (asset O..== O.sqlStrictText "Native" O..&& account O..== O.sqlStrictText "operating"
      O..&& (O.sqlBool spend O..|| event O..== O.sqlStrictText "contract-operating-race"))
    pure n
    :: IO [Int64]
  let delta=negate(sum changes); text=O.sqlStrictText
      event=if spend then "contract-operating-race" else "contract-operating-race-return"
  void $ O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(text event,text "independent connection budget contract")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=
    [(Nothing,text event,text "Native",text account,O.sqlInt8 n)| (account,n)<-[("operating",delta),("external",negate delta)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  fixture c RefreshCustody
fixture c LockDeployment = do
  rows<-O.runSelect c $ Locking.forUpdate $ fmap S.singleton $ O.selectTable S.deployment
  unless (rows==[1::Int64]) (fail "deployment row missing")
fixture c RecoveryPauseCount = length <$> (O.runSelect c (do
  (_,kind,reason)<-O.selectTable S.audit
  O.where_ (kind O..== O.sqlStrictText "pause" O..&& reason O..== O.sqlStrictText "payment_requires_reconciliation")
  pure reason) :: IO [T.Text])
fixture c LockRestoreAudits = O.runSelect c $ do
  (_,kind,subject)<-O.selectTable S.audit
  O.where_ (kind O..== O.sqlStrictText "native_locks_restored")
  pure subject
fixture c Initialize = fixture c (InitializeIdentity "contract")
fixture c (InitializeIdentity identity) = PG.withTransaction c $ do
  void $ O.runInsert c O.Insert {O.iTable=S.deployment,O.iRows=[S.Deployment (O.sqlInt8 1) (O.sqlInt8 2200) (O.sqlStrictText identity) (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "test")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  forM_ ["009-stage.sql","009-activate.sql"] $ \name->do
    path<-getDataFileName ("migrations/"<>name)
    BS.readFile path >>= void . PG.execute_ c . Query
  void $ O.runUpdate c O.Update {O.uTable=S.deployment,O.uUpdateWith= \r->r {S.schemaVersion=O.sqlInt8 22},O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
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
          (O.sqlInt8 $ if identifier=="visible" then 1 else 0)
    void $ O.runInsert c O.Insert {O.iTable=S.orders,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
fixture c CoverBackup = void $ O.runUpdate c O.Update {O.uTable=S.deployment,
  O.uUpdateWith= \r->r {S.backupSequence=S.criticalSequence r},O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
fixture c SeedReview = PG.withTransaction c $ do
  let text=O.sqlStrictText; num=O.sqlInt8
  void $ O.runInsert c O.Insert {O.iTable=S.deposits,O.iRows=[S.Deposit (text "review-deposit") (O.toNullable $ text "visible") (text "Native") (num 100) (text "anchor") (num 100) (num 2) (num 1) (num 1) (text "observed")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.obligations,O.iRows=[S.Obligation (text "review-obligation") (text "visible") (text "review-deposit") (text "conversion") (text "Wrapped") (num 93) (text "recipient")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.paymentRoots,
    O.iRows=[S.PaymentRoot (text "review-obligation") (O.toNullable $ text "review-obligation") O.null (O.toNullable $ text "review-deposit")
      (text "Solana") O.null (text "ready") O.null O.null O.null],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  -- Restored source eligibility does not approve the payment's retained review.
  -- This replaces the old freely writable obligation status with its evidence.
  void $ O.runInsert c O.Insert {O.iTable=S.sourceChecks,
    O.iRows=[(Nothing,text "review-deposit",text state,num 0,text proof,num n) | (state,proof,n)<-
      [("unavailable","{\"reason\":\"source_eligibility_lost\",\"reviewedObligations\":[{\"intent\":\"review-obligation\"}]}",1),
       ("restored","{}",2)]],O.iReturning=O.rCount,O.iOnConflict=Nothing}

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
    pure (S.admissionState row)
    :: IO [T.Text]
  states<-O.runSelect c $ do
    (key,_,_,state)<-Projection.orderObligations
    O.where_ (key O..== O.sqlStrictText("convert:"<>oid))
    pure state
    :: IO [T.Text]
  let display=if "review" `elem` states || "NeedsReview" `elem` orders then "NeedsReview" else "Ready"
  pure (obligations==[S.Obligation ("convert:"<>oid) oid did "conversion" (T.pack $ show asset) quantity "recipient"] && deposits==[1] && states `elem` [["ready"],["review"]] && display==status)

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
      (O.toNullable $ text "historical-native-fixture") (O.toNullable $ num 0) (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
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
    (_,order,_,state)<-Projection.orderObligations
    O.where_ (order O..== O.sqlStrictText oid)
    pure state
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
      preparations=O.table "preparations" $ p6 (O.requiredTableField "intent_id",O.requiredTableField "generation",O.requiredTableField "policy_json",O.requiredTableField "draft_json",O.requiredTableField "retired_txid",O.requiredTableField "cancelled")
      attempts=O.table "attempts" $ p9 (O.requiredTableField "txid",O.requiredTableField "intent_id",O.requiredTableField "signed_bytes",O.requiredTableField "policy_json",O.requiredTableField "fee_limit",O.requiredTableField "state",O.requiredTableField "critical_sequence",O.requiredTableField "observation_json",O.requiredTableField "preparation_generation")
  sources<-O.runSelect c $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationId row O..== text ("convert:"<>oid))
    pure (S.obligationDeposit row)
  source<-case sources of [did]->pure did; _->fail "missing scan source"
  void $ O.runUpdate c O.Update {O.uTable=S.paymentRoots,O.uUpdateWith= \r->r {S.rootPhase=text "cancelled"},
    O.uWhere= \r->S.rootId r O..== text ("convert:"<>oid),O.uReturning=O.rCount}
  void $ O.runInsert c O.Insert {O.iTable=S.obligations,
    O.iRows=[S.Obligation (text intent) (text oid) (text source) (text "refund") (text "Native") (num 10) (text "refund")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.paymentRoots,O.iRows=[S.PaymentRoot (text intent) (O.toNullable $ text intent) O.null (O.toNullable $ text source)
    (text "Native") O.null (text "ready") O.null O.null O.null],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=S.feeHolds,O.iRows=[(text intent,text "Native",num 1,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runInsert c O.Insert {O.iTable=preparations,O.iRows=[(text intent,num 0,text "{}",O.toNullable $ text "{}",O.null,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  void $ O.runUpdate c O.Update {O.uTable=S.paymentRoots,O.uUpdateWith= \r->r {S.rootPhase=text "active",S.rootGeneration=O.toNullable $ num 0},
    O.uWhere= \r->S.rootId r O..== text intent,O.uReturning=O.rCount}
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
fixture c (SourceHistory did) = O.runSelect c $ O.limit 1000 $ O.orderBy (O.desc $ \(_,_,_,n)->n) $ do
  (_,source,state,loss,proof,n)<-O.selectTable S.sourceChecks
  O.where_ (source O..== O.sqlStrictText did)
  pure (state,loss,proof,n)
fixture c (PaymentAttemptHistory identifier) = do
  rows<-O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc id) $ do
    (tx,key,_,_,_,_)<-S.workAttempts
    O.where_ (key O..== O.sqlStrictText identifier)
    pure tx
  unless (length rows<=1000) (fail "payment history too large")
  pure rows

fixture c (CheckFundingBinding identifier withdrawal) = do
  rows<-O.runSelect c $ do
    row<-O.selectTable S.paymentRoots
    O.where_ (S.rootId row O..== O.sqlStrictText identifier)
    pure (S.rootObligation row,S.rootWithdrawal row)
    :: IO [(Maybe T.Text,Maybe T.Text)]
  changed<-try (O.runUpdate c O.Update {O.uTable=S.paymentRoots,O.uUpdateWith= \r->r {S.rootChain=O.sqlStrictText "Solana"},O.uWhere= \r->S.rootId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}) :: IO (Either PG.SqlError Int64)
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
custodyContract :: PG.ConnectInfo -> StorePolicy -> PG.Connection -> Reader -> IO ()
custodyContract database store fixtures reader = do
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
  let dual primary verifier=inspect (pure 100) (pure ()) nativeCall primary (Just verifier)
        settings {solanaSettings=solana {Solana.solanaVerifierRpc=Just "https://independent.example"}}
  primaryStarted<-newEmptyMVar; verifierStarted<-newEmptyMVar
  let rendezvous own other method params=do
        when (method=="getMultipleAccounts") (putMVar own () >> takeMVar other)
        good method params
  concurrentResult<-timeout 5000000 $ dual (rendezvous primaryStarted verifierStarted) (rendezvous verifierStarted primaryStarted)
  case concurrentResult of
    Just (_,_,True,_)->pure ()
    _->fail "custody providers did not inspect concurrently"
  -- Failure on either provider cancels its sibling before returning to the caller.
  forM_ [False,True] $ \swap->do
    started<-newEmptyMVar; blocked<-newEmptyMVar; stopped<-newEmptyMVar
    let waiting _ _=(putMVar started () >> takeMVar blocked) `finally` putMVar stopped ()
        failing _ _=takeMVar started >> reject "rpc_error_-32019"
    completed<-timeout 5000000 $ do
      expectStore "rpc_error_-32019" (if swap then dual failing waiting else dual waiting failing)
      takeMVar stopped
    unless (completed==Just ()) (fail "custody provider failure left a running inspection")
  let advanced wallet method params=if method=="listsinceblock" then pure $ object ["lastblock" .= ("advanced"::T.Text)] else nativeCall wallet method params
  expectStore "custody_native_history_advanced" (inspect (pure 100) (pure ()) advanced good Nothing settings)
  -- A new mempool receipt can appear after scanning without advancing the tip.
  -- Absence defers custody; an existing reviewed or changed event stays strict.
  let newTx=T.replicate 64 "2"
      proof=object ["confirmations" .= (0::Int)]
      seed review=fixture fixtures $ SeedTreasuryEvidence "Native" newTx "unconfirmed" "reference" review proof
      appeared action confirmations wallet method params=if method=="listsinceblock" then do
        action
        pure $ object ["lastblock" .= ("fixture-anchor"::T.Text)
          ,"transactions" .= [object ["txid" .= newTx,"confirmations" .= (confirmations::Int)]]
          ,"removed" .= ([]::[Value])]
       else nativeCall wallet method params
      inspectAppeared action confirmations=inspect (pure 100) (pure ()) (appeared action confirmations) good Nothing settings
  expectStore "custody_native_history_advanced" (inspectAppeared (pure ()) 0)
  seed 0
  expectStore "custody_native_history_changed" (inspectAppeared (pure ()) 1)
  expectStore "custody_history_not_current" (inspectAppeared (seed 1) 0) `finally` seed 0
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
  -- Keep pending-family fixtures out of the shared ledger contract. Restore
  -- one real archive and use the same restricted reader and closed Store DSL.
  withTestSigningKey $ \temporary->do
    archive<-evalBackup reader (ExportLedger $ takeDirectory temporary)
    role<-getEnv "ECX_REBUILD_CONTRACT_READER"
    bracket (evalRestore database $ RestoreLedger (manifestPath archive) "contract" (archiveSequence archive))
      (\(name,_)->Backup.discardRestore database {PG.connectDatabase=T.unpack name}) $ \(name,_)->do
        let target=database {PG.connectDatabase=T.unpack name}
        bracket (PG.connect target) PG.close $ \connection->do
          -- Privilege DDL only; all application rows use closed Opaleye operations.
          void $ PG.execute connection "GRANT CONNECT ON DATABASE ? TO ?" (Identifier name,Identifier $ T.pack role)
          void $ PG.execute connection "GRANT USAGE ON SCHEMA public TO ?" (PG.Only $ Identifier $ T.pack role)
          void $ PG.execute connection "GRANT SELECT ON ALL TABLES IN SCHEMA public TO ?" (PG.Only $ Identifier $ T.pack role)
          void $ PG.execute connection "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ?" (PG.Only $ Identifier $ T.pack role)
          withReader target {PG.connectUser=role} "contract" True $ \isolated->
            withWriter target store (const $ pure ()) $ \writer->
              nativeCustodyFamilies connection isolated writer settings config nativeCall good

-- Synthetic RPC replies over a real ledger: no live-chain acceptance claim.
nativeCustodyFamilies :: PG.Connection -> Reader -> Writer -> ObserverSettings -> H.SolanaPolicy
  -> NP.NativeRPC -> SP.SolanaRPC -> IO ()
nativeCustodyFamilies fixtures reader writer settings config base solana=do
  captured<-getDataFileName "test/fixtures/native-signet-payment.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  originalPlan<-fieldValue "plan" captured
  let check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "native custody family contract: "<>prettyCallStack callStack)
      encodeText :: ToJSON a => a -> T.Text
      encodeText=TE.decodeUtf8 . BL.toStrict . encode
      block=T.replicate 64 "a"
      position=object ["hash" .= block,"height" .= (100::Int)]
      plan=originalPlan {NP.planAmount=money 10,NP.planDepth=2,NP.planFeeLimit=money 5}
      previous key n=NP.NativePrevout (NP.Outpoint (T.replicate 64 key) 0) (money n) (NP.planChangeScript plan) 2 False
      shared=[previous "b" 60,previous "c" 40]
      member key raw inputs fee=NP.NativeSigned raw
        (NP.NativeTx (T.replicate 64 key) 2 0 [NP.NativeInput (NP.prevout p) 4294967294|p<-inputs]
          ([NP.NativeOutput (NP.planChangeScript plan) (money change)|change>0]
            <>[NP.NativeOutput (NP.planRecipientScript plan) (money 10)])) plan inputs (money fee)
        where change=sum(map (toInteger.units.NP.prevoutAmount) inputs)-10-fee
      parent=member "d" "70" shared 1
      child=member "e" "80" shared 2
      noChange=member "f" "90" [previous "9" 11] 1
      overlap=member "8" "a0" shared 1
      txid=NP.nativeTxid.NP.signedNativeTransaction
      draft s=NP.NativeDraft "offline-custody" (NP.signedNativeTransaction s) (NP.signedNativePrevouts s) (NP.signedNativeFee s)
      wire s=let p=NP.prevout $ head $ NP.signedNativePrevouts s in
        SignedAttempt (txid s) (NP.signedNativeBytes s) (encodeText s) (Just $ NP.outpointTxid p<>":"<>T.pack(show $ NP.outpointVout p))
      ready=fixture fixtures ReadyIntake
      paused=evalWrite writer (Pause "custody fixture") >> fixture fixtures RefreshCustody
      seed s=do
        paused
        void $ evalWrite writer (ReserveFees 100 (txid s) Native (money 10) (NP.planRecipient plan) "custody fixture")
        let identifier="fee:"<>txid s
        ready
        void $ evalWrite writer (PreparePayment 100 identifier (money 5) $ encodeText plan)
        evalWrite writer (SaveDraft identifier 0 $ encodeText $ draft s)
        prepared<-evalRead reader (ReadPreparation identifier)
        void $ evalWrite writer (RecordAttempt prepared $ wire s)
        ready
        void $ evalWrite writer (MarkBroadcast 100 $ txid s)
        pure identifier
      evidence s=fixture fixtures $ SeedTreasuryEvidence "Native" (txid s) "unconfirmed" "outgoing" 0
        (object ["confirmations" .= (0::Int),"walletNetUnits" .= ("-10"::T.Text),"feeUnits" .= NP.signedNativeFee s])
      settle s=do
        saved<-evalRead reader (ReadAttempt $ txid s)
        evalWrite writer (SettlePayment saved (W.PaymentCosts (NP.signedNativeFee s) (money 0)) $
          encodeText $ object ["blockhash" .= block,"requiredDepth" .= (2::Int)])
        fixture fixtures $ SeedTreasuryEvidence "Native" (txid s) block "outgoing" 0
          (object ["confirmations" .= (2::Int),"walletNetUnits" .= ("-10"::T.Text),"feeUnits" .= NP.signedNativeFee s])
      decoded s=let tx=NP.signedNativeTransaction s in object
        ["txid" .= txid s,"version" .= NP.nativeVersion tx,"locktime" .= NP.nativeLocktime tx
        ,"vin" .= [object ["txid" .= NP.outpointTxid p,"vout" .= NP.outpointVout p,"sequence" .= NP.nativeSequence i]
          |i<-NP.nativeInputs tx,let p=NP.nativeOutpoint i]
        ,"vout" .= [object ["n" .= i,"value" .= N.nativeNumber (NP.nativeOutputAmount o)
          ,"scriptPubKey" .= object ["hex" .= NP.nativeOutputScript o]]| (i,o)<-zip [0::Int ..] $ NP.nativeOutputs tx]]
      -- Retained members can be inactive, abandoned, or absent. The optional
      -- spender is independently read from gettxspendingprevout.
      call members retained abandoned active raw pending wallet method params=case (wallet,method,params) of
        (True,"getbalances",[])->pure $ object ["mine" .= object
          ["trusted" .= N.nativeNumber(money $ raw-pending),"untrusted_pending" .= N.nativeNumber(money pending)
          ,"immature" .= (0::Int)],"lastprocessedblock" .= position]
        (False,"getblockchaininfo",[])->pure $ object ["chain" .= ("signet"::T.Text),"initialblockdownload" .= False
          ,"blocks" .= (100::Int),"bestblockhash" .= block,"signet_challenge" .= N.signetChallenge]
        (False,"getblockhash",[Number 1])->pure $ String "scan-origin"
        (False,"getconnectioncount",[])->pure $ Number 1
        (True,"getwalletinfo",[])->pure $ object ["walletname" .= ("test"::T.Text),"descriptors" .= True
          ,"scanning" .= False,"avoid_reuse" .= False,"lastprocessedblock" .= position]
        (False,"decoderawtransaction",[String bytes])->case [s|s<-members,NP.signedNativeBytes s==bytes] of
          [s]->pure (decoded s); _->fail "unknown custody transaction bytes"
        (True,"gettransaction",[String identifier,Bool False,Bool True])->case [s|s<-members,txid s==identifier] of
          [s] | retained->pure $ object ["txid" .= identifier,"hex" .= NP.signedNativeBytes s,"decoded" .= decoded s
            ,"fee" .= Number (negate(fromIntegral $ units $ NP.signedNativeFee s)/100000000),"confirmations" .= (0::Int)
            ,"lastprocessedblock" .= position,"walletconflicts" .= ([]::[T.Text]),"mempoolconflicts" .= ([]::[T.Text])
            ,"trusted" .= False,"details" .= [object ["category" .= ("send"::T.Text),"abandoned" .= abandoned]]]
          [_]->reject "rpc_error_-5"
          _->fail "unknown custody transaction"
        (False,"gettxspendingprevout",[points])->do
          requested<-either fail pure $ eitherDecodeStrict' $ BL.toStrict $ encode points
          pure $ toJSON [object $ ["txid" .= NP.outpointTxid p,"vout" .= NP.outpointVout p]
            <>maybe [] (\identifier->["spendingtxid" .= identifier]) active | p<-(requested::[NP.Outpoint])]
        (False,"gettxout",[String identifier,Number index,Bool False])->case
          [p|s<-members,p<-NP.signedNativePrevouts s,NP.outpointTxid(NP.prevout p)==identifier
            ,toInteger(NP.outpointVout $ NP.prevout p)==round index] of
          p:_->pure $ object ["value" .= N.nativeNumber(NP.prevoutAmount p),"confirmations" .= (2::Int),"coinbase" .= False
            ,"scriptPubKey" .= object ["hex" .= NP.prevoutScript p,"address" .= NP.planChange plan]]
          _->fail "unknown custody prevout"
        (True,"getaddressinfo",[String address]) | address==NP.planChange plan->pure $ object
          ["ismine" .= True,"scriptPubKey" .= NP.planChangeScript plan]
        (False,"getmempoolentry",[String identifier]) | active==Just identifier->pure $ object ["vsize" .= (100::Int)]
        _->base wallet method params
      inspect native=inspectCustodyWith (pure 100) (pure ()) native solana Nothing settings config reader False
      assertReport members retained abandoned active raw pending excluded delta matches=do
        (_,_,actual,report)<-inspect $ call members retained abandoned active raw pending
        reported<-fieldValue "nativeWalletReported" report
        removed<-fieldValue "nativeWalletExcludedInputs" report
        assets<-fieldValue "assets" report :: IO [Value]
        nativeRows<-filterM (fmap (==Native) . fieldValue "asset") assets
        row<-case nativeRows of [r]->pure r; _->fail "native custody report row missing"
        inFlight<-fieldValue "inFlight" row
        observed<-fieldValue "observed" row
        difference<-fieldValue "difference" row
        let corrected=raw+sum(map (toInteger.units.NP.prevoutAmount) excluded)
        check (actual==matches && reported==T.pack(show raw)
          && removed==[object ["outpoint" .= NP.prevout p,"units" .= NP.prevoutAmount p]|p<-excluded]
          && inFlight==T.pack(show delta) && observed==T.pack(show corrected)
          && difference==T.pack(show $ corrected-2100-delta))
  first<-seed parent
  recorded<-evalRead reader (ReadAttempt $ txid parent)
  revision<-evalRead reader ReadCustodyRevision
  evalWrite writer (RecordCustody revision 100 (Just "custody_native_history_advanced") Nothing)
  evalRead reader ReadState >>= check . not . ledgerPaused
  expectStore "scanners_not_fresh" (evalWrite writer $ AuthorizeSend 100 $ txid parent)
  evalRead reader (ReadAttempt $ txid parent) >>= check . (==recorded)
  fixture fixtures (FreshAt 100)
  paused
  decision<-evalWrite writer (SaveReplacementDraft 100 recorded (draft child) "custody replacement")
  fixture fixtures CoverBackup
  fixture fixtures RefreshCustody
  void $ evalWrite writer (RecordReplacement 100 decision [(recorded,parent)] child)
  ready
  void $ evalWrite writer (MarkBroadcast 100 $ txid child)
  mapM_ evidence [parent,child]
  fixture fixtures (FreshAt 100)
  assertReport [parent,child] True False (Just $ txid parent) 2089 0 [] (-11) True
  assertReport [parent,child] True False (Just $ txid child) 2088 0 [] (-12) True
  -- Both replacement alternatives exclude the same two whole prevouts once.
  assertReport [parent,child] True False Nothing 2000 0 shared 0 True
  assertReport [parent,child] False False Nothing 2100 0 [] 0 True
  assertReport [parent,child] True True Nothing 2100 0 [] 0 True
  -- Never fit the correction to a balance gap: unexplained excess/deficit stays.
  assertReport [parent,child] True False Nothing 2100 0 shared 0 False
  assertReport [parent,child] True False Nothing 1999 0 shared 0 False
  expectStore "custody_native_pending_credit_unresolved" $ inspect $ call [parent,child] True False Nothing 2000 1
  settle child
  _<-seed noChange
  evidence noChange
  fixture fixtures (FreshAt 100)
  samples<-newIORef (0::Int)
  let transition wallet method params=do
        when (method=="getbalances") (modifyIORef' samples (+1))
        count<-readIORef samples
        call [noChange] True False (if count>=2 then Just $ txid noChange else Nothing) 2089 0 wallet method params
  -- An exact-output spend has no change: raw balance is identical before and
  -- after mempool admission, yet the accounting evidence must be rejected.
  expectStore "custody_native_view_changed" (inspect transition)
  settle noChange
  _<-seed overlap
  -- The intact schema refuses reopening the settled family; the active-chain
  -- unique index is exercised separately by the root constraint contract.
  conflicting<-try (fixture fixtures $ ReactivatePayment first) :: IO (Either PG.SqlError ())
  check (case conflicting of
    Left problem->PG.sqlState problem=="23514" && "invalid_payment_phase_transition" `BS.isInfixOf` PG.sqlErrorMsg problem
    Right ()->False)

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
        "contract" key key 8 (money 2) (money 1000) (M.fromList [("NativeToWrapped",100),("WrappedToNative",100)]) False False (W.Availability False "starting") Nothing
      customerSettings=CustomerSettings public storePolicy "/unused/sdk"
      endpoint=SigningEndpoint 9443 "/unused/auth"
  bracket (newManager defaultManagerSettings {managerModifyRequest= \_ -> reject "offline_process_rpc"}) closeManager $ \manager->do
    forM_ [False,True] $ \paying->
      withWorkerProcess manager reader writer chainSettings config
        (Just customerSettings {publicConfiguration=public {W.pubIntakeEnabled=paying}}) endpoint $ \port directory->
        bracket (newManager defaultManagerSettings) closeManager $ \client->do
          let control=Control.callControl directory
              request method path body=do
                wire<-HTTP.parseRequest ("http://127.0.0.1:"<>show port<>path)
                HTTP.httpLbs wire {HTTP.method=method,HTTP.requestHeaders=[("Content-Type","application/json"),("Authorization",TE.encodeUtf8 header)]
                  ,HTTP.requestBody=HTTP.RequestBodyLBS body} client
              decodeReply response=either fail pure (eitherDecodeStrict' $ BL.toStrict $ HTTP.responseBody response)
          status<-control (object ["operation" .= ("status"::T.Text)])
          service<-either fail pure (eitherDecodeStrict' $ BL.toStrict $ encode status)
          check (W.paused service)
          savedResponse<-request "GET" ("/api/v1/orders/"<>T.unpack wrapId) ""
          saved<-decodeReply savedResponse
          current<-evalRead reader (ReadOrder header wrapId)
          check (statusCode(HTTP.responseStatus savedResponse)==200 && saved==current
            && W.orderId saved==W.orderId recovered && W.quote saved==W.quote recovered
            && W.depositInstruction saved==W.depositInstruction recovered)
          replayResponse<-request "POST" "/api/v1/orders" (encode wrapping)
          if paying then do
            replay<-decodeReply replayResponse
            check (statusCode(HTTP.responseStatus replayResponse)==200 && replay==saved)
            let withdrawal=T.replicate 64 "a"
                withdraw n asset=control $ object ["operation" .= ("withdraw-fees"::T.Text),"id" .= withdrawal
                  ,"asset" .= asset,"amount" .= money n,"recipient" .= ("recipient"::T.Text),"reason" .= ("test owned revenue"::T.Text)]
                cancel reason=control $ object ["operation" .= ("cancel-fees"::T.Text),"id" .= withdrawal,"reason" .= (reason::T.Text)]
            withdraw 100 Native >>= check . (==String ("fee:"<>withdrawal))
            cancel "cancel" >>= check . (==String ("fee:"<>withdrawal))
            withdraw 101 Native >>= check . (==object ["error" .= ("fee_withdrawal_conflict"::T.Text)])
            cancel "changed" >>= check . (==object ["error" .= ("fee_withdrawal_cancellation_conflict"::T.Text)])
            withdraw 1 Sol >>= check . (==object ["error" .= ("invalid_fee_withdrawal"::T.Text)])
          else do
            refused<-decodeReply replayResponse
            check (statusCode(HTTP.responseStatus replayResponse)==409 && refused==object ["error" .= ("observation_only"::T.Text)])
            instructions<-request "POST" ("/api/v1/orders/"<>T.unpack oid<>"/transaction") ""
            denied<-decodeReply instructions
            check (statusCode(HTTP.responseStatus instructions)==409 && denied==object ["error" .= ("deposit_window_closed"::T.Text)])
          control (object ["operation" .= ("pause"::T.Text),"reason" .= ("operator contract"::T.Text)]) >> pure ()
    expectStore "customer_configuration_mismatch" $
      runProcess manager reader (WorkerProcess chainSettings config
        (Just customerSettings {publicConfiguration=public {W.pubMint="wrong"}}) endpoint writer 1 "/unused" "/unused")

  -- A slow checkpoint neither exposes stale instructions nor renews a quote.
  -- Clock/freshness changes are fixtures; this is a PostgreSQL workflow contract.
  fixture fixtures ReadyIntake
  fixture fixtures (FreshAt 100)
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
        let uncertain n=do
              advance n
              -- A separate reader must still see the previous committed sequence.
              visible<-evalRead reader ReadState
              check (ledgerSequence visible==1)
              bytes<-BS.readFile (directory</>"sequence.json")
              watermark<-either fail pure (eitherDecodeStrict' bytes)
              fieldValue "sequence" watermark >>= check . (==n)
              when (n==2) (reject "injected_uncertain_commit")
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
-- Test lifetimes expose only real transports, never a runtime evaluator.
freePort :: IO Int
freePort=bracket (NS.socket NS.AF_INET NS.Stream NS.defaultProtocol) NS.close $ \socket->do
  NS.bind socket (NS.SockAddrInet 0 (NS.tupleToHostAddress (127,0,0,1)))
  address<-NS.getSocketName socket
  case address of NS.SockAddrInet port _->pure (fromIntegral port); _->fail "unexpected listener address"

awaitCondition :: String -> IO Bool -> IO ()
awaitCondition label condition=do
  result<-timeout 120000000 loop
  unless (result==Just ()) (fail $ "timed out: "<>label)
 where loop=condition >>= \ready->unless ready (threadDelay 100000 >> loop)

withProcessListening :: IO () -> Int -> IO a -> IO a
withProcessListening process port action=withAsync process $ \child->do
  awaitCondition "process listener" $ do
    status<-poll child
    case status of
      Just (Left problem)->throwIO problem
      Just (Right ())->fail "process exited before listener"
      Nothing->do
        result<-try $ bracket (NS.socket NS.AF_INET NS.Stream NS.defaultProtocol) NS.close $ \socket->
          NS.connect socket (NS.SockAddrInet (fromIntegral port) (NS.tupleToHostAddress (127,0,0,1)))
        pure (case result::Either IOException () of Right ()->True; Left _->False)
  action

withWorkerProcess :: HTTP.Manager -> Reader -> Writer -> ObserverSettings -> H.SolanaPolicy
  -> Maybe CustomerSettings -> SigningEndpoint -> (Int -> FilePath -> IO a) -> IO a
withWorkerProcess manager reader writer settings policy customer endpoint action=withTestSigningKey $ \key->do
  let directory=takeDirectory key; assets=directory</>"assets"
  createDirectory assets; createDirectory (assets</>"dist")
  mapM_ (\file->writeFile (assets</>file) "process contract fixture") ["index.html","style.css","dist/wallet.js"]
  port<-freePort
  withProcessListening (runProcess manager reader $ WorkerProcess settings policy customer endpoint writer port assets directory)
    port $ do
      awaitCondition "operator listener" $ do
        exists<-Posix.fileExist (directory</>"operator.sock")
        if not exists then pure False else do
          status<-Posix.getSymbolicLinkStatus (directory</>"operator.sock")
          if Posix.fileMode status .&. 0o077/=0 then pure False else do
            reply<-try (Control.callControl directory $ object ["operation" .= ("status"::T.Text)]) :: IO (Either IOException Value)
            pure (case reply of Right _->True; Left _->False)
      action port directory

makeCertificate :: FilePath -> IO ()
makeCertificate file=do
  (exit,_,err)<-Process.readProcessWithExitCode "openssl" ["req","-x509","-newkey","rsa:2048","-nodes","-keyout",file<>".key","-out",file<>".pem","-days","1","-subj","/CN=127.0.0.1","-addext","subjectAltName=IP:127.0.0.1"] ""
  unless (exit==ExitSuccess) (fail err)
  setFileMode (file<>".key") 0o600

signingEndpoint :: FilePath -> IO SigningEndpoint
signingEndpoint directory=do
  let auth=directory</>"auth"
  writeFile auth (replicate 64 'a'); setFileMode auth 0o600
  makeCertificate auth
  port<-freePort
  pure (SigningEndpoint port auth)

withSigningClient :: SigningEndpoint -> (HTTP.Manager -> IO a) -> IO a
withSigningClient=withSigningClientSettings id

withSigningClientSettings :: (HTTP.ManagerSettings -> HTTP.ManagerSettings) -> SigningEndpoint -> (HTTP.Manager -> IO a) -> IO a
withSigningClientSettings configure endpoint action=do
  certificate<-signerCertificate endpoint
  let base=TLS.defaultParamsClient "127.0.0.1" BS.empty
      tls=base {TLS.clientShared=(TLS.clientShared base) {TLS.sharedCAStore=makeCertificateStore [certificate]}
        ,TLS.clientSupported=(TLS.clientSupported base) {TLS.supportedCiphers=ciphersuite_default}}
      settings=HTTP.managerSetProxy HTTP.noProxy (mkManagerSettings (NC.TLSSettings tls) Nothing)
        {HTTP.managerRetryableException=const False,HTTP.managerIdleConnectionCount=0
        ,HTTP.managerResponseTimeout=HTTP.responseTimeoutMicro 60000000}
  bracket (newManager $ configure settings) closeManager action

signerPost :: ToJSON a => HTTP.Manager -> SigningEndpoint -> String -> a -> IO (HTTP.Response BL.ByteString)
signerPost manager endpoint path body=do
  BasicAuthData user token<-signerCredentials endpoint
  request<-HTTP.parseRequest ("https://127.0.0.1:"<>show(signerPort endpoint)<>path)
  HTTP.httpLbs request {HTTP.method="POST",HTTP.redirectCount=0
    ,HTTP.requestHeaders=[("Content-Type","application/json"),("Authorization","Basic "<>B64.encode (user<>":"<>token))]
    ,HTTP.requestBody=HTTP.RequestBodyLBS (encode body)} manager

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
  canonical<-(==Just "1") <$> lookupEnv "ECX_REBUILD_CANONICAL"
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
    let network=if canonical then base {Config.profile=W.CanonicalBeta,Config.backupRequired=True,
          Config.nativeCheckpointHeight=967680,Config.nativeCheckpointHash="00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042",
          Config.mint="EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq",Config.solanaVerifierRpc=Just "https://localhost:1"} else base
        config=network {Config.serverPort=port,Config.fenceDirectory=directory<>"/fence",
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
    withReader settings {PG.connectUser=role} identity (Config.backupRequired config) $ \reader->do
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
                && W.pubProfile decoded==Config.profile config && W.pubMint decoded==Config.mint config
                && W.pubSolanaCluster decoded==(if canonical then "mainnet-beta" else "devnet")
                && W.pubAvailability decoded==W.Availability False "observation_only")
              orderRequest<-HTTP.parseRequest ("http://127.0.0.1:"<>show port<>"/api/v1/orders")
              deniedOrder<-HTTP.httpLbs orderRequest {HTTP.method="POST"
                ,HTTP.requestHeaders=[("Content-Type","application/json"),("Authorization","Bearer "<>BS.replicate 64 97)]
                ,HTTP.requestBody=HTTP.RequestBodyLBS $ encode $
                  W.OrderRequest WrappedToNative (money 10000) "recipient" "" Nothing "observer-contract"} manager
              deniedBody<-either fail pure (eitherDecodeStrict' $ BL.toStrict $ HTTP.responseBody deniedOrder)
              check (statusCode(HTTP.responseStatus deniedOrder)==409
                && deniedBody==object ["error" .= ("observation_only"::T.Text)])
              bracket (PG.connect settings) PG.close $ \connection->do
                (rows,attempts,_)<-fixture connection ArchiveRecords
                counts<-fixture connection OrderSnapshot
                check (counts==[0,0,0,0] && null attempts && case rows of [row]->S.criticalSequence row==0; _->False)
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
              (denied,empty,diagnostic)<-Process.readCreateProcessWithExitCode (Process.proc binary ["operator",filename])
                "{\"operation\":\"resume\"}"
              check (denied/=ExitSuccess && null empty)
              cliError<-either fail pure (eitherDecodeStrict' $ TE.encodeUtf8 $ T.pack diagnostic)
              check (cliError==object ["error" .= ("observation_only"::T.Text)])
              evalRead reader ReadBalances >>= check . (==before)
      -- Mainnet paying mode uses the same CLI/resource assembly. Unavailable
      -- chains still leave it paused and unable to create a fresh order.
      when canonical $ bracket (newManager defaultManagerSettings) closeManager $ \manager->
        withFile (directory<>"/paying.log") WriteMode $ \logFile->
          Process.withCreateProcess (Process.proc binary ["serve",filename])
            {Process.env=Just childEnv,Process.std_out=Process.UseHandle logFile,Process.std_err=Process.UseHandle logFile} $ \_ _ _ process->
            flip finally (Process.terminateProcess process >> void (Process.waitForProcess process)) $ do
              let request path=HTTP.parseRequest ("http://127.0.0.1:"<>show port<>path)
              awaitCondition "canonical paying server" $ do
                alive<-Process.getProcessExitCode process
                check (alive==Nothing)
                result<-try (request "/api/v1/config" >>= flip HTTP.httpLbs manager) :: IO (Either HTTP.HttpException (HTTP.Response BL.ByteString))
                pure $ case result of Right _->True; _->False
              reply<-request "/api/v1/config" >>= flip HTTP.httpLbs manager
              public<-either fail pure (eitherDecodeStrict' $ BL.toStrict $ HTTP.responseBody reply)
              check (W.pubIntakeEnabled public && W.pubProfile public==W.CanonicalBeta
                && W.pubSolanaCluster public=="mainnet-beta" && not(W.available $ W.pubAvailability public))
              wire<-request "/api/v1/orders"
              denied<-HTTP.httpLbs wire {HTTP.method="POST",HTTP.requestHeaders=[("Content-Type","application/json"),("Authorization","Bearer "<>BS.replicate 64 97)]
                ,HTTP.requestBody=HTTP.RequestBodyLBS $ encode $
                  W.OrderRequest WrappedToNative (money 10000) "recipient" "" Nothing "canonical-paused"} manager
              check (statusCode(HTTP.responseStatus denied)==409 && eitherDecodeStrict' (BL.toStrict $ HTTP.responseBody denied)
                ==Right (object ["error" .= ("intake_paused"::T.Text)]))
              evalRead reader ReadBalances >>= check . (==before)
              evalRead reader PendingAttempts >>= check . null
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
  stateBeforeReport<-evalRead reader ReadState
  reportBefore<-evalRead reader (ReadPublicReport 110)
  let fees report=[(W.reportAsset row,W.reportFees row)|row<-W.reportAssets report]
      counts report=(W.reportWraps24h report,W.reportUnwraps24h report,W.reportUndatedTransfers report)
  check (lookup Native (fees reportBefore)==Just "7" && W.reportWraps24h reportBefore==1
    && W.reportUnwraps24h reportBefore==0 && W.reportUndatedTransfers reportBefore==0)
  evalRead reader ReadState >>= check . (==stateBeforeReport)
  expiredReport<-evalRead reader (ReadPublicReport $ W.reportGeneratedAt reportBefore+86400)
  check (W.reportWraps24h expiredReport==0 && W.reportUnwraps24h expiredReport==0)
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
  reportAfter<-evalRead reader (ReadPublicReport 110)
  check (fees reportAfter==fees reportBefore && counts reportAfter==counts reportBefore
    && not(W.reportCustodyFresh reportAfter))
  expectStore "pause_before_operator_action" (evalWrite writer $ RepairCompletedOrderView 110 paidOrder)
  evalWrite writer (Pause "repair historical refund view")
  expectStore "custody_not_reconciled" (evalWrite writer $ RepairCompletedOrderView 110 paidOrder)
  fixture fixtures RefreshCustody
  beforeRepair<-evalRead reader ReadState
  evalWrite writer (RepairCompletedOrderView 110 paidOrder)
  unchanged
  evalRead reader ReadBalances >>= check . (==afterRefund)
  afterRepair<-evalRead reader ReadState
  check (ledgerPaused afterRepair && ledgerSequence afterRepair==ledgerSequence beforeRepair)
  evalWrite writer (RepairCompletedOrderView 110 paidOrder)
  evalRead reader ReadState >>= check . (==afterRepair)
  expectStore "completed_order_repair_not_proven" (evalWrite writer $ RepairCompletedOrderView 110 "unknown-order")

orderedRefundContract :: PG.Connection -> Reader -> Writer -> IO ()
orderedRefundContract fixtures reader writer=do
  -- Two receipts can be refunded successively without a conversion. While the
  -- second is active, preserve the first link; once settled, select the second
  -- by its original principal event, independently of transaction-name ordering.
  let header="Bearer "<>T.replicate 64 "0"
      check ok=unless ok (fail "ordered refund projection contract failed")
  requested<-lookupEnv "ECX_REBUILD_HISTORY_COUNT"
  count<-case requested of
    Nothing->pure 2
    Just raw | Just n<-readMaybe raw, n>=2 && n<=2000->pure n
    _->fail "history workload count must be between 2 and 2000"
  let transactions=take count $ ["z-first","a-second"]<>["history-"<>T.pack(show n) | n<-[3::Int ..]]
      observed transaction review=fixture fixtures $ SeedTreasuryEvidence "Native" transaction "fixture-anchor" "outgoing" review
        (object ["confirmations" .= (2::Int)])
  fixture fixtures ReadyIntake
  ordered<-evalWrite writer (CreateOrder 110 header $ W.OrderRequest NativeToWrapped (money 10) "recipient" "native-refund" Nothing "refund-ordered")
  claim<-evalWrite writer (ClaimNative 110 header ordered)
  void $ evalWrite writer (RecordNative header ordered (allocationLabel claim) "ordered-refund-address")
  forM_ (zip3 [1::Int ..] transactions (Nothing:map Just transactions)) $ \(index,transaction,previous)->do
    let sourceId="ordered:"<>transaction
        n=if index==1 then 9 else 3
        view=evalRead reader (ReadOrder header ordered)
    fixture fixtures (SeedReceipt sourceId (Just ordered) Native n 2 True 110)
    evalWrite writer (Pause "ordered refunds")
    fixture fixtures RefreshCustody
    authorized<-evalWrite writer (AuthorizeRefund 110 sourceId)
    view >>= \v->check (W.status v=="Refunding" && W.payoutTx v==previous)
    fixture fixtures ReadyIntake
    void $ evalWrite writer (PreparePayment 110 (W.refundPayment authorized) (money 1) "{}")
    view >>= \v->check (W.status v=="Preparing" && W.payoutTx v==previous)
    evalWrite writer (SaveDraft (W.refundPayment authorized) 0 "{}")
    fixture fixtures CoverBackup
    fixture fixtures ReadyIntake
    prepared<-evalRead reader (ReadSigningDecision 110 (W.refundPayment authorized) 0)
    void $ evalWrite writer (RecordAttempt prepared $ SignedAttempt transaction "ordered-refund-fixture-bytes" "{}" (Just $ transaction<>"-input:0"))
    view >>= \v->check (W.status v=="Paying" && W.payoutTx v==previous)
    fixture fixtures ReadyIntake
    void $ evalWrite writer (MarkBroadcast 110 transaction)
    fixture fixtures CoverBackup
    fixture fixtures ReadyIntake
    queued<-evalWrite writer (AuthorizeSend 110 transaction)
    observed transaction 0
    let settle=SettlePayment queued (W.PaymentCosts (money 1) (money 0)) "{\"offlineOrderedRefund\":true,\"blockhash\":\"fixture-anchor\",\"requiredDepth\":2}"
    evalWrite writer settle
    view >>= \v->check (W.status v=="Refunded" && W.payoutTx v==Just transaction)
    settled<-evalRead reader ReadBalances
    evalWrite writer settle
    evalRead reader ReadBalances >>= check . (==settled)
    when (count>2 && (index `elem` [1,10,100,1000] || index==count)) $ do
      -- Exercise actual closed reads across the 1000-row page boundary. Fixture
      -- outcomes are deliberately offline; there is no chain RPC or signing.
      started<-getMonotonicTimeNSec
      forM_ [1::Int ..10] $ \_->view >>= \v->check (W.status v=="Refunded" && W.payoutTx v==Just transaction)
      finished<-getMonotonicTimeNSec
      putStrLn ("WORKLOAD: refunds="<>show index<>" mean ReadOrder ms="<>show (fromIntegral(finished-started)/10000000::Double))
  -- Healthy lifetime history is not a recovery backlog. More than 1000
  -- unresolved observations still refuse rather than silently skipping work.
  when (count>1000) $ bracket_ (mapM_ (`observed` 1) transactions) (mapM_ (`observed` 0) transactions) $
    expectStore "native_settlement_recovery_backlog" (evalRead reader NativeSettlementCandidates)
  evalRead reader NativeSettlementCandidates >>= check . all ((`notElem` transactions) . signedId . recordedSigned)

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

-- Real signer/worker process lifetimes and HTTPS over public offline vectors.
-- RPC responses and ledger funding are explicit fixtures, not live acceptance.
tlsMain :: IO ()
tlsMain=do
  canonical<-(==Just "1") <$> lookupEnv "ECX_REBUILD_CANONICAL"
  database<-getEnv "ECX_REBUILD_CONTRACT_DATABASE"
  unless ("ecx_rebuild_contract_" `T.isPrefixOf` T.pack database) (fail "disposable database required")
  user<-getEnv "USER"; role<-getEnv "ECX_REBUILD_CONTRACT_READER"; sdk<-getEnv "ECX_REBUILD_TEST_SDK"
  vector<-getDataFileName "test/fixtures/signed-three-units.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  workflow<-getDataFileName "test/fixtures/signed-payment-workflow.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  owner<-fieldValue "owner" vector; recipient<-fieldValue "recipient" vector; vectorMint<-fieldValue "mint" vector; hash<-fieldValue "blockhash" vector
  vectorReply<-fieldValue "reply" workflow :: IO H.HelperReply
  identifier<-fieldValue "paymentId" workflow
  let profile=if canonical then W.CanonicalBeta else W.L2LSignetDevnet
      cluster=if canonical then "mainnet-beta" else "devnet"
      mint=if canonical then "EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq" else vectorMint
      -- Classic SPL ATA for the public fixture owner and canonical mint, derived
      -- by the token tool. The SDK independently derives and checks it below.
      custody=if canonical then "Jon9rntk6G8BftwW1nRqkSf54iqXaqDD6a2ZSky2bWW" else H.replySource vectorReply
      identity="offline-policy"; encoded value=TE.decodeUtf8 (BL.toStrict $ encode value)
      settings=PG.defaultConnectInfo {PG.connectHost="/tmp/ecx-pg-seam",PG.connectPort=29436,PG.connectUser=user,PG.connectDatabase=database}
      policy=PaymentTerms (PolicySnapshot 1 "finalized" identity) (CostLimits (money 1) (money 10000) (money 2100000))
      store=StorePolicy policy (OrderLimits (money 2) (money 1000) 100 100 100 (money 10000000) (money 10000000)) "codec-fixture" True
      config=H.SolanaPolicy "codec-fixture" identity mint owner custody (money 10000) (money 2100000)
      plan=SP.SolanaPlan identity recipient (money 3) (payoutReference identity identifier) (SP.RecentBlockhash hash 1000 100) (money 10000) (money 2100000)
      native=N.NativeSettings profile "http://127.0.0.1:1" "/unused" "ecx-bridge-test"
        (if canonical then 967680 else 16000)
        (if canonical then "00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042" else "00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47")
      solana=Solana.SolanaSettings profile "https://primary.example" (if canonical then Just "https://verifier.example" else Nothing) mint owner custody
      check :: HasCallStack => Bool -> IO ()
      check ok=unless ok (fail $ "TLS signing contract failed\n"<>prettyCallStack callStack)
      context value=object ["context" .= object ["slot" .= (100::Int)],"value" .= value]
      token=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::T.Text),"info" .= object
        ["mint" .= mint,"owner" .= owner,"state" .= ("initialized"::T.Text),"isNative" .= False,"tokenAmount" .= object ["amount" .= ("10000000"::T.Text),"decimals" .= (8::Int)]]]]]
      mintAccount=object ["owner" .= Solana.tokenProgram,"executable" .= False,"data" .= object ["space" .= (82::Int),"parsed" .= object ["type" .= ("mint"::T.Text),"info" .= object
        ["decimals" .= (8::Int),"isInitialized" .= True,"freezeAuthority" .= Null,"mintAuthority" .= Null,"supply" .= ("10000000"::T.Text)]]]]
      payer=object ["owner" .= ("11111111111111111111111111111111"::T.Text),"executable" .= False,"data" .= ["","base64"::T.Text],"lamports" .= (10000000::Int)]
  reply<-if not canonical then pure vectorReply else do
    -- The expected signature is computed independently from the unsigned SDK
    -- message with the public fixture seed. Actual signing must still traverse
    -- HTTPS and the gated critical evaluator below. No transaction is submitted.
    preview<-H.invokeUnsignedHelper sdk config (SP.solanaPayoutRequest config plan)
    message<-either fail pure (B64.decode $ TE.encodeUtf8 $ H.replyMessage preview)
    secret<-case Ed.secretKey (BS.replicate 32 1) of CryptoPassed key->pure key; CryptoFailed _->fail "invalid public fixture seed"
    let signature=BA.convert (Ed.sign secret (Ed.toPublic secret) message) :: BS.ByteString
        expected=preview {H.replySignature=Just $ SolanaMessage.base58 signature,
          H.replyTransaction=TE.decodeUtf8 $ B64.encode $ BS.singleton 1<>signature<>message}
    _<-either reject pure (H.validateHelperReply config (SP.solanaPayoutRequest config plan) expected)
    pure expected
  calls<-newIORef ([]::[T.Text])
  barrier<-newIORef Nothing
  let rpcApplication request respond=do
        raw<-Wai.strictRequestBody request
        value<-either fail pure (eitherDecodeStrict' $ BL.toStrict raw)
        method<-fieldValue "method" value; params<-fieldValue "params" value :: IO [Value]; requestId<-fieldValue "id" value :: IO Value
        when (method=="getGenesisHash") $ do
          blocked<-atomicModifyIORef' barrier (\old->(Nothing,old))
          forM_ blocked $ \(entered,release)->putMVar entered () >> takeMVar release
        modifyIORef' calls (<>[method])
        result<-case method of
          "getblockchaininfo"->pure $ object $ ["chain" .= (if canonical then "main" else "signet"::T.Text),"initialblockdownload" .= False
            ,"blocks" .= N.nativeCheckpointHeight native] <> if canonical then [] else ["signet_challenge" .= N.signetChallenge]
          "getblockhash"->pure $ String (N.nativeCheckpointHash native)
          "getconnectioncount"->pure $ Number 1
          "getwalletinfo"->pure $ object ["walletname" .= N.nativeWallet native,"descriptors" .= True
            ,"scanning" .= False,"private_keys_enabled" .= True,"external_signer" .= False]
          "getSignatureStatuses"->pure Null -- Deliberate unavailable observation, never a successful chain effect.
          "getGenesisHash"->pure $ toJSON (Solana.solanaGenesis profile)
          "getAccountInfo"->pure $ context $ if take 1 params==[toJSON mint] then mintAccount else token
          "getBlockHeight"->pure $ Number 900
          "getMultipleAccounts"->pure $ context $ toJSON [token,Null,payer]
          "getMinimumBalanceForRentExemption"->pure $ Number 1488440
          "getFeeForMessage"->pure $ context $ Number 5000
          "simulateTransaction"->pure $ context $ object ["err" .= Null]
          _->pure Null -- Unavailable scan/custody replies must not abort the fixture server.
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
          let directory=takeDirectory keyFile
          endpoint<-signingEndpoint directory
          let auth=signerAuthFile endpoint
          makeCertificate (directory<>"/untrusted")
          certificate<-BS.readFile (auth<>".pem")
          untrusted<-BS.readFile (directory<>"/untrusted.pem")
          -- Actual HTTPS responseOpen/JSON-RPC integration: exactly one pacing
          -- admission per request, including a retried read but no retry of send.
          ticks<-newIORef 0; starts<-newIORef []; requests<-newIORef (0::Int)
          paced<-rpcManagerSettings 2 (readIORef ticks) (\us->modifyIORef' ticks (+toInteger us*1000))
          let rateApplication request respond=do
                void (Wai.strictRequestBody request)
                n<-atomicModifyIORef' requests (\old->(old+1,old+1))
                let result=if n==2 then ["result" .= ("fixture"::T.Text)] else ["error" .= object ["code" .= (429::Int)]]
                respond $ Wai.responseLBS status200 [("Content-Type","application/json"),("Retry-After","1")]
                  (encode $ object $ ["jsonrpc" .= ("2.0"::T.Text),"id" .= (1::Int)]<>result)
              pacedSettings base=base {HTTP.managerWrapException= \request action->
                HTTP.managerWrapException paced request (readIORef ticks >>= \now->modifyIORef' starts (<>[now]) >> action)}
          withProcessListening (runSigningServer endpoint rateApplication) (signerPort endpoint) $
            withSigningClientSettings pacedSettings endpoint $ \client->do
              let call=rpc client ("https://127.0.0.1:"<>show(signerPort endpoint)) Nothing
              call "getGenesisHash" [] >>= check . (==String "fixture")
              expectStore "rpc_rate_limited" (call "sendTransaction" [])
              readIORef requests >>= check . (==3)
              readIORef starts >>= check . (==[0,500000000,1000000000])
          writeIORef starts []; writeIORef requests 0
          let closingApplication request respond=do
                void (Wai.strictRequestBody request)
                n<-atomicModifyIORef' requests (\old->(old+1,old+1))
                respond $ if n==2 then Wai.responseLBS status200 [("Content-Type","application/json")]
                  (encode $ object ["jsonrpc" .= ("2.0"::T.Text),"id" .= (1::Int),"result" .= ("fixture"::T.Text)])
                  else Wai.responseRaw (\_ _->pure ()) (Wai.responseLBS status500 [] "raw transport required")
          withProcessListening (runSigningServer endpoint closingApplication) (signerPort endpoint) $
            withSigningClientSettings pacedSettings endpoint $ \client->do
              let call=rpc client ("https://127.0.0.1:"<>show(signerPort endpoint)) Nothing
              call "getGenesisHash" [] >>= check . (==String "fixture")
              expectStore "rpc_transport_unknown_outcome" (call "sendTransaction" [])
              expectStore "rpc_transport_unknown_outcome" (call "futureMethod" [])
              readIORef requests >>= check . (==4)
              readIORef starts >>= check . (==[1500000000,2000000000,2500000000,3000000000])
          Warp.testWithApplication (pure rpcApplication) $ \rpcPort->
            bracket (newManager defaultManagerSettings {managerModifyRequest= \request->pure request {HTTP.secure=False,HTTP.host="127.0.0.1",HTTP.port=rpcPort}}) closeManager $ \manager->do
              let post client=signerPost client endpoint "/sign-preparation" (identity,identifier,0::Int)
                  signedResponse response=do
                    unless (statusCode(HTTP.responseStatus response)==200) $
                      fail ("expected signed result, got "<>show(HTTP.responseStatus response)<>" "<>show(HTTP.responseBody response))
                    Op.preparedOutput <$> either fail pure (eitherDecodeStrict' $ BL.toStrict $ HTTP.responseBody response)
              when canonical $ do
                let signing=SignerSettings native solana config sdk keyFile Nothing Nothing
                    start configured=runProcess manager reader (SignerProcess configured endpoint)
                expectStore "canonical_identity_or_verifier_required" $
                  start signing {signingSolana=solana {Solana.solanaVerifierRpc=Nothing}}
                expectStore "independent_rpc_required" $
                  start signing {signingSolana=solana {Solana.solanaVerifierRpc=Just $ Solana.solanaRpc solana}}
                expectStore "signer_profile_mismatch" $
                  start signing {signingNative=native {N.profile=W.ECXBetanetDevnet}}
                readIORef calls >>= check . null
              withProcessListening (runProcess manager reader $ SignerProcess
                (SignerSettings native solana config sdk keyFile Nothing Nothing) endpoint) (signerPort endpoint) $ do
                writeFile auth (replicate 64 'b')
                withSigningClient endpoint $ \client->post client >>= check . (==403) . statusCode . HTTP.responseStatus
                readIORef calls >>= check . null
                evalRead reader PendingAttempts >>= check . null
                writeFile auth (replicate 64 'a')
                BS.writeFile (auth<>".pem") untrusted
                untrustedReply<-try (withSigningClient endpoint post) :: IO (Either HTTP.HttpException (HTTP.Response BL.ByteString))
                check (case untrustedReply of Left _->True; Right _->False)
                readIORef calls >>= check . null
                BS.writeFile (auth<>".pem") certificate
                before<-evalRead reader ReadBalances
                -- Both requests are real HTTPS clients. While the first signer
                -- owns the gate, the second cannot enter the first RPC method.
                signed<-withSigningClient endpoint $ \client->do
                  entered<-newEmptyMVar; release<-newEmptyMVar
                  writeIORef barrier (Just (entered,release))
                  flip finally (void $ tryPutMVar release ()) $ withAsync (post client) $ \first->do
                    timeout 5000000 (takeMVar entered) >>= check . (==Just ())
                    withAsync (post client) $ \second->do
                      threadDelay 100000
                      readIORef calls >>= check . null
                      waiting<-poll second
                      check (case waiting of Nothing->True; _->False)
                      putMVar release ()
                      a<-wait first >>= signedResponse
                      b<-wait second >>= signedResponse
                      check (a==b && Just(signedId a)==H.replySignature reply && signedBytes a==H.replyTransaction reply)
                      pure a
                evalRead reader PendingAttempts >>= check . null
                evalRead reader ReadBalances >>= check . (==before)
                -- A decision changed after admission must not release a result.
                withSigningClient endpoint $ \client->do
                  entered<-newEmptyMVar; release<-newEmptyMVar
                  writeIORef barrier (Just (entered,release))
                  flip finally (void $ tryPutMVar release ()) $ withAsync (post client) $ \request->do
                    timeout 5000000 (takeMVar entered) >>= check . (==Just ())
                    fixture fixtures StaleCustody
                    putMVar release ()
                    refused<-wait request
                    check (statusCode(HTTP.responseStatus refused)==409 &&
                      eitherDecodeStrict' (BL.toStrict $ HTTP.responseBody refused)==Right (object ["error" .= ("custody_not_reconciled"::T.Text)]))
                  clock<-floor <$> getPOSIXTime
                  fixture fixtures (FreshAt clock)
                  post client >>= signedResponse >>= check . (==signed)
                decision<-evalRead reader (ReadPreparation identifier)
                saved<-evalWrite writer (RecordAttempt decision signed)
                evalWrite writer (RecordAttempt decision signed) >>= check . (==saved)
                check (recordedState saved=="signed")
                fixture fixtures CoverBackup
                clock<-floor <$> getPOSIXTime
                fixture fixtures (FreshAt clock)
                count<-length <$> readIORef calls
                withSigningClient endpoint $ \client->do
                  repeated<-post client
                  check (statusCode(HTTP.responseStatus repeated)==409 &&
                    eitherDecodeStrict' (BL.toStrict $ HTTP.responseBody repeated)==Right (object ["error" .= ("attempt_already_recorded"::T.Text)]))
                readIORef calls >>= check . (==count) . length
                evalRead reader ReadBalances >>= check . (==before)
                methods<-readIORef calls
                check ("simulateTransaction" `elem` methods && "sendTransaction" `notElem` methods)
              -- Rotation requires a restart: old trust and old authentication
              -- must each fail independently, while saved signing stays refused.
              withSigningClient endpoint $ \oldClient->do
                let oldAuth=directory</>"old-auth"
                writeFile oldAuth (replicate 64 'a'); setFileMode oldAuth 0o600
                writeFile auth (replicate 64 'b')
                makeCertificate auth
                stateBefore<-evalRead reader ReadState
                pendingBefore<-evalRead reader PendingAttempts
                callsBefore<-readIORef calls
                withProcessListening (runProcess manager reader $ SignerProcess
                  (SignerSettings native solana config sdk keyFile Nothing Nothing) endpoint) (signerPort endpoint) $ do
                  staleTrust<-try (post oldClient) :: IO (Either HTTP.HttpException (HTTP.Response BL.ByteString))
                  check (case staleTrust of Left _->True; Right _->False)
                  withSigningClient endpoint $ \client->do
                    signerPost client endpoint {signerAuthFile=oldAuth} "/sign-preparation" (identity,identifier,0::Int)
                      >>= check . (==403) . statusCode . HTTP.responseStatus
                    current<-post client
                    check (statusCode(HTTP.responseStatus current)==409 &&
                      eitherDecodeStrict' (BL.toStrict $ HTTP.responseBody current)==Right (object ["error" .= ("attempt_already_recorded"::T.Text)]))
                evalRead reader ReadState >>= check . (==stateBefore)
                evalRead reader PendingAttempts >>= check . (==pendingBefore)
                readIORef calls >>= check . (==callsBefore)
              -- Recovery is now driven by the actual process loop. A bad native
              -- payment must not hide the later Solana attempt or broadcast it.
              let nativeKey=T.replicate 64 "0"; nativeId="fee:"<>nativeKey
              recoveryNow<-floor <$> getPOSIXTime
              evalWrite writer (Pause "multi-payment recovery contract")
              fixture fixtures (FreshAt recoveryNow)
              void $ evalWrite writer (ReserveFees recoveryNow nativeKey Native (money 3) "recipient" "recovery fixture")
              fixture fixtures ReadyIntake
              fixture fixtures (FreshAt recoveryNow)
              void $ evalWrite writer (PreparePayment recoveryNow nativeId (money 1) "{}")
              evalWrite writer (SaveDraft nativeId 0 "{}")
              nativePrepared<-evalRead reader (ReadPreparation nativeId)
              void $ evalWrite writer (RecordAttempt nativePrepared $ SignedAttempt "malformed-native" "00" "{}" (Just "offline:0"))
              original<-evalRead reader ReadBalances
              pending<-evalRead reader PendingAttempts >>= mapM (evalRead reader . ReadAttempt)
              check (sort(map recordedPayment pending)==[nativeId,identifier])
              writeIORef calls []
              prior<-fixture fixtures RecoveryPauseCount
              withWorkerProcess manager reader writer (ObserverSettings native solana 1 "origin" "origin") config Nothing endpoint $ \_ _->do
                awaitCondition "both payment recoveries" $ (>=prior+3) <$> fixture fixtures RecoveryPauseCount
                observed<-readIORef calls
                check ("getSignatureStatuses" `elem` observed && "sendTransaction" `notElem` observed)
                evalRead reader ReadState >>= check . ledgerPaused
                evalRead reader ReadBalances >>= check . (==original)
                evalRead reader PendingAttempts >>= mapM (evalRead reader . ReadAttempt) >>= check . (==pending)
              -- An existing bound order reaches the worker's real checkpoint
              -- operation through HTTP, even while intake is paused. Only the
              -- authenticated remote receipt is a fixture; no evaluator escapes.
              let cookie=directory</>"native-cookie"
                  configuredNative=native {N.nativeCookie=cookie}
                  header="Bearer "<>T.replicate 64 "c"
                  order=W.OrderRequest WrappedToNative (money 10) "native-recipient" "" Nothing "checkpoint-http"
                  publicConfig=W.PublicConfiguration profile cluster (W.InterfaceConfig Nothing Nothing Nothing Nothing Nothing)
                    "codec-fixture" mint owner 8 (money 2) (money 1000) (M.fromList [("NativeToWrapped",100),("WrappedToNative",100)])
                    True False (W.Availability False "starting") Nothing
              writeFile cookie "fixture:fixture"; setFileMode cookie 0o600
              fixture fixtures ReadyIntake
              now<-floor <$> getPOSIXTime
              fixture fixtures (FreshAt now)
              orderId<-evalWrite writer (CreateOrder now header order)
              required<-evalWrite writer (BindSolana now header orderId)
              evalWrite writer (Pause "checkpoint HTTP contract")
              state<-evalRead reader ReadState
              let sequenceNo=ledgerSequence state; covered=ledgerBackup state
                  receipt=W.BackupReceipt identity sequenceNo (T.replicate 64 "a") (T.replicate 64 "b")
              check (required>covered && required<=sequenceNo)
              checkpointReply<-newIORef (Nothing::Maybe W.BackupReceipt)
              checkpoints<-newIORef (0::Int)
              let fixtureCheckpoint :: forall a. Op.Request 'Op.Signer 'Op.Critical a -> IO a
                  fixtureCheckpoint request=case Op.resolve request of
                    Op.SigningDSL (Op.CheckpointSigning (Op.CheckpointCustody fingerprint minimumSequence))->do
                      check (fingerprint==identity && minimumSequence==required)
                      modifyIORef' checkpoints (+1)
                      Op.CheckpointResult <$> (readIORef checkpointReply >>= maybe (reject "checkpoint_fixture_refused") pure)
                    _->reject "checkpoint_fixture_only"
              credentials<-signerCredentials endpoint
              checkpointApp<-signingApplication credentials fixtureCheckpoint
              checkpointPort<-freePort
              let checkpointEndpoint=endpoint {signerPort=checkpointPort}
              withProcessListening (runSigningServer checkpointEndpoint checkpointApp) checkpointPort $
                withWorkerProcess manager reader writer (ObserverSettings configuredNative solana 1 "origin" "origin") config
                  (Just $ CustomerSettings publicConfig store sdk) checkpointEndpoint $ \httpPort _->
                  bracket (newManager defaultManagerSettings) closeManager $ \client->do
                    let submit=do
                          request<-HTTP.parseRequest ("http://127.0.0.1:"<>show httpPort<>"/api/v1/orders")
                          HTTP.httpLbs request {HTTP.method="POST",HTTP.requestHeaders=[("Content-Type","application/json"),("Authorization",TE.encodeUtf8 header)]
                            ,HTTP.requestBody=HTTP.RequestBodyLBS (encode order)} client
                        refused code=do
                          response<-submit
                          check (statusCode(HTTP.responseStatus response)==409 &&
                            eitherDecodeStrict' (BL.toStrict $ HTTP.responseBody response)==Right (object ["error" .= (code::T.Text)]))
                    refused "signer_outcome_unknown"
                    forM_ [receipt {W.receiptIdentity="other"},receipt {W.receiptSequence=sequenceNo-1},receipt {W.receiptSequence=sequenceNo+1}
                      ,receipt {W.receiptSnapshot="latest"},receipt {W.receiptArchiveHash=T.replicate 64 "A"}] $ \bad->do
                        writeIORef checkpointReply (Just bad)
                        refused "invalid_custody_checkpoint_receipt"
                        evalRead reader ReadState >>= check . (==covered) . ledgerBackup
                    writeIORef checkpointReply (Just receipt)
                    refused "intake_paused"
                    evalRead reader ReadState >>= check . (==sequenceNo) . ledgerBackup
                    callsBefore<-readIORef checkpoints
                    removeFile auth
                    refused "intake_paused"
                    readIORef checkpoints >>= check . (==callsBefore)
                    evalRead reader (ReadOrder header orderId) >>= check . (==Nothing) . W.depositInstruction
                    evalRead reader ReadBalances >>= check . (==original)
        -- Retrying reopens the same intent. Proved expired signatures remain
        -- history, not a second live transaction or a native replacement family.
        fixture fixtures SeedCustodyHeads
        let origins=[("Native","scan-origin"),("Solana","sol-origin"),("SolanaOperating","opening-signature")]
            proof="{\"expiry\":\"offline custody selection contract\"}"
            pending expected=do
              clock<-floor <$> getPOSIXTime
              fixture fixtures (FreshAt clock)
              snapshot<-evalRead reader (ReadCustodySnapshot clock origins False)
              check (filter ((==identifier).recordedPayment) (custodyPending snapshot)==expected)
              check ("malformed-native" `elem` map (signedId.recordedSigned) (custodyPending snapshot))
        old<-evalRead reader (ReadAttempt $ maybe "" id $ H.replySignature reply)
        pending [old]
        evalWrite writer (RecordSolanaExpiry old proof)
        pending []
        retired<-evalRead reader (ReadAttempt $ signedId $ recordedSigned old)
        clock<-floor <$> getPOSIXTime
        evalWrite writer (ApproveSolanaRetry clock retired "custody retry contract" proof)
        original<-evalRead reader (ReadRecordedPreparation $ signedId $ recordedSigned old)
        fixture fixtures ReadyIntake
        fixture fixtures (FreshAt clock)
        next<-evalWrite writer (PreparePayment clock identifier (preparedFee original) (preparedPolicy original))
        evalWrite writer (SaveDraft identifier (preparedGeneration next) (maybe "" id $ preparedDraft original))
        pending []
        fixture fixtures CoverBackup
        prepared<-evalRead reader (ReadPreparation identifier)
        successor<-evalWrite writer (RecordAttempt prepared (recordedSigned old) {signedId="offline-custody-successor"})
        pending [successor]
        evalWrite writer (RecordSolanaExpiry successor proof)
        pending []
        evalRead reader (ReadAttempt $ signedId $ recordedSigned old) >>= check . (==retired)
  putStrLn $ "PASS: "<>(if canonical then "canonical Mainnet profile" else "Devnet profile")<>", real process HTTPS signing, auth/certificate refusal and rotation, serialized concurrent requests, second-read refusal and gate recovery, exact SDK output, durable ledger replay, pending-payment recovery and HTTP-triggered checkpoint receipt validation/acknowledgment/replay; offline fixtures only"

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
  mutation<-try (fixture fixtures $ SourceRecipient key "changed") :: IO (Either PG.SqlError ())
  check (case mutation of Left err->PG.sqlState err=="23514"; _->False)
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
  mutation<-try (fixture fixtures $ SourceRecipient key "changed") :: IO (Either PG.SqlError ())
  check (case mutation of Left err->PG.sqlState err=="23514"; _->False)
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
  oldSend<-evalWrite writer (MarkBroadcast 110 $ signedId $ recordedSigned signed)
  fixture fixtures CoverBackup
  -- Recover already-signed work, preserving its bytes and paying state.
  void restore
  suspend
  evalRead reader (ReadPayment key) >>= check . (==PaymentReview) . savedStatus
  payingReturn<-restore
  evalWrite writer (Pause "review signed source restoration")
  fixture fixtures RefreshCustody
  approve key payingReturn "signed source returned"
  evalRead reader (ReadPayment key) >>= check . (==PaymentPaying) . savedStatus
  preserved<-evalRead reader (ReadAttempt "covered-conversion")
  check (recordedSigned preserved==recordedSigned signed)
  suspend
  payingSource<-evalRead reader (ReadSource did)
  evalWrite writer (RecordSourceCheck payingSource $ W.SourceMissing proof)
  payingLoss<-ledgerSequence <$> evalRead reader ReadState
  payingRevision<-evalRead reader ReadCustodyRevision
  evalWrite writer (CoverSourceLoss payingSource payingLoss 110 (money 10) (money 0)
    "cover signed source loss" proof (payingRevision,110,True,report))
  certify
  evalWrite writer (ApproveCoveredSource 110 key payingLoss "signed loss reviewed" proof)
  payingApproval<-ledgerSequence <$> evalRead reader ReadState
  evalWrite writer (ApproveCoveredSource 110 key payingLoss "signed loss reviewed" proof)
  evalRead reader ReadState >>= check . (==payingApproval) . ledgerSequence
  evalRead reader (ReadPayment key) >>= check . (==PaymentPaying) . savedStatus
  evalRead reader (ReadSource did) >>= check . not . W.depositEligible
  fixture fixtures ReadyIntake
  newSend<-evalWrite writer (MarkBroadcast 110 "covered-conversion")
  check (newSend>oldSend && newSend>=payingApproval)
  expectStore "backup_pending" (evalWrite writer $ AuthorizeSend 110 "covered-conversion")
  fixture fixtures CoverBackup
  fixture fixtures ReadyIntake
  evidenceUnavailable
  ready
  expectStore "source_not_eligible" (evalWrite writer $ AuthorizeSend 110 "covered-conversion")
  evalWrite writer (RecordSourceCheck source $ W.SourceMissing proof)
  ready
  authorized<-evalWrite writer (AuthorizeSend 110 "covered-conversion")
  check (recordedSigned authorized==recordedSigned signed)
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
nativeReplacementContract fixtures reader writer=handle (\(BridgeError code)->fail $ "native replacement ledger contract: "<>T.unpack code) $ forM_ [False,True] $ \customer->do
  captured<-getDataFileName "test/fixtures/native-signet-payment.json" >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
  originalPlan<-fieldValue "plan" captured
  originalTx<-fieldValue "decoded" captured >>= either reject pure . NP.decodeNativeTx
  let check ok=unless ok (fail "native replacement ledger contract")
      key=T.replicate 64 (if customer then "4" else "6")
      header="Bearer "<>T.replicate 64 "6"
      plan=originalPlan {NP.planAmount=money 10,NP.planDepth=2,NP.planFeeLimit=money 5}
      point=NP.nativeOutpoint $ head $ NP.nativeInputs originalTx
      prevouts=[NP.NativePrevout point (money 100) (NP.planChangeScript plan) 2 False]
      outputs n=[NP.NativeOutput (NP.planChangeScript plan) (money n),NP.NativeOutput (NP.planRecipientScript plan) (money 10)]
      tx=originalTx {NP.nativeTxid=key,NP.nativeOutputs=outputs 89}
      signed=NP.NativeSigned "00" tx plan prevouts (money 1)
      wire=SignedAttempt (NP.nativeTxid tx) "00" (encodeText signed) (Just $ NP.outpointTxid point<>":"<>T.pack(show $ NP.outpointVout point))
      draft=NP.NativeDraft "offline-replacement" tx {NP.nativeTxid=T.replicate 64 (if customer then "5" else "7"),NP.nativeOutputs=outputs 88} prevouts (money 2)
      ready=fixture fixtures ReadyIntake
      paused=evalWrite writer (Pause "replacement ledger contract") >> fixture fixtures RefreshCustody
  order<-if customer then do
    ready
    oid<-evalWrite writer (CreateOrder 110 header $ W.OrderRequest WrappedToNative (money 11) (NP.planRecipient plan) "" Nothing "replacement-customer")
    void $ evalWrite writer (BindSolana 110 header oid)
    fixture fixtures (SeedReceipt "replacement-customer-source" (Just oid) Wrapped 11 2 True 110)
    evalWrite writer (PromoteDeposit 110 "replacement-customer-source") >>= check
    pure (Just oid)
  else do
    paused
    void $ evalWrite writer (ReserveFees 110 key Native (money 10) (NP.planRecipient plan) "replacement earnings")
    pure Nothing
  let identifier=maybe ("fee:"<>key) ("convert:"<>) order
      link expected=forM_ order $ \oid->evalRead reader (ReadOrder header oid) >>= check . (==Just expected) . W.payoutTx
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
  evalRead reader ReadState >>= check . (==n) . ledgerSequence
  expectStore "native_replacement_draft_conflict" (evalWrite writer $ SaveReplacementDraft 110 parent draft {NP.draftPsbt="changed"} "increase fee")
  expectStore "native_replacement_draft_pending" (save "another decision")
  evalRead reader (ReadReplacementPayment decision) >>= check . (==identifier)
  expectStore "native_replacement_draft_pending" (evalRead reader $ ReadReplacementDraftContext 110 (signedId wire) (money 3))
  fixture fixtures CoverBackup
  ready
  expectStore "native_replacement_draft_pending" (evalWrite writer $ AuthorizeSend 110 $ signedId wire)
  paused
  evalWrite writer (CancelReplacementDraft decision "abandon unsigned draft")
  evalWrite writer (CancelReplacementDraft decision "abandon unsigned draft")
  expectStore "native_replacement_cancellation_conflict" (evalWrite writer $ CancelReplacementDraft decision "different")
  evalRead reader (ReadReplacementDecision (signedId wire) (money 2) "increase fee") >>= check . (==Just(decision,True))
  save "increase fee" >>= check . (==decision)
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
  -- Actual PostgreSQL winner history with synthetic chain evidence: principal
  -- remains paid while either family member becomes the canonical winner.
  settled<-evalRead reader (ReadAttempt $ signedId $ recordedSigned child)
  settledBalances<-evalRead reader ReadBalances
  link (signedId $ recordedSigned child)
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
  link (signedId wire)
  let lowerFee=M.insertWith (+) (Native,Operating) 1 $ M.insertWith (+) (Native,External) (-1) settledBalances
  evalRead reader ReadBalances >>= check . (==lowerFee)
  evalRead reader (ReadPayment identifier) >>= check . (==PaymentPaid) . savedStatus
  expectStore "native_settlement_changed" (record reconfirmed $ NativeWinnerChanged familyNow (signedId wire) (costs 1) $ proof parent c)
  candidate changed >>= check . not
  updatedFamily<-map fst <$> evalRead reader (ReadNativeFamily identifier)
  -- The primary link is derived from the payment winner; there is no mutable
  -- compatibility column that can point at an unrelated transaction.
  scanned child d 2 2
  record changed (NativeWinnerChanged updatedFamily (signedId $ recordedSigned child) (costs 2) $ proof child d)
  restoredWinner<-evalRead reader (ReadAttempt $ signedId $ recordedSigned child)
  link (signedId $ recordedSigned child)
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
  evalRead reader ReadNativeReviews >>= check . elem (winnerId,"unavailable",anchorSequence)
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
  record restoredWinner (NativeUnavailable "rpc_unavailable")
  expectStore "native_rebroadcast_not_missing" (evalRead reader $ ReadNativeRebroadcastContext winnerId)
  record restoredWinner (NativeReconfirmed (costs 2) $ proof restoredWinner d)
  evalRead reader ReadBalances >>= check . (==settledBalances)
  evalRead reader PendingAttempts >>= check . all (`notElem` [signedId wire,winnerId])
 where
  encodeText value=TE.decodeUtf8 (BL.toStrict $ encode value)

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
    history<-fixture fixtures MigrationRecords
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
              fixture connection MigrationRecords >>= check . (==history)
              fixture connection ReadCustodyCheck >>= check . (==(Nothing,Nothing,Just "restored_requires_reconciliation"))
            denied<-try (bracket (PG.connect target {PG.connectUser=role}) PG.close (const $ pure ())) :: IO (Either SomeException ())
            check (case denied of Left err->"permission denied for database" `T.isInfixOf` T.pack(show err); Right ()->False)
    databasesBefore<-fixture fixtures RestoreDatabases
    let linked=directory</>"linked-manifest"
    bracket_ (Posix.createSymbolicLink (manifestPath archive) linked) (removeFile linked) $
      expectStore "unsafe_backup_file" (restore linked)
    bracket_ (Posix.createLink (manifestPath archive) linked) (removeFile linked) $
      expectStore "unsafe_backup_file" (restore $ manifestPath archive)
    bracket_ (BS.writeFile linked (BS.replicate 8193 32) >> setFileMode linked 0o600) (removeFile linked) $
      expectStore "backup_file_too_large" (restore linked)
    expectStore "invalid_restore_policy" (evalRestore settings $ RestoreLedger (manifestPath archive) "contract" (-1))
    expectStore "backup_identity_mismatch" (evalRestore settings $ RestoreLedger (manifestPath archive) "wrong" 0)
    expectStore "backup_snapshot_too_old" (evalRestore settings $ RestoreLedger (manifestPath archive) "contract" (archiveSequence archive+1))
    restore (manifestPath archive)
    -- Pin the real read-only snapshot, then commit a separate writer before
    -- production pg_dump starts. A recipient changes without changing row counts;
    -- both metadata and complete financial records must retain the old snapshot.
    let snapshotSettings=settings {PG.connectUser=role}
        originalSequence=ledgerSequence before
        payment="historical-fee"
        changeSource n recipient=PG.withTransaction fixtures $ do
          fixture fixtures (SetArchiveSequence n)
          fixture fixtures (SourceAnchor payment recipient)
    recipient<-W.depositAnchor <$> evalRead reader (ReadSource payment)
    snapshotArchive<-bracket (PG.connect snapshotSettings) PG.close $ \connection->
      Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly) connection $ do
        original<-fixture connection ArchiveRecords
        check (original==records)
        fixture connection MigrationRecords >>= check . (==history)
        snapshot<-fixture connection ExportArchiveSnapshot
        bracket_ (changeSource (originalSequence+1) "archive-same-count-change")
          (changeSource originalSequence recipient) $ do
            evalRead reader ReadState >>= check . (==(originalSequence+1)) . ledgerSequence
            fixture fixtures MigrationRecords >>= check . (/=history)
            fixture connection ArchiveRecords >>= check . (==records)
            fixture connection MigrationRecords >>= check . (==history)
            let (rows,_,_)=records
            row<-case rows of [value]->pure value; _->fail "deployment row missing"
            Backup.archiveLedger snapshotSettings directory "contract" (S.schemaVersion row) originalSequence snapshot
    restore (manifestPath snapshotArchive)
    evalRead reader ReadState >>= check . (==before)
    let tampered=directory</>"tampered.json"
        change key value=case manifest of
          Object fields->BL.writeFile tampered (encode $ Object $ KM.insert key value fields) >> setFileMode tampered 0o600
          _->fail "manifest object required"
    change "criticalSequence" (toJSON $ archiveSequence archive+1)
    expectStore "restored_sequence_mismatch" (evalRestore settings $ RestoreLedger tampered "contract" 0)
    change "schemaVersion" (toJSON (18::Int))
    expectStore "invalid_backup_manifest" (evalRestore settings $ RestoreLedger tampered "contract" 0)
    change "schemaVersion" (toJSON (21::Int))
    expectStore "restored_schema_or_sequence_mismatch" (evalRestore settings $ RestoreLedger tampered "contract" 0)
    change "sha256" (toJSON $ T.replicate 64 "0")
    expectStore "backup_archive_mismatch" (evalRestore settings $ RestoreLedger tampered "contract" 0)
    -- Corrupt bytes, not just a manifest field; retain the same file length.
    let corrupted=BS.snoc (BS.init bytes) (BS.last bytes+1)
    check (BS.length corrupted==BS.length bytes && corrupted/=bytes)
    bracket_ (BS.writeFile (archivePath archive) corrupted)
      (BS.writeFile (archivePath archive) bytes) $
        expectStore "backup_archive_mismatch" (evalRestore settings $ RestoreLedger (manifestPath archive) "contract" 0)
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
    expectStore "backup_archive_mismatch" (upload archive {archiveSchema=21})
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
    fixture fixtures MigrationRecords >>= check . (==history)
    putStrLn "PASS: same-count financial change excluded by exported snapshot, complete financial records restored, same-length archive corruption refused, authenticated download, restricted paused restore, stale/identity/schema/hash refusal, failed-stage cleanup, private snapshot, real restic encryption/readback/restore, repository/permission/integrity/password refusal, unchanged coverage, exact signed attempts and every ledger posting"
