module Bridge.Admission (checkOrderAdmission, checkNativeQuoteWith, checkSolanaQuoteWith) where

import Bridge.Config
import Bridge.Native
import Bridge.NativePayment
import Bridge.RPC
import Bridge.Solana
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.SolanaMessage (publicKey)
import Bridge.Types
import Control.Monad (forM, when)
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager)

-- Neither preflight grants signing or send authority. Identity is checked for
-- both chains; native policy covers a wrap refund or the redemption payout.
checkOrderAdmission :: Manager -> Config -> OrderRequest -> IO ()
checkOrderAdmission manager c request = do
  _ <- nativeIdentity manager c
  checkNativeQuoteWith (nativeCall manager c) c request
  _ <- solanaIdentity manager c
  when (direction request==NativeToWrapped) $
    checkSolanaQuoteWith (solanaCall manager c) (invokeUnsignedHelper c) c request

-- The selected daemon applies its actual dust/fee policy. Use an EXISTING
-- owned address for change, no input locks, no key allocation and no signer.
-- Discard the unsigned draft: it is neither a reservation nor a payment.
checkNativeQuoteWith :: NativeRPC -> Config -> OrderRequest -> IO ()
checkNativeQuoteWith call cfg request = do
  require (input request>=minInput cfg && input request<=maxInput cfg) "amount_outside_limits"
  q <- either reject pure (makeQuote (direction request) (input request))
  let wrapping=direction request==NativeToWrapped
      destination=if wrapping then refund request else recipient request
      quantity=if wrapping then gross q else net q
      depth=nativeConfirmations cfg
  require (depth>0 && depth<=1008 && units (maxNativeFee cfg)>0) "invalid_native_plan"
  script <- validateNativeRecipientWith call destination
  coins <- call True "listunspent" [toJSON depth,toJSON (9999999::Int),toJSON ([]::[Text]),Bool False
    ,object ["maximumCount" .= (100::Int)]] >>= parseValue parseJSON :: IO [Value]
  require (length coins<=100) "native_admission_utxo_bounds"
  addresses <- forM coins $ parseValue $ withObject "unspent" $ \o -> do
    safe <- o .: "safe"; spendable <- o .: "spendable"; solvable <- o .: "solvable"
    confirmations <- o .: "confirmations"
    address <- o .:? "address"
    pure $ if safe && spendable && solvable && confirmations>=depth then address else Nothing
  change <- case [a | Just a<-addresses] of a:_ -> pure a; [] -> reject "native_admission_funds_unavailable"
  changeScript <- ownedScript call change
  require (script/=changeScript) "bridge_owned_destination"
  let plan=NativePlan (profile cfg) destination script change changeScript quantity depth (maxNativeFee cfg)
  _ <- fundNativeDraftWith False call plan
  locks <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
  require (null locks) "native_preparation_locks_require_review"

-- This check has no signer, wallet mutation or ledger mutation. Its previews
-- contain only zero signatures and are never returned as deposit instructions.
-- Admission is a current-state check; signing still rechecks the saved order,
-- live accounts and costs. Full fee/rent ceilings are reserved in the ledger.
checkSolanaQuoteWith :: SolanaRPC -> (HelperRequest -> IO HelperReply) -> Config -> OrderRequest -> IO ()
checkSolanaQuoteWith call helper c request = do
  require (direction request==NativeToWrapped && sourceOwner request==Nothing) "invalid_solana_owner_binding"
  quote <- either reject pure(makeQuote (direction request) (input request))
  require (input request>=minInput c && input request<=maxInput c) "amount_outside_limits"
  let owner=recipient request
      outgoing=net quote
  require (T.length owner<=44) "invalid_public_key"
  _ <- either reject pure (publicKey owner)
  require (owner `notElem` [custodyOwner c,custodyAta c,mint c]) "bridge_owned_destination"
  recent <- getRecentBlockhash call
  let payoutRequest=HelperRequest True (custodyOwner c) owner outgoing (recentHash recent) "quote-check"
  payout <- helper payoutRequest
  payoutTransaction <- either reject pure (validateUnsignedHelperReply c payoutRequest payout)
  require (replyDestination payout `notElem` [custodyAta c,custodyOwner c,mint c,owner]) "invalid_solana_destination"
  (slot,values) <- call "getMultipleAccounts"
    [toJSON [owner,replyDestination payout,custodyAta c,custodyOwner c],object
      ["commitment" .= ("confirmed"::Text),"encoding" .= ("jsonParsed"::Text),"minContextSlot" .= recentSlot recent]]
        >>= contextValue (recentSlot recent)
  accounts <- parseValue parseJSON values
  (wallet,destination,custody,payer) <- case accounts of
    [a,b,d,e] -> pure (a,b,d,e)
    _ -> reject "solana_account_snapshot_incomplete"
  when (wallet/=Null) $ systemLamports wallet >> pure ()
  custodyBalance <- either reject pure (inspectTokenAccount (mint c) (custodyOwner c) custody)
  require (custodyBalance>=outgoing) "insufficient_custody_tokens"
  rent <- solanaDestinationRent call c owner destination
  require (rent<=maxSolAccountRent c) "solana_rent_above_limit"
  fee <- messageFee slot payout
  require (fee<=maxSolFee c) "solana_fee_above_limit"
  operatingBalance <- systemLamports payer
  require (toInteger (units operatingBalance)>=toInteger (units fee)+toInteger (units rent)) "insufficient_operating_sol"
  (_,result) <- call "simulateTransaction" [toJSON (unsignedSimulation payoutTransaction),object
    ["encoding" .= ("base64"::Text),"commitment" .= ("confirmed"::Text),"sigVerify" .= False
    ,"replaceRecentBlockhash" .= False,"minContextSlot" .= slot]] >>= contextValue slot
  err <- fieldValue "err" result :: IO Value
  require (err==Null) "solana_simulation_failed"
  checkBlockhashWindow call recent
 where
  messageFee slot reply = do
    (_,value) <- call "getFeeForMessage" [toJSON (replyMessage reply),object
      ["commitment" .= ("confirmed"::Text),"minContextSlot" .= slot]] >>= contextValue slot
    require (value/=Null) "solana_fee_unavailable"
    fee <- parseValue parseJSON value >>= either reject pure . amount
    require (units fee>0) "invalid_solana_fee_quote"
    pure fee
