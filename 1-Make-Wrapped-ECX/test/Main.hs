module Main (main) where
import Token
import qualified Bridge.AdminStatus as Status
import qualified Token.Network as N
import qualified Data.Aeson.KeyMap as KM
import qualified Token.Operation as O
import qualified Token.Metadata as M
import Token.Signing
import Crypto.Hash (hash,Digest,SHA256)
import qualified Data.Text.Encoding as TE
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import qualified Data.ByteString.Lazy as L
import System.IO (openTempFile,hClose)
import System.Directory (removeDirectoryRecursive,removeFile)
import qualified System.Posix.Directory as PD
import System.Posix.Files (setFileMode,createSymbolicLink)
import System.FilePath ((</>))
import qualified Bridge.SolanaHelper as H
import Bridge.Domain (amount)
import Data.Word (Word64)
import Data.Aeson (Value(..),encode,eitherDecode,object,(.=),withObject,(.:))
import Data.Aeson.Types (parseEither)
import Bridge.SDKBuild (sdkLibraryPath)
import Bridge.SolanaMessage (Transaction(..),decodeTransaction,base58)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.Either (isLeft)
import Control.Exception (SomeException,try,bracket)
import System.Exit (exitFailure)
import Test.QuickCheck

request :: Action -> Word64 -> Request
request operation n=Request operation "AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9"
  "GyGKxMyg1p9SsHfm15MkNUu1u9TN2JtTspcdmrtGUdse" "13KoHDCDXebtaN59JpGpQCmhsk8u7qk9H9FFSCMyynLh"
  n "GgBaCs3NCBuZN12kCJgAW63ydqohFkHEdfdEXBPzLHq"
