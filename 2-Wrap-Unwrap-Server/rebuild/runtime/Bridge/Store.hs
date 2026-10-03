{-# LANGUAGE DataKinds, GADTs, LambdaCase, ScopedTypeVariables #-}
-- Closed ledger operations. Connections, queries and transaction callbacks never
-- escape this module; the runtime will interpret its customer/operator DSL here.
module Bridge.Store
  ( Reader, Writer, BridgeError(..), StoreRead(..), StoreWrite(..), OrderLimits(..), StorePolicy(..), AllocationClaim(..), LedgerState(..), WithdrawalView(..)
  , withReader, withWriter, evalRead, evalWrite ) where

import Bridge.Error
import Bridge.Identity (bearerHash,digest,payInstruction)
import qualified Bridge.Wire as W
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),PolicySnapshot(..),CostLimits(..))
import qualified Bridge.Store.Schema as S
import Bridge.Store.Catalog (claimWorker,verifyReadRole)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString as BS
import Data.List (nub,sortOn)
import Data.Profunctor.Product (p3)
import Data.Scientific (Scientific,floatingOrInteger)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless,forM,forM_,when)
import Data.Aeson (FromJSON,ToJSON,Value(Null),object,(.=),encode,eitherDecodeStrict',withObject,(.:))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Transaction as Tx
import qualified Opaleye as O
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
data AllocationClaim = AllocationClaim { allocationLabel :: Text, mayAllocate :: Bool }
  deriving (Eq,Show)

data StoreRead a where
  ReadState :: StoreRead LedgerState
  ReadBalances :: StoreRead (M.Map (Asset,Account) Integer)
  ReadWithdrawal :: Text -> StoreRead (Maybe WithdrawalView)
  ReadOrder :: Text -> Text -> StoreRead W.OrderView
  PromotionCandidates :: StoreRead [Text]
  LookupInstruction :: Text -> StoreRead (Maybe (Text,W.OrderRequest,W.PolicySnapshot))
  MaximumNativeDepth :: Int -> StoreRead Int
  ReadSourceWorkHash :: Text -> StoreRead Text
  ReadCheckpoint :: Text -> StoreRead (Maybe Text)
  ReadSource :: Text -> StoreRead W.Deposit
  ReadSourceEvidence :: Text -> StoreRead (Text,Text)
data StoreWrite a where
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
      ReadState -> pure (LedgerState (S.criticalSequence row) (S.backupSequence row) (S.paused row/=0) (S.pauseReason row))
      LookupInstruction instruction -> lookupInstruction c instruction
      MaximumNativeDepth minimumDepth -> maximumNativeDepth c minimumDepth
      ReadSourceWorkHash identifier -> sourceWorkHash c identifier
      ReadCheckpoint chain -> readCheckpoint c chain
      ReadSource identifier -> readSource c identifier >>= asDeposit
      ReadSourceEvidence txid -> sourceEvidence c txid
      PromotionCandidates -> promotionCandidates c
      ReadBalances -> balances c
      ReadWithdrawal key -> readWithdrawal c key
      ReadOrder header identifier -> do
        cap <- checked (bearerHash header)
        readOrder c identity (if remote then Just(S.backupSequence row) else Nothing) cap identifier

evalWrite :: Writer -> StoreWrite a -> IO a
evalWrite writer@(Writer _ config _) operation = transaction writer $ \c ->
 let policy=executionTerms config; limit=admissionLimits config in case operation of
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
        require (null work) "fee_withdrawal_payment_exists"
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
      result <- try $ do
        PG.begin c
        locked <- O.runSelect c $ Locking.forUpdate $ do
          r <- O.selectTable S.deployment
          O.where_ (S.singleton r O..== O.sqlInt8 1)
          pure (S.singleton r)
        require (locked==[1::Int64]) "corrupt_deployment"
        _ <- metadata c (deploymentFingerprint $ paymentPolicy policy)
        value <- restore (action c)
        row <- metadata c (deploymentFingerprint $ paymentPolicy policy)
        checkpoint (S.criticalSequence row)
        PG.commit c
        pure value
      case result of
        Right value -> pure (Just c,Right value)
        Left (err :: SomeException) -> do
          rollback <- try (PG.rollback c) :: IO (Either SomeException ())
          let reusable = case (fromException err :: Maybe BridgeError,rollback) of
                (Just _,Right ()) -> True
                _ -> False
          pure (if reusable then Just c else Nothing,Left err)
  either throwIO pure outcome

metadata :: PG.Connection -> Text -> IO S.Deployment
metadata c identity = do
  rows <- O.runSelect c (O.selectTable S.deployment)
  case rows of
    [r] | S.singleton r==1 && S.schemaVersion r==18 && S.fingerprint r==identity
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
    O.where_ (tx O..== attempt O..&& intent O..== intentId O..&& obligation O..== obligationId
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

-- Chain-specific admission happens before this closed operation. It does not
-- allocate an address or issue instructions: it atomically saves an order and
-- both its payout inventory and conversion/refund operating allowances.
createOrder :: PG.Connection -> PaymentTerms -> OrderLimits -> Int64 -> Text -> W.OrderRequest -> IO Text
createOrder c terms limits now header request = do
  cap <- checked (bearerHash header)
  let key=W.idempotencyKey request; identity=deploymentFingerprint (paymentPolicy terms)
      encoded=encodeSaved request; requestDigest=digest (TE.encodeUtf8 $ identity<>encoded)
  require (not(T.null key) && T.length key<=64 && T.all (\x->x `elem` ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"::String)) key) "invalid_idempotency_key"
  previous <- O.runSelect c $ do
    row <- O.selectTable S.orders
    O.where_ (S.capabilityHash row O..== O.sqlStrictText cap O..&& S.idempotencyKey row O..== O.sqlStrictText key)
    pure (S.orderId row,S.requestHash row)
    :: IO [(Text,Text)]
  case previous of
    [(identifier,saved)] -> require (saved==requestDigest) "idempotency_conflict" >> pure identifier
    [] -> do
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
    _ -> reject "duplicate_idempotency"

intakeReady :: PG.Connection -> Text -> Int64 -> IO ()
intakeReady c identity now = do
  require (now>=0) "invalid_order_time"
  d <- metadata c identity
  require (S.paused d==0) "intake_paused"
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
  fresh c now

reserveOrderCosts :: PG.Connection -> OrderLimits -> CostLimits -> M.Map (Asset,Account) Integer -> Text -> Direction -> IO ()
reserveOrderCosts c limits costs booked identifier direction = do
  total <- checked $ amount (toInteger(units $ savedSolanaFee costs)+toInteger(units $ savedSolanaRent costs))
  wallTime <- floor <$> getPOSIXTime
  times <- O.runUpdate c O.Update {O.uTable=S.operatingClock,
    O.uUpdateWith= \(key,old)->(key,O.ifThenElse (old O..> O.sqlInt8 wallTime) old (O.sqlInt8 wallTime)),
    O.uWhere= \(key,_)->key O..== O.sqlInt8 1,O.uReturning=O.rReturning snd}
  now <- case times of [t]->pure t; _->reject "operating_clock_missing"
  let allowances=[(Native,savedNativeFee costs,nativeDaily limits),(Sol,total,solanaDaily limits)]
  forM_ allowances $ \(asset,quantity,daily)->do
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
    spending <- O.runSelect c $ do
      (posting,_,currency,_,delta) <- O.selectTable S.postings
      (cost,at) <- O.selectTable S.operatingCosts
      O.where_ (posting O..== cost O..&& currency O..== O.sqlStrictText name O..&& at O..> O.sqlInt8 (now-86400))
      pure delta
      :: IO [Int64]
    let held=sum(map toInteger $ orderHolds<>paymentHolds); needed=toInteger(units quantity)
    require (M.findWithDefault 0 (asset,Operating) booked-held>=needed) "insufficient_fee_budget"
    require (negate(sum(map toInteger spending))+held+needed<=toInteger(units daily)) "operating_daily_limit"
  let text=O.sqlStrictText; num=O.sqlInt8
  _ <- O.runInsert c O.Insert {O.iTable=S.orderCosts,
    O.iRows=[(text identifier,num $ units $ savedNativeFee costs,num $ units $ savedSolanaFee costs,num $ units $ savedSolanaRent costs)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
  forM_ allowances $ \(asset,quantity,_)->do
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
sourceWorkHash c intent = do
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
  pure (if null drafts && null cancelled then base else digest $ BL.toStrict $ encode (base,drafts,cancelled))

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
