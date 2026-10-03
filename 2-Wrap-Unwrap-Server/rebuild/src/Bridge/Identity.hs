-- Exact baseline capability hashing; raw tokens never become persisted IDs.
module Bridge.Identity (digest, capabilityHash, bearerHash,payInstruction,publicKey) where
import Crypto.Hash (Digest,SHA256,hash)
import qualified Data.ByteArray.Encoding as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Hex
import qualified Data.ByteString.Base58 as B58
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

digest :: ByteString -> Text
digest bytes=TE.decodeUtf8 (BA.convertToBase BA.Base16 (hash bytes :: Digest SHA256))
capabilityHash :: Text -> Either Text Text
capabilityHash token
  | T.length token==64 && T.all (`elem` ("0123456789abcdef"::String)) token =
      Right (digest $ TE.encodeUtf8 $ "ecx-capability-v1:"<>token)
  | otherwise=Left "invalid_capability"
bearerHash :: Text -> Either Text Text
bearerHash header=maybe (Left "authorization_required") capabilityHash (T.stripPrefix "Bearer " header)

-- Same order-derived Solana Pay reference as the original bridge.
payInstruction :: Text -> Either Text Text
payInstruction identifier = do
  raw <- either (const $ Left "invalid_order_reference") Right (Hex.decode $ TE.encodeUtf8 identifier)
  if BS.length raw/=32 then Left "invalid_order_reference" else
    Right ("solana-pay:"<>TE.decodeUtf8 (B58.encodeBase58 B58.bitcoinAlphabet raw))

publicKey :: Text -> Either Text BS.ByteString
publicKey value
  | T.length value<32 || T.length value>44 = Left "invalid_public_key"
  | otherwise = case B58.decodeBase58 B58.bitcoinAlphabet (TE.encodeUtf8 value) of
      Just bytes | BS.length bytes==32 -> Right bytes
      _ -> Left "invalid_public_key"
