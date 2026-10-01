module Bridge.Deposit (DepositStore(..), solanaDepositMemo, prepareSolanaDeposit, prepareSolanaDepositWith) where

import Bridge.Config
import Bridge.Ledger
import Bridge.Native (nativeIdentity)
import Bridge.RPC
import Bridge.Solana
import Bridge.SolanaHelper
import Bridge.SolanaPayment
import Bridge.Types
import Control.Exception (onException)
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)

class DepositStore ledger where
  depositRead :: ledger -> Text -> Text -> IO OrderView
  depositExpose :: ledger -> Bool -> Text -> Text -> IO OrderView
  depositPause :: ledger -> Text -> IO ()
  depositReadiness :: ledger -> IO Availability
instance DepositStore Ledger where
  depositRead = readOrder
  depositExpose = exposeOrder
  depositPause = pause
  depositReadiness = readiness

solanaDepositMemo :: Config -> Text -> Text
solanaDepositMemo c oid="ecx-bridge:v1:"<>deploymentId c<>":deposit:"<>oid

prepareSolanaDeposit :: DepositStore ledger => Manager -> Config -> ledger -> Text -> Text -> IO Value
prepareSolanaDeposit manager c ledger capability oid = do
  -- Invalid customer authorization must not pause the whole deployment.
  _ <- depositRead ledger capability oid
  (nativeIdentity manager c >> solanaIdentity manager c >> pure ())
    `onException` depositPause ledger "deposit_chain_identity_unavailable"
  prepareSolanaDepositWith (floor <$> getPOSIXTime) (solanaCall manager c) (invokeHelper c) c ledger capability oid

-- The helper returns an unsigned standard wallet transaction. Only the owner
-- bound in the immutable order can sign it; custody never signs a deposit.
-- A blockhash refresh may change bytes, never the amount, owner or order memo.
prepareSolanaDepositWith :: DepositStore ledger => IO Int64 -> SolanaRPC -> (HelperRequest -> IO HelperReply) -> Config -> ledger -> Text -> Text -> IO Value
prepareSolanaDepositWith clock call helper c ledger capability oid = do
  order <- checkOrder
  let customerRequest=request order
  owner <- maybe (reject "source_owner_missing") pure (sourceOwner customerRequest)
  recent <- getRecentBlockhash call
  let helperRequest=HelperRequest False owner (custodyOwner c) (input customerRequest) (recentHash recent) oid
  reply <- helper helperRequest
  _ <- either reject pure (validateHelperReply c helperRequest reply)
  let options=object ["commitment" .= ("confirmed"::Text),"minContextSlot" .= recentSlot recent]
  (_,value) <- call "getMultipleAccounts"
    [toJSON [replySource reply,custodyAta c,owner],object
      ["commitment" .= ("confirmed"::Text),"encoding" .= ("jsonParsed"::Text),"minContextSlot" .= recentSlot recent]]
      >>= contextValue (recentSlot recent)
  accounts <- parseValue parseJSON value
  (source,custody,payer) <- case accounts of [a,b,d] -> pure(a,b,d); _ -> reject "deposit_accounts_unavailable"
  balance <- either reject pure (inspectTokenAccount (mint c) owner source)
  _ <- either reject pure (inspectTokenAccount (mint c) (custodyOwner c) custody)
  require (balance>=input customerRequest) "insufficient_source_tokens"
  (_,quotedFee) <- call "getFeeForMessage" [toJSON $ replyMessage reply,options] >>= contextValue (recentSlot recent)
  require (quotedFee/=Null) "deposit_fee_unavailable"
  fee <- parseValue parseJSON quotedFee >>= either reject pure . amount
  payerBalance <- systemLamports payer
  require (units fee>0 && payerBalance>=fee) "insufficient_deposit_fee_sol"
  -- Time, availability, order state and backup coverage may change during RPC.
  checkBlockhashWindow call recent
  fresh <- checkOrder
  require (fresh==order) "deposit_order_changed"
  pure $ object ["transaction" .= replyTransaction reply,"orderId" .= oid,"owner" .= owner
    ,"mint" .= mint c,"custody" .= custodyAta c,"amount" .= input customerRequest,"memo" .= replyMemo reply
    ,"blockhash" .= recentHash recent,"lastValidBlockHeight" .= recentLastValidHeight recent
    ,"feeLamports" .= fee,"chain" .= (if profile c==CanonicalBeta then "solana:mainnet" else "solana:devnet"::Text)]
 where
  checkOrder=do
    order <- depositExpose ledger (backupRequired c) capability oid
    now <- clock
    health <- depositReadiness ledger
    require (available health) "deposits_paused"
    require (status order=="AwaitingDeposit" && now>=0 && now<=deadline order) "deposit_window_closed"
    let customerRequest=request order
    require (direction customerRequest==WrappedToNative && sourceOwner customerRequest==Just (refund customerRequest)
      && deploymentFingerprint (policy order)==fingerprint c && solanaCommitment (policy order)=="finalized"
      && depositInstruction order==Just (solanaDepositMemo c oid)) "invalid_solana_order_binding"
    pure order
