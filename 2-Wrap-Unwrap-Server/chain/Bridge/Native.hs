{-# LANGUAGE GADTs, ScopedTypeVariables #-}
module Bridge.Native
  ( NativeSettings(..), validateNativeSettings, nativeCall, nativeIdentity, nativeIdentityWith
  , verifyNativeBoundaryWith, validateNativeRecipientWith, nativeWalletInfoWith, nativeWalletKeysWith, nativeWalletReadyWith
  , NativeRecovery(..), evalNativeRecoveryWith
  , recoverNativeAddressWith, nativeHistory, nativeAmount, nativeNumber, signetChallenge ) where

import qualified Bridge.AdminKey as Private
import qualified Bridge.NativeBackup as BackupTransfer
import Bridge.Identity (digest)
import Crypto.Random (getRandomBytes)
import System.Directory (removeDirectoryRecursive,listDirectory)
import qualified System.Posix.Directory as PD
import Bridge.Wallet (nativeDescriptors,protectWalletProcess)
import qualified Data.Text.Encoding as TE
import Bridge.Wire (Profile(..))
import Bridge.RPC
import Bridge.Error
import Bridge.File (withHandle,readBounded,hashHandle)
import Bridge.Domain
import Control.Monad (when)
import Control.Concurrent (threadDelay)
import System.Timeout (timeout)
import Control.Exception (IOException,bracket,catch,throwIO,try,finally)
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
import System.IO (withBinaryFile,IOMode(ReadMode),hFlush)
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

-- Receiving addresses uses the descriptor keypool while an encrypted wallet is
-- locked. Private-key availability and signing readiness are separate checks.
nativeWalletKeysWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> IO Value
nativeWalletKeysWith call c = do
  wallet <- nativeWalletInfoWith call c
  keys <- fieldValue "private_keys_enabled" wallet
  external <- fieldValue "external_signer" wallet
  require (keys && not external) "native_wallet_not_ready"
  pure wallet

nativeWalletReadyWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> Int64 -> IO ()
nativeWalletReadyWith call c now = do
  wallet <- nativeWalletKeysWith call c
  unlocked <- parseValue (withObject "wallet" (.:? "unlocked_until")) wallet :: IO (Maybe Int64)
  require (maybe True (>now) unlocked) "native_wallet_not_ready"

-- A durable ledger claim supplies fresh=True exactly once. Recovery only reads
-- the saved label; absent/ambiguous evidence never permits a second allocation.
recoverNativeAddressWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> Bool -> Text -> IO Text
recoverNativeAddressWith call c fresh label = do
  require (not (T.null label) && T.length label<=160) "invalid_allocation_label"
  _<-nativeWalletKeysWith call c
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
   "dumpwallet","gethdkeys","listdescriptors","walletpassphrase","walletpassphrasechange","walletlock",
   "encryptwallet","importprivkey","importwallet","backupwallet"]
 where
  denied method = do
    result<-try (call True method []) :: IO (Either BridgeError Value)
    require (case result of Left(BridgeError "rpc_method_forbidden")->True; _->False) "native_signing_authority_not_separated"

-- Offline custody authority, never a worker or signer HTTP operation. The node
-- and this evaluator must share a private staging directory under the same UID.
-- An encrypted wallet still requires its separately retained unlock material.
data NativeRecovery a where
  InitializeNativeWallet :: FilePath -> Maybe FilePath -> Bool -> Int -> NativeRecovery Text
  BackupNativeWallet :: FilePath -> NativeRecovery FilePath
  ReceiveNativeWalletBackup :: FilePath -> NativeRecovery FilePath
  ServeNativeWalletBackup :: FilePath -> NativeRecovery ()
  CheckNativeRestore :: FilePath -> NativeRecovery ()
  RestoreNativeWallet :: FilePath -> NativeRecovery ()
  InspectNativeWalletBackup :: FilePath -> NativeRecovery (Text,FilePath,Text)

