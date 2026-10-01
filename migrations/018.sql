-- A reorg may select another already-broadcast member of the same family.
-- Keep the original economic settlement and journal only the fee difference.
CREATE TABLE native_winner_changes(critical_sequence INTEGER PRIMARY KEY CHECK(critical_sequence>0), previous_txid TEXT NOT NULL REFERENCES attempts(txid), winner_txid TEXT NOT NULL REFERENCES attempts(txid), previous_observation TEXT NOT NULL CHECK(json_valid(previous_observation) AND length(previous_observation)<=32768), observation_json TEXT NOT NULL CHECK(json_valid(observation_json) AND length(observation_json)<=32768), evidence_hash TEXT NOT NULL REFERENCES observation_evidence(hash), fee_delta INTEGER NOT NULL CHECK(typeof(fee_delta)='integer' AND fee_delta<>0), CHECK(previous_txid<>winner_txid));
-- @statement
CREATE INDEX native_winner_change_history ON native_winner_changes(winner_txid,critical_sequence);
-- @statement
CREATE TRIGGER native_winner_change_binding BEFORE INSERT ON native_winner_changes WHEN NOT EXISTS(SELECT 1 FROM attempts old JOIN attempts winner ON winner.intent_id=old.intent_id JOIN intents i ON i.id=old.intent_id WHERE old.txid=NEW.previous_txid AND winner.txid=NEW.winner_txid AND old.state='settled' AND old.observation_json=NEW.previous_observation AND winner.state IN('broadcast_intent','review') AND old.critical_sequence>0 AND winner.critical_sequence>0 AND old.preparation_generation=winner.preparation_generation AND old.fee_limit=winner.fee_limit AND i.chain='Native' AND i.resolved=1) BEGIN SELECT RAISE(ABORT,'native_winner_change_binding'); END;
-- @statement
CREATE TRIGGER immutable_native_winner_change_update BEFORE UPDATE ON native_winner_changes BEGIN SELECT RAISE(ABORT,'immutable_native_winner_change'); END;
-- @statement
CREATE TRIGGER immutable_native_winner_change_delete BEFORE DELETE ON native_winner_changes BEGIN SELECT RAISE(ABORT,'immutable_native_winner_change'); END;
-- @statement
CREATE TRIGGER custody_native_winner_change AFTER INSERT ON native_winner_changes BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
DROP VIEW native_payment_recovery_state;
-- @statement
-- Old reviews remain immutable history. A freshly proved winner supersedes
-- its earlier review; a later loss of finality opens a new current review.
CREATE VIEW native_payment_recovery_state AS SELECT r.* FROM native_payment_recoveries r JOIN attempts a ON a.txid=r.txid WHERE a.state='settled' AND r.id=(SELECT MAX(p.id) FROM native_payment_recoveries p WHERE p.txid=r.txid) AND r.critical_sequence>COALESCE((SELECT MAX(w.critical_sequence) FROM native_winner_changes w WHERE w.winner_txid=r.txid),0);
-- @statement
UPDATE deployment SET schema_version=18,paused=1,pause_reason='migration_requires_reconciliation';
