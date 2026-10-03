{-# LANGUAGE GADTs, ScopedTypeVariables #-}
module Bridge.Native
  ( NativeSettings(..), validateNativeSettings, nativeCall, nativeIdentity, nativeIdentityWith
  , verifyNativeBoundaryWith, validateNativeRecipientWith, nativeWalletInfoWith, nativeWalletReadyWith
  , NativeRecovery(..), evalNativeRecoveryWith
  , recoverNativeAddressWith, nativeHistory, nativeAmount, nativeNumber, signetChallenge ) where

import Bridge.Wire (Profile(..))
import Bridge.RPC
import Bridge.Error
import Bridge.Domain
import Control.Exception (IOException,bracket,catch,throwIO,try)
import Crypto.Hash (Context,Digest,SHA256,hashInit,hashUpdate,hashFinalize)
import Data.Aeson
import Data.Bits ((.&.))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Int (Int64)
import Data.Scientific (Scientific, coefficient, base10Exponent)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager,parseRequest,host,path,queryString,requestHeaders)
import System.IO (Handle,withBinaryFile,IOMode(ReadMode),hClose,hFlush)
import System.FilePath (isAbsolute,normalise,takeDirectory,takeFileName,(</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

-- Real deployment identity, independent of web/installer/signer configuration.
data NativeSettings = NativeSettings
  { profile :: Profile, nativeRpc :: String, nativeCookie :: FilePath, nativeWallet :: Text
  , nativeCheckpointHeight :: Int64, nativeCheckpointHash :: Text } deriving (Eq,Show)
signetChallenge :: Text
signetChallenge = "00148835832e28c816b7acd8fdb19772ab2199603a56"
validateNativeSettings :: NativeSettings -> IO ()
validateNativeSettings c = do
  let wallet=nativeWallet c
  require (not(T.null wallet) && T.length wallet<=64 && T.all (`elem` ("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_"::String)) wallet) "invalid_native_wallet"
  require (isAbsolute $ nativeCookie c) "absolute_credential_path_required"
  require (nativeCheckpointHeight c>0 && T.length(nativeCheckpointHash c)==64 && T.all (`elem` ("0123456789abcdef"::String)) (nativeCheckpointHash c)) "checkpoint_required"
  endpoint <- parseRequest (nativeRpc c)
  require (host endpoint `elem` ["127.0.0.1","localhost","::1"] && path endpoint=="/" && queryString endpoint=="" && null(requestHeaders endpoint)) "invalid_native_rpc_endpoint"
  require (profile c==L2LSignetDevnet || nativeCheckpointHeight c==967680 && nativeCheckpointHash c=="00000000000000030101ba5cfea54b22becc79f95dc6040beb76e01dd9d04042") "wrong_ecx_checkpoint"

nativeCall :: Manager -> NativeSettings -> Bool -> Text -> [Value] -> IO Value
nativeCall manager c wallet methodName params = do
  validateNativeSettings c
  cookie <- withBinaryFile (nativeCookie c) ReadMode (`BS.hGet` 4097)
  require (BS.length cookie <= 4096) "invalid_rpc_cookie"
  let (username,rest) = BC.break (==':') (BC.takeWhile (/='\n') cookie)
  require (not (BS.null username) && BS.length rest>1) "invalid_rpc_cookie"
  let url = reverse(dropWhile (=='/') $ reverse $ nativeRpc c) <> if wallet then "/wallet/" <> T.unpack (nativeWallet c) else ""
  rpc manager url (Just (username,BS.drop 1 rest)) methodName params
nativeIdentity :: Manager -> NativeSettings -> IO Value
nativeIdentity manager c = nativeIdentityWith (nativeCall manager c) c
nativeIdentityWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> IO Value
nativeIdentityWith call c = do
  info <- call False "getblockchaininfo" []
  name <- fieldValue "chain" info :: IO Text
  syncing <- fieldValue "initialblockdownload" info
  require (not syncing) "native_synchronizing"
  height <- fieldValue "blocks" info :: IO Int64
  require (height >= nativeCheckpointHeight c) "native_checkpoint_unavailable"
  actual <- call False "getblockhash" [toJSON (nativeCheckpointHeight c)] >>= parseValue parseJSON
  require (actual==nativeCheckpointHash c) "native_checkpoint_mismatch"
  if profile c==L2LSignetDevnet
    then do
      challenge <- fieldValue "signet_challenge" info
      require (name=="signet" && challenge==signetChallenge) "wrong_signet"
    else require (name=="main") "wrong_ecx_chain"
  peers <- call False "getconnectioncount" [] >>= parseValue parseJSON :: IO Int
  require (peers>0) "native_no_peers"
  pure info
validateNativeRecipientWith :: (Bool -> Text -> [Value] -> IO Value) -> Text -> IO Text
validateNativeRecipientWith call address = do
  require (not (T.null address) && T.length address<=128) "invalid_native_address"
  v <- call True "getaddressinfo" [toJSON address]
  owned <- fieldValue "ismine" v :: IO Bool
  watched <- parseValue (withObject "address" (\o -> o .:? "iswatchonly" .!= False)) v
  require (not owned && not watched) "bridge_owned_destination"
  script <- fieldValue "scriptPubKey" v
  require (not (T.null script) && T.length script<=200 && even (T.length script)
    && T.all (`elem` ("0123456789abcdef"::String)) script) "invalid_native_script"
  decoded <- call False "decodescript" [toJSON script]
  kind <- fieldValue "type" decoded :: IO Text
  require (kind `elem` ["pubkeyhash","scripthash","witness_v0_keyhash","witness_v0_scripthash","witness_v1_taproot"]) "unsupported_native_destination"
  pure script
-- Observation and recovery require the named descriptor wallet to be idle,
-- without requiring private keys. Callers check its chain position separately.
nativeWalletInfoWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> IO Value
nativeWalletInfoWith call c = do
  wallet <- call True "getwalletinfo" []
  name <- fieldValue "walletname" wallet
  descriptors <- fieldValue "descriptors" wallet
  scanning <- fieldValue "scanning" wallet :: IO Value
  require (name==nativeWallet c && descriptors && scanning==Bool False) "native_wallet_not_ready"
  pure wallet

nativeWalletReadyWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> Int64 -> IO ()
nativeWalletReadyWith call c now = do
  wallet <- nativeWalletInfoWith call c
  keys <- fieldValue "private_keys_enabled" wallet
  external <- fieldValue "external_signer" wallet
  unlocked <- parseValue (withObject "wallet" (.:? "unlocked_until")) wallet :: IO (Maybe Int64)
  require (keys && not external && maybe True (>now) unlocked) "native_wallet_not_ready"

-- A durable ledger claim supplies fresh=True exactly once. Recovery only reads
-- the saved label; absent/ambiguous evidence never permits a second allocation.
recoverNativeAddressWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> Int64 -> Bool -> Text -> IO Text
recoverNativeAddressWith call c now fresh label = do
  require (not (T.null label) && T.length label<=160) "invalid_allocation_label"
  nativeWalletReadyWith call c now
  prior <- lookupLabel
  address <- case prior of
    Just a -> pure a
    Nothing -> do
      require fresh "native_allocation_unresolved"
      a <- call True "getnewaddress" [toJSON label,String "bech32"] >>= parseValue parseJSON
      saved <- lookupLabel
      require (saved==Just a) "native_allocation_label_mismatch"
      pure a
  require (not (T.null address) && T.length address<=128) "invalid_native_address"
  info <- call True "getaddressinfo" [toJSON address]
  actual <- fieldValue "address" info
  owned <- fieldValue "ismine" info
  solvable <- fieldValue "solvable" info
  change <- fieldValue "ischange" info
  labels <- fieldValue "labels" info
  script <- fieldValue "scriptPubKey" info :: IO Text
  require (actual==address && owned && solvable && not change && labels==[label]
    && T.length script==44 && "0014" `T.isPrefixOf` script
    && T.all (`elem` ("0123456789abcdef"::String)) script) "native_allocation_policy_mismatch"
  pure address
 where
  lookupLabel = do
    result <- (Just <$> call True "getaddressesbylabel" [toJSON label]) `catch` missingLabel
    case result of
      Nothing -> pure Nothing
      Just (Object entries) -> case KM.toList entries of
        [(address,entry)] -> do
          purpose <- fieldValue "purpose" entry :: IO Text
          require (purpose=="receive") "native_allocation_policy_mismatch"
          pure (Just $ K.toText address)
        _ -> reject "native_allocation_ambiguous"
      _ -> reject "native_allocation_ambiguous"
  missingLabel e@(BridgeError code) = if code=="rpc_error_-11" then pure Nothing else throwIO e
nativeHistory :: Manager -> NativeSettings -> Maybe Text -> Int -> IO Value
nativeHistory manager c anchor depth = nativeCall manager c True "listsinceblock" [maybe Null toJSON anchor,toJSON depth,Bool False,Bool True]
nativeAmount :: Scientific -> Either Text Amount
nativeAmount n
  | (base10Exponent n < -20 || base10Exponent n > 20) || abs (coefficient n) > 1000000000000000000000000000000 = Left "native_amount_out_of_range"
  | e>=0 = amount (coefficient n * 10^e)
  | otherwise = let (a,r) = coefficient n `divMod` (10^negate e) in if r==0 then amount a else Left "native_excess_precision"
 where e=base10Exponent n+8
nativeNumber :: Amount -> Value
nativeNumber a = Number (fromIntegral (units a) / 100000000)

-- Empty arguments cannot authorize a financial action; anything other than the
-- node's explicit forbidden-method result fails the worker credential boundary.
verifyNativeBoundaryWith :: (Bool -> Text -> [Value] -> IO Value) -> IO ()
verifyNativeBoundaryWith call = mapM_ denied
  ["walletprocesspsbt","signrawtransactionwithwallet","signmessage","dumpprivkey",
   "dumpwallet","gethdkeys","listdescriptors","walletpassphrase","walletpassphrasechange",
   "encryptwallet","importprivkey","importwallet","backupwallet"]
 where
  denied method = do
    result<-try (call True method []) :: IO (Either BridgeError Value)
    require (case result of Left(BridgeError "rpc_method_forbidden")->True; _->False) "native_signing_authority_not_separated"

-- Offline custody authority, never a worker or signer HTTP operation. The node
-- and this evaluator must share a private staging directory under the same UID.
-- An encrypted wallet still requires its separately retained unlock material.
data NativeRecovery a where
  BackupNativeWallet :: FilePath -> NativeRecovery FilePath
  RestoreNativeWallet :: FilePath -> NativeRecovery ()
  InspectNativeWalletBackup :: FilePath -> NativeRecovery (Text,FilePath,Text)

evalNativeRecoveryWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> NativeRecovery a -> IO a
evalNativeRecoveryWith call c operation = do
  validateNativeSettings c
  case operation of
    BackupNativeWallet destination -> do
      _<-nativeIdentityWith call c
      privateParent destination
      let manifest=destination<>".json"
      absent destination
      absent manifest
      before<-descriptors
      result<-call True "backupwallet" [toJSON destination]
      require (result==Null) "unexpected_rpc_schema"
      privateBackup destination
      after<-descriptors
      require (before==after) "native_wallet_changed_during_backup"
      sync destination
      checksum<-withBinaryFile destination ReadMode (hashChunks hashInit)
      let evidence=manifestValue (profile c) (nativeCheckpointHeight c) (nativeCheckpointHash c)
            (nativeWallet c) (takeFileName destination) checksum before
          encoded=encode evidence
      require (BL.length encoded<=1048576) "native_backup_manifest_too_large"
      bracket (openFd manifest WriteOnly defaultFileFlags
        {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True} >>= fdToHandle) hClose $ \handle->do
          BL.hPut handle encoded
          hFlush handle
      sync manifest
      sync (takeDirectory destination)
      pure manifest
    RestoreNativeWallet manifest -> do
      (_,backup,_,expected)<-load manifest
      _<-nativeIdentityWith call c
      wallets<-call False "listwalletdir" [] >>= fieldValue "wallets" :: IO [Value]
      names<-mapM (fieldValue "name") wallets
      require (nativeWallet c `notElem` names) "native_restore_wallet_exists"
      result<-call False "restorewallet" [toJSON $ nativeWallet c,toJSON backup,Bool False]
      name<-fieldValue "name" result
      require (name==nativeWallet c) "native_restore_wallet_mismatch"
      restored<-descriptors
      matching<-and <$> sequence (zipWith sameDescriptor expected restored)
      require (length restored==length expected && matching) "native_restore_descriptors_mismatch"
    InspectNativeWalletBackup manifest -> do
      (wallet,backup,checksum,_)<-load manifest
      pure (wallet,backup,checksum)
 where
  load manifest = do
    privateParent manifest
    privateBackup manifest
    bytes<-withBinaryFile manifest ReadMode (`BS.hGet` 1048577)
    require (BS.length bytes<=1048576) "native_backup_manifest_too_large"
    value<-either (const $ reject "invalid_native_backup_manifest") pure (eitherDecodeStrict' bytes)
    version<-fieldValue "format" value :: IO Int
    savedProfile<-fieldValue "profile" value
    height<-fieldValue "checkpointHeight" value
    checkpoint<-fieldValue "checkpointHash" value
    wallet<-fieldValue "wallet" value
    name<-fieldValue "archive" value
    checksum<-fieldValue "sha256" value
    expected<-fieldValue "descriptors" value
    require (version==1 && value==manifestValue savedProfile height checkpoint wallet name checksum expected
      && name==takeFileName name && name `notElem` ["",".",".."]
      && T.length checksum==64 && T.all (`elem` ("0123456789abcdef"::String)) checksum
      && not(null expected)) "invalid_native_backup_manifest"
    require (savedProfile==profile c && height==nativeCheckpointHeight c
      && checkpoint==nativeCheckpointHash c) "native_backup_network_mismatch"
    validateNativeSettings c {nativeWallet=wallet}
    let backup=takeDirectory manifest </> name
    privateBackup backup
    actual<-withBinaryFile backup ReadMode (hashChunks hashInit)
    require (actual==checksum) "native_backup_hash_mismatch"
    pure (wallet,backup,checksum,expected)
  -- Only public descriptors and relative archive names enter the manifest;
  -- cookie paths and other local credentials are deliberately excluded.
  manifestValue savedProfile height checkpoint wallet name checksum values=object
    ["format" .= (1::Int),"profile" .= (savedProfile::Profile),"checkpointHeight" .= (height::Int64)
    ,"checkpointHash" .= (checkpoint::Text),"wallet" .= (wallet::Text),"archive" .= (name::FilePath)
    ,"sha256" .= (checksum::Text),"descriptors" .= (values::[Value])]
  absent path=do
    exists<-(getSymbolicLinkStatus path >> pure True) `catch` (\(e::IOException)->
      if isDoesNotExistError e then pure False else throwIO e)
    require (not exists) "native_backup_destination_exists"
  descriptors = do
    wallet<-nativeWalletInfoWith call c
    keys<-fieldValue "private_keys_enabled" wallet
    external<-fieldValue "external_signer" wallet
    require (keys && not external) "native_wallet_not_ready"
    result<-call True "listdescriptors" [Bool False]
    name<-fieldValue "wallet_name" result
    values<-fieldValue "descriptors" result :: IO [Value]
    require (name==nativeWallet c && not(null values)) "native_backup_descriptors_missing"
    pure values
  -- Loading a wallet replenishes its lookahead keypool. Only an expanded range
  -- is allowed; keys, timestamps, allocation indices and other fields stay exact.
  sameDescriptor (Object before) (Object after)
    | KM.delete "range" before==KM.delete "range" after = case (KM.lookup "range" before,KM.lookup "range" after) of
        (Nothing,Nothing)->pure True
        (Just old,Just new)->do
          oldRange<-parseValue parseJSON old :: IO [Int64]
          newRange<-parseValue parseJSON new :: IO [Int64]
          pure $ case (oldRange,newRange) of
            ([lo,hi],[loNew,hiNew])->0<=lo && lo<=hi && loNew==lo && hiNew>=hi && hiNew<2147483648
            _->False
        _->pure False
  sameDescriptor _ _=pure False
  privateParent path = do
    require (isAbsolute path && normalise path==path) "invalid_native_backup_path"
    status<-getSymbolicLinkStatus (takeDirectory path)
    uid<-getEffectiveUserID
    require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_native_backup_directory"
  privateBackup path = do
    status<-getSymbolicLinkStatus path
    uid<-getEffectiveUserID
    require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o077==0
      && linkCount status==1 && fileSize status>0) "unsafe_native_backup_file"
  hashChunks :: Context SHA256 -> Handle -> IO Text
  hashChunks context handle = do
    bytes<-BS.hGet handle 65536
    if BS.null bytes then pure (T.pack $ show (hashFinalize context :: Digest SHA256))
      else hashChunks (hashUpdate context bytes) handle
  sync path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
