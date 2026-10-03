{-# LANGUAGE ScopedTypeVariables #-}
module Bridge.Observer
  ( observeOnce, SignatureInfo(..), collectSignatures, epochSeconds
  ) where

import Bridge.Config
import Bridge.Postgres.Ledger (Ledger)
import qualified Bridge.Postgres.Observation as Store
import Bridge.Ledger.Model (Deposit(..), ScanBatch(..), ChainEvent(..))
import Bridge.Native
import Bridge.RPC
import Bridge.Solana
import qualified Bridge.SolanaPay as Pay
import qualified Data.Aeson.KeyMap as KM
import Bridge.SolanaDeposit
import Bridge.SolanaMessage (signatureBytes)
import Bridge.Types
import Control.Exception (IOException, catch, try)
import Control.Monad (forM, forM_, when)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.List (nub)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)

epochSeconds :: IO Int64
epochSeconds = floor <$> getPOSIXTime

optionalField :: FromJSON a => Key -> Value -> IO (Maybe a)
optionalField key = parseValue (withObject "RPC object" (.:? key))

isHash :: Text -> Bool
isHash value = T.length value==64 && T.all (`elem` ("0123456789abcdef"::String)) value

observeNative :: Manager -> Config -> Ledger -> IO ()
observeNative manager c ledger = do
  info <- nativeIdentity manager c
  wallet <- nativeWalletInfoWith (nativeCall manager c) c
  tip <- fieldValue "blocks" info :: IO Int64
  processed <- fieldValue "lastprocessedblock" wallet
  height <- fieldValue "height" processed :: IO Int64
  walletHash <- fieldValue "hash" processed :: IO Text
  activeHash <- nativeCall manager c False "getblockhash" [toJSON height] >>= parseValue parseJSON
  require (height>=tip && walletHash==activeHash) "native_wallet_behind_chain"
  previous <- Store.readCheckpoint ledger "Native"
  when (previous==Nothing) $ do
    born <- fieldValue "birthtime" wallet :: IO Int64
    header <- nativeCall manager c False "getblockheader" [toJSON (nativeCheckpointHash c)]
    checkpointTime <- fieldValue "time" header :: IO Int64
    require (born>=checkpointTime) "native_wallet_predates_scan_origin"
  depth <- Store.maximumNativeDepth ledger (nativeConfirmations c)
  history <- nativeHistory manager c (Just $ maybe (nativeCheckpointHash c) id previous) depth
  current <- fieldValue "transactions" history :: IO [Value]
  removed <- fieldValue "removed" history :: IO [Value]
  next <- fieldValue "lastblock" history
  require (isHash next && length current+length removed<=1000) "native_history_batch_too_large"
  txids <- nub <$> mapM (fieldValue "txid") (removed<>current)
  require (all isHash txids) "invalid_native_transaction_id"
  -- gettransaction supplies current canonical status, including transactions
  -- that appear in both lists after being re-added on the active branch.
  observations <- mapM readTransaction txids
  now <- epochSeconds
  let deposits=concatMap fst observations
      events=concatMap snd observations
  Store.commitScan ledger (ScanBatch "Native" (nativeCheckpointHash c) previous next now deposits events)
 where
  readTransaction txid = do
    value <- nativeCall manager c True "gettransaction" [toJSON txid,Bool False,Bool True]
    actual <- fieldValue "txid" value
    require (actual==txid) "native_transaction_identity_mismatch"
    confirmations <- fieldValue "confirmations" value :: IO Int
    anchor <- optionalField "blockhash" value
    require (confirmations<=0 || maybe False isHash anchor) "native_block_anchor_missing"
    decoded <- fieldValue "decoded" value
    decodedId <- fieldValue "txid" decoded
    require (decodedId==txid) "native_decoded_identity_mismatch"
    walletAmount <- fieldValue "amount" value
    magnitude <- either reject pure (nativeAmount $ abs walletAmount)
    feeValue <- optionalField "fee" value
    feeAmount <- mapM (either reject pure . nativeAmount . abs) feeValue
    let walletUnits=toInteger (units magnitude) * if walletAmount<0 then -1 else 1
    outputs <- fieldValue "vout" decoded :: IO [Value]
    details <- fieldValue "details" value :: IO [Value]
    require (length outputs<=1000 && length details<=1000) "native_transaction_too_large"
    now <- epochSeconds
    rows <- forM details $ \detail -> do
      category <- fieldValue "category" detail :: IO Text
      if category=="send" then pure ([],True) else do
        require (category `elem` ["receive","generate","immature","orphan"]) "native_category_unsupported"
        address <- fieldValue "address" detail
        outpoint <- fieldValue "vout" detail :: IO Int
        require (outpoint>=0 && outpoint<length outputs) "native_output_index_invalid"
        let output=outputs!!outpoint
        outputIndex <- fieldValue "n" output :: IO Int
        detailAmount <- fieldValue "amount" detail >>= either reject pure . nativeAmount
        outputAmount <- fieldValue "value" output >>= either reject pure . nativeAmount
        require (outputIndex==outpoint && detailAmount==outputAmount && units outputAmount>0) "native_output_amount_mismatch"
        addressInfo <- nativeCall manager c True "getaddressinfo" [toJSON (address::Text)]
        owned <- fieldValue "ismine" addressInfo :: IO Bool
        script <- fieldValue "scriptPubKey" addressInfo :: IO Text
        outputScript <- fieldValue "scriptPubKey" output >>= fieldValue "hex"
        require (owned && script==outputScript) "native_output_script_mismatch"
        binding <- if category=="receive" then Store.lookupInstruction ledger address else pure Nothing
        (order,required) <- case binding of
          Nothing -> pure (Nothing,if category=="receive" then nativeConfirmations c else max 101 (nativeConfirmations c))
          Just (oid,request,policy) -> do
            require (direction request==NativeToWrapped) "native_instruction_direction_mismatch"
            pure (Just oid,nativeDepth policy)
        let receipt=Deposit ("native:"<>txid<>":"<>T.pack(show outpoint)) order Native outputAmount
              (maybe "unconfirmed" id anchor) (max 0 confirmations) (confirmations>=required && category/="orphan") now
        pure ([receipt],False)
    let deposits=concatMap fst rows
        sending=or (map snd rows)
        evidence=object ["txid" .= txid,"confirmations" .= confirmations,"blockhash" .= anchor
          ,"walletNetUnits" .= T.pack(show walletUnits),"feeUnits" .= feeAmount
          ,"receipts" .= [object ["id" .= depositId d,"amount" .= depositAmount d,"order" .= depositOrder d,"eligible" .= depositEligible d] | d<-deposits]
          ,"rpcPayloadHash" .= digest (LBS.toStrict $ encode value)]
        kind | sending = "outgoing"
             | any ((/=Nothing) . depositOrder) deposits = "incoming"
             | not (null deposits) = "unmatched_incoming"
             | otherwise = "reference"
    pure (deposits,[ChainEvent txid kind (maybe "unconfirmed" id anchor) evidence])

