{-# LANGUAGE DataKinds, GADTs, TypeOperators, TypeFamilies, TypeApplications #-}
module Main (main) where

import qualified SigningTransportCheck
import qualified ChainCheck
import Bridge.Identity (bearerHash,capabilityHash,payInstruction,payURIFor)
import Bridge.API (customerServer)
import Bridge.Signer (signingServer)
import Bridge.Operation.Internal
import qualified Bridge.Wire as W
import Servant.API ((:<|>)(..))
import Bridge.Domain
import Data.Aeson (eitherDecode,encode)
import Data.Int (Int64)
import Data.List (nub)
import Data.Typeable (typeOf,eqT)
import Data.Type.Equality ((:~:)(Refl))
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import System.Exit (exitFailure)
import Test.QuickCheck hiding (total,Result)

main :: IO ()
main = do
  results <- sequence
    [ check "Solana Pay URI preserves exact units and rejects injectable keys" $ forAll amounts $ \n ->
        let key=T.replicate 32 "1"; quantity=good(amount n); instruction="solana-pay:"<>key
        in payURIFor key key instruction quantity==Right("solana:"<>key<>"?amount="<>renderCoins quantity<>"&spl-token="<>key<>"&reference="<>key<>"&label=ECX%20Bridge")
          && isLeft(payURIFor (key<>"?evil") key instruction quantity)
          && isLeft(payURIFor key key "invalid" quantity)
    , check "Solana Pay reference retains the baseline order binding" $ once $ property $
        and [payInstruction (T.replicate 64 "0")==Right ("solana-pay:"<>T.replicate 32 "1"),isLeft(payInstruction "bad")]
    , check "capabilities retain baseline hashing and reject malformed headers" $ once $ property $
        and [capabilityHash (T.replicate 64 "0")==Right "c7de6a9548a8cbddf66a91b07bedaa2949ebe64ce649be6d584f7ba7122b4c04"
            ,bearerHash ("Bearer "<>T.replicate 64 "0")==capabilityHash (T.replicate 64 "0")
            ,all (isLeft . bearerHash) ["", "bearer "<>T.replicate 64 "0", "Bearer "<>T.replicate 64 "A", "Bearer "<>T.replicate 64 "0"<>" "]]
    , check "customer handlers preserve request, result type and severity" $ once $ property handlerContract
    , check "signer handler resolves an existential to a signer-only critical operation" $ once $ property $
        let prepared :<|> replacement :<|> draft :<|> checkpoint=signingServer ()
        in case (checkedRequest $ prepared ("deployment","payment",3),checkedRequest $ replacement ("deployment",7),checkedRequest $ draft ("deployment","parent",good $ amount 2),checkedRequest $ checkpoint ("deployment",9)) of
          (Right(SigningDSL (PreparedSigning (SignPrepared identity identifier generation))),Right(SigningDSL (ReplacementSigning (SignReplacement other decision))),Right(SigningDSL (DraftSigning (DraftReplacement third parent fee))),Right(SigningDSL (CheckpointSigning (CheckpointCustody fourth sequenceNo))))->
            identity=="deployment" && identifier=="payment" && generation==3 && other==identity && decision==7 && third==identity && parent=="parent" && units fee==2 && fourth==identity && sequenceNo==9
          _->False
    , check "each associated dictionary identity is distinct and survives DSL resolution" $ once $ property $
        let identities=[typeOf(operationDictionary @'Customer @'Safe @CustomerCommand)
              ,typeOf(operationDictionary @'Customer @'Critical @CustomerCommand)
              ,typeOf(operationDictionary @'Operator @'Safe @OperatorCommand)
              ,typeOf(operationDictionary @'Operator @'Critical @OperatorCommand)
              ,typeOf(operationDictionary @'Worker @'Critical @WorkerCommand)
              ,typeOf(operationDictionary @'Signer @'Critical @SignerCommand)]
            select :: Request caller severity a -> T.Text
            select request=case checkedRequest request of
              Left _->"mismatch"
              Right operation->case operation of
                ReadCustomer{}->"customer-read"
                ReadOperator{}->"operator-read"
                WriteCustomer{}->"customer-write"
                OperatorDSL{}->"operator-write"
                WorkerDSL{}->"worker"
                SigningDSL{}->"signer"
        in length(nub identities)==6 && and
          [select(Request $ CustomerQuery PublicConfig)=="customer-read"
          ,select(Request $ OperatorQuery ServiceState)=="operator-read"
          ,select(Request $ CustomerChange $ CreateOrder "auth" $ W.OrderRequest NativeToWrapped (good $ amount 100) "dest" "refund" Nothing "key")=="customer-write"
          ,select(Request $ OperatorChange $ PauseService "reason")=="operator-write"
          ,select(workerRequest RunWorkerCycle)=="worker"
          ,select(Request $ SignerAction $ PreparedSigning $ SignPrepared "deployment" "payment" 3)=="signer"]
    , check "distinct dictionary constraints and signer outputs have no equality witness" $ once $ property $
        absent(eqT @(OperationContext 'Customer 'Safe CustomerCommand) @(OperationContext 'Customer 'Critical CustomerCommand))
        && absent(eqT @(OperationContext 'Worker 'Critical WorkerCommand) @(OperationContext 'Signer 'Critical SignerCommand))
        && absent(eqT @PreparedResult @ReplacementResult) && absent(eqT @PreparedResult @DraftResult)
        && absent(eqT @PreparedResult @CheckpointResult) && absent(eqT @ReplacementResult @DraftResult)
        && absent(eqT @ReplacementResult @CheckpointResult) && absent(eqT @DraftResult @CheckpointResult)
    , check "result equality determines both severity and operation" $ once $ property $
        case resultIndices (Refl :: Result 'Critical SignPrepared :~: Result 'Critical SignPrepared) of
          (Refl,Refl)->True
    , check "typed signer result preserves all evidence through JSON" $ once $ property $
        let result=W.SignedAttempt "id" "bytes" "proof" (Just "outpoint")
        in eitherDecode (encode result)==Right result
    , check "serialized quotes cannot change saved accounting" $ forAll (chooseInteger (2,1000000000)) $ \n ->
        let q=good (quote $ good $ amount n)
        in conjoin [eitherDecode (encode q)===Right q,
          property (isLeft (eitherDecode "{\"gross\":\"100\",\"fee\":\"1\",\"net\":\"100\"}" :: Either String Quote))]
    , check "exact amount wire/decimal round trips" $ forAll amounts $ \n ->
        let a=good (amount n)
        in conjoin [parseUnits (T.pack $ show n)===Right a,parseCoins (renderCoins a)===Right a,
                    eitherDecode (encode a)===Right a]
    , check "new fee rounds upward without overflow" $ forAll (chooseInteger (2,toInteger(maxBound::Int64))) $ \n ->
        let q=good (quote $ good $ amount n); f=toInteger (units $ fee q)
        in conjoin [f*100>=n,(f-1)*100<n,toInteger(units(net q))+f==n]
    , check "conversion/refund settlement balances each asset" $ forAll (chooseInteger (2,1000000000000)) $ \n ->
        forAll (elements [NativeToWrapped,WrappedToNative]) $ \direction ->
          let q=good (quote $ good $ amount n)
              c=good (conversion "order" "receipt" direction q)
              r=good (refund "order" "receipt" (sourceAsset direction) (gross q))
              make funding=good (payment "payment" funding "recipient")
              cp=make c; rp=make r
          in conjoin
            [balanced (settlement cp),balanced (settlement rp)
            ,paymentAmount cp==net q,paymentAmount rp==gross q
            ,paymentAsset cp==destinationAsset direction
            ,delta (sourceAsset direction) Principal (settlement cp)==negate n
            ,delta (sourceAsset direction) Earned (settlement rp)==0
            ,isLeft (reserveEarned c),isLeft (reserveEarned r)]
    , check "earned funds never consume customer principal or inventory" $ forAll (chooseInteger (1,1000000000000)) $ \n ->
        forAll (elements [Native,Wrapped]) $ \asset ->
          let f=good (earnedFees "withdrawal" asset (good $ amount n))
              reserve=good (reserveEarned f); release=good (releaseEarned f)
              paid=settlement (good $ payment "payment" f "recipient")
              total=reserve<>paid
          in conjoin
            [balanced reserve,balanced release,balanced paid
            ,all (==0) (M.elems $ totals $ reserve<>release)
            ,delta asset Earned total==negate n,delta asset External total==n
            ,delta asset FeePending total==0
            ,all (\p->postingAccount p `notElem` [Principal,Float,Backing,Liquidity]) total]
    , check "historical quotes retain their saved charge" $ forAll (chooseInteger (2,1000000000)) $ \n ->
        forAll (chooseInteger (0,n-1)) $ \saved ->
          let q=good (historicalQuote (good $ amount n) (good $ amount saved))
              p=good (conversion "order" "receipt" NativeToWrapped q >>= \f->payment "payment" f "recipient")
          in conjoin [toInteger(units(paymentAmount p))==n-saved,
                      delta Native Earned (settlement p)==saved]
    , check "invalid monetary forms and unsupported payouts are refused" $ once $ property $
        and [all (isLeft . parseUnits) ["", "01", "-1", "+1", "1e8", "1.0", "１２", "9223372036854775808"]
            ,isLeft (amount (-1)),isLeft (amount (toInteger(maxBound::Int64)+1))
            ,isLeft (quote $ good $ amount 0),isLeft (quote $ good $ amount 1)
            ,isLeft (historicalQuote (good $ amount 10) (good $ amount 11))
            ,isLeft (earnedFees "withdrawal" Sol (good $ amount 1))
            ,isLeft (refund "order" "receipt" Native (good $ amount 0))]
    ]
  chainResults <- ChainCheck.checks
  transportResults <- SigningTransportCheck.checks
  if all isSuccess (results<>chainResults<>transportResults) then pure () else exitFailure
 where
  check description p=putStrLn description >> quickCheckWithResult stdArgs{maxSuccess=300} p
  amounts=chooseInteger (0,toInteger(maxBound::Int64))

good :: Show e => Either e a -> a
good = either (error . show) id
isLeft :: Either a b -> Bool
isLeft (Left _)=True
isLeft (Right _)=False
totals :: [Posting] -> M.Map (Asset,Account) Integer
totals = M.fromListWith (+) . map (\p->((postingAsset p,postingAccount p),postingDelta p))
delta :: Asset -> Account -> [Posting] -> Integer
delta asset account = M.findWithDefault 0 (asset,account) . totals
balanced :: [Posting] -> Bool
balanced = all (==0) . M.elems . M.fromListWith (+) . map (\p->(postingAsset p,postingDelta p))

-- Inspect the real Servant handlers; no mock chain or evaluator is involved.
handlerContract :: Bool
handlerContract =
  let config :<|> create :<|> status :<|> instructions = customerServer
      inputRequest = W.OrderRequest NativeToWrapped (good $ amount 100) "destination" "refund" Nothing "key"
      configOK = case config of
        SafePlan req -> case checkedRequest req of Right(ReadCustomer PublicConfig) -> True; _ -> False
        _ -> False
      createOK = case create "auth" inputRequest of
        CriticalPlan req -> case checkedRequest req of
          Right(WriteCustomer (CreateOrder auth saved)) -> auth=="auth" && saved==inputRequest
          _ -> False
        _ -> False
      statusOK = case status "order" "auth" of
        SafePlan req -> case checkedRequest req of
          Right(ReadCustomer (OrderStatus auth oid)) -> auth=="auth" && oid=="order"
          _ -> False
        _ -> False
      instructionsOK = case instructions "order" "auth" of
        SafePlan req -> case checkedRequest req of
          Right(ReadCustomer (PaymentInstructions auth oid)) -> auth=="auth" && oid=="order"
          _ -> False
        _ -> False
  in and [configOK,createOK,statusOK,instructionsOK]

-- GHC must derive both equalities from family-result equality, without casts.
resultIndices :: Result s op :~: Result t other -> (s :~: t, op :~: other)
resultIndices Refl = (Refl,Refl)

absent :: Maybe a -> Bool
absent Nothing=True
absent Just{}=False
