-- Fixed final DDL in the same transaction as staging and Opaleye conversion.
-- The evaluator verifies rows, installs these constraints, then records version 22.
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM deployment WHERE singleton=1 AND schema_version=2200 AND paused=1)
 THEN RAISE EXCEPTION 'payment_root_migration_not_staged'; END IF;
END $$;
ALTER TABLE intents ALTER COLUMN phase SET NOT NULL;
ALTER TABLE orders ALTER COLUMN admission_state SET NOT NULL;
ALTER TABLE orders ADD CONSTRAINT order_admission_state CHECK(admission_state IN('Provisioning','AwaitingDeposit','ExpiredUnfunded','NeedsReview'));
ALTER TABLE intents ADD CONSTRAINT payment_phase CHECK(
 (phase IN('ready','cancelled') AND active_generation IS NULL AND settled_txid IS NULL AND settlement_event_id IS NULL)
 OR (phase='active' AND active_generation IS NOT NULL AND active_generation BETWEEN 0 AND 7 AND settled_txid IS NULL AND settlement_event_id IS NULL)
 OR (phase='settled' AND active_generation IS NULL AND settled_txid IS NOT NULL AND settlement_event_id IS NOT NULL));
ALTER TABLE intents ADD CONSTRAINT payment_receipt_funding CHECK((obligation_id IS NULL)=(deposit_id IS NULL));
ALTER TABLE intents ADD CONSTRAINT payment_common_input CHECK(chain='Native' OR common_input IS NULL);
ALTER TABLE obligations ADD CONSTRAINT obligation_receipt_identity UNIQUE(id,deposit_id);
ALTER TABLE intents ADD CONSTRAINT payment_receipt_binding FOREIGN KEY(obligation_id,deposit_id)
 REFERENCES obligations(id,deposit_id) MATCH FULL DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE attempts ADD CONSTRAINT attempt_payment_identity UNIQUE(intent_id,txid);
ALTER TABLE intents ADD CONSTRAINT payment_active_generation FOREIGN KEY(id,active_generation)
 REFERENCES preparations(intent_id,generation) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE intents ADD CONSTRAINT payment_settled_winner FOREIGN KEY(id,settled_txid)
 REFERENCES attempts(intent_id,txid) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE intents ADD CONSTRAINT payment_original_event FOREIGN KEY(settlement_event_id) REFERENCES events(id);
ALTER TABLE intents ADD CONSTRAINT one_payment_principal_event UNIQUE(settlement_event_id);
ALTER TABLE preparations ADD CONSTRAINT preparation_generation_bound CHECK(generation<8);
DROP INDEX one_unresolved_chain_intent;
DROP INDEX one_active_deposit_allocation;
CREATE UNIQUE INDEX one_active_chain_payment ON intents(chain) WHERE phase='active';
CREATE UNIQUE INDEX one_live_receipt_payment ON intents(deposit_id) WHERE phase<>'cancelled';
CREATE INDEX ready_payment_queue ON intents(chain,id) WHERE phase='ready';

