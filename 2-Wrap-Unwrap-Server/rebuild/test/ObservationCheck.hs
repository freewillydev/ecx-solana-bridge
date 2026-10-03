-- Captured Devnet deposit; Pay/v0 rewrites below are offline parser contracts.
module ObservationCheck (checks) where
import Bridge.Domain (Amount, Asset(..), amount, units)
import qualified Bridge.Wire as W
import Bridge.Error
import Bridge.RPC (fieldValue)
import Bridge.Solana (SignatureInfo(..),collectSignatures,tokenProgram)
import Bridge.SolanaDeposit
import Bridge.SolanaMessage (base58)
import Control.Exception (try)
import Data.Aeson hiding (Result)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.IORef
import Data.List (elemIndex)
import Data.Text (Text)
import qualified Data.Text as T
import Paths_ecx_bridge_rebuild (getDataFileName)
import Test.QuickCheck

checks :: IO [Result]
checks=do
  captured<-fixture "solana-devnet-order-deposit.json"
  binding<-fieldValue "binding" captured
  expected<-DepositBinding <$> fieldValue "signature" binding <*> fieldValue "owner" binding
    <*> fieldValue "mint" binding <*> fieldValue "custody" binding <*> fieldValue "custodyOwner" binding <*> fieldValue "memo" binding
  proof<-fieldValue "transaction" captured
  quantity<-fieldValue "expectedAmount" captured
  message<-fieldValue "transaction" proof >>= fieldValue "message"
  keys<-fieldValue "accountKeys" message :: IO [Text]
  instructions<-fieldValue "instructions" message :: IO [Value]
  reference<-either reject pure (payReference $ T.replicate 64 "f")
  index<-maybe (fail "memo program missing") pure (elemIndex "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr" keys)
  transferred<-mapM (\ix->do
    program<-fieldValue "programIdIndex" ix
    accounts<-fieldValue "accounts" ix :: IO [Int]
    pure (keys!!program,replace ["accounts"] (toJSON $ accounts<>[index]) ix)) instructions
  let payProof=replace ["transaction","message","accountKeys"] (toJSON [if i==index then reference else key | (i,key)<-zip [0..] keys]) $
        replace ["transaction","message","instructions"] (toJSON [ix | (program,ix)<-transferred,program==tokenProgram]) proof
      pay=PayBinding (boundSignature expected) (boundMint expected) (boundCustody expected) (boundCustodyOwner expected) reference
      effect=custodyEffect (boundSignature expected) (boundMint expected) (boundCustody expected) (boundCustodyOwner expected)
  versioned<-versionZero (boundCustody expected) payProof
  local<-sequence
    [ check "treasury outflows separate native fees token value and SOL debit" $ forAll (chooseInteger (1,1000000)) $ \n ->
        let raw=T.pack(show $ negate n)
        in W.economicOutflow "Native" (object ["walletNetUnits" .= raw,"feeUnits" .= amt 1])==Right (Native,amt(n+1),amt 1) &&
          W.economicOutflow "Solana" (object ["delta" .= raw])==Right (Wrapped,amt n,amt 0) &&
          W.economicOutflow "SolanaOperating" (object ["delta" .= raw,"feeUnits" .= amt 1])==Right (Sol,amt n,amt 1)
    , check "treasury evidence refuses noncanonical oversized or nonnegative outflow" $ once $
        all (isLeft . W.economicOutflow "Solana" . (\raw->object ["delta" .= (raw::Text)]))
          ["-0","00","-01","1","1e2",T.replicate 10000 "9"]
    , check "captured Devnet deposit binds historical source owner memo and exact custody increase" $ once $
        (verifiedAmount <$> verifyDeposit expected proof)==Right quantity &&
        transactionMemo proof==Just (boundMemo expected) &&
        (effectDelta <$> effect proof)==Right (toInteger $ units quantity)
    , check "unmatched receipts retain their custody effect without payout authorization" $ once $
        isLeft (verifyDeposit expected {boundMemo="wrong-order"} proof) &&
        (effectDelta <$> effect proof)==Right (toInteger $ units quantity)
    , check "Solana Pay binds read-only reference and derives refund owner from historical source" $ once $
        (verifiedOwner <$> verifyPay pay payProof)==Right (boundOwner expected) &&
        (verifiedAmount <$> verifyPay pay versioned)==Right quantity &&
        isLeft (verifyPay pay {payOrderReference=boundMint expected} payProof) &&
        isLeft (verifyPay pay $ replace ["transaction","message","header","numReadonlyUnsignedAccounts"] (Number 0) payProof)
    , check "deposit authorization refuses failed versioned CPI and historical identity mutations" $ once $
        let mutations=[(["meta","err"],String "failure"),(["version"],Number 1),
              (["transaction","message","header","numRequiredSignatures"],Number 0),
              (["meta","postTokenBalances"],toJSON ([]::[Value])),
              (["meta","innerInstructions"],toJSON [object ["instructions" .= [object []]]])]
        in all (\(path,v)->isLeft(verifyDeposit expected $ replace path v proof) && isLeft(verifyPay pay $ replace path v payProof)) mutations
    , check "duplicate empty and malformed account keys never authorize deposits" $ once $
        all (\bad->isLeft(transactionKeys $ replace ["transaction","message","accountKeys"] (toJSON bad) proof))
          [[],keys<>take 1 keys,[T.replicate 45 "1"],["invalid"]]
    , check "historical token quantity requires unique exact owner mint and decimals" $ forAll (chooseInteger (0,toInteger(maxBound::Int64))) $ \n ->
        let entry=object ["accountIndex" .= (2::Int),"mint" .= boundMint expected,"owner" .= boundOwner expected,
              "uiTokenAmount" .= object ["decimals" .= (8::Int),"amount" .= T.pack(show n)]]
            parse=parseEither (historicalTokenBalance (boundMint expected) 2 (boundOwner expected))
        in parse [entry]==Right n && all (isLeft . parse) [[],[entry,entry],[replace ["owner"] (String "wrong") entry],
             [replace ["uiTokenAmount","decimals"] (Number 9) entry],[replace ["uiTokenAmount","amount"] (String "-1") entry]]
    , check "instruction indices sizes and compute directives are bounded" $ forAll (chooseInt (2,10000)) $ \outside ->
        let ix p accounts dat=object ["programIdIndex" .= (p::Int),"accounts" .= (accounts::[Int]),"data" .= (dat::Text)]
            budget=base58 (BS.pack [2,0,0,0,0])
            parse=parseEither (depositInstructions ["ComputeBudget111111111111111111111111111111",tokenProgram])
        in parse [ix 0 [] budget]==Right [] && all (isLeft . parse . pure)
          [ix outside [] "",ix (-1) [] "",ix 1 [outside] "",ix 1 [-1] "",ix 1 [] "0",
           ix 1 [] (T.replicate 513 "1"),ix 0 [1] budget,ix 0 [] "1",ix 1 (replicate 9 0) ""] &&
           isLeft (parse $ replicate 5 $ ix 0 [] budget)
    , check "payment URI uses exact decimal amount and bounded order reference" $ once $
        let uri=payURIFor (boundCustodyOwner expected) (boundMint expected) ("solana-pay:"<>reference) (amt 3)
        in either (const False) (T.isInfixOf "?amount=0.00000003&spl-token=") uri &&
          isLeft(payReference $ T.replicate 100000 "f")
    , check "signature history pages include the exact overlap anchor oldest first" $ once $ ioProperty $ do
        calls<-newIORef []
        let row n=SignatureInfo (T.pack $ show n) n False
            fetch cursor=do
              modifyIORef' calls (<>[cursor])
              pure $ case cursor of Nothing->map row [205,204..106]; Just "106"->map row [105,104..6]; Just "6"->map row [5,4..1]; _->[]
        rows<-collectSignatures "1" (Just "3") fetch
        seen<-readIORef calls
        pure (map historySlot rows==[3..205] && seen==[Nothing,Just "106",Just "6"])
    , check "history gaps repeated pages reversed slots and page limits refuse advancement" $ once $ ioProperty $ do
        let row n=SignatureInfo (T.pack $ show n) n False
        gap<-rejects "solana_history_gap" $ collectSignatures "origin" Nothing (\cursor->pure $ if cursor==Nothing then [row 20] else [])
        repeated<-rejects "solana_history_repeated_page" $ collectSignatures "origin" Nothing (const $ pure [row 20])
        order<-rejects "solana_history_order_invalid" $ collectSignatures "origin" Nothing (const $ pure [row 1,row 2])
        count<-newIORef (1001::Int64)
        limit<-rejects "solana_history_batch_too_large" $ collectSignatures "origin" Nothing (\_->atomicModifyIORef' count $ \n->(n-1,[row n]))
        pure (gap && repeated && order && limit)
    , check "history decoder requires valid signatures nonnegative slots and finality" $ once $
        let good=object ["signature" .= base58(BS.replicate 64 1),"slot" .= (10::Int),"confirmationStatus" .= ("finalized"::Text),"err" .= Null]
            parse v=parseEither parseJSON v :: Either String SignatureInfo
        in not(isLeft $ parse good) && all (isLeft . parse) [replace ["signature"] (String "wrong") good,
          replace ["slot"] (Number (-1)) good,replace ["confirmationStatus"] (String "confirmed") good]
    ]
  effects<-mapM capturedEffect ["new","existing"]
  pure (local<>effects)

capturedEffect :: String -> IO Result
capturedEffect kind=do
  value<-fixture ("solana-devnet-"<>kind<>"-payment.json")
  proof<-fieldValue "transaction" value
  signatures<-fieldValue "transaction" proof >>= fieldValue "signatures" :: IO [Text]
  sig<-case signatures of [s]->pure s; _->fail "one signature required"
  let effect=lamportEffect sig "RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX"
      failed=effect $ replace ["meta","err"] (String "failure") proof
  check ("captured SOL fees and rent for "<>kind<>" ATA") $ once $
    (lamportDelta <$> effect proof)==Right (if kind=="new" then -1493440 else -5000) &&
    (lamportFee <$> effect proof)==Right (amt 5000) &&
    (if kind=="new" then isLeft failed else (lamportFailed <$> failed)==Right True)

-- Re-index only JSON evidence. This is not a newly signed/submitted transaction.
versionZero :: Text -> Value -> IO Value
versionZero custody proof=do
  message<-fieldValue "transaction" proof >>= fieldValue "message"
  keys<-fieldValue "accountKeys" message :: IO [Text]
  meta<-fieldValue "meta" proof
  index<-maybe (fail "missing custody") pure (elemIndex custody keys)
  let static=[i | i<-[0..length keys-1],i/=index]; order=static<>[index]
      remap old=maybe (error "fixture index") id (lookup old $ zip order [0::Int ..])
  instructions<-fieldValue "instructions" message :: IO [Value]
  rewritten<-mapM (\ix->do
    program<-fieldValue "programIdIndex" ix; accounts<-fieldValue "accounts" ix
    pure $ replace ["programIdIndex"] (toJSON $ remap program) $ replace ["accounts"] (toJSON $ map remap accounts) ix) instructions
  let balances key=do
        rows<-fieldValue key meta :: IO [Value]
        mapM (\v->do i<-fieldValue "accountIndex" v; pure $ replace ["accountIndex"] (toJSON $ remap i) v) rows
      lamports key=do values<-fieldValue key meta :: IO [Integer]; pure $ toJSON $ map (values!!) order
  pre<-balances "preTokenBalances"; post<-balances "postTokenBalances"
  before<-lamports "preBalances"; after<-lamports "postBalances"
  pure $ foldr (uncurry replace) proof
    [(["version"],Number 0),(["transaction","message","accountKeys"],toJSON $ map (keys!!) static),
     (["transaction","message","instructions"],toJSON rewritten),
     (["meta","loadedAddresses"],object ["writable" .= [custody],"readonly" .= ([]::[Text])]),
     (["meta","preTokenBalances"],toJSON pre),(["meta","postTokenBalances"],toJSON post),
     (["meta","preBalances"],before),(["meta","postBalances"],after)]
fixture :: FilePath -> IO Value
fixture name=getDataFileName ("test/fixtures/"<>name) >>= BS.readFile >>= either fail pure . eitherDecodeStrict'
check :: Testable prop => String -> prop -> IO Result
check name p=putStrLn name >> quickCheckWithResult stdArgs {maxSuccess=100} p
amt :: Integer -> Amount
amt n=either (error . T.unpack) id (amount n)
isLeft :: Either a b -> Bool
isLeft (Left _)=True
isLeft _=False
rejects :: Text -> IO a -> IO Bool
rejects code action=do result<-try action; pure $ case result of Left(BridgeError actual)->actual==code; Right _->False
replace :: [Key] -> Value -> Value -> Value
replace [] replacement _=replacement
replace (key:rest) replacement (Object fields)=Object $ KM.insert key (replace rest replacement $ maybe Null id $ KM.lookup key fields) fields
replace _ _ value=value