evalNativeRecoveryWith :: (Bool -> Text -> [Value] -> IO Value) -> NativeSettings -> NativeRecovery a -> IO a
evalNativeRecoveryWith call c operation = do
  validateNativeSettings c
  case operation of
    InitializeNativeWallet phraseFile unlockFile restoring rangeEnd -> Private.withFamily phraseFile $ do
      protectWalletProcess
      require (rangeEnd>=999 && rangeEnd<=1000000) "invalid_native_recovery_range"
      -- Phrase stays in this process. RPC receives only derived descriptors.
      phrase<-BC.unpack . BC.strip <$> Private.readPrivate phraseFile
      privateDescriptors<-nativeDescriptors (profile c==L2LSignetDevnet) phrase >>= either reject pure
      -- Only identity reads may wait/retry. Never replay wallet mutations after
      -- an unknown outcome merely because the node was restarting.
      let ready first=nativeIdentityWith call c `catch` \(BridgeError code)->
            if code `elem` ["rpc_transport_unknown_outcome","rpc_error_-28","native_synchronizing","native_checkpoint_unavailable","native_no_peers"]
              then do
                when first $ putStrLn "Waiting up to 60 seconds for the ECX node to finish starting/syncing; saved setup is retained."
                threadDelay 1000000
                ready False
              else throwIO(BridgeError code)
      chain<-timeout (60*1000000) (ready True) >>= maybe (reject "native_not_ready_rerun_start") pure
      when restoring $ do
        pruned<-fieldValue "pruned" chain
        require (not pruned) "native_seed_restore_requires_full_chain_history"
      infos<-mapM (\desc->call False "getdescriptorinfo" [String desc]) privateDescriptors
      publicDescriptors<-mapM (fieldValue "descriptor") infos :: IO [Text]
      checksums<-mapM (fieldValue "checksum") infos :: IO [Text]
      let expected=zip publicDescriptors [False,True]
          checkpoint=phraseFile<>".initialized.json"
          verify=do
            _<-nativeWalletKeysWith call c
            entries<-call True "listdescriptors" [Bool False] >>= fieldValue "descriptors" :: IO [Value]
            actual<-mapM (\entry->do
              active<-fieldValue "active" entry
              require active "native_seed_inactive_descriptor"
              (,) <$> fieldValue "desc" entry <*> fieldValue "internal" entry) entries
            require (length actual==2 && all (`elem` actual) expected) "native_seed_wallet_mismatch"
          binding address=object ["profile" .= profile c,"wallet" .= nativeWallet c
            ,"checkpoint" .= nativeCheckpointHash c,"rangeEnd" .= rangeEnd,"restoring" .= restoring,"descriptors" .= publicDescriptors,"address" .= (address::Text)]
      receiveDescriptor<-case publicDescriptors of [receive,_]->pure receive; _->reject "native_seed_descriptor_count"
      initialAddresses<-call False "deriveaddresses" [String receiveDescriptor,toJSON ([0,0]::[Int])] >>= parseValue parseJSON :: IO [Text]
      require (length initialAddresses==1) "native_seed_address_mismatch"
      completed<-fileExist checkpoint
      if completed then do
        record<-Private.readPrivate checkpoint >>= either (const $ reject "invalid_native_seed_checkpoint") pure . eitherDecodeStrict'
        address<-fieldValue "address" record
        require (initialAddresses==[address]) "native_seed_address_mismatch"
        require (record==binding address) "native_seed_checkpoint_mismatch"
        verify
        pure address
       else do
        wallets<-call False "listwalletdir" [] >>= fieldValue "wallets" :: IO [Value]
        names<-mapM (fieldValue "name") wallets
        require (nativeWallet c `notElem` names) "native_seed_wallet_exists_requires_review"
        passphrase<-case unlockFile of
          Nothing->pure ""
          Just file->do
            bytes<-Private.readPrivate file
            require (not(BS.null bytes) && BS.length bytes<=1024 && not(BS.any (`elem` [0,10,13]) bytes)) "invalid_native_unlock_file"
            either (const $ reject "invalid_native_unlock_file") pure (TE.decodeUtf8' bytes)
        result<-call False "createwallet" [toJSON $ nativeWallet c,Bool False,Bool True,String passphrase,Bool False,Bool True,Bool True,Bool False]
        name<-fieldValue "name" result
        require (name==nativeWallet c) "native_seed_wallet_mismatch"
        let populate=do
              let requests=[object ["desc" .= (desc<>"#"<>checksum),"active" .= True
                    ,"internal" .= internal,"range" .= ([0,rangeEnd]::[Int]),"next_index" .= (0::Int)
                    ,"timestamp" .= (if restoring then Number 0 else String "now")]
                    | ((desc,checksum),internal)<-zip (zip privateDescriptors checksums) [False,True]]
              imported<-call True "importdescriptors" [toJSON requests] >>= parseValue parseJSON :: IO [Value]
              succeeded<-mapM (fieldValue "success") imported
              require (length succeeded==2 && and succeeded) "native_seed_import_or_rescan_failed"
        if T.null passphrase then populate else
          (call True "walletpassphrase" [String passphrase,Number 120] >> populate)
            `finally` (call True "walletlock" [] >> pure ())
        verify
        address<-call True "getnewaddress" [String "bridge-initial-funding",String "bech32"] >>= parseValue parseJSON
        require (initialAddresses==[address]) "native_seed_address_mismatch"
        Private.savePrivate checkpoint (BL.toStrict $ encode $ binding address)
        pure address
    ServeNativeWalletBackup parent -> Private.withFamily (parent</>"export") $ do
      result<-timeout 240000000 $ do
        BackupTransfer.request backupIdentity
        -- A killed helper may leave a node RPC still copying. Never unlink that
        -- output on a guessed timeout; bound retained orphans and refuse instead.
        entries<-listDirectory parent
        let orphans=filter (/="export.lock") entries
            valid name=length name==71 && take 7 name=="export-"
              && all (`elem` ("0123456789abcdef"::String)) (drop 7 name)
        require (all valid orphans && length orphans<2) "native_backup_spool_requires_cleanup"
        nonce<-digest <$> (getRandomBytes 16 :: IO BS.ByteString)
        let directory=parent</>("export-"<>T.unpack nonce)
        PD.createDirectory directory 0o700
        -- RPC failure/cancellation is not proof the node stopped writing. Retain
        -- that directory; cleanup is safe only after a fully validated backup.
        _<-evalNativeRecoveryWith call c (BackupNativeWallet $ directory</>"wallet")
        BackupTransfer.send (directory</>"wallet") `finally` removeDirectoryRecursive directory
      require (result==Just ()) "native_backup_service_timeout"
    ReceiveNativeWalletBackup destination -> backup destination True
    BackupNativeWallet destination -> backup destination False
    CheckNativeRestore manifest -> do
      (wallet,_,_)<-restoreReady manifest
      require (wallet==nativeWallet c) "native_restore_wallet_mismatch"
      pure ()
    RestoreNativeWallet manifest -> do
      (_,backup,expected)<-restoreReady manifest
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
  restoreReady manifest=do
    (wallet,backup,_,expected)<-load manifest
    _<-nativeIdentityWith call c
    wallets<-call False "listwalletdir" [] >>= fieldValue "wallets" :: IO [Value]
    names<-mapM (fieldValue "name") wallets
    require (nativeWallet c `notElem` names) "native_restore_wallet_exists"
    pure (wallet,backup,expected)
  backupIdentity=digest . BL.toStrict . encode $ object
    ["profile" .= profile c,"wallet" .= nativeWallet c,"height" .= nativeCheckpointHeight c,"checkpoint" .= nativeCheckpointHash c]
  backup destination transferred = do
      _<-nativeIdentityWith call c
      privateParent destination
      let manifest=destination<>".json"
      absent destination
      absent manifest
      before<-descriptors
      if transferred then BackupTransfer.receive backupIdentity destination else do
        result<-call True "backupwallet" [toJSON destination]
        require (result==Null) "unexpected_rpc_schema"
      privateBackup destination
      after<-descriptors
      require (before==after) "native_wallet_changed_during_backup"
      sync destination
      checksum<-withBackupFile destination hashHandle
      let evidence=manifestValue (profile c) (nativeCheckpointHeight c) (nativeCheckpointHash c)
            (nativeWallet c) (takeFileName destination) checksum before
          encoded=encode evidence
      require (BL.length encoded<=1048576) "native_backup_manifest_too_large"
      bracket (openFd manifest WriteOnly defaultFileFlags
        {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True}) closeFd $ \fd->do
          withHandle fd $ \handle->BL.hPut handle encoded >> hFlush handle
          fileSynchronise fd
      sync (takeDirectory destination)
      pure manifest
  load manifest = do
    privateParent manifest
    bytes<-withBackupFile manifest (readBounded 1048576) >>= maybe (reject "native_backup_manifest_too_large") pure
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
    actual<-withBackupFile backup hashHandle
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
  -- Loading/rescanning replenishes lookahead and advances allocation indexes for
  -- addresses found on chain. Identity stays exact; neither range nor index may
  -- retreat, and the next allocation must remain within the restored keypool.
  sameDescriptor (Object before) (Object after)
    | identity before==identity after = case (KM.lookup "range" before,KM.lookup "range" after) of
        (Nothing,Nothing)->pure (before==after)
        (Just old,Just new)->do
          oldRange<-parseValue parseJSON old :: IO [Int64]
          newRange<-parseValue parseJSON new :: IO [Int64]
          case (oldRange,newRange) of
            ([lo,hi],[loNew,hiNew]) | 0<=lo && lo<=hi && loNew==lo && hiNew>=hi && hiNew<2147483648 ->
              and <$> mapM (indexForward lo hi hiNew) ["next","next_index"]
            _->pure False
        _->pure False
    where
      identity=KM.delete "next_index" . KM.delete "next" . KM.delete "range"
      indexForward lo hi hiNew key=case (KM.lookup key before,KM.lookup key after) of
        (Nothing,Nothing)->pure True
        (Just old,Just new)->do
          previous<-parseValue parseJSON old :: IO Int64
          current<-parseValue parseJSON new :: IO Int64
          pure (lo<=previous && previous<=hi+1 && previous<=current && current<=hiNew+1)
        _->pure False
  sameDescriptor _ _=pure False
  privateParent path = do
    require (isAbsolute path && normalise path==path) "invalid_native_backup_path"
    status<-getSymbolicLinkStatus (takeDirectory path)
    uid<-getEffectiveUserID
    require (isDirectory status && fileOwner status==uid && fileMode status .&. 0o077==0) "unsafe_native_backup_directory"
  privateBackup path = getSymbolicLinkStatus path >>= backupStatus
  backupStatus status = do
    uid<-getEffectiveUserID
    require (isRegularFile status && fileOwner status==uid && fileMode status .&. 0o077==0
      && linkCount status==1 && fileSize status>0) "unsafe_native_backup_file"
  withBackupFile path action=do
    privateBackup path
    bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd->do
        getFdStatus fd >>= backupStatus
        withHandle fd action
  sync path=bracket (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True}) closeFd fileSynchronise
