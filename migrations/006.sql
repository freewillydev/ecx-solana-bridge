CREATE TABLE solana_retry_approvals(expired_txid TEXT PRIMARY KEY REFERENCES solana_expiries(txid), reason TEXT NOT NULL, proof_json TEXT NOT NULL, critical_sequence INTEGER NOT NULL);
-- @statement
CREATE TRIGGER immutable_retry_approval_update BEFORE UPDATE ON solana_retry_approvals BEGIN SELECT RAISE(ABORT,'immutable_retry_approval'); END;
-- @statement
CREATE TRIGGER immutable_retry_approval_delete BEFORE DELETE ON solana_retry_approvals BEGIN SELECT RAISE(ABORT,'immutable_retry_approval'); END;
-- @statement
UPDATE obligations SET status='review' WHERE status='ready' AND id IN (SELECT i.obligation_id FROM intents i WHERE i.resolved=1 AND EXISTS(SELECT 1 FROM attempts a JOIN solana_expiries e ON e.txid=a.txid WHERE a.intent_id=i.id));
-- @statement
UPDATE orders SET status='NeedsReview' WHERE status='Ready' AND id IN (SELECT order_id FROM obligations WHERE status='review');
-- @statement
UPDATE deployment SET schema_version=6,paused=1,pause_reason='migration_requires_reconciliation';
