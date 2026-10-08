{-# LANGUAGE DeriveGeneric, ScopedTypeVariables, TypeApplications #-}
-- Shared, bounded evidence for closed token/pool recovery operations.
module Bridge.AdminStatus
  ( Status(..),inspectStatus,classifyStatus,Recovery(..),newRecovery,renewRecovery
  , validateRecovery,validateSuccessor,attemptPath,newRecoveryWith,retirementWith
  , Archive(..),readSaved,readFamily,withSavedFamily,successor
  , DebitLimit(..),submitSavedWith ) where
import Bridge.AdminKey (readPrivate,withFamily)
import Bridge.Error (require,reject)
import Bridge.RPC
import Bridge.Identity (digest)
import Bridge.Solana (SignatureInfo(..),collectSignatures)
import Bridge.SolanaMessage (publicKey,signatureBytes)
import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.ByteString as B
import Data.Proxy (Proxy(..))
import Data.Aeson
import Data.Aeson.Types (parseEither,Parser)
import qualified Data.ByteString.Lazy as L
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import GHC.Generics (Generic)
import Network.HTTP.Client (parseRequest,secure,closeManager)
import System.FilePath (isAbsolute,normalise)
import System.Posix.Files (fileExist)

-- File mechanics are shared; each archive type must validate its own signatures,
-- closed intent and successor relation. These methods provide no signing authority.
class FromJSON a => Archive a where
  archiveKind :: proxy a -> Text
  archiveRecovery :: a -> Maybe Recovery
  validateArchive :: a -> Either Text ()
  validateArchiveChild :: a -> Text -> a -> Either Text ()

readSaved :: forall a. Archive a => FilePath -> IO (B.ByteString,a)
readSaved path=do
  raw<-readPrivate path
  saved<-either (const $ reject $ "invalid_"<>kind<>"_attempt") pure (eitherDecodeStrict' raw)
  either reject pure (validateArchive saved)
  mapM_ (\r->require (path==attemptPath r) (kind<>"_attempt_path_mismatch")) (archiveRecovery saved)
  pure (raw,saved)
 where kind=archiveKind (Proxy @a)

-- Check each parent before following it; validated generations bound the walk.
readFamily :: Archive a => FilePath -> IO (B.ByteString,a)
readFamily path=do
  record<-readSaved path
  ancestors (snd record)
  pure record
 where
  ancestors saved=case archiveRecovery saved of
    Just r | recoveryGeneration r>0->do
      (raw,old)<-readSaved (attemptPath r {recoveryGeneration=recoveryGeneration r-1})
      either reject pure (validateArchiveChild old (digest raw) saved)
      ancestors old
    _->pure ()

withSavedFamily :: forall a b. Archive a => FilePath -> (B.ByteString -> a -> IO b) -> IO b
withSavedFamily path action=do
  (_,initial)<-readSaved @a path
  withFamily (maybe path recoveryRoot $ archiveRecovery initial) $ do
    (raw,saved)<-readFamily path
    require (archiveRecovery saved==archiveRecovery initial) (archiveKind (Proxy @a)<>"_attempt_changed")
    action raw saved

successor :: Archive a => B.ByteString -> a -> IO (Maybe a)
successor raw saved=case archiveRecovery saved of
  Just r | recoveryGeneration r<7->do
    let path=attemptPath r {recoveryGeneration=recoveryGeneration r+1}
    exists<-fileExist path
    if not exists then pure Nothing else do
      (_,child)<-readFamily path
      either reject pure (validateArchiveChild saved (digest raw) child)
      pure (Just child)
  _->pure Nothing

data DebitLimit = FeeOnly | TotalDebit Word64 | RentAndFee Word64

-- Called only after archive/intent validation under the family lock. Preflight
-- remains specific to the closed token/pool operation and precedes any submission.
-- No retry or replacement is performed here: a timeout leaves the saved bytes.
submitSavedWith :: (Text -> [Value] -> IO Value) -> Text -> Text -> Word64 -> DebitLimit
  -> IO () -> IO (Text,Maybe Integer)
submitSavedWith call signature bytes feeLimit debitLimit preflight=do
  require (feeLimit>0) "invalid_administration_fee_limit"
  values<-call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]] >>= fieldValue "value"
  status<-case values of [value]->pure value; _->reject "invalid_administration_status"
  if status==Null then do
    preflight
    returned<-call "sendTransaction" [toJSON bytes,object
      ["encoding" .= ("base64"::Text),"skipPreflight" .= False,"preflightCommitment" .= ("finalized"::Text),"maxRetries" .= (0::Int)]] >>= parseValue parseJSON
    require (returned==signature) "administration_submission_identifier_mismatch"
    pure ("submitted",Nothing)
  else do
    commitment<-fieldValue "confirmationStatus" status :: IO (Maybe Text)
    if commitment/=Just "finalized" then pure ("pending",Nothing) else do
      result<-call "getTransaction" [toJSON signature,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
      encoded<-fieldValue "transaction" result :: IO [Text]
      require (encoded==[bytes,"base64"]) "administration_finalized_bytes_mismatch"
      meta<-fieldValue "meta" result
      failure<-fieldValue "err" meta :: IO Value
      statusFailure<-fieldValue "err" status :: IO Value
      fee<-fieldValue "fee" meta :: IO Integer
      require (failure==statusFailure && fee>=0 && fee<=toInteger feeLimit) "administration_finalized_metadata_mismatch"
      let maximumDebit=case debitLimit of FeeOnly->Nothing; TotalDebit n->Just(toInteger n); RentAndFee n->Just(toInteger n+fee)
      mapM_ (\limit->do
        before<-fieldValue "preBalances" meta :: IO [Integer]
        after<-fieldValue "postBalances" meta :: IO [Integer]
        require (case (before,after) of (a:_,b:_)->a>=b && b>=0 && a-b>=fee && a-b<=limit; _->False)
          "administration_finalized_cost_exceeded") maximumDebit
      pure (if failure==Null then "finalized" else "failed",Just fee)

data Status = Pending | Finalized | Failed | Unseen | ExpiredUnseen deriving (Eq,Show)
instance ToJSON Status where toJSON=String . name
name :: Status -> Text
name Pending="pending"
name Finalized="finalized"
name Failed="failed"
name Unseen="unseen"
name ExpiredUnseen="expired-unseen"

-- Callers first verify the archived signatures and their closed operation intent.
inspectStatus :: Text -> String -> Text -> Text -> Text -> IO Status
inspectStatus genesis endpoint signature bytes blockhash=
  withSolanaRpc endpoint genesis ("administration_requires_https","wrong_administration_network") $ \call->do
    values<-call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]] >>= fieldValue "value"
    status<-case values of [value]->pure value; _->reject "invalid_administration_status"
    transaction<-call "getTransaction" [toJSON signature,object ["encoding" .= ("base64"::Text),"commitment" .= ("finalized"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
    valid<-if status==Null && transaction==Null then
      call "isBlockhashValid" [toJSON blockhash,object ["commitment" .= ("finalized"::Text)]] >>= fieldValue "value"
      else pure True
    either (const $ reject "administration_status_mismatch") pure (classifyStatus bytes status transaction valid)

-- Absence can reflect pruned/unavailable history: ExpiredUnseen is not nonexecution proof.
classifyStatus :: Text -> Value -> Value -> Bool -> Either String Status
classifyStatus bytes status transaction valid
  | status==Null = if transaction/=Null then Left "inconsistent transaction history"
      else Right (if valid then Unseen else ExpiredUnseen)
  | otherwise = parseEither (withObject "signature status" $ \s->do
      commitment<-s .: "confirmationStatus" :: Parser Text
      failure<-s .: "err" :: Parser Value
      case commitment of
        "finalized"->withObject "finalized transaction" (\t->do
          encoded<-t .: "transaction"
          unless (encoded==[bytes,"base64"]) (fail "saved bytes mismatch")
          metadata<-t .: "meta"
          actual<-withObject "metadata" (.: "err") metadata
          unless (actual==failure) (fail "status disagreement")
          pure (if failure==Null then Finalized else Failed)) transaction
        "processed"->pending
        "confirmed"->pending
        _->fail "unknown commitment") status
 where
  pending=if transaction==Null then pure Pending else fail "history changed during read; inspect again"

-- The retained canonical pathname prevents making a second successor by copying
-- a parent elsewhere. Independent copies of keys/journals on another host still
-- require operator exclusion. These fields are not a cryptographic chain proof.
data Recovery = Recovery
  { recoveryGenesis :: Text, recoveryPayer :: Text, recoveryFeeLimit :: Word64
  , recoveryRoot :: FilePath, recoveryGeneration :: Int, recoveryParent :: Maybe Text
  , recoveryBlockhash :: Text, recoveryOrigin :: Text, recoveryOriginSlot :: Word64
  , recoverySlot :: Word64, recoveryLastHeight :: Word64, recoveryEvidence :: Maybe Value
  } deriving (Eq,Show,Generic)
instance ToJSON Recovery where toJSON=genericToJSON defaultOptions
instance FromJSON Recovery where
  parseJSON=genericParseJSON defaultOptions {rejectUnknownFields=True}

attemptPath :: Recovery -> FilePath
attemptPath r=recoveryRoot r<>concat (replicate (recoveryGeneration r) ".retry")

validateRecovery :: Text -> Text -> Word64 -> Text -> Recovery -> Either Text ()
validateRecovery genesis payer fee recent r=do
  _<-publicKey payer; _<-publicKey recent; _<-signatureBytes (recoveryOrigin r)
  unless (recoveryGenesis r==genesis && recoveryPayer r==payer && recoveryFeeLimit r==fee
    && fee>0 && recoveryBlockhash r==recent && isAbsolute (recoveryRoot r)
    && normalise (recoveryRoot r)==recoveryRoot r && recoveryGeneration r>=0 && recoveryGeneration r<8
    && recoveryOriginSlot r<=recoverySlot r && recoverySlot r<=fromIntegral(maxBound::Int64)
    && recoveryLastHeight r>0) (Left "invalid_administration_recovery_context")
  unless (case (recoveryGeneration r,recoveryParent r,recoveryEvidence r) of
    (0,Nothing,Nothing)->True
    (n,Just parent,Just (Object _))->n>0 && T.length parent==64 && T.all (`elem` ("0123456789abcdef"::String)) parent
    _->False) (Left "invalid_administration_recovery_lineage")

validateSuccessor :: Recovery -> Text -> Recovery -> Either Text ()
validateSuccessor old parent new=do
  validateRecovery (recoveryGenesis old) (recoveryPayer old) (recoveryFeeLimit old) (recoveryBlockhash old) old
  validateRecovery (recoveryGenesis old) (recoveryPayer old) (recoveryFeeLimit old) (recoveryBlockhash new) new
  unless (recoveryRoot new==recoveryRoot old && recoveryGeneration new==recoveryGeneration old+1
    && recoveryParent new==Just parent && recoveryBlockhash new/=recoveryBlockhash old
    && recoverySlot new>recoverySlot old) (Left "administration_successor_mismatch")

type Call = Text -> [Value] -> IO Value

-- These read-only adapter seams never accept signing, submission or key callbacks.
newRecovery :: Text -> String -> Text -> Word64 -> FilePath -> IO Recovery
newRecovery genesis endpoint payer fee root=do
  transport<-parseRequest endpoint
  require (secure transport) "administration_requires_https"
  bracket newRpcManager closeManager $ \manager->newRecoveryWith (rpc manager endpoint Nothing) genesis payer fee root

newRecoveryWith :: Call -> Text -> Text -> Word64 -> FilePath -> IO Recovery
newRecoveryWith call genesis payer fee root=do
  identity call genesis
  _<-either reject pure (publicKey payer)
  origins<-call "getSignaturesForAddress" [toJSON payer,object
    ["commitment" .= ("finalized"::Text),"limit" .= (1::Int)]] >>= parseValue parseJSON
  origin<-case origins of [value]->pure value; _->reject "administration_history_origin_required"
  latest<-call "getLatestBlockhash" [object ["commitment" .= ("finalized"::Text),"minContextSlot" .= historySlot origin]]
  context<-fieldValue "context" latest
  slot<-fieldValue "slot" context
  value<-fieldValue "value" latest
  recent<-fieldValue "blockhash" value
  height<-fieldValue "lastValidBlockHeight" value
  let r=Recovery genesis payer fee root 0 Nothing recent (historySignature origin)
          (fromIntegral $ historySlot origin) slot height Nothing
  either reject pure (validateRecovery genesis payer fee recent r)
  checkBlock call r
  pure r

renewRecovery :: String -> String -> Text -> Text -> Text -> Recovery -> IO Recovery
renewRecovery primary verifier signature bytes parent old=do
  independentHttps primary verifier
  either reject pure (validateRecovery (recoveryGenesis old) (recoveryPayer old) (recoveryFeeLimit old) (recoveryBlockhash old) old)
  require (recoveryGeneration old<7) "administration_generation_limit"
  -- A throttled verifier may take longer than the primary's keep-alive timeout.
  -- Close each read session; acquiring the new context gets a fresh connection.
  let collect endpoint=bracket newRpcManager closeManager $ \manager->
        retirementWith (rpc manager endpoint Nothing) signature bytes old
  proof<-collect primary
  other<-collect verifier
  -- Both providers must agree on the terminal outcome and exact failed effect.
  outcome<-fieldValue "outcome" proof :: IO Text
  actual<-fieldValue "outcome" other
  require (outcome==actual) "administration_retirement_disagreement"
  if outcome=="failed" then do
    terminal<-fieldValue "transactionHash" proof :: IO Text
    agreed<-fieldValue "transactionHash" other
    require (terminal==agreed) "administration_retirement_disagreement"
    else pure ()
  fresh<-newRecovery (recoveryGenesis old) primary (recoveryPayer old)
    (recoveryFeeLimit old) (recoveryRoot old)
  let child=fresh {recoveryGeneration=recoveryGeneration old+1,recoveryParent=Just parent
        ,recoveryEvidence=Just $ object ["signature" .= signature,"primary" .= primary,"verifier" .= verifier
           ,"primaryEvidence" .= proof,"verifierEvidence" .= other]}
  either reject pure (validateSuccessor old parent child)
  pure child

identity :: Call -> Text -> IO ()
identity call expected=do
  actual<-call "getGenesisHash" [] >>= parseValue parseJSON
  require (actual==expected) "wrong_administration_network"

-- Anchor slot must precede any possible execution, not merely this invocation of
-- deterministic Ed25519 signing. Verify the actual block that created the hash;
-- transactions in that block predate availability of its resulting blockhash.
checkBlock :: Call -> Recovery -> IO ()
checkBlock call r=do
  block<-call "getBlock" [toJSON(recoverySlot r),object ["commitment" .= ("finalized"::Text)
    ,"transactionDetails" .= ("none"::Text),"rewards" .= False]]
  recent<-fieldValue "blockhash" block
  height<-fieldValue "blockHeight" block :: IO Word64
  require (recent==recoveryBlockhash r && height<recoveryLastHeight r
    && toInteger(recoveryLastHeight r)-toInteger height<=300) "administration_blockhash_origin_mismatch"

retirementWith :: Call -> Text -> Text -> Recovery -> IO Value
retirementWith call signature bytes r=do
  identity call (recoveryGenesis r)
  _<-either reject pure (signatureBytes signature)
  either reject pure (validateRecovery (recoveryGenesis r) (recoveryPayer r) (recoveryFeeLimit r) (recoveryBlockhash r) r)
  checkBlock call r
  let readStatus=do
        response<-call "getSignatureStatuses" [toJSON [signature],object ["searchTransactionHistory" .= True]]
        values<-fieldValue "value" response
        status<-case values of [value]->pure value; _->reject "invalid_administration_status"
        transaction<-call "getTransaction" [toJSON signature,object ["encoding" .= ("base64"::Text)
          ,"commitment" .= ("finalized"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
        pure (status,transaction)
  (status,transaction)<-readStatus
  if status/=Null || transaction/=Null then do
    state<-either (const $ reject "administration_status_mismatch") pure (classifyStatus bytes status transaction True)
    require (state==Failed) "administration_attempt_not_retryable"
    slot<-fieldValue "slot" transaction :: IO Word64
    reported<-fieldValue "slot" status
    metadata<-fieldValue "meta" transaction
    charged<-fieldValue "fee" metadata :: IO Word64
    require (slot==reported && slot>recoverySlot r && charged>0 && charged<=recoveryFeeLimit r) "administration_failed_evidence_mismatch"
    pure $ object ["outcome" .= ("failed"::Text),"slot" .= slot,"fee" .= charged
      ,"transactionHash" .= digest(L.toStrict $ encode transaction)]
  else do
    validity<-call "isBlockhashValid" [toJSON(recoveryBlockhash r),object ["commitment" .= ("finalized"::Text),"minContextSlot" .= recoverySlot r]]
    valid<-fieldValue "value" validity
    context<-fieldValue "context" validity
    finalSlot<-fieldValue "slot" context :: IO Word64
    height<-call "getBlockHeight" [object ["commitment" .= ("finalized"::Text),"minContextSlot" .= finalSlot]] >>= parseValue parseJSON :: IO Word64
    require (not valid && finalSlot>recoverySlot r && height>recoveryLastHeight r) "administration_attempt_not_expired"
    history<-collectSignatures (recoveryOrigin r) Nothing $ \before->
      call "getSignaturesForAddress" [toJSON(recoveryPayer r),object
        (["commitment" .= ("finalized"::Text),"minContextSlot" .= finalSlot,"limit" .= (100::Int)]
        <>maybe [] (\previous->["before" .= previous]) before)] >>= parseValue parseJSON
    let anchored=case history of
          origin:_->historySignature origin==recoveryOrigin r && fromIntegral(historySlot origin)==recoveryOriginSlot r
          []->False
    require (anchored
      && all ((/=signature) . historySignature) history) "administration_history_disagrees"
    (again,saved)<-readStatus
    require (again==Null && saved==Null) "administration_history_changed"
    pure $ object ["outcome" .= ("expired-unseen"::Text),"finalizedSlot" .= finalSlot,"height" .= height
      ,"historyCount" .= length history,"historyHash" .= digest(L.toStrict $ encode
        [(historySignature h,historySlot h,historyFailed h) | h<-history])]
