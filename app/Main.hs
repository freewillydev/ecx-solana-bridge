module Main where
import Bridge.Config
import Bridge.Worker
import Bridge.Web
import Bridge.Types
import Control.Exception (catch)
import Data.Aeson (encode,object,(.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import System.Environment (getArgs)
import System.Exit (die,exitFailure)
import Text.Read (readMaybe)
main :: IO ()
main = go `catch` (\(BridgeError code) -> LBS.putStrLn (encode $ object ["error" .= code]) >> exitFailure)
 where
  go = getArgs >>= \case
    ["version"] -> putStrLn "ecx-bridge 0.1.0.0 (development; intake disabled)"
    ["check-config",path] -> loadConfig path >>= LBS.putStrLn . encode . object . pure . ("fingerprint" .=) . fingerprint
    ["doctor",path] -> loadConfig path >>= doctor >>= LBS.putStrLn . encode
    ["scan",path] -> loadConfig path >>= scanOnce >>= LBS.putStrLn . encode
    ["reconcile",path] -> loadConfig path >>= reconcileOnce >>= LBS.putStrLn . encode
    ["approve-solana-retry",path,txid,reason] -> loadConfig path >>= \c -> approveRetry c (T.pack txid) (T.pack reason) >>= LBS.putStrLn . encode
    ["cancel-preparation",path,intent,generation,reason] -> case readMaybe generation of
      Just g | g>=0 && g<8 -> loadConfig path >>= \c -> cancelUnsigned c (T.pack intent) g (T.pack reason) >>= LBS.putStrLn . encode
      _ -> die "Invalid preparation generation (expected 0 through 7)"
    ["worker",path] -> loadConfig path >>= runWorker
    ["serve",socket,port,assets] -> case readMaybe port of
      Just p | p>=1024 && p<=65535 -> runPublic socket p assets
      _ -> die "Invalid unprivileged port"
    _ -> die "Usage: ecx-bridge version | check-config CONFIG | doctor CONFIG | scan CONFIG | reconcile CONFIG | approve-solana-retry CONFIG SIGNATURE REASON | cancel-preparation CONFIG INTENT GENERATION REASON | worker CONFIG | serve CUSTOMER_SOCKET PORT ASSETS"
