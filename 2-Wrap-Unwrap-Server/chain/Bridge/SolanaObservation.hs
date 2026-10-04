{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.SolanaObservation (scanSolanaWith,scanSolanaOperatingWith) where
import Bridge.Domain
import Bridge.Wire
import Bridge.Solana
import Bridge.SolanaDeposit
import Bridge.SolanaMessage (signatureBytes)
import Bridge.RPC
import Bridge.Error
import Bridge.Identity (digest)
import Control.Exception (try)
import Control.Monad (forM,when)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T

type Call = Text -> [Value] -> IO Value
type Binding = (Text,OrderRequest,PolicySnapshot)

-- Read-only RPC and closed lookup capabilities only; the caller commits one batch.
scanSolanaWith :: Call -> Maybe Call -> SolanaSettings -> Text -> Maybe Text -> Int64
  -> [Text] -> (Text -> IO (Maybe Binding)) -> ([Text] -> IO (Maybe (Text,OrderRequest,PolicySnapshot,Text))) -> IO ScanBatch
scanSolanaWith call verifier c origin previous now pending lookupInstruction lookupReferences = do
  validateCursor origin previous now
  _ <- solanaIdentityWith call verifier c
  require (length pending<=1000) "solana_verification_backlog"
  mapM_ (either reject (const $ pure ()) . signatureBytes) pending
  history <- collectSignatures origin previous $ \before ->
    solanaAddressHistoryWith call (custodyAta c) before Nothing >>= parseValue parseJSON
  let historyIds=map historySignature history
      work=[(historySignature h,Just h) | h<-history] <> [(sig,Nothing) | sig<-pending,sig `notElem` historyIds]
  require (length work<=1000) "solana_verification_backlog"
  observations <- mapM readTransaction work
  let next=historySignature (last history) -- collectSignatures is nonempty
  pure (ScanBatch "Solana" origin previous next now (concatMap fst observations) (map snd observations))
 where
  readTransaction (sig,history) = do
    result <- try (finalizedTransactionWith call sig) :: IO (Either BridgeError Value)
    case result of
      Left (BridgeError "rpc_error_-32015") -> pure ([],ChainEvent sig "unsupported" (maybe "unknown" (T.pack.show.historySlot) history)
        (object ["reason" .= ("transaction_version_unsupported"::Text),"signature" .= sig]))
      Left problem -> reject (case problem of BridgeError code -> code)
      Right value -> do
        require (value/=Null) "solana_history_transaction_unavailable"
        slot <- fieldValue "slot" value :: IO Int64
        require (maybe True ((==slot) . historySlot) history) "solana_history_slot_mismatch"
        let anchor=T.pack(show slot)
            payloadHash=digest (LBS.toStrict $ encode value)
            evidence effect reason=object ["signature" .= sig,"slot" .= slot,"custody" .= custodyAta c
              ,"mint" .= mint c,"delta" .= fmap (T.pack.show.effectDelta) effect,"classification" .= (reason::Text),"rpcPayloadHash" .= payloadHash]
        case custodyEffect sig (mint c) (custodyAta c) (custodyOwner c) value of
          Left code -> pure ([],ChainEvent sig "unclassified" anchor (evidence Nothing code))
          Right effect -> do
            require (maybe True ((==effectFailed effect) . historyFailed) history) "solana_history_result_mismatch"
            if effectFailed effect then pure ([],ChainEvent sig "failed" anchor (evidence (Just effect) "failed"))
            else if effectDelta effect<0 || effectClosed effect then pure ([],ChainEvent sig "outgoing" anchor (evidence (Just effect) "custody_decreased"))
            else if effectDelta effect==0 then pure ([],ChainEvent sig "reference" anchor (evidence (Just effect) "no_token_change"))
            else do
              let memo=transactionMemo value
              legacy <- maybe (pure Nothing) lookupInstruction memo
              referenced <- case transactionKeys value of
                Left _->pure Nothing
                Right keys->lookupReferences keys
              authorized <- case (legacy,referenced) of
                (Nothing,Just (oid,request,_,reference)) | direction request==WrappedToNative ->
                  authorize sig value oid (Just ("solana-pay:"<>reference)) (verifyPay (PayBinding sig (mint c) (custodyAta c) (custodyOwner c) reference))
                (Just (oid,request,_),Nothing) | direction request==WrappedToNative,Just owner<-sourceOwner request ->
                  authorize sig value oid memo (verifyDeposit (DepositBinding sig owner (mint c) (custodyAta c) (custodyOwner c) (maybe "" id memo)))
                _->pure Nothing
              quantity <- either reject pure (amount $ effectDelta effect)
              let (order,seen,kind,eligible)=case authorized of
                    Nothing -> (Nothing,now,"unmatched_incoming",True)
                    Just (oid,at,"verified",_,_) -> (Just oid,at,"incoming",True)
                    Just (oid,at,reason,_,_) -> (Just oid,at,reason,False)
                  receipt=Deposit ("solana:"<>sig) order Wrapped quantity anchor 1 eligible seen
              let saved=case (authorized,evidence (Just effect) kind) of
                    (Just (_,_,_,owner,instruction),Object fields)->Object(KM.insert "verifiedOwner" (toJSON owner) $ KM.insert "instruction" (toJSON instruction) fields)
                    (_,plain)->plain
              pure ([receipt],ChainEvent sig kind anchor saved)
  authorize signature value oid instruction verify = case verify value of
    Left _->pure Nothing
    Right proof->do
      verification <- verifyIndependent signature verify proof
      pure(Just(oid,now,verification,Just(verifiedOwner proof),instruction))
  verifyIndependent signature verify primary = case verifier of
    Nothing -> require (solanaProfile c/=CanonicalBeta) "independent_rpc_required" >> pure "verified"
    Just verifyCall -> do
      -- An unavailable reread must not revoke an already verified receipt.
      -- Refuse the batch; only actual contradictory evidence is disputed.
      value <- finalizedTransactionWith verifyCall signature
      require (value/=Null) "solana_verifier_transaction_unavailable"
      pure $ case verify value of
        Right secondary | secondary==primary -> "verified"
        _ -> "disputed"

scanSolanaOperatingWith :: Call -> Maybe Call -> SolanaSettings -> Text -> Maybe Text -> Int64 -> IO ScanBatch
scanSolanaOperatingWith call verifier c origin previous now = do
  validateCursor origin previous now
  _ <- solanaIdentityWith call verifier c
  history <- collectSignatures origin previous $ \before ->
    solanaAddressHistoryWith call (custodyOwner c) before Nothing >>= parseValue parseJSON
  observations <- forM history $ \h -> do
    let sig=historySignature h
        anchor=T.pack (show $ historySlot h)
    result <- try (finalizedTransactionWith call sig) :: IO (Either BridgeError Value)
    case result of
      Left (BridgeError "rpc_error_-32015") -> pure ([],ChainEvent sig "unsupported" anchor
        (object ["reason" .= ("transaction_version_unsupported"::Text)]))
      Left (BridgeError code) -> reject code
      Right value -> do
        require (value/=Null) "solana_history_transaction_unavailable"
        case lamportEffect sig (custodyOwner c) value of
          Left code -> pure ([],ChainEvent sig "unclassified" anchor (object ["reason" .= code]))
          Right effect -> do
            require (lamportSlot effect==historySlot h && lamportFailed effect==historyFailed h) "solana_history_result_mismatch"
            when (previous==Nothing && sig==origin) $
              require (units (lamportBefore effect)==0) "solana_operating_opening_balance_requires_history"
            receipts <- if lamportDelta effect<=0 then pure [] else do
              quantity <- either reject pure (amount $ lamportDelta effect)
              pure [Deposit ("sol-operating:"<>sig) Nothing Sol quantity anchor 1 True now]
            let kind | lamportDelta effect<0 = "outgoing"
                     | lamportDelta effect>0 = "unmatched_incoming"
                     | lamportFailed effect = "failed"
                     | otherwise = "reference"
                evidence=object ["signature" .= sig,"slot" .= lamportSlot effect,"owner" .= custodyOwner c
                  ,"delta" .= T.pack (show $ lamportDelta effect),"feeUnits" .= lamportFee effect
                  ,"failed" .= lamportFailed effect,"rpcPayloadHash" .= digest (LBS.toStrict $ encode value)]
            pure (receipts,ChainEvent sig kind anchor evidence)
  pure (ScanBatch "SolanaOperating" origin previous (historySignature $ last history) now
    (concatMap fst observations) (map snd observations))

validateCursor :: Text -> Maybe Text -> Int64 -> IO ()
validateCursor origin previous now = do
  require (now>=0) "invalid_scan_time"
  mapM_ (either reject (const $ pure ()) . signatureBytes) (origin:maybe [] pure previous)
