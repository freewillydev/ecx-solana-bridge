-- Past costs have no trustworthy booking time. Count them for a full day from
-- migration rather than guessing that they fall outside the operating window.
CREATE TABLE operating_clock(singleton INTEGER PRIMARY KEY CHECK(singleton=1), last_time INTEGER NOT NULL CHECK(last_time>=0));
-- @statement
INSERT INTO operating_clock VALUES(1,unixepoch());
-- @statement
CREATE TABLE operating_costs(posting_id INTEGER PRIMARY KEY REFERENCES postings(id), recorded_at INTEGER NOT NULL CHECK(recorded_at>=0));
-- @statement
INSERT INTO operating_costs SELECT id,unixepoch() FROM postings WHERE account='operating' AND delta<0;
-- @statement
CREATE INDEX operating_cost_time ON operating_costs(recorded_at);
-- @statement
CREATE TRIGGER immutable_operating_cost_update BEFORE UPDATE ON operating_costs BEGIN SELECT RAISE(ABORT,'immutable_operating_cost'); END;
-- @statement
CREATE TRIGGER immutable_operating_cost_delete BEFORE DELETE ON operating_costs BEGIN SELECT RAISE(ABORT,'immutable_operating_cost'); END;
-- @statement
CREATE TRIGGER record_operating_cost AFTER INSERT ON postings WHEN NEW.account='operating' AND NEW.delta<0 BEGIN UPDATE operating_clock SET last_time=MAX(last_time,unixepoch()); INSERT INTO operating_costs(posting_id,recorded_at) SELECT NEW.id,last_time FROM operating_clock; END;
-- @statement
CREATE TABLE order_cost_limits(order_id TEXT PRIMARY KEY REFERENCES orders(id), native_fee INTEGER NOT NULL CHECK(native_fee>0), solana_fee INTEGER NOT NULL CHECK(solana_fee>0), solana_rent INTEGER NOT NULL CHECK(solana_rent>=0));
-- @statement
CREATE TRIGGER immutable_order_cost_update BEFORE UPDATE ON order_cost_limits BEGIN SELECT RAISE(ABORT,'immutable_order_cost_limits'); END;
-- @statement
CREATE TRIGGER immutable_order_cost_delete BEFORE DELETE ON order_cost_limits BEGIN SELECT RAISE(ABORT,'immutable_order_cost_limits'); END;
-- @statement
CREATE TABLE operating_reservations(order_id TEXT NOT NULL REFERENCES order_cost_limits(order_id), kind TEXT NOT NULL CHECK(kind IN('conversion','refund')), asset TEXT NOT NULL CHECK(asset IN('Native','Sol')), amount INTEGER NOT NULL CHECK(amount>0), phase TEXT NOT NULL CHECK(phase IN('quote','obligation','transferred','released')), PRIMARY KEY(order_id,kind));
-- @statement
CREATE TRIGGER immutable_operating_reservation BEFORE UPDATE OF order_id,kind,asset,amount ON operating_reservations BEGIN SELECT RAISE(ABORT,'immutable_operating_reservation'); END;
-- @statement
CREATE TRIGGER immutable_operating_reservation_delete BEFORE DELETE ON operating_reservations BEGIN SELECT RAISE(ABORT,'immutable_operating_reservation'); END;
-- @statement
UPDATE deployment SET schema_version=7,paused=1,pause_reason='migration_requires_reconciliation';
