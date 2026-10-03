module Main (main) where
import Pool
import qualified Pool.Signing as S
import qualified Pool.Position as P
import qualified Pool.Liquidity as Q
import qualified Crypto.PubKey.Ed25519 as Ed
import Crypto.Error (CryptoFailable(..))
import qualified Data.ByteArray as BA
import Bridge.SolanaMessage (decodeTransaction,decodePoolTransaction,decodePositionTransaction,Transaction(..),Message(..),base58)
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
  (creation,creationPrepared,creationSnapshot)<-either fail pure $ parseEither (withObject "fixture" $ \o->do
    value<-o .: "simulatedCreation"
    withObject "simulation" (\c->do
      request<-c .: "request"; prepared<-c .: "prepared"
      snapshot<-c .: "snapshot" >>= withObject "snapshot" (\x->Snapshot <$> x .: "slot" <*> x .: "accounts")
      pure(request,prepared,snapshot)) value) fixture
  (positionRequest,positionPrepared,positionAccounts)<-either fail pure $ parseEither (withObject "fixture" $ \o->do
    o .: "simulatedPosition" >>= withObject "simulation" (\v->(,,) <$> v .: "request" <*> v .: "prepared" <*> v .: "accounts")) fixture
  positionBytes<-either fail pure $ B64.decode $ TE.encodeUtf8 $ P.transaction positionPrepared
  let request=Create "3psSKHRPopKXPcBajcm2crjoKzrUtWyfsqeprTRMxAqZ" (expectedA expected) (expectedB expected)
        "HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg" "AzNd4srpctGzR5Q7LqkQh6aUwwqNEveTcCTNX8uHixDC"
        (2^(64::Int)) (pool expected)
  prepared<-evalSafe (Prepare sdkLibraryPath Devnet request)
  bytes<-either fail pure $ B64.decode $ TE.encodeUtf8 $ unsignedTransaction prepared
  secrets<-mapM (\n->case Ed.secretKey (B.replicate 32 n) of CryptoPassed key->pure key; _->fail "test key") [1,2,3]
  let publics=map (base58 . BA.convert . Ed.toPublic) secrets
  signingRequest<-case publics of
    [owner,a,b]->pure request {payer=owner,createVaultA=a,createVaultB=b}
    _->fail "test keys"
  signingPrepared<-evalSafe (Prepare sdkLibraryPath Devnet signingRequest)
  Transaction _ (Message _ _ _ signingKeys _ _) message<-either (fail . show) pure $ decodePoolTransaction(unsignedTransaction signingPrepared)
  signatures<-mapM (\key->case lookup (base58 key) (zip publics secrets) of
    Just secret->pure (BA.convert (Ed.sign secret (Ed.toPublic secret) message) :: B.ByteString)
    Nothing->fail "test signer") (take 3 signingKeys)
  first<-case signatures of sig:_->pure sig; _->fail "test signature"
  let signedBytes=B.singleton 3<>B.concat signatures<>message
      saved=S.Saved Devnet (S.Creation signingRequest signingPrepared) 20000 20000000 (base58 first) (TE.decodeUtf8 $ B64.encode signedBytes)
  openingRequest<-case publics of
    owner:mint:_->pure positionRequest {P.payer=owner,P.positionMint=mint}
    _->fail "position test keys"
  openingPrepared<-P.evalSafe(P.Prepare sdkLibraryPath openingRequest)
  Transaction _ _ openingMessage<-either (fail . show) pure $ decodePositionTransaction(P.transaction openingPrepared)
  let openingSignatures=[BA.convert(Ed.sign secret (Ed.toPublic secret) openingMessage) :: B.ByteString | secret<-take 2 secrets]
  openingFirst<-case openingSignatures of first:_->pure first; _->fail "position signature"
  let openingBytes=B.singleton 2<>B.concat openingSignatures<>openingMessage
      openingSaved=S.Saved Devnet (S.Opening openingRequest openingPrepared) 20000 20000000 (base58 openingFirst) (TE.decodeUtf8 $ B64.encode openingBytes)
  let liquidityRequests=[Q.Request action positionRequest (if action==Q.Collect then 0 else 1000)
        (if action==Q.Collect then 0 else 1000) (if action==Q.Collect then 0 else 1000)
        (createVaultA creation) (createVaultB creation) | action<-[Q.Deposit,Q.Withdraw,Q.Collect]]
  liquidityPreparations<-mapM (Q.evalSafe . Q.Prepare sdkLibraryPath) liquidityRequests
  results<-sequence
    [ quickCheckResult $ once $ property $ and
        [not(isLeft $ Q.validate r p) && (eitherDecode (encode r) :: Either String Q.Request)==Right r
          && isLeft(Q.validate r {Q.vaultA=Q.vaultB r} p)
          && isLeft(Q.validate r {Q.positionRequest=(Q.positionRequest r) {P.blockhash=P.pool positionRequest}} p)
          && isLeft(decodeTransaction $ Q.transaction p)
          && case B64.decode(TE.encodeUtf8 $ Q.transaction p) of
            Left _->False
            Right wire->all (\index->isLeft $ Q.validate r p {Q.transaction=TE.decodeUtf8 $ B64.encode $
              B.take index wire<>B.singleton((B.index wire index) `xor` 1)<>B.drop (index+1) wire}) [0..B.length wire-1]
        | (r,p)<-zip liquidityRequests liquidityPreparations]
    , quickCheckResult $ once $ property $ and
        [case toJSON r of
          Object fields->all (\bad->case fromJSON(Object(KM.insert "liquidity" (String bad) fields)) :: Result Q.Request of Error _->True; _->False)
            ["-1","00","1.0","340282366920938463463374607431768211456"]
          _->False | r<-liquidityRequests]
    , quickCheckResult $ once $ property $
        not(isLeft $ S.validateSaved openingSaved)
        && (eitherDecode (encode openingSaved) :: Either String S.Saved)==Right openingSaved
        && isLeft(S.validateSaved openingSaved {S.action=S.action saved})
        && isLeft(S.validateSaved saved {S.action=S.action openingSaved})
        && all (\index->isLeft $ S.validateSaved openingSaved {S.transaction=TE.decodeUtf8 $ B64.encode $
          B.take index openingBytes<>B.singleton((B.index openingBytes index) `xor` 1)<>B.drop (index+1) openingBytes}) [1..128]
    , quickCheckResult $ once $ property $
        not(isLeft $ P.validate positionRequest positionPrepared)
        && not(isLeft $ P.validateOpened positionRequest positionAccounts)
        && isLeft(P.validateOpened positionRequest {P.payer=P.positionMint positionRequest} positionAccounts)
        && isLeft(P.validateOpened positionRequest {P.pool=P.payer positionRequest} positionAccounts)
        && isLeft(P.validate positionRequest {P.blockhash=P.pool positionRequest} positionPrepared)
        && isLeft(decodeTransaction $ P.transaction positionPrepared)
        && all (\index->isLeft $ P.validate positionRequest positionPrepared {P.transaction=TE.decodeUtf8 $ B64.encode $
          B.take index positionBytes<>B.singleton((B.index positionBytes index) `xor` 1)<>B.drop (index+1) positionBytes}) [0..B.length positionBytes-1]
    , quickCheckResult $ once $ property $
        not(isLeft $ S.validateSaved saved)
        && (eitherDecode (encode saved) :: Either String S.Saved)==Right saved
        && isLeft(S.validateSaved saved {S.identifier=payer signingRequest})
        && isLeft(S.validateSaved saved {S.network=Mainnet})
        && all (\index->isLeft $ S.validateSaved saved {S.transaction=TE.decodeUtf8 $ B64.encode $
             B.take index signedBytes<>B.singleton((B.index signedBytes index) `xor` 1)<>B.drop (index+1) signedBytes}) [1..192]
    , quickCheckResult $ once $ property $
        let check r p rate=validateCreated Devnet r p rate creationSnapshot
        in not(isLeft(check creation creationPrepared 10000))
          && isLeft(check creation {initialPrice=initialPrice creation+1} creationPrepared 10000)
          && isLeft(check creation {createVaultA=createVaultB creation} creationPrepared 10000)
          && isLeft(check creation creationPrepared 10001)
          && isLeft(validateCreated Mainnet creation creationPrepared 10000 creationSnapshot)
          && not(isLeft(validatePrepared Devnet creation creationPrepared))
    , quickCheckResult $ once $ property $
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
