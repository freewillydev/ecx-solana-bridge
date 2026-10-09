{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import Bridge.Domain (Direction(..), parseCoins, renderCoins, gross, fee, net)
import qualified Bridge.Domain as Domain
import Bridge.Wire
import Data.Char (isDigit)
import qualified Browser as B
import Codec.QRCode (encodeText, defaultQRCodeOptions, ErrorLevel(M), TextEncoding(Utf8WithoutECI), qrImageSize, toMatrix)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (forM_, forever, join, unless, void, when)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as LBS
import Data.IORef
import Data.List (find)
import Data.Maybe (isJust, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.JS.Foreign.Callback (asyncCallback)
import GHC.JS.Prim (toJSArray)

-- Persist the capability and immutable request before POST. A lost response
-- retries the same request/key, rather than creating another economic order.
data Session = Session { capability :: Text, savedId :: Maybe Text, savedRequest :: Maybe OrderRequest }
  deriving (Eq, Show)
instance ToJSON Session where
  toJSON s = object ["capability" .= capability s, "id" .= savedId s, "request" .= savedRequest s]
instance FromJSON Session where
  parseJSON = withObject "saved order" $ \o -> do
    s <- Session <$> o .: "capability" <*> o .:? "id" <*> o .:? "request"
    unless (validCapability (capability s) && maybe True validId (savedId s)
      && (isJust (savedId s) || isJust (savedRequest s))) (fail "invalid saved order")
    pure s

data State = State { configuration :: Maybe PublicConfiguration, current :: Maybe Session, recent :: [Session], payment :: Text }
data Response = Response Bool Int Text
instance FromJSON Response where
  parseJSON = withObject "fetch response" $ \o -> Response <$> o .: "ok" <*> o .: "status" <*> o .: "body"
newtype Failure = Failure Text deriving (Show)
instance Exception Failure
failWith :: Text -> IO a
failWith = throwIO . Failure
validCapability :: Text -> Bool
validCapability t = T.length t == 64 && T.all (\c -> isDigit c || c >= 'a' && c <= 'f') t
validId :: Text -> Bool
validId t = not (T.null t) && T.length t <= 64 && T.all (\c -> isDigit c || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c `elem` ['-','_']) t

text :: Text -> Text -> IO ()
text key = B.setText (B.js key) . B.js
value :: Text -> IO Text
value key = B.text <$> B.getValue (B.js key)
setValue :: Text -> Text -> IO ()
setValue key = B.setValue (B.js key) . B.js
hidden, disabled :: Text -> Bool -> IO ()
hidden key = B.setBool (B.js key) (B.js "hidden")
disabled key = B.setBool (B.js key) (B.js "disabled")
link :: Text -> Maybe Text -> IO ()
link key = B.setLink (B.js key) . B.js . fromMaybe ""
encodeTextJSON :: ToJSON a => a -> Text
encodeTextJSON = TE.decodeUtf8 . LBS.toStrict . encode
decodeTextJSON :: FromJSON a => Text -> Maybe a
decodeTextJSON = decodeStrict' . TE.encodeUtf8

api :: FromJSON a => IORef State -> Text -> Text -> Maybe OrderRequest -> IO a
api state path method body = do
  token <- maybe "" capability . current <$> readIORef state
  raw <- B.text <$> B.fetchJSON (B.js path) (B.js method) (B.js token) (B.js $ maybe "" encodeTextJSON body)
  case decodeTextJSON raw of
    Just (Response True _ result) -> maybe (failWith "Invalid server response. Contact support.") pure (decodeTextJSON result)
    Just (Response False statusCode result) -> do
      let code = decodeTextJSON result >>= parseMaybe (withObject "error" (\o -> do
            e <- o .:? "error"; maybe (o .:? "reason") (pure . Just) e))
      failWith $ customerError $ fromMaybe ("Request failed (" <> T.pack (show statusCode) <> ").") (join code)
    Nothing -> failWith "Invalid server response. Contact support."

customerError :: Text -> Text
customerError code = fromMaybe code $ lookup code
  [ ("network_error", "Network request failed. Refresh before sending again.")
  , ("rpc_error_-5", "Check the native destination or refund address for the configured network.")
  , ("rpc_error_-4", "The native node could not prepare this quote. Try later or contact support.")
  , ("native_admission_funds_unavailable", "The bridge needs more native liquidity before it can quote this transfer.")
  , ("insufficient_custody_tokens", "The bridge needs more wrapped-token liquidity. Try later.")
  , ("insufficient_operating_sol", "The bridge needs more SOL for transaction fees. Try later.")
  , ("invalid_public_key", "Enter a valid Solana address.")
  , ("amount_outside_limits", "Enter an amount within the displayed limits.")
  , ("deposit_window_closed", "This order has expired. Do not pay; create a new order.")
  , ("payouts_paused", "The bridge is paused. Refresh for its current status.")
  , ("scanners_not_fresh", "Waiting for fresh chain observations. Try again shortly.") ]

controls :: IORef State -> Bool -> IO ()
controls state busy = do
  s <- readIORef state
  let hasId = isJust (current s >>= savedId)
      locked = hasId || isJust (current s >>= savedRequest)
      accepting = maybe False (available . pubAvailability) (configuration s)
  disabled "create" (busy || not accepting || hasId)
  forM_ ["refresh","copy"] $ \key -> disabled key (busy || not hasId)
  forM_ ["new","copy-payment","history"] $ \key -> disabled key busy
  forM_ ["direction","amount","recipient","refund"] $ \key -> disabled key (busy || locked)

attempt :: IORef State -> MVar () -> IO () -> IO ()
attempt state gate work = do
  acquired <- tryTakeMVar gate
  forM_ acquired $ \() -> (do
    text "error" ""
    controls state True
    work `catch` (\(e :: SomeException) -> text "error" $ case fromException e of
      Just (Failure message) -> message
      Nothing -> "Request failed. Refresh before sending again."))
    `finally` (putMVar gate () >> controls state False)

persist :: IORef State -> IO ()
persist state = do
  s <- readIORef state
  let history = take 20 $ case current s of
        Just entry | isJust (savedId entry) -> entry : filter ((/= savedId entry) . savedId) (recent s)
        _ -> recent s
  modifyIORef' state $ \old -> old{recent=history}
  saved <- B.writeStorage (B.js "ecx-current-v2") (B.js $ maybe "" encodeTextJSON (current s))
  savedHistory <- B.writeStorage (B.js "ecx-orders-v2") (B.js $ encodeTextJSON history)
  unless (saved && savedHistory) $ text "message" "Device storage unavailable. Copy your recovery link before leaving."
  labels <- toJSArray $ map (B.js . T.take 12 . fromMaybe "" . savedId) history
  values <- toJSArray $ map (B.js . fromMaybe "" . savedId) history
  B.historyOptions labels values (B.js $ fromMaybe "" $ current s >>= savedId)
  hidden "history-field" (null history)

readDirection :: IO Direction
readDirection = do
  d <- value "direction"
  case d of "NativeToWrapped" -> pure NativeToWrapped; "WrappedToNative" -> pure WrappedToNative; _ -> failWith "Invalid direction."
preview :: IO ()
preview = do
  _ <- readDirection
  a <- value "amount"
  case parseCoins a >>= Domain.quote of
    Right q -> text "fee" (renderCoins $ fee q) >> text "net" (renderCoins $ net q)
    Left _ -> text "fee" "—" >> text "net" "—"
showDirection :: IO ()
showDirection = do
  wrapping <- (==NativeToWrapped) <$> readDirection
  hidden "refund-field" (not wrapping)
  B.setBool (B.js "refund") (B.js "required") wrapping
  hidden "refund-note" wrapping
  text "destination-label" (if wrapping then "Solana destination address" else "Native destination address")
  preview
showRequest :: OrderRequest -> IO ()
showRequest r = do
  setValue "direction" (T.pack $ show $ direction r)
  setValue "amount" (renderCoins $ input r)
  setValue "recipient" (recipient r)
  setValue "refund" (refund r)
  showDirection

solanaExplorer :: PublicConfiguration -> Text -> Text -> IO Text
solanaExplorer cfg kind identifier = do
  encoded <- B.text <$> B.urlEncode (B.js identifier)
  pure $ "https://explorer.solana.com/" <> kind <> "/" <> encoded <> if pubSolanaCluster cfg=="mainnet-beta" then "" else "?cluster=devnet"
loadConfig :: IORef State -> IO ()
loadConfig state = do
  cfg <- api state "/api/v1/config" "GET" Nothing
  modifyIORef' state $ \s -> s{configuration=Just cfg}
  text "network" $ case pubProfile cfg of
    L2LSignetDevnet -> "L2L Signet / Solana Devnet"
    ECXBetanetDevnet -> "ECX betanet / Solana Devnet"
    CanonicalBeta -> "ECX / Solana Mainnet"
  text "network-note" $ if pubSolanaCluster cfg=="devnet"
    then "Test coins only. Select Devnet in your Solana Pay wallet; the transfer URI does not select a network."
    else "Verify the configured networks before paying."
  text "mint" (pubMint cfg)
  solanaExplorer cfg "address" (pubMint cfg) >>= link "mint-link" . Just
  let links = pubLinks cfg
  link "support-link" (supportUrl links)
  link "jupiter-link" (jupiterUrl links)
  link "orca-link" (orcaUrl links)
  hidden "trading" (not $ isJust (jupiterUrl links) || isJust (orcaUrl links))
  text "availability" $ if available (pubAvailability cfg) then "Bridge is accepting orders."
    else "Deposits paused: " <> customerError (reason $ pubAvailability cfg)
  text "limits" $ "Amount limits: " <> renderCoins (pubMinInput cfg) <> "–" <> renderCoins (pubMaxInput cfg)
  hidden "report-data" (not $ isJust $ pubReport cfg)
  text "report-note" "Report unavailable."
  forM_ (pubReport cfg) $ \report -> do
    date<-B.text <$> B.dateText (fromIntegral $ reportGeneratedAt report)
    custodyDate<-maybe (pure "not observed") (fmap B.text . B.dateText . fromIntegral) (reportCustodyAt report)
    text "report-note" $ "Ledger report: "<>date<>". Custody checked: "<>custodyDate
      <>if reportCustodyFresh report then "." else ". Reserves are stale or unverified; they are not a current balance guarantee."
    text "report-wraps" (T.pack $ show $ reportWraps24h report)
    text "report-unwraps" (T.pack $ show $ reportUnwraps24h report)
    text "report-undated" $ if reportUndatedTransfers report==0 then "" else
      T.pack(show $ reportUndatedTransfers report)<>" older/zero-fee transfers lack a settlement time and are excluded from the 24-hour counts."
    forM_ (reportAssets report) $ \asset -> do
      let key="report-"<>T.pack(show $ reportAsset asset)
          places=if reportAsset asset==Domain.Sol then 9 else 8
          coins raw=let (sign,digits)=if T.isPrefixOf "-" raw then ("-",T.drop 1 raw) else ("",raw)
                        padded=T.justifyRight (places+1) '0' digits
                        (whole,fraction)=T.splitAt (T.length padded-places) padded
                        trimmed=T.dropWhileEnd (=='0') fraction
                    in sign<>whole<>if T.null trimmed then "" else "."<>trimmed
      text (key<>"-reserve") (maybe "Unknown" coins $ reportReserve asset)
      text (key<>"-fees") (coins $ reportFees asset)
      text (key<>"-float") (coins $ reportFloat asset)
      text (key<>"-held") (coins $ reportHeld asset)
      text (key<>"-liability") (coins $ reportLiability asset)

clearPayment :: IORef State -> IO ()
clearPayment state = do
  modifyIORef' state $ \s -> s{payment=""}
  link "payment-link" Nothing
  forM_ ["qr","copy-payment"] $ \key -> hidden key True
  text "deposit-address" ""
showQR :: Text -> IO ()
showQR instruction = case encodeText (defaultQRCodeOptions M) Utf8WithoutECI instruction of
  Nothing -> text "message" "QR unavailable. Copy the payment instructions below."
  Just image -> do
    B.beginQR (qrImageSize image)
    forM_ (zip [0..] $ toMatrix True False image) $ \(y,row) ->
      forM_ (zip [0..] row) $ \(x,black) -> when black (B.qrModule x y)
    hidden "qr" False

refresh :: IORef State -> IO ()
refresh state = do
  clearPayment state
  s <- readIORef state
  forM_ (current s >>= savedId) $ \oid -> do
    encoded <- B.text <$> B.urlEncode (B.js oid)
    let path = "/api/v1/orders/" <> encoded
    o <- api state path "GET" Nothing
    unless (orderId o==oid) $ failWith "Order identity mismatch. Contact support."
    showRequest (request o)
    let refunding = status o `elem` ["Refunded","Refunding"]
        q = quote o
    text "fee" $ if refunding then "0.00000000" else renderCoins (fee q)
    text "net" $ if refunding then "—" else renderCoins (net q)
    text "status" $ fromMaybe (status o) $ lookup (status o)
      [ ("Provisioning","Preparing instructions."), ("AwaitingDeposit","Waiting for payment and confirmations.")
      , ("Ready","Payment verified. Payout queued."), ("Preparing","Preparing payout.")
      , ("Paying","Payout is being confirmed."), ("Paid","Transfer complete.")
      , ("Refunding","Refund is being processed."), ("Refunded","Deposit refunded.")
      , ("ExpiredUnfunded","Order expired. Do not pay."), ("NeedsReview","Operator review required. Do not send another payment.") ]
    text "order-short" ("Order " <> orderId o)
    text "order-summary" $ if refunding then "Refunds return the deposit to its verified refund destination with no bridge fee. The refund transaction shows the actual amount and recipient."
      else "Send " <> renderCoins (gross q) <> "; receive " <> renderCoins (net q) <> ". Fee " <> renderCoins (fee q) <> ". Destination: " <> recipient (request o)
    hidden "order-details" False
    now <- B.now
    let awaiting = status o=="AwaitingDeposit" && now < fromIntegral (deadline o)
    expiry <- B.text <$> B.dateText (fromIntegral $ deadline o)
    text "deposit-deadline" $ if awaiting then "Pay before " <> expiry <> ". Send the exact amount once." else ""
    forM_ (configuration s) $ \cfg -> do
      when (awaiting && available (pubAvailability cfg)) $ forM_ (depositInstruction o) $ \instruction -> do
        paymentText <- if direction (request o)==NativeToWrapped then pure instruction else do
          instructions <- api state (path <> "/transaction") "POST" Nothing
          let reference = T.stripPrefix "solana-pay:" instruction
              expected = "solana:" <> pubCustodyOwner cfg <> "?amount=" <> renderCoins (gross q)
                <> "&spl-token=" <> pubMint cfg <> "&reference=" <> instructionReference instructions <> "&label=ECX%20Bridge"
          unless (reference==Just (instructionReference instructions) && instructionMint instructions==pubMint cfg
            && instructionAmount instructions==gross q && instructionUri instructions==expected) $
            failWith "Payment instructions do not match this order. Contact support."
          link "payment-link" (Just $ instructionUri instructions)
          pure (instructionUri instructions)
        modifyIORef' state $ \old -> old{payment=paymentText}
        text "deposit-address" paymentText
        hidden "copy-payment" False
        showQR paymentText
      text "payout-link" $ if refunding then "View refund transaction" else "View payout transaction"
      url <- case payoutTx o of
        Nothing -> pure Nothing
        Just txid -> if (if status o=="Refunded" then direction (request o)==NativeToWrapped else direction (request o)==WrappedToNative)
          then do encodedTx <- B.text <$> B.urlEncode (B.js txid); pure ((<> encodedTx) <$> nativeExplorerBase (pubLinks cfg))
          else Just <$> solanaExplorer cfg "tx" txid
      link "payout-link" url

createOrder :: IORef State -> IO ()
createOrder state = do
  s <- readIORef state
  cfg <- maybe (failWith "Deployment configuration unavailable.") pure (configuration s)
  unless (available $ pubAvailability cfg) $ failWith "Deposits are paused."
  entry <- case current s of
    Just existing | isJust (savedRequest existing) -> pure existing
    _ -> do
      d <- readDirection
      quantity <- value "amount" >>= either (const $ failWith "Enter a decimal amount with at most eight places.") pure . parseCoins
      unless (quantity>=pubMinInput cfg && quantity<=pubMaxInput cfg) $ failWith "Amount outside displayed limits."
      destination <- T.strip <$> value "recipient"
      refundAddress <- if d==NativeToWrapped then T.strip <$> value "refund" else pure ""
      cap <- B.text <$> B.randomHex
      key <- B.text <$> B.randomHex
      pure $ Session cap Nothing (Just $ OrderRequest d quantity destination refundAddress Nothing key)
  modifyIORef' state $ \old -> old{current=Just entry}
  persist state
  saved <- api state "/api/v1/orders" "POST" (savedRequest entry)
  unless (Just (request saved)==savedRequest entry) $ failWith "Saved order terms changed. Contact support."
  modifyIORef' state $ \old -> old{current=Just entry{savedId=Just $ orderId saved}}
  persist state
  refresh state

closeCopy :: IO ()
closeCopy = setValue "copy-text" "" >> hidden "manual-copy" True
copyText :: Text -> Text -> IO ()
copyText content confirmation = unless (T.null content) $ do
  setValue "copy-text" content
  hidden "manual-copy" False
  B.selectText (B.js "copy-text")
  copied <- B.clipboard (B.js content)
  text "message" $ if copied then confirmation <> " Selected text is also available below."
    else "Clipboard access is unavailable. Copy the selected text below."
newOrder :: IORef State -> IO ()
newOrder state = do
  persist state
  modifyIORef' state $ \s -> s{current=Nothing}
  clearPayment state
  forM_ ["amount","recipient","refund"] $ \key -> setValue key ""
  showDirection
  persist state
  hidden "order-details" True
  closeCopy
  text "status" "No order yet."
  forM_ ["error","message"] $ \key -> text key ""

main :: IO ()
main = do
  stored <- B.text <$> B.readStorage (B.js "ecx-current-v2")
  history <- B.text <$> B.readStorage (B.js "ecx-orders-v2")
  fragment <- B.takeFragment
  oid <- B.text <$> B.fragmentField fragment (B.js "order")
  cap <- B.text <$> B.fragmentField fragment (B.js "cap")
  let session = if validId oid && validCapability cap then Just (Session cap (Just oid) Nothing)
        else decodeTextJSON stored >>= id
      saved = take 20 $ filter (isJust . savedId) $ fromMaybe [] (decodeTextJSON history)
  state <- newIORef $ State Nothing session saved ""
  gate <- newMVar ()
  let on key event action = asyncCallback (attempt state gate action) >>= B.listen (B.js key) (B.js event)
      reload = loadConfig state >> refresh state
  on "order-form" "submit" (createOrder state)
  on "direction" "change" showDirection
  on "amount" "input" preview
  on "refresh" "click" reload
  on "new" "click" (newOrder state)
  on "close-copy" "click" closeCopy
  on "copy-payment" "click" $ readIORef state >>= \s -> copyText (payment s) "Payment instructions copied."
  on "copy" "click" $ do
    s <- readIORef state
    forM_ (current s) $ \entry -> forM_ (savedId entry) $ \identifier -> do
      base <- B.text <$> B.origin
      encoded <- B.text <$> B.urlEncode (B.js identifier)
      copyText (base <> "/#order=" <> encoded <> "&cap=" <> capability entry) "Private recovery link copied."
  on "history" "change" $ do
    selected <- value "history"
    s <- readIORef state
    case find ((==Just selected) . savedId) (recent s) of
      Nothing -> persist state
      Just entry -> do
        closeCopy
        modifyIORef' state $ \old -> old{current=Just entry}
        persist state
        refresh state
  showDirection
  forM_ (session >>= savedRequest) showRequest
  persist state
  attempt state gate reload
  void $ forkIO $ forever $ threadDelay 15000000 >> attempt state gate reload
