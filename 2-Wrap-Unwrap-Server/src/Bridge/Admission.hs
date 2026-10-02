module Bridge.Admission (checkSolanaQuoteFor, SolanaQuoteCheck(..), checkSolanaQuoteWith) where

import Bridge.Config
import Bridge.RPC
import Bridge.Solana
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.SolanaMessage (publicKey)
import Bridge.Types
import Control.Monad (when)
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Network.HTTP.Client (Manager)

data SolanaQuoteCheck = SolanaQuoteCheck
  { checkedSolanaRole :: !Text, checkedSolanaOwner :: !Text, checkedSolanaAta :: !Text
  , checkedSolanaAmount :: !Amount, checkedSolanaSlot :: !Int64
  , checkedSolanaFee :: !Amount, checkedSolanaRent :: !Amount
  , checkedSolanaDepositFee :: !(Maybe Amount)
  } deriving (Eq,Show,Generic,ToJSON)

checkSolanaQuoteFor :: Manager -> Config -> Quote -> OrderRequest -> IO SolanaQuoteCheck
checkSolanaQuoteFor manager c quote request = do
  _ <- solanaIdentity manager c
  checkSolanaQuoteUsing quote (solanaCall manager c) (invokeUnsignedHelper c) c request

-- This check has no signer, wallet mutation or ledger mutation. Its previews
-- contain only zero signatures and are never returned as deposit instructions.
-- Admission is a current-state check; signing still rechecks the saved order,
-- live accounts and costs. Full fee/rent ceilings are reserved in the ledger.
checkSolanaQuoteWith :: SolanaRPC -> (HelperRequest -> IO HelperReply) -> Config -> OrderRequest -> IO SolanaQuoteCheck
checkSolanaQuoteWith call helper c request = do
  quote <- either reject pure(makeQuote (direction request) (input request))
  checkSolanaQuoteUsing quote call helper c request
checkSolanaQuoteUsing :: Quote -> SolanaRPC -> (HelperRequest -> IO HelperReply) -> Config -> OrderRequest -> IO SolanaQuoteCheck
checkSolanaQuoteUsing quote call helper c request = do
  require (input request>=minInput c && input request<=maxInput c) "amount_outside_limits"
  let wrapping=direction request==NativeToWrapped
      owner=if wrapping then recipient request else refund request
      outgoing=if wrapping then net quote else input request
  require (if wrapping then sourceOwner request==Nothing else sourceOwner request==Just owner) "invalid_solana_owner_binding"
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
  walletBalance <- if wallet==Null then either reject pure (amount 0) else systemLamports wallet
  custodyBalance <- either reject pure (inspectTokenAccount (mint c) (custodyOwner c) custody)
  when wrapping $ require (custodyBalance>=outgoing) "insufficient_custody_tokens"
  -- A new wrap recipient may have no account/SOL. The bridge pays ATA creation.
  -- A redemption source must already own the supported account and gross input.
  when (not wrapping) $ do
    sourceBalance <- either reject pure (inspectTokenAccount (mint c) owner destination)
    require (sourceBalance>=input request) "insufficient_source_tokens"
  rent <- solanaDestinationRent call c owner destination
  require (rent<=maxSolAccountRent c) "solana_rent_above_limit"
  fee <- messageFee slot payout
  require (fee<=maxSolFee c) "solana_fee_above_limit"
  operatingBalance <- systemLamports payer
  require (toInteger (units operatingBalance)>=toInteger (units fee)+toInteger (units rent)) "insufficient_operating_sol"
  (simulation,depositFee) <- if wrapping then pure (payoutTransaction,Nothing) else do
    let depositRequest=HelperRequest False owner (custodyOwner c) (input request) (recentHash recent) "quote-check"
    deposit <- helper depositRequest
    transaction <- either reject pure (validateUnsignedHelperReply c depositRequest deposit)
    require (replySource deposit==replyDestination payout) "helper_ata_mismatch"
    customerFee <- messageFee slot deposit
    require (walletBalance>=customerFee) "insufficient_deposit_fee_sol"
    pure (transaction,Just customerFee)
  (simulationSlot,result) <- call "simulateTransaction" [toJSON (unsignedSimulation simulation),object
    ["encoding" .= ("base64"::Text),"commitment" .= ("confirmed"::Text),"sigVerify" .= False
    ,"replaceRecentBlockhash" .= False,"minContextSlot" .= slot]] >>= contextValue slot
  err <- fieldValue "err" result :: IO Value
  require (err==Null) "solana_simulation_failed"
  checkBlockhashWindow call recent
  pure $ SolanaQuoteCheck (if wrapping then "payout" else "refund") owner (replyDestination payout)
    outgoing simulationSlot fee rent depositFee
 where
  messageFee slot reply = do
    (_,value) <- call "getFeeForMessage" [toJSON (replyMessage reply),object
      ["commitment" .= ("confirmed"::Text),"minContextSlot" .= slot]] >>= contextValue slot
    require (value/=Null) "solana_fee_unavailable"
    fee <- parseValue parseJSON value >>= either reject pure . amount
    require (units fee>0) "invalid_solana_fee_quote"
    pure fee
