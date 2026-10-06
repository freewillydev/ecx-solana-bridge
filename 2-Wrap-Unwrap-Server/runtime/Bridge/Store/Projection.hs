-- Relational facts for specific closed Store/migration operations. No connection,
-- evaluator or write capability is exported. Phase and restrictions stay distinct.
module Bridge.Store.Projection (paymentStates, activePayments, readyPayments, sourceRestricted, successorReady) where

import qualified Bridge.Store.Schema as S
import qualified Opaleye as O
import qualified Opaleye.Exists as E

-- The caller checks the overflow row. Active ownership excludes competing ready
-- work even when that active payment itself needs review.
activePayments, readyPayments :: O.Select (S.TextField,S.TextField)
activePayments=O.limit 3 $ do
  root<-O.selectTable S.paymentRoots
  O.where_ (S.rootPhase root O..== O.sqlStrictText "active")
  pure (S.rootId root,S.rootChain root)
readyPayments=O.limit 1001 $ O.orderBy (O.asc fst) $ do
  (root,state)<-paymentStates
  O.where_ (S.rootPhase root O..== O.sqlStrictText "ready" O..&& state O..== O.sqlStrictText "ready")
  pure (S.rootId root,S.rootChain root)

paymentStates :: O.Select (S.PaymentRootFields,S.TextField)
paymentStates = do
  root<-O.selectTable S.paymentRoots
  restricted<-sourceRestricted (S.rootId root)
  retryable<-successorReady (S.rootId root)
  let phase=S.rootPhase root; text=O.sqlStrictText
      state=O.ifThenElse (phase O..== text "settled") (text "paid") $
        O.ifThenElse (phase O..== text "cancelled") (text "cancelled") $
        O.ifThenElse (restricted O..|| (phase O..== text "ready" O..&& O.not retryable)) (text "review") $
        O.ifThenElse (phase O..== text "active") (text "paying") $
        O.ifThenElse (phase O..== text "ready") (text "ready") (text "review")
  pure (root,state)

-- An eligible-again receipt does not itself clear a recorded work-bound review.
-- Coverage also needs this obligation's immutable approval of that active cover.
sourceRestricted :: S.TextField -> O.Select (O.Field O.SqlBool)
sourceRestricted identifier = E.exists $ do
  (obligation,deposit)<-S.obligationReceipts
  source<-O.selectTable S.deposits
  O.where_ (obligation O..== identifier O..&& deposit O..== S.depositId source)
  pending<-E.exists $ do
    (_,receipt,_,_,proof,sequenceNo)<-O.selectTable S.sourceChecks
    let subject=O.jsonBuildObject $ O.jsonBuildObjectField "reason" (O.sqlStrictText "source_eligibility_lost")
          <> O.jsonBuildObjectField "reviewedObligations"
            (O.sqlArray id [O.jsonBuildObject $ O.jsonBuildObjectField "intent" identifier])
    O.where_ (receipt O..== S.depositId source O..&& json proof O..@> json subject)
    approved<-E.exists $ do
      (key,n)<-S.sourceApprovals
      O.where_ (key O..== identifier O..&& n O..>= sequenceNo)
      pure ()
    O.where_ (O.not approved)
    pure ()
  covered<-E.exists $ do
    receipt<-S.accountedLosses
    (cover,key,quantity,_,_)<-S.activeSourceCovers
    (payment,_,_,_,_,_,proof,n)<-O.selectTable S.sourceRecoveryDecisions
    O.where_ (receipt O..== S.depositId source O..&& key O..== receipt O..&& quantity O..== S.depositAmount source
      O..&& payment O..== identifier O..&& n O..> cover
      O..&& json proof O..@> json (O.jsonBuildObject $ O.jsonBuildObjectField "sourceCover" cover))
    pure ()
  O.where_ (pending O..|| (S.depositEligible source O..== O.sqlInt8 0 O..&& O.not covered))
  pure ()
 where
  -- Fixed typed cast of the schema-checked JSON text, never caller SQL.
  json :: O.Field a -> O.Field O.SqlJsonb
  json=O.unsafeCastSqlType

-- Queue/display filter only. The locked preparation decision also validates the
-- full bounded generation history, source, holds, current budget and readiness.
successorReady :: S.TextField -> O.Select (O.Field O.SqlBool)
successorReady identifier = do
  previous<-E.exists $ do
    (key,_,_,_,_,_)<-S.workPreparations
    O.where_ (key O..== identifier)
    pure ()
  successor<-E.exists $ do
    (key,g,_,_,retired,cancelled)<-S.workPreparations
    O.where_ (key O..== identifier O..&& g O..< O.sqlInt8 7)
    cleanup<-E.exists $ do
      (payment,generation,_,_,done)<-S.workCancellations
      O.where_ (payment O..== key O..&& generation O..== g O..&& done O..== O.sqlInt8 1
        O..&& cancelled O..== O.sqlInt8 1 O..&& O.isNull retired)
      pure ()
    expiry<-E.exists $ do
      (tx,_,_,_)<-O.selectTable S.solanaRetryApprovals
      O.where_ (O.matchNullable (O.sqlBool False) (O..== tx) retired O..&& cancelled O..== O.sqlInt8 0)
      pure ()
    later<-E.exists $ do
      (payment,generation,_,_,_,_)<-S.workPreparations
      O.where_ (payment O..== key O..&& generation O..> g)
      pure ()
    remaining<-E.exists $ do
      (tx,payment,_,_,_,_)<-S.workAttempts
      expired<-E.exists $ do
        (saved,_,_)<-O.selectTable S.solanaExpiries
        O.where_ (saved O..== tx)
        pure ()
      O.where_ (payment O..== key O..&& O.not expired)
      pure ()
    O.where_ ((cleanup O..|| expiry) O..&& O.not later O..&& O.not remaining)
    pure ()
  pure (O.not previous O..|| successor)
