-- Mutually exclusive attempts share one economic intent. A later callback or
-- an accidental intent reopening cannot book a second successful payout.
CREATE UNIQUE INDEX one_settled_payment_per_intent ON attempts(intent_id) WHERE state='settled';
-- @statement
UPDATE deployment SET schema_version=15,paused=1,pause_reason='migration_requires_reconciliation';
