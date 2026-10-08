{-# LANGUAGE GADTs #-}
-- Closed LP operations sign, recover or submit only validated saved intent.
module Pool.Signing (Action(..),Safe(..),evalSafe,Critical(..),evalCritical,Saved(..),validateSaved,validateChild) where
import Pool hiding (Safe,evalSafe)
import qualified Pool
import Bridge.AdminStatus (Status,inspectStatus,Recovery(..),newRecovery,renewRecovery,validateRecovery,validateSuccessor,attemptPath)
import qualified Bridge.AdminStatus as Archive
import qualified Pool.Position as P
import qualified Pool.Liquidity as Q
import Bridge.AdminKey (readKey,savePrivate,newPrivatePath,withFamily)
import Bridge.Identity (digest)
import Bridge.Error (require,reject)
import Bridge.Domain (parseNatural)
import Bridge.RPC
import Bridge.SolanaMessage (Transaction(..),Message(..),decodePoolTransaction,decodePositionTransaction,decodeLiquidityTransaction,base58)
import Control.Monad (unless,forM_,zipWithM)
import Crypto.Error (CryptoFailable(..))
import qualified Crypto.PubKey.Ed25519 as Ed
import qualified Data.ByteArray as BA
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)

-- Closed alternatives share execution without a sign-arbitrary-message operation.
data Action = Creation Create Prepared | Opening P.Request P.Prepared | Liquidity Q.Request Q.Prepared deriving (Eq,Show)
data Saved = Saved {network :: Network,action :: Action,feeLimit :: Word64,costLimit :: Word64
  ,identifier :: Text,transaction :: Text,savedRecovery :: Maybe Recovery} deriving (Eq,Show)
instance Archive.Archive Saved where
  archiveKind _="pool"
  archiveRecovery=savedRecovery
  validateArchive=validateSaved
  validateArchiveChild=validateChild
instance ToJSON Saved where
  toJSON s=object $ ["network" .= (case network s of Devnet->"devnet"; Mainnet->"mainnet"::Text)
    ,"feeLimit" .= show(feeLimit s),"costLimit" .= show(costLimit s),"signature" .= identifier s,"transaction" .= transaction s]
    <> maybe [] (\r->["recovery" .= r]) (savedRecovery s)
    <> case action s of
      Creation r p->["request" .= r,"prepared" .= p]
      Opening r p->["operation" .= ("open-position"::Text),"request" .= r,"prepared" .= p]
      Liquidity r p->["operation" .= ("liquidity"::Text),"request" .= r,"prepared" .= p]
instance FromJSON Saved where
  parseJSON=withObject "saved pool creation" $ \o->do
    kind<-o .:? "operation" :: Parser (Maybe Text)
    recovery<-if KM.member "recovery" o then Just <$> o .: "recovery" else pure Nothing
    let fields=length o-maybe 0 (const 1) recovery
    operation<-case kind of
      Nothing | fields==7->Creation <$> o .: "request" <*> o .: "prepared"
      Just "open-position" | fields==8->Opening <$> o .: "request" <*> o .: "prepared"
      Just "liquidity" | fields==8->Liquidity <$> o .: "request" <*> o .: "prepared"
      _->fail "unexpected saved operation fields"
    name<-o .: "network" :: Parser Text
    selected<-case name of "devnet"->pure Devnet; "mainnet"->pure Mainnet; _->fail "unknown network"
    fee<-o .: "feeLimit" >>= amount; cost<-o .: "costLimit" >>= amount
    Saved selected operation fee cost <$> o .: "signature" <*> o .: "transaction" <*> pure recovery
   where
    amount text=case parseNatural (toInteger(maxBound::Word64)) text of
      Just n | n>0->pure(fromInteger n)
      _->fail "invalid pool cost limit"

validateSaved :: Saved -> Either Text ()
validateSaved s=do
  Transaction _ _ expected<-validateAction (network s) (action s)
  Transaction signatures (Message _ _ _ keys _ _) message<-decodeAction (action s) (transaction s)
  unless (expected==message && feeLimit s>0 && costLimit s>=feeLimit s) (Left "pool_saved_message_or_policy_mismatch")
  valid<-zipWithM (verify message) (take (length signatures) keys) signatures
  unless (and valid && case signatures of first:_->base58 first==identifier s; _->False) (Left "invalid_pool_signatures")
  mapM_ (validateRecovery (networkGenesis $ network s) (actionPayer $ action s) (feeLimit s) (actionHash $ action s)) (savedRecovery s)
 where
  verify message key bytes=case (Ed.publicKey key,Ed.signature bytes) of
    (CryptoPassed public,CryptoPassed signature)->pure(Ed.verify public message signature)
    _->Left "invalid_pool_signature_encoding"

