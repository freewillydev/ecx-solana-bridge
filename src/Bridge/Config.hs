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
import Network.HTTP.Client (parseRequest,Request,host,secure,path,requestHeaders)
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
  , maxSolAccountRent :: !Amount
  , solanaOperatingHistoryStart :: !(Maybe Text)
  , maxNativeDailyCost :: !Amount, maxSolDailyCost :: !Amount
  } deriving (Eq, Show, Generic, ToJSON)
instance FromJSON Config where parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }

-- Public presentation settings are separate from financial identity and orders.
data InterfaceConfig = InterfaceConfig
  { supportUrl :: !(Maybe Text), jupiterUrl :: !(Maybe Text)
  , orcaUrl :: !(Maybe Text), nativeExplorerBase :: !(Maybe Text)
  , publicOrigin :: !(Maybe Text)
  } deriving (Eq,Show,Generic,ToJSON)
instance FromJSON InterfaceConfig where
  parseJSON = genericParseJSON defaultOptions { rejectUnknownFields = True }

defaultInterface :: Profile -> InterfaceConfig
defaultInterface p = InterfaceConfig Nothing Nothing Nothing
  (if p==L2LSignetDevnet then Just "https://explorer.signet.drivechain.info/tx/" else Nothing) Nothing

loadInterface :: Config -> Maybe FilePath -> IO InterfaceConfig
loadInterface c file = do
  links <- case file of
    Nothing->pure(defaultInterface $ profile c)
    Just filename->do
      bytes <- BS.readFile filename
      require (BS.length bytes<=8192) "interface_config_too_large"
      either (const $ reject "invalid_interface_config") pure(eitherDecodeStrict' bytes)
  validateInterface c links
  pure links

validateInterface :: Config -> InterfaceConfig -> IO ()
validateInterface c links = do
  mapM_ (\url->require (httpsLink url && not(T.any (`elem` ("?#"::String)) url) && maybe False ((=="/") . path) (parseLink url)) "invalid_public_origin") (publicOrigin links)
  mapM_ (\url->require (httpsLink url || mailLink url) "invalid_support_url") (supportUrl links)
  mapM_ (\url->require (httpsLink url && "/tx/" `T.isSuffixOf` url && not(T.any (`elem` ("?#"::String)) url)) "invalid_native_explorer") (nativeExplorerBase links)
  require (profile c==CanonicalBeta || (jupiterUrl links==Nothing && orcaUrl links==Nothing)) "trading_links_require_mainnet"
  mapM_ (\url->require (httpsLink url && allowedHost ["jup.ag","www.jup.ag"] url && mint c `T.isInfixOf` url) "invalid_jupiter_link") (jupiterUrl links)
  mapM_ (\url->do
    require (httpsLink url && allowedHost ["orca.so","www.orca.so"] url && not(T.any (`elem` ("?#"::String)) url)) "invalid_orca_link"
    case parseLink url of
      Just r | Just pool<-T.stripPrefix "/pools/" (TE.decodeUtf8 $ path r)->either (const $ reject "invalid_orca_pool") (const $ pure ()) (publicKey pool)
      _->reject "invalid_orca_pool") (orcaUrl links)
 where
  parseLink :: Text -> Maybe Request
  parseLink = parseRequest . T.unpack
  httpsLink url = T.length url<=2048 && T.all (\x->x>' ' && x<'\DEL') url &&
    case parseLink url of Just r->secure r && null(requestHeaders r); Nothing->False
  mailLink url = case T.stripPrefix "mailto:" url of
    Just address->T.length address<=320 && T.count "@" address==1 && T.all (\x->x `elem` ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-@"::String)) address
    Nothing->False
  allowedHost names url = maybe False (\r->host r `elem` names) (parseLink url)

-- Public test deployments always use a noncanonical Solana Devnet mint.
-- Valuable-fund/canonical activation remains a distinct release gate.
publicTestProfile :: Config -> Bool
publicTestProfile c = profile c `elem` [L2LSignetDevnet,ECXBetanetDevnet] && not(backupRequired c)

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
  require (units (maxNativeDailyCost c)>0 && units (maxSolDailyCost c)>0) "invalid_daily_budget"
  _ <- either reject pure (amount $ toInteger (units $ maxSolFee c)+toInteger (units $ maxSolAccountRent c))
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
      require (maybe False (const True) (solanaOperatingHistoryStart c)) "solana_operating_history_start_required"
    else require (mint c /= canonicalMint) "canonical_mint_forbidden_on_devnet"
  require (all (\t -> T.length t >= 32 && T.length t <= 44 && BS.all (<128) (TE.encodeUtf8 t)) [mint c,custodyOwner c,custodyAta c]) "invalid_solana_identity"
  mapM_ (either reject (const $ pure ()) . publicKey) [mint c,custodyOwner c,custodyAta c]
  mapM_ (mapM_ (either reject (const $ pure ()) . signatureBytes))
    [solanaHistoryStart c,solanaOperatingHistoryStart c]
