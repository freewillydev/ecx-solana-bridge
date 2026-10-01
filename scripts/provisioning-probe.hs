{-# LANGUAGE OverloadedStrings #-}
-- Actual Signet/Devnet quote provisioning; no source deposit or payment is sent.
-- The interrupt mode exits immediately after the real wallet allocates an
-- address, before that address can be recorded or returned as an instruction.
import Bridge.Config
import Bridge.Ledger
import Bridge.Observer
import Bridge.Order
import Bridge.RPC
import Bridge.Reconciliation
import Bridge.Types
import Control.Exception (finally)
import Control.Monad (when)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Database.SQLite.Simple
import System.Environment (getArgs)
import System.Exit (ExitCode(..))
import System.IO (hFlush,stdout)
import System.Posix.Process (exitImmediately)

main :: IO ()
main=do
  args<-getArgs
  (path,privateRequest,mode)<-case args of
    [p,r,m] | m `elem` ["interrupt","recover","redeem","expire","status"] -> pure(p,r,m)
    _->fail "provisioning-probe CONFIG PRIVATE_REQUEST interrupt|recover|redeem|expire|status"
  configured<-loadConfig path
  require (profile configured==L2LSignetDevnet && not (backupRequired configured)
    && fingerprint configured=="027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8") "dedicated_public_test_only"
  -- A real one-minute, zero-grace test quote. The running configuration is not
  -- changed; this exact deadline is durably saved and never reset on recovery.
  let c=configured{quoteSeconds=60,confirmationGraceSeconds=0}
      owner="HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg"
      native="tb1q8frp8q5wu4lpr8f6426ndxwuagymygl9w0nn3m"
  saved<-BS.readFile privateRequest >>= either fail pure . eitherDecodeStrict'
  capability<-fieldValue "capability" saved
  request<-fieldValue "request" saved
  let wrapping=direction request==NativeToWrapped
  require (units (input request)==10000 && if wrapping
    then idempotencyKey request=="provision-wrap-1" && recipient request==owner && refund request==native && sourceOwner request==Nothing
    else idempotencyKey request=="provision-redeem-1" && recipient request==native && refund request==owner && sourceOwner request==Just owner) "unexpected_provisioning_request"
  manager<-newRpcManager
  withLedger (dbPath c) (fingerprint c) $ \ledger -> (do
    orders<-ledgerAction ledger $ \db -> query_ db "SELECT idempotency_key,status FROM orders" :: IO [(Text,Text)]
    require (length orders<=5 && all (\(key,st)->
      (key `elem` ["public-test-wrap-1","public-test-redeem-1","public-test-redeem-2"] && st `elem` ["Paid","Refunded"])
      || key==idempotencyKey request
      || (key `elem` ["provision-wrap-1","provision-redeem-1"] && st=="ExpiredUnfunded")) orders) "unexpected_existing_test_orders"
    pendingAttempts ledger >>= \xs->require (null xs) "pending_payment_must_resolve_first"
    pendingPreparations ledger >>= \xs->require (null xs) "pending_payment_must_resolve_first"
    prior<-findOrder ledger c capability request
    let transport=realOrderTransport manager c (const $ reject "unexpected_remote_backup")
        nativeCall wallet method params=do
          require (method `elem` ["getwalletinfo","getaddressesbylabel","getnewaddress","getaddressinfo"]) "unexpected_provisioning_rpc"
          result<-orderNative transport wallet method params
          when (mode=="interrupt" && method=="getnewaddress") $ do
            output $ object ["forcedExitAfterActualAddressAllocation" .= True,"instructionReturned" .= False]
            exitImmediately (ExitFailure 75)
          pure result
    order<-case mode of
      "status"->existing prior
      "expire"->do
        current<-existing prior
        now<-epochSeconds
        require (now>deadline current) "quote_not_expired_yet"
        expireQuotes ledger now
        readOrder ledger capability (orderId current)
      _->do
        require (if mode=="redeem" then not wrapping else wrapping) "wrong_provisioning_mode"
        when (mode=="interrupt") $ require (prior==Nothing) "interrupt_must_not_repeat"
        when (mode=="recover") $ require (prior/=Nothing) "missing_interrupted_order"
        scans<-observeOnce manager c ledger
        reviews<-fieldValue "review" scans :: IO [Value]
        require (null reviews) "scanner_review_required"
        custody<-reconcileCustody manager c ledger
        failure<-fieldValue "lastError" custody :: IO (Maybe Text)
        require (failure==Nothing) "custody_not_reconciled"
        resumeAfterChecks ledger
        createCustomerOrderWith transport{orderNative=nativeCall} c ledger capability request
    visible<-exposeOrder ledger False capability (orderId order)
    meta<-ledgerAction ledger $ \db -> query db "SELECT instruction_issued,instruction_sequence,grace_deadline FROM orders WHERE id=?" (Only $ orderId order) :: IO [(Bool,Maybe Int64,Int64)]
    claims<-ledgerAction ledger $ \db -> query db "SELECT label FROM native_allocations WHERE order_id=?" (Only $ orderId order) :: IO [Only Text]
    addressCount<-case claims of
      []->pure (0::Int)
      [Only label]->do
        result<-orderNative transport True "getaddressesbylabel" [toJSON label]
        parseValue (withObject "label addresses" $ pure . length) result
      _->reject "duplicate_allocation_claim"
    audit<-auditExportWithBudget ledger c
    output $ object ["order" .= visible,"instructionMeta" .= meta,"addressesForOrderLabel" .= addressCount
      ,"audit" .= audit,"broadcast" .= False,"publicHttpEnabled" .= False,"ledgerSchema" .= schemaVersion]
    ) `finally` pause ledger "public_test_provisioning_paused"
 where
  existing=maybe (reject "provisioning_order_not_found") pure
  output value=LBS.putStrLn (encode value) >> hFlush stdout
