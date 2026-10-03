{-# LANGUAGE DataKinds, GADTs, LambdaCase, ScopedTypeVariables #-}
-- Closed ledger operations. Connections, queries and transaction callbacks never
-- escape this module; the runtime will interpret its customer/operator DSL here.
module Bridge.Store
  ( Reader, Writer, StoreError(..), StoreRead(..), StoreWrite(..), OrderLimits(..), StorePolicy(..), AllocationClaim(..), LedgerState(..), WithdrawalView(..)
  , withReader, withWriter, evalRead, evalWrite ) where

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
import Control.Monad (unless,forM_,when)
import Data.Aeson (FromJSON,ToJSON,encode,eitherDecodeStrict')
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

data StoreError = StoreError Text deriving (Eq,Show)
instance Exception StoreError
require :: Bool -> Text -> IO ()
require ok problem = unless ok (throwIO $ StoreError problem)
reject :: Text -> IO a
reject = throwIO . StoreError

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
data StoreWrite a where
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
      ReadBalances -> balances c
      ReadWithdrawal key -> readWithdrawal c key
      ReadOrder header identifier -> do
        cap <- checked (bearerHash header)
        readOrder c identity (if remote then Just(S.backupSequence row) else Nothing) cap identifier

evalWrite :: Writer -> StoreWrite a -> IO a
evalWrite writer@(Writer _ config _) operation = transaction writer $ \c ->
 let policy=executionTerms config; limit=admissionLimits config in case operation of
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
    Nothing -> pure (Nothing,Left (toException $ StoreError "ledger_connection_fenced"))
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
          let reusable = case (fromException err :: Maybe StoreError,rollback) of
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
