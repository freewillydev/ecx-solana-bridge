-- Replacement decisions use the same customer/earned funding engine.
BEGIN;
DO $$ BEGIN
 IF NOT pg_try_advisory_xact_lock(1162041393,18)
 THEN RAISE EXCEPTION 'worker_already_running'; END IF;
 IF EXISTS(SELECT 1 FROM deployment WHERE schema_version<>20)
 THEN RAISE EXCEPTION 'replacement_schema_mismatch'; END IF;
END $$;
CREATE OR REPLACE FUNCTION trg_native_replacement_draft_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(
   SELECT 1 FROM attempts a JOIN intents i ON i.id=a.intent_id
   JOIN fee_reservations f ON f.intent_id=i.id
   LEFT JOIN obligations o ON o.id=i.obligation_id
   LEFT JOIN deposits d ON d.id=o.deposit_id
   LEFT JOIN fee_withdrawals w ON w.id=i.withdrawal_id
   WHERE a.txid=NEW.parent_txid AND a.state='broadcast_intent'
   AND a.critical_sequence>0 AND NEW.critical_sequence>a.critical_sequence
   AND i.chain='Native' AND i.resolved=0 AND f.asset='Native'
   AND f.released=0 AND f.amount>=a.fee_limit AND NEW.fee<=a.fee_limit
   AND EXISTS(SELECT 1 FROM deployment WHERE singleton=1 AND paused=1)
   AND ((o.status='paying' AND (d.eligible=1 OR EXISTS(
     SELECT 1 FROM accounted_source_losses l JOIN active_source_loss_covers c ON c.deposit_id=l.deposit_id
     JOIN source_recovery_approvals r ON r.obligation_id=o.id
     WHERE l.deposit_id=d.id AND c.amount=d.amount AND r.critical_sequence>c.critical_sequence
     AND r.proof_json::jsonb->>'sourceCover'=c.critical_sequence::text)))
     OR (w.asset='Native' AND NOT EXISTS(SELECT 1 FROM fee_withdrawal_cancellations x WHERE x.withdrawal_id=w.id)))
 ) OR EXISTS(
   SELECT 1 FROM native_replacement_drafts r JOIN attempts a ON a.txid=r.parent_txid
   WHERE a.intent_id=(SELECT intent_id FROM attempts WHERE txid=NEW.parent_txid)
   AND NOT EXISTS(SELECT 1 FROM native_replacement_cancellations x WHERE x.draft_sequence=r.critical_sequence)
   AND NOT EXISTS(SELECT 1 FROM native_replacement_members m WHERE m.draft_sequence=r.critical_sequence)
 ) THEN RAISE EXCEPTION 'native_replacement_draft_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
UPDATE deployment SET schema_version=21;
COMMIT;