data SignatureInfo = SignatureInfo
  { historySignature :: !Text, historySlot :: !Int64, historyFailed :: !Bool
  } deriving (Eq,Show)
instance FromJSON SignatureInfo where
  parseJSON = withObject "signature history" $ \o -> do
    sig <- o .: "signature"
    _ <- either (fail . T.unpack) pure (signatureBytes sig)
    slot <- o .: "slot"
    finality <- o .: "confirmationStatus" :: Parser Text
    err <- o .: "err" :: Parser Value
    if slot<0 || finality/="finalized" then fail "history is not finalized"
      else pure (SignatureInfo sig slot (err/=Null))

-- Fetch newest-first pages through an explicit, known anchor. A short/empty
-- response is never accepted as proof of complete history. Return oldest first,
-- including the previous cursor as a one-transaction finality overlap.
collectSignatures :: Text -> Maybe Text -> (Maybe Text -> IO [SignatureInfo]) -> IO [SignatureInfo]
collectSignatures origin previous fetch = go Nothing [] Set.empty 0
 where
  target=maybe origin id previous
  go before accumulated seen pages = do
    require (pages<10) "solana_history_batch_too_large"
    page <- fetch before
    require (not (null page) && length page<=100) "solana_history_gap"
    let ids=map historySignature page
    require (length ids==Set.size (Set.fromList ids) && all (`Set.notMember` seen) ids) "solana_history_repeated_page"
    let combined=accumulated<>page
        slots=map historySlot combined
    require (and (zipWith (>=) slots (drop 1 slots))) "solana_history_order_invalid"
    case break ((==target) . historySignature) page of
      (prefix,anchor:_) -> pure (reverse $ accumulated<>prefix<>[anchor])
      (_,[]) -> go (Just $ last ids) combined (Set.union seen $ Set.fromList ids) (pages+1::Int)

