CREATE TABLE deployment(singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version=1), fingerprint TEXT NOT NULL, critical_sequence INTEGER NOT NULL DEFAULT 0, backup_sequence INTEGER NOT NULL DEFAULT 0, paused INTEGER NOT NULL DEFAULT 1 CHECK(paused IN(0,1)), pause_reason TEXT NOT NULL DEFAULT 'initialization');
-- @statement
CREATE TABLE orders(id TEXT PRIMARY KEY, capability_hash TEXT NOT NULL, idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL, request_json TEXT NOT NULL, quote_json TEXT NOT NULL, policy_json TEXT NOT NULL, status TEXT NOT NULL, deadline INTEGER NOT NULL, grace_deadline INTEGER NOT NULL, instruction TEXT UNIQUE, instruction_sequence INTEGER, payout_tx TEXT, UNIQUE(capability_hash,idempotency_key));
-- @statement
CREATE TRIGGER immutable_order BEFORE UPDATE OF id,capability_hash,idempotency_key,request_hash,request_json,quote_json,policy_json,deadline,grace_deadline ON orders BEGIN SELECT RAISE(ABORT,'immutable_order'); END;
-- @statement
CREATE TABLE events(id TEXT PRIMARY KEY, description TEXT NOT NULL);
-- @statement
CREATE TABLE postings(id INTEGER PRIMARY KEY, event_id TEXT NOT NULL REFERENCES events(id), asset TEXT NOT NULL CHECK(asset IN('Native','Wrapped','Sol')), account TEXT NOT NULL, delta INTEGER NOT NULL CHECK(typeof(delta)='integer' AND delta<>0));
-- @statement
CREATE INDEX posting_balance ON postings(asset,account);
-- @statement
CREATE TRIGGER immutable_posting_update BEFORE UPDATE ON postings BEGIN SELECT RAISE(ABORT,'append_only_journal'); END;
-- @statement
CREATE TRIGGER immutable_posting_delete BEFORE DELETE ON postings BEGIN SELECT RAISE(ABORT,'append_only_journal'); END;
-- @statement
CREATE TABLE reservations(order_id TEXT PRIMARY KEY REFERENCES orders(id), asset TEXT NOT NULL, amount INTEGER NOT NULL CHECK(amount>0), phase TEXT NOT NULL CHECK(phase IN('quote','obligation','payment','released')));
-- @statement
CREATE TABLE deposits(id TEXT PRIMARY KEY, order_id TEXT REFERENCES orders(id), asset TEXT NOT NULL, amount INTEGER NOT NULL CHECK(amount>0), anchor TEXT NOT NULL, first_seen INTEGER NOT NULL, confirmations INTEGER NOT NULL CHECK(confirmations>=0), eligible INTEGER NOT NULL CHECK(eligible IN(0,1)), allocated INTEGER NOT NULL DEFAULT 0 CHECK(allocated IN(0,1)), state TEXT NOT NULL DEFAULT 'observed');
-- @statement
CREATE TABLE obligations(id TEXT PRIMARY KEY, order_id TEXT NOT NULL REFERENCES orders(id), deposit_id TEXT NOT NULL REFERENCES deposits(id), kind TEXT NOT NULL CHECK(kind IN('conversion','refund')), asset TEXT NOT NULL, amount INTEGER NOT NULL CHECK(amount>0), recipient TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN('ready','paying','paid','review','cancelled')));
-- @statement
CREATE UNIQUE INDEX one_conversion ON obligations(order_id) WHERE kind='conversion';
-- @statement
CREATE TABLE intents(id TEXT PRIMARY KEY, obligation_id TEXT NOT NULL UNIQUE REFERENCES obligations(id), chain TEXT NOT NULL CHECK(chain IN('Native','Solana')), common_input TEXT, resolved INTEGER NOT NULL DEFAULT 0 CHECK(resolved IN(0,1)));
-- @statement
CREATE UNIQUE INDEX one_unresolved_chain_intent ON intents(chain) WHERE resolved=0;
-- @statement
CREATE TABLE attempts(txid TEXT PRIMARY KEY, intent_id TEXT NOT NULL REFERENCES intents(id), signed_bytes TEXT NOT NULL, policy_json TEXT NOT NULL, fee_limit INTEGER NOT NULL CHECK(fee_limit>=0), state TEXT NOT NULL CHECK(state IN('signed','broadcast_intent','settled','failed','review')), critical_sequence INTEGER, observation_json TEXT);
-- @statement
CREATE TRIGGER immutable_signed_bytes BEFORE UPDATE OF txid,intent_id,signed_bytes,policy_json,fee_limit ON attempts BEGIN SELECT RAISE(ABORT,'immutable_attempt'); END;
-- @statement
CREATE TABLE checkpoints(chain TEXT PRIMARY KEY, anchor TEXT NOT NULL);
-- @statement
CREATE TABLE audit(id INTEGER PRIMARY KEY, action TEXT NOT NULL, detail TEXT NOT NULL);
-- @statement
CREATE TABLE hints(order_id TEXT NOT NULL REFERENCES orders(id), signature TEXT NOT NULL, PRIMARY KEY(order_id,signature));
-- @statement
CREATE TABLE fee_reservations(intent_id TEXT PRIMARY KEY REFERENCES intents(id), asset TEXT NOT NULL, amount INTEGER NOT NULL CHECK(amount>=0), released INTEGER NOT NULL DEFAULT 0 CHECK(released IN(0,1)));
-- @statement
CREATE UNIQUE INDEX one_active_deposit_allocation ON obligations(deposit_id) WHERE status<>'cancelled';
