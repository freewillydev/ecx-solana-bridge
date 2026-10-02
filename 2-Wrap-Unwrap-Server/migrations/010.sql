-- Cancel only preparations without a recorded signed attempt. Keep the exact
-- old policy/draft and journal the requested cleanup before touching wallet locks.
ALTER TABLE preparations ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0 CHECK(cancelled IN(0,1));
-- @statement
DROP INDEX one_active_preparation;
-- @statement
CREATE UNIQUE INDEX one_active_preparation ON preparations(intent_id) WHERE retired_txid IS NULL AND cancelled=0;
-- @statement
CREATE TABLE preparation_cancellations(intent_id TEXT NOT NULL, generation INTEGER NOT NULL, reason TEXT NOT NULL, cleanup_json TEXT NOT NULL, critical_sequence INTEGER NOT NULL CHECK(critical_sequence>0), completed INTEGER NOT NULL DEFAULT 0 CHECK(completed IN(0,1)), PRIMARY KEY(intent_id,generation), FOREIGN KEY(intent_id,generation) REFERENCES preparations(intent_id,generation));
-- @statement
CREATE TRIGGER immutable_preparation_cancellation BEFORE UPDATE OF intent_id,generation,reason,cleanup_json,critical_sequence ON preparation_cancellations BEGIN SELECT RAISE(ABORT,'immutable_preparation_cancellation'); END;
-- @statement
CREATE TRIGGER immutable_preparation_cancellation_delete BEFORE DELETE ON preparation_cancellations BEGIN SELECT RAISE(ABORT,'immutable_preparation_cancellation'); END;
-- @statement
CREATE TRIGGER irreversible_preparation_cleanup BEFORE UPDATE OF completed ON preparation_cancellations WHEN NEW.completed<OLD.completed BEGIN SELECT RAISE(ABORT,'irreversible_preparation_cleanup'); END;
-- @statement
CREATE TRIGGER irreversible_preparation_cancellation BEFORE UPDATE OF cancelled ON preparations WHEN NEW.cancelled<OLD.cancelled OR (NEW.cancelled=1 AND (NEW.retired_txid IS NOT NULL OR NOT EXISTS(SELECT 1 FROM preparation_cancellations c WHERE c.intent_id=NEW.intent_id AND c.generation=NEW.generation AND c.completed=1) OR EXISTS(SELECT 1 FROM attempts a WHERE a.intent_id=NEW.intent_id AND a.preparation_generation=NEW.generation))) BEGIN SELECT RAISE(ABORT,'invalid_preparation_cancellation'); END;
-- @statement
CREATE TRIGGER cancelled_preparation_draft BEFORE UPDATE OF draft_json ON preparations WHEN EXISTS(SELECT 1 FROM preparation_cancellations c WHERE c.intent_id=NEW.intent_id AND c.generation=NEW.generation) BEGIN SELECT RAISE(ABORT,'preparation_cancellation_pending'); END;
-- @statement
CREATE TRIGGER cancelled_preparation_attempt BEFORE INSERT ON attempts WHEN NOT EXISTS(SELECT 1 FROM preparations p JOIN intents i ON i.id=p.intent_id WHERE p.intent_id=NEW.intent_id AND p.generation=NEW.preparation_generation AND i.resolved=0 AND p.retired_txid IS NULL AND p.cancelled=0) OR EXISTS(SELECT 1 FROM preparation_cancellations c WHERE c.intent_id=NEW.intent_id AND c.generation=NEW.preparation_generation) BEGIN SELECT RAISE(ABORT,'preparation_not_active'); END;
-- @statement
UPDATE deployment SET schema_version=10,paused=1,pause_reason='migration_requires_reconciliation';
