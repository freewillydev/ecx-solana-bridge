module Bridge.Postgres.Provisioning (createCustomerOrder, createCustomerOrderWith) where

import Bridge.Config
import Bridge.Types
import Bridge.SolanaPay (payInstruction)
import Bridge.Admission (checkSolanaQuoteFor)
import Bridge.NativePayment (checkNativeQuote)
import Bridge.Solana (solanaIdentity)
import Control.Monad (when)
import Bridge.Native (recoverNativeAddressWith)
import Bridge.Order (OrderTransport(..), realOrderTransport)
import Bridge.Postgres.Ledger (Ledger, ledgerAction)
import Bridge.Postgres.Order
import Bridge.Postgres.Schema (ordersId)
import Network.HTTP.Client (Manager)
import Data.Int (Int64)
import Data.Text (Text)

-- Uses the existing real identity/admission/native adapter. It is not wired into
-- the paying worker until observation, reconciliation and payment conversion.
createCustomerOrder :: Manager -> Config -> Ledger -> (Int64 -> IO ()) -> Text -> OrderRequest -> IO OrderView
createCustomerOrder manager cfg ledger backup = createCustomerOrderWith transport cfg ledger
 where
  transport=(realOrderTransport manager cfg backup) {orderAdmission= \request->do
    _ <- checkNativeQuote manager cfg request
    fee <- either reject pure(feeFor 100 $ input request)
    netAmount <- either reject pure(amount $ toInteger(units $ input request)-toInteger(units fee))
    _ <- solanaIdentity manager cfg
    when (direction request==NativeToWrapped) $ checkSolanaQuoteFor manager cfg (Quote (input request) fee netAmount) request >> pure ()}

createCustomerOrderWith :: OrderTransport -> Config -> Ledger -> Text -> OrderRequest -> IO OrderView
createCustomerOrderWith transport cfg ledger capability requested = do
  previous <- findSavedOrder ledger cfg capability requested
  now <- orderClock transport
  expireQuotes ledger now
  stored <- case previous of
    Just old->pure old
    Nothing->do
      checkIntakeReady ledger now
      orderAdmission transport requested
      admitted <- orderClock transport
      checkIntakeReady ledger admitted
      createOrder ledger cfg admitted capability requested
  cap <- either reject pure (capabilityHash capability)
  let oid=ordersId stored
  order <- ledgerAction ledger (\connection->readOrderC connection cap oid)
  visible <- exposeOrder ledger (backupRequired cfg) capability oid
  if depositInstruction visible/=Nothing then pure visible else do
    orderIdentity transport
    case depositInstruction order of
      Just _->pure ()
      Nothing->case direction requested of
        NativeToWrapped->do
          started <- orderClock transport
          (fresh,label) <- claimNativeAllocation ledger cfg started capability oid
          address <- recoverNativeAddressWith (orderNative transport) cfg started fresh label
          recordNativeInstruction ledger capability oid label address
        WrappedToNative->do
          started <- orderClock transport
          checkIntakeReady ledger started
          require (started<=deadline order) "deposit_window_closed"
          instruction <- either reject pure(payInstruction oid)
          bindInstruction ledger oid instruction
    coverage <- instructionBackup ledger (backupRequired cfg) capability oid
    mapM_ (orderBackup transport) coverage
    issued <- orderClock transport
    issueInstruction ledger cfg issued capability oid
