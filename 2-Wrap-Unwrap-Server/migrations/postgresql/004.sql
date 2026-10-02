-- Extend the existing immutable approval journal with an explicit capital-cover
-- resolution. Financial ledger format remains 18; no balances or history change.
BEGIN;
CREATE OR REPLACE FUNCTION trg_source_approval_binding() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM obligations o
    JOIN deposits d ON d.id=o.deposit_id
    JOIN source_recovery_state r ON r.deposit_id=d.id
    JOIN source_recoveries loss ON loss.critical_sequence=NEW.loss_sequence
    WHERE o.id=NEW.obligation_id AND o.status='review'
      AND r.critical_sequence=NEW.restoration_sequence
      AND loss.deposit_id=d.id AND loss.critical_sequence<r.critical_sequence
      AND (
        (d.eligible=1 AND r.state='restored' AND r.shortfall=0)
        OR
        (d.asset='Native' AND d.eligible=0 AND r.state='missing' AND r.shortfall=d.amount
         AND EXISTS (
           SELECT 1 FROM active_source_loss_covers f
           WHERE f.deposit_id=d.id AND f.amount=d.amount
             AND f.recovery_sequence<=r.critical_sequence
             AND NEW.critical_sequence>f.critical_sequence
             AND NEW.proof_json::jsonb @> jsonb_build_object('sourceCover',f.critical_sequence)
         ))
      )
  ) THEN RAISE EXCEPTION 'source_approval_binding' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END
$body$;
COMMIT;
