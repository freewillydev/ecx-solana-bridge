{-# LANGUAGE TemplateHaskell, CPP, ForeignFunctionInterface #-}
-- Offline BIP-39 English / SLIP-0010 ed25519. No RPC or signing authority.
module Bridge.Wallet (mnemonic, walletKey, nativeDescriptors, derivationPath, protectWalletProcess) where
import System.Posix.Resource (setResourceLimit,Resource(ResourceCoreFileSize),ResourceLimits(..),ResourceLimit(..))
#if defined(linux_HOST_OS)
import Bridge.Error (require)
import Foreign.C.Types (CInt(..),CULong(..))
#endif
import Bridge.SolanaMessage (base58)
import Control.Monad (unless)
import Crypto.Hash (Digest,SHA256,SHA512,RIPEMD160,hash)
import Crypto.PubKey.ECC.Types (getCurveByName,CurveName(SEC_p256k1),Point(..))
import Crypto.PubKey.ECC.Prim (pointBaseMul)
import qualified Data.Text as T
import Control.Monad (foldM)
import Data.ByteArray.Encoding (convertToBase,Base(Base16))
import Crypto.MAC.HMAC (HMAC,hmac)
import Crypto.KDF.PBKDF2 (Parameters(..),fastPBKDF2_SHA512)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Data.Bits (shiftR, (.&.))
import Data.List (elemIndex)
import Data.Text (Text)
import Data.Word (Word32)
import Language.Haskell.TH (location,loc_filename,runIO)
import Language.Haskell.TH.Syntax (addDependentFile,lift)
import System.FilePath ((</>),takeDirectory)

derivationPath :: String
derivationPath = "m/44'/501'/0'/0' (BIP-39 English, empty passphrase)"

-- The standard MIT-licensed BIP-39 English list is embedded at build time;
-- installed executables never load a mutable external word list.
wordList :: [String]
wordList = $(do
  loc<-location
  let path=takeDirectory (loc_filename loc)</>"bip39-english.txt"
  addDependentFile path
  contents<-runIO (readFile path)
  lift (words contents))

mnemonic :: B.ByteString -> Either Text String
mnemonic entropy=do
  unless (B.length entropy==16 && length wordList==2048) (Left "invalid_wallet_entropy")
  let checksum=B.head (BA.convert (hash entropy :: Digest SHA256)::B.ByteString) `shiftR` 4
      number=16*B.foldl' (\n b->256*n+fromIntegral b) (0::Integer) entropy+fromIntegral checksum
  pure $ unwords [wordList !! fromIntegral ((number `shiftR` offset) .&. 2047) | offset<-[121,110..0]]

-- Return standard Solana seed || public-key bytes, accepted by the existing signer.
-- Only canonical 12-word English phrases are accepted: normalization is unambiguous.
walletKey :: String -> Either Text B.ByteString
walletSeed :: String -> Either Text B.ByteString
walletSeed phrase=do
  let ws=words phrase
  unless (length ws==12 && unwords ws==phrase) (Left "invalid_wallet_mnemonic")
  indexes<-mapM (maybe (Left "invalid_wallet_mnemonic") Right . (`elemIndex` wordList)) ws
  let number=foldl' (\n i->2048*n+fromIntegral i) (0::Integer) indexes `shiftR` 4
      entropy=B.pack [fromIntegral (number `shiftR` offset) | offset<-[120,112..0]]
  expected<-mnemonic entropy
  unless (expected==phrase) (Left "invalid_wallet_mnemonic_checksum")
  pure $ fastPBKDF2_SHA512 (Parameters 2048 64) (B8.pack phrase) ("mnemonic"::B.ByteString)

walletKey phrase=do
  seed<-walletSeed phrase
  let child parent index=mac (B.drop 32 parent) (B.singleton 0<>B.take 32 parent<>B.pack
        [fromIntegral ((index+0x80000000) `shiftR` offset) | offset<-[24,16,8,0]])
      secret=B.take 32 $ foldl' child (mac ("ed25519 seed"::B.ByteString) seed) ([44,501,0,0]::[Word32])
  case Ed.secretKey secret of
    CryptoFailed _->Left "invalid_wallet_key"
    CryptoPassed key->Right (secret<>BA.convert (Ed.toPublic key))

mac :: B.ByteString -> B.ByteString -> B.ByteString
mac key input=BA.convert (hmac key input :: HMAC SHA512)

-- BIP-32 / BIP-84. Derive the hardened account here so the node's public
-- descriptor has no hardened xpub suffix. Preserve the root fingerprint/origin.
-- These contain private material: never show, log, or pass them in argv.
nativeDescriptors :: Bool -> String -> Either Text [Text]
nativeDescriptors signet phrase=do
  seed<-walletSeed phrase
  let master=mac "Bitcoin seed" seed
      order=0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141
      integer=B.foldl' (\n b->256*n+fromIntegral b) (0::Integer)
      bytes :: Int -> Integer -> B.ByteString
      bytes count value=B.pack [fromIntegral (value `shiftR` offset) | offset<-reverse [0,8..8*(count-1)]]
      sha value=BA.convert (hash value :: Digest SHA256)::B.ByteString
      fingerprint scalar=case pointBaseMul (getCurveByName SEC_p256k1) scalar of
        Point x y->Right $ B.take 4 (BA.convert (hash (sha $ B.singleton (if even y then 2 else 3)<>bytes 32 x) :: Digest RIPEMD160))
        PointO->Left "invalid_native_master_key"
      root=integer (B.take 32 master)
      coin :: Integer
      coin=if signet then 1 else 0
      child (parent,chain,_) index=do
        let result=mac chain (B.singleton 0<>bytes 32 parent<>bytes 4 (index+0x80000000))
            left=integer (B.take 32 result)
            scalar=(parent+left) `mod` order
        unless (left<order && scalar/=0) (Left "invalid_native_child_key")
        parentFingerprint<-fingerprint parent
        pure (scalar,B.drop 32 result,parentFingerprint)
  unless (root>0 && root<order) (Left "invalid_native_master_key")
  origin<-fingerprint root
  (key,chain,parent)<-foldM child (root,B.drop 32 master,B.empty) [84,coin,0]
  let version=if signet then [0x04,0x35,0x83,0x94] else [0x04,0x88,0xad,0xe4]
      payload=B.pack version<>B.singleton 3<>parent<>bytes 4 0x80000000<>chain<>B.singleton 0<>bytes 32 key
      extended=base58 (payload<>B.take 4 (sha $ sha payload))
      account=T.pack (B8.unpack (convertToBase Base16 origin))<>"/84h/"<>T.pack(show coin)<>"h/0h"
  pure ["wpkh(["<>account<>"]"<>extended<>"/"<>branch<>"/*)" | branch<-["0","1"]]

-- Refuse generation/import if process dump protection cannot be established.
-- PR_SET_DUMPABLE also covers Linux pipe-based core collectors, which may ignore
-- RLIMIT_CORE. Privileged monitoring and terminal recorders remain host policy.
protectWalletProcess :: IO ()
protectWalletProcess=do
  setResourceLimit ResourceCoreFileSize (ResourceLimits (ResourceLimit 0) (ResourceLimit 0))
#if defined(linux_HOST_OS)
  status<-prctl 4 0 0 0 0
  require (status==0) "wallet_dump_protection_failed"
#else
  pure ()
#endif
#if defined(linux_HOST_OS)
foreign import ccall unsafe "prctl" prctl :: CInt -> CULong -> CULong -> CULong -> CULong -> IO CInt
#endif
