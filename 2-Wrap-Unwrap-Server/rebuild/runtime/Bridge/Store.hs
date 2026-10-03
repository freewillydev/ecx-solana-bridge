{-# LANGUAGE DataKinds, GADTs, LambdaCase, ScopedTypeVariables #-}
-- Closed ledger operations. Connections, queries and transaction callbacks never
-- escape this module; the runtime will interpret its customer/operator DSL here.
module Bridge.Store
  ( Reader, Writer, BridgeError(..), StoreRead(..), StoreWrite(..), OrderLimits(..), StorePolicy(..), AllocationClaim(..), LedgerState(..), WithdrawalView(..), PaymentView(..), PaymentStatus(..), PreparedPayment(..), SignedAttempt(..), RecordedAttempt(..), NativeLockWork(..), NativeSettlementCheck(..), CustodySnapshot(..)
  , StoreBackup(..), LedgerArchive(..), BackupReceipt(..), evalBackup, StoreRestore(..), evalRestore
  , withReader, withWriter, withFencedWriter, evalRead, evalWrite ) where

import qualified Bridge.NativePayment as N
import Bridge.Error
import Bridge.Fence (withFence)
import Bridge.Identity (bearerHash,digest,payInstruction,publicKey)
import Text.Read (readMaybe)
import qualified Bridge.Wire as W
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),PolicySnapshot(..),CostLimits(..),SignedAttempt(..))
import qualified Bridge.Store.Schema as S
import Bridge.Store.Catalog (claimWorker,verifyReadRole,exportSnapshot)
import Bridge.Store.Backup (LedgerArchive(..),archiveLedger,BackupReceipt(..),loadRemoteBackup,uploadRemoteArchive,loadLedgerArchive,restoreLedger,discardRestore,downloadRemoteArchive)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString as BS
import Data.List (nub,sortOn)
import Data.Profunctor.Product (p3)
import Data.Scientific (Scientific,floatingOrInteger)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless,forM,forM_,when)
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
data WithdrawalView = WithdrawalView
  { withdrawalPayment :: Payment, withdrawalTerms :: PaymentTerms, withdrawalReason :: Text
  , withdrawalSequence :: Int64, withdrawalCancellation :: Maybe (Text,Int64) }
  deriving (Eq,Show)

data OrderLimits = OrderLimits
  { orderMinimum :: Amount, orderMaximum :: Amount, quoteSeconds :: Int64
  , graceSeconds :: Int64, maximumQueued :: Int, nativeDaily :: Amount, solanaDaily :: Amount }
  deriving (Eq,Show)

data StorePolicy = StorePolicy
  { executionTerms :: PaymentTerms, admissionLimits :: OrderLimits
  , deploymentName :: Text, requireBackup :: Bool } deriving (Eq,Show)
data PaymentStatus = PaymentReady | PaymentPaying | PaymentPaid | PaymentReview | PaymentCancelled deriving (Eq,Show)
data PaymentView = PaymentView
  { savedPayment :: Payment, savedTerms :: PaymentTerms, savedStatus :: PaymentStatus } deriving (Eq,Show)
data PreparedPayment = PreparedPayment
  { preparedView :: PaymentView, preparedGeneration :: Int, preparedPolicy :: Text
  , preparedDraft :: Maybe Text, preparedFee :: Amount } deriving (Eq,Show)
data RecordedAttempt = RecordedAttempt
  { recordedPayment :: Text, recordedChain :: Text, recordedGeneration :: Int
  , recordedFee :: Amount, recordedState :: Text, recordedSequence :: Maybe Int64
  , recordedObservation :: Maybe Text, recordedSigned :: SignedAttempt } deriving (Eq,Show)
data AllocationClaim = AllocationClaim { allocationLabel :: Text, mayAllocate :: Bool }
  deriving (Eq,Show)

data NativeLockWork = NativeLockWork
  { lockPreparation :: PreparedPayment, lockCancelling :: Bool, lockAttempts :: [RecordedAttempt] } deriving (Eq,Show)

data CustodySnapshot = CustodySnapshot
  { custodyRevision :: Int64, custodyTotals :: M.Map Asset Integer
  , custodyHeads :: [(Text,Text)], custodySlot :: Int64, custodyPending :: [RecordedAttempt] } deriving (Eq,Show)
data NativeSettlementCheck = NativeConfirming | NativeUnavailable Text
  | NativeReconfirmed W.PaymentCosts Text
  | NativeWinnerChanged [RecordedAttempt] Text W.PaymentCosts Text deriving (Eq,Show)

-- Offline restoration requires database-creation authority, not a Reader or
-- paying Writer. No online handler receives this capability or chooses a target.
data StoreRestore a where
  RestoreLedger :: FilePath -> Text -> Int64 -> StoreRestore (Text,Int64)
  RecoverLedger :: FilePath -> Text -> FilePath -> Text -> Int64 -> StoreRestore (Text,Int64)

evalRestore :: PG.ConnectInfo -> StoreRestore a -> IO a
evalRestore settings (RecoverLedger configuration snapshot directory identity minimumSequence) = do
  remote<-loadRemoteBackup configuration
  bracket (downloadRemoteArchive remote snapshot identity minimumSequence directory)
    (removeDirectoryRecursive . takeDirectory . manifestPath) $ \archive->
      evalRestore settings (RestoreLedger (manifestPath archive) identity minimumSequence)
