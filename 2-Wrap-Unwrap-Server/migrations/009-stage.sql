-- Fixed DDL used only inside the closed payment-root migration transaction.
-- Version 2200 is private staging; neither serve nor signer accepts it.
DO $$ BEGIN
 IF NOT pg_try_advisory_xact_lock(1162041393,18)
 THEN RAISE EXCEPTION 'worker_already_running'; END IF;
 IF NOT EXISTS(SELECT 1 FROM deployment WHERE singleton=1 AND schema_version=2200 AND paused=1)
 THEN RAISE EXCEPTION 'payment_root_migration_not_staged'; END IF;
END $$;
ALTER TABLE intents ADD COLUMN deposit_id TEXT;
ALTER TABLE intents ADD COLUMN phase TEXT;
ALTER TABLE intents ADD COLUMN active_generation BIGINT;
ALTER TABLE intents ADD COLUMN settled_txid TEXT;
ALTER TABLE intents ADD COLUMN settlement_event_id TEXT;
ALTER TABLE intents ALTER COLUMN resolved SET DEFAULT 1;
ALTER TABLE orders ADD COLUMN admission_state TEXT;
-- Backfill creates ready and cancelled roots that had no schema-21 intent.
-- Final immutable funding/phase checks are installed after verified conversion.
DROP TRIGGER payment_funding_binding ON intents;
