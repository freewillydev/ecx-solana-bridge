module Bridge.Config where

import Bridge.Types
import Bridge.SolanaMessage (publicKey,signatureBytes)
import Control.Monad (unless)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import Network.HTTP.Client (parseRequest, host, secure)
import System.FilePath (isAbsolute)

data Profile = L2LSignetDevnet | ECXBetanetDevnet | CanonicalBeta deriving (Eq, Show, Generic, ToJSON, FromJSON)
data Config = Config
  { profile :: !Profile, deploymentId :: !Text, nativeRpc :: !String
  , nativeCookie :: !FilePath, nativeWallet :: !Text
  , nativeCheckpointHeight :: !Int64, nativeCheckpointHash :: !Text
  , solanaRpc :: !String, solanaVerifierRpc :: !(Maybe String), mint :: !Text
  , custodyOwner :: !Text, custodyAta :: !Text
  , dbPath :: !FilePath, customerSocket :: !FilePath, adminSocket :: !FilePath
  , helperPath :: !FilePath, helperConfig :: !FilePath
  , minInput :: !Amount, maxInput :: !Amount, maxQueued :: !Int
  , quoteSeconds :: !Int64, confirmationGraceSeconds :: !Int64
  , nativeConfirmations :: !Int, maxNativeFee :: !Amount, maxSolFee :: !Amount
  , backupRequired :: !Bool, solanaHistoryStart :: !(Maybe Text)
  } deriving (Eq, Show, Generic, ToJSON)
instance FromJSON Config where parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }

tokenProgram, canonicalMint, ecxCheckpoint, signetChallenge :: Text
tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
canonicalMint = "EVHqNdzjCupKi4rQkbuYw52sa1m8A7jeUAMP23S9AVVq"
ecxCheckpoint = "00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042"
signetChallenge = "00148835832e28c816b7acd8fdb19772ab2199603a56"
solanaGenesis :: Profile -> Text
solanaGenesis CanonicalBeta = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
solanaGenesis _ = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
fingerprint :: Config -> Text
fingerprint c = digest . LBS.toStrict . encode $ object
  [ "schema" .= (1::Int), "profile" .= profile c, "deployment" .= deploymentId c
  , "checkpointHeight" .= nativeCheckpointHeight c, "checkpointHash" .= nativeCheckpointHash c
  , "genesis" .= solanaGenesis (profile c), "mint" .= mint c
  , "custodyOwner" .= custodyOwner c, "custodyAta" .= custodyAta c, "wallet" .= nativeWallet c ]
loadConfig :: FilePath -> IO Config
loadConfig path = do
  b <- BS.readFile path
  require (BS.length b <= 32768) "config_too_large"
  c <- either (const $ reject "invalid_config_json") pure (eitherDecodeStrict' b)
  validateConfig c
  pure c
validateConfig :: Config -> IO ()
validateConfig c = do
  require (validIdentifier (deploymentId c) && validIdentifier (nativeWallet c)) "invalid_deployment_identifier"
  require (all isAbsolute [nativeCookie c,dbPath c,customerSocket c,adminSocket c,helperPath c,helperConfig c]) "absolute_paths_required"
  require (customerSocket c /= adminSocket c && length (customerSocket c) < 100 && length (adminSocket c) < 100) "invalid_socket_paths"
  require (units (minInput c) > 0 && minInput c <= maxInput c && units (maxInput c) <= 1000000000000000) "invalid_limits"
  require (maxQueued c > 0 && maxQueued c <= 1000 && quoteSeconds c > 0 && quoteSeconds c <= 3600 && confirmationGraceSeconds c >= 0 && confirmationGraceSeconds c <= 86400 && nativeConfirmations c > 0) "invalid_policy"
  require (units (maxNativeFee c) > 0 && units (maxSolFee c) > 0) "invalid_fee_budget"
  require (T.length (nativeCheckpointHash c) == 64 && T.all (\x -> x `elem` ("0123456789abcdef"::String)) (nativeCheckpointHash c) && nativeCheckpointHeight c > 0) "checkpoint_required"
  nr <- parseRequest (nativeRpc c)
  require (host nr `elem` ["127.0.0.1","localhost","::1"]) "native_rpc_must_be_loopback"
  mapM_ (\url -> parseRequest url >>= \r -> require (secure r) "solana_requires_https") (solanaRpc c : maybe [] pure (solanaVerifierRpc c))
  unless (profile c == L2LSignetDevnet) $ require (nativeCheckpointHeight c == 967680 && nativeCheckpointHash c == ecxCheckpoint) "wrong_ecx_checkpoint"
  if profile c == CanonicalBeta
    then do
      require (mint c == canonicalMint && backupRequired c) "canonical_identity_or_backup_required"
      require (maybe False (/= solanaRpc c) (solanaVerifierRpc c)) "independent_rpc_required"
      require (maybe False (const True) (solanaHistoryStart c)) "solana_history_start_required"
    else require (mint c /= canonicalMint) "canonical_mint_forbidden_on_devnet"
  require (all (\t -> T.length t >= 32 && T.length t <= 44 && BS.all (<128) (TE.encodeUtf8 t)) [mint c,custodyOwner c,custodyAta c]) "invalid_solana_identity"
  mapM_ (either reject (const $ pure ()) . publicKey) [mint c,custodyOwner c,custodyAta c]
  mapM_ (either reject (const $ pure ()) . signatureBytes) (solanaHistoryStart c)