evalRestore settings (RestoreLedger manifest identity minimumSequence) = do
  archive<-loadLedgerArchive identity minimumSequence manifest
  bracketOnError (restoreLedger settings archive) discardRestore $ \target->
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
  minimumInput <- checked (amount 2)
  require (orderMinimum limit>=minimumInput && orderMaximum limit>=orderMinimum limit
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
evalRead (Reader settings identity remote) operation = bracket (PG.connect settings) PG.close $ \c ->
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
      ReadCustodySnapshot now origins losses -> custodySnapshot c now origins losses
      ReadCustodyEvent chain identifier -> custodyEvent c chain identifier
      HasCustodyEvent chain identifier -> do
        rows<-O.runSelect c $ O.limit 1 $ do
          event<-O.selectTable S.chainEvents
          O.where_ (S.eventId event O..== O.sqlStrictText identifier O..&& O.in_ (map O.sqlStrictText $ if chain=="Solana" then ["Solana","SolanaOperating"] else [chain]) (S.eventChain event))
          pure (S.eventId event)
        pure (not $ null (rows :: [Text]))
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
  SettlePayment expected costs proof -> settlePayment c (deploymentFingerprint $ paymentPolicy policy) expected costs proof
  FailSolana expected fee proof -> failSolana c (deploymentFingerprint $ paymentPolicy policy) expected fee proof
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
    row <- authorizedOrder c (deploymentFingerprint $ paymentPolicy policy) header identifier
    request <- decodeSaved (S.requestJson row)
    require (W.direction request==NativeToWrapped && S.instruction row==Nothing) "invalid_native_provisioning_order"
    let label="ecx-bridge:v1:"<>deploymentName config<>":order:"<>identifier
    old <- allocation c identifier
    case old of
      Just saved -> require (saved==label) "allocation_label_mismatch" >> pure(AllocationClaim label False)
      Nothing -> do
        intakeReady c (deploymentFingerprint $ paymentPolicy policy) now
        require (S.status row=="Provisioning" && now<=S.deadline row) "deposit_window_closed"
        n <- nextSequence c
        _ <- O.runInsert c O.Insert {O.iTable=S.nativeAllocations,
          O.iRows=[(O.sqlStrictText identifier,O.sqlStrictText label,O.sqlInt8 n)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        pure (AllocationClaim label True)
  RecordNative header identifier label address -> do
    row <- authorizedOrder c (deploymentFingerprint $ paymentPolicy policy) header identifier
    request <- decodeSaved (S.requestJson row)
    saved <- allocation c identifier
    require (saved==Just label && W.direction request==NativeToWrapped &&
      not(T.null address) && T.length address<=128 && not(T.any (<= ' ') address)) "invalid_native_allocation_result"
    saveInstruction c row address
  BindSolana now header identifier -> do
    row <- authorizedOrder c (deploymentFingerprint $ paymentPolicy policy) header identifier
    request <- decodeSaved (S.requestJson row)
    require (W.direction request==WrappedToNative) "invalid_solana_provisioning_order"
    instruction <- checked (payInstruction identifier)
    when (S.instruction row==Nothing) $ do
      intakeReady c (deploymentFingerprint $ paymentPolicy policy) now
      require (S.status row=="Provisioning" && now<=S.deadline row) "deposit_window_closed"
    saveInstruction c row instruction
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
  ReserveFees now key currency n destination explanation -> do
    validReason explanation
    require (now>=0 && T.length key==64 && T.all (`elem` ("0123456789abcdef"::String)) key && n<=orderMaximum limit) "invalid_fee_withdrawal"
    funding <- checked (earnedFees key currency n)
    outgoing <- checked (payment ("fee:"<>key) funding destination)
    old <- readWithdrawal c key
    case old of
      Just saved -> do
        require (withdrawalPayment saved==outgoing && withdrawalTerms saved==policy && withdrawalReason saved==explanation) "fee_withdrawal_conflict"
        pure saved
      Nothing -> do
        d <- metadata c (deploymentFingerprint $ paymentPolicy policy)
        require (S.paused d==1) "fee_withdrawal_requires_pause"
        fresh c now
        booked <- balances c
        require (M.findWithDefault 0 (currency,Earned) booked>=toInteger(units n)) "insufficient_earned_fees"
        sequenceNumber <- nextSequence c
        let raw=TE.decodeUtf8 (BL.toStrict $ encode policy)
        count <- O.runInsert c O.Insert {O.iTable=S.withdrawals,
          O.iRows=[S.Withdrawal (O.sqlStrictText key) (O.sqlStrictText $ T.pack $ show currency)
            (O.sqlInt8 $ units n) (O.sqlStrictText destination) (O.sqlStrictText raw)
            (O.sqlStrictText explanation) (O.sqlInt8 sequenceNumber)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        require (count==1) "withdrawal_insert_failed"
        entries <- checked (reserveEarned funding)
        post c ("fee-reserve:"<>key) "reserve earned fees for operator withdrawal" entries
        pure (WithdrawalView outgoing policy explanation sequenceNumber Nothing)
  CancelFees key explanation -> do
    validReason explanation
    saved <- readWithdrawal c key >>= maybe (reject "fee_withdrawal_not_found") pure
    case withdrawalCancellation saved of
      Just (reason,_) -> require (reason==explanation) "fee_withdrawal_cancellation_conflict" >> pure saved
      Nothing -> do
        work <- O.runSelect c $ do
          identifier <- O.selectTable S.intentIds
          O.where_ (identifier O..== O.sqlStrictText ("fee:"<>key))
          pure identifier
          :: IO [Text]
        unless (null work) $ do
          retry<-cancelledGeneration c ("fee:"<>key)
          require (retry/=Nothing) "fee_withdrawal_payment_exists"
          state<-metadata c (deploymentFingerprint $ paymentPolicy policy)
          require (S.paused state==1) "pause_before_operator_action"
          _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(identifier,a,n,_)->(identifier,a,n,O.sqlInt8 1),O.uWhere= \(identifier,_,_,_)->identifier O..== O.sqlStrictText("fee:"<>key),O.uReturning=O.rCount}
          pure ()
        n <- nextSequence c
        count <- O.runInsert c O.Insert {O.iTable=S.cancellations,
          O.iRows=[(O.sqlStrictText key,O.sqlStrictText explanation,O.sqlInt8 n)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        require (count==1) "withdrawal_cancellation_insert_failed"
        entries <- checked (releaseEarned $ paymentFunding $ withdrawalPayment saved)
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
        PG.begin c
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
    [r] | S.singleton r==1 && S.schemaVersion r==21 && S.fingerprint r==identity
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
fresh c now = do
  rows <- O.runSelect c (O.selectTable S.custody) :: IO [(Int64,Int64,Maybe Int64,Maybe Int64,Maybe Text)]
  require (case rows of
    [(1,revision,Just checkedRevision,Just at,Nothing)] -> checkedRevision==revision && at>=0 && at<=now && toInteger now-toInteger at<=60
    _ -> False) "custody_not_reconciled"
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
validReason r=require (not(T.null $ T.strip r) && T.length r<=512) "invalid_reason"

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
    (obligationId,order,_,_) <- S.orderObligations
    O.where_ (tx O..== attempt O..&& intent O..== intentId O..&& O.matchNullable (O.sqlBool False) (O..== obligationId) obligation
      O..&& order O..== O.sqlStrictText identifier O..&& state O../= O.sqlStrictText "reconfirmed")
    pure tx
    :: IO [Text]
  obligations <- O.runSelect c $ do
    (_,order,deposit,state) <- S.orderObligations
    O.where_ (order O..== O.sqlStrictText identifier)
    pure (deposit,state)
    :: IO [(Text,Text)]
  sources <- O.runSelect c $ do
    (deposit,state) <- S.sourceRecovery
    (depositId,order) <- S.orderDeposits
    O.where_ (deposit O..== depositId O..&& state O../= O.sqlStrictText "restored"
      O..&& O.matchNullable (O.sqlBool False) (O..== O.sqlStrictText identifier) order)
    pure deposit
    :: IO [Text]
  accounted <- if null sources then pure [] else O.runSelect c (do
    deposit <- S.accountedLosses
    O.where_ (O.in_ (map O.sqlStrictText sources) deposit)
    pure deposit) :: IO [Text]
  let review=not(null native) || any ((=="review").snd) obligations ||
        any (\deposit->deposit `notElem` accounted || (deposit,"paid") `notElem` obligations) sources
  pure (W.OrderView identifier request savedQuote (if review then "NeedsReview" else S.status r)
    (S.deadline r) visible (S.payoutTx r) policy)
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
      intakeReady c identity now
      require (W.input request>=orderMinimum limits && W.input request<=orderMaximum limits) "amount_outside_limits"
      require (W.sourceOwner request==Nothing && (W.direction request/=WrappedToNative || T.null(W.refund request))) "invalid_connection_free_order"
      let address t=not(T.null t) && T.length t<=128 && not(T.any (<= ' ') t)
      require (address(W.recipient request) && (W.direction request/=NativeToWrapped || address(W.refund request))) "invalid_destination"
      termsQuote <- checked (quote $ W.input request)
      queued <- O.runSelect c $ do
        row <- O.selectTable S.orders
        O.where_ (O.not $ O.in_ (map O.sqlStrictText ["Paid","Refunded","ExpiredUnfunded"]) (S.status row))
        pure (S.orderId row)
        :: IO [Text]
      unpaid <- O.runSelect c $ do
        (_,order,_,state) <- S.orderObligations
        O.where_ (O.not $ O.in_ (map O.sqlStrictText ["paid","cancelled"]) state)
        pure order
        :: IO [Text]
      require (length(nub $ queued<>unpaid)<maximumQueued limits) "queue_full"
      booked <- balances c
      let destination=destinationAsset (W.direction request); name=T.pack(show destination)
      holds <- O.runSelect c $ do
        (_,asset,n,phase) <- O.selectTable S.reservations
        O.where_ (asset O..== O.sqlStrictText name O..&& phase O../= O.sqlStrictText "released")
        pure n
        :: IO [Int64]
      require (M.findWithDefault 0 (destination,Float) booked-sum(map toInteger holds)>=toInteger(units $ net termsQuote)) "insufficient_inventory"
      let end=toInteger now+toInteger(quoteSeconds limits); grace=end+toInteger(graceSeconds limits)
      require (now>=0 && grace<=toInteger(maxBound::Int64)) "invalid_order_time"
      identifier <- digest <$> (getRandomBytes 32 :: IO BS.ByteString)
      let text=O.sqlStrictText; num=O.sqlInt8
          row=S.Order (text identifier) (text cap) (text key) (text requestDigest) (text encoded)
            (text $ encodeSaved termsQuote) (text $ encodeSaved $ paymentPolicy terms) (text "Provisioning")
            (num $ fromInteger end) (num $ fromInteger grace) O.null O.null O.null (num 0)
      _ <- O.runInsert c O.Insert {O.iTable=S.orders,O.iRows=[row],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runInsert c O.Insert {O.iTable=S.reservations,O.iRows=[(text identifier,text name,num $ units $ net termsQuote,text "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      reserveOrderCosts c limits (paymentLimits terms) booked identifier (W.direction request)
      pure identifier

intakeReady :: PG.Connection -> Text -> Int64 -> IO ()
intakeReady c identity now = do
  require (now>=0) "invalid_order_time"
  d <- metadata c identity
  require (S.paused d==0) "intake_paused"
  _<-scanHeads c now
  fresh c now

scanHeads :: PG.Connection -> Int64 -> IO [(Text,Text)]
scanHeads c now = do
  require (now>=0) "invalid_custody_time"
  scans <- O.runSelect c $ do
    (chain,success,problem,_) <- O.selectTable S.scanHealth
    (stream,anchor) <- O.selectTable S.checkpoints
    O.where_ (chain O..== stream)
    pure (chain,success,problem,anchor)
    :: IO [(Text,Maybe Int64,Maybe Text,Text)]
  let ordered=sortOn (\(chain,_,_,_)->chain) scans
  require (map (\(chain,_,_,_)->chain) ordered==["Native","Solana","SolanaOperating"] &&
    all (\(_,at,problem,anchor)->problem==Nothing && not(T.null anchor) &&
      maybe False (\t->t>=0 && t<=now && toInteger now-toInteger t<=60) at) ordered) "scanners_not_fresh"
  pure [(chain,anchor) | (chain,_,_,anchor)<-ordered]

reserveOrderCosts :: PG.Connection -> OrderLimits -> CostLimits -> M.Map (Asset,Account) Integer -> Text -> Direction -> IO ()
reserveOrderCosts c limits costs booked identifier direction = do
  total <- checked $ amount (toInteger(units $ savedSolanaFee costs)+toInteger(units $ savedSolanaRent costs))
  let allowances=[(Native,savedNativeFee costs),(Sol,total)]
  operatingCapacity c limits booked allowances
  let text=O.sqlStrictText; num=O.sqlInt8
  _ <- O.runInsert c O.Insert {O.iTable=S.orderCosts,
    O.iRows=[(text identifier,num $ units $ savedNativeFee costs,num $ units $ savedSolanaFee costs,num $ units $ savedSolanaRent costs)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  forM_ allowances $ \(asset,quantity)->do
    let isConversion=(direction==NativeToWrapped && asset==Sol) || (direction==WrappedToNative && asset==Native)
    _ <- O.runInsert c O.Insert {O.iTable=S.operatingReservations,
      O.iRows=[(text identifier,text $ if isConversion then "conversion" else "refund",text $ T.pack(show asset),num $ units quantity,text "quote")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
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
saveInstruction :: PG.Connection -> S.Order -> Text -> IO Int64
saveInstruction c row instruction = case (S.instruction row,S.instructionSequence row) of
  (Just old,Just n) -> require (old==instruction && n>0) "instruction_is_immutable" >> pure n
  (Nothing,Nothing) -> do
    require (S.status row `elem` ["Provisioning","ExpiredUnfunded"]) "order_no_longer_provisioning"
    n <- nextSequence c
    _ <- O.runUpdate c O.Update {O.uTable=S.orders,
      O.uUpdateWith= \r->r {S.instruction=O.toNullable $ O.sqlStrictText instruction,S.instructionSequence=O.toNullable $ O.sqlInt8 n,
        S.status=O.ifThenElse (S.status r O..== O.sqlStrictText "Provisioning") (O.sqlStrictText "AwaitingDeposit") (S.status r)},
      O.uWhere= \r->S.orderId r O..== O.sqlStrictText(S.orderId row),O.uReturning=O.rCount}
    pure n
  _ -> reject "invalid_instruction_state"
issueInstruction :: PG.Connection -> StorePolicy -> Int64 -> Text -> Text -> IO W.OrderView
issueInstruction c config now header identifier = do
  let identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  row <- authorizedOrder c identity header identifier
  n <- maybe (reject "instruction_not_recorded") pure (S.instructionSequence row)
  require (n>0 && S.instruction row/=Nothing && S.instructionIssued row `elem` [0,1]) "invalid_instruction_state"
  d <- metadata c identity
  require (not(requireBackup config) || S.backupSequence d>=n) "backup_pending"
  cap <- checked (bearerHash header)
  view <- readOrder c identity Nothing cap identifier
  when (S.instructionIssued row==0) $ do
    intakeReady c identity now
    require (W.status view=="AwaitingDeposit" && now<=S.deadline row) "deposit_window_closed"
    held <- O.runSelect c $ do
      (key,_,_,phase) <- O.selectTable S.reservations
      O.where_ (key O..== O.sqlStrictText identifier)
      pure phase
      :: IO [Text]
    costs <- O.runSelect c $ do
      (key,_,_,_,phase) <- O.selectTable S.operatingReservations
      O.where_ (key O..== O.sqlStrictText identifier)
      pure phase
      :: IO [Text]
    require (held==["quote"] && costs==["quote","quote"]) "quote_reservations_unavailable"
    _ <- O.runUpdate c O.Update {O.uTable=S.orders,
      O.uUpdateWith= \r->r {S.instructionIssued=O.sqlInt8 1},O.uWhere= \r->S.orderId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
    audit c "instruction_issued" identifier
  pure view {W.depositInstruction=S.instruction row}
expireQuotes :: PG.Connection -> Int64 -> IO ()
expireQuotes c now = do
  require (now>=0) "invalid_order_time"
  expired <- O.runSelect c $ do
    row <- O.selectTable S.orders
    O.where_ (S.graceDeadline row O..< O.sqlInt8 now)
    pure (S.orderId row)
    :: IO [Text]
  forM_ expired $ \identifier -> do
    _ <- O.runUpdate c O.Update {O.uTable=S.reservations,
      O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlStrictText "released"),
      O.uWhere= \(key,_,_,phase)->key O..== O.sqlStrictText identifier O..&& phase O..== O.sqlStrictText "quote",O.uReturning=O.rCount}
    _ <- O.runUpdate c O.Update {O.uTable=S.operatingReservations,
      O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText "released"),
      O.uWhere= \(key,_,_,_,phase)->key O..== O.sqlStrictText identifier O..&& phase O..== O.sqlStrictText "quote",O.uReturning=O.rCount}
    deposits <- O.runSelect c $ O.limit 1 $ do
      (key,order) <- S.orderDeposits
      O.where_ (O.matchNullable (O.sqlBool False) (O..== O.sqlStrictText identifier) order)
      pure key
      :: IO [Text]
    when (null deposits) $ do
      _ <- O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=O.sqlStrictText "ExpiredUnfunded"},
        O.uWhere= \r->S.orderId r O..== O.sqlStrictText identifier O..&& O.in_ (map O.sqlStrictText ["Provisioning","AwaitingDeposit"]) (S.status r),O.uReturning=O.rCount}
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
    (S.status o O..== O.sqlStrictText "Provisioning" O..|| S.status o O..== O.sqlStrictText "AwaitingDeposit"))
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
      require (W.input request==gross savedQuote && deploymentFingerprint policy==deploymentFingerprint(paymentPolicy terms)) "saved_order_terms_mismatch"
      previous <- O.runSelect c $ do
        obligation <- O.selectTable S.obligations
        O.where_ (S.obligationOrder obligation O..== O.sqlStrictText oid O..&& S.obligationKind obligation O..== O.sqlStrictText "conversion")
        pure (S.obligationId obligation)
        :: IO [Text]
      let exact=S.depositAmount d==units(gross savedQuote) && S.depositAsset d==T.pack(show $ sourceAsset $ W.direction request)
          eligible=S.depositAsset d/="Native" || S.depositDepth d>=fromIntegral(nativeDepth policy)
          timely=S.depositSeen d>=0 && S.depositSeen d<=S.deadline o && now<=S.graceDeadline o
          pending=S.status o `elem` ["Provisioning","AwaitingDeposit"] && S.instruction o/=Nothing
      if not (exact && eligible && timely && pending && null previous) then do
        _ <- O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=O.sqlStrictText "NeedsReview"},
          O.uWhere= \r->S.orderId r O..== O.sqlStrictText oid O..&& S.status r O../= O.sqlStrictText "Paid",O.uReturning=O.rCount}
        pure False
      else do
        holds <- O.runSelect c $ do
          (key,asset,n,phase) <- O.selectTable S.reservations
          O.where_ (key O..== O.sqlStrictText oid)
          pure (asset,n,phase)
          :: IO [(Text,Int64,Text)]
        require (holds==[(T.pack(show $ destinationAsset $ W.direction request),units(net savedQuote),"quote")]) "reservation_not_provisional"
        costs <- O.runSelect c $ do
          (key,nativeFee,solFee,rent) <- O.selectTable S.orderCosts
          O.where_ (key O..== O.sqlStrictText oid)
          pure (nativeFee,solFee,rent)
          :: IO [(Int64,Int64,Int64)]
        (nativeFee,solFee,rent) <- case costs of [one]->pure one; _->reject "missing_order_cost_policy"
        solTotal <- checked (amount $ toInteger solFee+toInteger rent)
        require (nativeFee>0 && solFee>0 && rent>=0) "invalid_order_cost_policy"
        allowances <- O.runSelect c $ do
          (key,kind,asset,n,phase) <- O.selectTable S.operatingReservations
          O.where_ (key O..== O.sqlStrictText oid)
          pure (kind,asset,n,phase)
          :: IO [(Text,Text,Int64,Text)]
        let nativeKind=if W.direction request==NativeToWrapped then "refund" else "conversion"
            solKind=if W.direction request==NativeToWrapped then "conversion" else "refund"
        require (sortOn id allowances==sortOn id [(nativeKind,"Native",nativeFee,"quote"),(solKind,"Sol",units solTotal,"quote")]) "operating_reservation_not_provisional"
        _ <- O.runInsert c O.Insert {O.iTable=S.obligations,
          O.iRows=[S.Obligation (O.sqlStrictText $ "convert:"<>oid) (O.sqlStrictText oid) (O.sqlStrictText identifier)
            (O.sqlStrictText "conversion") (O.sqlStrictText $ T.pack $ show $ destinationAsset $ W.direction request)
            (O.sqlInt8 $ units $ net savedQuote) (O.sqlStrictText $ W.recipient request) (O.sqlStrictText "ready")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        _ <- O.runUpdate c O.Update {O.uTable=S.deposits,O.uUpdateWith= \r->r {S.depositAllocated=O.sqlInt8 1},
          O.uWhere= \r->S.depositId r O..== O.sqlStrictText identifier,O.uReturning=O.rCount}
        _ <- O.runUpdate c O.Update {O.uTable=S.reservations,
          O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlStrictText "obligation"),
          O.uWhere= \(key,_,_,_)->key O..== O.sqlStrictText oid,O.uReturning=O.rCount}
        _ <- O.runUpdate c O.Update {O.uTable=S.operatingReservations,
          O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,O.sqlStrictText "obligation"),
          O.uWhere= \(key,_,_,_,phase)->key O..== O.sqlStrictText oid O..&& phase O..== O.sqlStrictText "quote",O.uReturning=O.rCount}
        _ <- O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=O.sqlStrictText "Ready"},
          O.uWhere= \r->S.orderId r O..== O.sqlStrictText oid,O.uReturning=O.rCount}
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
      eligible=S.depositEligible source==1
  asset <- parseAsset (S.depositAsset source)
  history <- O.runSelect c $ O.limit 1 $ O.orderBy (O.desc (\(key,_,_,_,_,_)->key)) $ do
    row@(_,deposit,_,_,_,_) <- O.selectTable S.sourceChecks
    O.where_ (deposit O..== O.sqlStrictText did)
    pure row
    :: IO [(Int64,Text,Text,Int64,Text,Int64)]
  let old=case history of [(_,_,state,loss,savedProof,_)]->Just(state,loss,savedProof); _->Nothing
      previousLoss=maybe 0 (\(_,n,_)->n) old
      proof=sourceProof check
      evidence=encodeSaved proof
  (state,loss) <- case check of
    W.SourcePending _->require (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure ("pending",0)
    W.SourceMissing _->require (not eligible && asset==Native) "source_recovery_scan_not_current" >> pure ("missing",S.depositAmount source)
    W.SourceRestored _->require eligible "source_recovery_scan_not_current" >> pure ("restored",0)
    W.SourceUnavailable _->pure ("unavailable",previousLoss)
  require (proof/=Null && T.length evidence<=16384) "invalid_source_recovery_evidence"
  let ordinary=old==Nothing && S.depositAllocated source==0 && state=="pending"
      unchanged=maybe False (\(s,n,p)->s==state && n==loss && (state/="unavailable" || p==evidence)) old
  unless (ordinary || unchanged) $ do
    sequenceNo <- nextSequence c
    _ <- O.runInsert c O.Insert {O.iTable=S.sourceChecks,
      O.iRows=[(Nothing,O.sqlStrictText did,O.sqlStrictText state,O.sqlInt8 loss,O.sqlStrictText evidence,O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
    let delta=toInteger loss-toInteger previousLoss
    when (delta/=0) $ post c ("source-recovery:"<>T.pack(show sequenceNo)) "change in verified missing source value"
      [Posting asset SourceDeficit (negate delta),Posting asset External delta]
    when (delta<0) $ do
      covers <- O.runSelect c $ do
        (key,deposit,n,capital,earned) <- S.activeSourceCovers
        O.where_ (deposit O..== O.sqlStrictText did)
        pure (key,n,capital,earned)
        :: IO [(Int64,Int64,Int64,Int64)]
      forM_ covers $ \(covered,n,capital,earned)->do
        require (toInteger n==negate delta) "source_loss_return_mismatch"
        _ <- O.runInsert c O.Insert {O.iTable=S.sourceReturns,O.iRows=[(O.sqlInt8 covered,O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        post c ("source-loss-return:"<>T.pack(show covered)) "restored source returns its operator loss allocation"
          [Posting asset Float (toInteger capital),Posting asset Earned (toInteger earned),Posting asset SourceDeficit (negate $ toInteger n)]
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
    (key,chain,resolved,common) <- S.workIntents
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

scanAssets :: [(Text,Asset)]
scanAssets=[("Native",Native),("Solana",Wrapped),("SolanaOperating",Sol)]
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
      require (S.depositOrder previous==oid && S.depositAsset previous==T.pack(show currency) && S.depositAmount previous==units quantity) "conflicting_deposit_evidence"
      _ <- O.runUpdate c O.Update {O.uTable=S.deposits,
        O.uUpdateWith= \r->r {S.depositAnchor=text anchor,S.depositDepth=num $ fromIntegral depth,S.depositEligible=num bit},
        O.uWhere= \r->S.depositId r O..== text did,O.uReturning=O.rCount}
      current <- readSource c did
      when (S.depositEligible previous==1 && not eligible) $ do
        reviewed <- O.runSelect c $ do
          row <- O.selectTable S.obligations
          O.where_ (S.obligationDeposit row O..== text did O..&& O.in_ (map text ["ready","paying"]) (S.obligationStatus row))
          pure (S.obligationId row,S.obligationStatus row)
          :: IO [(Text,Text)]
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
        when (null covered) $ do
          pauseScan c "source_reorg_review"
          _ <- O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text "review"},
            O.uWhere= \r->S.obligationDeposit r O..== text did O..&& O.not (O.in_ (map text ["paid","cancelled"]) (S.obligationStatus r)),O.uReturning=O.rCount}
          pure ()
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
  pauseScan c ("scanner_unavailable:"<>chain)

commitScan :: PG.Connection -> W.ScanBatch -> IO ()
commitScan c batch = do
  let chain=W.scanChain batch; now=W.scanTime batch; origin=W.scanOrigin batch; next=W.scanNext batch
      deposits=W.scanDeposits batch; events=W.scanEvents batch; text=O.sqlStrictText; num=O.sqlInt8
  require (chain `elem` map fst scanAssets && now>=0 && length deposits<=1000 && length events<=1000) "invalid_scan_batch"
  require (all (\anchor->not(T.null anchor) && T.length anchor<=128) [origin,next]) "invalid_scan_anchor"
  require (all (\d->Just(W.depositAsset d)==lookup chain scanAssets) deposits) "scan_asset_mismatch"
  previous <- readCheckpoint c chain
  require (previous==W.scanPrevious batch) "stale_scan_cursor"
  origins <- O.runSelect c $ do
    (key,anchor) <- O.selectTable S.scanOrigins
    O.where_ (key O..== text chain)
    pure anchor
    :: IO [Text]
  case origins of
    []->O.runInsert c O.Insert {O.iTable=S.scanOrigins,O.iRows=[(text chain,text origin)],O.iReturning=O.rCount,O.iOnConflict=Nothing} >> pure ()
    [saved]->require (saved==origin) "scan_origin_mismatch"
    _->reject "duplicate_scan_origin"
  mapM_ (observeDeposit c) deposits
  forM_ events $ \event->do
    let identifier=W.chainEventId event; anchor=W.chainEventAnchor event; kind=W.chainEventKind event
        proof=W.chainEventEvidence event
        evidence=encodeSaved $ object ["chain" .= chain,"id" .= identifier,"anchor" .= anchor,"kind" .= kind,"proof" .= proof]
        hash=digest (TE.encodeUtf8 evidence)
        paymentChain=if chain=="SolanaOperating" then "Solana" else chain
    require (not(T.null identifier) && T.length identifier<=128 && T.length anchor<=128) "invalid_observation_identity"
    require (kind `elem` ["incoming","unmatched_incoming","outgoing","failed","reference","unsupported","unclassified","awaiting_verifier","disputed"]) "invalid_observation_kind"
    require (T.length evidence<=8192) "observation_evidence_too_large"
    attempts <- O.runSelect c $ do
      (tx,intent,state,_,sequenceNo,observation) <- S.workAttempts
      (key,currency,_,_) <- S.workIntents
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
    let known=any (\(state,sequenceNo,observation)->state `elem` ["broadcast_intent","settled","failed"] ||
          state=="review" && paymentChain=="Native" && maybe False (>0) sequenceNo && maybe False (`elem` formerWinners) observation) attempts
        approved=case W.economicOutflow chain proof of Right economic->treasury==[(anchor,encodeSaved economic)]; Left _->False
        review=kind `elem` ["unsupported","unclassified","disputed"] || kind=="outgoing" && not known && not approved
        bit=if review then 1 else 0
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
      state <- case S.obligationStatus ob of
        "ready"->pure PaymentReady; "paying"->pure PaymentPaying; "paid"->pure PaymentPaid
        "review"->pure PaymentReview; "cancelled"->pure PaymentCancelled
        _->reject "unknown_payment_status"
      pure (PaymentView outgoing (PaymentTerms policy costs) state)
    ([],Just saved) -> do
      work <- O.runSelect c $ do
        row <- O.selectTable S.intents
        O.where_ (S.intentId row O..== O.sqlStrictText identifier)
        pure (S.intentObligation row,S.intentWithdrawal row,S.intentResolved row)
        :: IO [(Maybe Text,Maybe Text,Int64)]
      state <- case (withdrawalCancellation saved,work) of
        (Just _,[])->pure PaymentCancelled
        (Just _,[(Nothing,Just key,1)]) | identifier=="fee:"<>key->do
          retry<-cancelledGeneration c identifier
          require (retry/=Nothing) "payment_funding_mismatch"
          pure PaymentCancelled
        (Nothing,[])->pure PaymentReady
        (Nothing,[(Nothing,Just key,0)]) | identifier=="fee:"<>key->pure PaymentPaying
        (Nothing,[(Nothing,Just key,1)]) | identifier=="fee:"<>key->do
          winners <- O.runSelect c $ do
            (tx,intent,status,_,_,_) <- S.workAttempts
            O.where_ (intent O..== O.sqlStrictText identifier O..&& status O..== O.sqlStrictText "settled")
            pure tx
            :: IO [Text]
          retry<-retryGeneration c identifier
          pure (if length winners==1 then PaymentPaid else if maybe False (<8) retry then PaymentReady else PaymentReview)
        _->reject "payment_funding_mismatch"
      pure (PaymentView (withdrawalPayment saved) (withdrawalTerms saved) state)
    ([],Nothing)->reject "payment_not_found"
    _->reject "ambiguous_payment_funding"
  require (deploymentFingerprint (paymentPolicy $ savedTerms result)==identity) "payment_profile_mismatch"
  pure result
 where quantity=checked . amount . toInteger

operatingCapacity :: PG.Connection -> OrderLimits -> M.Map (Asset,Account) Integer -> [(Asset,Amount)] -> IO ()
operatingCapacity c limits booked allowances = do
  wallTime <- floor <$> getPOSIXTime
  times <- O.runUpdate c O.Update {O.uTable=S.operatingClock,
    O.uUpdateWith= \(key,old)->(key,O.ifThenElse (old O..> O.sqlInt8 wallTime) old (O.sqlInt8 wallTime)),
    O.uWhere= \(key,_)->key O..== O.sqlInt8 1,O.uReturning=O.rReturning snd}
  now <- case times of [t]->pure t; _->reject "operating_clock_missing"
  forM_ allowances $ \(asset,quantity)->do
    let daily=if asset==Native then nativeDaily limits else solanaDaily limits
    let name=T.pack(show asset)
    held<-operatingHolds c asset
    spending <- O.runSelect c $ do
      (posting,_,currency,_,delta) <- O.selectTable S.postings
      (cost,at) <- O.selectTable S.operatingCosts
      O.where_ (posting O..== cost O..&& currency O..== O.sqlStrictText name O..&& at O..> O.sqlInt8 (now-86400))
      pure delta
      :: IO [Int64]
    let needed=toInteger(units quantity)
    require (M.findWithDefault 0 (asset,Operating) booked-held>=needed) "insufficient_fee_budget"
    require (negate(sum(map toInteger spending))+held+needed<=toInteger(units daily)) "operating_daily_limit"

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
    intent <- O.selectTable S.intents
    (key,generation,policy,draft,retired,cancelled) <- O.selectTable S.preparations
    (feeKey,asset,n,released) <- O.selectTable S.feeHolds
    O.where_ (S.intentId intent O..== O.sqlStrictText identifier O..&& key O..== S.intentId intent O..&& feeKey O..== key
      O..&& S.intentResolved intent O..== O.sqlInt8 0 O..&& O.isNull retired O..&& cancelled O..== O.sqlInt8 0 O..&& released O..== O.sqlInt8 0)
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
  view <- readPayment c identity identifier
  let outgoing=savedPayment view; funding=paymentFunding outgoing; chain=if paymentAsset outgoing==Native then "Native" else "Solana"
      feeAsset=if chain=="Native" then Native else Sol; costs=paymentLimits $ savedTerms view
      bound=if feeAsset==Native then toInteger(units $ savedNativeFee costs) else toInteger(units $ savedSolanaFee costs)+toInteger(units $ savedSolanaRent costs)
  require (units allowance>0 && toInteger(units allowance)<=bound) "order_fee_limit_exceeded"
  existing <- O.runSelect c $ do
    intent <- O.selectTable S.intents
    O.where_ (S.intentId intent O..== text identifier)
    pure intent
    :: IO [S.Intent]
  let resolved=case existing of [i]->S.intentResolved i==1 && S.intentChain i==chain; _->False
  case existing of
    [intent] | S.intentResolved intent==0 -> do
      saved <- readPreparation c identity identifier
      require (preparedPolicy saved==plan && preparedFee saved==allowance && S.intentChain intent==chain) "preparation_conflict"
      pure saved
    previous | null previous || resolved -> do
      generation<-if null previous then pure 0 else retryGeneration c identifier >>= maybe (reject "preparation_retry_not_authorized") pure
      require (generation<8) "preparation_generation_limit"
      intakeReady c identity now
      require (savedStatus view==PaymentReady) "payment_not_ready"
      busy <- O.runSelect c $ O.limit 1 $ do
        intent <- O.selectTable S.intents
        O.where_ (S.intentChain intent O..== text chain O..&& S.intentResolved intent O..== num 0)
        pure (S.intentId intent)
        :: IO [Text]
      require (null busy) "destination_payment_unresolved"
      unless (null previous) $ do
        paymentSource c outgoing
        fees<-O.runSelect c $ do
          (key,asset,n,released)<-O.selectTable S.feeHolds
          (p,g,_,_,retired,_)<-S.workPreparations
          O.where_ (key O..== text identifier O..&& p O..== key O..&& g O..== num(fromIntegral generation-1))
          pure(asset,n,released,retired)
          :: IO [(Text,Int64,Int64,Maybe Text)]
        require (case fees of [(asset,n,released,retired)]->asset==T.pack(show feeAsset) && n>0 && released==(if retired==Nothing then 0 else 1); _->False) "preparation_fee_hold_missing"
        _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,a,n,_)->(key,a,n,num 1),O.uWhere= \(key,_,_,_)->key O..== text identifier,O.uReturning=O.rCount}
        pure ()
      booked <- balances c
      (obligation,withdrawal) <- case funding of
        EarnedFees key asset n -> do
          require (M.findWithDefault 0 (asset,FeePending) booked>=toInteger(units n)) "earned_reservation_missing"
          pure (Nothing,Just key)
        Conversion oid receipt _ _ -> when (null previous) (transfer oid receipt "conversion" feeAsset) >> pure (Just identifier,Nothing)
        Refund oid receipt _ _ -> when (null previous) (transfer oid receipt "refund" feeAsset) >> pure (Just identifier,Nothing)
      operatingCapacity c (admissionLimits config) booked [(feeAsset,allowance)]
      _ <- nextSequence c
      if null previous then do
        _<-O.runInsert c O.Insert {O.iTable=S.intents,O.iRows=[S.Intent (text identifier) (nullable obligation) (nullable withdrawal) (text chain) O.null (num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        _<-O.runInsert c O.Insert {O.iTable=S.feeHolds,O.iRows=[(text identifier,text $ T.pack(show feeAsset),num $ units allowance,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
        pure ()
      else do
        _<-O.runUpdate c O.Update {O.uTable=S.intents,O.uUpdateWith= \r->r {S.intentResolved=num 0,S.intentCommon=O.null},O.uWhere= \r->S.intentId r O..== text identifier,O.uReturning=O.rCount}
        _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,a,_,_)->(key,a,num $ units allowance,num 0),O.uWhere= \(key,_,_,_)->key O..== text identifier,O.uReturning=O.rCount}
        pure ()
      _<-O.runInsert c O.Insert {O.iTable=S.preparations,O.iRows=[(text identifier,num(fromIntegral generation),text plan,O.null,O.null,num 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      forM_ obligation $ \key -> do
        _ <- O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text "paying"},O.uWhere= \r->S.obligationId r O..== text key,O.uReturning=O.rCount}
        let oid=case funding of Conversion order _ _ _->order; Refund order _ _ _->order; EarnedFees{}->""
        _ <- O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(order,asset,n,phase)->(order,asset,n,O.ifThenElse (phase O..== text "obligation") (text "payment") phase),O.uWhere= \(order,_,_,_)->order O..== text oid,O.uReturning=O.rCount}
        _ <- O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=text "Preparing"},O.uWhere= \r->S.orderId r O..== text oid,O.uReturning=O.rCount}
        pure ()
      readPreparation c identity identifier
    _ -> reject "preparation_retry_requires_recovery"
 where
  nullable=maybe O.null (O.toNullable . O.sqlStrictText)
  transfer oid receipt kind currency = do
    sourceAuthorized c identifier receipt >>= \authorized->require authorized "source_not_eligible"
    count <- O.runUpdate c O.Update {O.uTable=S.operatingReservations,
      O.uUpdateWith= \(order,purpose,asset,n,_)->(order,purpose,asset,n,O.sqlStrictText "transferred"),
      O.uWhere= \(order,purpose,asset,n,phase)->order O..== O.sqlStrictText oid O..&& purpose O..== O.sqlStrictText kind O..&& asset O..== O.sqlStrictText(T.pack $ show currency) O..&& n O..>= O.sqlInt8(units allowance) O..&& O.in_ (map O.sqlStrictText ["quote","obligation"]) phase,O.uReturning=O.rCount}
    require (count==1) "operating_reservation_missing"

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
    intent <- O.selectTable S.intents
    O.where_ (S.attemptId attempt O..== O.sqlStrictText identifier O..&& S.attemptIntent attempt O..== S.intentId intent)
    pure (attempt,S.intentChain intent,S.intentCommon intent)
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
  require (savedStatus(preparedView prepared)==PaymentPaying && preparedDraft prepared/=Nothing) "payment_not_prepared"
  attempts <- O.runSelect c $ O.limit 1 $ do
    (tx,intent,_,g,_,_) <- S.workAttempts
    O.where_ (intent O..== O.sqlStrictText identifier O..&& g O..== O.sqlInt8(fromIntegral generation))
    pure tx
    :: IO [Text]
  require (null attempts) "attempt_already_recorded"
  paymentSource c (savedPayment $ preparedView prepared)
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
      _ <- O.runUpdate c O.Update {O.uTable=S.intents,
        O.uUpdateWith= \r->r {S.intentCommon=maybe O.null (O.toNullable . text) (commonInput signed)},
        O.uWhere= \r->S.intentId r O..== text identifier,O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=S.attempts,
        O.iRows=[S.Attempt (text $ signedId signed) (text identifier) (text $ signedBytes signed) (text $ signedPolicy signed)
          (num $ units $ preparedFee current) (text "signed") O.null O.null (num $ fromIntegral generation)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      let funding=paymentFunding(savedPayment $ preparedView current)
          order=case funding of Conversion oid _ _ _->Just oid; Refund oid _ _ _->Just oid; EarnedFees{}->Nothing
      forM_ order $ \oid->do
        _ <- O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=text "Paying"},O.uWhere= \r->S.orderId r O..== text oid,O.uReturning=O.rCount}
        pure ()
      readAttempt c (signedId signed)
    _ -> reject "duplicate_attempt"

paymentWork :: PG.Connection -> Text -> Text -> IO (PaymentView,Maybe PreparedPayment,[Text])
paymentWork c identity identifier = do
  view <- readPayment c identity identifier
  active <- O.runSelect c $ do
    row <- O.selectTable S.intents
    O.where_ (S.intentId row O..== O.sqlStrictText identifier O..&& S.intentResolved row O..== O.sqlInt8 0)
    pure (S.intentId row)
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
paymentSource c outgoing = case paymentFunding outgoing of
  EarnedFees{}->pure ()
  Conversion _ receipt _ _->eligible receipt
  Refund _ receipt _ _->eligible receipt
 where eligible receipt=sourceAuthorized c (paymentId outgoing) receipt >>= \authorized->require authorized "source_not_eligible"

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
  saved<-readAttempt c txid
  prepared<-readPreparation c identity (recordedPayment saved)
  require (savedStatus(preparedView prepared)==PaymentPaying && recordedGeneration saved==preparedGeneration prepared
    && recordedFee saved==preparedFee prepared) "payment_not_sendable"
  paymentSource c (savedPayment $ preparedView prepared)
  when (recordedChain saved=="Native") $ do
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
    require (latest==Just txid) "native_replacement_not_current"
    require (all (\(n,parent,_,_,_,_)->parent `notElem` family || any (\(d,_,_)->d==n) (members<>cancelled)) drafts) "native_replacement_draft_pending"
  pure saved

broadcastCoverage :: PG.Connection -> RecordedAttempt -> IO Int64
broadcastCoverage c saved = do
  original<-maybe (reject "broadcast_intent_required") pure (recordedSequence saved)
  approvals<-O.runSelect c $ do
    (identifier,n)<-S.sourceApprovals
    O.where_ (identifier O..== O.sqlStrictText(recordedPayment saved))
    pure n
    :: IO [Int64]
  cancellations<-O.runSelect c $ do
    (decision,_,sequenceNo)<-S.replacementCancellations
    (n,parent,_,_,_,_)<-S.replacementDrafts
    (tx,intent,_,_,_,_)<-S.workAttempts
    O.where_ (decision O..== n O..&& parent O..== tx O..&& intent O..== O.sqlStrictText(recordedPayment saved))
    pure sequenceNo
    :: IO [Int64]
  pure (maximum $ original:approvals<>cancellations)

markBroadcast :: PG.Connection -> StorePolicy -> Int64 -> Text -> IO Int64
markBroadcast c config now txid = do
  let identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  intakeReady c identity now
  saved<-sendContext c identity txid
  case (recordedState saved,recordedSequence saved) of
    ("broadcast_intent",Just _)->broadcastCoverage c saved
    ("signed",Nothing)->do
      n<-nextSequence c
      _<-O.runUpdate c O.Update {O.uTable=S.attempts,
        O.uUpdateWith= \r->r {S.attemptState=O.sqlStrictText "broadcast_intent",S.attemptSequence=O.toNullable $ O.sqlInt8 n},
        O.uWhere= \r->S.attemptId r O..== O.sqlStrictText txid,O.uReturning=O.rCount}
      pure n
    _->reject "attempt_not_sendable"

authorizeSend :: PG.Connection -> StorePolicy -> Int64 -> Text -> IO RecordedAttempt
authorizeSend c config now txid = do
  let identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  intakeReady c identity now
  saved<-sendContext c identity txid
  require (recordedState saved=="broadcast_intent") "broadcast_intent_required"
  needed<-broadcastCoverage c saved
  row<-metadata c identity
  require (not(requireBackup config) || S.backupSequence row>=needed) "backup_pending"
  pure saved

-- Settlement accepts only an independently verified outcome for the exact saved
-- attempt. Pausing/source loss does not erase an already finalized liability.
settlePayment :: PG.Connection -> Text -> RecordedAttempt -> W.PaymentCosts -> Text -> IO ()
settlePayment c identity expected costs proof = do
  let txid=signedId(recordedSigned expected)
      saved=encodeSaved $ object ["costs" .= costs,"proof" .= proof]
      actual=toInteger(units $ W.networkFee costs)+toInteger(units $ W.accountRent costs)
  require (not(T.null proof) && T.length proof<=32768 && units(W.networkFee costs)>0
    && actual<=toInteger(units $ recordedFee expected)
    && (recordedChain expected=="Solana" || units(W.accountRent costs)==0)) "settlement_fee_or_evidence_invalid"
  (current,view)<-settlementContext c identity expected "settled" saved
  unless (recordedState current=="settled") $ do
    post c ("settlement:"<>txid) "successful finalized payout" (settlement $ savedPayment view)
    forM_ [("network-fee",W.networkFee costs),("account-rent",W.accountRent costs)] $ \(label,cost)->
      when (units cost>0) $ paymentCost c current (label<>":"<>txid) label cost
    resolvePayment c current view "settled" saved

failSolana :: PG.Connection -> Text -> RecordedAttempt -> Amount -> Text -> IO ()
failSolana c identity expected fee proof = do
  require (recordedChain expected=="Solana" && units fee>0 && fee<=recordedFee expected
    && not(T.null proof) && T.length proof<=32768) "invalid_failure_evidence"
  let txid=signedId(recordedSigned expected)
  (current,view)<-settlementContext c identity expected "failed" proof
  if recordedState current=="failed" then do
    charged<-O.runSelect c $ do
      (_,event,_,account,n)<-O.selectTable S.postings
      O.where_ (event O..== O.sqlStrictText("failed-fee:"<>txid) O..&& account O..== O.sqlStrictText "external")
      pure n
      :: IO [Int64]
    require (charged==[units fee]) "failure_evidence_conflict"
  else do
    paymentCost c current ("failed-fee:"<>txid) "finalized Solana failure network fee" fee
    resolvePayment c current view "failed" proof

settlementContext :: PG.Connection -> Text -> RecordedAttempt -> Text -> Text -> IO (RecordedAttempt,PaymentView)
settlementContext c identity expected state proof = do
  current<-readAttempt c (signedId $ recordedSigned expected)
  require (recordedState expected=="broadcast_intent" && recordedSequence expected/=Nothing
    && current {recordedState=recordedState expected,recordedObservation=recordedObservation expected}==expected) "settlement_attempt_changed"
  view<-readPayment c identity (recordedPayment current)
  if recordedState current==state then require (recordedObservation current==Just proof) "settlement_evidence_conflict"
  else do
    require (current==expected && savedStatus view `elem` [PaymentPaying,PaymentReview]) "settlement_not_expected"
    rows<-O.runSelect c $ do
      intent<-O.selectTable S.intents
      (key,currency,n,released)<-O.selectTable S.feeHolds
      O.where_ (S.intentId intent O..== O.sqlStrictText(recordedPayment current) O..&& key O..== S.intentId intent)
      pure (S.intentResolved intent,currency,n,released)
      :: IO [(Int64,Text,Int64,Int64)]
    let asset=if recordedChain current=="Native" then "Native" else "Sol"
    require (case rows of [(0,currency,n,0)]->currency==asset && n>=units(recordedFee current); _->False) "payment_intent_not_settleable"
    winners<-O.runSelect c $ do
      r<-O.selectTable S.attempts
      O.where_ (S.attemptIntent r O..== O.sqlStrictText(recordedPayment current) O..&& S.attemptState r O..== O.sqlStrictText "settled")
      pure (S.attemptId r)
      :: IO [Text]
    require (null winners) "payment_already_settled"
  pure (current,view)

paymentCost :: PG.Connection -> RecordedAttempt -> Text -> Text -> Amount -> IO ()
paymentCost c saved event explanation quantity =
  let asset=if recordedChain saved=="Native" then Native else Sol; n=toInteger(units quantity)
  in post c event explanation [Posting asset Operating (-n),Posting asset External n]

resolvePayment :: PG.Connection -> RecordedAttempt -> PaymentView -> Text -> Text -> IO ()
resolvePayment c saved view state proof = do
  let text=O.sqlStrictText; identifier=recordedPayment saved; paid=state=="settled"
  _<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text state,S.attemptObservation=O.toNullable $ text proof},O.uWhere= \r->S.attemptId r O..== text(signedId $ recordedSigned saved),O.uReturning=O.rCount}
  _<-O.runUpdate c O.Update {O.uTable=S.intents,O.uUpdateWith= \r->r {S.intentResolved=O.sqlInt8 1},O.uWhere= \r->S.intentId r O..== text identifier,O.uReturning=O.rCount}
  _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,O.sqlInt8 1),O.uWhere= \(key,_,_,_)->key O..== text identifier,O.uReturning=O.rCount}
  let customer=case paymentFunding(savedPayment view) of Conversion order _ _ _->Just(order,False); Refund order _ _ _->Just(order,True); EarnedFees{}->Nothing
  forM_ customer $ \(order,isRefund)->do
    _<-O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text $ if paid then "paid" else "review"},O.uWhere= \r->S.obligationId r O..== text identifier,O.uReturning=O.rCount}
    _<-O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=text $ if not paid then "NeedsReview" else if isRefund then "Refunded" else "Paid",S.payoutTx=if paid then O.toNullable(text $ signedId $ recordedSigned saved) else S.payoutTx r},O.uWhere= \r->S.orderId r O..== text order O..&& (O.sqlBool(not isRefund) O..|| S.status r O../= text "Paid"),O.uReturning=O.rCount}
    when paid $ do
      _<-O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,text "released"),O.uWhere= \(key,_,_,_)->key O..== text order,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.operatingReservations,O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,text "released"),O.uWhere= \(key,_,_,_,phase)->key O..== text order O..&& O.in_ (map text ["quote","obligation"]) phase,O.uReturning=O.rCount}
      pure ()

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
    i<-O.selectTable S.intents
    O.where_ (S.attemptIntent a O..== S.intentId i O..&& S.intentResolved i O..== O.sqlInt8 0)
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
    intent<-O.selectTable S.intents
    O.where_ (S.attemptIntent row O..== S.intentId intent O..&& S.intentResolved intent O..== O.sqlInt8 0)
    O.where_ (O.in_ (map O.sqlStrictText ["signed","broadcast_intent"]) (S.attemptState row))
    pure (S.attemptId row)
  require (length rows<=1000) "pending_attempts_too_large"
  pure rows

