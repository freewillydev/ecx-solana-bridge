module Bridge.Postgres.Refund (createRefund) where
import Bridge.Types
import Bridge.Ledger.Model (Obligation(..))
import Bridge.Postgres.Ledger
import Bridge.Postgres.Schema
import Bridge.RPC (fieldValue)
import Bridge.SolanaMessage (publicKey)
import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict')
import Data.Text (Text)
import Data.Int (Int64)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Opaleye as O

-- Explicit operator/customer-resolution workflow, never an automatic change of
-- destination supplied by a caller. Solana refunds use immutable verified receipt
-- evidence, not a wallet address guessed before the payment exists.
createRefund :: Ledger -> Text -> IO Obligation
createRefund ledger did = ledgerAction ledger $ \c->do
  existing <- O.runSelect c $ do
    row <- O.selectTable obligationsTable
    O.where_(obligationsDepositId row O..== text did O..&& obligationsKind row O..== text "refund")
    pure row
    :: IO [Obligations]
  case existing of
    [row]->pure(asObligation row)
    []->do
      rows <- O.runSelect c $ do
        d <- O.selectTable depositsTable
        q <- O.selectTable ordersTable
        O.where_(depositsId d O..== text did O..&& O.matchNullable (O.sqlBool False) (\oid->oid O..== ordersId q) (depositsOrderId d))
        pure(d,q)
        :: IO [(Deposits,Orders)]
      (d,q) <- case rows of [row@(d,_)] | depositsEligible d==1->pure row; _->reject "refundable_deposit_not_found"
      request <- stored(ordersRequestJson q)
      let oid=ordersId q
      require (depositsAsset d==T.pack(show $ sourceAsset $ direction request)) "unsupported_refund_asset"
      busy <- O.runSelect c $ do
        i <- O.selectTable intentsTable
        o <- O.selectTable obligationsTable
        O.where_(intentsObligationId i O..== obligationsId o O..&& obligationsOrderId o O..== text oid O..&& intentsResolved i O..== O.sqlInt8 0)
        pure(intentsId i)
        :: IO [Text]
      require (null busy) "refund_would_race_payment"
      obligations <- O.runSelect c $ do
        row <- O.selectTable obligationsTable
        O.where_(obligationsOrderId row O..== text oid O..&& obligationsStatus row O../= text "cancelled")
        pure row
        :: IO [Obligations]
      require (all (\row->obligationsDepositId row==did || obligationsStatus row=="paid") obligations) "other_obligation_must_resolve_before_refund"
      let active=[row | row<-obligations,obligationsDepositId row==did]
      require (length active<=1 && all ((`elem` ["ready","review"]).obligationsStatus) active) "principal_already_resolved"
      destination <- if direction request==NativeToWrapped then pure(refund request) else case sourceOwner request of
        Just owner->pure owner
        Nothing->do
          signature <- maybe (reject "invalid_solana_deposit_id") pure(T.stripPrefix "solana:" did)
          evidence <- O.runSelect c $ do
            event <- O.selectTable chaineventsTable
            saved <- O.selectTable observationevidenceTable
            O.where_(chaineventsChain event O..== text "Solana" O..&& chaineventsEventId event O..== text signature O..&& chaineventsKind event O..== text "incoming" O..&& chaineventsNeedsReview event O..== O.sqlInt8 0 O..&& chaineventsEvidenceHash event O..== observationevidenceHash saved)
            pure(observationevidenceEvidenceJson saved)
            :: IO [Text]
          encoded <- case evidence of [value]->pure value; _->reject "verified_refund_owner_missing"
          proof <- stored encoded >>= fieldValue "proof"
          instruction <- fieldValue "instruction" proof
          require (ordersInstruction q==Just instruction) "refund_reference_mismatch"
          owner <- fieldValue "verifiedOwner" proof
          _ <- either reject pure(publicKey owner)
          pure owner
      forM_ active $ \old->do
        _ <- O.runUpdate c O.Update {O.uTable=obligationsTable,O.uUpdateWith= \r->r {obligationsStatus=text "cancelled"},O.uWhere= \r->obligationsId r O..== text(obligationsId old),O.uReturning=O.rCount}
        cancellation <- O.runSelect c $ do
          row <- O.selectTable preparationcancellationsTable
          i <- O.selectTable intentsTable
          O.where_(preparationcancellationsIntentId row O..== text(obligationsId old) O..&& intentsId i O..== preparationcancellationsIntentId row O..&& intentsResolved i O..== O.sqlInt8 1 O..&& preparationcancellationsCompleted row O..== O.sqlInt8 1)
          pure(preparationcancellationsGeneration row)
          :: IO [Int64]
        if null cancellation then pure () else do
          _ <- O.runUpdate c O.Update {O.uTable=feereservationsTable,O.uUpdateWith= \r->r {feereservationsReleased=O.sqlInt8 1},O.uWhere= \r->feereservationsIntentId r O..== text(obligationsId old),O.uReturning=O.rCount}
          pure ()
      let ob=Obligation ("refund:"<>did) oid did "refund" (depositsAsset d) (depositsAmount d) destination
      _ <- O.runInsert c O.Insert {O.iTable=obligationsTable,O.iRows=[Obligations (text $ obligationId ob) (text oid) (text did) (text "refund") (text $ depositsAsset d) (O.sqlInt8 $ depositsAmount d) (text destination) (text "ready")],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      _ <- O.runUpdate c O.Update {O.uTable=depositsTable,O.uUpdateWith= \r->r {depositsAllocated=O.sqlInt8 1},O.uWhere= \r->depositsId r O..== text did,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=reservationsTable,O.uUpdateWith= \r->r {reservationsPhase=text "released"},O.uWhere= \r->reservationsOrderId r O..== text oid,O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=operatingreservationsTable,O.uUpdateWith= \r->r {operatingreservationsPhase=O.ifThenElse (operatingreservationsKind r O..== text "conversion") (text "released") (text "obligation")},O.uWhere= \r->operatingreservationsOrderId r O..== text oid O..&& (operatingreservationsPhase r O..== text "quote" O..|| (operatingreservationsKind r O..== text "conversion" O..&& operatingreservationsPhase r O..== text "obligation")),O.uReturning=O.rCount}
      _ <- O.runUpdate c O.Update {O.uTable=ordersTable,O.uUpdateWith= \r->r {ordersStatus=text "Refunding"},O.uWhere= \r->ordersId r O..== text oid O..&& ordersStatus r O../= text "Paid",O.uReturning=O.rCount}
      _ <- O.runInsert c O.Insert {O.iTable=auditTable,O.iRows=[Audit Nothing (text "refund_authorized") (text did)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
      pure ob
    _->reject "duplicate_refund"
 where
  text=O.sqlStrictText
  stored raw=either (const $ reject "corrupt_ledger_json") pure(eitherDecodeStrict' $ TE.encodeUtf8 raw)
  asObligation row=Obligation (obligationsId row) (obligationsOrderId row) (obligationsDepositId row) (obligationsKind row) (obligationsAsset row) (obligationsAmount row) (obligationsRecipient row)
