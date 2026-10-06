-- Pure payment facts and decisions. These values carry no database, clock,
-- network or signing authority; the closed Store operation must read them afresh.
module Bridge.Lifecycle
  ( PaymentStatus(..), PaymentView(..), PreparedPayment(..), RecordedAttempt(..)
  ) where

import Bridge.Domain (Payment,Amount)
import Bridge.Wire (PaymentTerms,SignedAttempt)
import Data.Int (Int64)
import Data.Text (Text)

-- Schema-21 projection retained during extraction. Review can hide economic
-- progress here; schema 22 will separate phase from its execution restrictions.
data PaymentStatus = PaymentReady | PaymentPaying | PaymentPaid | PaymentReview | PaymentCancelled deriving (Eq,Show)
data PaymentView = PaymentView
  { savedPayment :: Payment, savedTerms :: PaymentTerms, savedStatus :: PaymentStatus } deriving (Eq,Show)
data PreparedPayment = PreparedPayment
  { preparedView :: PaymentView, preparedGeneration :: Int, preparedPolicy :: Text
  , preparedDraft :: Maybe Text, preparedFee :: Amount } deriving (Eq,Show)
data RecordedAttempt = RecordedAttempt
  { recordedPayment :: Text, recordedChain :: Text, recordedGeneration :: Int
  , recordedFee :: Amount, recordedState :: Text, recordedSequence :: Maybe Int64
  , recordedObservation :: Maybe Text, recordedSigned :: SignedAttempt } deriving (Eq,Show)