CREATE OR REPLACE FUNCTION trg_payment_funding_binding() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE currency TEXT;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_payment_funding' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' AND (NEW.id,NEW.obligation_id,NEW.withdrawal_id,NEW.deposit_id,NEW.chain)
   IS DISTINCT FROM (OLD.id,OLD.obligation_id,OLD.withdrawal_id,OLD.deposit_id,OLD.chain)
 THEN RAISE EXCEPTION 'immutable_payment_funding' USING ERRCODE='23514'; END IF;
 IF NEW.withdrawal_id IS NOT NULL THEN
   SELECT asset INTO currency FROM fee_withdrawals WHERE id=NEW.withdrawal_id;
   IF EXISTS(SELECT 1 FROM fee_withdrawal_cancellations WHERE withdrawal_id=NEW.withdrawal_id) AND NEW.phase<>'cancelled'
   THEN RAISE EXCEPTION 'cancelled_payment_funding' USING ERRCODE='23514'; END IF;
 ELSE SELECT asset INTO currency FROM obligations WHERE id=NEW.obligation_id; END IF;
 IF currency IS NULL OR currency NOT IN('Native','Wrapped') OR NEW.chain<>(CASE WHEN currency='Native' THEN 'Native' ELSE 'Solana' END)
 THEN RAISE EXCEPTION 'payment_funding_chain_mismatch' USING ERRCODE='23514'; END IF;
 IF TG_OP='INSERT' AND NEW.phase<>'ready'
 THEN RAISE EXCEPTION 'new_payment_not_ready' USING ERRCODE='23514'; END IF;
 IF TG_OP='UPDATE' THEN
   IF OLD.common_input IS NOT NULL AND NEW.common_input IS DISTINCT FROM OLD.common_input
     OR OLD.settlement_event_id IS NOT NULL AND NEW.settlement_event_id IS DISTINCT FROM OLD.settlement_event_id
     OR OLD.phase='cancelled' AND NEW IS DISTINCT FROM OLD
     OR OLD.phase='settled' AND NEW.phase<>'settled'
     OR OLD.phase='active' AND NEW.phase='cancelled'
     OR OLD.phase='ready' AND NEW.phase='settled'
     OR OLD.phase='active' AND NEW.phase='active' AND NEW.active_generation IS DISTINCT FROM OLD.active_generation
   THEN RAISE EXCEPTION 'invalid_payment_phase_transition' USING ERRCODE='23514'; END IF;
   IF OLD.phase='settled' AND NEW.settled_txid IS DISTINCT FROM OLD.settled_txid AND NOT EXISTS(
     SELECT 1 FROM native_winner_changes w WHERE w.previous_txid=OLD.settled_txid AND w.winner_txid=NEW.settled_txid
       AND w.critical_sequence=(SELECT MAX(h.critical_sequence) FROM native_winner_changes h JOIN attempts a ON a.txid=h.winner_txid WHERE a.intent_id=NEW.id))
   THEN RAISE EXCEPTION 'payment_winner_change_unproven' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER payment_funding_binding BEFORE INSERT OR UPDATE OR DELETE ON intents FOR EACH ROW EXECUTE FUNCTION trg_payment_funding_binding();

