module Bridge.Order (OrderTransport(..), realOrderTransport, createCustomerOrder, createCustomerOrderWith) where

import Bridge.Admission
import Bridge.Config
import Bridge.Deposit (solanaDepositMemo)
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment
import Bridge.Observer (epochSeconds)
import Bridge.Solana
import Bridge.Types
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

createCustomerOrder :: Manager -> Config -> Ledger -> (Int64 -> IO ()) -> Text -> OrderRequest -> IO OrderView
createCustomerOrder manager c ledger backup = createCustomerOrderWith (realOrderTransport manager c backup) c ledger

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
    _ <- checkSolanaQuote manager c request
    pure ()

-- Every database action is short. Node calls and backup callbacks run only
-- after their preceding durable mutation has committed and released the writer.
createCustomerOrderWith :: OrderTransport -> Config -> Ledger -> Text -> OrderRequest -> IO OrderView
createCustomerOrderWith transport c ledger capability requested = do
  previous <- findOrder ledger c capability requested
  now <- orderClock transport
  expireQuotes ledger now
  order <- case previous of
    Just old -> readOrder ledger capability (orderId old)
    Nothing -> do
      checkIntakeReady ledger now
      orderAdmission transport requested
      admitted <- orderClock transport
      checkIntakeReady ledger admitted
      createOrder ledger c admitted capability requested
  let oid=orderId order
  visible <- exposeOrder ledger (backupRequired c) capability oid
  if depositInstruction visible/=Nothing then pure visible else do
    orderIdentity transport
    case depositInstruction order of
      Just _ -> pure ()
      Nothing -> case direction requested of
        NativeToWrapped -> do
          started <- orderClock transport
          (fresh,label) <- claimNativeAllocation ledger c started capability oid
          address <- recoverNativeAddressWith (orderNative transport) c started fresh label
          recordNativeInstruction ledger capability oid label address
        WrappedToNative -> do
          started <- orderClock transport
          checkIntakeReady ledger started
          require (started<=deadline order) "deposit_window_closed"
          bindInstruction ledger oid (solanaDepositMemo c oid)
    coverage <- instructionBackup ledger (backupRequired c) capability oid
    mapM_ (orderBackup transport) coverage
    issued <- orderClock transport
    issueInstruction ledger c issued capability oid
