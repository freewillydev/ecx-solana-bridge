module Bridge.Native where

import Bridge.Config
import Bridge.RPC
import Bridge.Types
import Control.Exception (catch,throwIO)
import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Int (Int64)
import Data.Scientific (Scientific, coefficient, base10Exponent)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Manager)

nativeCall :: Manager -> Config -> Bool -> Text -> [Value] -> IO Value
nativeCall manager c wallet methodName params = do
  cookie <- BS.readFile (nativeCookie c)
  require (BS.length cookie <= 4096) "invalid_rpc_cookie"
  let (username,rest) = BC.break (==':') (BC.takeWhile (/='\n') cookie)
  require (not (BS.null username) && BS.length rest>1) "invalid_rpc_cookie"
  let url = nativeRpc c <> if wallet then "/wallet/" <> T.unpack (nativeWallet c) else ""
  rpc manager url (Just (username,BS.drop 1 rest)) methodName params
nativeIdentity :: Manager -> Config -> IO Value
nativeIdentity manager c = do
  info <- nativeCall manager c False "getblockchaininfo" []
  name <- fieldValue "chain" info :: IO Text
  syncing <- fieldValue "initialblockdownload" info
  require (not syncing) "native_synchronizing"
  height <- fieldValue "blocks" info :: IO Int64
  require (height >= nativeCheckpointHeight c) "native_checkpoint_unavailable"
  actual <- nativeCall manager c False "getblockhash" [toJSON (nativeCheckpointHeight c)] >>= parseValue parseJSON
  require (actual==nativeCheckpointHash c) "native_checkpoint_mismatch"
  if profile c==L2LSignetDevnet
    then do
      challenge <- fieldValue "signet_challenge" info
      require (name=="signet" && challenge==signetChallenge) "wrong_signet"
    else require (name=="main") "wrong_ecx_chain"
  peers <- nativeCall manager c False "getconnectioncount" [] >>= parseValue parseJSON :: IO Int
  require (peers>0) "native_no_peers"
  pure info
validateNativeRecipient :: Manager -> Config -> Text -> IO Text
validateNativeRecipient manager c = validateNativeRecipientWith (nativeCall manager c)
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
nativeWalletReadyWith :: (Bool -> Text -> [Value] -> IO Value) -> Config -> Int64 -> IO ()
nativeWalletReadyWith call c now = do
  wallet <- call True "getwalletinfo" []
  name <- fieldValue "walletname" wallet
  descriptors <- fieldValue "descriptors" wallet
  keys <- fieldValue "private_keys_enabled" wallet
  external <- fieldValue "external_signer" wallet
  scanning <- fieldValue "scanning" wallet :: IO Value
  unlocked <- parseValue (withObject "wallet" (.:? "unlocked_until")) wallet :: IO (Maybe Int64)
  require (name==nativeWallet c && descriptors && keys && not external && scanning==Bool False
    && maybe True (>now) unlocked) "native_wallet_not_ready"

-- A durable ledger claim supplies fresh=True exactly once. Recovery only reads
-- the saved label; absent/ambiguous evidence never permits a second allocation.
recoverNativeAddressWith :: (Bool -> Text -> [Value] -> IO Value) -> Config -> Int64 -> Bool -> Text -> IO Text
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
nativeHistory :: Manager -> Config -> Maybe Text -> Int -> IO Value
nativeHistory manager c anchor depth = nativeCall manager c True "listsinceblock" [maybe Null toJSON anchor,toJSON depth,Bool False,Bool True]
nativeAmount :: Scientific -> Either Text Amount
nativeAmount n
  | abs (base10Exponent n) > 20 || abs (coefficient n) > 1000000000000000000000000000000 = Left "native_amount_out_of_range"
  | e>=0 = amount (coefficient n * 10^e)
  | otherwise = let (a,r) = coefficient n `divMod` (10^negate e) in if r==0 then amount a else Left "native_excess_precision"
 where e=base10Exponent n+8
nativeNumber :: Amount -> Value
nativeNumber a = Number (fromIntegral (units a) / 100000000)
broadcastNative :: Manager -> Config -> Text -> IO Text
broadcastNative manager c signed = nativeCall manager c True "sendrawtransaction" [toJSON signed] >>= parseValue parseJSON
