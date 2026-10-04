module Main (main) where
import Pool
import qualified Pool.Operation as O
import qualified Pool.Signing as S
import qualified Pool.Position as P
import qualified Pool.Liquidity as Q
import qualified Crypto.PubKey.Ed25519 as Ed
import Crypto.Error (CryptoFailable(..))
import qualified Data.ByteArray as BA
import Bridge.SolanaMessage (decodeTransaction,decodePoolTransaction,decodePositionTransaction,decodeLiquidityTransaction,Transaction(..),Message(..),base58)
import Data.Bits (xor)
import Data.Word (Word64)
import Bridge.SDKBuild (sdkLibraryPath)
import Bridge.AdminStatus (Recovery(..),attemptPath)
import Bridge.Identity (digest)
import Paths_ecx_pool (getDataFileName)
import Data.Aeson
import Data.Aeson.Types (parseEither,Parser)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as L
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
  (collectRequest,collectBefore,collectAfter)<-either fail pure $ parseEither (withObject "fixture" $ \o->do
    o .: "simulatedCollection" >>= withObject "collection" (\v->do
      r<-v .: "request"
      before<-v .: "before" >>= withObject "snapshot" (\b->Snapshot <$> b .: "slot" <*> b .: "accounts")
      afterSlot<-v .: "afterSlot"; changes<-v .: "afterChanges" :: Parser [(Int,Value)]
      let after=Snapshot afterSlot [maybe original id (lookup index changes) | (index,original)<-zip [0..] (accounts before)]
      pure(r,before,after))) fixture
  let request=Create "3psSKHRPopKXPcBajcm2crjoKzrUtWyfsqeprTRMxAqZ" (expectedA expected) (expectedB expected)
        "HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg" "AzNd4srpctGzR5Q7LqkQh6aUwwqNEveTcCTNX8uHixDC"
        (2^(64::Int)) (pool expected)
  prepared<-(O.runSafe . O.Request) (Prepare sdkLibraryPath Devnet request)
  bytes<-either fail pure $ B64.decode $ TE.encodeUtf8 $ unsignedTransaction prepared
  secrets<-mapM (\n->case Ed.secretKey (B.replicate 32 n) of CryptoPassed key->pure key; _->fail "test key") [1,2,3]
  let publics=map (base58 . BA.convert . Ed.toPublic) secrets
  signingRequest<-case publics of
    [owner,a,b]->pure request {payer=owner,createVaultA=a,createVaultB=b}
    _->fail "test keys"
  signingPrepared<-(O.runSafe . O.Request) (Prepare sdkLibraryPath Devnet signingRequest)
  Transaction _ (Message _ _ _ signingKeys _ _) message<-either (fail . show) pure $ decodePoolTransaction(unsignedTransaction signingPrepared)
  signatures<-mapM (\key->case lookup (base58 key) (zip publics secrets) of
    Just secret->pure (BA.convert (Ed.sign secret (Ed.toPublic secret) message) :: B.ByteString)
    Nothing->fail "test signer") (take 3 signingKeys)
  first<-case signatures of sig:_->pure sig; _->fail "test signature"
  let signedBytes=B.singleton 3<>B.concat signatures<>message
      saved=S.Saved Devnet (S.Creation signingRequest signingPrepared) 20000 20000000 (base58 first) (TE.decodeUtf8 $ B64.encode signedBytes) Nothing
  openingRequest<-case publics of
    owner:mint:_->pure positionRequest {P.payer=owner,P.positionMint=mint}
    _->fail "position test keys"
  openingPrepared<-(O.runSafe . O.Request) (P.Prepare sdkLibraryPath openingRequest)
  Transaction _ _ openingMessage<-either (fail . show) pure $ decodePositionTransaction(P.transaction openingPrepared)
  let openingSignatures=[BA.convert(Ed.sign secret (Ed.toPublic secret) openingMessage) :: B.ByteString | secret<-take 2 secrets]
  openingFirst<-case openingSignatures of first:_->pure first; _->fail "position signature"
  let openingBytes=B.singleton 2<>B.concat openingSignatures<>openingMessage
      openingSaved=S.Saved Devnet (S.Opening openingRequest openingPrepared) 20000 20000000 (base58 openingFirst) (TE.decodeUtf8 $ B64.encode openingBytes) Nothing
  let liquidityRequests=[Q.Request action positionRequest quantity
        (if action==Q.Collect then 0 else 1000) (if action==Q.Collect then 0 else 1000)
        (createVaultA creation) (createVaultB creation) | (action,quantity)<-[(Q.Deposit,1000),(Q.Withdraw,1000),(Q.Collect,0),(Q.Collect,1000)]]
  liquidityPreparations<-mapM (O.runSafe . O.Request . Q.Prepare sdkLibraryPath) liquidityRequests
  liquiditySigned<-mapM (\original->do
    let r=original {Q.positionRequest=openingRequest}
    p<-(O.runSafe . O.Request) (Q.Prepare sdkLibraryPath r)
    Transaction _ _ msg<-either (fail . show) pure $ decodeLiquidityTransaction(Q.transaction p)
    secret<-case secrets of key:_->pure key; _->fail "liquidity key"
    let sig=BA.convert(Ed.sign secret (Ed.toPublic secret) msg) :: B.ByteString
        tx=TE.decodeUtf8 $ B64.encode $ B.singleton 1<>sig<>msg
    pure(S.Saved Devnet (S.Liquidity r p) 20000 20000000 (base58 sig) tx Nothing)) liquidityRequests
  let tracked=map withRecovery (saved:openingSaved:liquiditySigned)
  children<-mapM (successor secrets) tracked
  changed<-mapM (successor secrets . changeIntent (last publics)) tracked
  let divergent=zipWith (\old child->child {S.savedRecovery=(\r->r {recoveryParent=Just(digest $ L.toStrict $ encode old)}) <$> S.savedRecovery child}) tracked changed
  results<-sequence
    [ quickCheckResult $ once $ property $ and
        [not(isLeft $ S.validateSaved child) && isLeft(S.validateChild old (digest $ L.toStrict $ encode old) child)
        | (old,child)<-zip tracked divergent]
    , quickCheckResult $ once $ property $ and [
        let parentHash=digest (L.toStrict $ encode old)
            valid candidate=not(isLeft $ S.validateChild old parentHash candidate)
        in valid child && (eitherDecode(encode child) :: Either String S.Saved)==Right child
          && B.length (L.toStrict $ encode child)<=8192
          && not(valid child {S.feeLimit=S.feeLimit child+1})
          && not(valid child {S.costLimit=S.costLimit child+1})
          && not(valid child {S.network=Mainnet})
          && not(valid child {S.action=S.action old})
          && not(valid child {S.savedRecovery=Nothing})
          && isLeft(S.validateChild old "incorrect-file-hash" child)
          && isLeft(S.validateChild old {S.savedRecovery=Nothing} parentHash child)
          && all (\change->not(valid child {S.savedRecovery=change <$> S.savedRecovery child}))
            [\r->r {recoveryGeneration=0},\r->r {recoveryGeneration=2}
            ,\r->r {recoveryGeneration=8},\r->r {recoveryRoot="/tmp/copied-pool.json"}
            ,\r->r {recoveryBlockhash=recoveryOrigin r},\r->r {recoveryEvidence=Nothing}
            ,\r->r {recoverySlot=0}]
        | (old,child)<-zip tracked children]
    , quickCheckResult $ once $ property $ all (\record->
        not(isLeft $ S.validateSaved record) && (eitherDecode(encode record) :: Either String S.Saved)==Right record
        && case toJSON record of
          Object fields->all (\bad->case fromJSON(Object bad) :: Result S.Saved of Error _->True; _->False)
            [KM.insert "recovery" Null fields,KM.insert "unexpected" Null fields]
          _->False) tracked
    , quickCheckResult $ quoteContract expected
    , quickCheckResult $ once $ property $ all (\record->
        not(isLeft $ S.validateSaved record) && (eitherDecode(encode record) :: Either String S.Saved)==Right record
        && isLeft(S.validateSaved record {S.identifier=S.identifier openingSaved})
        && isLeft(S.validateSaved record {S.action=S.action openingSaved})) liquiditySigned
    , quickCheckResult $ once $ property $
        Q.validateEffects Devnet collectRequest 5000 10000 collectBefore collectAfter==Right(Q.Effect 0 0 0 10000)
        && isLeft(Q.validateEffects Devnet collectRequest 5000 9999 collectBefore collectAfter)
        && isLeft(Q.validateEffects Mainnet collectRequest 5000 10000 collectBefore collectAfter)
        && isLeft(Q.validateEffects Devnet collectRequest {Q.liquidity=1} 5000 10000 collectBefore collectAfter)
        && all (\after->isLeft $ Q.validateEffects Devnet collectRequest 5000 10000 collectBefore after)
          [mutateByte collectAfter 9 64,mutateByte collectAfter 4 64,mutateByte collectAfter 6 72,mutateByte collectAfter 8 32]
    , quickCheckResult $ once $ property $ and
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
        derived<-(O.runSafe . O.Request) (Address sdkLibraryPath Mainnet (expectedA expected) (expectedB expected) 1034)
        devnet<-(O.runSafe . O.Request) (Address sdkLibraryPath Devnet (expectedA expected) (expectedB expected) 1034)
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


-- These pure archives exercise all closed pool actions; no RPC or key-file IO.
withRecovery :: S.Saved -> S.Saved
withRecovery saved=saved {S.savedRecovery=Just $ Recovery (networkGenesis $ S.network saved)
  owner (S.feeLimit saved) "/tmp/ecx-pool-test.json" 0 Nothing recent
  (S.identifier saved) 90 100 200 Nothing}
 where
  (owner,recent)=case S.action saved of
    S.Creation r _->(payer r,recentBlockhash r)
    S.Opening r _->(P.payer r,P.blockhash r)
    S.Liquidity r _->let p=Q.positionRequest r in (P.payer p,P.blockhash p)


-- Independently valid signatures must not authorize changed economic intent.
changeIntent :: Text -> S.Saved -> S.Saved
changeIntent replacement saved=saved {S.action=case S.action saved of
  S.Creation r p->S.Creation r {initialPrice=initialPrice r+1} p
  S.Opening r p->S.Opening r {P.positionMint=replacement} p
  S.Liquidity r p->S.Liquidity r {Q.liquidity=Q.liquidity r+1} p}

successor :: [Ed.SecretKey] -> S.Saved -> IO S.Saved
successor secrets old=do
  before<-maybe (fail "test recovery") pure (S.savedRecovery old)
  let recent=base58 (B.replicate 32 7)
      context=before {recoveryGeneration=1,recoveryParent=Just(digest $ L.toStrict $ encode old)
        ,recoveryBlockhash=recent,recoverySlot=101,recoveryLastHeight=201
        ,recoveryEvidence=Just $ object ["outcome" .= ("expired-unseen"::Text)]}
  (operation,decode)<-case S.action old of
    S.Creation r _->do
      let next=r {recentBlockhash=recent}
      p<-(O.runSafe . O.Request) (Prepare sdkLibraryPath (S.network old) next)
      pure(S.Creation next p,decodePoolTransaction $ unsignedTransaction p)
    S.Opening r _->do
      let next=r {P.blockhash=recent}
      p<-(O.runSafe . O.Request) (P.Prepare sdkLibraryPath next)
      pure(S.Opening next p,decodePositionTransaction $ P.transaction p)
    S.Liquidity r _->do
      let next=r {Q.positionRequest=(Q.positionRequest r) {P.blockhash=recent}}
      p<-(O.runSafe . O.Request) (Q.Prepare sdkLibraryPath next)
      pure(S.Liquidity next p,decodeLiquidityTransaction $ Q.transaction p)
  Transaction empty (Message _ _ _ keys _ _) message<-either (fail . show) pure decode
  let sources=[(base58 $ BA.convert $ Ed.toPublic key,key) | key<-secrets]
  signatures<-mapM (\key->case lookup (base58 key) sources of
    Nothing->fail "test successor signer"
    Just secret->pure(BA.convert(Ed.sign secret (Ed.toPublic secret) message) :: B.ByteString)) (take (length empty) keys)
  first<-case signatures of sig:_->pure sig; _->fail "test successor signature"
  let child=old {S.action=operation,S.identifier=base58 first,S.savedRecovery=Just context
        ,S.transaction=TE.decodeUtf8 $ B64.encode $ B.singleton (fromIntegral $ length signatures)<>B.concat signatures<>message}
  if attemptPath context=="/tmp/ecx-pool-test.json.retry" then pure child else fail "test successor path"

-- Change one byte of a captured account without inventing another chain response.
mutateByte :: Snapshot -> Int -> Int -> Snapshot
mutateByte snapshot accountIndex offset=snapshot {accounts=[if index==accountIndex then change value else value | (index,value)<-zip [0..] (accounts snapshot)]}
 where
  change (Object fields)=case KM.lookup "data" fields of
    Just value->case fromJSON value :: Result [Text] of
      Success [encoded,"base64"]->case B64.decode(TE.encodeUtf8 encoded) of
        Right bytes | offset<B.length bytes->Object(KM.insert "data" (toJSON [TE.decodeUtf8 $ B64.encode $
          B.take offset bytes<>B.singleton((B.index bytes offset) `xor` 1)<>B.drop (offset+1) bytes,"base64"]) fields)
        _->Null
      _->Null
    _->Null
  change _=Null

-- Generated amounts and one-field adversarial mutations exercise the route contract.
quoteContract :: Expected -> Positive Word64 -> Positive Word64 -> Property
quoteContract expected (Positive input) (Positive output)=
  let info=object ["ammKey" .= pool expected,"inputMint" .= expectedA expected,"outputMint" .= expectedB expected,"label" .= ("Whirlpool"::Text)]
      leg=object ["bps" .= (10000::Int),"swapInfo" .= info]
      good=object ["inputMint" .= expectedA expected,"outputMint" .= expectedB expected
        ,"inAmount" .= show input,"outAmount" .= show output,"swapMode" .= ("ExactIn"::Text)
        ,"transaction" .= Null,"routePlan" .= [leg],"router" .= ("metis"::Text),"feeBps" .= (10::Int)]
      change field value (Object fields)=Object(KM.insert field value fields)
      change _ _ value=value
      bad=[change field value good | (field,value)<-
        [("inputMint",String $ expectedB expected),("outputMint",String $ expectedA expected)
        ,("inAmount",String "0"),("swapMode",String "ExactOut"),("transaction",String "signed-bytes")
        ,("taker",String $ pool expected),("errorCode",Number 0),("feeBps",Number 10001)
        ,("routePlan",toJSON ([]::[Value])),("routePlan",toJSON [leg,leg])]]
        <>[change "outAmount" (String n) good | n<-["","0","-1","01","1.0","1e2","18446744073709551616","123456789012345678901"]]
        <>[change "routePlan" (toJSON [changed]) good | changed<-
          [change "bps" (Number 9999) leg]
          <>[change "swapInfo" (change field (String $ pool expected<>"x") info) leg | field<-["ammKey","inputMint","outputMint"]]]
  in counterexample "quote binding/amount/route rejection" $
    validateQuote expected input good==Right(output,Just "metis",Just "Whirlpool",Just 10)
    && validateQuote expected input (change "transaction" (String "") good)==validateQuote expected input good
    && isLeft(validateQuote expected 0 good)
    && validateQuote expected input (change "outAmount" (String "18446744073709551615") good)
      ==Right(maxBound,Just "metis",Just "Whirlpool",Just 10)
    && all (isLeft . validateQuote expected input) bad
