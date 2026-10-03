-- Allow earned-reservation release only after all preparation work was cancelled
-- unsigned. Preserve every intent, preparation and cancellation record.
BEGIN;
DO $$ BEGIN
 IF NOT pg_try_advisory_xact_lock(1162041393,18)
 THEN RAISE EXCEPTION 'worker_already_running'; END IF;
 IF EXISTS(SELECT 1 FROM deployment WHERE schema_version<>19)
 THEN RAISE EXCEPTION 'cancellation_schema_mismatch'; END IF;
END $$;
CREATE OR REPLACE FUNCTION trg_fee_withdrawal_cancellation_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM fee_withdrawals w WHERE w.id=NEW.withdrawal_id AND NEW.critical_sequence>w.critical_sequence)
 THEN RAISE EXCEPTION 'fee_withdrawal_cancellation_binding' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM intents WHERE id='fee:'||NEW.withdrawal_id) AND NOT EXISTS(
   SELECT 1 FROM intents i JOIN fee_reservations f ON f.intent_id=i.id
   WHERE i.id='fee:'||NEW.withdrawal_id AND i.withdrawal_id=NEW.withdrawal_id
   AND i.obligation_id IS NULL AND i.resolved=1 AND f.released=1
   AND EXISTS(SELECT 1 FROM deployment WHERE singleton=1 AND paused=1)
   AND NOT EXISTS(SELECT 1 FROM attempts a WHERE a.intent_id=i.id)
   AND EXISTS(SELECT 1 FROM preparations p WHERE p.intent_id=i.id)
   AND NOT EXISTS(SELECT 1 FROM preparations p WHERE p.intent_id=i.id AND
     (p.cancelled<>1 OR p.retired_txid IS NOT NULL OR NOT EXISTS(
       SELECT 1 FROM preparation_cancellations c WHERE c.intent_id=p.intent_id
       AND c.generation=p.generation AND c.completed=1 AND c.critical_sequence<NEW.critical_sequence)))
 ) THEN RAISE EXCEPTION 'fee_withdrawal_cancellation_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
UPDATE deployment SET schema_version=20;
COMMIT;