-- Prefer the existing intent on each chain; never prepare a competing payment.
-- Resolved intents return only after cancellation or approved expiry; settled history and
-- cancelled withdrawals cannot fill the bounded queue. Candidates are revalidated.
paymentCandidates :: PG.Connection -> IO [Text]
paymentCandidates c = do
  active<-O.runSelect c $ O.limit 1001 $ do
    row<-O.selectTable S.intents
    O.where_ (S.intentResolved row O..== O.sqlInt8 0)
    pure (S.intentId row,S.intentChain row)
    :: IO [(Text,Text)]
  let absent identifier=do
        found<-Exists.exists $ do
          row<-O.selectTable S.intents
          O.where_ (S.intentId row O..== identifier)
          pure ()
        retry<-Exists.exists $ do
          row<-O.selectTable S.intents
          (key,g,_,_,retired,cancelled)<-S.workPreparations
          O.where_ (S.intentId row O..== identifier O..&& S.intentResolved row O..== O.sqlInt8 1
            O..&& key O..== identifier O..&& g O..< O.sqlInt8 7)
          cancelledWork<-Exists.exists $ do
            (other,generation,_,_,done)<-S.workCancellations
            O.where_ (other O..== key O..&& generation O..== g O..&& done O..== O.sqlInt8 1 O..&& cancelled O..== O.sqlInt8 1 O..&& O.isNull retired)
            pure ()
          expiredWork<-Exists.exists $ do
            (tx,_,_,_)<-O.selectTable S.solanaRetryApprovals
            O.where_ (O.matchNullable (O.sqlBool False) (O..== tx) retired O..&& cancelled O..== O.sqlInt8 0)
            pure ()
          later<-Exists.exists $ do
            (other,generation,_,_,_,_)<-S.workPreparations
            O.where_ (other O..== key O..&& generation O..> g)
            pure ()
          pending<-Exists.exists $ do
            (tx,other,_,_,_,_)<-S.workAttempts
            expired<-Exists.exists $ do
              (retiredId,_,_)<-O.selectTable S.solanaExpiries
              O.where_ (retiredId O..== tx)
              pure ()
            O.where_ (other O..== key O..&& O.not expired)
            pure ()
          O.where_ ((cancelledWork O..|| expiredWork) O..&& O.not later O..&& O.not pending)
          pure ()
        O.where_ (O.not found O..|| retry)
      orders=do
        row<-O.selectTable S.obligations
        O.where_ (S.obligationStatus row O..== O.sqlStrictText "ready")
        absent (S.obligationId row)
        pure (S.obligationId row,S.obligationAsset row)
      fees=do
        row<-O.selectTable S.withdrawals
        let identifier=O.sqlStrictText "fee:" O..++ S.withdrawalId row
        absent identifier
        cancelled<-Exists.exists $ do
          (key,_,_)<-O.selectTable S.cancellations
          O.where_ (key O..== S.withdrawalId row)
          pure ()
        O.where_ (O.not cancelled)
        pure (identifier,S.asset row)
  ready<-O.runSelect c $ O.limit 1001 $ O.orderBy (O.asc fst) $ O.unionAll orders fees
    :: IO [(Text,Text)]
  require (length ready<=1000 && length active<=2
    && all ((`elem` ["Native","Solana"]).snd) active
    && length(nub $ map snd active)==length active
    && all ((`elem` ["Native","Wrapped"]).snd) ready) "payment_queue_requires_review"
  let waiting=[(key,if asset=="Native" then "Native" else "Solana")|(key,asset)<-ready]
  pure [key|chain<-["Native","Solana"],key<-take 1 ([i|(i,currency)<-active,currency==chain]<>[i|(i,currency)<-waiting,currency==chain])]

