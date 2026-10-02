-- Existing bound instructions may already have been shown. Preserve that fact;
-- new instructions stay hidden until explicit admission/backup checks pass.
ALTER TABLE orders ADD COLUMN instruction_issued INTEGER NOT NULL DEFAULT 0 CHECK(instruction_issued IN(0,1));
-- @statement
UPDATE orders SET instruction_issued=1 WHERE instruction IS NOT NULL;
-- @statement
CREATE TRIGGER immutable_instruction BEFORE UPDATE OF instruction,instruction_sequence ON orders WHEN OLD.instruction IS NOT NULL AND (NEW.instruction IS NOT OLD.instruction OR NEW.instruction_sequence IS NOT OLD.instruction_sequence) BEGIN SELECT RAISE(ABORT,'immutable_instruction'); END;
-- @statement
CREATE TRIGGER irreversible_instruction_issue BEFORE UPDATE OF instruction_issued ON orders WHEN NEW.instruction_issued<OLD.instruction_issued OR (NEW.instruction_issued=1 AND NEW.instruction IS NULL) BEGIN SELECT RAISE(ABORT,'invalid_instruction_issue'); END;
-- @statement
CREATE TABLE native_allocations(order_id TEXT PRIMARY KEY REFERENCES orders(id), label TEXT NOT NULL UNIQUE, critical_sequence INTEGER NOT NULL CHECK(critical_sequence>0));
-- @statement
CREATE TRIGGER immutable_native_allocation_update BEFORE UPDATE ON native_allocations BEGIN SELECT RAISE(ABORT,'immutable_native_allocation'); END;
-- @statement
CREATE TRIGGER immutable_native_allocation_delete BEFORE DELETE ON native_allocations BEGIN SELECT RAISE(ABORT,'immutable_native_allocation'); END;
-- @statement
UPDATE deployment SET schema_version=8,paused=1,pause_reason='migration_requires_reconciliation';
