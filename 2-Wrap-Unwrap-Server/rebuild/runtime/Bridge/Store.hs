{-# LANGUAGE DataKinds, GADTs, LambdaCase, ScopedTypeVariables #-}
-- Closed ledger operations. Connections, queries and transaction callbacks never
-- escape this module; the runtime will interpret its customer/operator DSL here.
module Bridge.Store
  ( Reader, Writer, StoreError(..), StoreRead(..), StoreWrite(..), LedgerState(..), WithdrawalView(..)
  , withReader, withWriter, evalRead, evalWrite ) where

import Bridge.Identity (bearerHash)
import qualified Bridge.Wire as W
import Bridge.Domain
import Bridge.Wire (PaymentTerms(..),PolicySnapshot(..))
import qualified Bridge.Store.Schema as S
import Bridge.Store.Catalog (claimWorker,verifyReadRole)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless)
import Data.Aeson (FromJSON,encode,eitherDecodeStrict')
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

data StoreRead a where
  ReadState :: StoreRead LedgerState
  ReadBalances :: StoreRead (M.Map (Asset,Account) Integer)
  ReadWithdrawal :: Text -> StoreRead (Maybe WithdrawalView)
  ReadOrder :: Text -> Text -> StoreRead W.OrderView
data StoreWrite a where
  Pause :: Text -> StoreWrite ()
  ReserveFees :: Int64 -> Text -> Asset -> Amount -> Text -> Text -> StoreWrite WithdrawalView
  CancelFees :: Text -> Text -> StoreWrite WithdrawalView

-- Reader has no writer connection, checkpoint or writable credentials.
data Reader = Reader PG.ConnectInfo Text Bool
data Writer = Writer (MVar (Maybe PG.Connection)) PaymentTerms Amount (Int64 -> IO ())

withReader :: PG.ConnectInfo -> Text -> Bool -> (Reader -> IO a) -> IO a
withReader settings identity remote action = do
  let reader = Reader settings identity remote
  _ <- evalRead reader ReadState
  action reader

-- The checkpoint must persist the monotonic host fence before commit. It is
-- infrastructure, not an operation supplied by a handler. No optional bypass.
withWriter :: PG.ConnectInfo -> PaymentTerms -> Amount -> (Int64 -> IO ()) -> (Writer -> IO a) -> IO a
withWriter settings policy limit checkpoint action = bracket (PG.connect settings) PG.close $ \c -> do
  require (units limit>0 && nativeDepth (paymentPolicy policy)>0 && solanaCommitment (paymentPolicy policy)=="finalized") "invalid_store_policy"
  claimWorker c >>= flip require "worker_already_running"
  row <- metadata c (deploymentFingerprint $ paymentPolicy policy)
  checkpoint (S.criticalSequence row)
  writer <- (\cell -> Writer cell policy limit checkpoint) <$> newMVar (Just c)
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
evalWrite writer@(Writer _ policy limit _) operation = transaction writer $ \c -> case operation of
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
    require (now>=0 && T.length key==64 && T.all (`elem` ("0123456789abcdef"::String)) key && n<=limit) "invalid_fee_withdrawal"
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
transaction (Writer cell policy _ checkpoint) action = do
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
  rows <- O.runSelect c $ do
    (_,_,currency,account,delta) <- O.selectTable S.postings
    pure (currency,account,delta)
    :: IO [(Text,Text,Int64)]
  entries <- mapM (\(currency,account,delta)->do
    a<-parseAsset currency
    b<-maybe (reject "unknown_ledger_account") pure (lookup account accounts)
    pure ((a,b),toInteger delta)) rows
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
