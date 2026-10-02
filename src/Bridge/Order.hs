module Bridge.Order (OrderTransport(..), realOrderTransport) where

import Bridge.Admission
import Bridge.Config
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
