-- Focused source reads never advance scanner checkpoints or invent receipts.
module Bridge.PaymentSource (verifyPaymentSource) where
import Bridge.Domain (Asset(..))
import Bridge.Error
import Bridge.Native (nativeAmount)
import Bridge.NativePayment (NativeRPC)
import Bridge.PaymentObservation (activeNativeBlock)
import Bridge.RPC (fieldValue)
import Bridge.SolanaPayment (SolanaRPC)
import Bridge.SolanaDeposit
import qualified Bridge.SolanaHelper as H
import qualified Bridge.Wire as W
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

verifyPaymentSource :: NativeRPC -> SolanaRPC -> Maybe SolanaRPC -> W.Profile -> H.SolanaPolicy -> W.PaymentSource -> IO W.Deposit
verifyPaymentSource native solana independent profile config binding = do
  let deposit=W.sourceDeposit binding; policy=W.sourcePolicy binding
      instruction=W.sourceInstruction binding; request=W.sourceRequest binding
  require (W.deploymentFingerprint policy==H.fingerprint config && W.solanaCommitment policy=="finalized"
    && W.nativeDepth policy>0) "payment_profile_mismatch"
  case W.depositAsset deposit of
    Native->do
      (txid,index)<-case T.splitOn ":" (W.depositId deposit) of
        ["native",tx,n] | T.length tx==64,T.all (`elem` ("0123456789abcdef"::String)) tx,
          Just i<-readMaybe (T.unpack n),i>=0->pure(tx,i::Int)
        _->reject "invalid_native_deposit_id"
      value<-native True "gettransaction" [toJSON txid,Bool False,Bool True]
      actual<-fieldValue "txid" value
      decoded<-fieldValue "decoded" value
      decodedId<-fieldValue "txid" decoded
      outputs<-fieldValue "vout" decoded :: IO [Value]
      require (actual==txid && decodedId==txid && index<length outputs) "source_binding_mismatch"
      let output=outputs!!index
      actualIndex<-fieldValue "n" output :: IO Int
      quantity<-fieldValue "value" output >>= either reject pure . nativeAmount
      script<-fieldValue "scriptPubKey" output >>= fieldValue "hex"
      address<-native True "getaddressinfo" [toJSON instruction]
      owned<-fieldValue "ismine" address
      ownedScript<-fieldValue "scriptPubKey" address :: IO Text
      require (owned && actualIndex==index && quantity==W.depositAmount deposit && script==ownedScript) "source_binding_mismatch"
      depth<-fieldValue "confirmations" value
      conflicts<-fieldValue "walletconflicts" value :: IO [Text]
      if depth<W.nativeDepth policy || not(null conflicts)
        then pure deposit {W.depositAnchor="unconfirmed",W.depositConfirmations=max 0 depth,W.depositEligible=False}
        else do
          anchor<-fieldValue "blockhash" value
          _<-activeNativeBlock native anchor (W.nativeDepth policy)
          pure deposit {W.depositAnchor=anchor,W.depositConfirmations=depth,W.depositEligible=True}
    Wrapped->do
      signature<-maybe (reject "invalid_solana_deposit_id") pure (T.stripPrefix "solana:" $ W.depositId deposit)
      verify<-case T.stripPrefix "solana-pay:" instruction of
        Just reference->pure (verifyPay $ PayBinding signature (H.mint config) (H.custodyAta config) (H.custodyOwner config) reference)
        Nothing->do
          owner<-maybe (reject "source_owner_missing") pure (W.sourceOwner request)
          pure (verifyDeposit $ DepositBinding signature owner (H.mint config) (H.custodyAta config) (H.custodyOwner config) instruction)
      let proof call=call "getTransaction" [toJSON signature,object
            ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]] >>= either reject pure . verify
      verified<-proof solana
      require (verifiedAmount verified==W.depositAmount deposit && T.pack(show $ verifiedSlot verified)==W.depositAnchor deposit) "source_binding_mismatch"
      case independent of
        Nothing->require (profile/=W.CanonicalBeta) "independent_rpc_required"
        Just call->proof call >>= \other->require (other==verified) "source_verifier_disagreement"
      pure deposit {W.depositConfirmations=1,W.depositEligible=True}
    Sol->reject "unsupported_source_asset"