-- Saved native work only: no source/payment authorization is granted by this read.
nativeLockWork :: PG.Connection -> Text -> IO (Maybe NativeLockWork)
nativeLockWork c identity = do
  active<-O.runSelect c $ O.limit 2 $ do
    row<-O.selectTable S.intents
    O.where_ (S.intentChain row O..== O.sqlStrictText "Native" O..&& S.intentResolved row O..== O.sqlInt8 0)
    pure (S.intentId row)
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
    row<-O.selectTable S.intents
    O.where_ (S.intentResolved row O..== O.sqlInt8 0)
    pure (S.intentId row)
  require (all (`elem` map recordedPayment reviewed) unresolved) "unresolved_intents_require_review"
  problems<-O.runSelect c $ O.limit 1 $ do
    row<-O.selectTable S.obligations
    O.where_ (S.obligationStatus row O..== O.sqlStrictText "review")
    pure (S.obligationId row)
    :: IO [Text]
  require (null problems) "obligations_require_review"
  legacy<-O.runSelect c $ O.limit 1 $ do
    row<-O.selectTable S.orders
    costs<-Exists.exists $ do
      (key,_,_,_)<-O.selectTable S.orderCosts
      O.where_ (key O..== S.orderId row)
      pure ()
    unpaid<-Exists.exists $ do
      ob<-O.selectTable S.obligations
      O.where_ (S.obligationOrder ob O..== S.orderId row
        O..&& O.not(O.in_ (map O.sqlStrictText ["paid","cancelled"]) (S.obligationStatus ob)))
      pure ()
    O.where_ (O.not costs O..&& (unpaid O..|| O.not(O.in_ (map O.sqlStrictText ["Paid","Refunded","ExpiredUnfunded"]) (S.status row))))
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
      state<-metadata c identity
      require (S.paused state==1) "pause_before_operator_action"
      fresh c now
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
      require (deploymentFingerprint policy==identity && S.depositAsset d==T.pack(show $ sourceAsset $ W.direction request)) "unsupported_refund_asset"
      require (not native || S.depositDepth d>=fromIntegral(nativeDepth policy)) "source_not_eligible"
      allowance<-checked $ amount $ if native then toInteger nativeFee else toInteger solFee+toInteger rent
      require (nativeFee>0 && solFee>0 && rent>=0) "invalid_order_cost_policy"
      unresolved<-O.runSelect c $ do
        i<-O.selectTable S.intents
        ob<-O.selectTable S.obligations
        O.where_ (O.matchNullable (O.sqlBool False) (O..== S.obligationId ob) (S.intentObligation i) O..&& S.obligationOrder ob O..== text oid O..&& S.intentResolved i O..== num 0)
        pure (S.intentId i)
        :: IO [Text]
      require (null unresolved) "refund_would_race_payment"
      obligations<-O.runSelect c $ do
        ob<-O.selectTable S.obligations
        O.where_ (S.obligationOrder ob O..== text oid O..&& S.obligationStatus ob O../= text "cancelled")
        pure ob
        :: IO [S.Obligation]
      require (all (\ob->S.obligationDeposit ob==receipt || S.obligationStatus ob=="paid") obligations) "other_obligation_must_resolve_before_refund"
      let active=filter ((==receipt).S.obligationDeposit) obligations
      require (length active<=1 && all ((`elem` ["ready","review"]).S.obligationStatus) active) "principal_already_resolved"
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
      require (not(T.null destination) && T.length destination<=128) "invalid_destination"
      -- Resolved failed/cancelled preparations may retain unused operating holds.
      -- No unresolved intent survives the check above, so release only this work.
      forM_ active $ \old->do
        _<-O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text "cancelled"},O.uWhere= \r->S.obligationId r O..== text(S.obligationId old),O.uReturning=O.rCount}
        _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,num 1),O.uWhere= \(key,_,_,_)->key O..== text(S.obligationId old),O.uReturning=O.rCount}
        pure ()
      _<-O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(key,asset,n,_)->(key,asset,n,text "released"),O.uWhere= \(key,_,_,_)->key O..== text oid,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.operatingReservations,O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,text "released"),O.uWhere= \(key,kind,_,_,_)->key O..== text oid O..&& kind O..== text "conversion",O.uReturning=O.rCount}
      holds<-O.runSelect c $ do
        (key,kind,asset,n,phase)<-O.selectTable S.operatingReservations
        O.where_ (key O..== text oid O..&& kind O..== text "refund")
        pure (asset,n,phase)
        :: IO [(Text,Int64,Text)]
      phase<-case holds of
        [(asset,n,phase)] | asset==T.pack(show feeAsset) && n==units allowance->pure phase
        _->reject "operating_reservation_missing"
      -- Expired quotes and additional receipts need a fresh budget reservation.
      when (phase `notElem` ["quote","obligation"]) $ do
        require (phase `elem` ["released","transferred"]) "invalid_reservation_phase"
        booked<-balances c
        operatingCapacity c (admissionLimits config) booked [(feeAsset,allowance)]
      _<-O.runUpdate c O.Update {O.uTable=S.operatingReservations,O.uUpdateWith= \(key,kind,asset,n,_)->(key,kind,asset,n,text "obligation"),O.uWhere= \(key,kind,_,_,_)->key O..== text oid O..&& kind O..== text "refund",O.uReturning=O.rCount}
      _<-nextSequence c
      let ob=S.Obligation identifier oid receipt "refund" (S.depositAsset d) (S.depositAmount d) destination "ready"
      _<-O.runInsert c O.Insert {O.iTable=S.obligations,O.iRows=[S.Obligation (text identifier) (text oid) (text receipt) (text "refund") (text $ S.depositAsset d) (num $ S.depositAmount d) (text destination) (text "ready")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _<-O.runUpdate c O.Update {O.uTable=S.deposits,O.uUpdateWith= \r->r {S.depositAllocated=num 1},O.uWhere= \r->S.depositId r O..== text receipt,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=text "Refunding"},O.uWhere= \r->S.orderId r O..== text oid O..&& S.status r O../= text "Paid",O.uReturning=O.rCount}
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
  metadata c identity >>= \state->require (S.paused state==1) "pause_before_operator_action"
  previous<-readCancellation c identifier generation
  case previous of
    Just (old,plan,_)->require (old==reason && plan==cleanup) "preparation_cancellation_conflict"
    Nothing->do
      fresh c now
      current<-cancellationPreparation c identity identifier
      require (current==expected) "preparation_cancellation_not_expected"
      sequenceNo<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.preparationCancellations,
        O.iRows=[(O.sqlStrictText identifier,O.sqlInt8(fromIntegral generation),O.sqlStrictText reason,O.sqlStrictText cleanup,O.sqlInt8 sequenceNo,O.sqlInt8 0)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      audit c "preparation_cancellation_requested" (identifier<>"@"<>T.pack(show generation))

finishCancellation :: PG.Connection -> StorePolicy -> PreparedPayment -> Text -> Text -> IO ()
finishCancellation c config expected reason cleanup = do
  let identifier=paymentId(savedPayment $ preparedView expected); generation=preparedGeneration expected
      identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
      text=O.sqlStrictText; num=O.sqlInt8
  metadata c identity >>= \state->require (S.paused state==1) "pause_before_operator_action"
  saved<-readCancellation c identifier generation
  case saved of
    Just (old,plan,done)->do
      require (old==reason && plan==cleanup) "preparation_cancellation_conflict"
      unless done $ do
        current<-cancellationPreparation c identity identifier
        require (current==expected) "preparation_cancellation_not_expected"
        let outgoing=savedPayment $ preparedView expected
            binding=case paymentFunding outgoing of
              Conversion oid receipt _ _->Just(oid,receipt,False)
              Refund oid receipt _ _->Just(oid,receipt,True)
              EarnedFees{}->Nothing
        _<-nextSequence c
        _<-O.runUpdate c O.Update {O.uTable=S.preparationCancellations,O.uUpdateWith= \(key,g,r,p,n,_)->(key,g,r,p,n,num 1),O.uWhere= \(key,g,_,_,_,_)->key O..== text identifier O..&& g O..== num(fromIntegral generation),O.uReturning=O.rCount}
        _<-O.runUpdate c O.Update {O.uTable=S.preparations,O.uUpdateWith= \(key,g,p,d,r,_)->(key,g,p,d,r,num 1),O.uWhere= \(key,g,_,_,_,_)->key O..== text identifier O..&& g O..== num(fromIntegral generation),O.uReturning=O.rCount}
        _<-O.runUpdate c O.Update {O.uTable=S.intents,O.uUpdateWith= \r->r {S.intentResolved=num 1},O.uWhere= \r->S.intentId r O..== text identifier,O.uReturning=O.rCount}
        forM_ binding $ \(oid,receipt,isRefund)->do
          eligible<-sourceAuthorized c identifier receipt
          let retryable=eligible && generation<7
          _<-O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text(if retryable then "ready" else "review")},O.uWhere= \r->S.obligationId r O..== text identifier,O.uReturning=O.rCount}
          _<-O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=text(if not retryable then "NeedsReview" else if isRefund then "Refunding" else "Ready")},O.uWhere= \r->S.orderId r O..== text oid O..&& S.status r O../= text "Paid",O.uReturning=O.rCount}
          _<-O.runUpdate c O.Update {O.uTable=S.reservations,O.uUpdateWith= \(key,a,n,_)->(key,a,n,text "obligation"),O.uWhere= \(key,_,_,phase)->key O..== text oid O..&& phase O..== text "payment",O.uReturning=O.rCount}
          pure ()
        audit c "preparation_cancellation_completed" (identifier<>"@"<>T.pack(show generation))
    Nothing->reject "preparation_cancellation_not_expected"

