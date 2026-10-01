{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- Three explicitly scoped real Signet/Devnet ledger acceptance orders.
-- The client request/capability are private inputs; no browser/API gate is opened.
import Bridge.Config
import Bridge.Admission (checkSolanaQuote)
import Bridge.Deposit
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment (checkNativeQuote)
import Bridge.Observer
import Bridge.RPC
import Bridge.Settlement
import Bridge.Solana
import Bridge.SolanaPayment (systemLamports)
import Bridge.Types
import Control.Concurrent (threadDelay)
import Control.Exception (finally,catch,throwIO)
import Control.Monad (when)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)
import System.Environment (getArgs)
import System.IO (hFlush,stdout)

main :: IO ()
main=do
  args<-getArgs
  (path,privateRequest,mode)<-case args of [a,b,m] | m `elem` ["prepare","transaction","run","refund","status"] -> pure(a,b,m); _->fail "public-test-order CONFIG PRIVATE_REQUEST prepare|transaction|run|refund|status"
  c<-loadConfig path
  require (profile c==L2LSignetDevnet && not (backupRequired c)
    && fingerprint c=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "different_public_test_deployment"
  saved<-BS.readFile privateRequest >>= either fail pure . eitherDecodeStrict'
  capability<-fieldValue "capability" saved
  request<-fieldValue "request" saved
  let owner="HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg"
      wrapping=direction request==NativeToWrapped
      nativeDestination=if wrapping then refund request else recipient request
  require (units (input request)==10000 && if wrapping
    then recipient request==owner && idempotencyKey request=="public-test-wrap-1" && sourceOwner request==Nothing
    else refund request==owner && sourceOwner request==Just owner && idempotencyKey request `elem` ["public-test-redeem-1","public-test-redeem-2"]) "unexpected_public_test_order"
  manager<-newRpcManager
  withLedger (dbPath c) (fingerprint c) $ \ledger -> (do
    orders<-ledgerAction ledger $ \db -> query_ db "SELECT id,idempotency_key,status FROM orders" :: IO [(Text,Text,Text)]
    require (length orders<=3 && all (\(_,key,st)->key `elem` ["public-test-wrap-1","public-test-redeem-1","public-test-redeem-2"]
      && (key==idempotencyKey request || st `elem` ["Paid","Refunded"])) orders) "only_sequential_acceptance_orders"
    let existing=[oid | (oid,key,_)<-orders,key==idempotencyKey request]
    case mode of
      "prepare" -> do
        scan<-observeOnce manager c ledger
        requireHealthy scan
        requireBalances manager c ledger
        tester<-nativeCall manager c{nativeWallet="ecx-bridge-tester"} True "getaddressinfo" [toJSON nativeDestination]
        owned<-fieldValue "ismine" tester
        require owned "refund_must_belong_to_test_wallet"
        resumeAfterChecks ledger
        order<-case existing of
          []->do
            _<-checkNativeQuote manager c request
            _<-checkSolanaQuote manager c request
            now<-epochSeconds
            createOrder ledger c now capability request
          [oid]->do
            prior<-readOrder ledger capability oid
            require (Bridge.Types.request prior==request) "acceptance_request_changed"
            pure prior
          _->reject "duplicate_acceptance_order"
        case depositInstruction order of
          Nothing->if wrapping then newNativeAddress manager c (orderId order) >>= bindInstruction ledger (orderId order)
            else bindInstruction ledger (orderId order) (solanaDepositMemo c $ orderId order)
          Just _->pure ()
        exposeOrder ledger False capability (orderId order) >>= output
      _ -> do
        oid<-case existing of [i]->pure i; _->reject "prepare_order_first"
        case mode of
          "status"->readOrder ledger capability oid >>= output
          "transaction"->do
            require (not wrapping) "wrapped_deposit_only"
            observeOnce manager c ledger >>= requireHealthy
            requireBalances manager c ledger
            resumeAfterChecks ledger
            prepareSolanaDeposit manager c ledger capability oid >>= output
          "refund"->do
            -- The first redemption was observed after its immutable deadline.
            -- Preserve that exception and return its principal to the bound owner.
            require (not wrapping && idempotencyKey request=="public-test-redeem-1") "only_recorded_late_deposit"
            order<-readOrder ledger capability oid
            require (Bridge.Types.request order==request && status order `elem` ["NeedsReview","Refunding","Refunded"]) "unexpected_refund_state"
            observeOnce manager c ledger >>= requireHealthy
            let did="solana:r3SVnxiooDr24BqMwoo7DYsmLxazreNBpwV4BNE9HTUbMLFj99bnKZ68tN3VmHgsAi6uDGX7LaLoSx5HjWHTFsK"
            receipts<-ledgerAction ledger $ \db -> query db "SELECT order_id,amount,first_seen FROM deposits WHERE id=?" (Only did) :: IO [(Text,Int64,Int64)]
            require (case receipts of [(bound,n,seen)]->bound==oid && n==10000 && seen>deadline order; _->False) "late_deposit_evidence_mismatch"
            _<-createRefund ledger did
            end<- (+1800) <$> epochSeconds
            loop manager c ledger capability oid end Nothing
          _->do
            deadline<- (+1800) <$> epochSeconds
            loop manager c ledger capability oid deadline Nothing
    ) `finally` pause ledger "public_test_acceptance_paused"

output :: ToJSON a => a -> IO ()
output value=LBS.putStrLn (encode value) >> hFlush stdout
requireHealthy :: Value -> IO ()
requireHealthy scan=do
  reviews<-fieldValue "review" scan :: IO [Value]
  streams<-fieldValue "scanners" scan :: IO [Value]
  errors<-mapM (fieldValue "lastError") streams :: IO [Maybe Text]
  require (length streams==3 && null reviews && all (==Nothing) errors) "scanner_not_ready"

loop :: Manager -> Config -> Ledger -> Text -> Text -> Int64 -> Maybe (Text,Maybe Text) -> IO ()
loop manager c ledger capability oid deadline previous=do
  now<-epochSeconds
  require (now<deadline) "public_test_wait_deadline"
  scan<-observeOnce manager c ledger
  requireHealthy scan
  attempts<-pendingAttempts ledger
  preparations<-pendingPreparations ledger
  when (null attempts && null preparations) $ do
    requireBalances manager c ledger
    resumeAfterChecks ledger
  paymentPass manager c ledger (const $ reject "unexpected_remote_backup")
  order<-readOrder ledger capability oid
  let state=(status order,payoutTx order)
  when (previous/=Just state) $ output $ object ["order" .= order,"network" .= ("public L2L Signet / Solana Devnet"::Text)]
  if status order `elem` ["Paid","Refunded"] then do
    _<-observeOnce manager c ledger
    requireBalances manager c ledger
    audit<-auditExport ledger
    output $ object ["completed" .= True,"order" .= order,"audit" .= audit,"balancesMatch" .= True
      ,"scope" .= ("real ledger-driven public-test order; browser signing and full recovery are separate gates"::Text)]
  else do
    require (status order `elem` ["Provisioning","AwaitingDeposit","Ready","Preparing","Paying","Refunding"]) "acceptance_order_requires_review"
    threadDelay 15000000
    loop manager c ledger capability oid deadline (Just state)

-- This acceptance tool has no unrelated pending transactions. The runtime's
-- general reconciliation of in-flight effects remains a separate requirement.
requireBalances :: Manager -> Config -> Ledger -> IO ()
requireBalances manager c ledger=again (2::Int)
 where
  again retries=checkBalances manager c ledger `catch` \(problem::BridgeError)->case problem of
    BridgeError "custody_ledger_balance_mismatch" | retries>0 -> do
      -- A receipt can finalize between the history and balance RPCs. Re-scan
      -- without releasing the pause; persistent differences remain errors.
      pause ledger "public_test_balance_rescan"
      threadDelay 1000000
      observeOnce manager c ledger >>= requireHealthy
      again (retries-1)
    _->throwIO problem

checkBalances :: Manager -> Config -> Ledger -> IO ()
checkBalances manager c ledger=do
  _<-nativeIdentity manager c
  _<-solanaIdentity manager c
  mine<-nativeCall manager c True "getbalances" [] >>= fieldValue "mine"
  native<-mapM (\key->fieldValue key mine >>= either reject pure . nativeAmount) ["trusted","untrusted_pending","immature"]
  response<-solanaCall manager c "getMultipleAccounts" [toJSON [custodyAta c,custodyOwner c]
    ,object ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text)]]
  accounts<-fieldValue "value" response
  (token,owner)<-case accounts of [a,b]->pure(a,b); _->reject "custody_accounts_missing"
  wrapped<-either reject pure (inspectTokenAccount (mint c) (custodyOwner c) token)
  sol<-systemLamports owner
  rows<-ledgerAction ledger $ \db -> query_ db "SELECT asset,account,delta FROM postings" :: IO [(Text,Text,Int64)]
  let observed=[("Native",sum $ map (toInteger . units) native),("Wrapped",toInteger $ units wrapped),("Sol",toInteger $ units sol)]
  require (all (\(asset,n)->sum [toInteger d | (a,account,d)<-rows,a==asset,account/="external"]==n) observed) "custody_ledger_balance_mismatch"
