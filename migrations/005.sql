-- Preserve every preparation and signed attempt across conclusive Solana expiry.
CREATE TABLE solana_expiries(txid TEXT PRIMARY KEY REFERENCES attempts(txid), proof_json TEXT NOT NULL, critical_sequence INTEGER NOT NULL);
-- @statement
CREATE TRIGGER immutable_solana_expiry_update BEFORE UPDATE ON solana_expiries BEGIN SELECT RAISE(ABORT,'immutable_solana_expiry'); END;
-- @statement
CREATE TRIGGER immutable_solana_expiry_delete BEFORE DELETE ON solana_expiries BEGIN SELECT RAISE(ABORT,'immutable_solana_expiry'); END;
-- @statement
DROP TRIGGER immutable_preparation_policy;
-- @statement
DROP TRIGGER immutable_preparation_draft;
-- @statement
ALTER TABLE preparations RENAME TO preparations_v4;
-- @statement
CREATE TABLE preparations(intent_id TEXT NOT NULL REFERENCES intents(id), generation INTEGER NOT NULL CHECK(generation>=0), policy_json TEXT NOT NULL, draft_json TEXT, retired_txid TEXT UNIQUE REFERENCES solana_expiries(txid), PRIMARY KEY(intent_id,generation));
-- @statement
INSERT INTO preparations(intent_id,generation,policy_json,draft_json) SELECT intent_id,0,policy_json,draft_json FROM preparations_v4;
-- @statement
DROP TABLE preparations_v4;
-- @statement
CREATE UNIQUE INDEX one_active_preparation ON preparations(intent_id) WHERE retired_txid IS NULL;
-- @statement
CREATE TRIGGER immutable_preparation_policy BEFORE UPDATE OF intent_id,generation,policy_json ON preparations BEGIN SELECT RAISE(ABORT,'immutable_preparation'); END;
-- @statement
CREATE TRIGGER immutable_preparation_draft BEFORE UPDATE OF draft_json ON preparations WHEN OLD.draft_json IS NOT NULL BEGIN SELECT RAISE(ABORT,'immutable_preparation_draft'); END;
-- @statement
CREATE TRIGGER immutable_preparation_retirement BEFORE UPDATE OF retired_txid ON preparations WHEN OLD.retired_txid IS NOT NULL BEGIN SELECT RAISE(ABORT,'immutable_preparation_retirement'); END;
-- @statement
CREATE TRIGGER immutable_preparation_delete BEFORE DELETE ON preparations BEGIN SELECT RAISE(ABORT,'immutable_preparation'); END;
-- @statement
ALTER TABLE attempts ADD COLUMN preparation_generation INTEGER NOT NULL DEFAULT 0 CHECK(preparation_generation>=0);
-- @statement
CREATE TRIGGER immutable_attempt_generation BEFORE UPDATE OF preparation_generation ON attempts BEGIN SELECT RAISE(ABORT,'immutable_attempt'); END;
-- @statement
UPDATE deployment SET schema_version=5,paused=1,pause_reason='migration_requires_reconciliation';
