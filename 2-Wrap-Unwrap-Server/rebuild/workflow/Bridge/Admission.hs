-- Previews grant no authority and never sign, allocate keys, or send.
module Bridge.Admission (checkOrderAdmission,checkSolanaQuoteWith) where
import Bridge.Domain (Direction(..),units,amount)
import qualified Bridge.Domain as D
import Bridge.Wire (OrderRequest(..),PaymentTerms(..),CostLimits(..),PolicySnapshot(..))
import Bridge.Observer (ObserverSettings(..))
import Bridge.Store (StorePolicy(..),OrderLimits(..))
import qualified Bridge.Native as N
import Bridge.NativePayment (previewNativePayment)
import qualified Bridge.Solana as S
import Bridge.Solana (inspectTokenAccount)
import Bridge.SolanaPayment
import Bridge.SolanaHelper
import Bridge.Identity (publicKey)
import Bridge.RPC
import Bridge.Error
import Control.Monad (when)
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager)

checkOrderAdmission :: Manager -> ObserverSettings -> SolanaPolicy -> StorePolicy -> FilePath -> OrderRequest -> IO ()
checkOrderAdmission manager settings config store sdk request = do
  let native=nativeSettings settings; solana=solanaSettings settings
      limits=admissionLimits store; costs=paymentLimits(executionTerms store)
      wrapping=direction request==NativeToWrapped
  require (N.profile native==S.solanaProfile solana && S.mint solana==mint config
    && S.custodyOwner solana==custodyOwner config && S.custodyAta solana==custodyAta config
    && deploymentFingerprint(paymentPolicy $ executionTerms store)==fingerprint config
    && nativeDepth(paymentPolicy $ executionTerms store)==defaultNativeDepth settings
    && savedSolanaFee costs==maxSolFee config && savedSolanaRent costs==maxSolAccountRent config) "payment_profile_mismatch"
  require (input request>=orderMinimum limits && input request<=orderMaximum limits) "amount_outside_limits"
  require (sourceOwner request==Nothing && (wrapping || T.null(refund request))) "invalid_connection_free_order"
  terms<-either reject pure (D.quote $ input request)
  _<-N.nativeIdentity manager native
  previewNativePayment (N.nativeCall manager native) (N.profile native) (defaultNativeDepth settings)
    (savedNativeFee costs) (if wrapping then refund request else recipient request) (if wrapping then D.gross terms else D.net terms)
  _<-S.solanaIdentity manager solana
  when wrapping $ checkSolanaQuoteWith (S.solanaCall manager solana) (invokeUnsignedHelper sdk config) config request

checkSolanaQuoteWith :: SolanaRPC -> (HelperRequest -> IO HelperReply) -> SolanaPolicy -> OrderRequest -> IO ()
checkSolanaQuoteWith call helper c request = do
  require (direction request==NativeToWrapped && sourceOwner request==Nothing) "invalid_solana_owner_binding"
  quote <- either reject pure(D.quote (input request))
  let owner=recipient request
      outgoing=D.net quote
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
