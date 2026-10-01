module Bridge.Backup (Snapshot(..), snapshotLedger, uploadSnapshot) where

import Bridge.Types
import Bridge.Process
import Control.Exception (bracket)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>),isAbsolute)
import System.Posix.Files (setFileMode)

data Snapshot = Snapshot { snapshotPath :: FilePath, snapshotSequence :: Int64, snapshotFingerprint :: Text } deriving (Eq,Show)
snapshotLedger :: FilePath -> FilePath -> FilePath -> Text -> IO Snapshot
snapshotLedger sqliteExecutable database stage expectedIdentity = do
  require (all isAbsolute [sqliteExecutable,database,stage] && all (\s -> not (any (`elem` ['\n','\r','\'']) s)) [database,stage]) "invalid_backup_paths"
  createDirectoryIfMissing True stage
  setFileMode stage 0o700
  ident <- randomId
  let destination=stage </> T.unpack ident <> ".sqlite"
  _ <- runBounded 60 65536 sqliteExecutable [database,".timeout 5000",".backup '"<>destination<>"'"] BS.empty
  setFileMode destination 0o600
  result <- bracket (open destination) close $ \c -> do
    execute_ c "PRAGMA query_only=ON"
    integrity <- query_ c "PRAGMA integrity_check" :: IO [Only Text]
    require (integrity==[Only "ok"]) "snapshot_integrity_failed"
    meta <- query_ c "SELECT schema_version,fingerprint,critical_sequence FROM deployment" :: IO [(Int,Text,Int64)]
    case meta of
      [(1,identity,seqNo)] -> require (identity==expectedIdentity) "snapshot_profile_mismatch" >> pure (Snapshot destination seqNo identity)
      _ -> reject "snapshot_schema_mismatch"
  LBS.writeFile (destination<>".manifest.json") (encode $ object ["fingerprint" .= snapshotFingerprint result,"criticalSequence" .= snapshotSequence result,"schema" .= (1::Int)])
  setFileMode (destination<>".manifest.json") 0o600
  pure result
uploadSnapshot :: FilePath -> FilePath -> FilePath -> Snapshot -> IO Text
uploadSnapshot restic repositoryFile passwordFile snapshot = do
  require (all isAbsolute [restic,repositoryFile,passwordFile]) "absolute_backup_paths_required"
  output <- runBounded 60 (4*1024*1024) restic
    ["--repository-file",repositoryFile,"--password-file",passwordFile,"backup","--json","--tag","ecx-bridge-critical",snapshotPath snapshot,snapshotPath snapshot<>".manifest.json"] BS.empty
  let summaries = [ sid | line <- BC.lines output
        , Right value <- [eitherDecodeStrict' line]
        , Just (kind,sid) <- [parseMaybe (withObject "summary" (\o -> (,) <$> o .: "message_type" <*> o .: "snapshot_id")) value]
        , kind == ("summary"::Text) ]
  case summaries of
    [sid] | T.length sid==64 && T.all (`elem` ("0123456789abcdef"::String)) sid -> pure sid
    _ -> reject "backup_acknowledgment_missing"
