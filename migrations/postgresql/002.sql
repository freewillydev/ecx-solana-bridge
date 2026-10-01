-- Permit unchanged fields in Opaleye full-row updates; retain all value-change guards.
BEGIN;

CREATE OR REPLACE FUNCTION trg_immutable_order() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.id IS DISTINCT FROM OLD.id OR NEW.capability_hash IS DISTINCT FROM OLD.capability_hash OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key OR NEW.request_hash IS DISTINCT FROM OLD.request_hash OR NEW.request_json IS DISTINCT FROM OLD.request_json OR NEW.quote_json IS DISTINCT FROM OLD.quote_json OR NEW.policy_json IS DISTINCT FROM OLD.policy_json OR NEW.deadline IS DISTINCT FROM OLD.deadline OR NEW.grace_deadline IS DISTINCT FROM OLD.grace_deadline) THEN RAISE EXCEPTION 'immutable_order' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_signed_bytes() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.txid IS DISTINCT FROM OLD.txid OR NEW.intent_id IS DISTINCT FROM OLD.intent_id OR NEW.signed_bytes IS DISTINCT FROM OLD.signed_bytes OR NEW.policy_json IS DISTINCT FROM OLD.policy_json OR NEW.fee_limit IS DISTINCT FROM OLD.fee_limit) THEN RAISE EXCEPTION 'immutable_attempt' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_preparation_policy() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.intent_id IS DISTINCT FROM OLD.intent_id OR NEW.generation IS DISTINCT FROM OLD.generation OR NEW.policy_json IS DISTINCT FROM OLD.policy_json) THEN RAISE EXCEPTION 'immutable_preparation' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_preparation_draft() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.draft_json IS DISTINCT FROM OLD.draft_json) AND (OLD.draft_json IS NOT NULL) THEN RAISE EXCEPTION 'immutable_preparation_draft' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_preparation_retirement() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.retired_txid IS DISTINCT FROM OLD.retired_txid) AND (OLD.retired_txid IS NOT NULL) THEN RAISE EXCEPTION 'immutable_preparation_retirement' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_attempt_generation() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.preparation_generation IS DISTINCT FROM OLD.preparation_generation) THEN RAISE EXCEPTION 'immutable_attempt' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_operating_reservation() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.order_id IS DISTINCT FROM OLD.order_id OR NEW.kind IS DISTINCT FROM OLD.kind OR NEW.asset IS DISTINCT FROM OLD.asset OR NEW.amount IS DISTINCT FROM OLD.amount) THEN RAISE EXCEPTION 'immutable_operating_reservation' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_instruction() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.instruction IS DISTINCT FROM OLD.instruction OR NEW.instruction_sequence IS DISTINCT FROM OLD.instruction_sequence) AND (OLD.instruction IS NOT NULL AND (NEW.instruction IS DISTINCT FROM OLD.instruction OR NEW.instruction_sequence IS DISTINCT FROM OLD.instruction_sequence)) THEN RAISE EXCEPTION 'immutable_instruction' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_irreversible_instruction_issue() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.instruction_issued IS DISTINCT FROM OLD.instruction_issued) AND (NEW.instruction_issued<OLD.instruction_issued OR (NEW.instruction_issued=1 AND NEW.instruction IS NULL)) THEN RAISE EXCEPTION 'invalid_instruction_issue' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_immutable_preparation_cancellation() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.intent_id IS DISTINCT FROM OLD.intent_id OR NEW.generation IS DISTINCT FROM OLD.generation OR NEW.reason IS DISTINCT FROM OLD.reason OR NEW.cleanup_json IS DISTINCT FROM OLD.cleanup_json OR NEW.critical_sequence IS DISTINCT FROM OLD.critical_sequence) THEN RAISE EXCEPTION 'immutable_preparation_cancellation' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_irreversible_preparation_cleanup() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.completed IS DISTINCT FROM OLD.completed) AND (NEW.completed<OLD.completed) THEN RAISE EXCEPTION 'irreversible_preparation_cleanup' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_irreversible_preparation_cancellation() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.cancelled IS DISTINCT FROM OLD.cancelled) AND (NEW.cancelled<OLD.cancelled OR (NEW.cancelled=1 AND (NEW.retired_txid IS NOT NULL OR NOT EXISTS(SELECT 1 FROM preparation_cancellations c WHERE c.intent_id=NEW.intent_id AND c.generation=NEW.generation AND c.completed=1) OR EXISTS(SELECT 1 FROM attempts a WHERE a.intent_id=NEW.intent_id AND a.preparation_generation=NEW.generation)))) THEN RAISE EXCEPTION 'invalid_preparation_cancellation' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

CREATE OR REPLACE FUNCTION trg_cancelled_preparation_draft() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF (NEW.draft_json IS DISTINCT FROM OLD.draft_json) AND (EXISTS(SELECT 1 FROM preparation_cancellations c WHERE c.intent_id=NEW.intent_id AND c.generation=NEW.generation)) THEN RAISE EXCEPTION 'preparation_cancellation_pending' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;

COMMIT;
