-- Apply after baseline PostgreSQL 001..005, with the old worker stopped.
-- Existing intent/attempt identities and saved bytes are unchanged.
BEGIN;
DO $$ BEGIN
 IF NOT pg_try_advisory_xact_lock(1162041393,18)
 THEN RAISE EXCEPTION 'worker_already_running'; END IF;
 IF EXISTS(SELECT 1 FROM deployment WHERE schema_version<>18)
 THEN RAISE EXCEPTION 'payment_funding_schema_mismatch'; END IF;
END $$;
ALTER TABLE intents ALTER COLUMN obligation_id DROP NOT NULL;
ALTER TABLE intents ADD COLUMN withdrawal_id TEXT UNIQUE REFERENCES fee_withdrawals(id);
ALTER TABLE intents ADD CONSTRAINT exactly_one_payment_funding CHECK
 ((obligation_id IS NOT NULL AND withdrawal_id IS NULL AND id=obligation_id)
 OR (obligation_id IS NULL AND withdrawal_id IS NOT NULL AND id='fee:'||withdrawal_id));
CREATE FUNCTION trg_payment_funding_binding() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE currency TEXT;
BEGIN
 IF TG_OP='UPDATE' AND (NEW.id,NEW.obligation_id,NEW.withdrawal_id,NEW.chain)
   IS DISTINCT FROM (OLD.id,OLD.obligation_id,OLD.withdrawal_id,OLD.chain)
 THEN RAISE EXCEPTION 'immutable_payment_funding' USING ERRCODE='23514'; END IF;
 IF NEW.withdrawal_id IS NOT NULL THEN
   SELECT asset INTO currency FROM fee_withdrawals WHERE id=NEW.withdrawal_id;
   IF EXISTS(SELECT 1 FROM fee_withdrawal_cancellations WHERE withdrawal_id=NEW.withdrawal_id)
   THEN RAISE EXCEPTION 'cancelled_payment_funding' USING ERRCODE='23514'; END IF;
 ELSE
   SELECT asset INTO currency FROM obligations WHERE id=NEW.obligation_id;
 END IF;
 IF currency IS NULL OR currency NOT IN('Native','Wrapped')
   OR NEW.chain<>(CASE WHEN currency='Native' THEN 'Native' ELSE 'Solana' END)
 THEN RAISE EXCEPTION 'payment_funding_chain_mismatch' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER payment_funding_binding BEFORE INSERT OR UPDATE ON intents
 FOR EACH ROW EXECUTE FUNCTION trg_payment_funding_binding();
UPDATE deployment SET schema_version=19,paused=1,pause_reason='payment_funding_migration';
COMMIT;
