-- Captured finalized Devnet proofs and offline SDK/RPC contracts, never sends.
module SolanaPaymentCheck (checks) where
import Bridge.Domain (Amount, Asset(..), amount, units, earnedFees, payment)
import Bridge.Payment
import Bridge.Store
import qualified Bridge.Wire as W
import qualified Data.ByteString.Lazy as BL
import Bridge.Error
import Bridge.RPC (fieldValue)
import Bridge.Solana (tokenProgram)
import Bridge.SolanaHelper
import Bridge.SolanaMessage
import Bridge.SolanaPayment
import Control.Exception (try)
import Data.Aeson hiding (Result)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.IORef
import Data.Bits (xor)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Paths_ecx_bridge_rebuild (getDataFileName)
import Test.QuickCheck

checks :: IO [Result]
checks=do
  fixture <- readFixture "signed-three-units.json"
  unsignedFixture <- readFixture "unsigned-three-units.json"
  unsignedReply <- fieldValue "reply" unsignedFixture
  reply <- fieldValue "reply" fixture
  owner <- fieldValue "owner" fixture
  recipient <- fieldValue "recipient" fixture
  token <- fieldValue "mint" fixture
  hash <- fieldValue "blockhash" fixture
  let config=SolanaPolicy "codec-fixture" "offline-policy" token owner (replySource reply) (amt 10000) (amt 2100000)
      plan=SolanaPlan (fingerprint config) recipient (amt 3) "order-1" (RecentBlockhash hash 1000 100) (maxSolFee config) (maxSolAccountRent config)
      request=solanaPayoutRequest config plan
      call destination method _=case method of
        "getBlockHeight"->pure (Number 900)
        "getFeeForMessage"->pure (context $ Number 5000)
        "getMultipleAccounts"->pure $ context $ toJSON [tokenAccount config owner,destination,systemAccount 10000000]
        "getMinimumBalanceForRentExemption"->pure (Number 1488440)
        "simulateTransaction"->pure $ context $ object ["err" .= Null]
        _->fail ("unexpected RPC: "<>T.unpack method)
      prepare p rpcCall=prepareSolanaSigned rpcCall (const $ pure reply) config p
  workflowFixture <- readFixture "signed-payment-workflow.json"
  workflowReply <- fieldValue "reply" workflowFixture
  identifier <- fieldValue "paymentId" workflowFixture
  funding <- either reject pure (earnedFees (T.drop 4 identifier) Wrapped $ amt 3)
  outgoing <- either reject pure (payment identifier funding recipient)
  let encoded value=TE.decodeUtf8 (BL.toStrict $ encode value)
      boundPlan=plan {solPlanReference=payoutReference (fingerprint config) identifier}
      boundRequest=solanaPayoutRequest config boundPlan
      terms=W.PaymentTerms (W.PolicySnapshot 1 "finalized" $ fingerprint config)
        (W.CostLimits (amt 1) (maxSolFee config) (maxSolAccountRent config))
      prepared=PreparedPayment (PaymentView outgoing terms PaymentPaying) 0 (encoded boundPlan)
        (Just $ encoded boundRequest) (amt 2110000)
      signed=SolanaSigned boundPlan workflowReply (amt 5000) (amt 1488440)
      verify=verifySigningReply (\_ _ _->fail "Solana validation must not call native RPC") W.L2LSignetDevnet config
  proofResults <- mapM captured ["new","existing"]
  local <- sequence
    [ check "payment workflow verifies SDK bytes bound to earned funding and saved reference" $ once $ ioProperty $ do
        attempt<-verify prepared (SolanaReply signed)
        wrongReference<-rejects "saved_solana_policy_mismatch" $ resolveSigningPlan W.L2LSignetDevnet config
          prepared {preparedPolicy=encoded boundPlan {solPlanReference="order-1"}}
        wrongFee<-rejects "invalid_saved_payment" $ verify prepared (SolanaReply signed {signedSolanaFeeEstimate=amt 10001})
        wrongSignature<-rejectsAny $ verify prepared (SolanaReply signed {signedSolanaReply=workflowReply {replyTransaction=replyTransaction reply}})
        pure (Just (signedId attempt)==replySignature workflowReply && signedBytes attempt==replyTransaction workflowReply
          && commonInput attempt==Nothing && wrongReference && wrongFee && wrongSignature)
    , check "Solana signed SDK vector binds identity message and signature" $ once $
        isRight (validateHelperReply config request reply) &&
        all (isLeft . validateHelperReply config request)
          [reply {replyProtocol=2},reply {replyMemo="wrong"},reply {replySignature=Nothing},
           reply {replySource=replyDestination reply},reply {replyMessage="AAAA"}] &&
        isLeft (validateUnsignedHelperReply config request reply)
    , check "Solana unsigned deposit vector remains signature-free" $ once $
        isRight (validateHelperReply config {custodyOwner=recipient,custodyAta=replyDestination unsignedReply}
          request {helperPayout=False} unsignedReply)
    , check "Solana signature corruption is rejected" $ forAll (chooseInt (1,64)) $ \index ->
        let bytes=either error id (B64.decode $ TE.encodeUtf8 $ replyTransaction reply)
            corrupted=BS.take index bytes<>BS.singleton (BS.index bytes index `xor` 1)<>BS.drop (index+1) bytes
        in isLeft (validateHelperReply config request reply {replyTransaction=TE.decodeUtf8 $ B64.encode corrupted})
    , check "Solana amount mutation cannot reuse signature" $ forAll (chooseInteger (4,1000000000)) $ \n ->
        isLeft (validateHelperReply config request {helperAmount=amt n} reply)
    , check "Solana packet and message bounds apply before base64 decoding" $ once $
        decodeTransaction (T.replicate 1645 "A")==Left "transaction_too_large" &&
        isLeft (validateHelperReply config request reply {replyMessage=T.replicate 1645 "A"})
    , check "Solana simulation preserves message but removes usable signature" $ once $ ioProperty $ do
        calls<-newIORef ([]::[Text])
        let rpcCall method args=do
              modifyIORef' calls (<>[method])
              case (method,args) of
                ("simulateTransaction",[String encoded,options])->do
                  Transaction signatures _ body<-either reject pure (decodeTransaction encoded)
                  sigVerify<-fieldValue "sigVerify" options
                  replaceHash<-fieldValue "replaceRecentBlockhash" options
                  require (signatures==[BS.replicate 64 0] && TE.decodeUtf8(B64.encode body)==replyMessage reply && not sigVerify && not replaceHash) "unsafe_simulation"
                _->pure ()
              call Null method args
        signed<-prepare plan rpcCall
        methods<-readIORef calls
        pure (signedSolanaFeeEstimate signed==amt 5000 && signedSolanaRentEstimate signed==amt 1488440 && "sendTransaction" `notElem` methods)
    , check "Solana rent counts only required top-up and never goes negative" $ forAll (chooseInteger (0,3000000)) $ \prefunded -> ioProperty $ do
        signed<-prepare plan (call $ systemAccount prefunded)
        pure (toInteger(units $ signedSolanaRentEstimate signed)==max 0 (1488440-prefunded))
    , check "existing recipient ATA needs no rent" $ once $ ioProperty $ do
        signed<-prepare plan (call $ tokenAccount config recipient)
        pure (signedSolanaRentEstimate signed==amt 0)
    , check "Solana preparation rejects stale context expired hash missing/excess fees and failed simulation" $ once $ ioProperty $ do
        let cases=[("getBlockHeight",Number 970,"solana_blockhash_window_too_short"),
              ("getFeeForMessage",context Null,"solana_fee_unavailable"),
              ("getFeeForMessage",context $ Number 10001,"solana_fee_above_limit"),
              ("getMultipleAccounts",object ["context" .= object ["slot" .= (99::Int)],"value" .= Null],"solana_context_too_old"),
              ("simulateTransaction",context $ object ["err" .= String "failure"],"solana_simulation_failed")]
        and <$> mapM (\(method,value,code)->rejects code $ prepare plan (\m args->if m==method then pure value else call Null m args)) cases
    , check "Solana operating rent and fee ceilings are mandatory" $ once $ ioProperty $ do
        fees<-rejects "solana_fee_above_limit" (prepare plan {solPlanFeeLimit=amt 1} $ call Null)
        rent<-rejects "solana_rent_above_limit" (prepare plan {solPlanRentLimit=amt 1} $ call Null)
        identity<-rejects "saved_solana_policy_mismatch" (prepare plan {solPlanFingerprint="wrong"} $ call Null)
        pure (fees && rent && identity)
    ]
  pure (proofResults<>local)
 where
  captured kind=do
    fixture<-readFixture ("solana-devnet-"<>kind<>"-payment.json")
    signed<-fieldValue "signed" fixture
    proof<-fieldValue "transaction" fixture
    outcome<-fieldValue "outcome" fixture
    let config=SolanaPolicy "l2l-devnet-local" "027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8"
          "Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM" "RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX"
          "CKXz4AWgfRjw5YK17P64TgXuaci2QKAD7J1vZ9X2mNvT" (amt 10000) (amt 2100000)
        validate=verifySolanaOutcome config signed
        changed=[replace ["slot"] (Number 0) proof,replace ["meta","fee"] (Number 1) proof,
          replace ["transaction","signatures"] (toJSON ["wrong"::Text]) proof,
          replace ["meta","postTokenBalances"] (toJSON ([]::[Value])) proof,
          replace ["meta","err"] (String "failure") proof]
    check ("captured finalized Devnet "<>kind<>"-ATA payment and evidence mutations") $ once $
      validate proof==Right outcome && all (isLeft . validate) changed &&
      verifySolanaOutcome config {maxSolFee=amt 1,maxSolAccountRent=amt 0} signed proof==Right outcome

