-- Cover a proved deficit with explicitly chosen, unreserved operator capital.
-- The source observation and all customer obligations remain unchanged.
CREATE TABLE source_loss_covers(critical_sequence INTEGER PRIMARY KEY, deposit_id TEXT NOT NULL REFERENCES deposits(id), recovery_sequence INTEGER NOT NULL UNIQUE REFERENCES source_recoveries(critical_sequence), amount INTEGER NOT NULL CHECK(typeof(amount)='integer' AND amount>0), float_amount INTEGER NOT NULL CHECK(typeof(float_amount)='integer' AND float_amount>=0 AND float_amount<=amount), earned_amount INTEGER NOT NULL CHECK(typeof(earned_amount)='integer' AND earned_amount=amount-float_amount), reason TEXT NOT NULL CHECK(length(trim(reason))>0 AND length(reason)<=512), proof_json TEXT NOT NULL CHECK(json_valid(proof_json) AND length(proof_json)<=32768), CHECK(critical_sequence>recovery_sequence));
-- @statement
CREATE TABLE source_loss_returns(cover_sequence INTEGER PRIMARY KEY REFERENCES source_loss_covers(critical_sequence), recovery_sequence INTEGER NOT NULL REFERENCES source_recoveries(critical_sequence), CHECK(recovery_sequence>cover_sequence));
-- @statement
CREATE INDEX source_loss_deposit ON source_loss_covers(deposit_id);
-- @statement
CREATE VIEW active_source_loss_covers AS SELECT f.* FROM source_loss_covers f WHERE NOT EXISTS(SELECT 1 FROM source_loss_returns r WHERE r.cover_sequence=f.critical_sequence);
-- @statement
CREATE VIEW proven_source_losses AS SELECT d.id AS deposit_id FROM deposits d JOIN source_recovery_state r ON r.deposit_id=d.id WHERE d.asset='Native' AND d.eligible=0 AND r.state='missing' AND r.shortfall=d.amount;
-- @statement
CREATE VIEW accounted_source_losses AS SELECT f.deposit_id FROM active_source_loss_covers f JOIN source_recovery_state r ON r.deposit_id=f.deposit_id JOIN deposits d ON d.id=f.deposit_id WHERE d.asset='Native' AND d.eligible=0 AND r.state='missing' AND r.shortfall=d.amount AND f.amount=d.amount;
-- @statement
CREATE TRIGGER source_loss_cover_binding BEFORE INSERT ON source_loss_covers WHEN EXISTS(SELECT 1 FROM active_source_loss_covers f WHERE f.deposit_id=NEW.deposit_id) OR NOT EXISTS(SELECT 1 FROM deposits d JOIN source_recovery_state r ON r.deposit_id=d.id WHERE d.id=NEW.deposit_id AND d.asset='Native' AND d.eligible=0 AND r.state='missing' AND r.shortfall=d.amount AND NEW.amount=d.amount AND r.critical_sequence=NEW.recovery_sequence) BEGIN SELECT RAISE(ABORT,'source_loss_cover_binding'); END;
-- @statement
CREATE TRIGGER source_loss_return_binding BEFORE INSERT ON source_loss_returns WHEN NOT EXISTS(SELECT 1 FROM active_source_loss_covers f JOIN source_recovery_state r ON r.deposit_id=f.deposit_id WHERE f.critical_sequence=NEW.cover_sequence AND r.critical_sequence=NEW.recovery_sequence AND r.state IN('pending','restored') AND r.shortfall=0) BEGIN SELECT RAISE(ABORT,'source_loss_return_binding'); END;
-- @statement
CREATE TRIGGER immutable_source_cover_update BEFORE UPDATE ON source_loss_covers BEGIN SELECT RAISE(ABORT,'immutable_source_loss_cover'); END;
-- @statement
CREATE TRIGGER immutable_source_cover_delete BEFORE DELETE ON source_loss_covers BEGIN SELECT RAISE(ABORT,'immutable_source_loss_cover'); END;
-- @statement
CREATE TRIGGER immutable_source_return_update BEFORE UPDATE ON source_loss_returns BEGIN SELECT RAISE(ABORT,'immutable_source_loss_return'); END;
-- @statement
CREATE TRIGGER immutable_source_return_delete BEFORE DELETE ON source_loss_returns BEGIN SELECT RAISE(ABORT,'immutable_source_loss_return'); END;
-- @statement
CREATE TRIGGER custody_source_cover AFTER INSERT ON source_loss_covers BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_source_return AFTER INSERT ON source_loss_returns BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
UPDATE deployment SET schema_version=14,paused=1,pause_reason='migration_requires_reconciliation';
