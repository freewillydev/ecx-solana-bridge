module Main (main) where
import Token
import qualified Bridge.SolanaHelper as H
import Bridge.Domain (amount)
import Data.Word (Word64)
import Data.Aeson (encode,eitherDecode,object,(.=))
import Bridge.SDKBuild (sdkLibraryPath)
import Bridge.SolanaMessage (Transaction(..))
import qualified Data.ByteString as B
import Data.Text (Text)
import Data.Either (isLeft)
import Control.Exception (SomeException,try)
import System.Exit (exitFailure)
import Test.QuickCheck

request :: Action -> Word64 -> Request
request operation n=Request operation "AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9"
  "GyGKxMyg1p9SsHfm15MkNUu1u9TN2JtTspcdmrtGUdse" "13KoHDCDXebtaN59JpGpQCmhsk8u7qk9H9FFSCMyynLh"
  n "GgBaCs3NCBuZN12kCJgAW63ydqohFkHEdfdEXBPzLHq"
main :: IO ()
main=do
  results<-sequence
    [ quickCheckWithResult stdArgs {maxSuccess=100} $ forAll (frequency [(1,elements [1,maxBound::Word64]),(4,choose (1,maxBound::Word64))]) $ \n->ioProperty $ do
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
    , quickCheckResult $ once $ property $
        eitherDecode (encode $ request Mint maxBound)==Right(request Mint maxBound)
        && all (\raw->isLeft (eitherDecode (encode $ object
          ["protocol" .= (1::Int),"verb" .= ("mint"::Text),"authority" .= authority (request Mint 1)
          ,"mint" .= mint (request Mint 1),"account" .= account (request Mint 1)
          ,"blockhash" .= blockhash (request Mint 1),"amount" .= (raw::Text)]) :: Either String Request))
          ["0","01","-1","+1","1.0","1e1","18446744073709551616"]
    , quickCheckResult $ once $ ioProperty $ do
        refused<-try (evalSafe $ Prepare sdkLibraryPath $ request Mint 0) :: IO (Either SomeException Text)
        pure (isLeft refused)
    ]
  if all isSuccess results then pure () else exitFailure
 where
  check n operation=do
    let original=request operation n
    encoded<-evalSafe (Prepare sdkLibraryPath original)
    pure $ case validate original encoded of
      Right (Transaction signatures _ _) -> signatures==[B.replicate 64 0] && and
        [ isLeft $ validate original {action=if operation==Mint then Burn else Mint} encoded
        , isLeft $ validate original {quantity=if n==1 then 2 else 1} encoded
        , isLeft $ validate original {account=mint original} encoded
        , isLeft $ validate original {authority=account original} encoded
        , isLeft $ validate original {blockhash=mint original} encoded ]
      _ -> False
