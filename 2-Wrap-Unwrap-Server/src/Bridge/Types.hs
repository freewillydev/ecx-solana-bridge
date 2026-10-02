{-# LANGUAGE DerivingStrategies #-}
module Bridge.Types
  ( Amount, amount, units, parseUnits, parseCoins, renderCoins, feeFor
  , Direction(..), Asset(..), sourceAsset, destinationAsset, feeBps
  , OrderRequest(..), Quote(..), makeQuote, PolicySnapshot(..), OrderView(..), Availability(..)
  , BridgeError(..), reject, require, digest, randomId, capabilityHash, validIdentifier
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Bridge.Model
import qualified Data.ByteArray.Encoding as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Hex
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data BridgeError = BridgeError !Text deriving stock (Eq, Show)
instance Exception BridgeError
reject :: Text -> IO a
reject = throwIO . BridgeError
require :: Bool -> Text -> IO ()
require b msg = unless b (reject msg)
digest :: BS.ByteString -> Text
digest b = TE.decodeUtf8 (BA.convertToBase BA.Base16 (hash b :: Digest SHA256))
randomId :: IO Text
randomId = TE.decodeUtf8 . Hex.encode <$> (getRandomBytes 32 :: IO BS.ByteString)
capabilityHash :: Text -> Either Text Text
capabilityHash t
  | T.length t == 64 && T.all (\c -> asciiDigit c || c >= 'a' && c <= 'f') t = Right (digest (TE.encodeUtf8 ("ecx-capability-v1:" <> t)))
  | otherwise = Left "invalid_capability"
validIdentifier :: Text -> Bool
validIdentifier t = not (T.null t) && T.length t <= 64 && T.all (\c -> asciiDigit c || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '-' || c == '_') t