validateAction :: Network -> Action -> Either Text Transaction
validateAction selected (Creation r p)=validatePrepared selected r p
validateAction _ (Opening r p)=P.validate r p
validateAction _ (Liquidity r p)=Q.validate r p
decodeAction :: Action -> Text -> Either Text Transaction
decodeAction Creation{}=decodePoolTransaction
decodeAction Opening{}=decodePositionTransaction
decodeAction Liquidity{}=decodeLiquidityTransaction
checkAction :: FilePath -> Network -> String -> Word64 -> Word64 -> Action -> IO ()
checkAction library selected endpoint fee cost operation=case operation of
  Creation r p->Pool.evalSafe (Check library selected endpoint fee cost r p) >> pure ()
  Opening r p->P.evalSafe (P.Check library selected endpoint fee cost r p) >> pure ()
  Liquidity r p->Q.evalSafe (Q.Check library selected endpoint fee cost r p) >> pure ()
checkDerivation :: FilePath -> Network -> Action -> IO ()
checkDerivation library selected operation=do
  matches<-case operation of
    Creation r p->(==p) <$> Pool.evalSafe (Prepare library selected r)
    Opening r p->(==p) <$> P.evalSafe (P.Prepare library r)
    Liquidity r p->(==p) <$> Q.evalSafe (Q.Prepare library r)
  require matches "pool_saved_derivation_mismatch"

data Safe a where
  InspectSaved :: String -> FilePath -> Safe Status

-- A child preserves every request/preparation field except the recent hash and
-- its derived unsigned bytes. The digest commits to the exact predecessor file.
validateChild :: Saved -> Text -> Saved -> Either Text ()
validateChild old parent child=do
  validateSaved old; validateSaved child
  before<-maybe (Left "pool_legacy_attempt_not_recoverable") Right (savedRecovery old)
  after<-maybe (Left "pool_missing_recovery_context") Right (savedRecovery child)
  validateSuccessor before parent after
  unless (network old==network child && feeLimit old==feeLimit child && costLimit old==costLimit child
    && sameIntent (action old) (action child)) (Left "pool_successor_intent_mismatch")

sameIntent :: Action -> Action -> Bool
sameIntent (Creation a p) (Creation b q)=a==b {recentBlockhash=recentBlockhash a}
  && p==q {unsignedTransaction=unsignedTransaction p}
sameIntent (Opening a p) (Opening b q)=a==b {P.blockhash=P.blockhash a} && p==q {P.transaction=P.transaction p}
sameIntent (Liquidity a p) (Liquidity b q)=a==b {Q.positionRequest=(Q.positionRequest b) {P.blockhash=P.blockhash $ Q.positionRequest a}}
  && p==q {Q.transaction=Q.transaction p}
sameIntent _ _=False

actionPayer :: Action -> Text
actionPayer (Creation r _)=payer r
actionPayer (Opening r _)=P.payer r
actionPayer (Liquidity r _)=P.payer (Q.positionRequest r)
actionHash :: Action -> Text
actionHash (Creation r _)=recentBlockhash r
actionHash (Opening r _)=P.blockhash r
actionHash (Liquidity r _)=P.blockhash (Q.positionRequest r)

refresh :: FilePath -> Network -> Text -> Action -> IO Action
refresh library selected recent operation=case operation of
  Creation r _->let next=r {recentBlockhash=recent} in Creation next <$> Pool.evalSafe (Prepare library selected next)
  Opening r _->let next=r {P.blockhash=recent} in Opening next <$> P.evalSafe (P.Prepare library next)
  Liquidity r _->let next=r {Q.positionRequest=(Q.positionRequest r) {P.blockhash=recent}} in Liquidity next <$> Q.evalSafe (Q.Prepare library next)

