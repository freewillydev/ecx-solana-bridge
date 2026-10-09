{-# LANGUAGE DataKinds, GADTs, LambdaCase, ScopedTypeVariables #-}
-- Closed ledger operations. Connections, queries and transaction callbacks never
-- escape this module; the runtime will interpret its customer/operator DSL here.
module Bridge.Store
  ( Reader, Writer, BridgeError(..), StoreRead(..), StoreWrite(..), OrderLimits(..), StorePolicy(..), AllocationClaim(..), LedgerState(..), WithdrawalView(..), PaymentView(..), PaymentStatus(..), PreparedPayment(..), SignedAttempt(..), RecordedAttempt(..), NativeLockWork(..), NativeSettlementCheck(..), CustodySnapshot(..)
  , StoreSetup(..), evalSetup
  , StoreBackup(..), LedgerArchive(..), BackupReceipt(..), evalBackup, StoreRestore(..), evalRestore, CustodyArchive(..)
  , withReader, withWriter, withFencedWriter, evalRead, evalWrite ) where

import qualified Bridge.NativePayment as N
import Bridge.Error
import Bridge.Fence (withFence)
import qualified Bridge.Fence as Fence
import Bridge.Identity (bearerHash,digest,payInstruction,publicKey)
import Text.Read (readMaybe)
import qualified Bridge.Wire as W
import Bridge.Domain
import Bridge.Lifecycle
import Bridge.Wire (PaymentTerms(..),PolicySnapshot(..),CostLimits(..),SignedAttempt(..))
import qualified Bridge.Store.Schema as S
import qualified Bridge.Store.Projection as P
import qualified Bridge.Store.Migration as Migration
import qualified Bridge.Store.Provision as Provision
import Bridge.Store.Catalog (claimWorker,verifyReadRole,exportSnapshot)
import Bridge.Store.Backup (LedgerArchive(..),archiveLedger,BackupReceipt(..),loadRemoteBackup,uploadRemoteArchive,loadLedgerArchive,restoreLedger,discardRestore,downloadRemoteArchive,CustodyArchive(..),loadCustodyArchive,uploadRemoteCustody,downloadRemoteCustody)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString as BS
import Data.List (nub,sortOn)
import Data.Profunctor.Product (p2,p3)
import Data.Scientific (Scientific,floatingOrInteger)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless,forM,forM_,when,void)
import Data.Aeson (Key,FromJSON,ToJSON,Value(Null,Object),object,(.=),toJSON,encode,eitherDecodeStrict',withObject,(.:),(.:?))
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.IORef (newIORef,readIORef,writeIORef)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import System.Directory (removeFile,removeDirectoryRecursive)
import System.FilePath (takeDirectory)
import qualified Opaleye as O
import qualified Opaleye.Exists as Exists
import qualified Opaleye.Internal.Locking as Locking

data LedgerState = LedgerState
  { ledgerSequence :: Int64, ledgerBackup :: Int64, ledgerPaused :: Bool, ledgerReason :: Text }
  deriving (Eq,Show)
data StorePolicy = StorePolicy
  { executionTerms :: PaymentTerms, admissionLimits :: OrderLimits
  , deploymentName :: Text, requireBackup :: Bool } deriving (Eq,Show)
data NativeLockWork = NativeLockWork
  { lockPreparation :: PreparedPayment, lockCancelling :: Bool, lockAttempts :: [RecordedAttempt] } deriving (Eq,Show)

data CustodySnapshot = CustodySnapshot
  { custodyRevision :: Int64, custodyTotals :: M.Map Asset Integer
  , custodyHeads :: [(Text,Text)], custodySlot :: Int64, custodyPending :: [RecordedAttempt] } deriving (Eq,Show)

-- Closed offline setup: initialization cannot replace recovery, and conversion
-- requires a paused source and verified archive. Neither operation adopts a fence.
data StoreSetup a where
  ProvisionDatabase :: Text -> StoreSetup ()
  ProvisionRestoredDatabase :: Text -> Int64 -> StoreSetup ()
  InitializeLedger :: Text -> StoreSetup ()
  MigratePaymentRoots :: Text -> Int64 -> FilePath -> StoreSetup (Int64,Int)

evalSetup :: PG.ConnectInfo -> StoreSetup a -> IO a
evalSetup settings (ProvisionRestoredDatabase identity sequenceNo) = Provision.provisionRestoredDatabase settings identity sequenceNo
evalSetup settings (ProvisionDatabase token) = Provision.provisionDatabase settings token
evalSetup settings (MigratePaymentRoots identity minimumSequence manifest) =
  Migration.migratePaymentRoots settings identity minimumSequence manifest
evalSetup settings (InitializeLedger identity) = Migration.initializeLedger settings identity

-- Restoration needs database-creation authority; fence changes claim the paused
-- ledger exclusively. No online handler receives these maintenance operations.
data StoreRestore a where
  InspectCustodyFiles :: FilePath -> Text -> Int64 -> StoreRestore CustodyArchive
  UploadCustodyFiles :: FilePath -> CustodyArchive -> StoreRestore BackupReceipt
  DownloadCustodyFiles :: FilePath -> Text -> Text -> Int64 -> FilePath -> StoreRestore CustodyArchive
  InspectLedger :: FilePath -> Text -> Int64 -> StoreRestore LedgerArchive
  AdoptLedger :: FilePath -> Text -> Int64 -> StoreRestore (Text,Int64)
  RetireLedger :: FilePath -> Text -> Int64 -> StoreRestore (Text,Int64)
  RestoreLedger :: FilePath -> Text -> Int64 -> StoreRestore (Text,Int64)
  RecoverLedger :: FilePath -> Text -> FilePath -> Text -> Int64 -> StoreRestore (Text,Int64)

evalRestore :: PG.ConnectInfo -> StoreRestore a -> IO a
evalRestore _ (InspectCustodyFiles manifest identity minimumSequence) = loadCustodyArchive identity minimumSequence manifest
evalRestore _ (UploadCustodyFiles configuration archive) = loadRemoteBackup configuration >>= \remote->uploadRemoteCustody remote archive
evalRestore _ (DownloadCustodyFiles configuration snapshot identity minimumSequence directory) =
  loadRemoteBackup configuration >>= \remote->downloadRemoteCustody remote snapshot identity minimumSequence directory
evalRestore _ (InspectLedger manifest identity minimumSequence) = loadLedgerArchive identity minimumSequence manifest
evalRestore settings (AdoptLedger directory identity minimumSequence) =
  changeLedgerFence settings directory identity minimumSequence Fence.adoptFence
evalRestore settings (RetireLedger directory identity minimumSequence) =
  changeLedgerFence settings directory identity minimumSequence Fence.retireFence
evalRestore settings (RecoverLedger configuration snapshot directory identity minimumSequence) = do
  remote<-loadRemoteBackup configuration
  bracket (downloadRemoteArchive remote snapshot identity minimumSequence directory)
    (removeDirectoryRecursive . takeDirectory . manifestPath) $ \archive->
      evalRestore settings (RestoreLedger (manifestPath archive) identity minimumSequence)
evalRestore settings (RestoreLedger manifest identity minimumSequence) = do
  archive<-loadLedgerArchive identity minimumSequence manifest
  bracketOnError (restoreLedger settings archive) discardRestore $ \target->do
   -- Legacy archives are upgraded only in the newly created, private restore
   -- database. There is no signer, adopted fence or automatic resumption here.
   when (archiveSchema archive==21) $ do
    bracket (PG.connect target) PG.close $ \c->Tx.withTransaction c $ do
      claimWorker c >>= flip require "worker_already_running"
      rows<-O.runSelect c (O.selectTable S.deployment) :: IO [S.Deployment]
      require (case rows of
        [r]->S.singleton r==1 && S.schemaVersion r==21 && S.fingerprint r==identity && S.criticalSequence r==archiveSequence archive
        _->False) "restored_schema_or_sequence_mismatch"
      void $ O.runUpdate c O.Update {O.uTable=S.deployment,
        O.uUpdateWith= \r->r {S.paused=O.sqlInt8 1,S.pauseReason=O.sqlStrictText "restored_requires_migration"},
        O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
    void $ evalSetup target (MigratePaymentRoots identity minimumSequence manifest)
   bracket (PG.connect target) PG.close $ \c->Tx.withTransaction c $ do
    claimWorker c >>= flip require "worker_already_running"
    row<-metadata c identity
    require (S.criticalSequence row==archiveSequence archive) "restored_sequence_mismatch"
    _<-O.runUpdate c O.Update {O.uTable=S.deployment,
      O.uUpdateWith= \r->r {S.paused=O.sqlInt8 1,S.pauseReason=O.sqlStrictText "restored_requires_reconciliation"},
      O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
    count<-O.runUpdate c O.Update {O.uTable=S.custody,
      O.uUpdateWith= \(n,revision,_,_,_)->(n,revision,O.null,O.null,O.toNullable $ O.sqlStrictText "restored_requires_reconciliation"),
      O.uWhere= \(n,_,_,_,_)->n O..== O.sqlInt8 1,O.uReturning=O.rCount}
    require (count==1) "corrupt_custody_state"
    audit c "ledger_restored" (archiveHash archive)
    pure (T.pack $ PG.connectDatabase target,S.criticalSequence row)

-- Private implementation of the two closed fence operations above. The row
-- lock stabilizes pause/sequence through fsync; the session lock excludes a
-- paying worker even if it is using another filesystem directory.
changeLedgerFence :: PG.ConnectInfo -> FilePath -> Text -> Int64
  -> (FilePath -> Text -> Int64 -> IO ()) -> IO (Text,Int64)
changeLedgerFence settings directory identity minimumSequence change = do
  require (minimumSequence>=0) "invalid_restore_policy"
  bracket (PG.connect settings) PG.close $ \c->Tx.withTransaction c $ do
    claimWorker c >>= flip require "worker_already_running"
    rows<-O.runSelect c $ Locking.forUpdate $ do
      row<-O.selectTable S.deployment
      O.where_ (S.singleton row O..== O.sqlInt8 1)
      pure (S.singleton row)
    require (rows==[1::Int64]) "corrupt_deployment"
    row<-metadata c identity
    require (S.paused row==1) "pause_before_fence_change"
    require (S.criticalSequence row>=minimumSequence) "backup_snapshot_too_old"
    change directory identity (S.criticalSequence row)
    pure (T.pack $ PG.connectDatabase settings,S.criticalSequence row)

-- Privileged local archive operation, deliberately absent from StoreRead and
-- customer/signer capabilities. It never acknowledges off-host durability.
data StoreBackup a where
  ExportLedger :: FilePath -> StoreBackup LedgerArchive
  UploadLedger :: FilePath -> FilePath -> Int64 -> StoreBackup BackupReceipt

evalBackup :: Reader -> StoreBackup a -> IO a
evalBackup reader (UploadLedger configuration directory required) = do
  require (required>=0) "invalid_backup_coverage"
  remote<-loadRemoteBackup configuration
  bracket (evalBackup reader $ ExportLedger directory)
    (\archive->mapM_ removeFile [manifestPath archive,archivePath archive]) $ \archive->do
      require (archiveSequence archive>=required) "backup_snapshot_too_old"
      uploadRemoteArchive remote archive
-- Only the local pg_dump spans this read-only transaction; upload runs after
-- it has closed, and neither path holds a paying-writer transaction.
evalBackup (Reader settings identity _) (ExportLedger directory) =
  bracket (PG.connect settings) PG.close $ \c ->
    Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly) c $ do
      verifyReadRole c >>= flip require "unsafe_read_database_role"
      row <- metadata c identity
      snapshots <- O.runSelect c (pure exportSnapshot)
      snapshot <- case snapshots of
        [value] -> pure value
        _ -> reject "invalid_backup_snapshot"
      archiveLedger settings directory identity (S.schemaVersion row) (S.criticalSequence row) snapshot

data StoreRead a where
  ReadNativeReviews :: StoreRead [(Text,Text,Int64)]
  ReadTreasuryReceipts :: StoreRead [(Text,Asset,Amount)]
  ReadNativeRebroadcastContext :: Text -> StoreRead (RecordedAttempt,[(RecordedAttempt,N.NativeSigned)],Int64)
  ReadNativeRebroadcastDecision :: Text -> Int64 -> Text -> StoreRead (Maybe Int64)
  NativeSettlementCandidates :: StoreRead [RecordedAttempt]
  ReadReplacementDraftContext :: Int64 -> Text -> Amount -> StoreRead [(RecordedAttempt,N.NativeSigned)]
  ReadReplacementSigning :: Int64 -> Int64 -> StoreRead ([(RecordedAttempt,N.NativeSigned)],N.NativeDraft)
  ReadReplacementPayment :: Int64 -> StoreRead Text
  ReadReplacementMember :: Int64 -> StoreRead (Maybe RecordedAttempt)
  ReadNativeFamily :: Text -> StoreRead [(RecordedAttempt,N.NativeSigned)]
  ReadReplacementDecision :: Text -> Amount -> Text -> StoreRead (Maybe (Int64,Bool))
  ReadLossCover :: Text -> Int64 -> StoreRead (Maybe (Amount,Amount,Text))
  NativeSourceCandidates :: StoreRead [W.Deposit]
  ReadNativeSourceInspection :: Text -> StoreRead (Maybe (Text,W.PolicySnapshot),(Text,Value))
  ReadCoveredApproval :: Text -> Int64 -> StoreRead (Maybe Text)
  CheckCoveredSource :: Text -> Int64 -> StoreRead ()
  ReadSourceApproval :: Text -> Int64 -> StoreRead (Maybe Text)
  CheckSourceRestoration :: Text -> Int64 -> StoreRead ()
  ReadSolanaExpiry :: Text -> StoreRead (Maybe Text)
  ReadRetryApproval :: Text -> StoreRead (Maybe Text)
  ReadRecordedPreparation :: Text -> StoreRead PreparedPayment
  CheckExpiryOrigins :: (Text,Text) -> StoreRead ()
  ReadCancellation :: Text -> Int -> StoreRead (Maybe (Text,Text,Bool))
  ReadUnsignedPreparation :: Text -> StoreRead PreparedPayment
  ReadNativeLockWork :: StoreRead (Maybe NativeLockWork)
  FindOrder :: Text -> W.OrderRequest -> StoreRead (Maybe Text)
  ReadProvisioning :: Text -> Text -> StoreRead (W.OrderView,Maybe Int64)
  CheckIntake :: Int64 -> StoreRead ()
  ReadCustodyRevision :: StoreRead Int64
  ReadCustodySnapshot :: Int64 -> [(Text,Text)] -> Bool -> StoreRead CustodySnapshot
  ReadCustodyEvent :: Text -> Text -> StoreRead (Text,Text,Value)
  HasCustodyEvent :: Text -> Text -> StoreRead Bool
  PendingAttempts :: StoreRead [Text]
  PaymentCandidates :: StoreRead [Text]
  ReadState :: StoreRead LedgerState
  ReadPublicReport :: Int64 -> StoreRead W.PublicReport
  ReadBalances :: StoreRead (M.Map (Asset,Account) Integer)
  ReadPaymentWork :: Text -> StoreRead (PaymentView,Maybe PreparedPayment,[Text])
  ReadSigningDecision :: Int64 -> Text -> Int -> StoreRead PreparedPayment
  ReadAttempt :: Text -> StoreRead RecordedAttempt
  ReadPreparation :: Text -> StoreRead PreparedPayment
  ReadPayment :: Text -> StoreRead PaymentView
  CheckPaymentSource :: Text -> StoreRead ()
  ReadPaymentSource :: Text -> StoreRead (Maybe W.PaymentSource)
  ReadWithdrawal :: Text -> StoreRead (Maybe WithdrawalView)
  ReadPayableOrder :: Int64 -> Text -> Text -> StoreRead W.OrderView
  ReadOrder :: Text -> Text -> StoreRead W.OrderView
  PromotionCandidates :: StoreRead [Text]
  PendingVerification :: StoreRead [Text]
  LookupReferences :: [Text] -> StoreRead (Maybe (Text,W.OrderRequest,W.PolicySnapshot,Text))
  LookupInstruction :: Text -> StoreRead (Maybe (Text,W.OrderRequest,W.PolicySnapshot))
  MaximumNativeDepth :: Int -> StoreRead Int
  ReadSourceWorkHash :: Text -> StoreRead Text
  ReadCheckpoint :: Text -> StoreRead (Maybe Text)
  ReadSource :: Text -> StoreRead W.Deposit
  ReadSourceEvidence :: Text -> StoreRead (Text,Text)
data StoreWrite a where
  RepairCompletedOrderView :: Int64 -> Text -> StoreWrite ()
  RecordNativeRebroadcast :: RecordedAttempt -> [RecordedAttempt] -> Int64 -> Text -> Value -> StoreWrite Int64
  AuthorizeNativeRebroadcast :: RecordedAttempt -> [RecordedAttempt] -> Int64 -> StoreWrite RecordedAttempt
  RecordNativeSettlement :: RecordedAttempt -> NativeSettlementCheck -> StoreWrite ()
  RecordReplacement :: Int64 -> Int64 -> [(RecordedAttempt,N.NativeSigned)] -> N.NativeSigned -> StoreWrite RecordedAttempt
  SaveReplacementDraft :: Int64 -> RecordedAttempt -> N.NativeDraft -> Text -> StoreWrite Int64
  CancelReplacementDraft :: Int64 -> Text -> StoreWrite ()
  CoverSourceLoss :: W.Deposit -> Int64 -> Int64 -> Amount -> Amount -> Text -> Value -> (Int64,Int64,Bool,Value) -> StoreWrite ()
  ApproveCoveredSource :: Int64 -> Text -> Int64 -> Text -> Value -> StoreWrite ()
  ApproveSourceRestoration :: Int64 -> Text -> Int64 -> Text -> StoreWrite ()
  ClassifyTreasurySpend :: Text -> Text -> Text -> StoreWrite Int64
  AllocateTreasury :: Int64 -> Text -> [(Text,Amount)] -> Text -> StoreWrite Int64
  RecordSolanaExpiry :: RecordedAttempt -> Text -> StoreWrite ()
  ApproveSolanaRetry :: Int64 -> RecordedAttempt -> Text -> Text -> StoreWrite ()
  BeginCancellation :: PreparedPayment -> Int64 -> Text -> Text -> StoreWrite ()
  FinishCancellation :: PreparedPayment -> Text -> Text -> StoreWrite ()
  AuthorizeRefund :: Int64 -> Text -> StoreWrite W.RefundAuthorization
  ResumeLedger :: Int64 -> [(Text,Text)] -> [RecordedAttempt] -> StoreWrite ()
  RecordNativeLockRestore :: NativeLockWork -> Int -> StoreWrite ()
  RecordCustody :: Int64 -> Int64 -> Maybe Text -> Maybe Value -> StoreWrite ()
  MarkBroadcast :: Int64 -> Text -> StoreWrite Int64
  AuthorizeSend :: Int64 -> Text -> StoreWrite RecordedAttempt
  SettlePayment :: RecordedAttempt -> W.PaymentCosts -> Text -> StoreWrite ()
  FailSolana :: RecordedAttempt -> Amount -> Text -> StoreWrite ()
  RefreshPaymentSource :: W.Deposit -> W.Deposit -> StoreWrite ()
  RecordAttempt :: PreparedPayment -> SignedAttempt -> StoreWrite RecordedAttempt
  PreparePayment :: Int64 -> Text -> Amount -> Text -> StoreWrite PreparedPayment
  SaveDraft :: Text -> Int -> Text -> StoreWrite ()
  CommitScan :: W.ScanBatch -> StoreWrite ()
  ScanFailed :: Text -> Int64 -> Text -> StoreWrite ()
  RecordSourceCheck :: W.Deposit -> W.SourceCheck -> StoreWrite ()
  PromoteDeposit :: Int64 -> Text -> StoreWrite Bool
  Pause :: Text -> StoreWrite ()
  CreateOrder :: Int64 -> Text -> W.OrderRequest -> StoreWrite Text
  ClaimNative :: Int64 -> Text -> Text -> StoreWrite AllocationClaim
  RecordNative :: Text -> Text -> Text -> Text -> StoreWrite Int64
  BindSolana :: Int64 -> Text -> Text -> StoreWrite Int64
  IssueInstruction :: Int64 -> Text -> Text -> StoreWrite W.OrderView
  AcknowledgeBackup :: Text -> Int64 -> Text -> StoreWrite ()
  ExpireQuotes :: Int64 -> StoreWrite ()
  ReserveFees :: Int64 -> Text -> Asset -> Amount -> Text -> Text -> StoreWrite WithdrawalView
  CancelFees :: Text -> Text -> StoreWrite WithdrawalView

-- Reader has no writer connection, checkpoint or writable credentials.
data Reader = Reader PG.ConnectInfo Text Bool
data Writer = Writer (MVar (Maybe PG.Connection)) StorePolicy (Int64 -> IO ())

-- Production ownership: hold the host lock for the complete writer lifetime,
-- and fsync its monotonic watermark before each database commit.
withFencedWriter :: PG.ConnectInfo -> StorePolicy -> FilePath -> (Writer -> IO a) -> IO a
withFencedWriter settings config directory action =
  withFence directory (deploymentFingerprint $ paymentPolicy $ executionTerms config) $ \checkpoint->
    withWriter settings config checkpoint action

withReader :: PG.ConnectInfo -> Text -> Bool -> (Reader -> IO a) -> IO a
withReader settings identity remote action = do
  let reader = Reader settings identity remote
  _ <- evalRead reader ReadState
  action reader

-- The checkpoint must persist the monotonic host fence before commit. It is
-- infrastructure, not an operation supplied by a handler. No optional bypass.
withWriter :: PG.ConnectInfo -> StorePolicy -> (Int64 -> IO ()) -> (Writer -> IO a) -> IO a
withWriter settings config checkpoint action = bracket (PG.connect settings) PG.close $ \c -> do
  let policy=executionTerms config; limit=admissionLimits config
  require (not(T.null $ deploymentName config) && T.length(deploymentName config)<=64 && not(T.any (<= ' ') $ deploymentName config)) "invalid_deployment_name"
  require (units (maximumWithdrawal limit)>0
    && quoteSeconds limit>0 && graceSeconds limit>=0 && maximumQueued limit>0
    && units (savedNativeFee $ paymentLimits policy)>0 && units (savedSolanaFee $ paymentLimits policy)>0
    && nativeDepth (paymentPolicy policy)>0 && solanaCommitment (paymentPolicy policy)=="finalized") "invalid_store_policy"
  _ <- checked $ amount (toInteger(units $ savedSolanaFee $ paymentLimits policy)+toInteger(units $ savedSolanaRent $ paymentLimits policy))
  claimWorker c >>= flip require "worker_already_running"
  row <- metadata c (deploymentFingerprint $ paymentPolicy policy)
  checkpoint (S.criticalSequence row)
  writer <- (\cell -> Writer cell config checkpoint) <$> newMVar (Just c)
  evalWrite writer (Pause "restart_requires_reconciliation")
  action writer

evalRead :: Reader -> StoreRead a -> IO a
evalRead (Reader settings identity remote) operation = bracket connect PG.close $ \c ->
  Tx.withTransactionMode (Tx.TransactionMode Tx.RepeatableRead Tx.ReadOnly) c $ do
    verifyReadRole c >>= flip require "unsafe_read_database_role"
    row <- metadata c identity
    case operation of
      FindOrder header request -> findOrder c identity header request
      ReadProvisioning header identifier -> do
        row<-authorizedOrder c identity header identifier
        cap<-checked (bearerHash header)
        view<-readOrder c identity Nothing cap identifier
        pure (view,S.instructionSequence row)
      CheckIntake now -> intakeReady c identity now
      ReadCustodyRevision -> readCustodyRevision c
      ReadPublicReport now -> publicReport c now
      ReadCustodySnapshot now origins losses -> custodySnapshot c now origins losses
      ReadCustodyEvent chain identifier -> custodyEvent c chain identifier
      HasCustodyEvent chain identifier -> do
        rows<-O.runSelect c $ O.limit 1 $ do
          event<-O.selectTable S.chainEvents
          O.where_ (S.eventId event O..== O.sqlStrictText identifier O..&& O.in_ (map O.sqlStrictText $ if chain=="Solana" then ["Solana","SolanaOperating"] else [chain]) (S.eventChain event))
          pure (S.eventId event)
        pure (not $ null (rows :: [Text]))
      ReadTreasuryReceipts -> do
        -- A bounded selection aid, never allocation authority. The write leaf
        -- rechecks ownership evidence, obligations, readiness and exact amounts.
        rows<-O.runSelect c $ O.limit 100 $ O.orderBy (O.asc $ \(key,_,_)->key) $ do
          row<-O.selectTable S.deposits
          O.where_ (O.isNull(S.depositOrder row) O..&& S.depositEligible row O..== O.sqlInt8 1
            O..&& S.depositAllocated row O..== O.sqlInt8 0)
          linked<-Exists.exists $ do
            obligation<-O.selectTable S.obligations
            O.where_ (S.obligationDeposit obligation O..== S.depositId row)
            pure ()
          O.where_ (O.not linked)
          pure (S.depositId row,S.depositAsset row,S.depositAmount row)
          :: IO [(Text,Text,Int64)]
        forM rows $ \(key,asset,quantity)->(,,) key <$> parseAsset asset <*> checked(amount $ toInteger quantity)
      ReadNativeReviews -> do
        reviews<-O.runSelect c $ O.limit 1001 $ O.orderBy (O.desc $ \(_,_,n)->n) $ do
          (tx,_,state,_,n)<-S.nativeRecoveryDetails
          O.where_ (state O../= O.sqlStrictText "reconfirmed")
          pure (tx,state,n)
        require (length reviews<=1000) "native_settlement_recovery_backlog"
        pure reviews
      ReadNativeRebroadcastContext txid -> do
        (saved,family,_,_,n)<-nativeRebroadcastContext c identity txid
        pure (saved,family,n)
      ReadNativeRebroadcastDecision txid recovery reason -> nativeRebroadcastDecision c txid recovery reason
      NativeSettlementCandidates -> nativeSettlementCandidates c
      ReadReplacementDraftContext now parent fee -> replacementDraftContext c identity now parent fee
      ReadReplacementSigning now decision -> replacementSigning c identity remote now decision
      ReadReplacementPayment decision -> do
        parents<-O.runSelect c $ do
          (n,parent,_,_,_,_)<-S.replacementDrafts
          O.where_ (n O..== O.sqlInt8 decision)
          pure parent
          :: IO [Text]
        case parents of [parent]->recordedPayment <$> readAttempt c parent; _->reject "native_replacement_draft_missing"
      ReadReplacementMember decision -> replacementMember c decision
      ReadNativeFamily identifier -> nativeFamily c identity identifier
      ReadReplacementDecision parent fee reason -> replacementDecision c parent fee reason
      ReadNativeLockWork -> nativeLockWork c identity
      PendingAttempts -> pendingAttempts c
      PaymentCandidates -> paymentCandidates c
      ReadState -> pure (LedgerState (S.criticalSequence row) (S.backupSequence row) (S.paused row/=0) (S.pauseReason row))
      ReadLossCover key recovery -> lossCover c key recovery
      NativeSourceCandidates -> nativeSourceCandidates c
      ReadNativeSourceInspection key -> nativeSourceInspection c key
      ReadSourceApproval key restoration -> sourceApproval c False key restoration
      ReadCoveredApproval key recovery -> sourceApproval c True key recovery
      CheckCoveredSource key recovery -> sourceRecovery c True key recovery >> pure ()
      CheckSourceRestoration key restoration -> sourceRecovery c False key restoration >> pure ()
      ReadSolanaExpiry txid -> expiryProof c txid
      ReadRetryApproval txid -> retryReason c txid
      ReadRecordedPreparation txid -> recordedPreparation c identity txid
      CheckExpiryOrigins origins -> checkExpiryOrigins c origins
      ReadCancellation identifier generation -> readCancellation c identifier generation
      ReadUnsignedPreparation identifier -> cancellationPreparation c identity identifier
      ReadPaymentWork identifier -> paymentWork c identity identifier
      ReadSigningDecision now identifier generation -> signingDecision c identity remote now identifier generation
      ReadAttempt identifier -> readAttempt c identifier
      ReadPreparation identifier -> readPreparation c identity identifier
      ReadPayment identifier -> readPayment c identity identifier
      CheckPaymentSource identifier -> readPayment c identity identifier >>= paymentSource c . savedPayment
      ReadPaymentSource identifier -> readPaymentSource c identity identifier
      PendingVerification -> pendingVerification c
      LookupReferences keys -> lookupReferences c keys
      LookupInstruction instruction -> lookupInstruction c instruction
      MaximumNativeDepth minimumDepth -> maximumNativeDepth c minimumDepth
      ReadSourceWorkHash identifier -> sourceWorkHash c identifier
      ReadCheckpoint chain -> readCheckpoint c chain
      ReadSource identifier -> readSource c identifier >>= asDeposit
      ReadSourceEvidence txid -> sourceEvidence c txid
      PromotionCandidates -> promotionCandidates c
      ReadBalances -> balances c
      ReadWithdrawal key -> readWithdrawal c key
      ReadPayableOrder now header identifier -> do
        cap<-checked (bearerHash header)
        view<-readOrder c identity (if remote then Just(S.backupSequence row) else Nothing) cap identifier
        intakeReady c identity now
        require (W.status view=="AwaitingDeposit" && now<=W.deadline view && W.direction(W.request view)==WrappedToNative) "deposit_window_closed"
        pure view
      ReadOrder header identifier -> do
        cap <- checked (bearerHash header)
        readOrder c identity (if remote then Just(S.backupSequence row) else Nothing) cap identifier

 where
  -- Closing a timed-out client does not reliably cancel its server-side query.
  -- Fixed report-only connection settings bound lock/query/idle-transaction work;
  -- these are libpq session options, not a generic SQL operation or new authority.
  connect=case operation of
    ReadPublicReport _->PG.connectPostgreSQL $ PG.postgreSQLConnectionString settings
      <> " connect_timeout=3 options='-c statement_timeout=4000 -c lock_timeout=3000 -c idle_in_transaction_session_timeout=5000'"
    _->PG.connect settings

evalWrite :: Writer -> StoreWrite a -> IO a
evalWrite writer@(Writer _ config _) operation = transaction writer $ \c ->
 let policy=executionTerms config; limit=admissionLimits config in case operation of
  RecordSolanaExpiry expected proof -> recordSolanaExpiry c config expected proof
  ApproveSolanaRetry now expected reason proof -> approveSolanaRetry c config now expected reason proof
  BeginCancellation expected now reason cleanup -> beginCancellation c config expected now reason cleanup
  FinishCancellation expected reason cleanup -> finishCancellation c config expected reason cleanup
  AuthorizeRefund now receipt -> authorizeRefund c config now receipt
  ResumeLedger now origins reviewed -> resumeLedger c config now origins reviewed
  RecordNativeLockRestore expected count -> do
    current<-nativeLockWork c (deploymentFingerprint $ paymentPolicy policy)
    require (current==Just expected && not(lockCancelling expected) && preparedDraft(lockPreparation expected)/=Nothing && count>0 && count<=100) "native_lock_work_changed"
    let saved=lockPreparation expected
        subject=paymentId(savedPayment $ preparedView saved)<>"@"<>T.pack(show $ preparedGeneration saved)
    audit c "native_locks_restored" (subject<>":"<>T.pack(show count))
  RecordCustody revision now problem report -> recordCustody c revision now problem report
  MarkBroadcast now txid -> markBroadcast c config now txid
  AuthorizeSend now txid -> authorizeSend c config now txid
  RecordNativeRebroadcast expected family recovery reason proof -> recordNativeRebroadcast c (deploymentFingerprint $ paymentPolicy policy) expected family recovery reason proof
  AuthorizeNativeRebroadcast expected family approved -> do
    (saved,actual,_,proof,n)<-nativeRebroadcastContext c (deploymentFingerprint $ paymentPolicy policy) (signedId $ recordedSigned expected)
    require (saved==expected && map fst actual==family && n==approved) "native_rebroadcast_review_changed"
    anchor<-nativeProofField "rebroadcastRecovery" proof :: IO Int64
    recorded<-nativeProofField "rebroadcastProof" proof
    hash<-nativeProofField "bytesHash" recorded
    require (anchor>0 && hash==digest(TE.encodeUtf8 $ signedBytes $ recordedSigned saved)) "native_rebroadcast_payment_changed"
    state<-metadata c (deploymentFingerprint $ paymentPolicy policy)
    when (requireBackup config) $ require (S.backupSequence state>=S.criticalSequence state) "backup_pending"
    pure saved
  RecordNativeSettlement expected result -> recordNativeSettlement c (deploymentFingerprint $ paymentPolicy policy) expected result
  SettlePayment expected costs proof -> settleOutcome c (deploymentFingerprint $ paymentPolicy policy) expected (Succeeded costs proof)
  FailSolana expected fee proof -> settleOutcome c (deploymentFingerprint $ paymentPolicy policy) expected (Failed fee proof)
  RefreshPaymentSource expected observed -> do
    saved<-readSource c (W.depositId expected) >>= asDeposit
    require (saved==expected && observed {W.depositAnchor=W.depositAnchor expected,
      W.depositConfirmations=W.depositConfirmations expected,W.depositEligible=W.depositEligible expected}==expected) "source_binding_changed"
    when (observed/=expected) (observeDeposit c observed)
  RecordAttempt prepared signed -> recordAttempt c (deploymentFingerprint $ paymentPolicy policy) prepared signed
  PreparePayment now identifier allowance plan -> preparePayment c config now identifier allowance plan
  SaveDraft identifier generation draft -> saveDraft c (deploymentFingerprint $ paymentPolicy policy) identifier generation draft
  CommitScan batch -> commitScan c batch
  ScanFailed chain now code -> scanFailed c chain now code
  RecordSourceCheck expected check -> do
    current <- readSource c (W.depositId expected)
    snapshot <- asDeposit current
    require (snapshot==expected && W.depositAsset expected==Native) "source_recovery_changed"
    case check of
      W.SourceUnavailable _ -> pure ()
      _ -> do
        let proof=sourceProof check
        hash <- either (const $ reject "invalid_source_observation_hash") pure $ parseEither (withObject "source proof" (.: "observationHash")) proof
        txid <- case T.splitOn ":" (W.depositId expected) of ["native",tx,_]->pure tx; _->reject "invalid_native_deposit_id"
        (saved,_) <- sourceEvidence c txid
        require (hash==saved) "source_recovery_scan_not_current"
    recordSourceCheck c current check
  PromoteDeposit now identifier -> promoteDeposit c policy now identifier
  CreateOrder now header request -> createOrder c policy limit now header request
  ClaimNative now header identifier -> do
    row<-authorizedOrder c (deploymentFingerprint $ paymentPolicy policy) header identifier
    facts<-instructionFacts row
    let label="ecx-bridge:v1:"<>deploymentName config<>":order:"<>identifier
    previous<-allocation c identifier
    readiness<-if previous/=Nothing then pure Nothing else Just <$> readIntake c (deploymentFingerprint $ paymentPolicy policy) now
    claim<-checked (decideNativeClaim label previous facts readiness)
    when (mayAllocate claim) $ do
      n<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.nativeAllocations,
        O.iRows=[(O.sqlStrictText identifier,O.sqlStrictText label,O.sqlInt8 n)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    pure claim
  RecordNative header identifier label address -> do
    row<-authorizedOrder c (deploymentFingerprint $ paymentPolicy policy) header identifier
    facts<-instructionFacts row
    previous<-allocation c identifier
    checked (checkNativeAllocation previous label address facts)
    saveInstruction c row facts address
  BindSolana now header identifier -> do
    row<-authorizedOrder c (deploymentFingerprint $ paymentPolicy policy) header identifier
    facts<-instructionFacts row
    readiness<-if savedInstruction facts/=Nothing then pure Nothing else Just <$> readIntake c (deploymentFingerprint $ paymentPolicy policy) now
    checked (checkSolanaBinding facts readiness)
    instruction<-checked (payInstruction identifier)
    saveInstruction c row facts instruction
  IssueInstruction now header identifier -> issueInstruction c config now header identifier
  AcknowledgeBackup identity n snapshot -> do
    row <- metadata c identity
    require (T.length snapshot==64 && T.all (`elem` ("0123456789abcdef"::String)) snapshot) "invalid_backup_receipt"
    require (n>=S.backupSequence row && n<=S.criticalSequence row) "invalid_backup_coverage"
    when (n>S.backupSequence row) $ do
      _ <- O.runUpdate c O.Update {O.uTable=S.deployment,O.uUpdateWith= \r->r {S.backupSequence=O.sqlInt8 n},
        O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
      audit c "backup_acknowledged" (snapshot<>":"<>T.pack(show n))
  ExpireQuotes now -> expireQuotes c now
  Pause explanation -> do
    validReason explanation
    count <- O.runUpdate c O.Update {O.uTable=S.deployment,
      O.uUpdateWith= \r->r {S.paused=O.sqlInt8 1,S.pauseReason=O.sqlStrictText explanation},
      O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
    require (count==1) "corrupt_deployment"
    _ <- O.runInsert c O.Insert {O.iTable=S.audit,
      O.iRows=[(Nothing,O.sqlStrictText "pause",O.sqlStrictText explanation)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()
  RecordReplacement now decision family signed -> recordReplacement c config now decision family signed
  SaveReplacementDraft now parent draft reason -> saveReplacementDraft c policy now parent draft reason
  CancelReplacementDraft sequenceNo reason -> cancelReplacementDraft c policy sequenceNo reason
  CoverSourceLoss source recovery now capital earned reason proof custody -> coverSourceLoss c policy source recovery now capital earned reason proof custody
  ApproveCoveredSource now key recovery reason proof -> approveSourceRecovery c policy (Just proof) now key recovery reason
  ApproveSourceRestoration now key restoration reason -> approveSourceRecovery c policy Nothing now key restoration reason
  ClassifyTreasurySpend chain key reason -> classifyTreasurySpend c policy chain key reason
  AllocateTreasury now receipt split reason -> allocateTreasury c policy now receipt split reason
  RepairCompletedOrderView now identifier -> repairCompletedOrderView c policy now identifier
  ReserveFees now key currency n destination explanation -> do
    outgoing<-checked (withdrawalInput (maximumWithdrawal limit) now key currency n destination explanation)
    old<-readWithdrawal c key
    admission<-case old of
      Just _->pure Nothing
      Nothing->do
        operator<-readOperator c (deploymentFingerprint $ paymentPolicy policy) now
        booked<-balances c
        pure $ Just(operator,M.findWithDefault 0 (currency,Earned) booked)
    create<-checked (decideWithdrawal outgoing policy explanation old admission)
    if not create then maybe (reject "fee_withdrawal_not_found") pure old else do
      sequenceNumber<-nextSequence c
      count<-O.runInsert c O.Insert {O.iTable=S.withdrawals,
        O.iRows=[S.Withdrawal (O.sqlStrictText key) (O.sqlStrictText $ T.pack $ show currency)
          (O.sqlInt8 $ units n) (O.sqlStrictText destination) (O.sqlStrictText $ encodeSaved policy)
          (O.sqlStrictText explanation) (O.sqlInt8 sequenceNumber)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "withdrawal_insert_failed"
      createPaymentRoot c outgoing
      entries<-checked (reserveEarned $ paymentFunding outgoing)
      post c ("fee-reserve:"<>key) "reserve earned fees for operator withdrawal" entries
      pure (WithdrawalView outgoing policy explanation sequenceNumber Nothing)
  CancelFees key explanation -> do
    validReason explanation
    saved<-readWithdrawal c key >>= maybe (reject "fee_withdrawal_not_found") pure
    work<-case withdrawalCancellation saved of
      Just _->pure UnpreparedWithdrawal
      Nothing->do
        ids<-O.runSelect c $ O.limit 1 $ do
          (identifier,_,_,_,_,_)<-S.workPreparations
          O.where_ (identifier O..== O.sqlStrictText ("fee:"<>key))
          pure identifier
          :: IO [Text]
        if null ids then pure UnpreparedWithdrawal else do
          retry<-cancelledGeneration c ("fee:"<>key)
          state<-metadata c (deploymentFingerprint $ paymentPolicy policy)
          pure (WithdrawalWork (retry/=Nothing) (S.paused state==1))
    cancel<-checked (decideWithdrawalCancellation explanation saved work)
    if not cancel then pure saved else do
      case work of
        UnpreparedWithdrawal->pure ()
        WithdrawalWork{}->void $ O.runUpdate c O.Update {O.uTable=S.feeHolds,
          O.uUpdateWith= \(identifier,a,n,_)->(identifier,a,n,O.sqlInt8 1),
          O.uWhere= \(identifier,_,_,_)->identifier O..== O.sqlStrictText("fee:"<>key),O.uReturning=O.rCount}
      n<-nextSequence c
      count<-O.runInsert c O.Insert {O.iTable=S.cancellations,
        O.iRows=[(O.sqlStrictText key,O.sqlStrictText explanation,O.sqlInt8 n)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "withdrawal_cancellation_insert_failed"
      setPaymentPhase c ("fee:"<>key) Cancelled
      entries<-checked (releaseEarned $ paymentFunding $ withdrawalPayment saved)
      post c ("fee-cancel:"<>key) "cancel unsigned operator fee reservation" entries
      pure saved {withdrawalCancellation=Just(explanation,n)}

-- Serialize with the original worker's advisory-lock namespace and deployment
-- row. Any unexpected failure fences this connection; only policy rejection
-- with successful rollback permits reuse. No transaction spans chain RPC or remote backup.
transaction :: Writer -> (PG.Connection -> IO a) -> IO a
transaction (Writer cell config checkpoint) action = do
  let policy=executionTerms config
  outcome <- modifyMVar cell $ \case
    Nothing -> pure (Nothing,Left (toException $ BridgeError "ledger_connection_fenced"))
    Just c -> mask $ \restore -> do
      refused <- newIORef False
      result <- try $ do
        Tx.beginMode (Tx.TransactionMode Tx.ReadCommitted Tx.ReadWrite) c
        locked <- O.runSelect c $ Locking.forUpdate $ do
          r <- O.selectTable S.deployment
          O.where_ (S.singleton r O..== O.sqlInt8 1)
          pure (S.singleton r)
        require (locked==[1::Int64]) "corrupt_deployment"
        _ <- metadata c (deploymentFingerprint $ paymentPolicy policy)
        value <- restore (action c) `catch` \(err :: SomeException) -> do
          writeIORef refused (case fromException err :: Maybe BridgeError of Just _->True; _->False)
          throwIO err
        row <- metadata c (deploymentFingerprint $ paymentPolicy policy)
        checkpoint (S.criticalSequence row)
        PG.commit c
        pure value
      case result of
        Right value -> pure (Just c,Right value)
        Left (err :: SomeException) -> do
          rollback <- try (PG.rollback c) :: IO (Either SomeException ())
          policyRefusal <- readIORef refused
          let reusable = case (policyRefusal,rollback) of
                (True,Right ()) -> True
                _ -> False
          pure (if reusable then Just c else Nothing,Left err)
  either throwIO pure outcome

metadata :: PG.Connection -> Text -> IO S.Deployment
metadata c identity = do
  rows <- O.runSelect c (O.selectTable S.deployment)
  case rows of
    [r] | S.singleton r==1 && S.schemaVersion r==22 && S.fingerprint r==identity
        && S.criticalSequence r>=0 && S.backupSequence r>=0 && S.backupSequence r<=S.criticalSequence r
        && S.paused r `elem` [0,1] -> pure r
    _ -> reject "ledger_profile_or_schema_mismatch"
nextSequence :: PG.Connection -> IO Int64
nextSequence c = do
  rows <- O.runUpdate c O.Update {O.uTable=S.deployment,
    O.uUpdateWith= \r->r {S.criticalSequence=S.criticalSequence r+1},
    O.uWhere= \r->S.singleton r O..== O.sqlInt8 1 O..&& S.criticalSequence r O..< O.sqlInt8 maxBound,
    O.uReturning=O.rReturning S.criticalSequence}
  case rows of [n]->pure n; _->reject "sequence_exhausted"
fresh :: PG.Connection -> Int64 -> IO ()
fresh c now = custodyFacts c >>= checked . checkCustody now

readOperator :: PG.Connection -> Text -> Int64 -> IO OperatorFacts
readOperator c identity now = do
  state<-metadata c identity
  OperatorFacts now (S.paused state==1) <$> custodyFacts c

custodyFacts :: PG.Connection -> IO (Maybe (Int64,Int64,Int64))
custodyFacts c = do
  rows <- O.runSelect c $ O.limit 2 $ O.selectTable S.custody
    :: IO [(Int64,Int64,Maybe Int64,Maybe Int64,Maybe Text)]
  pure $ case rows of
    [(1,revision,Just checkedRevision,Just at,Nothing)] -> Just(revision,checkedRevision,at)
    _ -> Nothing
readWithdrawal :: PG.Connection -> Text -> IO (Maybe WithdrawalView)
readWithdrawal c key = do
  rows <- O.runSelect c $ do
    r <- O.selectTable S.withdrawals
    O.where_ (S.withdrawalId r O..== O.sqlStrictText key)
    pure r
  case rows of
    [] -> pure Nothing
    [r] -> do
      currency <- parseAsset (S.asset r)
      n <- checked (amount $ toInteger $ S.quantity r)
      funding <- checked (earnedFees key currency n)
      outgoing <- checked (payment ("fee:"<>key) funding (S.recipient r))
      policy <- either (const $ reject "invalid_saved_payment_terms") pure (eitherDecodeStrict' $ TE.encodeUtf8 $ S.terms r)
      cancellations <- O.runSelect c $ do
        (identifier,reason,sequenceNumber) <- O.selectTable S.cancellations
        O.where_ (identifier O..== O.sqlStrictText key)
        pure (reason,sequenceNumber)
      cancelled <- case cancellations of []->pure Nothing; [one]->pure(Just one); _->reject "duplicate_cancellation"
      pure (Just $ WithdrawalView outgoing policy (S.reason r) (S.sequenceNo r) cancelled)
    _ -> reject "duplicate_withdrawal"
-- One read-only snapshot of cached custody and immutable accounting. No RPC,
-- customer identifiers or full reconciliation evidence leave this operation.
publicReport :: PG.Connection -> Int64 -> IO W.PublicReport
publicReport c wallTime=do
  clock<-O.runSelect c (O.selectTable S.operatingClock) :: IO [(Int64,Int64)]
  now<-case clock of [(1,t)]->pure(max wallTime t); _->reject "operating_clock_missing"
  booked<-balances c
  holds<-O.runSelect c $ O.aggregate(p2(O.groupBy,O.sumInt8)) $ do
    (_,asset,n,phase)<-O.selectTable S.reservations
    O.where_ (phase O../= text "released")
    pure(asset,n)
    :: IO [(Text,Scientific)]
  let conversions=do
        root<-O.selectTable S.paymentRoots
        ob<-O.selectTable S.obligations
        O.where_ (S.rootId root O..== S.obligationId ob O..&& S.rootPhase root O..== text "settled"
          O..&& S.obligationKind ob O..== text "conversion")
        pure(root,ob)
  earned<-O.runSelect c $ O.aggregate(p2(O.groupBy,O.sumInt8)) $ do
    (root,_)<-conversions
    (_,event,asset,account,n)<-O.selectTable S.postings
    O.where_ (event O..== O.fromNullable (text "") (S.rootSettlementEvent root)
      O..&& account O..== text "earned" O..&& n O..> O.sqlInt8 0)
    pure(asset,n)
    :: IO [(Text,Scientific)]
  totals<-O.runSelect c $ O.aggregate O.count $ fmap (S.rootId.fst) conversions :: IO [Int64]
  -- Network-fee booking shares the original settlement transaction. Bind to its
  -- immutable event, not the mutable winner: replacement must not recount a sale.
  dated<-O.runSelect c $ O.aggregate(p3(O.groupBy,O.count,O.sumInt8)) $ do
    (root,ob)<-conversions
    (tx,payment)<-S.attemptIntents
    (posting,event,_,account,_)<-O.selectTable S.postings
    (cost,at)<-O.selectTable S.operatingCosts
    O.where_ (payment O..== S.rootId root O..&& O.fromNullable (text "") (S.rootSettlementEvent root) O..== (text "settlement:" O..++ tx)
      O..&& event O..== (text "network-fee:" O..++ tx) O..&& account O..== text "operating" O..&& cost O..== posting)
    pure(S.obligationAsset ob,S.rootId root,O.ifThenElse (at O..> O.sqlInt8(now-86400) O..&& at O..<= O.sqlInt8 now) (O.sqlInt8 1) (O.sqlInt8 0))
    :: IO [(Text,Int64,Scientific)]
  custody<-O.runSelect c $ do
    (key,revision,checked,at,failure)<-O.selectTable S.custody
    (other,encoded)<-O.selectTable S.custodyReport
    O.where_ (key O..== other O..&& key O..== O.sqlInt8 1)
    pure(revision,checked,at,failure,encoded)
    :: IO [(Int64,Maybe Int64,Maybe Int64,Maybe Text,Maybe Text)]
  (at,current,reserves)<-case custody of
    [(revision,checkedRevision,at,failure,encoded)]->do
      values<-case encoded of
        Nothing->pure []
        Just raw->do
          value<-decodeSaved raw
          either (const $ reject "invalid_public_custody_report") pure $ parseEither (withObject "custody" $ \o->do
            rows<-maybe [] id <$> o .:? "assets"
            mapM (withObject "asset" $ \r->(,) <$> r .: "asset" <*> r .: "observed") rows) value
      forM_ values $ \(_,n)->checked(parseUnits n) >> pure ()
      let complete=length values==3 && all (`M.member` M.fromList values) [Native,Wrapped,Sol]
          fresh=complete && checkCustody wallTime ((,,) revision <$> checkedRevision <*> at)==Right () && failure==Nothing
      pure(at,fresh,M.fromList values)
    _->reject "custody_state_missing"
  assets<-forM [Native,Wrapped,Sol] $ \asset->do
    held<-exact $ maybe 0 id $ lookup (T.pack $ show asset) holds
    fees<-exact $ maybe 0 id $ lookup (T.pack $ show asset) earned
    let available=M.findWithDefault 0 (asset,Float) booked-held
    pure $ W.PublicAssetReport asset (M.lookup asset reserves) (decimal available) (decimal held)
      (decimal $ M.findWithDefault 0 (asset,Principal) booked) (decimal fees)
  counts<-forM dated $ \(asset,_,n)->do value<-exact n; require (value<=toInteger(maxBound::Int64)) "public_count_overflow"; pure(asset,fromInteger value)
  total<-case totals of []->pure 0; [n]->pure n; _->reject "invalid_public_transfer_count"
  let undated=total-sum [n|(_,n,_)<-dated]
  require (undated>=0) "invalid_public_transfer_count"
  pure $ W.PublicReport now at current assets (maybe 0 id $ lookup "Wrapped" counts) (maybe 0 id $ lookup "Native" counts) undated
 where
  text=O.sqlStrictText
  decimal=T.pack.show
  exact value=case floatingOrInteger value :: Either Double Integer of
    Right n | n>=0->pure n
    _->reject "invalid_public_report_amount"

balances :: PG.Connection -> IO (M.Map (Asset,Account) Integer)
balances c = do
  rows <- O.runSelect c $ O.aggregate (p3 (O.groupBy,O.groupBy,O.sumInt8)) $ do
    (_,_,currency,account,delta) <- O.selectTable S.postings
    pure (currency,account,delta)
    :: IO [(Text,Text,Scientific)]
  entries <- mapM (\(currency,account,delta)->do
    a<-parseAsset currency
    b<-maybe (reject "unknown_ledger_account") pure (lookup account accounts)
    exact <- case floatingOrInteger delta :: Either Double Integer of
      Right n -> pure n
      Left _ -> reject "fractional_ledger_balance"
    pure ((a,b),exact)) rows
  pure (M.fromListWith (+) entries)
post :: PG.Connection -> Text -> Text -> [Posting] -> IO ()
post c event explanation entries = do
  require (all (==0) $ M.elems $ M.fromListWith (+) [(postingAsset p,postingDelta p)|p<-entries]) "unbalanced_journal"
  require (all ((<=toInteger(maxBound::Int64)).abs.postingDelta) entries) "posting_overflow"
  _ <- O.runInsert c O.Insert {O.iTable=S.events,O.iRows=[(O.sqlStrictText event,O.sqlStrictText explanation)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  let rows=[(Nothing,O.sqlStrictText event,O.sqlStrictText $ T.pack $ show $ postingAsset p,
             O.sqlStrictText $ accountName $ postingAccount p,O.sqlInt8 $ fromInteger $ postingDelta p)|p<-entries,postingDelta p/=0]
  unless (null rows) $ do
    count <- O.runInsert c O.Insert {O.iTable=S.postings,O.iRows=rows,O.iReturning=O.rCount,O.iOnConflict=Nothing}
    require (count==fromIntegral(length rows)) "posting_insert_failed"
accounts :: [(Text,Account)]
accounts=[("external",External),("principal",Principal),("unallocated",Unallocated),("float",Float),
  ("earned",Earned),("fee_pending",FeePending),("operating",Operating),("backing",Backing),("lp",Liquidity),("source_deficit",SourceDeficit)]
accountName :: Account -> Text
accountName = \case
  External->"external"; Principal->"principal"; Unallocated->"unallocated"
  Float->"float"; Earned->"earned"; FeePending->"fee_pending"
  Operating->"operating"; Backing->"backing"; Liquidity->"lp"; SourceDeficit->"source_deficit"
parseAsset :: Text -> IO Asset
parseAsset "Native"=pure Native
parseAsset "Wrapped"=pure Wrapped
parseAsset "Sol"=pure Sol
parseAsset _=reject "unknown_ledger_asset"
checked :: Either Text a -> IO a
checked=either reject pure
validReason :: Text -> IO ()
validReason=checked . checkReason

-- Authorized saved view, never re-quote. The reader transaction keeps all
-- recovery overlays and backup coverage in the same repeatable-read snapshot.
readOrder :: PG.Connection -> Text -> Maybe Int64 -> Text -> Text -> IO W.OrderView
readOrder c identity coverage cap identifier = do
  rows <- O.runSelect c $ do
    r <- O.selectTable S.orders
    O.where_ (S.orderId r O..== O.sqlStrictText identifier O..&& S.capabilityHash r O..== O.sqlStrictText cap)
    pure r
  r <- case (rows :: [S.Order]) of [one]->pure one; _->reject "order_not_found"
  request <- decodeSaved (S.requestJson r)
  savedQuote <- decodeSaved (S.quoteJson r)
  policy <- decodeSaved (S.policyJson r)
  require (W.input request==gross savedQuote && W.deploymentFingerprint policy==identity) "saved_order_terms_mismatch"
  visible <- case (S.instructionIssued r,S.instructionSequence r,S.instruction r) of
    (0,_,_) -> pure Nothing
    (1,Just sequenceNumber,Just instruction) -> do
      require (sequenceNumber>0 && maybe True (>=sequenceNumber) coverage) "backup_pending"
      pure (Just instruction)
    _ -> reject "invalid_instruction_state"
  native <- O.runSelect c $ O.limit 1 $ do
    (tx,state) <- S.nativeRecovery
    (attempt,intent) <- S.attemptIntents
    (intentId,obligation) <- S.intentObligations
    (obligationId,order,_,_) <- P.orderObligations
    O.where_ (tx O..== attempt O..&& intent O..== intentId O..&& O.matchNullable (O.sqlBool False) (O..== obligationId) obligation
      O..&& order O..== O.sqlStrictText identifier O..&& state O../= O.sqlStrictText "reconfirmed")
    pure tx
    :: IO [Text]
  payments<-customerPayments c identifier
  sources<-O.runSelect c $ O.limit 1 $ do
    (deposit,state)<-S.sourceRecovery
    (depositId,order)<-S.orderDeposits
    O.where_ (deposit O..== depositId O..&& state O../= O.sqlStrictText "restored"
      O..&& O.matchNullable (O.sqlBool False) (O..== O.sqlStrictText identifier) order)
    accounted<-Exists.exists $ do
      key<-S.accountedLosses
      O.where_ (key O..== deposit)
      pure ()
    paid<-Exists.exists $ do
      (_,owner,source,status)<-P.orderObligations
      O.where_ (owner O..== O.sqlStrictText identifier O..&& source O..== deposit O..&& status O..== O.sqlStrictText "paid")
      pure ()
    O.where_ (O.not accounted O..|| O.not paid)
    pure deposit
    :: IO [Text]
  let review=not(null native) || not(null sources)
  (status,payout)<-checked (projectCustomer (S.admissionState r) review payments)
  pure (W.OrderView identifier request savedQuote status (S.deadline r) visible payout policy)

-- A page reads roots and their current generation directly. Refund ordering uses
-- the immutable original principal event, even after a native winner changes.
customerPayments :: PG.Connection -> Text -> IO [CustomerPayment]
customerPayments c order = page "" []
 where
  page after retained = do
    rows<-O.runSelect c $ O.limit 1000 $ O.orderBy (O.asc (\(ob,_,_,_)->S.obligationId ob)) $ do
      ob<-O.selectTable S.obligations
      (root,state)<-P.paymentStates
      O.where_ (S.obligationOrder ob O..== O.sqlStrictText order O..&& S.obligationId ob O..> O.sqlStrictText after
        O..&& S.rootId root O..== S.obligationId ob)
      signed<-Exists.exists $ do
        attempt<-O.selectTable S.attempts
        O.where_ (S.attemptIntent attempt O..== S.rootId root
          O..&& O.matchNullable (O.sqlBool False) (O..== S.attemptGeneration attempt) (S.rootGeneration root))
        pure ()
      pure (ob,root,state,signed)
      :: IO [(S.Obligation,S.PaymentRoot,Text,Bool)]
    if null rows then pure retained else do
      original<-O.runSelect c $ O.aggregate (p2 (O.groupBy,O.max)) $ do
        root<-O.selectTable S.paymentRoots
        (ordinal,event,_,_,_)<-O.selectTable S.postings
        O.where_ (O.in_ [O.sqlStrictText(S.rootId r) | (_,r,_,_)<-rows] (S.rootId root)
          O..&& O.matchNullable (O.sqlBool False) (O..== event) (S.rootSettlementEvent root))
        pure (S.rootId root,ordinal)
        :: IO [(Text,Int64)]
      current<-forM rows $ \(ob,root,state,signed)->do
        economic<-rootPhase root
        purpose<-case S.obligationKind ob of "conversion"->pure CustomerConversion; "refund"->pure CustomerRefund; _->reject "unknown_payment_funding"
        status<-checked (parsePaymentStatus state)
        settled<-case (economic,lookup (S.rootId root) original) of
          (Settled tx _,Just ordinal)->pure(Just(tx,ordinal))
          (Settled{},Nothing)->reject "customer_settlement_missing"
          (_,Nothing)->pure Nothing
          _->reject "customer_payment_state_inconsistent"
        pure (CustomerPayment (S.obligationDeposit ob) purpose status (case economic of Active{}->Just signed; _->Nothing) settled)
      summary<-checked (compactCustomerPayments $ retained<>current)
      case reverse rows of
        (ob,_,_,_):_ | length rows==1000->page (S.obligationId ob) summary
        _->pure summary

decodeSaved :: FromJSON a => Text -> IO a
decodeSaved=either (const $ reject "corrupt_ledger_json") pure . eitherDecodeStrict' . TE.encodeUtf8

-- Bind replay to the original capability, request and deployment.
findOrder :: PG.Connection -> Text -> Text -> W.OrderRequest -> IO (Maybe Text)
findOrder c identity header request = do
  cap<-checked (bearerHash header)
  let key=W.idempotencyKey request
  require (not(T.null key) && T.length key<=64 && T.all (\x->x `elem` ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"::String)) key) "invalid_idempotency_key"
  rows<-O.runSelect c $ do
    row<-O.selectTable S.orders
    O.where_ (S.capabilityHash row O..== O.sqlStrictText cap O..&& S.idempotencyKey row O..== O.sqlStrictText(W.idempotencyKey request))
    pure (S.orderId row,S.requestHash row)
    :: IO [(Text,Text)]
  case rows of
    []->pure Nothing
    [(identifier,saved)]->do
      require (saved==digest(TE.encodeUtf8 $ identity<>encodeSaved request)) "idempotency_conflict"
      pure (Just identifier)
    _->reject "duplicate_idempotency"

-- Admission precedes this atomic reservation of inventory and operating costs.
createOrder :: PG.Connection -> PaymentTerms -> OrderLimits -> Int64 -> Text -> W.OrderRequest -> IO Text
createOrder c terms limits now header request = do
  cap <- checked (bearerHash header)
  let key=W.idempotencyKey request; identity=deploymentFingerprint (paymentPolicy terms)
      encoded=encodeSaved request; requestDigest=digest (TE.encodeUtf8 $ identity<>encoded)
  previous<-findOrder c identity header request
  case previous of
    Just identifier->pure identifier
    Nothing -> do
      readiness<-readIntake c identity now
      checked (checkIntake readiness)
      _<-checked (quoteOrder request)
      counts<-O.runSelect c $ O.aggregate O.count $ fmap S.orderId $ O.limit (maximumQueued limits) P.openOrders :: IO [Int64]
      queued<-case counts of
        []->pure 0 -- Opaleye aggregation preserves an empty input relation.
        [n] | n>=0 && toInteger n<=toInteger(maxBound::Int)->pure(fromIntegral n)
        _->reject "invalid_order_queue"
      booked<-balances c
      let destination=destinationAsset $ W.direction request
      held<-principalHeld c destination
      at<-operatingTime c
      nativeBudget<-readFeeBudget c limits booked at Native
      solanaBudget<-readFeeBudget c limits booked at Sol
      admitted<-checked $ decideOrder limits (paymentLimits terms) request $ OrderAdmissionFacts readiness
        queued (M.findWithDefault 0 (destination,Float) booked-held) nativeBudget solanaBudget
      identifier<-digest <$> (getRandomBytes 32 :: IO BS.ByteString)
      let text=O.sqlStrictText; num=O.sqlInt8; termsQuote=admittedQuote admitted
          row=S.Order (text identifier) (text cap) (text key) (text requestDigest) (text encoded)
            (text $ encodeSaved termsQuote) (text $ encodeSaved $ paymentPolicy terms) (text "Provisioning")
            (num $ admittedDeadline admitted) (num $ admittedGrace admitted) O.null O.null (num 0)
      _<-O.runInsert c O.Insert {O.iTable=S.orders,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _<-O.runInsert c O.Insert {O.iTable=S.reservations,O.iRows=[(text identifier,text $ T.pack(show destination),num $ units $ net termsQuote,text "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      reserveOrderCosts c (paymentLimits terms) identifier (admittedCosts admitted)
      pure identifier

intakeReady :: PG.Connection -> Text -> Int64 -> IO ()
intakeReady c identity now = readIntake c identity now >>= checked . checkIntake

readIntake :: PG.Connection -> Text -> Int64 -> IO IntakeFacts
readIntake c identity now = do
  require (now>=0) "invalid_order_time"
  d <- metadata c identity
  scans<-scanFacts <$> readScans c
  custody<-custodyFacts c
  pure $ IntakeFacts now (S.paused d/=0) scans custody

scanHeads :: PG.Connection -> Int64 -> IO [(Text,Text)]
scanHeads c now = do
  require (now>=0) "invalid_custody_time"
  scans<-readScans c
  checked (checkScans now $ scanFacts scans)
  pure [(chain,anchor) | (chain,_,_,anchor)<-scans]

readScans :: PG.Connection -> IO [(Text,Maybe Int64,Maybe Text,Text)]
readScans c = sortOn (\(chain,_,_,_)->chain) <$> (O.runSelect c $ O.limit 4 $ do
    (chain,success,problem,_) <- O.selectTable S.scanHealth
    (stream,anchor) <- O.selectTable S.checkpoints
    O.where_ (chain O..== stream)
    pure (chain,success,problem,anchor))

reserveOrderCosts :: PG.Connection -> CostLimits -> Text -> [(Text,Asset,Amount)] -> IO ()
reserveOrderCosts c costs identifier allowances = do
  let text=O.sqlStrictText; num=O.sqlInt8
  _<-O.runInsert c O.Insert {O.iTable=S.orderCosts,
    O.iRows=[(text identifier,num $ units $ savedNativeFee costs,num $ units $ savedSolanaFee costs,num $ units $ savedSolanaRent costs)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  forM_ allowances $ \(purpose,asset,quantity)->do
    _<-O.runInsert c O.Insert {O.iTable=S.operatingReservations,
      O.iRows=[(text identifier,text purpose,text $ T.pack(show asset),num $ units quantity,text "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    pure ()

encodeSaved :: ToJSON a => a -> Text
encodeSaved=TE.decodeUtf8 . BL.toStrict . encode

-- The raw row remains private: public reads must apply visibility and recovery.
authorizedOrder :: PG.Connection -> Text -> Text -> Text -> IO S.Order
authorizedOrder c identity header identifier = do
  cap <- checked (bearerHash header)
  rows <- O.runSelect c $ do
    row <- O.selectTable S.orders
    O.where_ (S.orderId row O..== O.sqlStrictText identifier O..&& S.capabilityHash row O..== O.sqlStrictText cap)
    pure row
  row <- case rows of [one]->pure one; _->reject "order_not_found"
  policy <- decodeSaved (S.policyJson row)
  require (deploymentFingerprint policy==identity) "order_profile_mismatch"
  pure row
allocation :: PG.Connection -> Text -> IO (Maybe Text)
allocation c identifier = do
  rows <- O.runSelect c $ do
    (key,label,_) <- O.selectTable S.nativeAllocations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure label
  case rows of []->pure Nothing; [label]->pure(Just label); _->reject "duplicate_native_allocation"
instructionFacts :: S.Order -> IO InstructionFacts
instructionFacts row = do
  request<-decodeSaved (S.requestJson row)
  pure $ InstructionFacts (W.direction request) (S.admissionState row) (S.deadline row)
    (S.instruction row) (S.instructionSequence row) (S.instructionIssued row)

saveInstruction :: PG.Connection -> S.Order -> InstructionFacts -> Text -> IO Int64
saveInstruction c row facts instruction = do
  decision<-checked (decideInstruction facts instruction)
  case decision of
    KeepInstruction n->pure n
    SaveInstruction->do
      n<-nextSequence c
      count<-O.runUpdate c O.Update {O.uTable=S.orders,
        O.uUpdateWith= \r->r {S.instruction=O.toNullable $ O.sqlStrictText instruction,S.instructionSequence=O.toNullable $ O.sqlInt8 n,
          S.admissionState=O.ifThenElse (S.admissionState r O..== O.sqlStrictText "Provisioning") (O.sqlStrictText "AwaitingDeposit") (S.admissionState r)},
        O.uWhere= \r->S.orderId r O..== O.sqlStrictText(S.orderId row),O.uReturning=O.rCount}
      require (count==1) "instruction_update_failed"
      pure n
issueInstruction :: PG.Connection -> StorePolicy -> Int64 -> Text -> Text -> IO W.OrderView
issueInstruction c config now header identifier = do
  let identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  row <- authorizedOrder c identity header identifier
  facts<-instructionFacts row
  state<-metadata c identity
  cap<-checked (bearerHash header)
  view<-readOrder c identity Nothing cap identifier
  admission<-if S.instructionIssued row/=0 then pure Nothing else do
    readiness<-readIntake c identity now
    held<-O.runSelect c $ do
      (key,_,_,phase)<-O.selectTable S.reservations
      O.where_ (key O..== O.sqlStrictText identifier)
      pure phase
      :: IO [Text]
    costs<-O.runSelect c $ do
      (key,_,_,_,phase)<-O.selectTable S.operatingReservations
      O.where_ (key O..== O.sqlStrictText identifier)
      pure phase
      :: IO [Text]
    pure $ Just(readiness,held,costs)
  issued<-checked (decideInstructionIssue (requireBackup config) (S.backupSequence state)
    facts {instructionStatus=W.status view} admission)
  when issued $ do
    count<-O.runUpdate c O.Update {O.uTable=S.orders,
      O.uUpdateWith= \r->r {S.instructionIssued=O.sqlInt8 1},O.uWhere= \r->S.orderId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
    require (count==1) "instruction_issue_failed"
    audit c "instruction_issued" identifier
  pure view {W.depositInstruction=S.instruction row}

expireQuotes :: PG.Connection -> Int64 -> IO ()
expireQuotes c now = do
  require (now>=0) "invalid_order_time"
  expired <- O.runSelect c $ do
    row <- O.selectTable S.orders
    O.where_ (S.graceDeadline row O..< O.sqlInt8 now)
    pure (S.orderId row,S.graceDeadline row)
    :: IO [(Text,Int64)]
  forM_ expired $ \(identifier,grace) -> do
    deposits <- O.runSelect c $ O.limit 1 $ do
      (key,order) <- S.orderDeposits
      O.where_ (O.matchNullable (O.sqlBool False) (O..== O.sqlStrictText identifier) order)
      pure key
      :: IO [Text]
    expire<-checked (shouldExpireQuote now grace $ not $ null deposits)
    when expire $ do
      _ <- O.runUpdate c O.Update {O.uTable=S.reservations,
        O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlStrictText "released"),
        O.uWhere= \(key,_,_,phase)->key O..== O.sqlStrictText identifier O..&& phase O..== O.sqlStrictText "quote",O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=S.operatingReservations,
        O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText "released"),
        O.uWhere= \(key,_,_,_,phase)->key O..== O.sqlStrictText identifier O..&& phase O..== O.sqlStrictText "quote",O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.admissionState=O.sqlStrictText "ExpiredUnfunded"},
        O.uWhere= \r->S.orderId r O..== O.sqlStrictText identifier O..&& O.in_ (map O.sqlStrictText ["Provisioning","AwaitingDeposit"]) (S.admissionState r),O.uReturning=O.rCount}
      pure ()

audit :: PG.Connection -> Text -> Text -> IO ()
audit c action detail = do
  _ <- O.runInsert c O.Insert {O.iTable=S.audit,O.iRows=[(Nothing,O.sqlStrictText action,O.sqlStrictText detail)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  pure ()

-- Promotion records a liability's payout terms; it does not sign, send or settle.
-- The writer transaction serializes duplicate receipts and competing promotions.
promotionCandidates :: PG.Connection -> IO [Text]
promotionCandidates c = O.runSelect c $ fmap snd $ O.limit 1000 $ O.orderBy (O.asc fst <> O.asc snd) $ do
  d <- O.selectTable S.deposits
  o <- O.selectTable S.orders
  O.where_ (O.matchNullable (O.sqlBool False) (O..== S.orderId o) (S.depositOrder d) O..&&
    S.depositEligible d O..== O.sqlInt8 1 O..&& S.depositAllocated d O..== O.sqlInt8 0 O..&&
    (S.admissionState o O..== O.sqlStrictText "Provisioning" O..|| S.admissionState o O..== O.sqlStrictText "AwaitingDeposit"))
  funded<-Exists.exists $ do
    ob<-O.selectTable S.obligations
    O.where_ (S.obligationOrder ob O..== S.orderId o)
    pure ()
  O.where_ (O.not funded)
  pure (S.depositSeen d,S.depositId d)

promoteDeposit :: PG.Connection -> PaymentTerms -> Int64 -> Text -> IO Bool
promoteDeposit c terms now identifier = do
  require (now>=0) "invalid_promotion_time"
  rows <- O.runSelect c $ do
    d <- O.selectTable S.deposits
    O.where_ (S.depositId d O..== O.sqlStrictText identifier)
    pure d
    :: IO [S.Deposit]
  d <- case rows of [one]->pure one; _->reject "deposit_not_found"
  case S.depositOrder d of
    Nothing -> pure False
    Just _ | S.depositAllocated d==1 || S.depositEligible d==0 -> pure False
    Just oid -> do
      orders <- O.runSelect c $ do
        o <- O.selectTable S.orders
        O.where_ (S.orderId o O..== O.sqlStrictText oid)
        pure o
        :: IO [S.Order]
      o <- case orders of [one]->pure one; _->reject "order_not_found"
      request <- decodeSaved (S.requestJson o)
      savedQuote <- decodeSaved (S.quoteJson o)
      policy <- decodeSaved (S.policyJson o)
      previous <- O.runSelect c $ O.limit 1 $ do
        obligation <- O.selectTable S.obligations
        O.where_ (S.obligationOrder obligation O..== O.sqlStrictText oid O..&& S.obligationKind obligation O..== O.sqlStrictText "conversion")
        pure (S.obligationId obligation)
        :: IO [Text]
      receipt<-asDeposit d
      payments<-customerPayments c oid
      (status,payout)<-checked $ projectCustomer (S.admissionState o) False payments
      let order=W.OrderView oid request savedQuote status (S.deadline o) (S.instruction o) payout policy
      decision<-checked $ decidePromotion (deploymentFingerprint $ paymentPolicy terms) now
        (PromotionFacts order receipt (S.graceDeadline o) (not $ null previous))
      case decision of
       Nothing->do
        when (status/="Paid") $ void $ O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.admissionState=O.sqlStrictText "NeedsReview"},
          O.uWhere= \r->S.orderId r O..== O.sqlStrictText oid,O.uReturning=O.rCount}
        pure False
       Just outgoing->do
        holds <- O.runSelect c $ do
          (key,asset,n,phase) <- O.selectTable S.reservations
          O.where_ (key O..== O.sqlStrictText oid)
          pure (asset,n,phase)
          :: IO [(Text,Int64,Text)]
        costs <- O.runSelect c $ do
          (key,nativeFee,solFee,rent) <- O.selectTable S.orderCosts
          O.where_ (key O..== O.sqlStrictText oid)
          pure (nativeFee,solFee,rent)
          :: IO [(Int64,Int64,Int64)]
        (nativeFee,solFee,rent) <- case costs of [one]->pure one; _->reject "missing_order_cost_policy"
        limits<-checked (savedCostLimits nativeFee solFee rent)
        allowances <- O.runSelect c $ do
          (key,kind,asset,n,phase) <- O.selectTable S.operatingReservations
          O.where_ (key O..== O.sqlStrictText oid)
          pure (kind,asset,n,phase)
          :: IO [(Text,Text,Int64,Text)]
        checked (checkPromotionHolds order limits holds allowances)
        _ <- O.runInsert c O.Insert {O.iTable=S.obligations,
          O.iRows=[S.Obligation (O.sqlStrictText $ paymentId outgoing) (O.sqlStrictText oid) (O.sqlStrictText identifier)
            (O.sqlStrictText "conversion") (O.sqlStrictText $ T.pack $ show $ paymentAsset outgoing)
            (O.sqlInt8 $ units $ paymentAmount outgoing) (O.sqlStrictText $ paymentRecipient outgoing)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        _ <- O.runUpdate c O.Update {O.uTable=S.deposits,O.uUpdateWith= \r->r {S.depositAllocated=O.sqlInt8 1},
          O.uWhere= \r->S.depositId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
        _ <- O.runUpdate c O.Update {O.uTable=S.reservations,
          O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlStrictText "obligation"),
          O.uWhere= \(key,_,_,_)->key O..== O.sqlStrictText oid,O.uReturning=O.rCount}
        _ <- O.runUpdate c O.Update {O.uTable=S.operatingReservations,
          O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText "obligation"),
          O.uWhere= \(key,_,_,_,phase)->key O..== O.sqlStrictText oid O..&& phase O..== O.sqlStrictText "quote",O.uReturning=O.rCount}
        createPaymentRoot c outgoing
        pure True

readSource :: PG.Connection -> Text -> IO S.Deposit
readSource c identifier = do
  rows <- O.runSelect c $ do
    row <- O.selectTable S.deposits
    O.where_ (S.depositId row O..== O.sqlStrictText identifier)
    pure row
  case rows of [row]->pure row; _->reject "source_deposit_missing"
asDeposit :: S.Deposit -> IO W.Deposit
asDeposit row = W.Deposit (S.depositId row) (S.depositOrder row) <$> parseAsset (S.depositAsset row)
  <*> checked (amount $ toInteger $ S.depositAmount row) <*> pure (S.depositAnchor row)
  <*> pure (fromIntegral $ S.depositDepth row) <*> pure (S.depositEligible row==1) <*> pure (S.depositSeen row)
sourceEvidence :: PG.Connection -> Text -> IO (Text,Text)
sourceEvidence c txid = do
  rows <- O.runSelect c $ do
    (chain,key,kind,hash,review) <- S.eventHeads
    (proofHash,_,_,proof) <- O.selectTable S.observationEvidence
    O.where_ (chain O..== O.sqlStrictText "Native" O..&& key O..== O.sqlStrictText txid O..&& review O..== O.sqlInt8 0
      O..&& O.in_ (map O.sqlStrictText ["incoming","unmatched_incoming"]) kind O..&& hash O..== proofHash)
    pure (hash,proof)
  case rows of [saved]->pure saved; _->reject "source_recovery_scan_not_current"
sourceProof :: W.SourceCheck -> Value
sourceProof = \case W.SourcePending p->p; W.SourceMissing p->p; W.SourceRestored p->p; W.SourceUnavailable p->p

-- Internal to source observation/recovery operations. Unavailable evidence never
-- becomes a loss; replay cannot post value twice, and restoration never resumes.
recordSourceCheck :: PG.Connection -> S.Deposit -> W.SourceCheck -> IO ()
recordSourceCheck c source check = do
  let did=S.depositId source
  asset <- parseAsset (S.depositAsset source)
  history <- O.runSelect c $ O.limit 1 $ O.orderBy (O.desc (\(key,_,_,_,_,_)->key)) $ do
    row@(_,deposit,_,_,_,_) <- O.selectTable S.sourceChecks
    O.where_ (deposit O..== O.sqlStrictText did)
    pure row
    :: IO [(Int64,Text,Text,Int64,Text,Int64)]
  let old=case history of [(_,_,state,loss,savedProof,_)]->Just(state,loss,savedProof); _->Nothing
  deposit<-asDeposit source
  effect<-checked (decideSourceCheck deposit (S.depositAllocated source==1) old check)
  forM_ effect $ \decision->do
    let state=sourceState decision; loss=sourceLoss decision; evidence=sourceCheckEvidence decision; delta=sourceLossDelta decision
    sequenceNo <- nextSequence c
    _ <- O.runInsert c O.Insert {O.iTable=S.sourceChecks,
      O.iRows=[(Nothing,O.sqlStrictText did,O.sqlStrictText state,O.sqlInt8 loss,O.sqlStrictText evidence,O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    when (delta/=0) $ post c ("source-recovery:"<>T.pack(show sequenceNo)) "change in verified missing source value"
      (sourcePostings decision)
    when (delta<0) $ do
      covers <- O.runSelect c $ do
        (key,deposit,n,capital,earned) <- S.activeSourceCovers
        O.where_ (deposit O..== O.sqlStrictText did)
        pure (key,n,capital,earned)
        :: IO [(Int64,Int64,Int64,Int64)]
      forM_ covers $ \(covered,n,capital,earned)->do
        postings<-checked (sourceReturnPostings asset (negate delta) (n,capital,earned))
        _ <- O.runInsert c O.Insert {O.iTable=S.sourceReturns,O.iRows=[(O.sqlInt8 covered,O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        post c ("source-loss-return:"<>T.pack(show covered)) "restored source returns its operator loss allocation"
          postings
    _ <- O.runUpdate c O.Update {O.uTable=S.deployment,
      O.uUpdateWith= \row->row {S.paused=O.sqlInt8 1,S.pauseReason=O.sqlStrictText "source_recovery_review"},
      O.uWhere= \row->S.singleton row O..== O.sqlInt8 1,O.uReturning=O.rCount}
    audit c "source_recovery" (did<>":"<>state)

-- Preserve the existing hash preimage exactly: changing it invalidates saved
-- source-restoration and replacement approvals. Queries project only bound work.
sourceWorkHash :: PG.Connection -> Text -> IO Text
sourceWorkHash=workHash True
paymentWorkHash :: PG.Connection -> Text -> IO Text
paymentWorkHash=workHash False
workHash :: Bool -> PG.Connection -> Text -> IO Text
workHash includeReplacements c intent = do
  obligations <- O.runSelect c $ do
    r <- O.selectTable S.obligations
    O.where_ (S.obligationId r O..== O.sqlStrictText intent)
    pure (S.obligationId r,S.obligationOrder r,S.obligationDeposit r,S.obligationKind r,S.obligationAsset r,S.obligationAmount r,S.obligationRecipient r)
    :: IO [(Text,Text,Text,Text,Text,Int64,Text)]
  work <- O.runSelect c $ do
    (key,chain,resolved,common) <- P.workIntents
    O.where_ (key O..== O.sqlStrictText intent)
    pure (chain,resolved O..== O.sqlInt8 1,common)
    :: IO [(Text,Bool,Maybe Text)]
  preparations <- O.runSelect c $ O.orderBy (O.asc (\(n,_,_,_,_)->n)) $ do
    (key,n,policy,draft,retired,cancelled) <- S.workPreparations
    O.where_ (key O..== O.sqlStrictText intent)
    pure (n,policy,draft,retired,cancelled O..== O.sqlInt8 1)
    :: IO [(Int64,Text,Maybe Text,Maybe Text,Bool)]
  attempts <- O.runSelect c $ O.orderBy (O.asc (\(_,_,n,_,_)->n) <> O.asc (\(tx,_,_,_,_)->tx)) $ do
    (tx,key,state,n,sequenceNo,observation) <- S.workAttempts
    O.where_ (key O..== O.sqlStrictText intent)
    pure (tx,state,n,sequenceNo,observation)
    :: IO [(Text,Text,Int64,Maybe Int64,Maybe Text)]
  cancellations <- O.runSelect c $ O.orderBy (O.asc (\(n,_,_,_)->n)) $ do
    (key,n,reason,cleanup,completed) <- S.workCancellations
    O.where_ (key O..== O.sqlStrictText intent)
    pure (n,reason,cleanup,completed O..== O.sqlInt8 1)
    :: IO [(Int64,Text,Text,Bool)]
  fees <- O.runSelect c $ do
    (key,asset,n,released) <- S.workFees
    O.where_ (key O..== O.sqlStrictText intent)
    pure (asset,n,released O..== O.sqlInt8 1)
    :: IO [(Text,Int64,Bool)]
  drafts <- O.runSelect c $ O.orderBy (O.asc (\(n,_,_,_,_,_)->n)) $ do
    draft@(_,parent,_,_,_,_) <- S.replacementDrafts
    (tx,key,_,_,_,_) <- S.workAttempts
    O.where_ (parent O..== tx O..&& key O..== O.sqlStrictText intent)
    pure draft
    :: IO [(Int64,Text,Int64,Text,Text,Text)]
  cancelled <- O.runSelect c $ O.orderBy (O.asc (\(_,_,n)->n)) $ do
    decision@(draft,_,_) <- S.replacementCancellations
    (n,parent,_,_,_,_) <- S.replacementDrafts
    (tx,key,_,_,_,_) <- S.workAttempts
    O.where_ (draft O..== n O..&& parent O..== tx O..&& key O..== O.sqlStrictText intent)
    pure decision
    :: IO [(Int64,Text,Int64)]
  let hashJson=digest . BL.toStrict . encode
      base=hashJson (obligations,work,preparations,attempts,cancellations,fees)
  pure (if not includeReplacements || null drafts && null cancelled then base else digest $ BL.toStrict $ encode (base,drafts,cancelled))

readCheckpoint :: PG.Connection -> Text -> IO (Maybe Text)
readCheckpoint c chain = do
  require (chain `elem` map fst scanAssets) "invalid_scan_chain"
  rows <- O.runSelect c $ do
    (key,anchor) <- O.selectTable S.checkpoints
    O.where_ (key O..== O.sqlStrictText chain)
    pure anchor
  case rows of []->pure Nothing; [anchor]->pure(Just anchor); _->reject "duplicate_checkpoint"

observeDeposit :: PG.Connection -> W.Deposit -> IO ()
observeDeposit c deposit = do
  let did=W.depositId deposit; currency=W.depositAsset deposit; quantity=W.depositAmount deposit
      seen=W.depositSeenAt deposit; depth=W.depositConfirmations deposit; eligible=W.depositEligible deposit
      oid=W.depositOrder deposit; anchor=W.depositAnchor deposit
  require (units quantity>0 && depth>=0 && seen>=0 && not(T.null did) && T.length did<=160) "invalid_deposit"
  forM_ oid $ \identifier->do
    orders <- O.runSelect c $ do
      row <- O.selectTable S.orders
      O.where_ (S.orderId row O..== O.sqlStrictText identifier)
      pure (S.requestJson row,S.policyJson row)
      :: IO [(Text,Text)]
    (request,savedPolicy) <- case orders of
      [(request,policy)]->(,) <$> decodeSaved request <*> decodeSaved policy
      _->reject "deposit_order_missing"
    require (sourceAsset (W.direction request)==currency) "deposit_asset_mismatch"
    when (currency==Native && eligible) $ require (depth>=nativeDepth savedPolicy) "deposit_confirmation_policy_mismatch"
  old <- O.runSelect c $ do
    row <- O.selectTable S.deposits
    O.where_ (S.depositId row O..== O.sqlStrictText did)
    pure row
    :: IO [S.Deposit]
  let bit=if eligible then 1 else 0; text=O.sqlStrictText; num=O.sqlInt8
  case old of
    [] -> do
      _ <- O.runInsert c O.Insert {O.iTable=S.deposits,
        O.iRows=[S.Deposit (text did) (maybe O.null (O.toNullable . text) oid) (text $ T.pack $ show currency)
          (num $ units quantity) (text anchor) (num seen) (num $ fromIntegral depth) (num bit) (num 0) (text "observed")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      post c ("deposit:"<>did) "observed customer value"
        [Posting currency (maybe Unallocated (const Principal) oid) (toInteger $ units quantity),Posting currency External (negate $ toInteger $ units quantity)]
    [previous] -> do
      reviewed<-if S.depositEligible previous==1 && not eligible then O.runSelect c (do
        (key,_,receipt,state)<-P.orderObligations
        O.where_ (receipt O..== text did O..&& O.in_ (map text ["ready","paying"]) state)
        pure (key,state)) else pure []
        :: IO [(Text,Text)]
      require (S.depositOrder previous==oid && S.depositAsset previous==T.pack(show currency) && S.depositAmount previous==units quantity) "conflicting_deposit_evidence"
      _ <- O.runUpdate c O.Update {O.uTable=S.deposits,
        O.uUpdateWith= \r->r {S.depositAnchor=text anchor,S.depositDepth=num $ fromIntegral depth,S.depositEligible=num bit},
        O.uWhere= \r->S.depositId r O..== text did,O.uReturning=O.rCount}
      current <- readSource c did
      when (S.depositEligible previous==1 && not eligible) $ do
        work <- forM reviewed $ \(intent,state)->do
          hash <- sourceWorkHash c intent
          pure $ object ["intent" .= intent,"previousStatus" .= state,"workHash" .= hash]
        recordSourceCheck c current $ W.SourceUnavailable $ object ["reason" .= ("source_eligibility_lost"::Text),
          "previousAnchor" .= S.depositAnchor previous,"anchor" .= anchor,"reviewedObligations" .= work]
      when (currency/=Native && eligible) $ do
        history <- O.runSelect c $ O.limit 1 $ O.orderBy (O.desc (\(n,_,_)->n)) $ do
          (key,source,state,loss,_,_) <- O.selectTable S.sourceChecks
          O.where_ (source O..== text did)
          pure (key,state,loss)
          :: IO [(Int64,Text,Int64)]
        case history of
          [(_,state,0)] | state/="restored"->recordSourceCheck c current (W.SourceRestored $ object ["anchor" .= anchor,"verifiedBy" .= ("source_observer"::Text)])
          _->pure ()
      when (not eligible && S.depositAllocated previous==1) $ do
        covered <- O.runSelect c $ do
          key <- S.accountedLosses
          O.where_ (key O..== text did)
          pure key
          :: IO [Text]
        when (null covered) $ pauseScan c "source_reorg_review"
    _->reject "duplicate_deposit"

pauseScan :: PG.Connection -> Text -> IO ()
pauseScan c reason = do
  _ <- O.runUpdate c O.Update {O.uTable=S.deployment,
    O.uUpdateWith= \r->r {S.paused=O.sqlInt8 1,S.pauseReason=O.sqlStrictText reason},
    O.uWhere= \r->S.singleton r O..== O.sqlInt8 1,O.uReturning=O.rCount}
  pure ()
scanHealth :: PG.Connection -> Text -> Int64 -> Maybe Text -> IO ()
scanHealth c chain now failure = do
  old <- O.runSelect c $ do
    (key,success,_,_) <- O.selectTable S.scanHealth
    O.where_ (key O..== O.sqlStrictText chain)
    pure success
    :: IO [Maybe Int64]
  let nullable=maybe O.null (O.toNullable . O.sqlInt8)
      success=if failure==Nothing then Just now else case old of [prior]->prior; _->Nothing
      row=(O.sqlStrictText chain,nullable success,maybe O.null (O.toNullable . O.sqlStrictText) failure,O.sqlInt8 now)
  case old of
    []->O.runInsert c O.Insert {O.iTable=S.scanHealth,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing} >> pure ()
    [_]->O.runUpdate c O.Update {O.uTable=S.scanHealth,O.uUpdateWith=const row,O.uWhere= \(key,_,_,_)->key O..== O.sqlStrictText chain,O.uReturning=O.rCount} >> pure ()
    _->reject "duplicate_scan_health"
scanFailed :: PG.Connection -> Text -> Int64 -> Text -> IO ()
scanFailed c chain now code = do
  require (chain `elem` map fst scanAssets && now>=0 && not(T.null code) && T.length code<=160) "invalid_scan_failure"
  old <- O.runSelect c $ do
    (key,_,failure,_) <- O.selectTable S.scanHealth
    O.where_ (key O..== O.sqlStrictText chain)
    pure failure
    :: IO [Maybe Text]
  when (old/=[Just code]) $ audit c "scanner_failure" (chain<>":"<>code)
  scanHealth c chain now (Just code)
  pauseScan c ((if code=="rpc_rate_limited" then "rpc_rate_limited:" else "scanner_unavailable:")<>chain)

commitScan :: PG.Connection -> W.ScanBatch -> IO ()
commitScan c batch = do
  let chain=W.scanChain batch; now=W.scanTime batch; origin=W.scanOrigin batch; next=W.scanNext batch
      deposits=W.scanDeposits batch; events=W.scanEvents batch; text=O.sqlStrictText; num=O.sqlInt8
  -- Validate the envelope before selecting its closed stream; then bind current
  -- cursor/origin before any deposit, evidence or coverage mutation.
  checked (checkScanBatch batch)
  previous <- readCheckpoint c chain
  origins <- O.runSelect c $ do
    (key,anchor) <- O.selectTable S.scanOrigins
    O.where_ (key O..== text chain)
    pure anchor
    :: IO [Text]
  checked (checkScan batch previous origins)
  when (null origins) $ void $ O.runInsert c O.Insert {O.iTable=S.scanOrigins,
    O.iRows=[(text chain,text origin)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  mapM_ (observeDeposit c) deposits
  forM_ events $ \event->do
    let identifier=W.chainEventId event; anchor=W.chainEventAnchor event; kind=W.chainEventKind event
        paymentChain=if chain=="SolanaOperating" then "Solana" else chain
    evidence<-checked (checkObservation chain event)
    attempts <- O.runSelect c $ do
      (tx,intent,state,_,sequenceNo,observation) <- S.workAttempts
      (key,currency,_,_) <- P.workIntents
      O.where_ (intent O..== key O..&& tx O..== text identifier O..&& currency O..== text paymentChain)
      pure (state,sequenceNo,observation)
      :: IO [(Text,Maybe Int64,Maybe Text)]
    formerWinners <- O.runSelect c $ do
      (tx,observation) <- S.winnerHistory
      O.where_ (tx O..== text identifier)
      pure observation
      :: IO [Text]
    treasury <- O.runSelect c $ do
      (currency,key,approvedAnchor,economic) <- S.treasurySpendEffects
      O.where_ (currency O..== text chain O..&& key O..== text identifier)
      pure (approvedAnchor,economic)
      :: IO [(Text,Text)]
    let review=observationNeedsReview chain event (ObservationFacts attempts formerWinners treasury)
        bit=if review then 1 else 0; hash=digest (TE.encodeUtf8 evidence)
    proofs <- O.runSelect c $ do
      (key,_,_,_) <- O.selectTable S.observationEvidence
      O.where_ (key O..== text hash)
      pure key
      :: IO [Text]
    when (null proofs) $ do
      _ <- O.runInsert c O.Insert {O.iTable=S.observationEvidence,O.iRows=[(text hash,text chain,text identifier,text evidence)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    old <- O.runSelect c $ do
      row <- O.selectTable S.chainEvents
      O.where_ (S.eventChain row O..== text chain O..&& S.eventId row O..== text identifier)
      pure (S.eventId row)
      :: IO [Text]
    case old of
      [] -> O.runInsert c O.Insert {O.iTable=S.chainEvents,
        O.iRows=[S.ChainEvent (text chain) (text identifier) (text kind) (text anchor) (text hash) (num now) (num now) (num bit)],O.iReturning=O.rCount,O.iOnConflict=Nothing} >> pure ()
      [_] -> O.runUpdate c O.Update {O.uTable=S.chainEvents,
        O.uUpdateWith= \r->r {S.eventKind=text kind,S.eventAnchor=text anchor,S.eventHash=text hash,S.eventLastSeen=num now,
          S.eventReview=O.ifThenElse (S.eventReview r O..> num bit) (S.eventReview r) (num bit)},
        O.uWhere= \r->S.eventChain r O..== text chain O..&& S.eventId r O..== text identifier,O.uReturning=O.rCount} >> pure ()
      _->reject "duplicate_chain_event"
    when review (pauseScan c $ "chain_review:"<>chain<>":"<>kind)
  case previous of
    Nothing->O.runInsert c O.Insert {O.iTable=S.checkpoints,O.iRows=[(text chain,text next)],O.iReturning=O.rCount,O.iOnConflict=Nothing} >> pure ()
    Just _->O.runUpdate c O.Update {O.uTable=S.checkpoints,O.uUpdateWith=const(text chain,text next),O.uWhere= \(key,_)->key O..== text chain,O.uReturning=O.rCount} >> pure ()
  scanHealth c chain now Nothing

lookupInstruction :: PG.Connection -> Text -> IO (Maybe (Text,W.OrderRequest,W.PolicySnapshot))
lookupInstruction connection instruction = do
  rows <- O.runSelect connection $ do
    row <- O.selectTable S.orders
    O.where_ (O.matchNullable (O.sqlBool False) (\value->value O..== O.sqlStrictText instruction) (S.instruction row))
    pure (S.orderId row,S.requestJson row,S.policyJson row)
    :: IO [(Text,Text,Text)]
  case rows of
    []->pure Nothing
    [(oid,req,savedPolicy)]->Just <$> ((,,) oid <$> decodeSaved req <*> decodeSaved savedPolicy)
    _->reject "duplicate_deposit_instruction"

maximumNativeDepth :: PG.Connection -> Int -> IO Int
maximumNativeDepth connection minimumDepth = do
  rows <- O.runSelect connection $ O.distinct $ fmap S.policyJson (O.selectTable S.orders) :: IO [Text]
  policies <- mapM decodeSaved rows
  pure (maximum (minimumDepth:1:map W.nativeDepth policies))

pendingVerification :: PG.Connection -> IO [Text]
pendingVerification c = O.runSelect c $ fmap snd $ O.limit 1000 $ O.orderBy (O.asc fst <> O.asc snd) $ do
  row <- O.selectTable S.chainEvents
  O.where_ (S.eventChain row O..== O.sqlStrictText "Solana" O..&& S.eventKind row O..== O.sqlStrictText "awaiting_verifier")
  pure (S.eventFirstSeen row,S.eventId row)

lookupReferences :: PG.Connection -> [Text] -> IO (Maybe (Text,W.OrderRequest,W.PolicySnapshot,Text))
lookupReferences c keys = do
  require (length keys<=256) "too_many_reference_keys"
  rows <- O.runSelect c $ O.limit 2 $ do
    row <- O.selectTable S.orders
    O.where_ (O.matchNullable (O.sqlBool False) (O.in_ $ map (O.sqlStrictText . ("solana-pay:"<>)) keys) (S.instruction row))
    pure (S.orderId row,S.requestJson row,S.policyJson row,S.instruction row)
    :: IO [(Text,Text,Text,Maybe Text)]
  case rows of
    [(oid,request,policy,Just instruction)] | Just reference<-T.stripPrefix "solana-pay:" instruction ->
      Just <$> ((,,,) oid <$> decodeSaved request <*> decodeSaved policy <*> pure reference)
    _->pure Nothing

-- One durable payment view for all three funding purposes. It does not authorize
-- signing: source/custody, active generation and backup are checked at that boundary.
readPayment :: PG.Connection -> Text -> Text -> IO PaymentView
readPayment c identity identifier = do
  (root,state)<-readPaymentRoot c identifier
  obligations <- O.runSelect c $ do
    row <- O.selectTable S.obligations
    O.where_ (S.obligationId row O..== O.sqlStrictText identifier)
    pure row
    :: IO [S.Obligation]
  withdrawal <- maybe (pure Nothing) (readWithdrawal c) (T.stripPrefix "fee:" identifier)
  result <- case (obligations,withdrawal) of
    ([ob],Nothing) -> do
      rows <- O.runSelect c $ do
        order <- O.selectTable S.orders
        deposit <- O.selectTable S.deposits
        (key,nativeFee,solanaFee,rent) <- O.selectTable S.orderCosts
        O.where_ (S.orderId order O..== O.sqlStrictText (S.obligationOrder ob) O..&&
          S.depositId deposit O..== O.sqlStrictText (S.obligationDeposit ob) O..&& key O..== S.orderId order)
        pure (order,deposit,nativeFee,solanaFee,rent)
        :: IO [(S.Order,S.Deposit,Int64,Int64,Int64)]
      (order,deposit,nativeFee,solanaFee,rent) <- case rows of [row]->pure row; _->reject "payment_funding_missing"
      request <- decodeSaved (S.requestJson order)
      termsQuote <- decodeSaved (S.quoteJson order)
      policy <- decodeSaved (S.policyJson order)
      costs <- CostLimits <$> quantity nativeFee <*> quantity solanaFee <*> quantity rent
      require (nativeFee>0 && solanaFee>0 && W.input request==gross termsQuote &&
        S.depositOrder deposit==Just (S.orderId order) && S.depositAllocated deposit==1) "payment_funding_mismatch"
      asset <- parseAsset (S.depositAsset deposit)
      n <- quantity (S.depositAmount deposit)
      funding <- case S.obligationKind ob of
        "conversion" -> do
          require (asset==sourceAsset(W.direction request) && n==gross termsQuote && S.obligationRecipient ob==W.recipient request) "payment_funding_mismatch"
          checked (conversion (S.orderId order) (S.depositId deposit) (W.direction request) termsQuote)
        "refund" -> checked (refund (S.orderId order) (S.depositId deposit) asset n)
        _ -> reject "unknown_payment_funding"
      outgoing <- checked (payment identifier funding (S.obligationRecipient ob))
      require (T.pack(show $ paymentAsset outgoing)==S.obligationAsset ob && units(paymentAmount outgoing)==S.obligationAmount ob) "payment_funding_mismatch"
      pure (PaymentView outgoing (PaymentTerms policy costs) state)
    ([],Just saved) -> pure (PaymentView (withdrawalPayment saved) (withdrawalTerms saved) state)
    ([],Nothing)->reject "payment_not_found"
    _->reject "ambiguous_payment_funding"
  let outgoing=savedPayment result
      (obligation,withdrawal,receipt)=case paymentFunding outgoing of
        Conversion _ source _ _->(Just identifier,Nothing,Just source)
        Refund _ source _ _->(Just identifier,Nothing,Just source)
        EarnedFees key _ _->(Nothing,Just key,Nothing)
  require (S.rootObligation root==obligation && S.rootWithdrawal root==withdrawal && S.rootDeposit root==receipt
    && S.rootChain root==(if paymentAsset outgoing==Native then "Native" else "Solana")) "payment_funding_mismatch"
  require (deploymentFingerprint (paymentPolicy $ savedTerms result)==identity) "payment_profile_mismatch"
  pure result
 where quantity=checked . amount . toInteger

-- These helpers are private to closed Store operations. They do not accept a
-- query callback or grant a caller the ability to commit an arbitrary decision.
readPaymentRoot :: PG.Connection -> Text -> IO (S.PaymentRoot,PaymentStatus)
readPaymentRoot c key = do
  rows<-O.runSelect c $ do
    row@(root,_)<-P.paymentStates
    O.where_ (S.rootId root O..== O.sqlStrictText key)
    pure row
    :: IO [(S.PaymentRoot,Text)]
  case rows of
    [(root,state)]->do
      _<-rootPhase root
      (root,) <$> checked (parsePaymentStatus state)
    []->reject "payment_not_found"
    _->reject "ambiguous_payment_funding"

rootPhase :: S.PaymentRoot -> IO PaymentPhase
rootPhase root=checked $ decodePaymentPhase (S.rootPhase root,S.rootGeneration root,S.rootWinner root,S.rootSettlementEvent root)

createPaymentRoot :: PG.Connection -> Payment -> IO ()
createPaymentRoot c outgoing = do
  let key=paymentId outgoing; text=O.sqlStrictText; nullable=maybe O.null (O.toNullable.text)
      (obligation,withdrawal,receipt)=case paymentFunding outgoing of
        Conversion _ source _ _->(Just key,Nothing,Just source)
        Refund _ source _ _->(Just key,Nothing,Just source)
        EarnedFees identifier _ _->(Nothing,Just identifier,Nothing)
      chain=if paymentAsset outgoing==Native then "Native" else "Solana"
  n<-O.runInsert c O.Insert {O.iTable=S.paymentRoots,
    O.iRows=[S.PaymentRoot (text key) (nullable obligation) (nullable withdrawal) (nullable receipt) (text chain) O.null (text "ready") O.null O.null O.null],
    O.iReturning=O.rCount,O.iOnConflict=Nothing}
  require (n==1) "payment_root_insert_failed"
  forM_ (customerFunding $ paymentFunding outgoing) $ \(order,_)->acceptCustomerPayment c order

-- Only a committed, validated payment transition supersedes admission review.
-- Reads never hide a retained flag. Source/retry/winner restrictions are separate
-- evidence and cannot be cleared here; this stores no execution progress.
acceptCustomerPayment :: PG.Connection -> Text -> IO ()
acceptCustomerPayment c order = void $ O.runUpdate c O.Update
  {O.uTable=S.orders,O.uUpdateWith= \row->row {S.admissionState=O.sqlStrictText "AwaitingDeposit"},
    O.uWhere= \row->S.orderId row O..== O.sqlStrictText order O..&& S.admissionState row O..== O.sqlStrictText "NeedsReview",O.uReturning=O.rCount}

setPaymentPhase :: PG.Connection -> Text -> PaymentPhase -> IO ()
setPaymentPhase c key economic = do
  let (phase,generation,winner,event)=encodePaymentPhase economic
      text=O.sqlStrictText; nullable=maybe O.null (O.toNullable.text)
  n<-O.runUpdate c O.Update {O.uTable=S.paymentRoots,
    O.uUpdateWith= \root->root {S.rootPhase=text phase,S.rootGeneration=maybe O.null (O.toNullable.O.sqlInt8) generation,
      S.rootWinner=nullable winner,S.rootSettlementEvent=nullable event},
    O.uWhere= \root->S.rootId root O..== text key,O.uReturning=O.rCount}
  require (n==1) "payment_root_update_failed"

operatingTime :: PG.Connection -> IO Int64
operatingTime c = do
  wallTime <- floor <$> getPOSIXTime
  times <- O.runUpdate c O.Update {O.uTable=S.operatingClock,
    O.uUpdateWith= \(key,old)->(key,O.ifThenElse (old O..> O.sqlInt8 wallTime) old (O.sqlInt8 wallTime)),
    O.uWhere= \(key,_)->key O..== O.sqlInt8 1,O.uReturning=O.rReturning snd}
  case times of [t]->pure t; _->reject "operating_clock_missing"

readFeeBudget :: PG.Connection -> OrderLimits -> M.Map (Asset,Account) Integer -> Int64 -> Asset -> IO FeeBudget
readFeeBudget c limits booked now asset = do
  held<-operatingHolds c asset
  spending <- O.runSelect c $ do
    (posting,_,currency,_,delta) <- O.selectTable S.postings
    (cost,at) <- O.selectTable S.operatingCosts
    O.where_ (posting O..== cost O..&& currency O..== O.sqlStrictText(T.pack $ show asset) O..&& at O..> O.sqlInt8 (now-86400))
    pure delta
    :: IO [Int64]
  pure $ FeeBudget (M.findWithDefault 0 (asset,Operating) booked) held (negate $ sum $ map toInteger spending)
    (if asset==Native then nativeDaily limits else solanaDaily limits)

readPreparation :: PG.Connection -> Text -> Text -> IO PreparedPayment
readPreparation c identity identifier = do
  (prepared,cancelling)<-preparationState c identity identifier
  require (not cancelling) "preparation_cancellation_pending"
  pure prepared

-- Recovery may inspect a pending cancellation, but ordinary signing may not.
preparationState :: PG.Connection -> Text -> Text -> IO (PreparedPayment,Bool)
preparationState c identity identifier = do
  view <- readPayment c identity identifier
  rows <- O.runSelect c $ do
    intent <- O.selectTable S.paymentRoots
    (key,generation,policy,draft,retired,cancelled) <- O.selectTable S.preparations
    (feeKey,asset,n,released) <- O.selectTable S.feeHolds
    O.where_ (S.rootId intent O..== O.sqlStrictText identifier O..&& key O..== S.rootId intent O..&& feeKey O..== key
      O..&& S.rootPhase intent O..== O.sqlStrictText "active"
      O..&& O.matchNullable (O.sqlBool False) (O..== generation) (S.rootGeneration intent)
      O..&& O.isNull retired O..&& cancelled O..== O.sqlInt8 0 O..&& released O..== O.sqlInt8 0)
    pure (generation,policy,draft,asset,n)
    :: IO [(Int64,Text,Maybe Text,Text,Int64)]
  (generation,policy,draft,asset,n) <- case rows of [row]->pure row; _->reject "preparation_not_found"
  require (generation>=0 && generation<8 && asset==if paymentAsset(savedPayment view)==Native then "Native" else "Sol") "invalid_preparation"
  cancellations <- O.runSelect c $ do
    (key,g,_,_,_) <- S.workCancellations
    O.where_ (key O..== O.sqlStrictText identifier O..&& g O..== O.sqlInt8 generation)
    pure key
    :: IO [Text]
  require (length cancellations<=1) "duplicate_preparation_cancellation"
  fee<-checked (amount $ toInteger n)
  pure (PreparedPayment view (fromIntegral generation) policy draft fee,not $ null cancellations)

preparePayment :: PG.Connection -> StorePolicy -> Int64 -> Text -> Amount -> Text -> IO PreparedPayment
preparePayment c config now identifier allowance plan = do
  let identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
      text=O.sqlStrictText; num=O.sqlInt8
  validateSavedJson 16384 plan
  view<-readPayment c identity identifier
  checked (checkPreparationInput allowance plan view)
  let outgoing=savedPayment view; funding=paymentFunding outgoing
      chain=if paymentAsset outgoing==Native then "Native" else "Solana"
      currency=if chain=="Native" then Native else Sol
  (root,_)<-readPaymentRoot c identifier
  economic<-rootPhase root
  history<-case economic of
    Active{}->LivePreparation (S.rootChain root) <$> readPreparation c identity identifier
    Ready->do
      existing<-O.runSelect c $ O.limit 1 $ do
        (key,_,_,_,_,_)<-S.workPreparations
        O.where_ (key O..== text identifier)
        pure key
        :: IO [Text]
      if null existing then pure InitialPreparation else RetiredPreparation chain <$> retryGeneration c identifier
    _->reject "preparation_retry_requires_recovery"
  admission<-case history of
    LivePreparation{}->pure Nothing
    RetiredPreparation _ Nothing->pure Nothing
    _->Just <$> readPreparationAdmission c config now view history
  decision<-checked (decidePreparation allowance plan $ PreparationFacts view history admission)
  case decision of
    ReusePreparation saved->pure saved
    CreatePreparation prepared->do
      let generation=preparedGeneration prepared; initial=generation==0
      when initial $ forM_ (customerFunding funding) $ \(order,kind)->
        one "operating_reservation_missing" $ O.runUpdate c O.Update {O.uTable=S.operatingReservations,
          O.uUpdateWith= \(key,purpose,asset,n,_)->(key,purpose,asset,n,text "transferred"),
          O.uWhere= \(key,purpose,asset,n,phase)->key O..== text order O..&& purpose O..== text kind
            O..&& asset O..== text(T.pack $ show currency) O..&& n O..>= num(units allowance)
            O..&& O.in_ (map text ["quote","obligation"]) phase,O.uReturning=O.rCount}
      _<-nextSequence c
      if initial then do
        one "payment_fee_hold_insert_failed" $ O.runInsert c O.Insert {O.iTable=S.feeHolds,O.iRows=[(text identifier,text $ T.pack(show currency),num $ units allowance,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      else do
        one "payment_fee_hold_update_failed" $ O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,a,_,_)->(key,a,num $ units allowance,num 0),O.uWhere= \(key,_,_,_)->key O..== text identifier,O.uReturning=O.rCount}
      one "preparation_insert_failed" $ O.runInsert c O.Insert {O.iTable=S.preparations,O.iRows=[(text identifier,num(fromIntegral generation),text plan,O.null,O.null,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      setPaymentPhase c identifier (Active generation)
      forM_ (customerFunding funding) $ \(order,_)->do
        acceptCustomerPayment c order
        _<-O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(key,asset,n,phase)->(key,asset,n,O.ifThenElse (phase O..== text "obligation") (text "payment") phase),O.uWhere= \(key,_,_,_)->key O..== text order,O.uReturning=O.rCount}
        pure ()
      readPreparation c identity identifier
 where
  one code action=action >>= \count->require (count==1) code

-- Only this closed operation loads admission facts. In particular, the budget is
-- read before transferring/replacing this payment's hold; the decision subtracts
-- exactly that hold once. All reads and resulting writes share the deployment lock.
readPreparationAdmission :: PG.Connection -> StorePolicy -> Int64 -> PaymentView -> PreparationHistory -> IO PreparationAdmission
readPreparationAdmission c config now view history = do
  let outgoing=savedPayment view; identifier=paymentId outgoing; funding=paymentFunding outgoing
      identity=deploymentFingerprint $ paymentPolicy $ savedTerms view
      native=paymentAsset outgoing==Native; chain=if native then "Native" else "Solana"
      currency=if native then Native else Sol; text=O.sqlStrictText
  readiness<-readIntake c identity now
  busy<-O.runSelect c $ O.limit 1 $ do
    row<-O.selectTable S.paymentRoots
    O.where_ (S.rootChain row O..== text chain O..&& S.rootPhase row O..== O.sqlStrictText "active")
    pure(S.rootId row)
    :: IO [Text]
  eligible<-paymentSourceEligible c outgoing
  fees<-case history of
    RetiredPreparation _ (Just generation)->O.runSelect c $ O.limit 2 $ do
      (key,asset,n,released)<-O.selectTable S.feeHolds
      (p,g,_,_,retired,_)<-S.workPreparations
      O.where_ (key O..== text identifier O..&& p O..== key O..&& g O..== O.sqlInt8(fromIntegral generation-1))
      pure(asset,n,released,retired)
    _->pure []
    :: IO [(Text,Int64,Int64,Maybe Text)]
  holds<-case (history,customerFunding funding) of
    (InitialPreparation,Just(order,kind))->O.runSelect c $ O.limit 2 $ do
      (key,purpose,asset,n,phase)<-O.selectTable S.operatingReservations
      O.where_ (key O..== text order O..&& purpose O..== text kind O..&& asset O..== text(T.pack $ show currency)
        O..&& O.in_ (map text ["quote","obligation"]) phase)
      pure n
    _->pure []
    :: IO [Int64]
  let quantity=either (const Nothing) Just . amount . toInteger
      previous=case fees of
        [(asset,n,released,retired)] | released `elem` [0,1]->
          PriorFeeHold <$> lookup asset [("Native",Native),("Sol",Sol)] <*> quantity n <*> pure(released==1) <*> pure(retired/=Nothing)
        _->Nothing
      held=case holds of [n]->quantity n; _->Nothing
  booked<-balances c
  at<-operatingTime c
  budget<-readFeeBudget c (admissionLimits config) booked at currency
  pure $ PreparationAdmission readiness (not $ null busy) eligible previous held
    (M.findWithDefault 0 (paymentAsset outgoing,FeePending) booked) budget

customerFunding :: Funding -> Maybe (Text,Text)
customerFunding (Conversion order _ _ _) = Just(order,"conversion")
customerFunding (Refund order _ _ _) = Just(order,"refund")
customerFunding EarnedFees{} = Nothing

validateSavedJson :: Int -> Text -> IO ()
validateSavedJson limit value = do
  require (not(T.null value) && T.length value<=limit) "invalid_payment_record"
  decoded <- decodeSaved value :: IO Value
  require (decoded/=Null) "invalid_payment_record"
saveDraft :: PG.Connection -> Text -> Text -> Int -> Text -> IO ()
saveDraft c identity identifier generation draft = do
  validateSavedJson 200000 draft
  prepared <- readPreparation c identity identifier
  require (generation==preparedGeneration prepared) "preparation_generation_changed"
  case preparedDraft prepared of
    Just saved -> require (saved==draft) "preparation_draft_conflict"
    Nothing -> do
      attempts <- O.runSelect c $ O.limit 1 $ do
        (tx,intent,_,g,_,_) <- S.workAttempts
        O.where_ (intent O..== O.sqlStrictText identifier O..&& g O..== O.sqlInt8(fromIntegral generation))
        pure tx
        :: IO [Text]
      require (null attempts) "preparation_already_signed"
      _ <- nextSequence c
      _ <- O.runUpdate c O.Update {O.uTable=S.preparations,
        O.uUpdateWith= \(key,g,policy,_,retired,cancelled)->(key,g,policy,O.toNullable $ O.sqlStrictText draft,retired,cancelled),
        O.uWhere= \(key,g,_,_,_,_)->key O..== O.sqlStrictText identifier O..&& g O..== O.sqlInt8(fromIntegral generation),O.uReturning=O.rCount}
      pure ()

readAttempt :: PG.Connection -> Text -> IO RecordedAttempt
readAttempt c identifier = do
  rows <- O.runSelect c $ do
    attempt <- O.selectTable S.attempts
    intent <- O.selectTable S.paymentRoots
    O.where_ (S.attemptId attempt O..== O.sqlStrictText identifier O..&& S.attemptIntent attempt O..== S.rootId intent)
    pure (attempt,S.rootChain intent,S.rootCommon intent)
    :: IO [(S.Attempt,Text,Maybe Text)]
  case rows of
    [(row,chain,common)] -> do
      require (S.attemptGeneration row>=0 && S.attemptGeneration row<8 && chain `elem` ["Native","Solana"]) "invalid_saved_attempt"
      allowance <- checked (amount $ toInteger $ S.attemptFee row)
      pure (RecordedAttempt (S.attemptIntent row) chain (fromIntegral $ S.attemptGeneration row) allowance
        (S.attemptState row) (S.attemptSequence row) (S.attemptObservation row)
        (SignedAttempt (S.attemptId row) (S.attemptBytes row) (S.attemptPolicy row) common))
    _ -> reject "attempt_not_found"

unsignedPreparation :: PG.Connection -> Text -> Text -> Int -> IO PreparedPayment
unsignedPreparation c identity identifier generation = do
  prepared <- readPreparation c identity identifier
  require (generation==preparedGeneration prepared) "preparation_generation_changed"
  paymentSource c (savedPayment $ preparedView prepared)
  require (savedStatus(preparedView prepared)==PaymentPaying && preparedDraft prepared/=Nothing) "payment_not_prepared"
  attempts <- O.runSelect c $ O.limit 1 $ do
    (tx,intent,_,g,_,_) <- S.workAttempts
    O.where_ (intent O..== O.sqlStrictText identifier O..&& g O..== O.sqlInt8(fromIntegral generation))
    pure tx
    :: IO [Text]
  require (null attempts) "attempt_already_recorded"
  pure prepared

-- The dedicated signer's read-only capability resolves durable IDs, never
-- caller-supplied transaction bytes. Chain-specific plan checks follow this read.
signingDecision :: PG.Connection -> Text -> Bool -> Int64 -> Text -> Int -> IO PreparedPayment
signingDecision c identity backed now identifier generation = do
  require (generation>=0 && generation<8 && not(T.null identifier) && T.length identifier<=256) "invalid_signing_decision"
  row <- metadata c identity
  when backed $ require (S.backupSequence row>=S.criticalSequence row) "signing_backup_required"
  intakeReady c identity now
  unsignedPreparation c identity identifier generation

recordAttempt :: PG.Connection -> Text -> PreparedPayment -> SignedAttempt -> IO RecordedAttempt
recordAttempt c identity expected signed = do
  let identifier=paymentId $ savedPayment $ preparedView expected; generation=preparedGeneration expected
      text=O.sqlStrictText; num=O.sqlInt8
  require (not(T.null $ signedId signed) && T.length(signedId signed)<=128 &&
    not(T.null $ signedBytes signed) && T.length(signedBytes signed)<=200000 &&
    maybe True (\value->not(T.null value) && T.length value<=160) (commonInput signed)) "invalid_attempt"
  validateSavedJson 32768 (signedPolicy signed)
  existing <- O.runSelect c $ O.limit 1 $ do
    row <- O.selectTable S.attempts
    O.where_ (S.attemptId row O..== text(signedId signed))
    pure (S.attemptId row)
    :: IO [Text]
  case existing of
    [_] -> do
      saved <- readAttempt c (signedId signed)
      require (recordedPayment saved==identifier && recordedGeneration saved==generation && recordedFee saved==preparedFee expected && recordedSigned saved==signed) "attempt_identity_conflict"
      pure saved
    [] -> do
      current <- unsignedPreparation c identity identifier generation
      require (current==expected) "preparation_changed"
      let native=paymentAsset(savedPayment $ preparedView current)==Native
      require (native==maybe False (const True) (commonInput signed)) "attempt_common_input_mismatch"
      _ <- nextSequence c
      _ <- O.runUpdate c O.Update {O.uTable=S.paymentRoots,
        O.uUpdateWith= \r->r {S.rootCommon=maybe O.null (O.toNullable . text) (commonInput signed)},
        O.uWhere= \r->S.rootId r O..== text identifier,O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=S.attempts,
        O.iRows=[S.Attempt (text $ signedId signed) (text identifier) (text $ signedBytes signed) (text $ signedPolicy signed)
          (num $ units $ preparedFee current) (text "signed") O.null O.null (num $ fromIntegral generation)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      forM_ (customerFunding $ paymentFunding $ savedPayment $ preparedView current) $ \(order,_)->acceptCustomerPayment c order
      readAttempt c (signedId signed)
    _ -> reject "duplicate_attempt"

paymentWork :: PG.Connection -> Text -> Text -> IO (PaymentView,Maybe PreparedPayment,[Text])
paymentWork c identity identifier = do
  view <- readPayment c identity identifier
  active <- O.runSelect c $ do
    row <- O.selectTable S.paymentRoots
    O.where_ (S.rootId row O..== O.sqlStrictText identifier O..&& S.rootPhase row O..== O.sqlStrictText "active")
    pure (S.rootId row)
    :: IO [Text]
  prepared <- case active of []->pure Nothing; [_]->Just <$> readPreparation c identity identifier; _->reject "duplicate_payment_intent"
  attempts <- O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc id) $ do
    row <- O.selectTable S.attempts
    expired<-Exists.exists $ do
      (key,_,_)<-O.selectTable S.solanaExpiries
      O.where_ (key O..== S.attemptId row)
      pure ()
    O.where_ (S.attemptIntent row O..== O.sqlStrictText identifier O..&& O.not expired)
    pure (S.attemptId row)
    :: IO [Text]
  require (length attempts<=1000) "payment_history_too_large"
  pure (view,prepared,attempts)

-- Sending is authorized from recorded bytes, never a request payload. Backup
-- coverage and chain-family selection are rechecked at each boundary.
paymentSource :: PG.Connection -> Payment -> IO ()
paymentSource c outgoing = paymentSourceEligible c outgoing >>= \eligible->require eligible "source_not_eligible"

paymentSourceEligible :: PG.Connection -> Payment -> IO Bool
paymentSourceEligible c outgoing = case paymentFunding outgoing of
  EarnedFees{}->pure True
  Conversion _ receipt _ _->eligible receipt
  Refund _ receipt _ _->eligible receipt
 where eligible=sourceAuthorized c (paymentId outgoing)

-- Physical eligibility or one still-active capital cover approved for this exact
-- obligation. This checks backing, not execution state: each payment operation
-- enforces its own state (including reviewed expiry). Returned covers cannot be reused.
sourceAuthorized :: PG.Connection -> Text -> Text -> IO Bool
sourceAuthorized c identifier receipt = do
  source<-readSource c receipt
  if S.depositEligible source==1 then pure True else do
    rows<-O.runSelect c $ do
      obligation<-O.selectTable S.obligations
      accounted<-S.accountedLosses
      (cover,key,quantity,_,_)<-S.activeSourceCovers
      O.where_ (S.obligationId obligation O..== O.sqlStrictText identifier
        O..&& S.obligationDeposit obligation O..== O.sqlStrictText receipt
        O..&& accounted O..== O.sqlStrictText receipt O..&& key O..== accounted
        O..&& quantity O..== O.sqlInt8(S.depositAmount source))
      pure cover
      :: IO [Int64]
    case rows of
      [cover] | S.depositAsset source=="Native"->do
        tx<-case T.splitOn ":" receipt of ["native",tx,_]->pure tx; _->reject "invalid_native_deposit_id"
        _<-sourceEvidence c tx
        approvals<-O.runSelect c $ do
          (key,_,_,_,_,_,proof,n)<-O.selectTable S.sourceRecoveryDecisions
          O.where_ (key O..== O.sqlStrictText identifier O..&& n O..> O.sqlInt8 cover)
          pure proof
          :: IO [Text]
        matches<-forM approvals $ \raw->do
          proof<-decodeSaved raw
          saved<-either (const $ reject "invalid_source_approval") pure (parseEither (withObject "approval" (.:? "sourceCover")) proof)
          pure (saved==Just cover)
        pure (or matches)
      []->pure False
      _->reject "invalid_source_cover_authorization"

sendContext :: PG.Connection -> Text -> Text -> IO RecordedAttempt
sendContext c identity txid = do
  (prepared,saved,eligible,selection)<-readSendSubject c identity txid
  checked (checkSendPayment prepared saved eligible selection)

readSendSubject :: PG.Connection -> Text -> Text -> IO (PreparedPayment,RecordedAttempt,Bool,Maybe (Text,Bool))
readSendSubject c identity txid = do
  saved<-readAttempt c txid
  prepared<-readPreparation c identity (recordedPayment saved)
  eligible<-paymentSourceEligible c (savedPayment $ preparedView prepared)
  selection<-if recordedChain saved/="Native" then pure Nothing else do
    family<-O.runSelect c $ do
      row<-O.selectTable S.attempts
      O.where_ (S.attemptIntent row O..== O.sqlStrictText(recordedPayment saved))
      pure (S.attemptId row)
      :: IO [Text]
    members<-O.runSelect c S.replacementMembers :: IO [(Int64,Text,Int64)]
    drafts<-O.runSelect c S.replacementDrafts :: IO [(Int64,Text,Int64,Text,Text,Text)]
    cancelled<-O.runSelect c S.replacementCancellations :: IO [(Int64,Text,Int64)]
    let descendants=sortOn (\(_,_,n)->n) [m | m@(_,tx,_)<-members,tx `elem` family]
        latest=case reverse descendants of (_,tx,_):_->Just tx; []->case family of [tx]->Just tx; _->Nothing
        pending=any (\(n,parent,_,_,_,_)->parent `elem` family && all (\(d,_,_)->d/=n) (members<>cancelled)) drafts
    pure $ fmap (\tx->(tx,pending)) latest
  pure (prepared,saved,eligible,selection)

readSendFacts :: PG.Connection -> StorePolicy -> Int64 -> Text -> IO SendFacts
readSendFacts c config now txid = do
  let identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  readiness<-readIntake c identity now
  checked (checkIntake readiness)
  (prepared,saved,eligible,selection)<-readSendSubject c identity txid
  review<-broadcastReviewSequence c (recordedPayment saved)
  row<-metadata c identity
  pure $ SendFacts readiness prepared saved eligible selection review (requireBackup config) (S.backupSequence row)

broadcastReviewSequence :: PG.Connection -> Text -> IO Int64
broadcastReviewSequence c identifier = do
  approvals<-O.runSelect c $ do
    (key,n)<-S.sourceApprovals
    O.where_ (key O..== O.sqlStrictText identifier)
    pure n
    :: IO [Int64]
  cancellations<-O.runSelect c $ do
    (decision,_,sequenceNo)<-S.replacementCancellations
    (n,parent,_,_,_,_)<-S.replacementDrafts
    (tx,intent,_,_,_,_)<-S.workAttempts
    O.where_ (decision O..== n O..&& parent O..== tx O..&& intent O..== O.sqlStrictText identifier)
    pure sequenceNo
    :: IO [Int64]
  pure (maximum $ 0:approvals<>cancellations)

markBroadcast :: PG.Connection -> StorePolicy -> Int64 -> Text -> IO Int64
markBroadcast c config now txid = do
  facts<-readSendFacts c config now txid
  decision<-checked (decideQueue facts)
  case decision of
    ReuseQueue n->pure n
    CreateQueue->do
      n<-nextSequence c
      count<-O.runUpdate c O.Update {O.uTable=S.attempts,
        O.uUpdateWith= \r->r {S.attemptState=O.sqlStrictText "broadcast_intent",S.attemptSequence=O.toNullable $ O.sqlInt8 n},
        O.uWhere= \r->S.attemptId r O..== O.sqlStrictText txid O..&& S.attemptState r O..== O.sqlStrictText "signed"
          O..&& O.isNull(S.attemptSequence r),O.uReturning=O.rCount}
      require (count==1) "broadcast_intent_update_failed"
      pure n

authorizeSend :: PG.Connection -> StorePolicy -> Int64 -> Text -> IO RecordedAttempt
authorizeSend c config now txid = readSendFacts c config now txid >>= checked . decideSend

-- Settlement accepts only an independently verified outcome for the exact saved
-- attempt. Pausing/source loss does not erase an already finalized liability.
settleOutcome :: PG.Connection -> Text -> RecordedAttempt -> SettlementOutcome -> IO ()
settleOutcome c identity expected outcome = do
  checked (checkSettlementEvidence expected outcome)
  let txid=signedId(recordedSigned expected); text=O.sqlStrictText
  current<-readAttempt c txid
  view<-readPayment c identity (recordedPayment current)
  holds<-O.runSelect c $ O.limit 2 $ do
    intent<-O.selectTable S.paymentRoots
    (key,currency,n,released)<-O.selectTable S.feeHolds
    O.where_ (S.rootId intent O..== text(recordedPayment current) O..&& key O..== S.rootId intent
      O..&& S.rootPhase intent O..== O.sqlStrictText "active" O..&& released O..== O.sqlInt8 0)
    pure (currency,n)
    :: IO [(Text,Int64)]
  winners<-O.runSelect c $ O.limit 1 $ do
    row<-O.selectTable S.attempts
    O.where_ (S.attemptIntent row O..== text(recordedPayment current) O..&& S.attemptState row O..== text "settled")
    pure(S.attemptId row)
    :: IO [Text]
  charged<-case outcome of
    Failed{} | recordedState current=="failed"->O.runSelect c $ O.limit 2 $ do
      (_,event,_,account,n)<-O.selectTable S.postings
      O.where_ (event O..== text("failed-fee:"<>txid) O..&& account O..== text "external")
      pure n
    _->pure []
    :: IO [Int64]
  let held=case holds of
        [(currency,n)]->(,) <$> lookup currency [("Native",Native),("Sol",Sol)] <*> either (const Nothing) Just (amount $ toInteger n)
        _->Nothing
      winner=case winners of [tx]->Just tx; _->Nothing
      failedCharge=case charged of [n]->Just(toInteger n); _->Nothing
  decision<-checked $ decideSettlement expected (SettlementFacts current view held winner failedCharge) outcome
  case decision of
    SettlementReplay->pure ()
    ApplySettlement effects->do
      case settlementOutcome effects of
        Succeeded costs _->do
          post c ("settlement:"<>txid) "successful finalized payout" (settlementPrincipal effects)
          forM_ [("network-fee",W.networkFee costs),("account-rent",W.accountRent costs)] $ \(label,cost)->
            when (units cost>0) $ paymentCost c current (label<>":"<>txid) label cost
        Failed cost _->paymentCost c current ("failed-fee:"<>txid) "finalized Solana failure network fee" cost
      resolvePayment c current effects

paymentCost :: PG.Connection -> RecordedAttempt -> Text -> Text -> Amount -> IO ()
paymentCost c saved event explanation quantity =
  let asset=if recordedChain saved=="Native" then Native else Sol; n=toInteger(units quantity)
  in post c event explanation [Posting asset Operating (-n),Posting asset External n]

resolvePayment :: PG.Connection -> RecordedAttempt -> SettlementEffects -> IO ()
resolvePayment c saved effects = do
  let text=O.sqlStrictText; identifier=recordedPayment saved; outcome=settlementOutcome effects
      state=outcomeState outcome; proof=outcomeRecord outcome
      paid=case outcome of Succeeded{}->True; Failed{}->False
  requireOne "settlement_attempt_update_failed" $ O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text state,S.attemptObservation=O.toNullable $ text proof},O.uWhere= \r->S.attemptId r O..== text(signedId $ recordedSigned saved),O.uReturning=O.rCount}
  setPaymentPhase c identifier $ if paid then Settled (signedId $ recordedSigned saved) ("settlement:"<>signedId(recordedSigned saved)) else Ready
  requireOne "settlement_fee_hold_update_failed" $ O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlInt8 1),O.uWhere= \(key,_,_,_)->key O..== text identifier,O.uReturning=O.rCount}
  forM_ (settlementCustomer effects) $ \customer->do
    let order=resolutionOrder customer
    acceptCustomerPayment c order
    when paid $ do
      _<-O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,text "released"),O.uWhere= \(key,_,_,_)->key O..== text order,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.operatingReservations,O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,text "released"),O.uWhere= \(key,_,_,_,phase)->key O..== text order O..&& O.in_ (map text ["quote","obligation"]) phase,O.uReturning=O.rCount}
      pure ()
 where
  requireOne code operation=operation >>= \count->require (count==1) code

-- Compatibility command: verify the historical completed conversion; the
-- authoritative projection cannot be repaired by writing a status or payout ID.
repairCompletedOrderView :: PG.Connection -> PaymentTerms -> Int64 -> Text -> IO ()
repairCompletedOrderView c policy now identifier = do
  let identity=deploymentFingerprint $ paymentPolicy policy
  state<-metadata c identity
  require (S.paused state==1) "pause_before_operator_action"
  fresh c now
  payments<-customerPayments c identifier
  require (length [() | p<-payments,customerKind p==CustomerConversion,customerState p==PaymentPaid,
    Just{}<-[customerSettlement p]]==1) "completed_order_repair_not_proven"

readPaymentSource :: PG.Connection -> Text -> Text -> IO (Maybe W.PaymentSource)
readPaymentSource c identity identifier = do
  view<-readPayment c identity identifier
  let binding=case paymentFunding(savedPayment view) of
        Conversion order receipt _ _->Just(order,receipt)
        Refund order receipt _ _->Just(order,receipt)
        EarnedFees{}->Nothing
  forM binding $ \(order,receipt)->do
    deposit<-readSource c receipt >>= asDeposit
    rows<-O.runSelect c $ do
      row<-O.selectTable S.orders
      O.where_ (S.orderId row O..== O.sqlStrictText order)
      pure (S.requestJson row,S.instruction row)
      :: IO [(Text,Maybe Text)]
    (request,instruction)<-case rows of
      [(value,Just instruction)]->(,instruction) <$> decodeSaved value
      _->reject "source_instruction_missing"
    require (W.depositOrder deposit==Just order && W.depositAsset deposit==sourceAsset(W.direction request)) "source_binding_mismatch"
    pure (W.PaymentSource deposit request (paymentPolicy $ savedTerms view) instruction)

readCustodyRevision :: PG.Connection -> IO Int64
readCustodyRevision c = do
  rows<-O.runSelect c $ fmap (\(_,revision,_,_,_)->revision) (O.selectTable S.custody)
  case rows of [revision]->pure revision; _->reject "custody_check_missing"

custodyEvent :: PG.Connection -> Text -> Text -> IO (Text,Text,Value)
custodyEvent c chain identifier = do
  rows<-O.runSelect c $ do
    event<-O.selectTable S.chainEvents
    (hash,_,_,proof)<-O.selectTable S.observationEvidence
    O.where_ (S.eventChain event O..== O.sqlStrictText chain O..&& S.eventId event O..== O.sqlStrictText identifier
      O..&& S.eventReview event O..== O.sqlInt8 0 O..&& S.eventHash event O..== hash)
    pure (S.eventKind event,S.eventAnchor event,proof)
    :: IO [(Text,Text,Text)]
  case rows of
    [(kind,anchor,encoded)]->do
      value<-decodeSaved encoded >>= field "proof"
      pure (kind,anchor,value)
    _->reject "custody_history_not_current"
 where field key value=either (const $ reject "invalid_reconciliation_evidence") pure (parseEither (withObject "evidence" (.: key)) value)

custodySnapshot :: PG.Connection -> Int64 -> [(Text,Text)] -> Bool -> IO CustodySnapshot
custodySnapshot c now expectedOrigins inspectLosses = do
  revision<-readCustodyRevision c
  heads<-scanHeads c now
  origins<-O.runSelect c (O.selectTable S.scanOrigins) :: IO [(Text,Text)]
  require (sortOn fst origins==sortOn fst expectedOrigins && map fst (sortOn fst origins)==map fst heads) "custody_scan_origin_mismatch"
  reviewed<-O.runSelect c $ O.limit 1 $ do
    event<-O.selectTable S.chainEvents
    O.where_ (S.eventReview event O../= O.sqlInt8 0)
    pure (S.eventId event)
    :: IO [Text]
  require (null reviewed) "chain_observations_require_review"
  accounted<-O.runSelect c S.accountedLosses :: IO [Text]
  proven<-if inspectLosses then O.runSelect c S.provenLosses else pure []
  let ignored key=key `elem` accounted || key `elem` proven
  ineligible<-O.runSelect c $ do
    deposit<-O.selectTable S.deposits
    O.where_ (S.depositAllocated deposit O..== O.sqlInt8 1 O..&& S.depositEligible deposit O..== O.sqlInt8 0)
    pure (S.depositId deposit)
    :: IO [Text]
  require (all ignored ineligible) "source_reorg_requires_review"
  recovery<-O.runSelect c S.sourceRecovery :: IO [(Text,Text)]
  require (all (\(key,state)->state=="restored" || ignored key) recovery) "source_recovery_requires_review"
  native<-O.runSelect c $ O.limit 1 $ do
    (tx,state)<-S.nativeRecovery
    O.where_ (state O../= O.sqlStrictText "reconfirmed")
    pure tx
    :: IO [Text]
  require (null native) "native_settlement_requires_review"
  terminal<-O.runSelect c $ do
    a<-O.selectTable S.attempts
    O.where_ (O.in_ (map O.sqlStrictText ["settled","failed"]) (S.attemptState a))
    pure (S.attemptId a)
    :: IO [Text]
  forM_ terminal $ \txid->do
    saved<-readAttempt c txid
    observation<-maybe (reject "invalid_reconciliation_evidence") decodeSaved (recordedObservation saved)
    proof<-if recordedState saved=="settled" then field "proof" observation >>= decodeSaved else pure observation
    (kind,anchor,evidence)<-custodyEvent c (recordedChain saved) txid
    if recordedChain saved=="Native" then do
      block<-field "blockhash" proof
      depth<-field "requiredDepth" proof :: IO Int64
      actual<-field "confirmations" evidence :: IO Int64
      require (recordedState saved=="settled" && kind=="outgoing" && anchor==block && depth>0 && actual>=depth) "settled_payment_observation_changed"
    else do
      outcome<-field "outcome" proof
      slot<-field "outcomeSlot" outcome :: IO Int64
      (operating,operatingAnchor,_)<-custodyEvent c "SolanaOperating" txid
      require (anchor==T.pack(show slot) && operatingAnchor==anchor && operating=="outgoing"
        && kind==(if recordedState saved=="settled" then "outgoing" else "failed")) "booked_solana_observation_changed"
  booked<-balances c
  let total asset=sum [n | ((currency,_),n)<-M.toList booked,currency==asset]
      owned asset=sum [n | ((currency,account),n)<-M.toList booked,currency==asset,account/=External]
      assets=[Native,Wrapped,Sol]
  require (all (\asset->total asset==0 && owned asset>=0) assets) "invalid_custody_journal"
  slots<-forM (filter ((/="Native").fst) heads) $ \(chain,txid)->do
    (_,anchor,_)<-custodyEvent c chain txid
    case readMaybe(T.unpack anchor) of Just n | n>=0->pure n; _->reject "custody_history_anchor_missing"
  require (length slots==2) "custody_history_anchor_missing"
  pendingIds<-O.runSelect c $ O.limit 1001 $ do
    a<-O.selectTable S.attempts
    i<-O.selectTable S.paymentRoots
    expired<-Exists.exists $ do
      (key,_,_)<-O.selectTable S.solanaExpiries
      O.where_ (key O..== S.attemptId a O..&& S.rootChain i O..== O.sqlStrictText "Solana")
      pure ()
    O.where_ (S.attemptIntent a O..== S.rootId i O..&& S.rootPhase i O..== O.sqlStrictText "active" O..&& O.not expired)
    pure (S.attemptId a)
    :: IO [Text]
  require (length pendingIds<=1000) "custody_attempt_bounds"
  pending<-mapM (readAttempt c) pendingIds
  pure (CustodySnapshot revision (M.fromList [(asset,owned asset)|asset<-assets]) heads (maximum slots) pending)
 where
  field :: FromJSON a => Key -> Value -> IO a
  field key value=either (const $ reject "invalid_reconciliation_evidence") pure (parseEither (withObject "evidence" (.: key)) value)

recordCustody :: PG.Connection -> Int64 -> Int64 -> Maybe Text -> Maybe Value -> IO ()
recordCustody c expected now problem report = do
  require (now>=0 && expected>=0) "invalid_custody_time"
  actual<-readCustodyRevision c
  require (actual==expected) "custody_ledger_changed"
  forM_ problem validReason
  forM_ report (validateSavedJson 200000 . encodeSaved)
  when (problem==Nothing) $ do
    matches<-case report of
      Just value->either (const $ reject "invalid_custody_report") pure (parseEither (withObject "report" (.: "matches")) value)
      Nothing->pure False
    require matches "invalid_custody_report"
  let text=O.sqlStrictText; number=O.sqlInt8
  forM_ problem $ \code->do
    old<-O.runSelect c $ fmap (\(_,_,_,_,err)->err) (O.selectTable S.custody) :: IO [Maybe Text]
    when (old/=[Just code]) (audit c "custody_failure" code)
    -- A recent scan can already be behind the chain. Invalidate it atomically
    -- so readiness refreshes history instead of repeating the same stale check.
    let affected=case code of
          "custody_native_history_advanced"->["Native"]
          "custody_solana_history_advanced"->["Solana","SolanaOperating"]
          _->[]
    forM_ affected $ \chain->scanHealth c chain now (Just code)
    when (code `notElem` ["custody_native_history_advanced","custody_solana_history_advanced","custody_ledger_changed"]) $ do
      _<-O.runUpdate c O.Update {O.uTable=S.deployment,O.uUpdateWith= \r->r {S.paused=number 1,S.pauseReason=text $ "custody:"<>code},O.uWhere= \r->S.singleton r O..== number 1,O.uReturning=O.rCount}
      pure ()
  _<-O.runUpdate c O.Update {O.uTable=S.custody,
    O.uUpdateWith= \(key,revision,_,_,_)->(key,revision,if report==Nothing then O.null else O.toNullable(number expected),O.toNullable(number now),maybe O.null (O.toNullable.text) problem),
    O.uWhere= \(key,_,_,_,_)->key O..== number 1,O.uReturning=O.rCount}
  _<-O.runUpdate c O.Update {O.uTable=S.custodyReport,O.uUpdateWith= \(key,_)->(key,maybe O.null (O.toNullable.text.encodeSaved) report),O.uWhere= \(key,_)->key O..== number 1,O.uReturning=O.rCount}
  pure ()

-- Bounded restart work. Recorded effects are checked even while intake is paused.
pendingAttempts :: PG.Connection -> IO [Text]
pendingAttempts c = do
  rows<-O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc id) $ do
    row<-O.selectTable S.attempts
    intent<-O.selectTable S.paymentRoots
    O.where_ (S.attemptIntent row O..== S.rootId intent O..&& S.rootPhase intent O..== O.sqlStrictText "active")
    O.where_ (O.in_ (map O.sqlStrictText ["signed","broadcast_intent"]) (S.attemptState row))
    pure (S.attemptId row)
  require (length rows<=1000) "pending_attempts_too_large"
  pure rows

-- Active ownership always wins its chain; a reviewed active payment cannot be
-- bypassed by a competing ready payment. Candidates are revalidated when prepared.
paymentCandidates :: PG.Connection -> IO [Text]
paymentCandidates c = do
  active<-O.runSelect c P.activePayments :: IO [(Text,Text)]
  ready<-O.runSelect c P.readyPayments :: IO [(Text,Text)]
  require (length ready<=1000 && length active<=2
    && all ((`elem` ["Native","Solana"]).snd) (active<>ready)
    && length(nub $ map snd active)==length active) "payment_queue_requires_review"
  pure [key | chain<-["Native","Solana"],key<-take 1 [identifier | (identifier,currency)<-active<>ready,currency==chain]]

-- Saved native work only: no source/payment authorization is granted by this read.
nativeLockWork :: PG.Connection -> Text -> IO (Maybe NativeLockWork)
nativeLockWork c identity = do
  active<-O.runSelect c $ O.limit 2 $ do
    row<-O.selectTable S.paymentRoots
    O.where_ (S.rootChain row O..== O.sqlStrictText "Native" O..&& S.rootPhase row O..== O.sqlStrictText "active")
    pure (S.rootId row)
  case active of
    []->pure Nothing
    [identifier]->do
      (prepared,cancelling)<-preparationState c identity identifier
      require (paymentAsset(savedPayment $ preparedView prepared)==Native) "payment_funding_mismatch"
      ids<-O.runSelect c $ O.limit 9 $ O.orderBy (O.asc id) $ do
        row<-O.selectTable S.attempts
        O.where_ (S.attemptIntent row O..== O.sqlStrictText identifier)
        pure (S.attemptId row)
      require (length ids<=8) "native_replacement_family_bounds"
      attempts<-if length ids>1 then map fst <$> nativeFamily c identity identifier else mapM (readAttempt c) ids
      pure (Just $ NativeLockWork prepared cancelling attempts)
    _->reject "native_lock_recovery_bounds"

principalHeld :: PG.Connection -> Asset -> IO Integer
principalHeld c asset = do
  quantities<-O.runSelect c $ do
    (_,currency,n,phase)<-O.selectTable S.reservations
    O.where_ (currency O..== O.sqlStrictText(T.pack $ show asset) O..&& phase O../= O.sqlStrictText "released")
    pure n
    :: IO [Int64]
  pure (sum $ map toInteger quantities)

operatingHolds :: PG.Connection -> Asset -> IO Integer
operatingHolds c asset = do
  let name=T.pack(show asset)
  orderHolds <- O.runSelect c $ do
    (_,_,currency,n,phase) <- O.selectTable S.operatingReservations
    O.where_ (currency O..== O.sqlStrictText name O..&& O.in_ (map O.sqlStrictText ["quote","obligation"]) phase)
    pure n
    :: IO [Int64]
  paymentHolds <- O.runSelect c $ do
    (currency,n,released) <- S.feeReservations
    O.where_ (currency O..== O.sqlStrictText name O..&& released O..== O.sqlInt8 0)
    pure n
    :: IO [Int64]
  pure (sum $ map toInteger $ orderHolds<>paymentHolds)

-- One atomic resume after the runtime has verified the exact saved attempts.
-- Reuse custody's review/source/journal checks instead of maintaining a second set.
resumeLedger :: PG.Connection -> StorePolicy -> Int64 -> [(Text,Text)] -> [RecordedAttempt] -> IO ()
resumeLedger c config now origins reviewed = do
  let identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
      txid=signedId.recordedSigned
  state<-metadata c identity
  require (S.paused state==1) "pause_before_operator_action"
  snapshot<-custodySnapshot c now origins False
  fresh c now
  require (sortOn txid (custodyPending snapshot)==sortOn txid reviewed
    && all ((`elem` ["signed","broadcast_intent"]).recordedState) reviewed) "resume_payment_changed"
  unresolved<-O.runSelect c $ do
    row<-O.selectTable S.paymentRoots
    O.where_ (S.rootPhase row O..== O.sqlStrictText "active")
    pure (S.rootId row)
  require (all (`elem` map recordedPayment reviewed) unresolved) "unresolved_intents_require_review"
  problems<-O.runSelect c $ O.limit 1 $ do
    (key,_,_,state)<-P.orderObligations
    O.where_ (state O..== O.sqlStrictText "review")
    pure key
    :: IO [Text]
  require (null problems) "obligations_require_review"
  legacy<-O.runSelect c $ O.limit 1 $ do
    row<-P.openOrders
    costs<-Exists.exists $ do
      (key,_,_,_)<-O.selectTable S.orderCosts
      O.where_ (key O..== S.orderId row)
      pure ()
    O.where_ (O.not costs)
    pure (S.orderId row)
    :: IO [Text]
  require (null legacy) "legacy_order_cost_review_required"
  booked<-balances c
  require (all (\asset->M.findWithDefault 0 (asset,SourceDeficit) booked==0) [Native,Wrapped,Sol]) "source_shortfall_requires_review"
  forM_ [Native,Sol] $ \asset->do
    held<-operatingHolds c asset
    require (M.findWithDefault 0 (asset,Operating) booked>=held) "operating_allocation_requires_funding"
  _<-O.runUpdate c O.Update {O.uTable=S.deployment,
    O.uUpdateWith= \row->row {S.paused=O.sqlInt8 0,S.pauseReason=O.sqlStrictText "ready"},
    O.uWhere= \row->S.singleton row O..== O.sqlInt8 1,O.uReturning=O.rCount}
  intakeReady c identity now
  audit c "resume" "checks_complete"

-- Reuse the ordinary payment engine, retaining all principal and saved terms.
-- No caller-supplied recipient, amount or signed bytes are accepted.
authorizeRefund :: PG.Connection -> StorePolicy -> Int64 -> Text -> IO W.RefundAuthorization
authorizeRefund c config now receipt = do
  let text=O.sqlStrictText; num=O.sqlInt8; identifier="refund:"<>receipt
      identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
      result ob=W.RefundAuthorization (S.obligationId ob) (S.obligationRecipient ob)
        <$> checked (amount $ toInteger $ S.obligationAmount ob)
  existing<-O.runSelect c $ do
    ob<-O.selectTable S.obligations
    O.where_ (S.obligationDeposit ob O..== text receipt O..&& S.obligationKind ob O..== text "refund")
    pure ob
    :: IO [S.Obligation]
  case existing of
    [ob]->result ob
    []->do
      operator<-readOperator c identity now
      checked (checkOperator "pause_before_operator_action" operator)
      rows<-O.runSelect c $ do
        d<-O.selectTable S.deposits
        q<-O.selectTable S.orders
        (key,nativeFee,solFee,rent)<-O.selectTable S.orderCosts
        O.where_ (S.depositId d O..== text receipt O..&& O.matchNullable (O.sqlBool False) (O..== S.orderId q) (S.depositOrder d) O..&& key O..== S.orderId q)
        pure(d,q,nativeFee,solFee,rent)
        :: IO [(S.Deposit,S.Order,Int64,Int64,Int64)]
      (d,q,nativeFee,solFee,rent)<-case rows of
        [row@(d,_,_,_,_)] | S.depositEligible d==1->pure row
        _->reject "refundable_deposit_not_found"
      request<-decodeSaved (S.requestJson q)
      policy<-decodeSaved (S.policyJson q)
      let oid=S.orderId q; native=W.direction request==NativeToWrapped
          feeAsset=if native then Native else Sol
      source<-asDeposit d
      checked (checkRefundSource identity request policy source)
      costs<-checked (savedCostLimits nativeFee solFee rent)
      unresolved<-O.runSelect c $ do
        i<-O.selectTable S.paymentRoots
        ob<-O.selectTable S.obligations
        O.where_ (O.matchNullable (O.sqlBool False) (O..== S.obligationId ob) (S.rootObligation i) O..&& S.obligationOrder ob O..== text oid O..&& S.rootPhase i O..== O.sqlStrictText "active")
        pure (S.rootId i)
        :: IO [Text]
      work<-O.runSelect c $ do
        (key,order,deposit,state)<-P.orderObligations
        O.where_ (order O..== text oid O..&& state O../= text "cancelled")
        pure (key,deposit,state)
        :: IO [(Text,Text,Text)]
      active<-checked (refundableWork receipt (not $ null unresolved) work)
      destination<-if native then pure (W.refund request) else case W.sourceOwner request of
        Just owner->checked (publicKey owner) >> pure owner
        Nothing->do
          signature<-maybe (reject "invalid_solana_deposit_id") pure (T.stripPrefix "solana:" receipt)
          (kind,_,proof)<-custodyEvent c "Solana" signature
          require (kind=="incoming") "verified_refund_owner_missing"
          instruction<-field "instruction" proof
          require (S.instruction q==Just instruction) "refund_reference_mismatch"
          owner<-field "verifiedOwner" proof
          _<-checked (publicKey owner)
          pure owner
      holds<-O.runSelect c $ do
        (key,kind,asset,n,phase)<-O.selectTable S.operatingReservations
        O.where_ (key O..== text oid)
        pure (kind,asset,n,phase)
        :: IO [(Text,Text,Int64,Text)]
      let refundHolds=[(asset,n,phase) | ("refund",asset,n,phase)<-holds]
      budget<-if any (\(_,_,phase)->phase `notElem` ["quote","obligation"]) refundHolds then do
        booked<-balances c
        at<-operatingTime c
        before<-readFeeBudget c (admissionLimits config) booked at feeAsset
        released<-O.runSelect c $ do
          (key,asset,n,done)<-O.selectTable S.feeHolds
          O.where_ (O.in_ (map text active) key O..&& asset O..== text(T.pack $ show feeAsset) O..&& done O..== num 0)
          pure n
          :: IO [Int64]
        let transferred=[n | ("conversion",asset,n,phase)<-holds,asset==T.pack(show feeAsset),phase `elem` ["quote","obligation"]]
        pure $ Just before {operatingHeld=operatingHeld before-sum(map toInteger $ released<>transferred)}
       else pure Nothing
      outgoing<-checked $ decideRefund request source costs (RefundFacts (not $ null unresolved) work destination refundHolds budget)
      -- Resolved failed/cancelled preparations may retain unused operating holds.
      -- No unresolved intent survives the check above, so release only this work.
      forM_ active $ \old->do
        setPaymentPhase c old Cancelled
        _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,num 1),O.uWhere= \(key,_,_,_)->key O..== text old,O.uReturning=O.rCount}
        pure ()
      _<-O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,text "released"),O.uWhere= \(key,_,_,_)->key O..== text oid,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.operatingReservations,O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,text "released"),O.uWhere= \(key,kind,_,_,_)->key O..== text oid O..&& kind O..== text "conversion",O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.operatingReservations,O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,text "obligation"),O.uWhere= \(key,kind,_,_,_)->key O..== text oid O..&& kind O..== text "refund",O.uReturning=O.rCount}
      _<-nextSequence c
      let ob=S.Obligation (paymentId outgoing) oid receipt "refund" (T.pack $ show $ paymentAsset outgoing) (units $ paymentAmount outgoing) (paymentRecipient outgoing)
      _<-O.runInsert c O.Insert {O.iTable=S.obligations,O.iRows=[S.Obligation (text identifier) (text oid) (text receipt) (text "refund") (text $ S.obligationAsset ob) (num $ S.obligationAmount ob) (text $ S.obligationRecipient ob)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _<-O.runUpdate c O.Update {O.uTable=S.deposits,O.uUpdateWith= \r->r {S.depositAllocated=num 1},O.uWhere= \r->S.depositId r O..== text receipt,O.uReturning=O.rCount}
      createPaymentRoot c outgoing
      audit c "refund_authorized" receipt
      result ob
    _->reject "duplicate_refund"
  where field key value=either (const $ reject "invalid_refund_evidence") pure (parseEither (withObject "refund evidence" (.: key)) value)

readCancellation :: PG.Connection -> Text -> Int -> IO (Maybe (Text,Text,Bool))
readCancellation c identifier generation = do
  require (generation>=0 && generation<8) "invalid_preparation_generation"
  rows<-O.runSelect c $ do
    (key,g,reason,cleanup,completed)<-S.workCancellations
    O.where_ (key O..== O.sqlStrictText identifier O..&& g O..== O.sqlInt8(fromIntegral generation))
    pure (reason,cleanup,completed)
    :: IO [(Text,Text,Int64)]
  case rows of
    []->pure Nothing
    [(reason,cleanup,done)]->pure (Just(reason,cleanup,done==1))
    _->reject "duplicate_preparation_cancellation"

cancellationPreparation :: PG.Connection -> Text -> Text -> IO PreparedPayment
cancellationPreparation c identity identifier = do
  (saved,_)<-preparationState c identity identifier
  attempts<-O.runSelect c $ O.limit 1 $ do
    (tx,key,_,g,_,_)<-S.workAttempts
    O.where_ (key O..== O.sqlStrictText identifier O..&& g O..== O.sqlInt8(fromIntegral $ preparedGeneration saved))
    pure tx
    :: IO [Text]
  require (null attempts) "preparation_already_signed"
  pure saved

beginCancellation :: PG.Connection -> StorePolicy -> PreparedPayment -> Int64 -> Text -> Text -> IO ()
beginCancellation c config expected now reason cleanup = do
  validReason reason
  validateSavedJson 32768 cleanup
  let identifier=paymentId(savedPayment $ preparedView expected); generation=preparedGeneration expected
      identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  operator<-readOperator c identity now
  require (operatorPaused operator) "pause_before_operator_action"
  previous<-readCancellation c identifier generation
  current<-case previous of
    Nothing->checked (checkOperator "pause_before_operator_action" operator) >> Just <$> cancellationPreparation c identity identifier
    Just _->pure Nothing
  decision<-checked $ decideCancellation BeginCleanup expected reason cleanup (CancellationFacts operator previous current False)
  when (decision==RequestCancellation) $ do
    sequenceNo<-nextSequence c
    _<-O.runInsert c O.Insert {O.iTable=S.preparationCancellations,
      O.iRows=[(O.sqlStrictText identifier,O.sqlInt8(fromIntegral generation),O.sqlStrictText reason,O.sqlStrictText cleanup,O.sqlInt8 sequenceNo,O.sqlInt8 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    audit c "preparation_cancellation_requested" (identifier<>"@"<>T.pack(show generation))

finishCancellation :: PG.Connection -> StorePolicy -> PreparedPayment -> Text -> Text -> IO ()
finishCancellation c config expected reason cleanup = do
  let identifier=paymentId(savedPayment $ preparedView expected); generation=preparedGeneration expected
      identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
      text=O.sqlStrictText; num=O.sqlInt8
  state<-metadata c identity
  let operator=OperatorFacts 0 (S.paused state==1) Nothing
  require (operatorPaused operator) "pause_before_operator_action"
  saved<-readCancellation c identifier generation
  (current,eligible)<-case saved of
    Just(old,plan,False) | old==reason && plan==cleanup->do
      unsigned<-cancellationPreparation c identity identifier
      source<-paymentSourceEligible c (savedPayment $ preparedView unsigned)
      pure (Just unsigned,source)
    _->pure (Nothing,False)
  decision<-checked $ decideCancellation FinishCleanup expected reason cleanup (CancellationFacts operator saved current eligible)
  case decision of
    CompleteCancellation _->do
      let binding=customerFunding (paymentFunding $ savedPayment $ preparedView expected)
      _<-nextSequence c
      _<-O.runUpdate c O.Update {O.uTable=S.preparationCancellations,O.uUpdateWith= \(key,g,r,p,n,_)->(key,g,r,p,n,num 1),O.uWhere= \(key,g,_,_,_,_)->key O..== text identifier O..&& g O..== num(fromIntegral generation),O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.preparations,O.uUpdateWith= \(key,g,p,d,r,_)->(key,g,p,d,r,num 1),O.uWhere= \(key,g,_,_,_,_)->key O..== text identifier O..&& g O..== num(fromIntegral generation),O.uReturning=O.rCount}
      setPaymentPhase c identifier Ready
      forM_ binding $ \(oid,_)->do
        acceptCustomerPayment c oid
        _<-O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(key,a,n,_)->(key,a,n,text "obligation"),O.uWhere= \(key,_,_,phase)->key O..== text oid O..&& phase O..== text "payment",O.uReturning=O.rCount}
        pure ()
      audit c "preparation_cancellation_completed" (identifier<>"@"<>T.pack(show generation))
    _->pure ()

-- Fee-reservation release accepts only wholly unsigned cancellation history.
-- Preparation retries also accept separately proved and approved Solana expiry.
cancelledGeneration :: PG.Connection -> Text -> IO (Maybe Int)
cancelledGeneration=nextGeneration False
retryGeneration :: PG.Connection -> Text -> IO (Maybe Int)
retryGeneration=nextGeneration True
nextGeneration :: Bool -> PG.Connection -> Text -> IO (Maybe Int)
nextGeneration includeExpired c identifier = do
  rows<-O.runSelect c $ O.limit 9 $ O.orderBy (O.asc (\(g,_,_)->g)) $ do
    (key,g,_,_,retired,cancelled)<-S.workPreparations
    O.where_ (key O..== O.sqlStrictText identifier)
    pure (g,retired,cancelled)
    :: IO [(Int64,Maybe Text,Int64)]
  attempts<-O.runSelect c $ do
    (tx,key,_,g,_,_)<-S.workAttempts
    O.where_ (key O..== O.sqlStrictText identifier)
    pure (tx,g)
    :: IO [(Text,Int64)]
  if null rows || length rows>8 || map (\(g,_,_)->g) rows/=[0..fromIntegral(length rows)-1]
    then pure Nothing else do
      endings<-forM rows $ \(g,retired,cancelled)->(g,) <$> case (retired,cancelled) of
        (Nothing,1)->do
          done<-readCancellation c identifier (fromIntegral g)
          pure $ UnsignedCleanup (case done of Just(_,_,True)->True; _->False)
        (Just txid,0) | includeExpired->do
          expired<-expiryProof c txid
          approved<-retryReason c txid
          pure $ SolanaRetired txid (expired/=Nothing) (approved/=Nothing)
        _->pure OpenGeneration
      pure (successorGeneration includeExpired endings attempts)

expiryProof :: PG.Connection -> Text -> IO (Maybe Text)
expiryProof c txid = do
  rows<-O.runSelect c $ do
    (key,proof,_)<-O.selectTable S.solanaExpiries
    O.where_ (key O..== O.sqlStrictText txid)
    pure proof
  case rows of []->pure Nothing; [proof]->pure (Just proof); _->reject "duplicate_expiry"
retryReason :: PG.Connection -> Text -> IO (Maybe Text)
retryReason c txid = do
  rows<-O.runSelect c $ do
    (key,reason,_,_)<-O.selectTable S.solanaRetryApprovals
    O.where_ (key O..== O.sqlStrictText txid)
    pure reason
  case rows of []->pure Nothing; [reason]->pure (Just reason); _->reject "duplicate_retry_approval"
checkExpiryOrigins :: PG.Connection -> (Text,Text) -> IO ()
checkExpiryOrigins c (token,operating) = do
  rows<-O.runSelect c $ do
    (chain,origin)<-O.selectTable S.scanOrigins
    O.where_ (O.in_ (map O.sqlStrictText ["Solana","SolanaOperating"]) chain)
    pure (chain,origin)
    :: IO [(Text,Text)]
  require (sortOn fst rows==[("Solana",token),("SolanaOperating",operating)] && not(T.null token) && not(T.null operating)) "expiry_scan_origin_mismatch"

-- Reverification of retired signed bytes uses that generation's saved policy,
-- draft and attempt allowance, never the latest generation's mutable fee hold.
recordedPreparation :: PG.Connection -> Text -> Text -> IO PreparedPayment
recordedPreparation c identity txid = do
  saved<-readAttempt c txid
  view<-readPayment c identity (recordedPayment saved)
  rows<-O.runSelect c $ do
    (key,g,policy,draft,_,_)<-S.workPreparations
    O.where_ (key O..== O.sqlStrictText(recordedPayment saved) O..&& g O..== O.sqlInt8(fromIntegral $ recordedGeneration saved))
    pure (policy,draft)
    :: IO [(Text,Maybe Text)]
  case rows of
    [(policy,Just draft)]->pure (PreparedPayment view (recordedGeneration saved) policy (Just draft) (recordedFee saved))
    _->reject "expiry_preparation_missing"

recordSolanaExpiry :: PG.Connection -> StorePolicy -> RecordedAttempt -> Text -> IO ()
recordSolanaExpiry c config expected proof = do
  validateSavedJson 200000 proof
  let txid=signedId $ recordedSigned expected; identifier=recordedPayment expected
      identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
      text=O.sqlStrictText; num=O.sqlInt8
  require (recordedChain expected=="Solana" && recordedState expected `elem` ["signed","broadcast_intent"]) "invalid_solana_expiry"
  previous<-expiryProof c txid
  case previous of
    Just _->void $ checked (decideSolanaExpiry expected proof previous Nothing)
    Nothing->do
      current<-readAttempt c txid
      prepared<-readPreparation c identity identifier
      family<-O.runSelect c $ do
        (key,intent,_,_,_,_)<-S.workAttempts
        expired<-Exists.exists $ do
          (other,_,_)<-O.selectTable S.solanaExpiries
          O.where_ (other O..== key)
          pure ()
        O.where_ (intent O..== text identifier O..&& O.not expired)
        pure key
        :: IO [Text]
      _<-checked (decideSolanaExpiry expected proof Nothing $ Just $ ExpiryFacts current prepared family)
      sequenceNo<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.solanaExpiries,O.iRows=[(text txid,text proof,num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _<-O.runUpdate c O.Update {O.uTable=S.preparations,O.uUpdateWith= \(key,g,p,d,_,cancelled)->(key,g,p,d,O.toNullable $ text txid,cancelled),O.uWhere= \(key,g,_,_,_,_)->key O..== text identifier O..&& g O..== num(fromIntegral $ recordedGeneration expected),O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text "review",S.attemptObservation=O.toNullable $ text proof},O.uWhere= \r->S.attemptId r O..== text txid,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,a,n,_)->(key,a,n,num 1),O.uWhere= \(key,_,_,_)->key O..== text identifier,O.uReturning=O.rCount}
      setPaymentPhase c identifier Ready
      audit c "solana_expiry_verified" txid

approveSolanaRetry :: PG.Connection -> StorePolicy -> Int64 -> RecordedAttempt -> Text -> Text -> IO ()
approveSolanaRetry c config now expected reason proof = do
  validReason reason
  validateSavedJson 200000 proof
  let txid=signedId $ recordedSigned expected; identifier=recordedPayment expected
      identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  old<-retryReason c txid
  case old of
    Just _->void $ checked (decideSolanaRetry expected reason old Nothing)
    Nothing->do
      operator<-readOperator c identity now
      checked (checkOperator "pause_before_operator_action" operator)
      current<-readAttempt c txid
      expired<-expiryProof c txid
      rows<-O.runSelect c $ do
        i<-O.selectTable S.paymentRoots
        (key,g,_,_,retired,cancelled)<-S.workPreparations
        O.where_ (S.rootId i O..== O.sqlStrictText identifier O..&& key O..== S.rootId i)
        pure (g,retired,cancelled,O.ifThenElse (S.rootPhase i O..== O.sqlStrictText "active") (O.sqlInt8 0) (O.sqlInt8 1))
        :: IO [(Int64,Maybe Text,Int64,Int64)]
      view<-readPayment c identity identifier
      eligible<-paymentSourceEligible c (savedPayment view)
      _<-checked (decideSolanaRetry expected reason Nothing $ Just $ RetryFacts operator current expired rows view eligible)
      sequenceNo<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.solanaRetryApprovals,O.iRows=[(O.sqlStrictText txid,O.sqlStrictText reason,O.sqlStrictText proof,O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      forM_ (customerFunding $ paymentFunding $ savedPayment view) $ \(order,_)->acceptCustomerPayment c order
      audit c "solana_retry_approved" txid

-- Only verified unbound receipts may become operator capital. The attestation
-- establishes ownership; it cannot supply amounts, chain effects or eligibility.
allocateTreasury :: PG.Connection -> PaymentTerms -> Int64 -> Text -> [(Text,Amount)] -> Text -> IO Int64
allocateTreasury c policy now receipt split reason = do
  validReason reason
  let entries=sortOn fst split; encoded=encodeSaved entries
      text=O.sqlStrictText; num=O.sqlInt8
  _<-checked (treasurySplit entries)
  old<-O.runSelect c $ do
    (key,allocation,proof,sequenceNo)<-O.selectTable S.treasuryAllocations
    O.where_ (key O..== text receipt)
    pure (allocation,proof,sequenceNo)
    :: IO [(Text,Text,Int64)]
  case old of
    [(allocation,proof,sequenceNo)]->do
      attestation<-decodeSaved proof >>= field "ownershipAttestation"
      require (allocation==encoded && attestation==reason) "treasury_allocation_conflict"
      pure sequenceNo
    []->do
      operator<-readOperator c (deploymentFingerprint $ paymentPolicy policy) now
      checked (checkOperator "treasury_allocation_requires_pause" operator)
      source<-readSource c receipt
      currency<-parseAsset (S.depositAsset source)
      let quantity=S.depositAmount source
          (chain,prefix,key)=case currency of
            Native->("Native","native:",T.takeWhile (/=':') $ T.drop 7 receipt)
            Wrapped->("Solana","solana:",T.drop 7 receipt)
            Sol->("SolanaOperating","sol-operating:",T.drop 14 receipt)
      linked<-O.runSelect c $ do
        row<-O.selectTable S.obligations
        O.where_ (S.obligationDeposit row O..== text receipt)
        pure (S.obligationId row)
        :: IO [Text]
      deposit<-asDeposit source
      postings<-checked $ decideTreasury (paymentPolicy policy) entries (TreasuryFacts operator deposit (S.depositAllocated source/=0) (not $ null linked))
      require (prefix `T.isPrefixOf` receipt && not(T.null key)) "invalid_treasury_receipt_id"
      (kind,anchor,proof)<-custodyEvent c chain key
      require (anchor==S.depositAnchor source && (kind=="unmatched_incoming" || currency==Native && kind=="incoming")) "verified_treasury_receipt_required"
      case currency of
        Native->do
          receipts<-field "receipts" proof :: IO [Value]
          matching<-forM receipts $ \value->do
            identifier<-field "id" value
            n<-field "amount" value :: IO Amount
            order<-field "order" value :: IO (Maybe Text)
            eligible<-field "eligible" value
            pure (identifier==receipt && units n==quantity && order==Nothing && eligible)
          require (length(filter id matching)==1) "verified_treasury_receipt_required"
        _->do
          delta<-field "delta" proof :: IO Text
          require (delta==T.pack(show quantity)) "verified_treasury_receipt_required"
          when (currency==Sol) $ field "failed" proof >>= \failed->require (not failed) "verified_treasury_receipt_required"
      let envelope=object ["chain" .= chain,"id" .= key,"anchor" .= anchor,"kind" .= kind,"proof" .= proof]
          evidence=encodeSaved $ object ["ownershipAttestation" .= reason,"observation" .= envelope]
      require (T.length evidence<=8192) "treasury_proof_too_large"
      sequenceNo<-nextSequence c
      post c ("treasury:"<>receipt) "operator allocation of verified treasury receipt"
        postings
      inserted<-O.runInsert c O.Insert {O.iTable=S.treasuryAllocations,O.iRows=[(text receipt,text encoded,text evidence,num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      updated<-O.runUpdate c O.Update {O.uTable=S.deposits,O.uUpdateWith= \row->row {S.depositAllocated=num 1,S.depositState=text "treasury"},O.uWhere= \row->S.depositId row O..== text receipt,O.uReturning=O.rCount}
      require (inserted==1 && updated==1) "treasury_allocation_changed"
      pure sequenceNo
    _->reject "duplicate_treasury_allocation"
 where field key value=either (const $ reject "invalid_treasury_evidence") pure (parseEither (withObject "treasury evidence" (.: key)) value)

-- Book an observed outflow once; never create signing or broadcast authority.
classifyTreasurySpend :: PG.Connection -> PaymentTerms -> Text -> Text -> Text -> IO Int64
classifyTreasurySpend c policy chain key reason = do
  validReason reason
  let text=O.sqlStrictText; num=O.sqlInt8
  state<-metadata c (deploymentFingerprint $ paymentPolicy policy)
  require (S.paused state==1) "treasury_spend_requires_pause"
  rows<-O.runSelect c $ do
    event<-O.selectTable S.chainEvents
    (hash,stream,identifier,proof)<-O.selectTable S.observationEvidence
    O.where_ (S.eventChain event O..== text chain O..&& S.eventId event O..== text key
      O..&& S.eventKind event O..== text "outgoing" O..&& S.eventHash event O..== hash
      O..&& stream O..== text chain O..&& identifier O..== text key)
    pure (S.eventAnchor event,proof)
    :: IO [(Text,Text)]
  (anchor,raw)<-case rows of [row]->pure row; _->reject "treasury_spend_not_observed"
  observation<-decodeSaved raw
  proof<-field "proof" observation
  economic@(currency,_,_)<-checked (W.economicOutflow chain proof)
  attempts<-O.runSelect c $ do
    (tx,_,_,_,_,_)<-S.workAttempts
    O.where_ (tx O..== text key)
    pure tx
    :: IO [Text]
  require (null attempts) "customer_attempt_cannot_be_treasury_spend"
  old<-O.runSelect c $ do
    (stream,identifier,savedAnchor,effects,evidence,sequenceNo)<-O.selectTable S.treasurySpends
    O.where_ (stream O..== text chain O..&& identifier O..== text key)
    pure (savedAnchor,effects,evidence,sequenceNo)
    :: IO [(Text,Text,Text,Int64)]
  sequenceNo<-case old of
    [(savedAnchor,effects,evidence,n)]->do
      attestation<-decodeSaved evidence >>= field "ownershipAttestation"
      require (savedAnchor==anchor && effects==encodeSaved economic && attestation==reason) "treasury_spend_conflict"
      pure n
    []->do
      booked<-balances c
      inventory<-principalHeld c currency
      operating<-operatingHolds c currency
      postings<-checked $ decideTreasurySpend economic
        (M.findWithDefault 0 (currency,Float) booked-inventory) (M.findWithDefault 0 (currency,Operating) booked-operating)
      n<-nextSequence c
      post c ("treasury-spend:"<>chain<>":"<>key) "verified operator spend and network costs"
        postings
      let evidence=encodeSaved $ object ["ownershipAttestation" .= reason,"observation" .= observation]
      count<-O.runInsert c O.Insert {O.iTable=S.treasurySpends,O.iRows=[(text chain,text key,text anchor,text $ encodeSaved economic,text evidence,num n)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "treasury_spend_changed"
      pure n
    _->reject "duplicate_treasury_spend"
  -- Avoid changing custody revision on exact replay; clear only this event.
  _<-O.runUpdate c O.Update {O.uTable=S.chainEvents,O.uUpdateWith= \row->row {S.eventReview=num 0},
    O.uWhere= \row->S.eventChain row O..== text chain O..&& S.eventId row O..== text key O..&& S.eventReview row O../= num 0,O.uReturning=O.rCount}
  pure sequenceNo
 where field name value=either (const $ reject "invalid_treasury_evidence") pure (parseEither (withObject "treasury evidence" (.: name)) value)

sourceApproval :: PG.Connection -> Bool -> Text -> Int64 -> IO (Maybe Text)
sourceApproval c covered key restoration = do
  rows<-O.runSelect c $ do
    (identifier,sequenceNo,_,_,_,reason,proof,_)<-O.selectTable S.sourceRecoveryDecisions
    O.where_ (identifier O..== O.sqlStrictText key O..&& sequenceNo O..== O.sqlInt8 restoration)
    pure (reason,proof)
    :: IO [(Text,Text)]
  case rows of
    []->pure Nothing
    [(reason,raw)]->do
      proof<-decodeSaved raw
      cover<-either (const $ reject "invalid_source_approval") pure (parseEither (withObject "approval" (.:? "sourceCover")) proof) :: IO (Maybe Int64)
      require (if covered then maybe False (>0) cover else cover==Nothing) "source_approval_kind_mismatch"
      pure (Just reason)
    _->reject "duplicate_source_approval"

-- Bind approval to the latest restoration and the exact suspended work. Source
-- eligibility alone cannot revive an obligation or approve a newer work history.
sourceRecovery :: PG.Connection -> Bool -> Text -> Int64 -> IO (S.Obligation,Text,Int64,Text,Maybe Int64)
sourceRecovery c covered key restoration = do
  let text=O.sqlStrictText; num=O.sqlInt8
  rows<-O.runSelect c $ do
    obligation<-O.selectTable S.obligations
    deposit<-O.selectTable S.deposits
    O.where_ (S.obligationId obligation O..== text key O..&& S.obligationDeposit obligation O..== S.depositId deposit)
    pure (obligation,deposit)
    :: IO [(S.Obligation,S.Deposit)]
  (obligation,deposit)<-case rows of [row]->pure row; _->reject "source_approval_not_expected"
  history<-O.runSelect c $ O.orderBy (O.desc (\(n,_,_,_,_,_)->n)) $ do
    row@(_,receipt,_,_,_,_)<-O.selectTable S.sourceChecks
    O.where_ (receipt O..== text(S.depositId deposit))
    pure row
    :: IO [(Int64,Text,Text,Int64,Text,Int64)]
  source<-asDeposit deposit
  (_,status)<-readPaymentRoot c key
  let latest=case history of (_,_,phase,shortfall,_,n):_->Just(phase,shortfall,n); _->Nothing
  checked (checkSourceApprovalSource covered restoration status source latest)
  cover<-if not covered then pure Nothing else do
    covers<-O.runSelect c $ do
      (n,receipt,quantity,_,_)<-S.activeSourceCovers
      O.where_ (receipt O..== text(S.depositId deposit) O..&& quantity O..== num(S.depositAmount deposit))
      pure n
      :: IO [Int64]
    case covers of [n]->pure (Just n); _->reject "source_loss_not_covered"
  approvals<-O.runSelect c $ do
    (identifier,n)<-S.sourceApprovals
    O.where_ (identifier O..== text key)
    pure n
    :: IO [Int64]
  let cutoff=maximum(0:approvals)
  reviews<-forM [row | row@(_,_,_,_,_,n)<-history,n>cutoff && n<restoration] $ \(_,_,_,_,raw,n)->do
    evidence<-decodeSaved raw
    reason<-either (const $ reject "invalid_source_recovery_evidence") pure (parseEither (withObject "recovery" (.:? "reason")) evidence)
    if reason/=Just ("source_eligibility_lost"::Text) then pure [] else do
      entries<-field "reviewedObligations" evidence :: IO [Value]
      matches<-forM entries $ \entry->do
        identifier<-field "intent" entry
        if identifier/=key then pure [] else do
          previous<-field "previousStatus" entry; hash<-field "workHash" entry
          pure [(previous,n,hash)]
      require (length(concat matches)<=1) "source_review_context_missing"
      pure (concat matches)
  let reviewed=case concat reviews of row:_->Just row; _->Nothing
  actual<-sourceWorkHash c key
  pending<-O.runSelect c $ do
    (identifier,g,_,_,done)<-S.workCancellations
    O.where_ (identifier O..== text key O..&& done O..== num 0)
    pure g
    :: IO [Int64]
  (previous,loss)<-checked (decideSourceApproval covered restoration $ SourceApprovalFacts status source latest cover reviewed actual (not $ null pending))
  pure (obligation,previous,loss,actual,cover)
 where field name value=either (const $ reject "invalid_source_recovery_evidence") pure (parseEither (withObject "recovery" (.: name)) value)

approveSourceRecovery :: PG.Connection -> PaymentTerms -> Maybe Value -> Int64 -> Text -> Int64 -> Text -> IO ()
approveSourceRecovery c policy sourceProof now key restoration reason = do
  validReason reason
  require (restoration>0) "invalid_source_approval"
  state<-metadata c (deploymentFingerprint $ paymentPolicy policy)
  require (S.paused state==1) "pause_before_operator_action"
  old<-sourceApproval c (maybe False (const True) sourceProof) key restoration
  case old of
    Just previous->require (previous==reason) "source_approval_conflict"
    Nothing->do
      (obligation,previous,loss,hash,cover)<-sourceRecovery c (maybe False (const True) sourceProof) key restoration
      fresh c now
      checks<-O.runSelect c $ do
        (_,revision,_,at,_)<-O.selectTable S.custody
        (_,report)<-O.selectTable S.custodyReport
        pure (revision,at,report)
        :: IO [(Int64,Maybe Int64,Maybe Text)]
      forM_ sourceProof $ \evidence->do
        report<-case checks of [(_,_,Just raw)]->decodeSaved raw; _->reject "custody_not_reconciled"
        verifyLossView c (S.obligationDeposit obligation) evidence report
      let proof=encodeSaved $ object $ ["custody" .= checks,"sourceRestoration" .= restoration]
            <> maybe [] (\n->["sourceCover" .= n,"source" .= sourceProof]) cover
          text=O.sqlStrictText; num=O.sqlInt8
      require (T.length proof<=32768) "source_approval_evidence_too_large"
      sequenceNo<-nextSequence c
      count<-O.runInsert c O.Insert {O.iTable=S.sourceRecoveryDecisions,O.iRows=[(text key,num restoration,num loss,text previous,text hash,text reason,text proof,num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "source_approval_changed"
      audit c "source_recovery_approved" key

nativeSourceCandidates :: PG.Connection -> IO [W.Deposit]
nativeSourceCandidates c = do
  rows<-O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc S.depositSeen <> O.asc S.depositId) $ do
    deposit<-O.selectTable S.deposits
    recovering<-Exists.exists $ do
      (key,state)<-S.sourceRecovery
      O.where_ (key O..== S.depositId deposit O..&& state O../= O.sqlStrictText "restored")
      pure ()
    O.where_ (S.depositAsset deposit O..== O.sqlStrictText "Native" O..&& (S.depositEligible deposit O..== O.sqlInt8 0 O..|| recovering))
    pure deposit
  require (length rows<=1000) "source_recovery_backlog"
  mapM asDeposit rows

nativeSourceInspection :: PG.Connection -> Text -> IO (Maybe (Text,W.PolicySnapshot),(Text,Value))
nativeSourceInspection c key = do
  source<-readSource c key
  require (S.depositAsset source=="Native") "invalid_native_source_receipt"
  tx<-case T.splitOn ":" key of ["native",transaction,_]->pure transaction; _->reject "invalid_native_deposit_id"
  (hash,raw)<-sourceEvidence c tx
  evidence<-decodeSaved raw
  binding<-forM (S.depositOrder source) $ \oid->do
    rows<-O.runSelect c $ do
      order<-O.selectTable S.orders
      O.where_ (S.orderId order O..== O.sqlStrictText oid)
      pure (S.instruction order,S.policyJson order)
      :: IO [(Maybe Text,Text)]
    case rows of [(Just address,policy)]->(address,) <$> decodeSaved policy; _->reject "source_instruction_missing"
  pure (binding,(hash,evidence))

lossCover :: PG.Connection -> Text -> Int64 -> IO (Maybe (Amount,Amount,Text))
lossCover c receipt recovery = do
  rows<-O.runSelect c $ do
    (_,key,loss,_,capital,earned,reason,_)<-O.selectTable S.sourceLossCovers
    O.where_ (key O..== O.sqlStrictText receipt O..&& loss O..== O.sqlInt8 recovery)
    pure (capital,earned,reason)
    :: IO [(Int64,Int64,Text)]
  case rows of
    []->pure Nothing
    [(capital,earned,reason)]->Just <$> ((,,) <$> checked(amount $ toInteger capital) <*> checked(amount $ toInteger earned) <*> pure reason)
    _->reject "duplicate_source_loss_cover"

-- Cover the entire proved deficit using only unreserved operator capital. This
-- neither restores the physical source nor approves any suspended payment.
coverSourceLoss :: PG.Connection -> PaymentTerms -> W.Deposit -> Int64 -> Int64 -> Amount -> Amount -> Text -> Value -> (Int64,Int64,Bool,Value) -> IO ()
coverSourceLoss c policy source recovery now capital earned reason proof (revision,at,matches,report) = do
  validReason reason
  require (recovery>0) "invalid_source_loss_cover"
  state<-metadata c (deploymentFingerprint $ paymentPolicy policy)
  require (S.paused state==1) "pause_before_operator_action"
  let receipt=W.depositId source; quantity=units(W.depositAmount source)
      text=O.sqlStrictText; num=O.sqlInt8
  previous<-lossCover c receipt recovery
  case previous of
    Just saved->require (saved==(capital,earned,reason)) "source_loss_cover_conflict"
    Nothing->do
      current<-readSource c receipt >>= asDeposit
      history<-O.runSelect c $ O.limit 1 $ O.orderBy (O.desc (\(n,_,_,_,_,_)->n)) $ do
        row@(_,key,_,_,_,_)<-O.selectTable S.sourceChecks
        O.where_ (key O..== text receipt)
        pure row
        :: IO [(Int64,Text,Text,Int64,Text,Int64)]
      covers<-O.runSelect c $ do
        (n,key,_,_,_)<-S.activeSourceCovers
        O.where_ (key O..== text receipt)
        pure n
        :: IO [Int64]
      verifyLossView c receipt proof report
      currentRevision<-readCustodyRevision c
      booked<-balances c
      holds<-O.runSelect c $ do
        (_,asset,n,phase)<-O.selectTable S.reservations
        O.where_ (asset O..== text "Native" O..&& phase O../= text "released")
        pure n
        :: IO [Int64]
      let latest=case history of [(_,_,"missing",n,_,sequenceNo)]->Just(n,sequenceNo); _->Nothing
          checkedCustody=if matches then Just(currentRevision,revision,at) else Nothing
      postings<-checked (decideLossCover source recovery now capital earned $ LossCoverFacts current latest (not $ null covers) checkedCustody
        (M.findWithDefault 0 (Native,Float) booked-sum(map toInteger holds)) (M.findWithDefault 0 (Native,Earned) booked))
      let custody=object ["revision" .= revision,"checkedAt" .= at,"report" .= report]
          evidence=encodeSaved $ object ["source" .= proof,"custody" .= custody]
      require (T.length evidence<=32768) "source_loss_evidence_too_large"
      sequenceNo<-nextSequence c
      count<-O.runInsert c O.Insert {O.iTable=S.sourceLossCovers,O.iRows=[(num sequenceNo,text receipt,num recovery,num quantity,num $ units capital,num $ units earned,text reason,text evidence)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "source_loss_cover_insert_failed"
      post c ("source-loss-cover:"<>T.pack(show sequenceNo)) "operator capital covers verified source shortfall"
        postings
      audit c "source_loss_covered" receipt

-- Both capital coverage and payment approval bind to the same scanned outpoint
-- and independently reconciled native chain view.
verifyLossView :: PG.Connection -> Text -> Value -> Value -> IO ()
verifyLossView c receipt proof report = do
  transaction<-field "transaction" proof; index<-field "output" proof :: IO Int64
  depth<-field "confirmations" proof :: IO Int64
  hash<-field "observationHash" proof
  require (depth<0 && index>=0 && receipt=="native:"<>transaction<>":"<>T.pack(show index)) "source_loss_not_proven"
  (observed,_)<-sourceEvidence c transaction
  require (observed==hash) "source_recovery_scan_not_current"
  block<-field "nativeBlock" report :: IO Text; height<-field "nativeHeight" report :: IO Int64
  sourceBlock<-field "nodeBlock" proof; sourceHeight<-field "nodeHeight" proof
  require (block==sourceBlock && height==sourceHeight) "source_loss_custody_view_changed"
  matched<-field "matches" report
  require matched "source_loss_custody_not_current"
 where field name value=either (const $ reject "invalid_source_loss_evidence") pure (parseEither (withObject "source loss" (.: name)) value)

-- Families are ordered by increasing actual fee, never transaction ID or caller
-- order. Every member is bound to the same immutable payment/preparation policy.
nativeFamily :: PG.Connection -> Text -> Text -> IO [(RecordedAttempt,N.NativeSigned)]
nativeFamily c identity identifier = do
  ids<-O.runSelect c $ O.limit 9 $ do
    row<-O.selectTable S.attempts
    O.where_ (S.attemptIntent row O..== O.sqlStrictText identifier)
    pure (S.attemptId row)
    :: IO [Text]
  require (not(null ids) && length ids<=8) "native_replacement_family_bounds"
  pairs<-forM ids $ \tx->do
    saved<-readAttempt c tx
    signed<-decodeSaved (signedPolicy $ recordedSigned saved)
    pure (saved,signed)
  let ordered=sortOn (N.signedNativeFee.snd) pairs
      signed=map snd ordered
  checked (N.validateNativeFamily signed)
  first<-case ordered of (a,_):_->pure a; _->reject "native_replacement_family_bounds"
  prepared<-recordedPreparation c identity (signedId $ recordedSigned first)
  plan<-decodeSaved (preparedPolicy prepared)
  let outgoing=savedPayment $ preparedView prepared
      terms=savedTerms $ preparedView prepared
  require (paymentAsset outgoing==Native && N.planAmount plan==paymentAmount outgoing
    && N.planRecipient plan==paymentRecipient outgoing && N.planDepth plan==nativeDepth(paymentPolicy terms)
    && N.planFeeLimit plan==preparedFee prepared) "saved_native_policy_mismatch"
  originalDraft<-maybe (reject "preparation_draft_required") decodeSaved (preparedDraft prepared)
  let original=head signed
  require (N.sameNativeTemplate (N.draftTransaction originalDraft) (N.signedNativeTransaction original)
    && N.draftFee originalDraft==N.signedNativeFee original
    && N.sameNativePrevouts (N.draftPrevouts originalDraft) (N.signedNativePrevouts original)) "native_signed_template_changed"
  previousWinners<-O.runSelect c S.winnerHistory :: IO [(Text,Text)]
  forM_ ordered $ \(saved,member)->do
    let wire=recordedSigned saved; tx=N.signedNativeTransaction member
    point<-case N.nativeInputs tx of input:_->pure (N.nativeOutpoint input); _->reject "native_input_mismatch"
    require (recordedChain saved=="Native" && recordedGeneration saved==recordedGeneration first
      && recordedFee saved==N.planFeeLimit plan && N.signedNativePlan member==plan
      && signedId wire==N.nativeTxid tx && signedBytes wire==N.signedNativeBytes member
      && commonInput wire==Just(N.outpointTxid point<>":"<>T.pack(show $ N.outpointVout point))) "saved_native_policy_mismatch"
    when (recordedState saved=="review") $ require
      (maybe False (\proof->(signedId wire,proof) `elem` previousWinners) $ recordedObservation saved) "native_family_review_not_a_previous_winner"
  links<-O.runSelect c $ do
    (decision,child,sequenceNo)<-S.replacementMembers
    (n,parent,fee,draft,_,_)<-S.replacementDrafts
    O.where_ (decision O..== n O..&& O.in_ (map O.sqlStrictText ids) child)
    pure (decision,parent,child,fee,draft,sequenceNo)
    :: IO [(Int64,Text,Text,Int64,Text,Int64)]
  cancelled<-O.runSelect c S.replacementCancellations :: IO [(Int64,Text,Int64)]
  require (length links==length ordered-1) "native_replacement_lineage_missing"
  forM_ (zip [1..] $ zip ordered $ drop 1 ordered) $ \(index,((parent,_),(child,member)))->do
    (decision,fee,raw,n)<-case [(d,f,r,s)|(d,p,t,f,r,s)<-links,p==signedId(recordedSigned parent),t==signedId(recordedSigned child)] of
      [row]->pure row; _->reject "native_replacement_lineage_missing"
    draft<-decodeSaved raw
    checked (N.validateNativeReplacementDraft (take index signed) (N.draftFee draft) draft)
    require (fee==units(N.signedNativeFee member) && fee==units(N.draftFee draft)
      && N.sameNativeTemplate (N.draftTransaction draft) (N.signedNativeTransaction member)
      && n>decision && all (\(d,_,_)->d/=decision) cancelled) "native_replacement_member_changed"
  pure ordered

replacementDecision :: PG.Connection -> Text -> Amount -> Text -> IO (Maybe (Int64,Bool))
replacementDecision c parent fee reason = do
  rows<-O.runSelect c $ do
    (n,p,f,_,_,r)<-S.replacementDrafts
    O.where_ (p O..== O.sqlStrictText parent O..&& f O..== O.sqlInt8(units fee) O..&& r O..== O.sqlStrictText reason)
    pure n
    :: IO [Int64]
  decision<-case rows of []->pure Nothing; [n]->pure (Just n); _->reject "duplicate_native_replacement_decision"
  forM decision $ \n->do
    cancelled<-O.runSelect c $ do
      (d,_,_)<-S.replacementCancellations
      O.where_ (d O..== O.sqlInt8 n)
      pure d
      :: IO [Int64]
    pure (n,not $ null cancelled)

-- Shared read-only preflight and atomic write guard. The signer can build only
-- a bounded replacement of the current, already broadcast family member.
replacementDraftContext :: PG.Connection -> Text -> Int64 -> Text -> Amount -> IO [(RecordedAttempt,N.NativeSigned)]
replacementDraftContext c identity now txid fee = do
  operator<-readOperator c identity now
  require (operatorPaused operator) "pause_before_operator_action"
  current<-sendContext c identity txid
  require (recordedChain current=="Native" && recordedState current=="broadcast_intent"
    && maybe False (>0) (recordedSequence current)) "native_replacement_not_expected"
  family<-nativeFamily c identity (recordedPayment current)
  checked (checkReplacementParent current $ map fst family)
  _<-checked (N.replacementOutputs (snd $ last family) fee)
  drafts<-O.runSelect c $ do
    (n,parent,_,_,_,_)<-S.replacementDrafts
    O.where_ (O.in_ (map (O.sqlStrictText.signedId.recordedSigned.fst) family) parent)
    pure n
    :: IO [Int64]
  checked (checkReplacementDraft operator current (map fst family) $ length drafts)
  pure family

saveReplacementDraft :: PG.Connection -> PaymentTerms -> Int64 -> RecordedAttempt -> N.NativeDraft -> Text -> IO Int64
saveReplacementDraft c policy now expected draft reason = do
  validReason reason
  validateSavedJson 200000 (encodeSaved draft)
  let identity=deploymentFingerprint(paymentPolicy policy); txid=signedId(recordedSigned expected)
      identifier=recordedPayment expected; text=O.sqlStrictText; num=O.sqlInt8
  metadata c identity >>= \state->require (S.paused state==1) "pause_before_operator_action"
  old<-replacementDecision c txid (N.draftFee draft) reason
  case old of
    Just (n,_)->do
      rows<-O.runSelect c $ do
        (key,_,_,saved,_,_)<-S.replacementDrafts
        O.where_ (key O..== num n)
        pure saved
        :: IO [Text]
      require (rows==[encodeSaved draft]) "native_replacement_draft_conflict"
      pure n
    Nothing->do
      family<-replacementDraftContext c identity now txid (N.draftFee draft)
      let current=fst(last family)
      require (current==expected) "native_replacement_not_expected"
      checked (N.validateNativeReplacementDraft (map snd family) (N.draftFee draft) draft)
      hash<-paymentWorkHash c identifier
      custody<-O.runSelect c $ do
        (_,revision,_,at,_)<-O.selectTable S.custody
        (_,report)<-O.selectTable S.custodyReport
        pure (revision,at,report)
        :: IO [(Int64,Maybe Int64,Maybe Text)]
      let proof=encodeSaved $ object ["custody" .= custody,"parentBroadcastSequence" .= recordedSequence current]
      require (T.length proof<=32768) "native_replacement_evidence_too_large"
      n<-nextSequence c
      count<-O.runInsert c O.Insert {O.iTable=S.replacementDecisions,
        O.iRows=[(num n,text txid,num $ units $ N.draftFee draft,text $ encodeSaved draft,text hash,text reason,text proof)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "native_replacement_draft_insert_failed"
      audit c "native_replacement_drafted" txid
      pure n

cancelReplacementDraft :: PG.Connection -> PaymentTerms -> Int64 -> Text -> IO ()
cancelReplacementDraft c policy decision reason = do
  validReason reason
  require (decision>0) "invalid_native_replacement_cancellation"
  metadata c (deploymentFingerprint $ paymentPolicy policy) >>= \state->require (S.paused state==1) "pause_before_operator_action"
  old<-O.runSelect c $ do
    (n,r,_)<-S.replacementCancellations
    O.where_ (n O..== O.sqlInt8 decision)
    pure r
    :: IO [Text]
  case old of
    [saved]->require (saved==reason) "native_replacement_cancellation_conflict"
    []->do
      drafts<-O.runSelect c $ do
        (n,parent,_,_,_,_)<-S.replacementDrafts
        O.where_ (n O..== O.sqlInt8 decision)
        pure parent
        :: IO [Text]
      parent<-case drafts of [p]->pure p; _->reject "native_replacement_draft_missing"
      members<-O.runSelect c $ do
        (n,tx,_)<-S.replacementMembers
        O.where_ (n O..== O.sqlInt8 decision)
        pure tx
        :: IO [Text]
      require (null members) "native_replacement_already_signed"
      sequenceNo<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.replacementCancellationRows,O.iRows=[(O.sqlInt8 decision,O.sqlStrictText reason,O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      audit c "native_replacement_cancelled" parent
    _->reject "duplicate_native_replacement_cancellation"

replacementMember :: PG.Connection -> Int64 -> IO (Maybe RecordedAttempt)
replacementMember c decision = do
  rows<-O.runSelect c $ do
    (n,tx,_)<-S.replacementMembers
    O.where_ (n O..== O.sqlInt8 decision)
    pure tx
    :: IO [Text]
  case rows of []->pure Nothing; [tx]->Just <$> readAttempt c tx; _->reject "duplicate_native_replacement_member"

-- Read-only signer authorization. The pending draft intentionally blocks the
-- ordinary send path, so this checks its own exact draft/family binding.
replacementSigning :: PG.Connection -> Text -> Bool -> Int64 -> Int64 -> IO ([(RecordedAttempt,N.NativeSigned)],N.NativeDraft)
replacementSigning c identity backed now decision = do
  require (decision>0) "invalid_native_replacement_decision"
  state<-metadata c identity
  require (S.paused state==1) "pause_before_operator_action"
  when backed $ require (S.backupSequence state>=S.criticalSequence state) "signing_backup_required"
  fresh c now
  old<-replacementMember c decision
  cancelled<-O.runSelect c $ do
    (n,_,_)<-S.replacementCancellations
    O.where_ (n O..== O.sqlInt8 decision)
    pure n
    :: IO [Int64]
  require (old==Nothing && null cancelled) "native_replacement_not_unsigned"
  rows<-O.runSelect c $ do
    (n,parent,fee,draft,hash,_)<-S.replacementDrafts
    O.where_ (n O..== O.sqlInt8 decision)
    pure (parent,fee,draft,hash)
    :: IO [(Text,Int64,Text,Text)]
  (txid,fee,raw,hash)<-case rows of [row]->pure row; _->reject "native_replacement_draft_missing"
  parent<-readAttempt c txid
  let identifier=recordedPayment parent
  prepared<-readPreparation c identity identifier
  eligible<-paymentSourceEligible c (savedPayment $ preparedView prepared)
  family<-nativeFamily c identity identifier
  currentHash<-paymentWorkHash c identifier
  checked (checkReplacementSigning prepared parent (map fst family) eligible (hash,currentHash))
  draft<-decodeSaved raw
  require (units(N.draftFee draft)==fee) "native_replacement_draft_changed"
  checked (N.validateNativeReplacementDraft (map snd family) (N.draftFee draft) draft)
  pure (family,draft)

recordReplacement :: PG.Connection -> StorePolicy -> Int64 -> Int64 -> [(RecordedAttempt,N.NativeSigned)] -> N.NativeSigned -> IO RecordedAttempt
recordReplacement c config now decision expected signed = do
  let identity=deploymentFingerprint(paymentPolicy $ executionTerms config)
      txid=N.nativeTxid(N.signedNativeTransaction signed); bytes=N.signedNativeBytes signed
      policy=encodeSaved signed; text=O.sqlStrictText; num=O.sqlInt8
  require (T.length bytes<=200000) "invalid_native_signed_bytes"
  validateSavedJson 32768 policy
  old<-replacementMember c decision
  case old of
    Just saved->do
      let previous=recordedSigned saved
      require (signedId previous==txid && signedBytes previous==bytes && signedPolicy previous==policy) "native_replacement_signature_conflict"
      pure saved
    Nothing->do
      (family,draft)<-replacementSigning c identity (requireBackup config) now decision
      require (family==expected) "native_replacement_family_changed"
      checked (N.validateNativeFamily $ map snd family<>[signed])
      require (N.sameNativeTemplate (N.draftTransaction draft) (N.signedNativeTransaction signed)
        && N.draftFee draft==N.signedNativeFee signed && N.sameNativePrevouts (N.draftPrevouts draft) (N.signedNativePrevouts signed)) "native_replacement_signed_template_changed"
      let parent=fst(last family)
      n<-nextSequence c
      count<-O.runInsert c O.Insert {O.iTable=S.attempts,
        O.iRows=[S.Attempt (text txid) (text $ recordedPayment parent) (text bytes) (text policy) (num $ units $ recordedFee parent)
          (text "signed") O.null O.null (num $ fromIntegral $ recordedGeneration parent)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      linked<-O.runInsert c O.Insert {O.iTable=S.replacementMemberRows,O.iRows=[(num decision,text txid,num n)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1 && linked==1) "native_replacement_member_insert_failed"
      audit c "native_replacement_signed" txid
      readAttempt c txid

-- Filter unchanged settled history in PostgreSQL before applying the recovery
-- bound. The fixed JSON projections are inside this one closed Opaleye read.
nativeSettlementCandidates :: PG.Connection -> IO [RecordedAttempt]
nativeSettlementCandidates c = do
  ids<-O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc id) $ do
    saved<-O.selectTable S.attempts
    intent<-O.selectTable S.paymentRoots
    O.where_ (S.attemptIntent saved O..== S.rootId intent O..&& S.rootChain intent O..== text "Native"
      O..&& S.attemptState saved O..== text "settled")
    -- CASE protects the native-only inner codec even if PostgreSQL evaluates
    -- this expression before its WHERE filters (Solana proofs have another shape).
    let proof=json $ O.ifThenElse (S.rootChain intent O..== text "Native" O..&& S.attemptState saved O..== text "settled")
          (O.fromNullable (text "{}") (json (O.fromNullable (text "{}") $ S.attemptObservation saved) O..->> text "proof")) (text "{}")
        anchor=O.fromNullable (text "") (proof O..->> text "blockhash")
        depth=integer (proof O..->> text "requiredDepth") 0
    healthy<-Exists.exists $ do
      event<-O.selectTable S.chainEvents
      (hash,_,_,raw)<-O.selectTable S.observationEvidence
      let confirmations=integer ((json raw O..-> text "proof") O..->> text "confirmations") (-1)
      O.where_ (S.eventChain event O..== text "Native" O..&& S.eventId event O..== S.attemptId saved
        O..&& S.eventKind event O..== text "outgoing" O..&& S.eventReview event O..== O.sqlInt8 0
        O..&& S.eventAnchor event O..== anchor O..&& S.eventHash event O..== hash
        O..&& depth O..> O.sqlInt8 0 O..&& confirmations O..>= depth)
      pure ()
    reviewed<-Exists.exists $ do
      (tx,state)<-S.nativeRecovery
      O.where_ (tx O..== S.attemptId saved O..&& state O../= text "reconfirmed")
      pure ()
    O.where_ (O.not healthy O..|| reviewed)
    pure (S.attemptId saved)
  require (length ids<=1000) "native_settlement_recovery_backlog"
  mapM (readAttempt c) ids
 where
  text=O.sqlStrictText
  json :: S.TextField -> O.FieldNullable O.SqlJsonb
  json=O.toNullable . O.unsafeCast "jsonb"
  integer value fallback=O.unsafeCast "bigint" (O.fromNullable (text $ T.pack $ show (fallback::Int64)) value)

-- Financial settlement stays final in the ledger. Confirmation loss creates a
-- review, reconfirmation changes evidence only, and a family winner change books
-- only its fee difference. No principal, reservation or intent is reopened.
recordNativeSettlement :: PG.Connection -> Text -> RecordedAttempt -> NativeSettlementCheck -> IO ()
recordNativeSettlement c identity expected result = do
  let txid=signedId(recordedSigned expected); identifier=recordedPayment expected
      text=O.sqlStrictText; num=O.sqlInt8
  actual<-readAttempt c txid
  require (actual==expected && recordedChain actual=="Native" && recordedState actual=="settled"
    && maybe False (>0) (recordedSequence actual)) "native_settlement_changed"
  nativeResolved c actual
  previous<-maybe (reject "native_settlement_missing") pure (recordedObservation actual)
  case result of
    NativeWinnerChanged expectedFamily winnerId costs proof->do
      family<-nativeFamily c identity identifier
      (winner,signed)<-case [(a,s)|(a,s)<-family,signedId(recordedSigned a)==winnerId] of
        [member]->pure member; _->reject "native_family_winner_missing"
      oldSigned<-decodeSaved (signedPolicy $ recordedSigned actual)
      oldCosts<-settledCosts actual oldSigned
      hash<-nativeSettlementProof c winner signed costs proof
      effect<-checked (decideNativeWinner expectedFamily winnerId costs proof $ NativeWinnerFacts actual (map fst family) oldCosts)
      let saved=changedObservation effect; delta=changedFee effect
      n<-nextSequence c
      inserted<-O.runInsert c O.Insert {O.iTable=S.nativeWinnerChanges,
        O.iRows=[(num n,text txid,text winnerId,text previous,text saved,text hash,num $ fromInteger delta)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (inserted==1) "native_winner_record_failed"
      post c ("native-winner-fee:"<>T.pack(show n)) "canonical native winner fee adjustment"
        (winnerPostings effect)
      oldChanged<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text "review"},O.uWhere= \r->S.attemptId r O..== text txid,O.uReturning=O.rCount}
      newChanged<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text "settled",S.attemptObservation=O.toNullable $ text saved},O.uWhere= \r->S.attemptId r O..== text winnerId,O.uReturning=O.rCount}
      require (oldChanged==1 && newChanged==1) "native_winner_context_changed"
      changed<-O.runUpdate c O.Update {O.uTable=S.paymentRoots,
        O.uUpdateWith= \r->r {S.rootWinner=O.toNullable $ text winnerId},
        O.uWhere= \r->S.rootId r O..== text identifier O..&& O.matchNullable (O.sqlBool False) (O..== text txid) (S.rootWinner r),O.uReturning=O.rCount}
      require (changed==1) "native_winner_context_changed"
      pauseScan c "native_winner_changed"
      audit c "native_winner_changed" (txid<>":"<>winnerId)
    _->do
      case result of
        NativeReconfirmed costs proof->do
          family<-nativeFamily c identity identifier
          signed<-case [s|(a,s)<-family,a==actual] of [s]->pure s; _->reject "native_settlement_changed"
          oldCosts<-settledCosts actual signed
          require (costs==oldCosts) "native_recovery_cost_changed"
          _<-nativeSettlementProof c actual signed costs proof
          pure ()
        _->pure ()
      old<-O.runSelect c $ do
        (tx,_,status,proof,_)<-S.nativeRecoveryDetails
        O.where_ (tx O..== text txid)
        pure (status,proof)
        :: IO [(Text,Text)]
      decision<-checked (decideNativeReview result previous old)
      forM_ decision $ \(state,saved)->do
        n<-nextSequence c
        _<-O.runInsert c O.Insert {O.iTable=S.nativeRecoveryRows,O.iRows=[(text txid,text previous,text state,text saved,num n)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        when (state=="reconfirmed") $ do
          _<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptObservation=O.toNullable $ text saved},O.uWhere= \r->S.attemptId r O..== text txid,O.uReturning=O.rCount}
          pure ()
        pauseScan c "native_settlement_recovery"
        audit c "native_settlement_recovery" (txid<>":"<>state)

settledCosts :: RecordedAttempt -> N.NativeSigned -> IO W.PaymentCosts
settledCosts saved signed = do
  observed<-maybe (reject "native_settlement_missing") decodeSaved (recordedObservation saved)
  costs<-nativeProofField "costs" observed
  proof<-nativeProofField "proof" observed >>= decodeSaved
  txid<-nativeProofField "txid" proof
  depth<-nativeProofField "requiredDepth" proof
  require (txid==signedId(recordedSigned saved) && depth==N.planDepth(N.signedNativePlan signed)
    && W.networkFee costs==N.signedNativeFee signed && units(W.accountRent costs)==0) "native_recovery_cost_changed"
  pure costs

nativeSettlementProof :: PG.Connection -> RecordedAttempt -> N.NativeSigned -> W.PaymentCosts -> Text -> IO Text
nativeSettlementProof c saved signed costs raw = do
  proof<-decodeSaved raw
  txid<-nativeProofField "txid" proof
  anchor<-nativeProofField "blockhash" proof
  depth<-nativeProofField "requiredDepth" proof
  height<-nativeProofField "height" proof :: IO Int64
  let plan=N.signedNativePlan signed
  require (txid==signedId(recordedSigned saved) && N.transactionId anchor && height>=0 && depth==N.planDepth plan
    && W.networkFee costs==N.signedNativeFee signed && units(W.accountRent costs)==0) "native_recovery_policy_changed"
  (kind,scanned,evidence)<-custodyEvent c "Native" txid
  confirmations<-nativeProofField "confirmations" evidence
  net<-nativeProofField "walletNetUnits" evidence
  fee<-nativeProofField "feeUnits" evidence
  require (kind=="outgoing" && scanned==anchor && confirmations>=depth
    && net==T.pack(show $ negate $ toInteger $ units $ N.planAmount plan) && fee==N.signedNativeFee signed) "native_recovery_scan_not_current"
  hashes<-O.runSelect c $ do
    event<-O.selectTable S.chainEvents
    O.where_ (S.eventChain event O..== O.sqlStrictText "Native" O..&& S.eventId event O..== O.sqlStrictText txid)
    pure (S.eventHash event)
  case hashes of [hash]->pure hash; _->reject "native_recovery_scan_not_current"

nativeProofField :: FromJSON a => Key -> Value -> IO a
nativeProofField key value=either (const $ reject "invalid_native_settlement") pure (parseEither (withObject "native proof" (.: key)) value)

nativeResolved :: PG.Connection -> RecordedAttempt -> IO ()
nativeResolved c saved = do
  context<-O.runSelect c $ do
    intent<-O.selectTable S.paymentRoots
    (key,asset,quantity,released)<-O.selectTable S.feeHolds
    O.where_ (S.rootId intent O..== O.sqlStrictText(recordedPayment saved) O..&& key O..== S.rootId intent)
    pure (S.rootPhase intent,S.rootWinner intent,asset,quantity,released)
    :: IO [(Text,Maybe Text,Text,Int64,Int64)]
  require (context==[("settled",Just(signedId $ recordedSigned saved),"Native",units(recordedFee saved),1)]) "native_winner_context_changed"

-- A rebroadcast repairs one already-booked native effect. It cannot reopen
-- principal, acquire new inputs or turn an unresolved intent into a payment.
nativeRebroadcastContext :: PG.Connection -> Text -> Text -> IO (RecordedAttempt,[(RecordedAttempt,N.NativeSigned)],Text,Value,Int64)
nativeRebroadcastContext c identity txid = do
  state<-metadata c identity
  require (S.paused state==1) "pause_before_operator_action"
  saved<-readAttempt c txid
  require (recordedChain saved=="Native" && recordedState saved=="settled"
    && maybe False (>0) (recordedSequence saved)) "native_rebroadcast_payment_changed"
  nativeResolved c saved
  view<-readPayment c identity (recordedPayment saved)
  eligible<-paymentSourceEligible c (savedPayment view)
  family<-nativeFamily c identity (recordedPayment saved)
  reviews<-O.runSelect c $ do
    (key,previous,status,proof,n)<-S.nativeRecoveryDetails
    O.where_ (key O..== O.sqlStrictText txid)
    pure (previous,status,proof,n)
    :: IO [(Text,Text,Text,Int64)]
  (previous,status,raw,n)<-case reviews of [row]->pure row; _->reject "native_rebroadcast_review_missing"
  value<-decodeSaved raw
  reason<-nativeProofField "reason" value :: IO Text
  checked (checkRebroadcast saved $ RebroadcastFacts (S.paused state==1) view eligible (map fst family) (previous,status,reason))
  pure (saved,family,status,value,n)

nativeRebroadcastDecision :: PG.Connection -> Text -> Int64 -> Text -> IO (Maybe Int64)
nativeRebroadcastDecision c txid anchor reason = do
  require (anchor>0) "invalid_native_rebroadcast_approval"
  validReason reason
  rows<-O.runSelect c $ O.limit 2 $ do
    (key,_,_,proof,n)<-O.selectTable S.nativeRecoveryRows
    let value=O.toNullable (O.unsafeCast "jsonb" proof :: O.Field O.SqlJsonb)
    O.where_ (key O..== O.sqlStrictText txid O..&& O.fromNullable (O.sqlStrictText "") (value O..->> O.sqlStrictText "rebroadcastRecovery") O..== O.sqlStrictText(T.pack $ show anchor))
    pure (proof,n)
    :: IO [(Text,Int64)]
  case rows of
    []->pure Nothing
    [(proof,n)]->do
      saved<-decodeSaved proof >>= nativeProofField "operatorReason"
      require (saved==reason) "native_rebroadcast_conflict"
      pure (Just n)
    _->reject "duplicate_native_rebroadcast_decision"

recordNativeRebroadcast :: PG.Connection -> Text -> RecordedAttempt -> [RecordedAttempt] -> Int64 -> Text -> Value -> IO Int64
recordNativeRebroadcast c identity expected family anchor reason proof = do
  let txid=signedId(recordedSigned expected); text=O.sqlStrictText; num=O.sqlInt8
  old<-nativeRebroadcastDecision c txid anchor reason
  case old of
    Just n->pure n
    Nothing->do
      (saved,actual,status,review,n)<-nativeRebroadcastContext c identity txid
      require (saved==expected && map fst actual==family && n==anchor) "native_rebroadcast_review_changed"
      provedId<-nativeProofField "transaction" proof
      bytesHash<-nativeProofField "bytesHash" proof
      block<-nativeProofField "nodeBlock" proof
      members<-nativeProofField "family" proof
      absent<-nativeProofField "noActiveFamilyPayment" proof
      require (provedId==txid && bytesHash==digest(TE.encodeUtf8 $ signedBytes $ recordedSigned saved)
        && N.transactionId block && members==map (signedId.recordedSigned) family && absent) "native_rebroadcast_proof_mismatch"
      fields<-case review of Object fields->pure fields; _->reject "invalid_native_settlement"
      let encoded=encodeSaved $ Object $ KM.insert "rebroadcastRecovery" (toJSON anchor) $
            KM.insert "operatorReason" (toJSON reason) $ KM.insert "rebroadcastProof" proof fields
      validateSavedJson 32768 encoded
      previous<-maybe (reject "native_settlement_missing") pure (recordedObservation saved)
      sequenceNo<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.nativeRecoveryRows,
        O.iRows=[(text txid,text previous,text status,text encoded,num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      audit c "native_rebroadcast_approved" (txid<>":"<>T.pack(show sequenceNo))
      pure sequenceNo
