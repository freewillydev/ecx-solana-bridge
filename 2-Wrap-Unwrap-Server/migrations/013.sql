-- An operator can restore only the exact obligation suspended by source loss.
-- Existing review records without that work snapshot are never inferred.
CREATE TABLE source_recovery_approvals(obligation_id TEXT NOT NULL REFERENCES obligations(id), restoration_sequence INTEGER NOT NULL REFERENCES source_recoveries(critical_sequence), loss_sequence INTEGER NOT NULL REFERENCES source_recoveries(critical_sequence), prior_status TEXT NOT NULL CHECK(prior_status IN('ready','paying')), work_hash TEXT NOT NULL CHECK(length(work_hash)=64), reason TEXT NOT NULL CHECK(length(trim(reason))>0 AND length(reason)<=512), proof_json TEXT NOT NULL CHECK(json_valid(proof_json) AND length(proof_json)<=32768), critical_sequence INTEGER NOT NULL UNIQUE CHECK(critical_sequence>restoration_sequence), PRIMARY KEY(obligation_id,restoration_sequence));
-- @statement
CREATE TRIGGER immutable_source_approval_update BEFORE UPDATE ON source_recovery_approvals BEGIN SELECT RAISE(ABORT,'immutable_source_approval'); END;
-- @statement
CREATE TRIGGER immutable_source_approval_delete BEFORE DELETE ON source_recovery_approvals BEGIN SELECT RAISE(ABORT,'immutable_source_approval'); END;
-- @statement
CREATE TRIGGER source_approval_binding BEFORE INSERT ON source_recovery_approvals WHEN NOT EXISTS(SELECT 1 FROM obligations o JOIN deposits d ON d.id=o.deposit_id JOIN source_recovery_state r ON r.deposit_id=d.id JOIN source_recoveries loss ON loss.critical_sequence=NEW.loss_sequence WHERE o.id=NEW.obligation_id AND o.status='review' AND d.eligible=1 AND r.state='restored' AND r.shortfall=0 AND r.critical_sequence=NEW.restoration_sequence AND loss.deposit_id=d.id AND loss.critical_sequence<r.critical_sequence) BEGIN SELECT RAISE(ABORT,'source_approval_binding'); END;
-- @statement
CREATE TRIGGER custody_source_approval AFTER INSERT ON source_recovery_approvals BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
UPDATE deployment SET schema_version=13,paused=1,pause_reason='migration_requires_reconciliation';
