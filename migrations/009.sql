-- A custody check certifies one ledger revision. Quotes and address allocation
-- do not move money; observations, journal entries and attempts invalidate it.
CREATE TABLE custody_check(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL DEFAULT 0 CHECK(typeof(revision)='integer' AND revision>=0), checked_revision INTEGER, checked_at INTEGER, last_error TEXT, report_json TEXT);
-- @statement
INSERT INTO custody_check(singleton) VALUES(1);
-- @statement
CREATE TRIGGER custody_posting AFTER INSERT ON postings BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_deposit_insert AFTER INSERT ON deposits BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_deposit_update AFTER UPDATE ON deposits BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_attempt_insert AFTER INSERT ON attempts BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_attempt_update AFTER UPDATE ON attempts BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_checkpoint_insert AFTER INSERT ON checkpoints BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_checkpoint_update AFTER UPDATE ON checkpoints BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_scan_insert AFTER INSERT ON scan_health BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_scan_update AFTER UPDATE ON scan_health BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_event_insert AFTER INSERT ON chain_events BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
CREATE TRIGGER custody_event_update AFTER UPDATE ON chain_events BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
UPDATE deployment SET schema_version=9,paused=1,pause_reason='migration_requires_reconciliation';
