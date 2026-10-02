{-# LANGUAGE TemplateHaskell, FlexibleInstances, MultiParamTypeClasses #-}
-- Internal funding stage only. No public handler, signing or send authority.
module Bridge.Postgres.FeeWithdrawal (reserve,cancel) where

import Bridge.Ledger.Model (encodeRecord)
import Bridge.Config
import Bridge.Types hiding (deploymentFingerprint)
import Bridge.Postgres.Ledger
import Bridge.Postgres.Custody (freshC)
import Bridge.Postgres.Schema (deploymentTable,deploymentPaused,deploymentFingerprint,intentsTable,intentsId)
import Data.Aeson (object,(.=),Value)
import Data.Int (Int64)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Profunctor.Product (p3)
import Data.Profunctor.Product.TH (makeAdaptorAndInstance)
import qualified Opaleye as O

data WithdrawalF a b c d e f g = Withdrawal
 { wid :: a, asset :: b, quantity :: c, recipient :: d, policy :: e, reason :: f, sequenceNo :: g }
 deriving (Eq,Show)
$(makeAdaptorAndInstance "pWithdrawal" ''WithdrawalF)
type Withdrawal = WithdrawalF Text Text Int64 Text Text Text Int64
type Fields = WithdrawalF (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
 (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlText) (O.Field O.SqlInt8)
withdrawals :: O.Table Fields Fields
withdrawals = O.table "fee_withdrawals" $ pWithdrawal (Withdrawal
 (O.requiredTableField "id") (O.requiredTableField "asset") (O.requiredTableField "amount")
 (O.requiredTableField "recipient") (O.requiredTableField "policy_json")
 (O.requiredTableField "reason") (O.requiredTableField "critical_sequence"))
cancellations :: O.Table (O.Field O.SqlText,O.Field O.SqlText,O.Field O.SqlInt8) (O.Field O.SqlText,O.Field O.SqlText,O.Field O.SqlInt8)
cancellations = O.table "fee_withdrawal_cancellations" $ p3
 (O.requiredTableField "withdrawal_id",O.requiredTableField "reason",O.requiredTableField "critical_sequence")

-- Caller must validate the recipient on the real chain before exposing this
-- stage as an operator command. Immutable policy supplies later payment limits.
reserve :: Ledger -> Config -> Int64 -> Text -> Asset -> Amount -> Text -> Text -> IO Value
reserve ledger cfg now key currency n destination explanation = ledgerAction ledger $ \c->do
 require (now>=0 && T.length key==64 && T.all (`elem` ("0123456789abcdef"::String)) key
   && currency `elem` [Native,Wrapped] && units n>0 && n<=maxInput cfg
   && not(T.null destination) && T.length destination<=128 && validReason explanation) "invalid_fee_withdrawal"
 deployment<-O.runSelect c $ fmap (\d->(deploymentPaused d,deploymentFingerprint d)) $ O.selectTable deploymentTable :: IO [(Int64,Text)]
 require(map snd deployment==[fingerprint cfg]) "fee_withdrawal_profile_mismatch"
 let saved=encodeRecord $ object
       ["fingerprint" .= fingerprint cfg,"policy" .= PolicySnapshot (nativeConfirmations cfg) "finalized" (fingerprint cfg),
        "nativeFee" .= maxNativeFee cfg,"solanaFee" .= maxSolFee cfg,"solanaRent" .= maxSolAccountRent cfg]
     expected :: Withdrawal
     expected=Withdrawal key (T.pack $ show currency) (units n) destination saved explanation 0
 old <- O.runSelect c $ do
   w<-O.selectTable withdrawals
   O.where_(wid w O..== text key)
   pure w
 seqNo <- case (old :: [Withdrawal]) of
   [w]->require (w{sequenceNo=0}==expected) "fee_withdrawal_conflict" >> pure(sequenceNo w)
   []->do
     require(map fst deployment==[1]) "fee_withdrawal_requires_pause"
     freshC c now
     totals<-balances c
     require(M.findWithDefault 0 (T.pack(show currency),"earned") totals>=toInteger(units n)) "insufficient_earned_fees"
     seqNo<-criticalSequence c
     _<-O.runInsert c O.Insert {O.iTable=withdrawals,O.iRows=[Withdrawal (text key) (text $ T.pack(show currency)) (num $ units n) (text destination) (text saved) (text explanation) (num seqNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
     posting c ("fee-reserve:"<>key) "reserve earned fees for operator withdrawal"
       [(currency,"earned",negate $ toInteger $ units n),(currency,"fee_pending",toInteger $ units n)]
     pure seqNo
   _->reject "duplicate_fee_withdrawal"
 pure(object["withdrawal" .= key,"criticalSequence" .= seqNo,"signedOrSent" .= False])

-- Cancellation returns funds only before any payment intent exists. A signed
-- or uncertain payment must use payment recovery, never this funding release.
cancel :: Ledger -> Text -> Text -> IO Value
cancel ledger key explanation = ledgerAction ledger $ \c->do
 require(validReason explanation) "invalid_fee_withdrawal_cancellation"
 old<-O.runSelect c $ do
   row@(identifier,_,_)<-O.selectTable cancellations
   O.where_(identifier O..== text key)
   pure row
 seqNo<-case (old :: [(Text,Text,Int64)]) of
   [(_,saved,s)]->require(saved==explanation) "fee_withdrawal_cancellation_conflict" >> pure s
   []->do
     ws<-O.runSelect c $ do
       w<-O.selectTable withdrawals
       O.where_(wid w O..== text key)
       pure w
     w<-case (ws :: [Withdrawal]) of [one]->pure one;_->reject "fee_withdrawal_not_found"
     work<-O.runSelect c $ do
       i<-O.selectTable intentsTable
       O.where_(intentsId i O..== text("fee:"<>key))
       pure(intentsId i)
       :: IO [Text]
     require(null work) "fee_withdrawal_payment_exists"
     currency<-case asset w of "Native"->pure Native;"Wrapped"->pure Wrapped;_->reject "invalid_fee_withdrawal_asset"
     seqNo<-criticalSequence c
     _<-O.runInsert c O.Insert {O.iTable=cancellations,O.iRows=[(text key,text explanation,num seqNo)],O.iReturning=O.rCount,O.iOnConflict=Nothing}
     posting c ("fee-cancel:"<>key) "cancel unsigned operator fee reservation"
       [(currency,"fee_pending",negate $ toInteger $ quantity w),(currency,"earned",toInteger $ quantity w)]
     pure seqNo
   _->reject "duplicate_fee_withdrawal_cancellation"
 pure(object["withdrawal" .= key,"criticalSequence" .= seqNo,"signedOrSent" .= False])

validReason :: Text -> Bool
validReason value=not(T.null $ T.strip value) && T.length value<=512
text :: Text -> O.Field O.SqlText
text=O.sqlStrictText
num :: Int64 -> O.Field O.SqlInt8
num=O.sqlInt8
