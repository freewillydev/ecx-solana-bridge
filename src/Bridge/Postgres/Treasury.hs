module Bridge.Postgres.Treasury (allocate, classifySpend) where

import Bridge.Ledger.Model (economicOutflow)
import Control.Monad (forM_)
import Bridge.Types
import Bridge.RPC (fieldValue)
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Bridge.Postgres.Custody (freshC)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.List (sortOn,nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Opaleye as O

-- Ownership is an explicit operator attestation; an unmatched receipt alone
-- does not establish that the coins belong to the operator.
allocate :: Ledger -> Int64 -> Text -> [(Text,Amount)] -> Text -> IO Value
allocate ledger now did split reason = ledgerAction ledger $ \c->do
  let entries=sortOn fst split; names=map fst entries
      encoded=json entries
  require (not(null entries) && length entries<=4 && length(nub names)==length names
    && all (`elem` ["float","backing","operating","lp"]) names
    && all ((>0).units.snd) entries && not(T.null $ T.strip reason) && T.length reason<=512) "invalid_treasury_allocation"
  old <- O.runSelect c $ do
    r<-O.selectTable treasuryallocationsTable
    O.where_(treasuryallocationsDepositId r O..== text did)
    pure r
  sequenceNumber <- case (old :: [TreasuryAllocations]) of
    [r]->do
      proof<-either (const $ reject "invalid_saved_treasury_proof") pure (eitherDecodeStrict' $ TE.encodeUtf8 $ treasuryallocationsProofJson r)
      savedReason<-fieldValue "ownershipAttestation" proof
      require (treasuryallocationsAllocationJson r==encoded && savedReason==reason) "treasury_allocation_conflict"
      pure(treasuryallocationsCriticalSequence r)
    []->do
      paused<-O.runSelect c(fmap deploymentPaused $ O.selectTable deploymentTable)
      require(paused==[1::Int64]) "treasury_allocation_requires_pause"
      freshC c now
      deposits<-O.runSelect c $ do
        r<-O.selectTable depositsTable
        O.where_(depositsId r O..== text did)
        pure r
      deposit<-case (deposits :: [Deposits]) of
        [r] | depositsOrderId r==Nothing && depositsEligible r==1 && depositsAllocated r==0 ->pure r
        _->reject "receipt_not_available_for_treasury"
      let quantity=depositsAmount deposit
      asset<-case depositsAsset deposit of
        "Native"->pure Native
        "Wrapped"->pure Wrapped
        "Sol"->pure Sol
        _->reject "invalid_treasury_asset"
      require(sum(map (toInteger.units.snd) entries)==toInteger quantity) "treasury_allocation_amount_mismatch"
      require(asset/=Sol || names==["operating"]) "sol_reserved_for_operating"
      linked<-O.runSelect c $ do
        r<-O.selectTable obligationsTable
        O.where_(obligationsDepositId r O..== text did)
        pure(obligationsId r)
      require(null (linked::[Text])) "receipt_has_customer_obligation"
      let (chain,eventId)=case asset of
            Native->("Native",T.takeWhile (/=':') $ T.drop 7 did)
            Wrapped->("Solana",T.drop 7 did)
            Sol->("SolanaOperating",T.drop 14 did)
      require ((case asset of Native->"native:"; Wrapped->"solana:"; Sol->"sol-operating:") `T.isPrefixOf` did && not(T.null eventId)) "invalid_treasury_receipt_id"
      evidence<-O.runSelect c $ do
        e<-O.selectTable chaineventsTable
        p<-O.selectTable observationevidenceTable
        O.where_(chaineventsChain e O..== text chain O..&& chaineventsEventId e O..== text eventId
          O..&& chaineventsAnchor e O..== text(depositsAnchor deposit) O..&& chaineventsNeedsReview e O..== num 0
          O..&& observationevidenceHash p O..== chaineventsEvidenceHash e)
        pure(chaineventsKind e,observationevidenceEvidenceJson p)
      envelope<-case (evidence :: [(Text,Text)]) of
        [(kind,raw)] | kind=="unmatched_incoming" || asset==Native && kind=="incoming" ->
          either (const $ reject "invalid_treasury_observation") pure (eitherDecodeStrict' $ TE.encodeUtf8 raw)
        _->reject "verified_treasury_receipt_required"
      proof<-fieldValue "proof" envelope :: IO Value
      case asset of
        Native->do
          receipts<-fieldValue "receipts" proof :: IO [Value]
          verified<-mapM (\r->do
            rid<-fieldValue "id" r; n<-fieldValue "amount" r :: IO Amount
            order<-fieldValue "order" r :: IO (Maybe Text); eligible<-fieldValue "eligible" r
            pure(rid==did && units n==quantity && order==Nothing && eligible)) receipts
          require(length(filter id verified)==1) "verified_treasury_receipt_required"
        _->do
          delta<-fieldValue "delta" proof :: IO Text
          require(delta==T.pack(show quantity)) "verified_treasury_receipt_required"
          if asset==Sol then do
            failed<-fieldValue "failed" proof
            require(not failed) "verified_treasury_receipt_required"
          else pure ()
      seqNo<-criticalSequence c
      posting c ("treasury:"<>did) "operator allocation of verified treasury receipt"
        ((asset,"unallocated",negate $ toInteger quantity):[(asset,account,toInteger $ units n) | (account,n)<-entries])
      let savedProof=json(object ["ownershipAttestation" .= reason,"observation" .= envelope])
      require(T.length savedProof<=8192) "treasury_proof_too_large"
      _<-O.runInsert c O.Insert {O.iTable=treasuryallocationsTable,O.iRows=[TreasuryAllocations (text did) (text encoded) (text savedProof) (num seqNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _<-O.runUpdate c O.Update {O.uTable=depositsTable,O.uUpdateWith= \r->r {depositsAllocated=num 1,depositsState=text "treasury"},O.uWhere= \r->depositsId r O..== text did,O.uReturning=O.rCount}
      pure seqNo
    _->reject "duplicate_treasury_allocation"
  pure(object ["receipt" .= did,"criticalSequence" .= sequenceNumber,"signedOrSent" .= False])
 where
  text=O.sqlStrictText
  num=O.sqlInt8
  json :: ToJSON a => a -> Text
  json=TE.decodeUtf8.LBS.toStrict.encode

-- Record an already-observed operator outflow; never sign or broadcast here.
-- The scanner supplies economic facts, the operator supplies ownership only.
classifySpend :: Ledger -> Text -> Text -> Text -> IO Value
classifySpend ledger stream txid reason = ledgerAction ledger $ \c->do
  require (not(T.null $ T.strip reason) && T.length reason<=512) "invalid_treasury_spend_attestation"
  paused <- O.runSelect c (fmap deploymentPaused $ O.selectTable deploymentTable) :: IO [Int64]
  require (paused==[1]) "treasury_spend_requires_pause"
  rows <- O.runSelect c $ do
    event <- O.selectTable chaineventsTable
    proof <- O.selectTable observationevidenceTable
    O.where_ (chaineventsChain event O..== text stream O..&& chaineventsEventId event O..== text txid O..&&
      chaineventsKind event O..== text "outgoing" O..&& chaineventsEvidenceHash event O..== observationevidenceHash proof O..&&
      observationevidenceChain proof O..== text stream O..&& observationevidenceEventId proof O..== text txid)
    pure (chaineventsAnchor event,observationevidenceEvidenceJson proof)
    :: IO [(Text,Text)]
  (anchor,raw) <- case rows of [row]->pure row; _->reject "treasury_spend_not_observed"
  observation <- either (const $ reject "invalid_observation_evidence") pure (eitherDecodeStrict' $ TE.encodeUtf8 raw)
  proof <- fieldValue "proof" observation
  economic@(asset,outflow,fee) <- either reject pure (economicOutflow stream proof)
  attempts <- O.runSelect c $ do
    a <- O.selectTable attemptsTable
    O.where_ (attemptsTxid a O..== text txid)
    pure (attemptsTxid a)
    :: IO [Text]
  require (null attempts) "customer_attempt_cannot_be_treasury_spend"
  old <- O.runSelect c $ do
    row <- O.selectTable treasuryspendsTable
    O.where_ (treasuryspendsChain row O..== text stream O..&& treasuryspendsEventId row O..== text txid)
    pure row
    :: IO [TreasurySpends]
  sequenceNo <- case old of
    [row]->do
      saved <- either (const $ reject "invalid_saved_treasury_proof") pure (eitherDecodeStrict' $ TE.encodeUtf8 $ treasuryspendsProofJson row)
      savedReason <- fieldValue "ownershipAttestation" saved
      require (treasuryspendsAnchor row==anchor && treasuryspendsEconomicJson row==json economic && savedReason==reason) "treasury_spend_conflict"
      pure (treasuryspendsCriticalSequence row)
    []->do
      let costs | asset==Native = [("float",toInteger(units outflow)-toInteger(units fee)),("operating",toInteger(units fee))]
                | asset==Wrapped = [("float",toInteger(units outflow))]
                | otherwise = [("operating",toInteger(units outflow))]
      forM_ costs $ \(account,cost)->do
        free <- if account=="float" then freeInventory c asset else freeOperating c (T.pack(show asset))
        require (cost>=0 && free>=cost) "treasury_spend_exceeds_free_allocation"
      n <- criticalSequence c
      posting c ("treasury-spend:"<>stream<>":"<>txid) "verified operator spend and network costs"
        ([(asset,account,negate cost) | (account,cost)<-costs]<>[(asset,"external",toInteger(units outflow))])
      let evidence=json(object["ownershipAttestation" .= reason,"observation" .= observation])
      _ <- O.runInsert c O.Insert
        { O.iTable=treasuryspendsTable,O.iRows=[TreasurySpends (text stream) (text txid) (text anchor) (text $ json economic) (text evidence) (O.sqlInt8 n)]
        , O.iReturning=O.rCount,O.iOnConflict=Nothing }
      pure n
    _->reject "duplicate_treasury_spend"
  -- Clear only this event. A changed anchor/economic effect conflicts above.
  -- Skip a no-op update so exact replay also preserves custody revision.
  _ <- O.runUpdate c O.Update
    { O.uTable=chaineventsTable,O.uUpdateWith= \row->row {chaineventsNeedsReview=O.sqlInt8 0}
    , O.uWhere= \row->chaineventsChain row O..== text stream O..&& chaineventsEventId row O..== text txid O..&& chaineventsNeedsReview row O../= O.sqlInt8 0
    , O.uReturning=O.rCount }
  pure(object["transaction" .= txid,"criticalSequence" .= sequenceNo,"signedOrSent" .= False])
 where
  text=O.sqlStrictText
  json :: ToJSON a => a -> Text
  json=TE.decodeUtf8.LBS.toStrict.encode
