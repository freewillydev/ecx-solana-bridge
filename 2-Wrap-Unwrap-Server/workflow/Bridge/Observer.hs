{-# LANGUAGE ScopedTypeVariables #-}
-- The critical runtime calls this cycle. Chain reads never share a DB transaction.
module Bridge.Observer (ObserverSettings(..),observeOnce) where
import Bridge.Native
import Bridge.NativeObservation
import Bridge.Solana
import Bridge.SolanaObservation
import Bridge.RPC (rpc)
import Bridge.Error (reject)
import Bridge.Store
import Control.Exception (IOException,catch,try)
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)

data ObserverSettings = ObserverSettings
  { nativeSettings :: NativeSettings, solanaSettings :: SolanaSettings
  , defaultNativeDepth :: Int, tokenOrigin :: Text, operatingOrigin :: Text }

observeOnce :: Manager -> ObserverSettings -> Reader -> Writer -> IO ()
observeOnce manager settings reader writer = do
  let native=nativeSettings settings; solana=solanaSettings settings
      call=solanaCall manager solana
      verifier=fmap (\url->rpc manager url Nothing) (solanaVerifierRpc solana)
      lookupInstruction address=evalRead reader (LookupInstruction address)
      lookupReferences keys=evalRead reader (LookupReferences keys)
      nativeScan = do
        previous<-evalRead reader (ReadCheckpoint "Native")
        depth<-evalRead reader (MaximumNativeDepth $ defaultNativeDepth settings)
        recovering<-evalRead reader NativeSourceCandidates
        now<-epoch
        scanNativeWith (nativeCall manager native) native (defaultNativeDepth settings) depth previous now recovering lookupInstruction
      tokenScan = do
        previous<-evalRead reader (ReadCheckpoint "Solana")
        pending<-evalRead reader PendingVerification
        now<-epoch
        scanSolanaWith call verifier solana (tokenOrigin settings) previous now pending lookupInstruction lookupReferences
      operatingScan = do
        previous<-evalRead reader (ReadCheckpoint "SolanaOperating")
        now<-epoch
        scanSolanaOperatingWith call verifier solana (operatingOrigin settings) previous now
  forM_ [("Native",nativeScan),("Solana",tokenScan),("SolanaOperating",operatingScan)] $ \(chain,scan)->do
    result<-try ((scan >>= evalWrite writer . CommitScan) `catch` (\(_::IOException)->reject "observer_io_unavailable"))
    case result of
      Right ()->pure ()
      Left (BridgeError code)->do now<-epoch; evalWrite writer (ScanFailed chain now code)
  candidates<-evalRead reader PromotionCandidates
  now<-epoch
  forM_ candidates $ \identifier->evalWrite writer (PromoteDeposit now identifier) >> pure ()
 where epoch=floor <$> getPOSIXTime