evalSafe :: Safe a -> IO a
evalSafe (InspectSaved endpoint path)=do
  (_,saved)<-Archive.readFamily path
  inspectStatus (networkGenesis $ network saved) endpoint (identifier saved) (transaction saved) (actionHash $ action saved)

data Critical a where
  Sign :: FilePath -> Network -> String -> Word64 -> Word64 -> Action -> [FilePath] -> FilePath -> Critical Text
  Recover :: FilePath -> String -> String -> FilePath -> [FilePath] -> Critical Text
  Submit :: FilePath -> String -> FilePath -> Critical Value

evalCritical :: Critical a -> IO a
evalCritical (Sign library selected endpoint fee cost operation keyfiles output)=withFamily output $ do
  newPrivatePath output
  either reject (const $ pure ()) (validateAction selected operation)
  context<-newRecovery (networkGenesis selected) endpoint (actionPayer operation) fee output
  fresh<-refresh library selected (recoveryBlockhash context) operation
  require (sameIntent operation fresh) "pool_refreshed_intent_mismatch"
  signSaved library endpoint keyfiles (Saved selected fresh fee cost "" "" (Just context))
evalCritical (Recover library endpoint verifier path keyfiles)=Archive.withSavedFamily path $ \raw old->do
  context<-maybe (reject "pool_legacy_attempt_not_recoverable") pure (savedRecovery old)
  require (recoveryGeneration context<7) "administration_generation_limit"
  child<-Archive.successor raw old
  case child of
    Just saved->pure(identifier saved)
    Nothing->do
      next<-renewRecovery endpoint verifier (identifier old) (transaction old) (digest raw) context
      fresh<-refresh library (network old) (recoveryBlockhash next) (action old)
      require (sameIntent (action old) fresh) "pool_refreshed_intent_mismatch"
      signSaved library endpoint keyfiles old {action=fresh,identifier="",transaction="",savedRecovery=Just next}
evalCritical (Submit library endpoint path)=Archive.withSavedFamily path $ \raw saved->do
  child<-Archive.successor raw saved
  forM_ child $ \_->reject "pool_attempt_superseded"
  submitSaved library endpoint saved

-- No signature leaves memory before exclusive, durable publication succeeds.
signSaved :: FilePath -> String -> [FilePath] -> Saved -> IO Text
signSaved library endpoint keyfiles draft=do
  context<-maybe (reject "pool_missing_recovery_context") pure (savedRecovery draft)
  let output=attemptPath context
      selected=network draft
      operation=action draft
  newPrivatePath output
  checkAction library selected endpoint (feeLimit draft) (costLimit draft) operation
  Transaction _ (Message _ _ _ keys _ _) message<-either reject pure (validateAction selected operation)
  let owners=case operation of Creation r _->[payer r,createVaultA r,createVaultB r]; Opening r _->[P.payer r,P.positionMint r]; Liquidity r _->[P.payer $ Q.positionRequest r]
      sources=zip owners keyfiles
  require (length keyfiles==length owners) "pool_signer_count_mismatch"
  signatures<-mapM (\key->do
    path<-maybe (reject "pool_signer_mismatch") pure (lookup (base58 key) sources)
    secret<-readKey (base58 key) path
    pure (BA.convert (Ed.sign secret (Ed.toPublic secret) message) :: B.ByteString)) (take (length owners) keys)
  first<-case signatures of a:_->pure a; _->reject "missing_pool_signature"
  let encoded=TE.decodeUtf8 $ B64.encode (B.singleton (fromIntegral $ length signatures)<>B.concat signatures<>message)
      saved=draft {identifier=base58 first,transaction=encoded}
  either reject pure (validateSaved saved)
  savePrivate output (L.toStrict $ encode saved)
  pure(identifier saved)

submitSaved :: FilePath -> String -> Saved -> IO Value
submitSaved library endpoint saved=do
  checkDerivation library (network saved) (action saved)
  withSolanaRpc endpoint (networkGenesis $ network saved) ("pool_requires_https","wrong_pool_network") $ \call->do
    (state,_)<-Archive.submitSavedWith call (identifier saved) (transaction saved) (feeLimit saved) (Archive.TotalDebit $ costLimit saved) $
      checkAction library (network saved) endpoint (feeLimit saved) (costLimit saved) (action saved)
    pure $ object ["signature" .= identifier saved,"status" .= state]
