module Bridge.Postgres.Provisioning (createCustomerOrder, createCustomerOrderWith) where

import Bridge.Config
import Bridge.Types
import Bridge.Deposit (solanaDepositMemo)
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
createCustomerOrder manager cfg ledger backup = createCustomerOrderWith (realOrderTransport manager cfg backup) cfg ledger

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
          -- Existing memo flow remains internal until the Solana Pay association
          -- contract and observer are converted together.
          started <- orderClock transport
          checkIntakeReady ledger started
          require (started<=deadline order) "deposit_window_closed"
          bindInstruction ledger oid (solanaDepositMemo cfg oid)
    coverage <- instructionBackup ledger (backupRequired cfg) capability oid
    mapM_ (orderBackup transport) coverage
    issued <- orderClock transport
    issueInstruction ledger cfg issued capability oid