-- Deferred checks see the final state of atomic preparation/settlement/winner
-- changes. They add no authorization path and execute with invoker privileges.
CREATE FUNCTION bridge_validate_payment(subject TEXT) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE p intents%ROWTYPE; original_events BIGINT;
BEGIN
 SELECT * INTO p FROM intents WHERE id=subject;
 IF NOT FOUND THEN RAISE EXCEPTION 'payment_root_missing' USING ERRCODE='23514'; END IF;
 SELECT COUNT(*) INTO original_events FROM attempts a JOIN events e ON e.id='settlement:'||a.txid WHERE a.intent_id=p.id;
 IF p.phase='active' THEN
   IF NOT EXISTS(SELECT 1 FROM preparations g JOIN fee_reservations f ON f.intent_id=g.intent_id
     WHERE g.intent_id=p.id AND g.generation=p.active_generation AND g.retired_txid IS NULL AND g.cancelled=0
       AND f.released=0 AND f.asset=(CASE WHEN p.chain='Native' THEN 'Native' ELSE 'Sol' END))
     OR EXISTS(SELECT 1 FROM preparations g WHERE g.intent_id=p.id AND g.generation>p.active_generation)
   THEN RAISE EXCEPTION 'payment_active_generation_mismatch' USING ERRCODE='23514'; END IF;
 ELSIF p.phase='settled' THEN
   IF NOT EXISTS(SELECT 1 FROM attempts a JOIN fee_reservations f ON f.intent_id=a.intent_id
     WHERE a.intent_id=p.id AND a.txid=p.settled_txid AND a.state='settled' AND f.released=1)
     OR original_events<>1 OR NOT EXISTS(SELECT 1 FROM attempts a JOIN postings j ON j.event_id=p.settlement_event_id
       WHERE a.intent_id=p.id AND p.settlement_event_id='settlement:'||a.txid)
   THEN RAISE EXCEPTION 'payment_settlement_mismatch' USING ERRCODE='23514'; END IF;
 ELSE
   -- Completed unsigned cleanup may retain the fee hold for a later retry.
   -- Cancelling the funding itself must release it; phase does not own capital.
   IF EXISTS(SELECT 1 FROM fee_reservations f WHERE f.intent_id=p.id AND f.released<>1)
     AND (p.phase<>'ready' OR NOT EXISTS(SELECT 1 FROM preparations g JOIN preparation_cancellations c
       ON c.intent_id=g.intent_id AND c.generation=g.generation
       WHERE g.intent_id=p.id AND g.cancelled=1 AND c.completed=1
         AND NOT EXISTS(SELECT 1 FROM preparations later WHERE later.intent_id=p.id AND later.generation>g.generation)))
     OR EXISTS(SELECT 1 FROM preparations g WHERE g.intent_id=p.id AND g.retired_txid IS NULL AND g.cancelled=0
     AND NOT EXISTS(SELECT 1 FROM attempts a WHERE a.intent_id=p.id AND a.preparation_generation=g.generation AND a.state='failed' AND p.chain='Solana'))
     OR EXISTS(SELECT 1 FROM attempts a WHERE a.intent_id=p.id AND a.state IN('signed','broadcast_intent','settled'))
   THEN RAISE EXCEPTION 'inactive_payment_has_live_work' USING ERRCODE='23514', DETAIL=subject; END IF;
 END IF;
 IF p.phase<>'settled' AND original_events<>0
 THEN RAISE EXCEPTION 'unbound_payment_principal_event' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM attempts a WHERE a.intent_id=p.id AND a.state='settled' AND a.txid IS DISTINCT FROM p.settled_txid)
 THEN RAISE EXCEPTION 'payment_winner_mismatch' USING ERRCODE='23514'; END IF;
 IF p.phase='cancelled' AND NOT (
   p.withdrawal_id IS NOT NULL AND EXISTS(SELECT 1 FROM fee_withdrawal_cancellations c WHERE c.withdrawal_id=p.withdrawal_id)
   OR p.obligation_id IS NOT NULL AND EXISTS(SELECT 1 FROM obligations o JOIN obligations r ON r.deposit_id=o.deposit_id
     JOIN intents i ON i.obligation_id=r.id WHERE o.id=p.obligation_id AND o.kind='conversion' AND r.kind='refund' AND i.phase<>'cancelled'))
 THEN RAISE EXCEPTION 'payment_cancellation_unproven' USING ERRCODE='23514'; END IF;
 RETURN true;
END $$;
CREATE FUNCTION trg_payment_consistency() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='intents' THEN PERFORM bridge_validate_payment(NEW.id);
 ELSIF TG_TABLE_NAME='obligations' THEN
   IF NOT EXISTS(SELECT 1 FROM intents WHERE id=NEW.id AND obligation_id=NEW.id)
   THEN RAISE EXCEPTION 'payment_root_missing' USING ERRCODE='23514'; END IF;
   PERFORM bridge_validate_payment(NEW.id);
 ELSIF TG_TABLE_NAME='fee_withdrawals' THEN
   IF NOT EXISTS(SELECT 1 FROM intents WHERE id='fee:'||NEW.id AND withdrawal_id=NEW.id)
   THEN RAISE EXCEPTION 'payment_root_missing' USING ERRCODE='23514'; END IF;
   PERFORM bridge_validate_payment('fee:'||NEW.id);
 ELSE PERFORM bridge_validate_payment(NEW.intent_id); END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER payment_root_consistency AFTER INSERT OR UPDATE ON intents DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_payment_consistency();
CREATE CONSTRAINT TRIGGER payment_obligation_consistency AFTER INSERT OR UPDATE ON obligations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_payment_consistency();
CREATE CONSTRAINT TRIGGER payment_withdrawal_consistency AFTER INSERT OR UPDATE ON fee_withdrawals DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_payment_consistency();
CREATE CONSTRAINT TRIGGER payment_preparation_consistency AFTER INSERT OR UPDATE ON preparations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_payment_consistency();
CREATE CONSTRAINT TRIGGER payment_attempt_consistency AFTER INSERT OR UPDATE ON attempts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_payment_consistency();
CREATE CONSTRAINT TRIGGER payment_fee_consistency AFTER INSERT OR UPDATE ON fee_reservations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_payment_consistency();

