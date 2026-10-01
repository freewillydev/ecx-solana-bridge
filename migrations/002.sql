ALTER TABLE deployment RENAME TO deployment_v1;
-- @statement
CREATE TABLE deployment(singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version>=1), fingerprint TEXT NOT NULL, critical_sequence INTEGER NOT NULL DEFAULT 0, backup_sequence INTEGER NOT NULL DEFAULT 0, paused INTEGER NOT NULL DEFAULT 1 CHECK(paused IN(0,1)), pause_reason TEXT NOT NULL DEFAULT 'initialization');
-- @statement
INSERT INTO deployment SELECT singleton,2,fingerprint,critical_sequence,backup_sequence,1,'migration_requires_reconciliation' FROM deployment_v1;
-- @statement
DROP TABLE deployment_v1;
-- @statement
CREATE TABLE scan_origins(chain TEXT PRIMARY KEY CHECK(chain IN('Native','Solana')), anchor TEXT NOT NULL);
-- @statement
CREATE TRIGGER immutable_scan_origin BEFORE UPDATE ON scan_origins BEGIN SELECT RAISE(ABORT,'immutable_scan_origin'); END;
-- @statement
CREATE TABLE scan_health(chain TEXT PRIMARY KEY CHECK(chain IN('Native','Solana')), last_success INTEGER, last_error TEXT, checked_at INTEGER NOT NULL);
-- @statement
CREATE TABLE observation_evidence(hash TEXT PRIMARY KEY, chain TEXT NOT NULL, event_id TEXT NOT NULL, evidence_json TEXT NOT NULL);
-- @statement
CREATE TRIGGER immutable_evidence_update BEFORE UPDATE ON observation_evidence BEGIN SELECT RAISE(ABORT,'immutable_evidence'); END;
-- @statement
CREATE TRIGGER immutable_evidence_delete BEFORE DELETE ON observation_evidence BEGIN SELECT RAISE(ABORT,'immutable_evidence'); END;
-- @statement
CREATE TABLE chain_events(chain TEXT NOT NULL CHECK(chain IN('Native','Solana')), event_id TEXT NOT NULL, kind TEXT NOT NULL, anchor TEXT NOT NULL, evidence_hash TEXT NOT NULL REFERENCES observation_evidence(hash), first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, needs_review INTEGER NOT NULL CHECK(needs_review IN(0,1)), PRIMARY KEY(chain,event_id));
-- @statement
CREATE INDEX chain_event_review ON chain_events(chain,needs_review,kind);
