{-# LANGUAGE OverloadedStrings #-}
-- Development probe on the real public L2L Signet. It never signs or sends.
-- Stop the worker first; the exclusive ledger lock prevents concurrent work.
import Bridge.Config
import Bridge.Ledger
import Bridge.Native
import Bridge.NativePayment
import Bridge.RPC
import Bridge.Types
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  (configPath,destination) <- case args of
    [path,address] -> pure (path,T.pack address)
    _ -> fail "usage: native-unsigned-probe.hs CONFIG TESTER_RECIPIENT"
  c <- loadConfig configPath
  require (profile c==L2LSignetDevnet && nativeWallet c=="ecx-bridge-test") "dedicated_public_signet_test_only"
  withLedger (dbPath c) (fingerprint c) $ \ledger -> do
    attempts <- pendingAttempts ledger
    preparations <- pendingPreparations ledger
    require (null attempts && null preparations) "pending_payment_must_resolve_first"
    manager <- newRpcManager
    _ <- nativeIdentity manager c
    let call=nativeCall manager c
    quantity <- either reject pure (amount 100000)
    plan <- newNativePlan call (profile c) (nativeConfirmations c) (maxNativeFee c) destination quantity
    draft <- fundNativeDraft call plan
    let points=map nativeOutpoint (nativeInputs $ draftTransaction draft)
    locked <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
    require (all (`elem` points) locked && all (`elem` locked) points) "unexpected_native_locks"
    -- No signer exists in this path. Only the exact inputs selected above can
    -- be unlocked. Any earlier failure leaves locks for explicit inspection.
    unlocked <- call True "lockunspent" [Bool True,toJSON points] >>= parseValue parseJSON
    require unlocked "native_probe_unlock_failed"
    remaining <- call True "listlockunspent" [] >>= parseValue parseJSON :: IO [Outpoint]
    require (null remaining) "native_probe_locks_remain"
    LBS.putStrLn $ encode $ object
      ["network" .= ("public-l2l-signet"::T.Text),"kind" .= ("unsigned-PSBT-validation"::T.Text)
      ,"recipient" .= destination,"units" .= quantity,"feeUnits" .= draftFee draft
      ,"inputs" .= length points,"outputs" .= length (nativeOutputs $ draftTransaction draft)
      ,"locktime" .= nativeLocktime (draftTransaction draft),"signerInvoked" .= False
      ,"broadcast" .= False,"selectedLocksReleased" .= True,"ledgerSchema" .= schemaVersion]