main :: IO ()
main=do
  results<-sequence
    [ quickCheckResult $ statusContract
    , quickCheckResult $ \n revoked->policyCheck n revoked
    , quickCheckResult $ once $ ioProperty $ do
        let original=request Mint 1
            run a b=try (O.runSafe $ O.Request $ N.InspectPolicy N.Devnet a b (mint original) (authority original) (account original) Nothing) :: IO (Either SomeException [(Word64,Word64,Word64)])
        and <$> mapM (\(a,b)->isLeft <$> run a b)
          [("https://rpc.example.invalid","https://RPC.EXAMPLE.INVALID"),("https://rpc.example.invalid","https://rpc.example.invalid."),("http://one.invalid","https://two.invalid")]
    , quickCheckWithResult stdArgs {maxSuccess=100} $ forAll (frequency [(1,elements [1,maxBound::Word64]),(4,choose (1,maxBound::Word64))]) $ \n->ioProperty $ do
        checks<-mapM (check n) [Mint,Burn]
        pure (and checks)
    , quickCheckResult $ once $ ioProperty $ do
        let original=request Mint 3
            money n=case amount n of Right a->a; Left _->error "invalid fixture amount"
            recipient="9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu"
            config=H.SolanaPolicy "codec-fixture" "unused" (mint original) recipient (account original) (money 10000) (money 2100000)
            transfer=H.HelperRequest False (authority original) recipient (money 3) (blockhash original) "order-1"
        reply<-H.invokeUnsignedHelper sdkLibraryPath config transfer
        pure (H.replySignature reply==Nothing && H.replyDestination reply==account original)
    , quickCheckWithResult stdArgs {maxSuccess=40} $ forAll (choose (1,32)) $ \size->ioProperty $ do
        let owner=authority(request Mint 1)
            label=T.replicate size "x"
        derived<-(O.runSafe . O.Request) (MintAddress owner label)
        let creation=CreateMint owner derived label 1461600 (blockhash $ request Mint 1)
        transaction<-(O.runSafe . O.Request) (Prepare sdkLibraryPath creation)
        pure (eitherDecode(encode creation)==Right creation && not(isLeft $ validate creation transaction)
          && isLeft(validate creation {rent=1} transaction)
          && isLeft(validate creation {seed="different"} transaction)
          && isLeft(validate creation {mint=mint(request Mint 1)} transaction)
          && isLeft(mintAddress owner (T.replicate 33 "x")))
    , quickCheckWithResult stdArgs {maxSuccess=40} $ forAll (choose (1,32)) $ \size->ioProperty $ do
        let original=request Mint 1
        address<-(O.runSafe . O.Request) (MetadataAddress sdkLibraryPath $ mint original)
        checks<-mapM (\creation->do
          let terms=M.Terms creation address (T.replicate size "x") "TEST" "" 20000000
              operation=Metadata (authority original) (mint original) terms (blockhash original)
          transaction<-(O.runSafe . O.Request) (Prepare sdkLibraryPath operation)
          pure $ eitherDecode(encode operation)==Right operation && not(isLeft $ validate operation transaction)
            && all (\changed->isLeft $ validate operation {metadata=changed} transaction)
               [terms {M.name="different"},terms {M.symbol="DIFF"},terms {M.uri="https://example.com/token.json"}
               ,terms {M.create=not creation},terms {M.address=mint original}]
            && isLeft(validate operation {authority=account original} transaction)
            && isLeft(validate operation {blockhash=mint original} transaction)
          ) [True,False]
        pure (and checks)
    , quickCheckResult $ once $ ioProperty $ do
        let original=request Mint 1
        address<-(O.runSafe . O.Request) (MetadataAddress sdkLibraryPath $ mint original)
        let terms=M.Terms True address (T.replicate 16 "é") "1234567890" ("https://"<>T.replicate 192 "x") 20000000
            operation=Metadata (authority original) (mint original) terms (blockhash original)
        transaction<-(O.runSafe . O.Request) (Prepare sdkLibraryPath operation)
        pure (not(isLeft $ validate operation transaction)
          && all (isLeft . M.checkTerms) [terms {M.name=T.replicate 17 "é"},terms {M.symbol="12345678901"}
            ,terms {M.uri=T.replicate 201 "x"},terms {M.name="bad\0name"},terms {M.maxCost=0}])
    -- Exact legacy messages generated using the unmodified Metaplex 5.1.1 builders.
    , quickCheckResult $ once $ ioProperty $ do
        let original=request Mint 1
            reference="H8pXsNTmVfo2RF7qQ39xGwzGyhNRhHvHhWny5FB7qA6h"
        address<-(O.runSafe . O.Request) (MetadataAddress sdkLibraryPath $ mint original)
        hashes<-mapM (\creation->do
          let terms=M.Terms creation address "ECX Test" "TEST" "" 20000000
          transaction<-(O.runSafe . O.Request) (Prepare sdkLibraryPath $ Metadata (authority original) (mint original) terms (blockhash original))
          pure (show (hash (TE.encodeUtf8 transaction) :: Digest SHA256))) [True,False]
        pure (address==reference && hashes==["0640af0794fb42396d44234c5cf720e05a2d13cf6cec79d42ead25656e1da0d1", "d90662feccbc56229eaca30a40ee94eef9a20f79257a67b877c5e10e56a69e71"])
    , quickCheckResult $ once $ ioProperty $ do
        let original=request Mint 1
        captured<-(O.runSafe . O.Request) (AssociatedAddress sdkLibraryPath "HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg" "Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM")
        checks<-mapM (\recipient->do
          address<-(O.runSafe . O.Request) (AssociatedAddress sdkLibraryPath recipient (mint original))
          let operation=Associated (authority original) (mint original) address recipient 2039280 (blockhash original)
          transaction<-(O.runSafe . O.Request) (Prepare sdkLibraryPath operation)
          pure (eitherDecode(encode operation)==Right operation && not(isLeft $ validate operation transaction)
            && isLeft(validate operation {account=mint original} transaction)
            && isLeft(validate operation {owner=mint original} transaction)
            && isLeft(validate operation {mint=account original} transaction)
            && isLeft(validate operation {blockhash=mint original} transaction)
            && isLeft(validate operation {rent=0} transaction)))
          [authority original,"9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu"]
        pure (captured=="GQnRnfs2B9j6pymrbY4KmX9WnAQ6czPAdt2u6XpWZSjQ" && and checks)
    , quickCheckResult $ once $ ioProperty signingCheck
    , quickCheckResult $ once $ property $
        eitherDecode (encode $ request Mint maxBound)==Right(request Mint maxBound)
        && all (\raw->isLeft (eitherDecode (encode $ object
          ["protocol" .= (1::Int),"verb" .= ("mint"::Text),"authority" .= authority (request Mint 1)
          ,"mint" .= mint (request Mint 1),"account" .= account (request Mint 1)
          ,"blockhash" .= blockhash (request Mint 1),"amount" .= (raw::Text)]) :: Either String Request))
          ["0","01","-1","+1","1.0","1e1","18446744073709551616"]
    , quickCheckResult $ once $ ioProperty $ do
        refused<-try (O.runSafe $ O.Request $ Prepare sdkLibraryPath $ request Mint 0) :: IO (Either SomeException Text)
        pure (isLeft refused)
    ]
  if all isSuccess results then pure () else exitFailure
 where
  check n operation=do
    let original=request operation n
    encoded<-(O.runSafe . O.Request) (Prepare sdkLibraryPath original)
    pure $ case validate original encoded of
      Right (Transaction signatures _ _) -> signatures==[B.replicate 64 0] && and
        [ isLeft $ validate original {action=if operation==Mint then Burn else Mint} encoded
        , isLeft $ validate original {quantity=if n==1 then 2 else 1} encoded
        , isLeft $ validate original {account=mint original} encoded
        , isLeft $ validate original {authority=account original} encoded
        , isLeft $ validate original {blockhash=mint original} encoded ]
      _ -> False

