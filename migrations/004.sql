-- One Solana adapter observes two addresses: the token ATA and SOL fee payer.
-- Their histories have different signatures and need independent cursors.
DROP TRIGGER immutable_scan_origin;
-- @statement
ALTER TABLE scan_origins RENAME TO scan_origins_v3;
-- @statement
CREATE TABLE scan_origins(chain TEXT PRIMARY KEY CHECK(chain IN('Native','Solana','SolanaOperating')), anchor TEXT NOT NULL);
-- @statement
INSERT INTO scan_origins SELECT * FROM scan_origins_v3;
-- @statement
DROP TABLE scan_origins_v3;
-- @statement
CREATE TRIGGER immutable_scan_origin BEFORE UPDATE ON scan_origins BEGIN SELECT RAISE(ABORT,'immutable_scan_origin'); END;
-- @statement
ALTER TABLE scan_health RENAME TO scan_health_v3;
-- @statement
CREATE TABLE scan_health(chain TEXT PRIMARY KEY CHECK(chain IN('Native','Solana','SolanaOperating')), last_success INTEGER, last_error TEXT, checked_at INTEGER NOT NULL);
-- @statement
INSERT INTO scan_health SELECT * FROM scan_health_v3;
-- @statement
DROP TABLE scan_health_v3;
-- @statement
DROP INDEX chain_event_review;
-- @statement
ALTER TABLE chain_events RENAME TO chain_events_v3;
-- @statement
CREATE TABLE chain_events(chain TEXT NOT NULL CHECK(chain IN('Native','Solana','SolanaOperating')), event_id TEXT NOT NULL, kind TEXT NOT NULL, anchor TEXT NOT NULL, evidence_hash TEXT NOT NULL REFERENCES observation_evidence(hash), first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, needs_review INTEGER NOT NULL CHECK(needs_review IN(0,1)), PRIMARY KEY(chain,event_id));
-- @statement
INSERT INTO chain_events SELECT * FROM chain_events_v3;
-- @statement
DROP TABLE chain_events_v3;
-- @statement
CREATE INDEX chain_event_review ON chain_events(chain,needs_review,kind);
-- @statement
CREATE TABLE treasury_allocations(deposit_id TEXT PRIMARY KEY REFERENCES deposits(id), allocation_json TEXT NOT NULL, proof_json TEXT NOT NULL, critical_sequence INTEGER NOT NULL);
-- @statement
CREATE TRIGGER immutable_treasury_allocation_update BEFORE UPDATE ON treasury_allocations BEGIN SELECT RAISE(ABORT,'immutable_treasury_allocation'); END;
-- @statement
CREATE TRIGGER immutable_treasury_allocation_delete BEFORE DELETE ON treasury_allocations BEGIN SELECT RAISE(ABORT,'immutable_treasury_allocation'); END;
-- @statement
CREATE TABLE treasury_spends(chain TEXT NOT NULL, event_id TEXT NOT NULL, anchor TEXT NOT NULL, economic_json TEXT NOT NULL, proof_json TEXT NOT NULL, critical_sequence INTEGER NOT NULL, PRIMARY KEY(chain,event_id), FOREIGN KEY(chain,event_id) REFERENCES chain_events(chain,event_id));
-- @statement
CREATE TRIGGER immutable_treasury_spend_update BEFORE UPDATE ON treasury_spends BEGIN SELECT RAISE(ABORT,'immutable_treasury_spend'); END;
-- @statement
CREATE TRIGGER immutable_treasury_spend_delete BEFORE DELETE ON treasury_spends BEGIN SELECT RAISE(ABORT,'immutable_treasury_spend'); END;
-- @statement
UPDATE deployment SET schema_version=4,paused=1,pause_reason='migration_requires_reconciliation';
