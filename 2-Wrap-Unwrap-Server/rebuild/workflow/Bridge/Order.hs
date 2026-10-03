-- Workflow capabilities are supplied by startup, never by HTTP requests.
module Bridge.Order (OrderTransport(..),createCustomerOrder,createCustomerOrderWith) where
import Bridge.Admission (checkOrderAdmission)
import Bridge.Observer (ObserverSettings(..))
import Bridge.Domain (Direction(..))
import qualified Bridge.Native as N
import Bridge.NativePayment (NativeRPC)
import qualified Bridge.Solana as S
import qualified Bridge.SolanaHelper as H
import Bridge.Store
import qualified Bridge.Wire as W
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)

data OrderTransport = OrderTransport
  { orderClock :: IO Int64, orderAdmission :: W.OrderRequest -> IO ()
  , orderIdentity :: IO (), orderNative :: NativeRPC, orderBackup :: Int64 -> IO () }

createCustomerOrder :: Manager -> ObserverSettings -> H.SolanaPolicy -> StorePolicy -> FilePath
  -> (Int64 -> IO ()) -> Reader -> Writer -> Text -> W.OrderRequest -> IO W.OrderView
createCustomerOrder manager settings config store sdk backup = createCustomerOrderWith transport (nativeSettings settings) (requireBackup store)
 where
  clock=floor <$> getPOSIXTime
  native=nativeSettings settings
  identity=do
    _<-N.nativeIdentity manager native
    _<-S.solanaIdentity manager (solanaSettings settings)
    clock >>= N.nativeWalletReadyWith (N.nativeCall manager native) native
  transport=OrderTransport clock (checkOrderAdmission manager settings config store sdk) identity (N.nativeCall manager native) backup

-- The runtime's critical gate spans this workflow, but no DB transaction spans
-- admission, address allocation or backup. A lost reply retains the saved claim.
createCustomerOrderWith :: OrderTransport -> N.NativeSettings -> Bool -> Reader -> Writer -> Text -> W.OrderRequest -> IO W.OrderView
createCustomerOrderWith transport native remote reader writer header requested = do
  previous<-evalRead reader (FindOrder header requested)
  now<-orderClock transport
  evalWrite writer (ExpireQuotes now)
  identifier<-case previous of
    Just oid->pure oid
    Nothing->do
      evalRead reader (CheckIntake now)
      orderAdmission transport requested
      admitted<-orderClock transport
      evalWrite writer (CreateOrder admitted header requested)
  (view,sequenceNumber)<-evalRead reader (ReadProvisioning header identifier)
  if W.depositInstruction view/=Nothing then evalRead reader (ReadOrder header identifier) else do
    orderIdentity transport
    required<-case sequenceNumber of
      Just n->pure n
      Nothing->case W.direction requested of
        NativeToWrapped->do
          started<-orderClock transport
          claim<-evalWrite writer (ClaimNative started header identifier)
          address<-N.recoverNativeAddressWith (orderNative transport) native started (mayAllocate claim) (allocationLabel claim)
          evalWrite writer (RecordNative header identifier (allocationLabel claim) address)
        WrappedToNative->do
          started<-orderClock transport
          evalWrite writer (BindSolana started header identifier)
    if remote then orderBackup transport required else pure ()
    issued<-orderClock transport
    evalWrite writer (IssueInstruction issued header identifier)
