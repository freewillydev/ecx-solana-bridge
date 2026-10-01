{-# LANGUAGE OverloadedStrings #-}
-- Manual public-Devnet acceptance probe. Preparation has no send operation.
-- The companion operator script journals bytes before sending and keeps them
-- for reconciliation. Neither program is a worker or an installed API route.
import Bridge.Config
import Bridge.RPC
import Bridge.Solana
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Types
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import System.Environment (getArgs)

readJSON :: FromJSON a => FilePath -> IO a
readJSON path = BS.readFile path >>= either fail pure . eitherDecodeStrict'

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["prepare",path,recipient,reference] -> do
      c <- publicTestConfig path
      manager <- newRpcManager
      _ <- solanaIdentity manager c
      let call=solanaCall manager c
      recent <- getRecentBlockhash call
      quantity <- either reject pure (amount 3)
      let plan=SolanaPlan (fingerprint c) (T.pack recipient) quantity (T.pack reference)
            recent (maxSolFee c) (maxSolAccountRent c)
      prepareSolanaSigned call (invokeHelper c) c plan >>= LBS.putStrLn . encode
    ["verify",path,signedPath,proofPath] -> do
      c <- publicTestConfig path
      signed <- readJSON signedPath
      proof <- readJSON proofPath
      either reject (LBS.putStrLn . encode) (verifySolanaOutcome c signed proof)
    _ -> fail "usage: solana-probe prepare CONFIG TESTER REFERENCE | verify CONFIG SIGNED_JSON FINALIZED_PROOF_JSON"
 where
  publicTestConfig path = do
    c <- loadConfig path
    require (profile c==L2LSignetDevnet && nativeWallet c=="ecx-bridge-test"
      && solanaRpc c=="https://api.devnet.solana.com" && mint c/=canonicalMint)
      "dedicated_public_devnet_test_only"
    pure c
