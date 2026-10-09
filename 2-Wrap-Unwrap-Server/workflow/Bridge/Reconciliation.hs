{-# LANGUAGE ScopedTypeVariables #-}
-- Read-only chain inspection; only the closed RecordCustody operation writes.
module Bridge.Reconciliation (reconcileCustody,inspectLossCustody,inspectCustodyWith,nativeBalance,solanaBalances) where
import Bridge.Domain (Asset(..),units)
import Bridge.Error
import Bridge.Store
import Bridge.Observer (ObserverSettings(..))
import Bridge.Payment
import Bridge.NativePayment
import Bridge.SolanaPayment
import qualified Bridge.Native as N
import qualified Bridge.Solana as S
import qualified Bridge.SolanaHelper as H
import Bridge.RPC (fieldValue,parseValue,rpc)
import Bridge.Wire (Profile(..))
import Control.Exception (IOException,catch,try)
import Control.Concurrent.Async (concurrently)
import Control.Monad (forM_)
import Data.Aeson hiding (decode)
import Data.Int (Int64)
import Data.List (nub,sortOn)
import Data.Maybe (mapMaybe)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Client (Manager)

reconcileCustody :: Manager -> ObserverSettings -> H.SolanaPolicy -> Reader -> Writer -> IO ()
reconcileCustody manager settings config reader writer = do
  expected<-evalRead reader ReadCustodyRevision
  result<-try (inspectCustody False manager settings config reader `catch` (\(_::IOException)->reject "custody_rpc_unavailable"))
  case result of
    Right (revision,at,matches,report)->evalWrite writer (RecordCustody revision at (if matches then Nothing else Just "custody_balance_mismatch") (Just report))
    Left (BridgeError code)->do
      at<-floor <$> getPOSIXTime
      evalWrite writer (RecordCustody expected at (Just code) Nothing)

-- Loss inspection includes proved deficits without certifying normal readiness.
inspectLossCustody :: Manager -> ObserverSettings -> H.SolanaPolicy -> Reader -> IO (Int64,Int64,Bool,Value)
inspectLossCustody=inspectCustody True

inspectCustody :: Bool -> Manager -> ObserverSettings -> H.SolanaPolicy -> Reader -> IO (Int64,Int64,Bool,Value)
inspectCustody losses manager settings config reader = do
  let native=nativeSettings settings; solana=solanaSettings settings
      verifier=fmap (\url->rpc manager url Nothing) (S.solanaVerifierRpc solana)
      identity=N.nativeIdentity manager native >> S.solanaGenesisWith (S.solanaCall manager solana) verifier solana
  inspectCustodyWith (floor <$> getPOSIXTime) identity (N.nativeCall manager native) (S.solanaCall manager solana)
    verifier settings config reader losses

-- Explicit read-only transports allow protocol contracts without invented chains.
-- No transaction spans RPC; the revision is checked again before certification.
inspectCustodyWith :: IO Int64 -> IO () -> NativeRPC -> SolanaRPC -> Maybe SolanaRPC
  -> ObserverSettings -> H.SolanaPolicy -> Reader -> Bool -> IO (Int64,Int64,Bool,Value)
inspectCustodyWith clock identity native solana verifier settings config reader inspectLosses = do
  at<-clock
  let n=nativeSettings settings; s=solanaSettings settings
      origins=[("Native",N.nativeCheckpointHash n),("Solana",tokenOrigin settings),("SolanaOperating",operatingOrigin settings)]
  require (N.profile n==S.solanaProfile s && S.mint s==H.mint config
    && S.custodyOwner s==H.custodyOwner config && S.custodyAta s==H.custodyAta config) "payment_profile_mismatch"
  require (maybe False (const True) verifier==maybe False (const True) (S.solanaVerifierRpc s)) "verifier_configuration_mismatch"
  view<-evalRead reader (ReadCustodySnapshot at origins inspectLosses)
  identity
  before<-nativeBalance native
  let groups=M.elems $ M.fromListWith (<>) [(recordedPayment a,[a])|a<-custodyPending view]
  pending<-mapM (pendingFamilyEffect native solana n config reader) groups
  let effects=concatMap fst pending
      families=mapMaybe snd pending
      excluded=concatMap (familyExcludedInputs.snd) families
      points=[nativeOutpoint input | (first:_,_)<-families,input<-nativeInputs $ signedNativeTransaction first]
  require (length points==length(nub points)) "custody_native_family_input_overlap"
  let balances call=solanaBalances call config view (\chain txid->evalRead reader $ ReadCustodyEvent chain txid)
  -- Independent read-only providers share a snapshot, not a DB connection.
  -- Both must finish successfully; an exception cancels the other inspection.
  (slot,wrapped,sol)<-case verifier of
    Nothing->do
      require (N.profile n/=CanonicalBeta) "independent_rpc_required"
      (slot,w,supply,_)<-balances solana
      pure (slot,w,supply)
    Just verify->do
      ((slot,w,supply,authority),(_,vw,vs,otherAuthority))<-concurrently (balances solana) (balances verify)
      require (authority==otherAuthority) "mint_verifier_policy_mismatch"
      require ((w,supply)==(vw,vs)) "custody_verifier_disagreement"
      pure (slot,w,supply)
  cursor<-headFor view "Native"
  depth<-evalRead reader (MaximumNativeDepth $ defaultNativeDepth settings)
  history<-native True "listsinceblock" [toJSON cursor,toJSON depth,Bool False,Bool True]
  next<-fieldValue "lastblock" history
  require (next==cursor) "custody_native_history_advanced"
  current<-fieldValue "transactions" history
  removed<-fieldValue "removed" history
  let entries=current<>removed :: [Value]
  require (length entries<=1000) "native_history_batch_too_large"
  forM_ entries $ \entry->do
    txid<-fieldValue "txid" entry
    confirmations<-fieldValue "confirmations" entry :: IO Int
    anchor<-parseValue (withObject "transaction" (.:? "blockhash")) entry
    known<-evalRead reader (HasCustodyEvent "Native" txid)
    require known "custody_native_history_advanced"
    (_,savedAnchor,proof)<-evalRead reader (ReadCustodyEvent "Native" txid)
    old<-fieldValue "confirmations" proof
    require (old==confirmations && savedAnchor==maybe "unconfirmed" id anchor) "custody_native_history_changed"
  after<-nativeBalance native
  require (before==after) "custody_native_view_changed"
  let (nativeUnits,pendingUnits,block,height)=after
  -- An asynchronously evicted wallet transaction can retain pending change
  -- when spendzeroconfchange is disabled. Defer normalization even if unrelated
  -- pending credit is the cause; trusted=false alone cannot exclude this case.
  require (null excluded || pendingUnits==0) "custody_native_pending_credit_unresolved"
  forM_ families $ \(members,saved)->do
    currentFamily<-readNativeFamily native n members
    require (currentFamily==saved && familyPosition saved==object ["hash" .= block,"height" .= height]) "custody_native_view_changed"
  active<-native False "getblockhash" [toJSON height] >>= parseValue parseJSON
  require (active==block) "custody_native_view_changed"
  end<-clock
  require (end>=at && toInteger end-toInteger at<=60) "custody_check_timed_out"
  let walletExcluded=sum (map (toInteger.units.prevoutAmount) excluded)
      observed=M.fromList [(Native,nativeUnits+walletExcluded),(Wrapped,wrapped),(Sol,sol)]
      adjustments=M.fromListWith (+) [(asset,delta)|(_,asset,delta)<-effects]
      rows=[(asset,n,M.findWithDefault 0 asset adjustments,M.findWithDefault 0 asset observed)|(asset,n)<-M.toList $ custodyTotals view]
      matches=all (\(_,booked,delta,actual)->booked+delta>=0 && booked+delta==actual) rows
      report=object ["matches" .= matches,"nativeBlock" .= block,"nativeHeight" .= height,"solanaSlot" .= slot
        ,"nativeWalletReported" .= T.pack(show nativeUnits)
        ,"nativeWalletExcludedInputs" .= [object ["outpoint" .= prevout p,"units" .= prevoutAmount p]|p<-excluded]
        ,"assets" .= [object ["asset" .= asset,"booked" .= T.pack(show booked),"inFlight" .= T.pack(show delta)
          ,"expected" .= T.pack(show $ booked+delta),"observed" .= T.pack(show actual),"difference" .= T.pack(show $ actual-booked-delta)]|(asset,booked,delta,actual)<-rows]
        ,"inFlightEffects" .= [object ["transaction" .= txid,"asset" .= asset,"units" .= T.pack(show delta)]|(txid,asset,delta)<-effects]]
  revision<-evalRead reader ReadCustodyRevision
  require (revision==custodyRevision view) "custody_ledger_changed"
  pure (revision,at,matches,report)

nativeBalance :: NativeRPC -> IO (Integer,Integer,Text,Int64)
nativeBalance call = do
  value<-call True "getbalances" []
  mine<-fieldValue "mine" value
  amounts<-mapM (\key->fieldValue key mine >>= either reject pure . N.nativeAmount) ["trusted","immature"]
  pending<-fieldValue "untrusted_pending" mine >>= either reject pure . N.nativeAmount
  reused<-parseValue (withObject "balance" (.:? "used")) mine
  reusedAmount<-mapM (either reject pure . N.nativeAmount) reused
  require (maybe True ((==0).units) reusedAmount) "native_reused_balance_requires_review"
  block<-fieldValue "lastprocessedblock" value
  hash<-fieldValue "hash" block
  height<-fieldValue "height" block
  require (T.length hash==64 && T.all (`elem` ("0123456789abcdef"::String)) hash && height>=0) "custody_native_anchor_missing"
  let pendingUnits=toInteger(units pending)
  pure (pendingUnits+sum(map (toInteger.units) amounts),pendingUnits,hash,height)

headFor :: CustodySnapshot -> Text -> IO Text
headFor view stream=maybe (reject "custody_history_anchor_missing") pure (lookup stream $ custodyHeads view)

solanaBalances :: SolanaRPC -> H.SolanaPolicy -> CustodySnapshot
  -> (Text -> Text -> IO (Text,Text,Value)) -> IO (Int64,Integer,Integer,Maybe Text)
solanaBalances call config view evidence = do
  (slot,value)<-call "getMultipleAccounts" [toJSON [H.mint config,H.custodyAta config,H.custodyOwner config],object
    ["commitment" .= ("finalized"::Text),"encoding" .= ("jsonParsed"::Text),"minContextSlot" .= custodySlot view]] >>= contextValue (custodySlot view)
  accounts<-parseValue parseJSON value
  (mintAccount,token,owner)<-case accounts of [m,a,b]->pure(m,a,b); _->reject "custody_accounts_missing"
  (authority,_)<-S.inspectMintAccount mintAccount
  wrapped<-either reject pure (S.inspectTokenAccount (H.mint config) (H.custodyOwner config) token)
  sol<-systemLamports owner
  forM_ [("Solana",H.custodyAta config),("SolanaOperating",H.custodyOwner config)] $ \(stream,address)->do
    signature<-headFor view stream
    response<-call "getSignaturesForAddress" [toJSON address,object
      ["commitment" .= ("finalized"::Text),"minContextSlot" .= slot,"limit" .= (1::Int)]] >>= parseValue parseJSON
    h<-case response of [a]->pure a; _->reject "custody_history_head_unavailable"
    (_,anchor,_)<-evidence stream signature
    require (S.historySignature h==signature && T.pack(show $ S.historySlot h)==anchor && S.historySlot h<=slot) "custody_solana_history_advanced"
  pure (slot,toInteger $ units wrapped,toInteger $ units sol,authority)

-- One verified spender contributes one adjustment, irrespective of how many
-- signed replacement alternatives share its inputs. The Store proves lineage.
pendingFamilyEffect :: NativeRPC -> SolanaRPC -> N.NativeSettings -> H.SolanaPolicy -> Reader -> [RecordedAttempt]
  -> IO ([(Text,Asset,Integer)],Maybe ([NativeSigned],NativeFamilyView))
pendingFamilyEffect native solana settings config reader [saved]
  | recordedChain saved=="Solana"=do
      effects<-pendingSolanaEffect native solana (N.profile settings) config reader saved
      pure (effects,Nothing)
pendingFamilyEffect native _ settings config reader attempts=do
  first<-case attempts of a:_->pure a; _->reject "native_replacement_family_bounds"
  (members,view)<-readSavedNativeFamily native settings config reader (recordedPayment first)
  require (sortOn (signedId.recordedSigned) attempts==sortOn (signedId.recordedSigned) (map fst members)) "native_replacement_family_changed"
  active<-activeNativeMember members view
  effects<-case active of
    Nothing->pure []
    Just (saved,signed,depth,value)->nativeObservedEffect reader saved signed depth value
  pure (effects,Just(map snd members,view))

nativeObservedEffect :: Reader -> RecordedAttempt -> NativeSigned -> Int -> Value -> IO [(Text,Asset,Integer)]
nativeObservedEffect reader saved signed depth value=do
  require (recordedState saved=="broadcast_intent") "unrecorded_broadcast_observed"
  let txid=signedId(recordedSigned saved)
  (kind,anchor,proof)<-evalRead reader (ReadCustodyEvent "Native" txid)
  actualAnchor<-parseValue (withObject "transaction" (.:? "blockhash")) value
  oldDepth<-fieldValue "confirmations" proof
  net<-fieldValue "walletNetUnits" proof
  fee<-fieldValue "feeUnits" proof
  let n=toInteger $ units $ planAmount $ signedNativePlan signed
      cost=toInteger $ units $ signedNativeFee signed
  require (kind=="outgoing" && anchor==maybe "unconfirmed" id actualAnchor && oldDepth==depth
    && net==T.pack(show $ negate n) && fee==signedNativeFee signed) "custody_payment_observation_mismatch"
  pure [(txid,Native,negate $ n+cost)]

pendingSolanaEffect :: NativeRPC -> SolanaRPC -> Profile -> H.SolanaPolicy -> Reader -> RecordedAttempt -> IO [(Text,Asset,Integer)]
pendingSolanaEffect native solana profile config reader saved = do
  prepared<-evalRead reader (ReadPreparation $ recordedPayment saved)
  require (recordedGeneration saved==preparedGeneration prepared) "payment_requires_recovery"
  verifySignedAttempt native profile config prepared (recordedSigned saved)
  let txid=signedId(recordedSigned saved)
      recorded=require (recordedState saved=="broadcast_intent") "unrecorded_broadcast_observed"
      unseen=do
        seen<-evalRead reader (HasCustodyEvent (recordedChain saved) txid)
        require (not seen) "custody_payment_evidence_unavailable"
        pure []
  signed<-either (const $ reject "invalid_saved_payment") pure (eitherDecodeStrict' $ TE.encodeUtf8 $ signedPolicy $ recordedSigned saved)
  proof<-solana "getTransaction" [toJSON txid,object
    ["commitment" .= ("finalized"::Text),"encoding" .= ("json"::Text),"maxSupportedTransactionVersion" .= (0::Int)]]
  if proof==Null then unseen else do
    recorded
    outcome<-either reject pure (verifySolanaOutcome config signed proof)
    let n=if outcomeSucceeded outcome then toInteger(units $ solPlanAmount $ signedSolanaPlan signed) else 0
        cost=toInteger(units $ outcomeFee outcome)+toInteger(units $ outcomeRent outcome)
        anchor=T.pack(show $ outcomeSlot outcome)
    forM_ [("Solana",negate n),("SolanaOperating",negate cost)] $ \(stream,delta)->do
      (kind,actualAnchor,evidence)<-evalRead reader (ReadCustodyEvent stream txid)
      actual<-fieldValue "delta" evidence
      require (actualAnchor==anchor && actual==T.pack(show delta)
        && kind==(if stream=="Solana" && n==0 then "failed" else "outgoing")) "custody_payment_observation_mismatch"
    pure [(txid,Wrapped,negate n),(txid,Sol,negate cost)]