observeSolana :: Manager -> Config -> Ledger -> IO ()
observeSolana manager c ledger = do
  _ <- solanaIdentity manager c
  origin <- maybe (reject "solana_history_start_required") pure (solanaHistoryStart c)
  previous <- Store.readCheckpoint ledger "Solana"
  history <- collectSignatures origin previous $ \before ->
    solanaHistory manager c before Nothing >>= parseValue parseJSON
  pending <- Store.pendingVerification ledger
  let historyIds=map historySignature history
      work=[(historySignature h,Just h) | h<-history] <> [(sig,Nothing) | sig<-pending,sig `notElem` historyIds]
  require (length work<=1000) "solana_verification_backlog"
  observations <- mapM readTransaction work
  now <- epochSeconds
  let next=historySignature (last history) -- collectSignatures is nonempty
  Store.commitScan ledger (ScanBatch "Solana" origin previous next now (concatMap fst observations) (map snd observations))
 where
  readTransaction (sig,history) = do
    result <- try (finalizedTransaction manager c sig) :: IO (Either BridgeError Value)
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
              legacy <- maybe (pure Nothing) (Store.lookupInstruction ledger) memo
              referenced <- case Pay.transactionKeys value of
                Left _->pure Nothing
                Right keys->Store.lookupReferences ledger keys
              authorized <- case (legacy,referenced) of
                (Nothing,Just (oid,request,_,reference)) | direction request==WrappedToNative ->
                  authorize sig value oid (Just ("solana-pay:"<>reference)) (Pay.verifyPay (Pay.PayBinding sig (mint c) (custodyAta c) (custodyOwner c) reference))
                (Just (oid,request,_),Nothing) | direction request==WrappedToNative,Just owner<-sourceOwner request ->
                  authorize sig value oid memo (verifyDeposit (DepositBinding sig owner (mint c) (custodyAta c) (custodyOwner c) (maybe "" id memo)))
                _->pure Nothing
              now <- epochSeconds
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
      now <- epochSeconds
      verification <- verifyIndependent signature verify proof
      pure(Just(oid,now,verification,Just(verifiedOwner proof),instruction))
  verifyIndependent signature verify primary = case solanaVerifierRpc c of
    Nothing -> require (profile c/=CanonicalBeta) "independent_rpc_required" >> pure "verified"
    Just verifier -> do
      result <- try (rpc manager verifier Nothing "getTransaction" [toJSON signature
        ,object ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]) :: IO (Either BridgeError Value)
      pure $ case result of
        Left _ -> "awaiting_verifier"
        Right Null -> "awaiting_verifier"
        Right value -> case verify value of
          Right secondary | secondary==primary -> "verified"
          _ -> "disputed"

observeSolanaOperating :: Manager -> Config -> Ledger -> IO ()
observeSolanaOperating manager c ledger = do
  _ <- solanaIdentity manager c
  origin <- maybe (reject "solana_operating_history_start_required") pure (solanaOperatingHistoryStart c)
  previous <- Store.readCheckpoint ledger "SolanaOperating"
  history <- collectSignatures origin previous $ \before ->
    solanaAddressHistory manager c (custodyOwner c) before Nothing >>= parseValue parseJSON
  observations <- forM history $ \h -> do
    let sig=historySignature h
        anchor=T.pack (show $ historySlot h)
    result <- try (finalizedTransaction manager c sig) :: IO (Either BridgeError Value)
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
            now <- epochSeconds
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
  now <- epochSeconds
  Store.commitScan ledger (ScanBatch "SolanaOperating" origin previous (historySignature $ last history) now
    (concatMap fst observations) (map snd observations))

observeOnce :: Manager -> Config -> Ledger -> IO ()
observeOnce manager c ledger = do
  forM_ [("Native",observeNative manager c ledger),("Solana",observeSolana manager c ledger)
    ,("SolanaOperating",observeSolanaOperating manager c ledger)] $ \(chain,scan) -> do
    result <- try (scan `catch` (\(_::IOException) -> reject "observer_io_unavailable")) :: IO (Either BridgeError ())
    case result of
      Right () -> pure ()
      Left (BridgeError code) -> epochSeconds >>= \now -> Store.recordScanFailure ledger chain now code
  promoteObserved ledger

promoteObserved :: Ledger -> IO ()
promoteObserved ledger = do
  candidates <- Store.promotionCandidates ledger
  now <- epochSeconds
  forM_ candidates $ \did->Store.promoteDeposit ledger now did >> pure ()
