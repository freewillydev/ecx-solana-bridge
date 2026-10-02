-- Preserve settlement history when a native payment loses finality or moves
-- to another active block. No row authorizes a replacement or changes money.
CREATE TABLE native_payment_recoveries(id INTEGER PRIMARY KEY, txid TEXT NOT NULL REFERENCES attempts(txid), previous_observation TEXT NOT NULL CHECK(json_valid(previous_observation) AND length(previous_observation)<=32768), state TEXT NOT NULL CHECK(state IN('confirming','unavailable','reconfirmed')), observation_json TEXT NOT NULL CHECK(json_valid(observation_json) AND length(observation_json)<=32768), critical_sequence INTEGER NOT NULL UNIQUE CHECK(critical_sequence>0));
-- @statement
CREATE INDEX native_payment_recovery_latest ON native_payment_recoveries(txid,id);
-- @statement
CREATE VIEW native_payment_recovery_state AS SELECT r.* FROM native_payment_recoveries r WHERE r.id=(SELECT MAX(p.id) FROM native_payment_recoveries p WHERE p.txid=r.txid);
-- @statement
CREATE TRIGGER immutable_native_payment_recovery_update BEFORE UPDATE ON native_payment_recoveries BEGIN SELECT RAISE(ABORT,'immutable_native_payment_recovery'); END;
-- @statement
CREATE TRIGGER immutable_native_payment_recovery_delete BEFORE DELETE ON native_payment_recoveries BEGIN SELECT RAISE(ABORT,'immutable_native_payment_recovery'); END;
-- @statement
CREATE TRIGGER native_payment_recovery_binding BEFORE INSERT ON native_payment_recoveries WHEN NOT EXISTS(SELECT 1 FROM attempts a JOIN intents i ON i.id=a.intent_id WHERE a.txid=NEW.txid AND a.state='settled' AND i.chain='Native' AND a.observation_json=NEW.previous_observation) BEGIN SELECT RAISE(ABORT,'native_payment_recovery_binding'); END;
-- @statement
CREATE TRIGGER custody_native_payment_recovery AFTER INSERT ON native_payment_recoveries BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
UPDATE deployment SET schema_version=11,paused=1,pause_reason='migration_requires_reconciliation';
