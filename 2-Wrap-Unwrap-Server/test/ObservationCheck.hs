-- Captured Devnet deposit; Pay/v0 rewrites below are offline parser contracts.
module ObservationCheck (checks) where
import Bridge.Domain (Amount, Asset(..), Direction(..), amount, units)
import qualified Bridge.Wire as W
import Bridge.PaymentSource (verifyPaymentSource,inspectNativeSource)
import qualified Bridge.SolanaHelper as H
import Bridge.Error
import Bridge.RPC (fieldValue)
import Bridge.Native (NativeSettings(..),signetChallenge)
import Bridge.NativeObservation (scanNativeWith)
import Bridge.Solana (SignatureInfo(..),collectSignatures,tokenProgram)
import qualified Bridge.Solana as S
import Bridge.SolanaObservation (scanSolanaWith,scanSolanaOperatingWith)
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
import Paths_ecx_bridge (getDataFileName)
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
  slot<-fieldValue "slot" proof :: IO Int64
  let sourcePolicy=H.SolanaPolicy "source-test" "profile" (boundMint expected) (boundCustodyOwner expected) (boundCustody expected) (amt 10) (amt 10)
      sourceDeposit=W.Deposit ("solana:"<>boundSignature expected) (Just "order") Wrapped quantity (T.pack $ show slot) 1 True 100
      sourceRequest=W.OrderRequest WrappedToNative quantity "destination" "" (Just $ boundOwner expected) "key"
      sourceBinding instruction=W.PaymentSource sourceDeposit sourceRequest (W.PolicySnapshot 2 "finalized" "profile") instruction
      sourceCall value method params=case (method,params) of
        ("getTransaction",[String signature,options])->do
          commitment<-fieldValue "commitment" options :: IO Text
          require (signature==boundSignature expected && commitment=="finalized") "wrong_source_request"
          pure value
        _->fail "unexpected source RPC"
      verifySource value verifier=verifyPaymentSource (\_ _ _->fail "unexpected native RPC") (sourceCall value) verifier W.L2LSignetDevnet sourcePolicy
  versioned<-versionZero (boundCustody expected) payProof
  local<-sequence
    [ check "focused Solana source checks bind legacy and Pay receipts and independent proofs" $ once $ ioProperty $ do
        legacy<-verifySource proof (Just $ sourceCall proof) (sourceBinding $ boundMemo expected)
        paySource<-verifySource payProof Nothing (sourceBinding $ "solana-pay:"<>reference)
        changedAmount<-rejects "source_binding_mismatch" $ verifySource proof Nothing
          (sourceBinding (boundMemo expected)) {W.sourceDeposit=sourceDeposit {W.depositAmount=amt 1}}
        disagreement<-rejects "source_verifier_disagreement" $ verifySource proof
          (Just $ sourceCall $ replace ["slot"] (toJSON $ slot+1) proof) (sourceBinding $ boundMemo expected)
        pure (legacy==sourceDeposit && paySource==sourceDeposit && changedAmount && disagreement)
    , check "treasury outflows separate native fees token value and SOL debit" $ forAll (chooseInteger (1,1000000)) $ \n ->
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
  native<-nativeChecks
  scans<-solanaScanChecks expected proof payProof reference
  pure (local<>effects<>native<>scans)

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

-- Captured decoded output, surrounded by injected RPC responses. This checks
-- protocol handling and reorg overlap, not a newly funded wallet or live scan.
nativeChecks :: IO [Result]
nativeChecks=do
  captured<-fixture "native-signet-payment.json"
  decoded<-fieldValue "decoded" captured
  tx<-fieldValue "txid" decoded :: IO Text
  outputs<-fieldValue "vout" decoded :: IO [Value]
  output<-case drop 1 outputs of [v]->pure v; _->fail "captured output missing"
  script<-fieldValue "scriptPubKey" output
  address<-fieldValue "address" script :: IO Text
  scriptHex<-fieldValue "hex" script :: IO Text
  let origin=T.replicate 64 "a"; tip=T.replicate 64 "b"
      settings=NativeSettings W.L2LSignetDevnet "http://127.0.0.1:8332" "/unused" "observer" 10 origin
      detail=object ["category" .= ("receive"::Text),"address" .= address,"vout" .= (1::Int),"amount" .= Number 0.001]
      transaction=object ["txid" .= tx,"confirmations" .= (3::Int),"blockhash" .= tip,
        "amount" .= Number 0.001,"decoded" .= decoded,"details" .= [detail],"walletconflicts" .= ([]::[Text])]
      request=W.OrderRequest NativeToWrapped (amt 100000) "destination" "refund" Nothing "idempotency"
      policy=W.PolicySnapshot 3 "finalized" "profile"
      binding a=if a==address then pure (Just ("order",request,policy)) else fail "unexpected address lookup"
      response method params=case (method,params) of
        ("getblockchaininfo",[])->pure $ object ["chain" .= ("signet"::Text),"signet_challenge" .= signetChallenge,"initialblockdownload" .= False,"blocks" .= (20::Int)]
        ("getblockhash",[Number 10])->pure (String origin)
        ("getblockhash",[Number 20])->pure (String tip)
        ("getconnectioncount",[])->pure (Number 2)
        ("getwalletinfo",[])->pure $ object ["walletname" .= ("observer"::Text),"descriptors" .= True,"scanning" .= False,
          "birthtime" .= (100::Int),"lastprocessedblock" .= object ["height" .= (20::Int),"hash" .= tip]]
        ("getblockheader",[String anchor]) | anchor==tip->pure $ object ["hash" .= tip,"height" .= (20::Int),"confirmations" .= (3::Int)]
        ("getblockheader",[String anchor]) | anchor==origin->pure $ object ["time" .= (100::Int)]
        ("listsinceblock",[String anchor,Number 3,Bool False,Bool True]) | anchor==origin->pure $ object
          ["lastblock" .= tip,"transactions" .= [object ["txid" .= tx]],"removed" .= [object ["txid" .= tx]]]
        ("gettransaction",[String key,Bool False,Bool True]) | key==tx->pure transaction
        ("getaddressinfo",[String a]) | a==address->pure $ object ["ismine" .= True,"scriptPubKey" .= scriptHex]
        _->fail ("unexpected native observation RPC "<>T.unpack method)
      scan change previous lookupOrder=scanNativeWith (\_ method params->change method <$> response method params)
        settings 1 3 previous 200 [] lookupOrder
  let deposit=W.Deposit ("native:"<>tx<>":1") (Just "order") Native (amt 100000) tip 3 True 200
      recheck change=verifyPaymentSource (\_ method params->change method <$> response method params)
        (\_ _->fail "unexpected Solana RPC") Nothing W.L2LSignetDevnet
        (H.SolanaPolicy "source-test" "profile" "" "" "" (amt 1) (amt 0)) (W.PaymentSource deposit request policy address)
  sequence
    [ check "native source loss requires matching scanner/wallet conflict, absent mempool and spent output" $ once $ ioProperty $ do
        let position=object ["height" .= (20::Int),"hash" .= tip]
            source depth=deposit {W.depositConfirmations=max 0 depth,W.depositEligible=depth>=3}
            evidence depth=("saved-hash",object ["anchor" .= tip,"proof" .= object ["confirmations" .= (depth::Int)]])
            transactionAt depth=replace ["lastprocessedblock"] position $ replace ["confirmations"] (toJSON (depth::Int)) transaction
            call depth _ method params=case method of
              "gettransaction"->pure (transactionAt depth)
              "getmempoolentry"->if depth<0 then reject "rpc_error_-5" else pure $ object ["vsize" .= (120::Int)]
              "gettxout"->pure Null
              _->response method params
            inspect depth rpc=inspectNativeSource rpc settings 3 "profile" (source depth) (Just(address,policy)) (evidence depth)
        missing<-inspect (-1) (call (-1))
        restored<-inspect 3 (call 3)
        shallow<-inspect 1 (call 1)
        timeoutRefused<-rejects "native_source_conflict_not_proven" $ inspect (-1) $ \wallet method params->
          if method=="getmempoolentry" then reject "rpc_transport_unknown_outcome" else call (-1) wallet method params
        unspentRefused<-rejects "native_source_conflict_not_proven" $ inspect (-1) $ \wallet method params->
          if method=="gettxout" then pure (object []) else call (-1) wallet method params
        mempoolRefused<-rejects "native_source_conflict_not_proven" $ inspect (-1) $ \wallet method params->
          if method=="getmempoolentry" then pure (object []) else call (-1) wallet method params
        stale<-rejects "source_recovery_scan_not_current" $ inspectNativeSource (call (-1)) settings 3 "profile" (source (-1)) (Just(address,policy)) (evidence 3)
        reads<-newIORef (0::Int)
        changed<-rejects "native_source_view_changed" $ inspect (-1) $ \wallet method params->
          if method/="gettransaction" then call (-1) wallet method params else do
            n<-atomicModifyIORef' reads (\n->(n+1,n))
            pure (transactionAt $ if n==0 then -1 else 3)
        pure (case (missing,restored,shallow) of
          (W.SourceMissing _,W.SourceRestored _,W.SourcePending _)->and [timeoutRefused,unspentRefused,mempoolRefused,stale,changed]
          _->False)
    , check "focused native source checks bind outpoint ownership depth and canonical block" $ once $ ioProperty $ do
        unchanged<-recheck (const id)
        shallow<-recheck (\method->if method=="gettransaction" then replace ["confirmations"] (Number 1) else id)
        unowned<-rejects "source_binding_mismatch" $ recheck (\method->if method=="getaddressinfo" then replace ["ismine"] (Bool False) else id)
        forked<-rejects "native_settlement_not_canonical" $ recheck (\method->if method=="getblockhash" then const(String origin) else id)
        pure (unchanged==deposit && not(W.depositEligible shallow) && W.depositAnchor shallow=="unconfirmed" && unowned && forked)
    , check "native observer rereads re-added transactions once and binds saved depth" $ once $ ioProperty $ do
        calls<-newIORef []
        batch<-scanNativeWith (\_ method params->modifyIORef' calls (<>[method]) >> response method params) settings 1 3 Nothing 200 [] binding
        seen<-readIORef calls
        pure (W.scanPrevious batch==Nothing && W.scanNext batch==tip && length(filter (=="gettransaction") seen)==1 &&
          W.scanDeposits batch==[W.Deposit ("native:"<>tx<>":1") (Just "order") Native (amt 100000) tip 3 True 200] &&
          map W.chainEventKind (W.scanEvents batch)==["incoming"])
    , check "native recovery rescans historical sources with matching receipt evidence and deduplicates overlap" $ withMaxSuccess 8 $
        forAll (chooseInt (1,8)) $ \copies->ioProperty $ do
          let position=object ["height" .= (20::Int),"hash" .= tip]
              current=replace ["lastprocessedblock"] position $ replace ["confirmations"] (Number 4) transaction
              stale=deposit {W.depositConfirmations=1,W.depositEligible=False}
          outcomes<-mapM (\overlap->do
            reads<-newIORef (0::Int)
            let call _ method params=case method of
                  "listsinceblock"->pure $ object ["lastblock" .= tip
                    ,"transactions" .= [object ["txid" .= tx] | overlap]
                    ,"removed" .= [object ["txid" .= tx] | overlap]]
                  "gettransaction"->modifyIORef' reads (+1) >> pure current
                  _->response method params
            batch<-scanNativeWith call settings 1 3 (Just tip) 200 (replicate copies stale) binding
            count<-readIORef reads
            case (W.scanDeposits batch,W.scanEvents batch) of
              ([source],[event])->do
                let evidence=object ["anchor" .= W.chainEventAnchor event,"proof" .= W.chainEventEvidence event]
                recovered<-inspectNativeSource call settings 3 "profile" source (Just(address,policy)) ("saved-hash",evidence)
                pure (count==1 && source==deposit {W.depositConfirmations=4}
                  && W.scanPrevious batch==Just tip && W.scanNext batch==tip && W.chainEventId event==tx
                  && case recovered of W.SourceRestored _->True; _->False)
              _->pure False) [False,True]
          pure (and outcomes)
    , check "native recovery refuses invalid receipts and bounded history overflow before transaction reads" $ once $ ioProperty $ do
        reads<-newIORef (0::Int)
        let call _ method params=do
              modifyIORef' reads (+1)
              response method params
            recover sources=scanNativeWith call settings 1 3 (Just origin) 200 sources binding
        oversized<-rejects "native_history_batch_too_large" (recover $ replicate 1001 deposit)
        malformed<-mapM (\source->rejects "invalid_native_deposit_id" (recover [source]))
          [deposit {W.depositAsset=Wrapped},deposit {W.depositId="native:"<>tx<>":-1"}
          ,deposit {W.depositId="native:invalid:1"}]
        callsBeforeHistory<-readIORef reads
        let many=[T.justifyRight 64 '0' (T.pack $ show n) | n<-[1..1000::Int]]
            combined _ method params=case method of
              "listsinceblock"->pure $ object ["lastblock" .= tip,"transactions" .= map (\key->object ["txid" .= key]) many
                ,"removed" .= ([]::[Value])]
              "gettransaction"->fail "oversized native history reached transaction RPC"
              _->response method params
        combinedOverflow<-rejects "native_history_batch_too_large" $
          scanNativeWith combined settings 1 3 (Just origin) 200 [deposit {W.depositId="native:"<>tip<>":1"}] binding
        pure (oversized && and malformed && callsBeforeHistory==0 && combinedOverflow)
    , check "native eligibility honors saved depth and negative confirmations retain receipt" $ once $ ioProperty $ do
        let changed n method=if method=="gettransaction" then replace ["confirmations"] (Number n) else id
        shallow<-scan (changed 2) (Just origin) binding
        removed<-scan (changed (-1)) (Just origin) binding
        unbound<-scan (const id) (Just origin) (const $ pure Nothing)
        pure (all (not . W.depositEligible) (W.scanDeposits shallow<>W.scanDeposits removed) &&
          map W.depositConfirmations (W.scanDeposits removed)==[0] && map W.chainEventKind (W.scanEvents unbound)==["unmatched_incoming"])
    , check "native scan refuses origin gaps identity script output and duplicate receipt faults" $ once $ ioProperty $ do
        let faults=[("getwalletinfo",["birthtime"],Number 99,"native_wallet_predates_scan_origin"),
              ("getwalletinfo",["lastprocessedblock","hash"],String origin,"native_wallet_behind_chain"),
              ("gettransaction",["txid"],String origin,"native_transaction_identity_mismatch"),
              ("gettransaction",["blockhash"],Null,"native_block_anchor_missing"),
              ("gettransaction",["details"],toJSON [detail,detail],"duplicate_native_receipt"),
              ("gettransaction",["details"],toJSON [replace ["amount"] (Number 0.002) detail],"native_output_amount_mismatch"),
              ("getaddressinfo",["ismine"],Bool False,"native_output_script_mismatch")]
        depthRefused<-rejects "invalid_saved_native_depth" $ scan (const id) Nothing (const $ pure $ Just ("order",request,policy {W.nativeDepth=4}))
        failures<-mapM (\(target,path,value,code)->rejects code $ scan (\method->if method==target then replace path value else id) Nothing binding) faults
        pure (depthRefused && and failures)
    ]

solanaScanChecks :: DepositBinding -> Value -> Value -> Text -> IO [Result]
solanaScanChecks bound proof payProof reference=do
  slot<-fieldValue "slot" proof :: IO Int64
  let sig=boundSignature bound
      c=S.SolanaSettings W.L2LSignetDevnet "https://api.devnet.solana.com" Nothing (boundMint bound) (boundCustodyOwner bound) (boundCustody bound)
      order=W.OrderRequest WrappedToNative (amt 10000) "native" "refund" (Just $ boundOwner bound) "key"
      policy=W.PolicySnapshot 2 "finalized" "profile"
      legacy memo=pure $ if memo==boundMemo bound then Just ("order",order,policy) else Nothing
      noReference _=pure Nothing
      history=toJSON [object ["signature" .= sig,"slot" .= slot,"err" .= Null,"confirmationStatus" .= ("finalized"::Text)]]
      call value method params=case method of
        "getSignaturesForAddress"->pure history
        "getTransaction"->if take 1 params==[toJSON sig] then pure value else fail "unexpected signature"
        _->solanaIdentityReply c method params
      run settings verifierCall value pending lookupMemo lookupPay=scanSolanaWith (call value) verifierCall settings sig Nothing 500 pending lookupMemo lookupPay
      verified settings verifierCall value=run settings verifierCall value [sig] legacy noReference
      withVerifier=c {S.solanaVerifierRpc=Just "https://verifier.example"}
      secondary value method params=if method=="getTransaction" then pure value else solanaIdentityReply c method params
      status batch=map W.chainEventKind (W.scanEvents batch)
      eligible batch=map W.depositEligible (W.scanDeposits batch)
  operating<-fixture "solana-devnet-existing-payment.json" >>= fieldValue "transaction"
  operatingSlot<-fieldValue "slot" operating :: IO Int64
  operatingSignatures<-fieldValue "transaction" operating >>= fieldValue "signatures" :: IO [Text]
  operatingSig<-case operatingSignatures of [s]->pure s; _->fail "expected one signature"
  let operatingConfig=c {S.custodyOwner="RWjpjjkpABkEGomLbZYyN53pA3FVdPXp9izJ25wErGX"}
      operatingCall method params=case method of
        "getSignaturesForAddress"->pure $ toJSON [object ["signature" .= operatingSig,"slot" .= operatingSlot,"err" .= Null,"confirmationStatus" .= ("finalized"::Text)]]
        "getTransaction"->pure operating
        _->solanaIdentityReply operatingConfig method params
  sequence
    [ check "Solana scan binds captured memo deposit and deduplicates pending overlap" $ once $ ioProperty $ do
        batch<-verified c Nothing proof
        pure (status batch==["incoming"] && eligible batch==[True] && map W.depositOrder (W.scanDeposits batch)==[Just "order"] &&
          W.scanNext batch==sig && W.scanTime batch==500)
    , check "Solana Pay scan derives refund owner while ambiguous bindings stay unallocated" $ once $ ioProperty $ do
        let payLookup _=pure $ Just ("pay-order",order {W.sourceOwner=Nothing},policy,reference)
        payBatch<-run c Nothing payProof [] (const $ pure Nothing) payLookup
        ambiguous<-run c Nothing proof [] legacy payLookup
        owners<-mapM (fieldValue "verifiedOwner" . W.chainEventEvidence) (W.scanEvents payBatch) :: IO [Text]
        pure (status payBatch==["incoming"] && owners==[boundOwner bound] && status ambiguous==["unmatched_incoming"] &&
          map W.depositOrder (W.scanDeposits ambiguous)==[Nothing])
    , check "independent proof agreement failure and disagreement remain distinct" $ once $ ioProperty $ do
        agreed<-verified withVerifier (Just $ secondary proof) proof
        unavailable<-verified withVerifier (Just $ secondary Null) proof
        disputed<-verified withVerifier (Just $ secondary $ replace ["slot"] (toJSON $ slot+1) proof) proof
        absent<-rejects "verifier_configuration_mismatch" (verified withVerifier Nothing proof)
        pure (status agreed==["incoming"] && eligible agreed==[True] && status unavailable==["awaiting_verifier"] &&
          eligible unavailable==[False] && status disputed==["disputed"] && eligible disputed==[False] && absent)
    , check "Solana scans refuse missing transactions wrong slots and incomplete history" $ once $ ioProperty $ do
        absent<-rejects "solana_history_transaction_unavailable" (verified c Nothing Null)
        wrongSlot<-rejects "solana_history_slot_mismatch" (verified c Nothing $ replace ["slot"] (toJSON $ slot+1) proof)
        gap<-rejects "solana_history_gap" $ scanSolanaWith (\method params->if method=="getSignaturesForAddress" then pure (toJSON ([]::[Value])) else call proof method params)
          Nothing c sig Nothing 500 [] legacy noReference
        pure (absent && wrongSlot && gap)
    , check "pending verifier work is revisited after the history cursor moves" $ once $ ioProperty $ do
        let newer=base58 (BS.replicate 64 7)
            pendingCall method params=case method of
              "getSignaturesForAddress"->pure $ toJSON [object ["signature" .= newer,"slot" .= (slot+1),"err" .= Null,"confirmationStatus" .= ("finalized"::Text)]]
              "getTransaction" | take 1 params==[toJSON newer]->pure $ replace ["slot"] (toJSON $ slot+1) $
                replace ["transaction","signatures"] (toJSON [newer]) proof
              _->call proof method params
        batch<-scanSolanaWith pendingCall Nothing c sig (Just newer) 500 [sig] legacy noReference
        pure (map W.chainEventId (W.scanEvents batch)==[newer,sig] && W.scanNext batch==newer && eligible batch==[True,True])
    , check "unsupported transaction versions are quarantined without a receipt" $ once $ ioProperty $ do
        let unsupported method params=if method=="getTransaction" then reject "rpc_error_-32015" else call proof method params
        batch<-scanSolanaWith unsupported Nothing c sig Nothing 500 [] legacy noReference
        pure (status batch==["unsupported"] && null(W.scanDeposits batch))
    , check "operating scan preserves captured fee outflow and refuses truncated opening history" $ once $ ioProperty $ do
        batch<-scanSolanaOperatingWith operatingCall Nothing operatingConfig operatingSig (Just operatingSig) 500
        opening<-rejects "solana_operating_opening_balance_requires_history" $
          scanSolanaOperatingWith operatingCall Nothing operatingConfig operatingSig Nothing 500
        flow<-case W.scanEvents batch of [event]->pure (W.economicOutflow "SolanaOperating" $ W.chainEventEvidence event); _->fail "one event expected"
        pure (status batch==["outgoing"] && null(W.scanDeposits batch) && flow==Right(Sol,amt 5000,amt 5000) && opening)
    ]

-- Only account/identity RPC fixtures shared by the scanner protocol checks.
solanaIdentityReply :: S.SolanaSettings -> Text -> [Value] -> IO Value
solanaIdentityReply c method params=case (method,params) of
  ("getGenesisHash",[])->pure $ toJSON (S.solanaGenesis $ S.solanaProfile c)
  ("getAccountInfo",String address:_) | address==S.mint c->pure $ object ["value" .= object
    ["owner" .= tokenProgram,"data" .= object ["parsed" .= object ["type" .= ("mint"::Text),"info" .= object
      ["decimals" .= (8::Int),"isInitialized" .= True,"freezeAuthority" .= Null]]]]]
  ("getAccountInfo",String address:_) | address==S.custodyAta c->pure $ object ["value" .= object
    ["owner" .= tokenProgram,"executable" .= False,"data" .= object ["space" .= (165::Int),"parsed" .= object
      ["type" .= ("account"::Text),"info" .= object ["owner" .= S.custodyOwner c,"mint" .= S.mint c,"state" .= ("initialized"::Text),
        "isNative" .= False,"tokenAmount" .= object ["decimals" .= (8::Int),"amount" .= ("1000000"::Text)]]]]]]
  _->fail ("unexpected Solana identity RPC "<>T.unpack method)
