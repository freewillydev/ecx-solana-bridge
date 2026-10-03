module Bridge.Order (OrderTransport(..), createCustomerOrder, createCustomerOrderWith) where

import Bridge.Admission (checkSolanaQuote)
import Bridge.Config
import Bridge.Native
import Bridge.NativePayment
import Bridge.Observer (epochSeconds)
import Bridge.Solana
import Bridge.Types
import Bridge.SolanaPay (payInstruction)
import Bridge.Postgres.Ledger (Ledger,ledgerAction)
import Bridge.Postgres.Order
import Bridge.Postgres.Schema (ordersId)
import Data.Int (Int64)
import Network.HTTP.Client (Manager)
import Data.Text (Text)

data OrderTransport = OrderTransport
  { orderClock :: IO Int64
  , orderAdmission :: OrderRequest -> IO ()
  , orderIdentity :: IO ()
  , orderNative :: NativeRPC
  , orderBackup :: Int64 -> IO ()
  }

realOrderTransport :: Manager -> Config -> (Int64 -> IO ()) -> OrderTransport
realOrderTransport manager c backup = OrderTransport epochSeconds admission identity (nativeCall manager c) backup
 where
  identity=do
    _ <- nativeIdentity manager c
    _ <- solanaIdentity manager c
    now <- epochSeconds
    nativeWalletReadyWith (nativeCall manager c) c now
  admission request=do
    _ <- checkNativeQuote manager c request
    if direction request==NativeToWrapped then checkSolanaQuote manager c request
      else solanaIdentity manager c >> pure ()

-- Every database action is short. Node calls and backup callbacks run only
-- after their preceding durable mutation has committed and released the writer.

createCustomerOrder :: Manager -> Config -> Ledger -> (Int64 -> IO ()) -> Text -> OrderRequest -> IO OrderView
createCustomerOrder manager cfg ledger backup =
  createCustomerOrderWith (realOrderTransport manager cfg backup) cfg ledger

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