readFixture :: FilePath -> IO Value
readFixture name=getDataFileName ("test/fixtures/"<>name) >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
check :: Testable prop => String -> prop -> IO Result
check name p=putStrLn name >> quickCheckWithResult stdArgs {maxSuccess=100} p
amt :: Integer -> Amount
amt n=either (error . T.unpack) id (amount n)
isLeft :: Either a b -> Bool
isLeft (Left _)=True
isLeft _=False
isRight :: Either a b -> Bool
isRight=not . isLeft
rejects :: Text -> IO a -> IO Bool
rejects code action=do
  result<-try action
  pure $ case result of Left(BridgeError actual)->actual==code; Right _->False
context :: Value -> Value
context value=object ["context" .= object ["slot" .= (100::Int)],"value" .= value]
systemAccount :: Integer -> Value
systemAccount n=object ["owner" .= ("11111111111111111111111111111111"::Text),"executable" .= False,"data" .= ["","base64"::Text],"lamports" .= (n::Integer)]
tokenAccount :: SolanaPolicy -> Text -> Value
tokenAccount c owner=object ["owner" .= tokenProgram,"executable" .= False,"data" .= object
  ["space" .= (165::Int),"parsed" .= object ["type" .= ("account"::Text),"info" .= object
    ["mint" .= mint c,"owner" .= owner,"state" .= ("initialized"::Text),"isNative" .= False,
     "tokenAmount" .= object ["amount" .= ("100000000000"::Text),"decimals" .= (8::Int)]]]]]
replace :: [Key] -> Value -> Value -> Value
replace [] replacement _=replacement
replace (key:rest) replacement (Object fields)=Object $ KM.insert key (replace rest replacement $ maybe Null id $ KM.lookup key fields) fields
replace _ _ value=value

rejectsAny :: IO a -> IO Bool
rejectsAny action = do
  result <- try (action >> pure ())
  pure $ case result of Left (BridgeError _)->True; Right _->False
