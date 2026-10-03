-- Exact baseline capability hashing; raw tokens never become persisted IDs.
module Bridge.Identity (digest, capabilityHash, bearerHash) where
import Crypto.Hash (Digest,SHA256,hash)
import qualified Data.ByteArray.Encoding as BA
import Data.ByteString (ByteString)
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
