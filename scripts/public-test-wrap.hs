{-# LANGUAGE OverloadedStrings #-}
-- A single, explicitly scoped real Signet -> Devnet ledger acceptance order.
-- The client request/capability are private inputs; no browser/API gate is opened.
import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.Observer
import Bridge.RPC
import Bridge.Settlement
import Bridge.Solana
import Bridge.SolanaPayment (systemLamports)
import Bridge.Types
import Control.Concurrent (threadDelay)
import Control.Exception (finally)
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
  (path,privateRequest,mode)<-case args of [a,b,m] | m `elem` ["prepare","run","status"] -> pure(a,b,m); _->fail "public-test-wrap CONFIG PRIVATE_REQUEST prepare|run|status"
  c<-loadConfig path
  require (profile c==L2LSignetDevnet && not (backupRequired c)
    && fingerprint c=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "different_public_test_deployment"
  saved<-BS.readFile privateRequest >>= either fail pure . eitherDecodeStrict'
  capability<-fieldValue "capability" saved
  request<-fieldValue "request" saved
  require (direction request==NativeToWrapped && units (input request)==10000
    && recipient request=="HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg"
    && idempotencyKey request=="public-test-wrap-1" && sourceOwner request==Nothing) "unexpected_public_test_order"
  manager<-newRpcManager
  withLedger (dbPath c) (fingerprint c) $ \ledger -> (do
    orders<-ledgerAction ledger $ \db -> query_ db "SELECT id,idempotency_key FROM orders" :: IO [(Text,Text)]
    require (null orders || map snd orders==[idempotencyKey request]) "one_acceptance_order_only"
    case mode of
      "prepare" -> do
        scan<-observeOnce manager c ledger
        requireHealthy scan
        requireBalances manager c ledger
        _<-validateNativeRecipient manager c (refund request)
        tester<-nativeCall manager c{nativeWallet="ecx-bridge-tester"} True "getaddressinfo" [toJSON $ refund request]
        owned<-fieldValue "ismine" tester
        require owned "refund_must_belong_to_test_wallet"
        resumeAfterChecks ledger
        now<-epochSeconds
        order<-createOrder ledger c now capability request
        case depositInstruction order of
          Nothing->newNativeAddress manager c (orderId order) >>= bindInstruction ledger (orderId order)
          Just _->pure ()
        exposeOrder ledger False capability (orderId order) >>= output
      _ -> do
        oid<-case orders of [(i,_)]->pure i; _->reject "prepare_order_first"
        if mode=="status" then readOrder ledger capability oid >>= output else do
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
  if status order=="Paid" then do
    _<-observeOnce manager c ledger
    requireBalances manager c ledger
    audit<-auditExport ledger
    output $ object ["completed" .= True,"order" .= order,"audit" .= audit,"balancesMatch" .= True
      ,"scope" .= ("one real ledger-driven wrap; browser signing, reverse direction and recovery are separate gates"::Text)]
  else do
    require (status order `elem` ["Provisioning","AwaitingDeposit","Ready","Preparing","Paying"]) "acceptance_order_requires_review"
    threadDelay 15000000
    loop manager c ledger capability oid deadline (Just state)

-- This acceptance tool has no unrelated pending transactions. The runtime's
-- general reconciliation of in-flight effects remains a separate requirement.
requireBalances :: Manager -> Config -> Ledger -> IO ()
requireBalances manager c ledger=do
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