CREATE OR REPLACE FUNCTION trg_cancelled_preparation_attempt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM preparations p JOIN intents i ON i.id=p.intent_id WHERE p.intent_id=NEW.intent_id
   AND p.generation=NEW.preparation_generation AND i.phase='active' AND i.active_generation=p.generation AND p.retired_txid IS NULL AND p.cancelled=0)
   OR EXISTS(SELECT 1 FROM preparation_cancellations c WHERE c.intent_id=NEW.intent_id AND c.generation=NEW.preparation_generation)
 THEN RAISE EXCEPTION 'preparation_not_active' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION trg_source_approval_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM obligations o JOIN intents i ON i.obligation_id=o.id JOIN deposits d ON d.id=o.deposit_id
   JOIN source_recovery_state r ON r.deposit_id=d.id JOIN source_recoveries loss ON loss.critical_sequence=NEW.loss_sequence
   WHERE o.id=NEW.obligation_id AND i.phase IN('ready','active') AND r.critical_sequence=NEW.restoration_sequence
     AND loss.deposit_id=d.id AND loss.critical_sequence<r.critical_sequence
     AND loss.evidence_json::jsonb @> jsonb_build_object('reason','source_eligibility_lost','reviewedObligations',
       jsonb_build_array(jsonb_build_object('intent',NEW.obligation_id,'previousStatus',NEW.prior_status,'workHash',NEW.work_hash)))
     AND NOT EXISTS(SELECT 1 FROM source_recovery_approvals a WHERE a.obligation_id=o.id AND a.critical_sequence>=loss.critical_sequence)
     AND ((d.eligible=1 AND r.state='restored' AND r.shortfall=0)
       OR (d.asset='Native' AND d.eligible=0 AND r.state='missing' AND r.shortfall=d.amount
         AND EXISTS(SELECT 1 FROM active_source_loss_covers f WHERE f.deposit_id=d.id AND f.amount=d.amount
           AND f.recovery_sequence<=r.critical_sequence AND NEW.critical_sequence>f.critical_sequence
           AND NEW.proof_json::jsonb @> jsonb_build_object('sourceCover',f.critical_sequence)))))
 THEN RAISE EXCEPTION 'source_approval_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION trg_native_replacement_member_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM native_replacement_drafts d JOIN attempts parent ON parent.txid=d.parent_txid
   JOIN attempts child ON child.txid=NEW.txid JOIN intents i ON i.id=parent.intent_id
   WHERE parent.intent_id=child.intent_id AND parent.preparation_generation=child.preparation_generation
     AND parent.state='broadcast_intent' AND child.state='signed' AND child.fee_limit=parent.fee_limit AND child.txid<>parent.txid
     AND i.chain='Native' AND i.phase='active' AND i.active_generation=parent.preparation_generation AND d.critical_sequence=NEW.draft_sequence
     AND NOT EXISTS(SELECT 1 FROM native_replacement_cancellations x WHERE x.draft_sequence=d.critical_sequence))
 THEN RAISE EXCEPTION 'native_replacement_member_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION trg_native_winner_change_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM attempts prior JOIN attempts winner ON winner.intent_id=prior.intent_id JOIN intents i ON i.id=prior.intent_id
   WHERE prior.txid=NEW.previous_txid AND winner.txid=NEW.winner_txid AND prior.state='settled' AND prior.observation_json=NEW.previous_observation
     AND winner.state IN('broadcast_intent','review') AND prior.critical_sequence>0 AND winner.critical_sequence>0
     AND prior.preparation_generation=winner.preparation_generation AND prior.fee_limit=winner.fee_limit
     AND i.chain='Native' AND i.phase='settled' AND i.settled_txid=prior.txid)
 THEN RAISE EXCEPTION 'native_winner_change_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION trg_fee_withdrawal_cancellation_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM fee_withdrawals w JOIN intents i ON i.withdrawal_id=w.id
   WHERE w.id=NEW.withdrawal_id AND NEW.critical_sequence>w.critical_sequence AND i.phase='ready'
     AND NOT EXISTS(SELECT 1 FROM attempts a WHERE a.intent_id=i.id)
     AND (NOT EXISTS(SELECT 1 FROM preparations p WHERE p.intent_id=i.id)
       OR (EXISTS(SELECT 1 FROM deployment WHERE singleton=1 AND paused=1)
         AND EXISTS(SELECT 1 FROM fee_reservations f WHERE f.intent_id=i.id AND f.released=1)
         AND NOT EXISTS(SELECT 1 FROM preparations p WHERE p.intent_id=i.id AND
           (p.cancelled<>1 OR p.retired_txid IS NOT NULL OR NOT EXISTS(SELECT 1 FROM preparation_cancellations c
             WHERE c.intent_id=p.intent_id AND c.generation=p.generation AND c.completed=1 AND c.critical_sequence<NEW.critical_sequence))))))
 THEN RAISE EXCEPTION 'fee_withdrawal_cancellation_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION trg_native_replacement_draft_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN fee_reservations f ON f.intent_id=i.id
   LEFT JOIN obligations o ON o.id=i.obligation_id LEFT JOIN deposits d ON d.id=o.deposit_id LEFT JOIN fee_withdrawals w ON w.id=i.withdrawal_id
   WHERE a.txid=NEW.parent_txid AND a.state='broadcast_intent' AND a.critical_sequence>0 AND NEW.critical_sequence>a.critical_sequence
     AND i.chain='Native' AND i.phase='active' AND i.active_generation=a.preparation_generation
     AND f.asset='Native' AND f.released=0 AND f.amount>=a.fee_limit AND NEW.fee<=a.fee_limit
     AND EXISTS(SELECT 1 FROM deployment WHERE singleton=1 AND paused=1)
     AND ((o.id IS NOT NULL AND (d.eligible=1 OR EXISTS(SELECT 1 FROM accounted_source_losses l
       JOIN active_source_loss_covers c ON c.deposit_id=l.deposit_id JOIN source_recovery_approvals r ON r.obligation_id=o.id
       WHERE l.deposit_id=d.id AND c.amount=d.amount AND r.critical_sequence>c.critical_sequence
         AND r.proof_json::jsonb->>'sourceCover'=c.critical_sequence::text))
       AND NOT EXISTS(SELECT 1 FROM source_recoveries loss WHERE loss.deposit_id=d.id
         AND loss.evidence_json::jsonb @> jsonb_build_object('reason','source_eligibility_lost','reviewedObligations',jsonb_build_array(jsonb_build_object('intent',o.id)))
         AND NOT EXISTS(SELECT 1 FROM source_recovery_approvals r WHERE r.obligation_id=o.id AND r.critical_sequence>=loss.critical_sequence)))
       OR (w.asset='Native' AND NOT EXISTS(SELECT 1 FROM fee_withdrawal_cancellations x WHERE x.withdrawal_id=w.id))))
   OR EXISTS(SELECT 1 FROM native_replacement_drafts r JOIN attempts a ON a.txid=r.parent_txid
     WHERE a.intent_id=(SELECT intent_id FROM attempts WHERE txid=NEW.parent_txid)
       AND NOT EXISTS(SELECT 1 FROM native_replacement_cancellations x WHERE x.draft_sequence=r.critical_sequence)
       AND NOT EXISTS(SELECT 1 FROM native_replacement_members m WHERE m.draft_sequence=r.critical_sequence))
 THEN RAISE EXCEPTION 'native_replacement_draft_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
ALTER TABLE intents DROP COLUMN resolved;
ALTER TABLE obligations DROP COLUMN status;
ALTER TABLE orders DROP COLUMN status, DROP COLUMN payout_tx;
-- With execution state moved to the root, every obligation column is immutable
-- funding. There is no legitimate runtime obligation UPDATE or DELETE left.
CREATE FUNCTION trg_immutable_obligation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'immutable_payment_terms' USING ERRCODE='23514'; END $$;
CREATE TRIGGER immutable_obligation BEFORE UPDATE OR DELETE ON obligations FOR EACH ROW EXECUTE FUNCTION trg_immutable_obligation();
