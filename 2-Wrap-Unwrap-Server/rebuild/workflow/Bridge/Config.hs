{-# LANGUAGE DeriveAnyClass #-}
-- One deployment configuration; financial identity retains the baseline hash.
module Bridge.Config
  ( Config(..),loadConfig,validateConfig,fingerprint,nativeSettings,solanaSettings
  , observerSettings,storePolicy,solanaPolicy,publicConfiguration
  , defaultInterface,loadInterface,validateInterface ) where
import Bridge.Domain (Amount,amount,units)
import Bridge.Wire (Profile(..),InterfaceConfig(..),PublicConfiguration(..),Availability(..),PaymentTerms(..),PolicySnapshot(..),CostLimits(..))
import Bridge.Identity (digest,publicKey)
import Bridge.SolanaMessage (signatureBytes)
import Bridge.Error
import qualified Bridge.Native as N
import qualified Bridge.Solana as S
import qualified Bridge.SolanaHelper as H
import qualified Bridge.Observer as O
import qualified Bridge.Store as Store
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as M
import GHC.Generics (Generic)
import Network.HTTP.Client (parseRequest,Request,host,secure,path,requestHeaders)
import System.FilePath (isAbsolute,normalise)
import System.IO (withBinaryFile,IOMode(ReadMode))

data Config = Config
  { profile :: !Profile, deploymentId :: !Text, nativeRpc :: !String
  , nativeCookie :: !FilePath, nativeWallet :: !Text, nativeUnlockFile :: !(Maybe FilePath)
  , nativeCheckpointHeight :: !Int64, nativeCheckpointHash :: !Text
  , solanaRpc :: !String, solanaVerifierRpc :: !(Maybe String), mint :: !Text
  , custodyOwner :: !Text, custodyAta :: !Text
  , serverPort :: !Int, fenceDirectory :: !FilePath
  , signerPort :: !Int, signerAuthFile :: !FilePath, solanaSdkLibrary :: !FilePath
  , minInput :: !Amount, maxInput :: !Amount, maxQueued :: !Int
  , quoteSeconds :: !Int64, confirmationGraceSeconds :: !Int64
  , nativeConfirmations :: !Int, maxNativeFee :: !Amount, maxSolFee :: !Amount
  , backupRequired :: !Bool, solanaHistoryStart :: !Text, maxSolAccountRent :: !Amount
  , solanaOperatingHistoryStart :: !Text, maxNativeDailyCost :: !Amount, maxSolDailyCost :: !Amount
  } deriving (Eq,Show,Generic,ToJSON)
instance FromJSON Config where parseJSON=genericParseJSON defaultOptions {rejectUnknownFields=True}

nativeSettings :: Config -> N.NativeSettings
nativeSettings c=N.NativeSettings (profile c) (nativeRpc c) (nativeCookie c) (nativeWallet c)
  (nativeCheckpointHeight c) (nativeCheckpointHash c)
solanaSettings :: Config -> S.SolanaSettings
solanaSettings c=S.SolanaSettings (profile c) (solanaRpc c) (solanaVerifierRpc c) (mint c) (custodyOwner c) (custodyAta c)
observerSettings :: Config -> O.ObserverSettings
observerSettings c=O.ObserverSettings (nativeSettings c) (solanaSettings c) (nativeConfirmations c) (solanaHistoryStart c) (solanaOperatingHistoryStart c)
solanaPolicy :: Config -> H.SolanaPolicy
solanaPolicy c=H.SolanaPolicy (deploymentId c) (fingerprint c) (mint c) (custodyOwner c) (custodyAta c) (maxSolFee c) (maxSolAccountRent c)
storePolicy :: Config -> Store.StorePolicy
storePolicy c=Store.StorePolicy
  (PaymentTerms (PolicySnapshot (nativeConfirmations c) "finalized" (fingerprint c)) (CostLimits (maxNativeFee c) (maxSolFee c) (maxSolAccountRent c)))
  (Store.OrderLimits (minInput c) (maxInput c) (quoteSeconds c) (confirmationGraceSeconds c) (maxQueued c) (maxNativeDailyCost c) (maxSolDailyCost c))
  (deploymentId c) (backupRequired c)
publicConfiguration :: Config -> InterfaceConfig -> Bool -> PublicConfiguration
publicConfiguration c links paying=PublicConfiguration (profile c) (if profile c==CanonicalBeta then "mainnet-beta" else "devnet")
  links (deploymentId c) (mint c) (custodyOwner c) 8 (minInput c) (maxInput c)
  (M.fromList [("NativeToWrapped",100),("WrappedToNative",100)]) paying False (Availability False "starting")

fingerprint :: Config -> Text
fingerprint c=digest . LBS.toStrict . encode $ object
  ["schema" .= (1::Int),"profile" .= profile c,"deployment" .= deploymentId c
  ,"checkpointHeight" .= nativeCheckpointHeight c,"checkpointHash" .= nativeCheckpointHash c
  ,"genesis" .= S.solanaGenesis (profile c),"mint" .= mint c
  ,"custodyOwner" .= custodyOwner c,"custodyAta" .= custodyAta c,"wallet" .= nativeWallet c]

loadConfig :: FilePath -> IO Config
loadConfig filename = do
  bytes<-withBinaryFile filename ReadMode (`BS.hGet` 32769)
  require (BS.length bytes<=32768) "config_too_large"
  config<-either (const $ reject "invalid_config_json") pure (eitherDecodeStrict' bytes)
  validateConfig config
  pure config
validateConfig :: Config -> IO ()
validateConfig c = do
  let identifier t=not(T.null t) && T.length t<=64 && T.all (`elem` ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"::String)) t
  require (identifier $ deploymentId c) "invalid_deployment_identifier"
  N.validateNativeSettings (nativeSettings c)
  S.validateSolanaSettings (solanaSettings c)
  require (all isAbsolute [fenceDirectory c,signerAuthFile c,solanaSdkLibrary c]
    && normalise(fenceDirectory c)==fenceDirectory c) "absolute_paths_required"
  mapM_ (\filename->require (isAbsolute filename && normalise filename==filename) "absolute_credential_path_required") (nativeUnlockFile c)
  require (all (\n->n>0 && n<=65535) [serverPort c,signerPort c] && serverPort c/=signerPort c
    && signerAuthFile c/=nativeCookie c) "invalid_server_endpoints"
  require (units(minInput c)>=2 && minInput c<=maxInput c && units(maxInput c)<=1000000000000000) "invalid_limits"
  require (maxQueued c>0 && maxQueued c<=1000 && quoteSeconds c>0 && quoteSeconds c<=3600
    && confirmationGraceSeconds c>=0 && confirmationGraceSeconds c<=86400
    && nativeConfirmations c>0 && nativeConfirmations c<=1008) "invalid_policy"
  require (units(maxNativeFee c)>0 && units(maxSolFee c)>0) "invalid_fee_budget"
  total<-either reject pure (amount $ toInteger(units $ maxSolFee c)+toInteger(units $ maxSolAccountRent c))
  require (maxNativeDailyCost c>=maxNativeFee c && maxSolDailyCost c>=total) "invalid_daily_budget"
  require (profile c/=CanonicalBeta || backupRequired c) "canonical_backup_required"
  mapM_ (either reject (const $ pure ()) . signatureBytes) [solanaHistoryStart c,solanaOperatingHistoryStart c]

-- Public presentation settings are separate from financial identity and orders.
defaultInterface :: Profile -> InterfaceConfig
defaultInterface p = InterfaceConfig Nothing Nothing Nothing
  (if p==L2LSignetDevnet then Just "https://explorer.signet.drivechain.info/tx/" else Nothing) Nothing

loadInterface :: Config -> Maybe FilePath -> IO InterfaceConfig
loadInterface c file = do
  links <- case file of
    Nothing->pure(defaultInterface $ profile c)
    Just filename->do
      bytes <- withBinaryFile filename ReadMode (`BS.hGet` 8193)
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
