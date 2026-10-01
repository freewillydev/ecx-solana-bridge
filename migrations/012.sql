-- Source loss never erases a receipt, obligation or outgoing payment. A
-- proved native conflict records a reversible contra-allocation separately.
CREATE TABLE source_recoveries(id INTEGER PRIMARY KEY, deposit_id TEXT NOT NULL REFERENCES deposits(id), state TEXT NOT NULL CHECK(state IN('pending','missing','restored','unavailable')), shortfall INTEGER NOT NULL CHECK(typeof(shortfall)='integer' AND shortfall>=0), evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json) AND length(evidence_json)<=16384), critical_sequence INTEGER NOT NULL UNIQUE CHECK(critical_sequence>0));
-- @statement
CREATE INDEX source_recovery_latest ON source_recoveries(deposit_id,id);
-- @statement
CREATE VIEW source_recovery_state AS SELECT r.* FROM source_recoveries r WHERE r.id=(SELECT MAX(p.id) FROM source_recoveries p WHERE p.deposit_id=r.deposit_id);
-- @statement
CREATE TRIGGER immutable_source_recovery_update BEFORE UPDATE ON source_recoveries BEGIN SELECT RAISE(ABORT,'immutable_source_recovery'); END;
-- @statement
CREATE TRIGGER immutable_source_recovery_delete BEFORE DELETE ON source_recoveries BEGIN SELECT RAISE(ABORT,'immutable_source_recovery'); END;
-- @statement
CREATE TRIGGER source_recovery_binding BEFORE INSERT ON source_recoveries WHEN NOT EXISTS(SELECT 1 FROM deposits d WHERE d.id=NEW.deposit_id AND NEW.shortfall IN(0,d.amount) AND (NEW.shortfall=0 OR d.asset='Native') AND (NEW.state<>'missing' OR NEW.shortfall=d.amount AND d.eligible=0) AND (NEW.state<>'restored' OR NEW.shortfall=0 AND d.eligible=1)) BEGIN SELECT RAISE(ABORT,'source_recovery_binding'); END;
-- @statement
CREATE TRIGGER custody_source_recovery AFTER INSERT ON source_recoveries BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
UPDATE deployment SET schema_version=12,paused=1,pause_reason='migration_requires_reconciliation';
