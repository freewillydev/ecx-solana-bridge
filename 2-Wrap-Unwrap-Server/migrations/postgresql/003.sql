-- Avoid collision between a SQL alias and PL/pgSQL OLD trigger record.
BEGIN;
CREATE OR REPLACE FUNCTION trg_native_winner_change_binding() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN IF NOT EXISTS(SELECT 1 FROM attempts prior JOIN attempts winner ON winner.intent_id=prior.intent_id JOIN intents i ON i.id=prior.intent_id WHERE prior.txid=NEW.previous_txid AND winner.txid=NEW.winner_txid AND prior.state='settled' AND prior.observation_json=NEW.previous_observation AND winner.state IN('broadcast_intent','review') AND prior.critical_sequence>0 AND winner.critical_sequence>0 AND prior.preparation_generation=winner.preparation_generation AND prior.fee_limit=winner.fee_limit AND i.chain='Native' AND i.resolved=1) THEN RAISE EXCEPTION 'native_winner_change_binding' USING ERRCODE='23514'; END IF; RETURN NEW; END
$body$;
COMMIT;