-- Only disposable fixture keys are signed, never the real Devnet authority.
signingCheck :: IO Bool
signingCheck=bracket temporary removeDirectoryRecursive $ \directory->do
  let seed=B.replicate 32 1
      secret=case Ed.secretKey seed of CryptoPassed key->key; _->error "fixture seed"
      public=BA.convert (Ed.toPublic secret) :: B.ByteString
      keyfile=directory </> "authority.json"
      output=directory </> "attempt.json"
      original=(request Mint 7) {authority=base58 public}
      refuse action= isLeft <$> (try action :: IO (Either SomeException Text))
  L.writeFile keyfile (encode $ B.unpack $ seed<>public)
  setFileMode keyfile 0o600
  let generatedPath=directory </> "generated.json"
  generatedOwner<-(O.runCritical . O.Request) (GenerateKey generatedPath)
  generatedBytes<-B.readFile generatedPath
  generatedRefusal<-refuse $ (O.runCritical . O.Request) (GenerateKey generatedPath)
  generatedUnchanged<-(==generatedBytes) <$> B.readFile generatedPath
  let generatedOperation=(request Mint 1) {authority=generatedOwner}
  generatedUnsigned<-(O.runSafe . O.Request) (Prepare sdkLibraryPath generatedOperation)
  _<-(O.runCritical . O.Request) (Sign generatedPath (directory </> "generated-attempt.json") generatedOperation generatedUnsigned)
  unsigned<-(O.runSafe . O.Request) (Prepare sdkLibraryPath original)
  mismatch<-refuse $ (O.runCritical . O.Request) (Sign keyfile output original {quantity=8} unsigned)
  identifier<-(O.runCritical . O.Request) (Sign keyfile output original unsigned)
  saved<-B.readFile output
  duplicate<-refuse $ (O.runCritical . O.Request) (Sign keyfile output original unsigned)
  unchanged<-(==saved) <$> B.readFile output
  createSymbolicLink keyfile (directory </> "linked.json")
  symlink<-refuse $ (O.runCritical . O.Request) (Sign (directory </> "linked.json") (directory </> "other.json") original unsigned)
  setFileMode keyfile 0o644
  permissions<-refuse $ (O.runCritical . O.Request) (Sign keyfile (directory </> "other.json") original unsigned)
  setFileMode keyfile 0o600
  let wrong=(request Mint 7) {authority="9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu"}
  altered<-(O.runSafe . O.Request) (Prepare sdkLibraryPath wrong)
  wrongAuthority<-refuse $ (O.runCritical . O.Request) (Sign keyfile (directory </> "other.json") wrong altered)
  L.writeFile keyfile (encode $ replicate 64 (256::Integer))
  wrappedBytes<-refuse $ (O.runCritical . O.Request) (Sign keyfile (directory </> "other.json") original unsigned)
  L.writeFile keyfile (encode $ B.unpack $ seed<>B.replicate 32 0)
  wrongPublicHalf<-refuse $ (O.runCritical . O.Request) (Sign keyfile (directory </> "other.json") original unsigned)
  validated<-case eitherDecode (L.fromStrict saved) of
    Right record->pure $ validateSaved record==Right unsigned
      && isLeft(validateSaved record {savedId="wrong"})
      && isLeft(validateSaved record {savedRequest=original {quantity=8}})
      && isLeft(validateSaved record {savedTransaction=unsigned})
    Left _->pure False
  -- Decode only the transaction field; independently verify the actual signature.
  case eitherDecode (L.fromStrict saved) of
    Left _->pure False
    Right record->case parseEither (withObject "attempt" (.: "transaction")) record >>= either (Left . show) Right . decodeTransaction of
      Right (Transaction [bytes] _ body)->case Ed.signature bytes of
        CryptoPassed signature->pure (all id [mismatch,duplicate,unchanged,symlink,permissions,wrongAuthority,wrappedBytes,wrongPublicHalf,validated,generatedRefusal,generatedUnchanged]
          && base58 bytes==identifier && Ed.verify (Ed.toPublic secret) body signature)
        _->pure False
      _->pure False
 where
  temporary=do
    (path,handle)<-openTempFile "/tmp" "ecx-token-sign"
    hClose handle; removeFile path; PD.createDirectory path 0o700
    pure path

