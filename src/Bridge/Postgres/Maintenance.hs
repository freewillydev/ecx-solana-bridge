-- Explicit offline installation authority; never reachable from Servant/DSL.
module Bridge.Postgres.Maintenance (initialize,verifySigner,initializeWorkerFence,retireWorkerFence) where
import Bridge.Config (Config,fingerprint,custodyOwner)
import Bridge.SolanaMessage (publicKey)
import Bridge.Types (require,reject)
import Bridge.Observer (epochSeconds)
import Bridge.Postgres.Schema
import Bridge.Postgres.Catalog (claimInstallationTransaction)
import qualified Bridge.Postgres.Fence as Fence
import Bridge.Postgres.Ledger (withLedger,ledgerAction)
import Control.Exception (bracket)
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.Aeson (eitherDecodeStrict')
import Data.Bits ((.&.))
import Data.Word (Word8)
import System.IO (withBinaryFile,IOMode(ReadMode))
import System.Posix.Files (getFileStatus,fileMode)

-- Explicit stopped-worker first adoption. The existing database identity and
-- ownership are checked before a host-local watermark can be initialized.
initializeWorkerFence :: PG.ConnectInfo -> Config -> IO ()
initializeWorkerFence settings cfg=do
  directory <- Fence.fenceDirectory
  withLedger settings (fingerprint cfg) $ \ledger->do
    sequenceNo <- ledgerAction ledger $ \c->do
      rows <- O.runSelect c $ fmap deploymentCriticalSequence (O.selectTable deploymentTable)
      case rows of [value]->pure value; _->reject "corrupt_sequence"
    Fence.initializeFence directory (fingerprint cfg) sequenceNo

retireWorkerFence :: PG.ConnectInfo -> Config -> IO ()
retireWorkerFence settings cfg=do
  directory <- Fence.fenceDirectory
  withLedger settings (fingerprint cfg) $ \ledger->do
    sequenceNo <- ledgerAction ledger $ \c->do
      rows <- O.runSelect c $ fmap deploymentCriticalSequence (O.selectTable deploymentTable)
      case rows of [value]->pure value; _->reject "corrupt_sequence"
    Fence.retireFence directory (fingerprint cfg) sequenceNo

-- Offline identity validation only: no signature, chain send or ledger mutation.
verifySigner :: Config -> FilePath -> IO ()
verifySigner cfg filename = do
  permissions <- fileMode <$> getFileStatus filename
  require (permissions .&. 0o077==0) "unsafe_signer_permissions"
  bytes <- withBinaryFile filename ReadMode (\h->BS.hGet h 32769)
  require (BS.length bytes<=32768) "signer_file_too_large"
  values <- either (const $ reject "invalid_signer_json") pure(eitherDecodeStrict' bytes :: Either String [Word8])
  require (length values==64) "invalid_signer_length"
  let key=BS.pack values
  expected <- either reject pure(publicKey $ custodyOwner cfg)
  case Ed.secretKey (BS.take 32 key) of
    CryptoPassed secret->do
      let actual=BA.convert(Ed.toPublic secret) :: BS.ByteString
      require (actual==BS.drop 32 key && actual==expected) "signer_mismatch"
    CryptoFailed _->reject "invalid_signer"

-- DDL is supplied by the reviewed installer. Repeat initialization verifies the
-- identity without changing an existing ledger, pause state or critical sequence.
initialize :: PG.ConnectInfo -> Config -> IO ()
initialize settings cfg = bracket (PG.connect settings) PG.close $ \c->PG.withTransaction c $ do
  existing <- O.runSelect c (O.selectTable deploymentTable) :: IO [Deployment]
  case existing of
    []->do
      claimInstallationTransaction c
      now <- epochSeconds
      _ <- O.runInsert c O.Insert {O.iTable=deploymentTable,O.iRows=[Deployment (O.sqlInt8 1) (O.sqlInt8 18) (O.sqlStrictText $ fingerprint cfg) (O.sqlInt8 0) (O.sqlInt8 0) (O.sqlInt8 1) (O.sqlStrictText "installation_requires_reconciliation")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runInsert c O.Insert {O.iTable=custodycheckTable,O.iRows=[CustodyCheck (O.sqlInt8 1) (O.sqlInt8 0) O.null O.null O.null O.null],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runInsert c O.Insert {O.iTable=operatingclockTable,O.iRows=[OperatingClock (O.sqlInt8 1) (O.sqlInt8 now)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ()
    [row]->require (deploymentSingleton row==1 && deploymentSchemaVersion row==18 && deploymentFingerprint row==fingerprint cfg) "ledger_profile_or_schema_mismatch"
    _->reject "corrupt_deployment"
