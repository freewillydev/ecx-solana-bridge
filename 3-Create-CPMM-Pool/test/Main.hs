module Main (main) where
import Pool
import Bridge.SolanaMessage (decodeTransaction)
import Data.Bits (xor)
import Bridge.SDKBuild (sdkLibraryPath)
import Paths_ecx_pool (getDataFileName)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import Data.Either (isLeft)
import System.Exit (exitFailure)
import Test.QuickCheck hiding (Success,Result)
main :: IO ()
main=do
  fixture<-getDataFileName "test/published-pool.json" >>= B.readFile >>= either fail pure . eitherDecodeStrict'
  (expected,snapshot)<-either fail pure $ parseEither (withObject "captured pool" $ \o->do
    expected<-Expected <$> o .: "pool" <*> o .: "mintA" <*> o .: "mintB"
    snapshot<-Snapshot <$> o .: "slot" <*> o .: "accounts"
    pure (expected,snapshot)) fixture
  let request=Create "3psSKHRPopKXPcBajcm2crjoKzrUtWyfsqeprTRMxAqZ" (expectedA expected) (expectedB expected)
        "HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg" "AzNd4srpctGzR5Q7LqkQh6aUwwqNEveTcCTNX8uHixDC"
        (2^(64::Int)) (pool expected)
  prepared<-evalSafe (Prepare sdkLibraryPath Devnet request)
  bytes<-either fail pure $ B64.decode $ TE.encodeUtf8 $ unsignedTransaction prepared
  results<-sequence
    [ quickCheckResult $ once $ property $
        not(isLeft $ validatePrepared Devnet request prepared)
        && isLeft(decodeTransaction $ unsignedTransaction prepared)
        && isLeft(validatePrepared Mainnet request prepared)
        && all (\r->isLeft $ validatePrepared Devnet r prepared)
          [request {initialPrice=initialPrice request+1},request {recentBlockhash=payer request}
          ,request {payer=createVaultA request},request {createVaultA=createVaultB request}
          ,request {createMintA=createMintB request}]
        && all (\index->let changed=B.take index bytes<>B.singleton((B.index bytes index) `xor` 1)<>B.drop (index+1) bytes
           in isLeft $ validatePrepared Devnet request prepared {unsignedTransaction=TE.decodeUtf8 $ B64.encode changed}) [0..B.length bytes-1]
    , quickCheckResult $ once $ ioProperty $ do
        derived<-evalSafe (Address sdkLibraryPath Mainnet (expectedA expected) (expectedB expected) 1034)
        devnet<-evalSafe (Address sdkLibraryPath Devnet (expectedA expected) (expectedB expected) 1034)
        pure (derived==pool expected && devnet/=derived && not(isLeft $ validate Mainnet expected snapshot))
    , quickCheckResult $ once $ property $
        isLeft(validate Devnet expected snapshot)
        && isLeft(validate Mainnet expected {expectedA=expectedB expected} snapshot)
        && isLeft(validate Mainnet expected {pool=expectedA expected} snapshot)
        && isLeft(validate Mainnet expected snapshot {slot= -1})
        && isLeft(validate Mainnet expected snapshot {accounts=take 5 $ accounts snapshot})
    , quickCheckWithResult stdArgs {maxSuccess=100} $ forAll (choose (0,5)) $ \index->
        let rewrite field value= snapshot {accounts=[if n==index then case account of
              Object fields->Object(KM.insert field value fields)
              _->Null else account | (n,account)<-zip [0::Int ..] (accounts snapshot)]}
        in all (isLeft . validate Mainnet expected)
          [rewrite "owner" (String "11111111111111111111111111111111"),rewrite "executable" (Bool True)
          ,rewrite "data" (toJSON (["","base64"]::[String]))]
    , quickCheckResult $ once $ property $
        let corrupt accountIndex offset byte= snapshot {accounts=[if n==accountIndex then change value else value
              | (n,value)<-zip [0::Int ..] (accounts snapshot)]}
             where
              change (Object fields)=case KM.lookup "data" fields >>= parseData of
                Just bytes->Object(KM.insert "data" (toJSON [TE.decodeUtf8 $ B64.encode $ B.take offset bytes<>B.singleton byte<>B.drop (offset+1) bytes,"base64"]) fields)
                Nothing->Null
              change _=Null
              parseData value=case fromJSON value :: Result [Text] of
                Success [text,"base64"]->either (const Nothing) Just (B64.decode $ TE.encodeUtf8 text)
                _->Nothing
        in all (isLeft . validate Mainnet expected)
          [corrupt 0 0 0,corrupt 0 8 0,corrupt 0 42 0,corrupt 0 92 255,corrupt 1 0 0
          ,corrupt 2 45 0,corrupt 3 45 0,corrupt 4 0 0,corrupt 4 32 0
          ,corrupt 4 72 1,corrupt 5 108 2,corrupt 5 129 1]
    ]
  if all isSuccess results then pure () else exitFailure
