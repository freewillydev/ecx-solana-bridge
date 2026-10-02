-- A replacement draft is an operator decision, not a second economic intent.
-- Cancellation retains the old attempt, its reservations and every old draft.
CREATE TABLE native_replacement_drafts(critical_sequence INTEGER PRIMARY KEY CHECK(critical_sequence>0), parent_txid TEXT NOT NULL REFERENCES attempts(txid), fee INTEGER NOT NULL CHECK(typeof(fee)='integer' AND fee>0), draft_json TEXT NOT NULL CHECK(json_valid(draft_json) AND length(draft_json)<=200000), work_hash TEXT NOT NULL CHECK(length(work_hash)=64), reason TEXT NOT NULL CHECK(length(trim(reason))>0 AND length(reason)<=512), proof_json TEXT NOT NULL CHECK(json_valid(proof_json) AND length(proof_json)<=32768), UNIQUE(parent_txid,fee,reason));
-- @statement
CREATE TABLE native_replacement_cancellations(draft_sequence INTEGER PRIMARY KEY REFERENCES native_replacement_drafts(critical_sequence), reason TEXT NOT NULL CHECK(length(trim(reason))>0 AND length(reason)<=512), critical_sequence INTEGER NOT NULL UNIQUE CHECK(critical_sequence>draft_sequence));
-- @statement
CREATE TRIGGER native_replacement_draft_binding BEFORE INSERT ON native_replacement_drafts WHEN NOT EXISTS(SELECT 1 FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN deposits d ON d.id=o.deposit_id JOIN fee_reservations f ON f.intent_id=i.id WHERE a.txid=NEW.parent_txid AND a.state='broadcast_intent' AND i.chain='Native' AND i.resolved=0 AND o.status='paying' AND d.eligible=1 AND f.asset='Native' AND f.released=0 AND f.amount>=a.fee_limit AND NEW.fee<=a.fee_limit) OR EXISTS(SELECT 1 FROM native_replacement_drafts r JOIN attempts a ON a.txid=r.parent_txid WHERE a.intent_id=(SELECT intent_id FROM attempts WHERE txid=NEW.parent_txid) AND NOT EXISTS(SELECT 1 FROM native_replacement_cancellations x WHERE x.draft_sequence=r.critical_sequence)) BEGIN SELECT RAISE(ABORT,'native_replacement_draft_binding'); END;
-- @statement
CREATE TRIGGER immutable_native_replacement_draft_update BEFORE UPDATE ON native_replacement_drafts BEGIN SELECT RAISE(ABORT,'immutable_native_replacement_draft'); END;
-- @statement
CREATE TRIGGER immutable_native_replacement_draft_delete BEFORE DELETE ON native_replacement_drafts BEGIN SELECT RAISE(ABORT,'immutable_native_replacement_draft'); END;
-- @statement
CREATE TRIGGER immutable_native_replacement_cancel_update BEFORE UPDATE ON native_replacement_cancellations BEGIN SELECT RAISE(ABORT,'immutable_native_replacement_cancellation'); END;
-- @statement
CREATE TRIGGER immutable_native_replacement_cancel_delete BEFORE DELETE ON native_replacement_cancellations BEGIN SELECT RAISE(ABORT,'immutable_native_replacement_cancellation'); END;
-- @statement
CREATE TRIGGER custody_native_replacement_draft AFTER INSERT ON native_replacement_drafts BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_native_replacement_cancel AFTER INSERT ON native_replacement_cancellations BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
UPDATE deployment SET schema_version=16,paused=1,pause_reason='migration_requires_reconciliation';
