-- Stream mechanics only: callers first validate the opened descriptor against
-- their fixed policy. This module cannot open a pathname or choose permissions.
module Bridge.File (withHandle,readBounded,hashHandle) where

import Control.Exception (bracket,onException)
import Crypto.Hash (Context,Digest,SHA256,hashInit,hashUpdate,hashFinalize)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (Handle,hClose)
import System.Posix.IO (dup,fdToHandle,closeFd,setFdOption,FdOption(CloseOnExec))
import System.Posix.Types (Fd)

withHandle :: Fd -> (Handle -> IO a) -> IO a
withHandle fd = bracket (do
  copy<-dup fd
  (setFdOption copy CloseOnExec True >> fdToHandle copy) `onException` closeFd copy) hClose

readBounded :: Int -> Handle -> IO (Maybe B.ByteString)
readBounded limit handle
  | limit<0 || limit==maxBound = pure Nothing
  | otherwise = do
      bytes<-B.hGet handle (limit+1)
      pure $ if B.length bytes<=limit then Just bytes else Nothing

hashHandle :: Handle -> IO Text
hashHandle = go hashInit
 where
  go :: Context SHA256 -> Handle -> IO Text
  go context handle = do
    bytes<-B.hGet handle 65536
    if B.null bytes then pure (T.pack $ show (hashFinalize context :: Digest SHA256))
      else go (hashUpdate context bytes) handle
