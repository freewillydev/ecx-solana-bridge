module Bridge.Postgres.NativeFamily (readFamily,familyC) where
import Bridge.Postgres.Ledger (Ledger,ledgerAction)
import Bridge.Types
import Bridge.Ledger.Model (decodePaymentRecord, Attempt(..))
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Postgres.Schema
import Control.Monad (forM_,when)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import qualified Opaleye as O

readFamily :: Ledger -> Text -> IO [Attempt]
readFamily ledger intent = ledgerAction ledger (\c->familyC c intent)

-- Shared validator runs inside the caller's existing financial transaction.
familyC :: PG.Connection -> Text -> IO [Attempt]
familyC connection intent = do
  rows <- O.runSelect connection $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_ (attemptsIntentId a O..== intentsId i O..&& intentsId i O..== O.sqlStrictText intent O..&& intentsChain i O..== O.sqlStrictText "Native")
    pure (a,i)
    :: IO [(Attempts,Intents)]
  -- Native replacement fees strictly increase; this preserves family order
  -- without depending on SQLite's implicit rowid.
  signedRows <- mapM (\(a,i)->do s <- decodePaymentRecord (attemptsPolicyJson a); pure (a,i,s)) rows
  let ordered=sortOn (units . signedNativeFee . third) signedRows
      family=[asAttempt a (intentsChain i) | (a,i,_)<-ordered]
      signed=map third ordered
  require (not(null family) && length family<=8) "native_replacement_family_bounds"
  changes <- O.runSelect connection (O.selectTable nativewinnerchangesTable) :: IO [NativeWinnerChanges]
  forM_ ordered $ \(a,_,_)->when (attemptsState a=="review") $
    require (any (\change->nativewinnerchangesPreviousTxid change==attemptsTxid a && Just(nativewinnerchangesPreviousObservation change)==attemptsObservationJson a) changes) "native_family_review_not_a_previous_winner"
  when (length family>1) $ do
    either reject pure (validateNativeFamily signed)
    require (and [attemptId a==nativeTxid(signedNativeTransaction s) && attemptBytes a==signedNativeBytes s && attemptFeeLimit a==units(planFeeLimit $ signedNativePlan s) | (a,s)<-zip family signed]) "saved_native_policy_mismatch"
    links <- O.runSelect connection $ do
      member <- O.selectTable nativereplacementmembersTable
      draft <- O.selectTable nativereplacementdraftsTable
      parent <- O.selectTable attemptsTable
      child <- O.selectTable attemptsTable
      O.where_ (nativereplacementmembersDraftSequence member O..== nativereplacementdraftsCriticalSequence draft O..&&
        nativereplacementmembersTxid member O..== attemptsTxid child O..&&
        nativereplacementdraftsParentTxid draft O..== attemptsTxid parent O..&& attemptsIntentId child O..== O.sqlStrictText intent)
      pure (member,draft,parent,child)
      :: IO [(NativeReplacementMembers,NativeReplacementDrafts,Attempts,Attempts)]
    cancelled <- O.runSelect connection (O.selectTable nativereplacementcancellationsTable) :: IO [NativeReplacementCancellations]
    let lineage=[(attemptId p,attemptId a) | (p,a)<-zip family (drop 1 family)]
    require (length links==length lineage && all (\(_,d,_,a)->(nativereplacementdraftsParentTxid d,attemptsTxid a) `elem` lineage) links) "native_replacement_lineage_missing"
    forM_ (zip [1..] lineage) $ \(count,pair)->do
      (member,draft,parent,child) <- case [row | row@(_,d,_,a)<-links,(nativereplacementdraftsParentTxid d,attemptsTxid a)==pair] of [row]->pure row; _->reject "native_replacement_lineage_missing"
      decoded <- decodePaymentRecord (nativereplacementdraftsDraftJson draft)
      let current=signed!!count; sequenceNo=nativereplacementdraftsCriticalSequence draft
      either reject pure (validateNativeReplacementDraft (take count signed) (draftFee decoded) decoded)
      require (nativereplacementdraftsFee draft==units(signedNativeFee current) && nativereplacementdraftsFee draft==units(draftFee decoded) &&
        sameNativeTemplate (draftTransaction decoded) (signedNativeTransaction current) && attemptsTxid child==nativeTxid(signedNativeTransaction current) &&
        all ((/=sequenceNo).nativereplacementcancellationsDraftSequence) cancelled &&
        nativereplacementmembersCriticalSequence member>sequenceNo && attemptsPreparationGeneration parent==attemptsPreparationGeneration child) "native_replacement_member_changed"
    case ordered of
      (_,i,first):_->case nativeInputs(signedNativeTransaction first) of
        input:_->let point=nativeOutpoint input in require (intentsCommonInput i==Just(outpointTxid point<>":"<>T.pack(show $ outpointVout point))) "native_replacement_common_input_changed"
        _->reject "native_input_mismatch"
      _->reject "native_replacement_family_bounds"
  pure family

third :: (a,b,c) -> c
third (_,_,c)=c

