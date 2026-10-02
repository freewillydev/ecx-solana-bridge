-- Exact-snapshot upload runs outside ledgerAction; only the final receipt is a
-- short financial transaction. No customer/operator DSL operation can forge it.
module Bridge.Postgres.Backup (RemoteBackup(..), loadRemoteBackup, backupCallback) where

import Bridge.Config (Config, fingerprint)
import Bridge.Postgres.Ledger (Ledger, acknowledgeBackup)
import Bridge.Process (runBoundedWithEnvironment)
import Bridge.Types (require, reject)
import Data.Aeson
import qualified Data.ByteString as BS
import Data.Int (Int64)
import GHC.Generics (Generic)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import System.Environment (getEnvironment)
import System.FilePath (isAbsolute)

-- Separate operational settings: repository credentials are protected files,
-- never part of public config, financial identity or customer order terms.
data RemoteBackup = RemoteBackup
  { python :: FilePath, uploader :: FilePath, stage :: FilePath
  , restic :: FilePath, repositoryFile :: FilePath, passwordFile :: FilePath
  } deriving (Eq,Show,Generic)
instance FromJSON RemoteBackup where
  parseJSON = genericParseJSON defaultOptions {rejectUnknownFields=True}

loadRemoteBackup :: FilePath -> IO RemoteBackup
loadRemoteBackup path = do
  bytes <- BS.readFile path
  require (BS.length bytes<=8192) "backup_configuration_too_large"
  remote <- either (const $ reject "invalid_backup_configuration") pure (eitherDecodeStrict' bytes)
  require (all isAbsolute [python remote,uploader remote,stage remote,restic remote,repositoryFile remote,passwordFile remote]) "invalid_backup_configuration"
  pure remote

data Receipt = Receipt Int Text Int64 Text Text
instance FromJSON Receipt where
  parseJSON = withObject "remote backup receipt" $ \o->Receipt
    <$> o .: "format" <*> o .: "fingerprint" <*> o .: "criticalSequence"
    <*> o .: "snapshotId" <*> o .: "archiveSha256"

-- settings must name the configured read-only backup role. pg_dump uses the
-- same actual database endpoint as the worker, not an ambient default database.
backupCallback :: PG.ConnectInfo -> Ledger -> Config -> RemoteBackup -> Int64 -> IO ()
backupCallback settings ledger cfg remote required = do
  require (required>=0 && all isAbsolute
    [python remote,uploader remote,stage remote,restic remote,repositoryFile remote,passwordFile remote]) "invalid_backup_configuration"
  inherited <- getEnvironment
  let database = [("PGHOST",PG.connectHost settings),("PGPORT",show $ PG.connectPort settings)
                 ,("PGDATABASE",PG.connectDatabase settings),("PGUSER",PG.connectUser settings)]
      -- A supplied role password supersedes ambient PGPASSWORD. An empty
      -- password uses peer authentication or the separately managed PGPASSFILE.
      credentials = if null(PG.connectPassword settings) then [] else [("PGPASSWORD",PG.connectPassword settings)]
      managed = map fst database <> ["PGPASSWORD"]
      environment = database <> credentials <> filter ((`notElem` managed).fst) inherited
  bytes <- runBoundedWithEnvironment environment 420 8192 (python remote)
    [uploader remote,"--directory",stage remote,"--username",PG.connectUser settings
    ,"--fingerprint",T.unpack $ fingerprint cfg,"--minimum-sequence",show required
    ,"--restic",restic remote,"--repository-file",repositoryFile remote,"--password-file",passwordFile remote] BS.empty
  Receipt version identity sequenceNo snapshot archiveHash <-
    either (const $ reject "invalid_backup_receipt") pure (eitherDecodeStrict' bytes)
  require (version==1 && identity==fingerprint cfg && sequenceNo>=required && validHash archiveHash && validHash snapshot) "invalid_backup_receipt"
  acknowledgeBackup ledger identity sequenceNo snapshot
 where
  validHash text=T.length text==64 && T.all (`elem` ("0123456789abcdef"::String)) text
