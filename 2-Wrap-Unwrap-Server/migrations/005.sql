-- Operator fee funding is separate from customer orders and chain receipts.
BEGIN;
CREATE TABLE fee_withdrawals(
 id TEXT PRIMARY KEY CHECK(id ~ '^[0-9a-f]{64}$'),
 asset TEXT NOT NULL CHECK(asset IN('Native','Wrapped')),
 amount BIGINT NOT NULL CHECK(amount>0),
 recipient TEXT NOT NULL CHECK(length(recipient)>0 AND length(recipient)<=128),
 policy_json TEXT NOT NULL CHECK(bridge_json_valid(policy_json)),
 reason TEXT NOT NULL CHECK(length(trim(reason))>0 AND length(reason)<=512),
 critical_sequence BIGINT NOT NULL UNIQUE CHECK(critical_sequence>0)
);
CREATE TABLE fee_withdrawal_cancellations(
 withdrawal_id TEXT PRIMARY KEY REFERENCES fee_withdrawals(id),
 reason TEXT NOT NULL CHECK(length(trim(reason))>0 AND length(reason)<=512),
 critical_sequence BIGINT NOT NULL UNIQUE CHECK(critical_sequence>0)
);
CREATE FUNCTION trg_immutable_fee_withdrawal() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN RAISE EXCEPTION 'immutable_fee_withdrawal' USING ERRCODE='23514'; END
$body$;
CREATE TRIGGER immutable_fee_withdrawal BEFORE UPDATE OR DELETE ON fee_withdrawals
 FOR EACH ROW EXECUTE FUNCTION trg_immutable_fee_withdrawal();
CREATE TRIGGER immutable_fee_withdrawal_cancellation BEFORE UPDATE OR DELETE ON fee_withdrawal_cancellations
 FOR EACH ROW EXECUTE FUNCTION trg_immutable_fee_withdrawal();
CREATE FUNCTION trg_fee_withdrawal_cancellation_binding() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM fee_withdrawals w WHERE w.id=NEW.withdrawal_id AND NEW.critical_sequence>w.critical_sequence)
 OR EXISTS(SELECT 1 FROM intents WHERE id='fee:'||NEW.withdrawal_id)
 THEN RAISE EXCEPTION 'fee_withdrawal_cancellation_binding' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END
$body$;
CREATE TRIGGER fee_withdrawal_cancellation_binding BEFORE INSERT ON fee_withdrawal_cancellations
 FOR EACH ROW EXECUTE FUNCTION trg_fee_withdrawal_cancellation_binding();
COMMIT;
