module Bridge.Legacy.Order (createCustomerOrderWith,solanaDepositMemo) where
import Bridge.Order (OrderTransport(..))
import Bridge.Config
import Bridge.Ledger
import Bridge.Native (recoverNativeAddressWith)
import Bridge.Types
import Data.Text (Text)

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

-- Historical memo form used only by the remaining SQLite provisioning tests.
solanaDepositMemo :: Config -> Text -> Text
solanaDepositMemo c oid="ecx-bridge:v1:"<>deploymentId c<>":deposit:"<>oid
