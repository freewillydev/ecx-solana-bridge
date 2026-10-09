{-# LANGUAGE ForeignFunctionInterface #-}
-- Offline derivation primitive only; no signing, RPC or mutable global context.
module Bridge.NativeKey (deriveChild) where
import Crypto.Random (getRandomBytes)
import Control.Exception (finally)
import qualified Data.ByteString as B
import Foreign (Ptr,allocaBytes,castPtr,fillBytes)
import Foreign.C.Types (CInt(..))
import Data.Word (Word8)

-- Returns child scalar and compressed parent public key. A zero tweak validates
-- a master key without changing it. Invalid scalars/zero children fail closed.
deriveChild :: B.ByteString -> B.ByteString -> IO (Maybe (B.ByteString,B.ByteString))
deriveChild parent tweak
  | B.length parent/=32 || B.length tweak/=32 = pure Nothing
  | otherwise = do
      randomness<-getRandomBytes 32
      B.useAsCString parent $ \p -> B.useAsCString tweak $ \t ->
        B.useAsCString randomness $ \r -> allocaBytes 32 $ \child -> allocaBytes 33 $ \public -> do
          (do
            ok<-nativeChild (castPtr p) (castPtr t) (castPtr r) child public
            if ok/=1 then pure Nothing else do
              secret<-B.packCStringLen (castPtr child,32)
              pub<-B.packCStringLen (castPtr public,33)
              pure (Just (secret,pub))) `finally` fillBytes child 0 32

foreign import ccall unsafe "ecx_native_child"
  nativeChild :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> IO CInt