-- Actual classic SPL response shape; mutations are parser contracts, not a network.
policyCheck :: Word64 -> Bool -> Bool
policyCheck n revoked=
  let original=request Mint 1; key=mint original; owner=authority original
      issuer=if revoked then Nothing else Just owner
      accountValue size kind info=object ["owner" .= ("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"::Text),"executable" .= False,
        "data" .= object ["space" .= (size::Int),"parsed" .= object ["type" .= (kind::Text),"info" .= info]]]
      mintInfo=object ["isInitialized" .= True,"decimals" .= (8::Int),"freezeAuthority" .= Null,"mintAuthority" .= issuer,"supply" .= show n]
      tokenInfo=object ["mint" .= key,"owner" .= owner,"state" .= ("initialized"::Text),"isNative" .= False,
        "tokenAmount" .= object ["decimals" .= (8::Int),"amount" .= show n]]
      mintValue=accountValue 82 "mint" mintInfo; custodyValue=accountValue 165 "account" tokenInfo
      response a b slot=object ["context" .= object ["slot" .= (slot::Int)],"value" .= [a,b]]
      parse=parseEither (N.inspectPolicy key owner issuer)
      set field value (Object o)=Object(KM.insert field value o)
      set _ _ value=value
      badMints=[accountValue 82 "mint" (set field value mintInfo) | (field,value)<-
        [("isInitialized",Bool False),("decimals",Number 9),("freezeAuthority",String owner),("mintAuthority",String key),("supply",String "-1"),("supply",String "18446744073709551616")]]
      badAccounts=[accountValue 165 "account" (set field value tokenInfo) | (field,value)<-
        [("mint",String owner),("owner",String key),("state",String "frozen"),("delegate",String key),("closeAuthority",String key),("isNative",Bool True)]]
  in parse(response mintValue custodyValue 1)==Right(1,n,n)
    && all (isLeft . parse) ([response a custodyValue 1 | a<-badMints]<>[response mintValue a 1 | a<-badAccounts]
      <>[response mintValue custodyValue 0,response (set "owner" (String owner) mintValue) custodyValue 1,
         response mintValue (accountValue 166 "account" tokenInfo) 1])

statusContract :: Bool -> Bool -> Bool
statusContract failed valid=
  let failure=if failed then object ["InstructionError" .= ([Number 0,String "Custom"]::[Value])] else Null
      status commitment=object ["confirmationStatus" .= (commitment::Text),"err" .= failure]
      transaction bytes err=object ["transaction" .= ([bytes,"base64"]::[Text]),"meta" .= object ["err" .= err]]
      classify=Status.classifyStatus "saved-bytes"
      rejected result=case result of Left _->True; _->False
  in classify Null Null valid==Right(if valid then Status.Unseen else Status.ExpiredUnseen)
    && classify (status "confirmed") Null valid==Right Status.Pending
    && classify (status "processed") Null valid==Right Status.Pending
    && classify (status "finalized") (transaction "saved-bytes" failure) valid==Right(if failed then Status.Failed else Status.Finalized)
    && all rejected
      [classify Null (transaction "saved-bytes" failure) valid
      ,classify (status "confirmed") (transaction "saved-bytes" failure) valid
      ,classify (status "finalized") Null valid
      ,classify (status "finalized") (transaction "different-bytes" failure) valid
      ,classify (status "finalized") (transaction "saved-bytes" $ if failed then Null else Number 1) valid
      ,classify (status "unknown") Null valid]
