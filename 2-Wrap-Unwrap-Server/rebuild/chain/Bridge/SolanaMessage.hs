{-# LANGUAGE RecordWildCards #-}
module Bridge.SolanaMessage
  ( Instruction(..), Message(..), Transaction(..), Expected(..), publicKey
  , signatureBytes, base58, decodeTransaction, decodePoolTransaction, validateTransaction ) where

import Bridge.Domain (Amount, units)
import Bridge.Identity (publicKey)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import Control.Monad (replicateM, unless, when)
import Data.Binary.Get
import Data.Bits ((.&.), (.|.), shiftL)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base58 as B58
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub,sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8,Word64)

data Instruction = Instruction !Word8 ![Word8] !BS.ByteString deriving (Eq,Show)
data Message = Message !Word8 !Word8 !Word8 ![BS.ByteString] !BS.ByteString ![Instruction] deriving (Eq,Show)
data Transaction = Transaction ![BS.ByteString] !Message !BS.ByteString deriving (Eq,Show)
signatureBytes :: Text -> Either Text BS.ByteString
signatureBytes t
  | T.length t<64 || T.length t>88 = Left "invalid_signature"
  | otherwise = case B58.decodeBase58 B58.bitcoinAlphabet (TE.encodeUtf8 t) of
      Just bytes | BS.length bytes==64 -> Right bytes
      _ -> Left "invalid_signature"
base58 :: BS.ByteString -> Text
base58 = TE.decodeUtf8 . B58.encodeBase58 B58.bitcoinAlphabet
short :: Get Int
short = do
  a <- getWord8
  if a<128 then pure (fromIntegral a) else do
    b <- getWord8
    when (b==0 || b>=128) (fail "noncanonical_short_vector")
    pure (fromIntegral (a .&. 127) .|. (fromIntegral b `shiftL` 7))
bounded :: Int -> Get Int
bounded maxN = short >>= \n -> if n<=maxN then pure n else fail "vector_too_large"
decodeTransaction :: Text -> Either Text Transaction
decodeTransaction = decodeLegacy 1 3 8
-- Pool initialization has three writable signers and exactly one instruction.
-- This does not widen the custody decoder above.
decodePoolTransaction :: Text -> Either Text Transaction
decodePoolTransaction = decodeLegacy 3 1 11
decodeLegacy :: Int -> Int -> Int -> Text -> Either Text Transaction
decodeLegacy signerCount instructionLimit accountLimit encoded = do
  unless (T.length encoded<=1644) (Left "transaction_too_large")
  bytes <- either (const $ Left "invalid_base64") Right (B64.decode (TE.encodeUtf8 encoded))
  unless (BS.length bytes<=1232) (Left "transaction_too_large")
  case runGetOrFail (parser bytes) (LBS.fromStrict bytes) of
    Left _ -> Left "invalid_legacy_transaction"
    Right (rest,_,tx) | LBS.null rest -> Right tx
    _ -> Left "trailing_transaction_bytes"
 where
  parser bytes = do
    count <- bounded signerCount
    unless (count==signerCount) (fail "unexpected_signer_count")
    signatures <- replicateM count (getByteString 64)
    start <- bytesRead
    n <- getWord8; rs <- getWord8; ru <- getWord8
    unless (fromIntegral n==signerCount && rs==0) (fail "unexpected_header")
    keyCount <- bounded 16
    unless (keyCount>=signerCount && fromIntegral ru<=keyCount-signerCount) (fail "invalid_account_flags")
    keys <- replicateM keyCount (getByteString 32)
    unless (length (nub keys)==length keys) (fail "duplicate_account")
    blockhash <- getByteString 32
    instructionCount <- bounded instructionLimit
    instructions <- replicateM instructionCount $ do
      program <- getWord8
      accountCount <- bounded accountLimit
      accounts <- replicateM accountCount getWord8
      dataSize <- bounded 512 -- Metaplex strings can exceed 256; full transaction stays <=1232
      payload <- getByteString dataSize
      unless (all ((<keyCount) . fromIntegral) (program:accounts)) (fail "account_index_out_of_bounds")
      pure (Instruction program accounts payload)
    end <- bytesRead
    let body = BS.drop (fromIntegral start) bytes
    pure (Transaction signatures (Message n rs ru keys blockhash instructions) (BS.take (fromIntegral (end-start)) body))

data Expected = Expected
  { expectedOwner :: !Text, expectedRecipient :: !Text, expectedMint :: !Text
  , expectedSource :: !Text, expectedDestination :: !Text, expectedBlockhash :: !Text
  , expectedAmount :: !Amount, expectedMemo :: !Text, expectedCreateAta :: !Bool
  , expectedSigned :: !Bool
  } deriving (Eq,Show)
validateTransaction :: Expected -> Text -> Either Text Transaction
validateTransaction Expected{..} encoded = do
  unless (units expectedAmount>0 && BS.length (TE.encodeUtf8 expectedMemo)<=256) (Left "invalid_transaction_expectation")
  when (expectedSigned && not expectedCreateAta) (Left "payout_requires_ata_binding")
  tx@(Transaction signatures (Message _ _ readonly keys recent instructions) _) <- decodeTransaction encoded
  owner <- publicKey expectedOwner
  recipient <- publicKey expectedRecipient
  mint <- publicKey expectedMint
  source <- publicKey expectedSource
  destination <- publicKey expectedDestination
  blockhash <- publicKey expectedBlockhash
  token <- publicKey "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  memo <- publicKey "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
  ata <- publicKey "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
  system <- publicKey "11111111111111111111111111111111"
  unless (take 1 keys==[owner] && recent==blockhash && owner/=recipient && source/=destination) (Left "message_identity_mismatch")
  let at i = keys !! fromIntegral i -- decoder bounded every index
      semantic (Instruction p as d) = (at p,map at as,d)
      transfer = (token,[source,mint,destination,owner],BS.pack (12:little64 (fromIntegral (units expectedAmount))<>[8]))
      memoIx = (memo,[owner],TE.encodeUtf8 expectedMemo)
      create = (ata,[owner,destination,recipient,mint,system,token],BS.singleton 1)
      expected = (if expectedCreateAta then [create] else []) <> [transfer,memoIx]
      referenced = nub (owner:concat [program:accounts | (program,accounts,_) <- expected])
      writable = take (length keys-fromIntegral readonly) keys
  unless (map semantic instructions==expected && sort keys==sort referenced && sort writable==sort [owner,source,destination]) (Left "transaction_semantics_mismatch")
  unless (case signatures of [sig] -> if expectedSigned then BS.any (/=0) sig else BS.all (==0) sig; _ -> False) (Left "signature_shape_mismatch")
  when expectedSigned $ case (Ed.publicKey owner, signatures) of
    (CryptoPassed public, [sig]) -> case Ed.signature sig of
      CryptoPassed signature -> unless (Ed.verify public (case tx of Transaction _ _ body -> body) signature) (Left "invalid_signature")
      CryptoFailed _ -> Left "invalid_signature"
    _ -> Left "invalid_signature"
  pure tx
 where little64 :: Word64 -> [Word8]
       little64 n = [fromIntegral (n `div` (256^i)) | i <- [0..7::Int]]
