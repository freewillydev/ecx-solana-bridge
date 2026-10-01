module Bridge.Postgres.PaymentStore (Store(..), pendingAttempts) where

import Bridge.Types
import Bridge.Ledger (Attempt(..),Obligation(..),Deposit(..))
import Bridge.Settlement (PaymentStore(..),SettlementStore(..))
import qualified Bridge.Postgres.Settlement as S
import Bridge.Payment (PreparationStore(..))
import Bridge.Deposit (DepositStore(..))
import qualified Bridge.Postgres.Order as Order
import qualified Bridge.Postgres.Preparation as P
import Bridge.Reconciliation (CustodyStore(..),View(..))
import qualified Bridge.Postgres.Custody as C
import qualified Bridge.Postgres.Observation as Observation
import Data.Int (Int64)
import Bridge.NativePayment
import Bridge.NativeReplacement
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Control.Monad (forM_,when)
import Data.Aeson (FromJSON,eitherDecodeStrict')
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Opaleye as O

newtype Store = Store Ledger

instance PaymentStore Store where
  paymentObligation (Store ledger) oid = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable obligationsTable
      O.where_ (obligationsId row O..== O.sqlStrictText oid)
      pure row
      :: IO [Obligations]
    case rows of [row]->pure (obligation row); _->reject "obligation_not_found"
  paymentSourceContext (Store ledger) expected = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      ob <- O.selectTable obligationsTable
      order <- O.selectTable ordersTable
      deposit <- O.selectTable depositsTable
      O.where_ (obligationsId ob O..== O.sqlStrictText (obligationId expected) O..&&
        obligationsOrderId ob O..== ordersId order O..&& obligationsDepositId ob O..== depositsId deposit)
      pure (ob,order,deposit)
      :: IO [(Obligations,Orders,Deposits)]
    (ob,order,deposit) <- case rows of [row]->pure row; _->reject "source_deposit_missing"
    require (obligation ob==expected) "obligation_mismatch"
    request <- stored (ordersRequestJson order)
    policy <- stored (ordersPolicyJson order)
    instruction <- maybe (reject "source_instruction_missing") pure (ordersInstruction order)
    let asset=sourceAsset (direction request)
    require (depositsOrderId deposit==Just (obligationOrder expected) && depositsAsset deposit==T.pack(show asset)) "source_binding_mismatch"
    quantity <- either reject pure (amount $ toInteger $ depositsAmount deposit)
    require (depositsConfirmations deposit>=0 && toInteger (depositsConfirmations deposit)<=toInteger(maxBound::Int)) "source_depth_overflow"
    pure (Deposit (depositsId deposit) (depositsOrderId deposit) asset quantity (depositsAnchor deposit)
      (fromIntegral $ depositsConfirmations deposit) (depositsEligible deposit==1) (depositsFirstSeen deposit),request,policy,instruction)
  paymentNativeFamily (Store ledger) intent = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      a <- O.selectTable attemptsTable
      i <- O.selectTable intentsTable
      O.where_ (attemptsIntentId a O..== intentsId i O..&& intentsId i O..== O.sqlStrictText intent O..&& intentsChain i O..== O.sqlStrictText "Native")
      pure (a,i)
      :: IO [(Attempts,Intents)]
    -- Native replacement fees strictly increase; this preserves family order
    -- without depending on SQLite's implicit rowid.
    signedRows <- mapM (\(a,i)->do s <- stored (attemptsPolicyJson a); pure (a,i,s)) rows
    let ordered=sortOn (units . signedNativeFee . third) signedRows
        family=[attempt a (intentsChain i) | (a,i,_)<-ordered]
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
        decoded <- stored (nativereplacementdraftsDraftJson draft)
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

pendingAttempts :: Store -> IO [Attempt]
pendingAttempts (Store ledger) = ledgerAction ledger $ \connection->do
  rows <- O.runSelect connection $ do
    a <- O.selectTable attemptsTable
    i <- O.selectTable intentsTable
    O.where_ (attemptsIntentId a O..== intentsId i O..&& intentsResolved i O..== O.sqlInt8 0)
    pure (a,intentsChain i)
    :: IO [(Attempts,Text)]
  expired <- O.runSelect connection (O.selectTable solanaexpiriesTable) :: IO [SolanaExpiries]
  pure [attempt a chain | (a,chain)<-sortOn (\(a,_)->(attemptsPreparationGeneration a,attemptsCriticalSequence a,attemptsTxid a)) rows,not(any ((==attemptsTxid a).solanaexpiriesTxid) expired)]

obligation :: Obligations -> Obligation
obligation row = Obligation (obligationsId row) (obligationsOrderId row) (obligationsDepositId row) (obligationsKind row) (obligationsAsset row) (obligationsAmount row) (obligationsRecipient row)
attempt :: Attempts -> Text -> Attempt
attempt row chain = Attempt (attemptsTxid row) (attemptsIntentId row) chain (attemptsSignedBytes row) (attemptsPolicyJson row) (attemptsFeeLimit row) (attemptsState row) (attemptsCriticalSequence row)
third :: (a,b,c) -> c
third (_,_,c)=c
stored :: FromJSON a => Text -> IO a
stored = either (const $ reject "invalid_saved_payment") pure . eitherDecodeStrict' . TE.encodeUtf8

instance CustodyStore Store where
  custodyView cfg (Store ledger) now losses = do
    snapshot <- C.readSnapshot cfg ledger now losses
    pure (View (C.revision snapshot) (C.totals snapshot) (C.heads snapshot) (C.slot snapshot))
  custodyPending = pendingAttempts
  custodyProof (Store ledger) = C.eventProof ledger
  custodyDepth (Store ledger) = Observation.maximumNativeDepth ledger
  custodyRevision (Store ledger) = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection (fmap custodycheckRevision $ O.selectTable custodycheckTable) :: IO [Int64]
    case rows of [revision]->pure revision; _->reject "custody_check_missing"
  custodyHasEvent (Store ledger) txid chain = ledgerAction ledger $ \connection->do
    rows <- O.runSelect connection $ do
      row <- O.selectTable chaineventsTable
      O.where_ (chaineventsEventId row O..== O.sqlStrictText txid O..&&
        (chaineventsChain row O..== O.sqlStrictText chain O..|| chaineventsChain row O..== O.sqlStrictText (if chain=="Solana" then "SolanaOperating" else "Native")))
      pure (chaineventsEventId row)
      :: IO [Text]
    pure (not $ null rows)


instance PreparationStore Store where
  preparationPause (Store ledger) = pause ledger
  preparationReadiness (Store ledger) = readiness ledger
  preparationOrderPolicy (Store ledger) = P.orderPolicy ledger
  preparationCostLimits (Store ledger) = P.costLimits ledger
  preparationAttempts = pendingAttempts
  preparationPending (Store ledger) = P.pending ledger
  preparationBegin (Store ledger) = P.begin ledger
  preparationActive (Store ledger) = P.active ledger
  preparationStoreDraft (Store ledger) = P.storeDraft ledger
  preparationStoreAttempt (Store ledger) = P.storeAttempt ledger

instance SettlementStore Store where
  settlementReady (Store ledger) = ledgerAction ledger $ \c->do
    rows <- O.runSelect c $ O.limit 100 $ do
      row <- O.selectTable obligationsTable
      O.where_ (obligationsStatus row O..== O.sqlStrictText "ready")
      pure row
      :: IO [Obligations]
    pure(map obligation rows)
  settlementBusy (Store ledger) chain = ledgerAction ledger $ \c->do
    rows <- O.runSelect c $ do
      row <- O.selectTable intentsTable
      O.where_ (intentsChain row O..== O.sqlStrictText chain O..&& intentsResolved row O..== O.sqlInt8 0)
      pure(intentsId row)
      :: IO [Text]
    pure(not $ null rows)
  settlementRefresh (Store ledger) = Observation.refreshDeposit ledger
  settlementRecord (Store ledger) = S.recordSettlement ledger
  settlementFailed (Store ledger) = S.recordFailedSolana ledger
  settlementExpiry (Store ledger) = S.recordSolanaExpiry ledger
  settlementExpiryOrigins (Store ledger) = S.checkExpiryOrigins ledger
  settlementBroadcast (Store ledger) = S.markBroadcastIntent ledger
  settlementAuthorize (Store ledger) = S.authorizeRecordedSend ledger

instance DepositStore Store where
  depositRead (Store ledger) capability oid = do
    cap <- either reject pure(capabilityHash capability)
    ledgerAction ledger (\connection->Order.readOrderC connection cap oid)
  depositExpose (Store ledger) = Order.exposeOrder ledger
  depositPause (Store ledger) = pause ledger
  depositReadiness (Store ledger) = readiness ledger