-- Fee-reservation release accepts only wholly unsigned cancellation history.
-- Preparation retries also accept separately proved and approved Solana expiry.
cancelledGeneration :: PG.Connection -> Text -> IO (Maybe Int)
cancelledGeneration=nextGeneration False
retryGeneration :: PG.Connection -> Text -> IO (Maybe Int)
retryGeneration=nextGeneration True
nextGeneration :: Bool -> PG.Connection -> Text -> IO (Maybe Int)
nextGeneration includeExpired c identifier = do
  rows<-O.runSelect c $ O.orderBy (O.asc (\(g,_,_)->g)) $ do
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
      permitted<-forM rows $ \(g,retired,cancelled)->case (retired,cancelled) of
        (Nothing,1)->do
          done<-readCancellation c identifier (fromIntegral g)
          pure (case done of Just(_,_,True)->all ((/=g).snd) attempts; _->False)
        (Just txid,0) | includeExpired->do
          expired<-expiryProof c txid
          approved<-retryReason c txid
          pure (expired/=Nothing && approved/=Nothing && filter ((==g).snd) attempts==[(txid,g)])
        _->pure False
      pure $ if and permitted && all (\(_,g)->g>=0 && g<fromIntegral(length rows)) attempts then Just(length rows) else Nothing

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
    Just old->require (old==proof) "expiry_evidence_conflict"
    Nothing->do
      current<-readAttempt c txid
      prepared<-readPreparation c identity identifier
      require (current==expected && preparedGeneration prepared==recordedGeneration expected) "expiry_attempt_changed"
      family<-O.runSelect c $ do
        (key,intent,_,_,_,_)<-S.workAttempts
        expired<-Exists.exists $ do
          (other,_,_)<-O.selectTable S.solanaExpiries
          O.where_ (other O..== key)
          pure ()
        O.where_ (intent O..== text identifier O..&& O.not expired)
        pure key
        :: IO [Text]
      require (family==[txid]) "expiry_attempt_changed"
      sequenceNo<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.solanaExpiries,O.iRows=[(text txid,text proof,num sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _<-O.runUpdate c O.Update {O.uTable=S.preparations,O.uUpdateWith= \(key,g,p,d,_,cancelled)->(key,g,p,d,O.toNullable $ text txid,cancelled),O.uWhere= \(key,g,_,_,_,_)->key O..== text identifier O..&& g O..== num(fromIntegral $ recordedGeneration expected),O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text "review",S.attemptObservation=O.toNullable $ text proof},O.uWhere= \r->S.attemptId r O..== text txid,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.feeHolds,O.uUpdateWith= \(key,a,n,_)->(key,a,n,num 1),O.uWhere= \(key,_,_,_)->key O..== text identifier,O.uReturning=O.rCount}
      _<-O.runUpdate c O.Update {O.uTable=S.intents,O.uUpdateWith= \r->r {S.intentResolved=num 1},O.uWhere= \r->S.intentId r O..== text identifier,O.uReturning=O.rCount}
      setCustomerPaymentState c (savedPayment $ preparedView prepared) "review" "NeedsReview"
      audit c "solana_expiry_verified" txid

approveSolanaRetry :: PG.Connection -> StorePolicy -> Int64 -> RecordedAttempt -> Text -> Text -> IO ()
approveSolanaRetry c config now expected reason proof = do
  validReason reason
  validateSavedJson 200000 proof
  let txid=signedId $ recordedSigned expected; identifier=recordedPayment expected
      identity=deploymentFingerprint $ paymentPolicy $ executionTerms config
  old<-retryReason c txid
  case old of
    Just previous->require (previous==reason) "retry_approval_conflict"
    Nothing->do
      metadata c identity >>= \state->require (S.paused state==1) "pause_before_operator_action"
      fresh c now
      current<-readAttempt c txid
      expired<-expiryProof c txid
      require (current==expected && recordedChain expected=="Solana" && recordedState expected=="review" && expired/=Nothing) "solana_retry_not_expected"
      rows<-O.runSelect c $ do
        i<-O.selectTable S.intents
        (key,g,_,_,retired,cancelled)<-S.workPreparations
        O.where_ (S.intentId i O..== O.sqlStrictText identifier O..&& key O..== S.intentId i)
        pure (g,retired,cancelled,S.intentResolved i)
        :: IO [(Int64,Maybe Text,Int64,Int64)]
      require (not(null rows) && maximum(map (\(g,_,_,_)->g) rows)==fromIntegral(recordedGeneration expected)
        && (fromIntegral(recordedGeneration expected),Just txid,0,1) `elem` rows && recordedGeneration expected<7) "solana_retry_not_expected"
      view<-readPayment c identity identifier
      require (savedStatus view==PaymentReview) "solana_retry_not_expected"
      paymentSource c (savedPayment view)
      sequenceNo<-nextSequence c
      _<-O.runInsert c O.Insert {O.iTable=S.solanaRetryApprovals,O.iRows=[(O.sqlStrictText txid,O.sqlStrictText reason,O.sqlStrictText proof,O.sqlInt8 sequenceNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      setCustomerPaymentState c (savedPayment view) "ready" "Ready"
      audit c "solana_retry_approved" txid

setCustomerPaymentState :: PG.Connection -> Payment -> Text -> Text -> IO ()
setCustomerPaymentState c outgoing obligationState orderState = do
  let binding=case paymentFunding outgoing of Conversion oid _ _ _->Just oid; Refund oid _ _ _->Just oid; EarnedFees{}->Nothing
      text=O.sqlStrictText
      status=case paymentFunding outgoing of Refund{} | orderState=="Ready"->"Refunding"; _->orderState
  forM_ binding $ \oid->do
    _<-O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \r->r {S.obligationStatus=text obligationState},O.uWhere= \r->S.obligationId r O..== text(paymentId outgoing),O.uReturning=O.rCount}
    _<-O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.status=text status},O.uWhere= \r->S.orderId r O..== text oid O..&& S.status r O../= text "Paid",O.uReturning=O.rCount}
    pure ()

-- Only verified unbound receipts may become operator capital. The attestation
-- establishes ownership; it cannot supply amounts, chain effects or eligibility.
allocateTreasury :: PG.Connection -> PaymentTerms -> Int64 -> Text -> [(Text,Amount)] -> Text -> IO Int64
allocateTreasury c policy now receipt split reason = do
  validReason reason
  let entries=sortOn fst split; names=map fst entries; encoded=encodeSaved entries
      text=O.sqlStrictText; num=O.sqlInt8
  require (not(null entries) && length entries<=4 && length(nub names)==length names
    && all (`elem` ["float","backing","operating","lp"]) names && all ((>0).units.snd) entries) "invalid_treasury_allocation"
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
      state<-metadata c (deploymentFingerprint $ paymentPolicy policy)
      require (S.paused state==1) "treasury_allocation_requires_pause"
      fresh c now
      source<-readSource c receipt
      require (S.depositOrder source==Nothing && S.depositEligible source==1 && S.depositAllocated source==0) "receipt_not_available_for_treasury"
      currency<-parseAsset (S.depositAsset source)
      let quantity=S.depositAmount source
          (chain,prefix,key)=case currency of
            Native->("Native","native:",T.takeWhile (/=':') $ T.drop 7 receipt)
            Wrapped->("Solana","solana:",T.drop 7 receipt)
            Sol->("SolanaOperating","sol-operating:",T.drop 14 receipt)
      require (prefix `T.isPrefixOf` receipt && not(T.null key)) "invalid_treasury_receipt_id"
      require (currency/=Native || S.depositDepth source>=fromIntegral(nativeDepth $ paymentPolicy policy)) "treasury_receipt_underconfirmed"
      require (sum(map (toInteger.units.snd) entries)==toInteger quantity) "treasury_allocation_amount_mismatch"
      require (currency/=Sol || names==["operating"]) "sol_reserved_for_operating"
      linked<-O.runSelect c $ do
        row<-O.selectTable S.obligations
        O.where_ (S.obligationDeposit row O..== text receipt)
        pure (S.obligationId row)
        :: IO [Text]
      require (null linked) "receipt_has_customer_obligation"
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
      postings<-forM entries $ \(name,n)->case lookup name accounts of
        Just account->pure (Posting currency account $ toInteger $ units n)
        Nothing->reject "invalid_treasury_allocation"
      post c ("treasury:"<>receipt) "operator allocation of verified treasury receipt"
        (Posting currency Unallocated (negate $ toInteger quantity):postings)
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
  economic@(currency,outflow,fee)<-checked (W.economicOutflow chain proof)
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
      let total=toInteger(units outflow); charge=toInteger(units fee)
          costs=case currency of Native->[(Float,total-charge),(Operating,charge)]; Wrapped->[(Float,total)]; Sol->[(Operating,total)]
      booked<-balances c
      inventory<-O.runSelect c $ do
        (_,asset,n,phase)<-O.selectTable S.reservations
        O.where_ (asset O..== text(T.pack $ show currency) O..&& phase O../= text "released")
        pure n
        :: IO [Int64]
      operating<-operatingHolds c currency
      forM_ costs $ \(account,cost)->do
        let held=if account==Float then sum(map toInteger inventory) else operating
        require (cost>=0 && M.findWithDefault 0 (currency,account) booked-held>=cost) "treasury_spend_exceeds_free_allocation"
      n<-nextSequence c
      post c ("treasury-spend:"<>chain<>":"<>key) "verified operator spend and network costs"
        ([Posting currency account (-cost) | (account,cost)<-costs]<>[Posting currency External total])
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
  require (S.obligationStatus obligation=="review" && case history of
    (_,_,phase,shortfall,_,n):_->n==restoration && if covered
      then S.depositAsset deposit=="Native" && S.depositEligible deposit==0 && phase=="missing" && shortfall==S.depositAmount deposit
      else S.depositEligible deposit==1 && phase=="restored" && shortfall==0
    _->False) "source_approval_not_expected"
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
  (previous,loss,expected)<-case concat reviews of
    row@(state,_,_):_ | state `elem` ["ready","paying"]->pure row
    _->reject "source_review_context_missing"
  actual<-sourceWorkHash c key
  require (expected==actual) "source_review_work_changed"
  pending<-O.runSelect c $ do
    (identifier,g,_,_,done)<-S.workCancellations
    O.where_ (identifier O..== text key O..&& done O..== num 0)
    pure g
    :: IO [Int64]
  require (null pending) "preparation_cancellation_pending"
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
      updated<-O.runUpdate c O.Update {O.uTable=S.obligations,O.uUpdateWith= \row->row {S.obligationStatus=text previous},O.uWhere= \row->S.obligationId row O..== text key,O.uReturning=O.rCount}
      require (count==1 && updated==1) "source_approval_changed"
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
      require (W.depositAsset source==Native && not(W.depositEligible source)) "source_loss_not_proven"
      current<-readSource c receipt >>= asDeposit
      history<-O.runSelect c $ O.limit 1 $ O.orderBy (O.desc (\(n,_,_,_,_,_)->n)) $ do
        row@(_,key,_,_,_,_)<-O.selectTable S.sourceChecks
        O.where_ (key O..== text receipt)
        pure row
        :: IO [(Int64,Text,Text,Int64,Text,Int64)]
      require (current==source && case history of [(_,_,"missing",n,_,sequenceNo)]->n==quantity && sequenceNo==recovery; _->False) "source_loss_not_proven"
      require (toInteger(units capital)+toInteger(units earned)==toInteger quantity) "source_loss_allocation_mismatch"
      covers<-O.runSelect c $ do
        (n,key,_,_,_)<-S.activeSourceCovers
        O.where_ (key O..== text receipt)
        pure n
        :: IO [Int64]
      require (null covers) "source_loss_already_covered"
      verifyLossView c receipt proof report
      currentRevision<-readCustodyRevision c
      require (matches && currentRevision==revision && at>=0 && at<=now && toInteger now-toInteger at<=60) "source_loss_custody_not_current"
      booked<-balances c
      holds<-O.runSelect c $ do
        (_,asset,n,phase)<-O.selectTable S.reservations
        O.where_ (asset O..== text "Native" O..&& phase O../= text "released")
        pure n
        :: IO [Int64]
      require (M.findWithDefault 0 (Native,Float) booked-sum(map toInteger holds)>=toInteger(units capital)
        && M.findWithDefault 0 (Native,Earned) booked>=toInteger(units earned)) "insufficient_loss_capital"
      let custody=object ["revision" .= revision,"checkedAt" .= at,"report" .= report]
          evidence=encodeSaved $ object ["source" .= proof,"custody" .= custody]
      require (T.length evidence<=32768) "source_loss_evidence_too_large"
      sequenceNo<-nextSequence c
      count<-O.runInsert c O.Insert {O.iTable=S.sourceLossCovers,O.iRows=[(num sequenceNo,text receipt,num recovery,num quantity,num $ units capital,num $ units earned,text reason,text evidence)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (count==1) "source_loss_cover_insert_failed"
      post c ("source-loss-cover:"<>T.pack(show sequenceNo)) "operator capital covers verified source shortfall"
        [Posting Native Float (negate $ toInteger $ units capital),Posting Native Earned (negate $ toInteger $ units earned),Posting Native SourceDeficit (toInteger quantity)]
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
  metadata c identity >>= \state->require (S.paused state==1) "pause_before_operator_action"
  current<-sendContext c identity txid
  require (recordedChain current=="Native" && recordedState current=="broadcast_intent"
    && maybe False (>0) (recordedSequence current)) "native_replacement_not_expected"
  family<-nativeFamily c identity (recordedPayment current)
  require (fst(last family)==current && length family<8) "native_replacement_not_current"
  _<-checked (N.replacementOutputs (snd $ last family) fee)
  drafts<-O.runSelect c $ do
    (n,parent,_,_,_,_)<-S.replacementDrafts
    O.where_ (O.in_ (map (O.sqlStrictText.signedId.recordedSigned.fst) family) parent)
    pure n
    :: IO [Int64]
  require (length drafts<7) "native_replacement_draft_limit"
  fresh c now
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
  require (recordedChain parent=="Native" && recordedState parent=="broadcast_intent"
    && maybe False (>0) (recordedSequence parent) && recordedGeneration parent==preparedGeneration prepared
    && savedStatus(preparedView prepared)==PaymentPaying && recordedFee parent==preparedFee prepared) "native_replacement_not_expected"
  paymentSource c (savedPayment $ preparedView prepared)
  family<-nativeFamily c identity identifier
  require (fst(last family)==parent) "native_replacement_not_current"
  currentHash<-paymentWorkHash c identifier
  require (currentHash==hash) "native_replacement_work_changed"
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
    intent<-O.selectTable S.intents
    O.where_ (S.attemptIntent saved O..== S.intentId intent O..&& S.intentChain intent O..== text "Native"
      O..&& S.attemptState saved O..== text "settled")
    -- CASE protects the native-only inner codec even if PostgreSQL evaluates
    -- this expression before its WHERE filters (Solana proofs have another shape).
    let proof=json $ O.ifThenElse (S.intentChain intent O..== text "Native" O..&& S.attemptState saved O..== text "settled")
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
      require (map fst family==expectedFamily && winnerId/=txid && actual `elem` map fst family) "native_replacement_family_changed"
      (winner,signed)<-case [(a,s)|(a,s)<-family,signedId(recordedSigned a)==winnerId] of
        [member]->pure member; _->reject "native_family_winner_missing"
      require (recordedState winner `elem` ["broadcast_intent","review"] && maybe False (>0) (recordedSequence winner)) "unrecorded_broadcast_observed"
      oldSigned<-decodeSaved (signedPolicy $ recordedSigned actual)
      oldCosts<-settledCosts actual oldSigned
      hash<-nativeSettlementProof c winner signed costs proof
      let saved=encodeSaved $ object ["costs" .= costs,"proof" .= proof]
          delta=toInteger(units $ W.networkFee costs)-toInteger(units $ W.networkFee oldCosts)
      require (T.length saved<=32768 && delta/=0 && abs delta<=toInteger(maxBound::Int64)) "invalid_native_settlement"
      n<-nextSequence c
      inserted<-O.runInsert c O.Insert {O.iTable=S.nativeWinnerChanges,
        O.iRows=[(num n,text txid,text winnerId,text previous,text saved,text hash,num $ fromInteger delta)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      require (inserted==1) "native_winner_record_failed"
      post c ("native-winner-fee:"<>T.pack(show n)) "canonical native winner fee adjustment"
        [Posting Native Operating (negate delta),Posting Native External delta]
      oldChanged<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text "review"},O.uWhere= \r->S.attemptId r O..== text txid,O.uReturning=O.rCount}
      newChanged<-O.runUpdate c O.Update {O.uTable=S.attempts,O.uUpdateWith= \r->r {S.attemptState=text "settled",S.attemptObservation=O.toNullable $ text saved},O.uWhere= \r->S.attemptId r O..== text winnerId,O.uReturning=O.rCount}
      require (oldChanged==1 && newChanged==1) "native_winner_context_changed"
      view<-readPayment c identity identifier
      let customer=case paymentFunding(savedPayment view) of Conversion order _ _ _->Just order; Refund order _ _ _->Just order; EarnedFees{}->Nothing
      forM_ customer $ \order->do
        _<-O.runUpdate c O.Update {O.uTable=S.orders,O.uUpdateWith= \r->r {S.payoutTx=O.toNullable $ text winnerId},
          O.uWhere= \r->S.orderId r O..== text order O..&& O.fromNullable (text "") (S.payoutTx r) O..== text txid,O.uReturning=O.rCount}
        pure ()
      pauseScan c "native_winner_changed"
      audit c "native_winner_changed" (txid<>":"<>winnerId)
    _->do
      (state,saved)<-case result of
        NativeConfirming->pure ("confirming",encodeSaved $ object ["reason" .= ("native_confirmation_policy_pending"::Text)])
        NativeUnavailable reason->do
          require (not(T.null reason) && T.length reason<=160) "invalid_native_recovery_reason"
          pure ("unavailable",encodeSaved $ object ["reason" .= reason])
        NativeReconfirmed costs proof->do
          family<-nativeFamily c identity identifier
          signed<-case [s|(a,s)<-family,a==actual] of [s]->pure s; _->reject "native_settlement_changed"
          oldCosts<-settledCosts actual signed
          require (costs==oldCosts) "native_recovery_cost_changed"
          _<-nativeSettlementProof c actual signed costs proof
          pure ("reconfirmed",encodeSaved $ object ["costs" .= costs,"proof" .= proof])
      validateSavedJson 32768 saved
      old<-O.runSelect c $ do
        (tx,_,status,proof,_)<-S.nativeRecoveryDetails
        O.where_ (tx O..== text txid)
        pure (status,proof)
        :: IO [(Text,Text)]
      let base value=case value of Object fields->Object $ foldr KM.delete fields ["rebroadcastRecovery","operatorReason","rebroadcastProof"]; other->other
      unchanged<-case old of
        [(status,proof)] | status==state->(==) <$> (base <$> (decodeSaved proof :: IO Value)) <*> (decodeSaved saved :: IO Value)
        []->pure (state=="reconfirmed" && previous==saved)
        [_]->pure False
        _->reject "duplicate_native_recovery_state"
      unless unchanged $ do
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
    intent<-O.selectTable S.intents
    (key,asset,quantity,released)<-O.selectTable S.feeHolds
    O.where_ (S.intentId intent O..== O.sqlStrictText(recordedPayment saved) O..&& key O..== S.intentId intent)
    pure (S.intentResolved intent,asset,quantity,released)
    :: IO [(Int64,Text,Int64,Int64)]
  require (context==[(1,"Native",units(recordedFee saved),1)]) "native_winner_context_changed"

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
  require (savedStatus view==PaymentPaid) "native_rebroadcast_payment_changed"
  paymentSource c (savedPayment view)
  family<-nativeFamily c identity (recordedPayment saved)
  require (saved `elem` map fst family) "native_replacement_family_changed"
  reviews<-O.runSelect c $ do
    (key,previous,status,proof,n)<-S.nativeRecoveryDetails
    O.where_ (key O..== O.sqlStrictText txid)
    pure (previous,status,proof,n)
    :: IO [(Text,Text,Text,Int64)]
  (previous,status,raw,n)<-case reviews of [row]->pure row; _->reject "native_rebroadcast_review_missing"
  value<-decodeSaved raw
  reason<-nativeProofField "reason" value :: IO Text
  require (recordedObservation saved==Just previous
    && (status=="confirming" && reason=="native_confirmation_policy_pending"
      || status=="unavailable" && reason=="native_settled_payment_unseen")) "native_rebroadcast_not_missing"
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
