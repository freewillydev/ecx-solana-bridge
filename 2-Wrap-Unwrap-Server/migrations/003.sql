CREATE TABLE preparations(intent_id TEXT PRIMARY KEY REFERENCES intents(id), policy_json TEXT NOT NULL, draft_json TEXT);
-- @statement
CREATE TRIGGER immutable_preparation_policy BEFORE UPDATE OF intent_id,policy_json ON preparations BEGIN SELECT RAISE(ABORT,'immutable_preparation'); END;
-- @statement
CREATE TRIGGER immutable_preparation_draft BEFORE UPDATE OF draft_json ON preparations WHEN OLD.draft_json IS NOT NULL BEGIN SELECT RAISE(ABORT,'immutable_preparation_draft'); END;
-- @statement
UPDATE deployment SET schema_version=3,paused=1,pause_reason='migration_requires_reconciliation';
