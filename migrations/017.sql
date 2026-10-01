-- A signed replacement consumes one immutable operator draft. Every member
-- belongs to the existing intent and keeps its original maximum fee hold.
CREATE TABLE native_replacement_members(draft_sequence INTEGER PRIMARY KEY REFERENCES native_replacement_drafts(critical_sequence), txid TEXT NOT NULL UNIQUE REFERENCES attempts(txid), critical_sequence INTEGER NOT NULL UNIQUE CHECK(critical_sequence>draft_sequence));
-- @statement
CREATE TRIGGER native_replacement_member_binding BEFORE INSERT ON native_replacement_members WHEN NOT EXISTS(SELECT 1 FROM native_replacement_drafts d JOIN attempts parent ON parent.txid=d.parent_txid JOIN attempts child ON child.txid=NEW.txid JOIN intents i ON i.id=parent.intent_id WHERE parent.intent_id=child.intent_id AND parent.preparation_generation=child.preparation_generation AND parent.state='broadcast_intent' AND child.state='signed' AND child.fee_limit=parent.fee_limit AND child.txid<>parent.txid AND i.chain='Native' AND i.resolved=0 AND d.critical_sequence=NEW.draft_sequence AND NOT EXISTS(SELECT 1 FROM native_replacement_cancellations x WHERE x.draft_sequence=d.critical_sequence)) BEGIN SELECT RAISE(ABORT,'native_replacement_member_binding'); END;
-- @statement
CREATE TRIGGER immutable_native_replacement_member_update BEFORE UPDATE ON native_replacement_members BEGIN SELECT RAISE(ABORT,'immutable_native_replacement_member'); END;
-- @statement
CREATE TRIGGER immutable_native_replacement_member_delete BEFORE DELETE ON native_replacement_members BEGIN SELECT RAISE(ABORT,'immutable_native_replacement_member'); END;
-- @statement
CREATE TRIGGER native_replacement_cancel_unsigned BEFORE INSERT ON native_replacement_cancellations WHEN EXISTS(SELECT 1 FROM native_replacement_members m WHERE m.draft_sequence=NEW.draft_sequence) BEGIN SELECT RAISE(ABORT,'native_replacement_already_signed'); END;
-- @statement
DROP TRIGGER native_replacement_draft_binding;
-- @statement
CREATE TRIGGER native_replacement_draft_binding BEFORE INSERT ON native_replacement_drafts WHEN NOT EXISTS(SELECT 1 FROM attempts a JOIN intents i ON i.id=a.intent_id JOIN obligations o ON o.id=i.obligation_id JOIN deposits d ON d.id=o.deposit_id JOIN fee_reservations f ON f.intent_id=i.id WHERE a.txid=NEW.parent_txid AND a.state='broadcast_intent' AND i.chain='Native' AND i.resolved=0 AND o.status='paying' AND d.eligible=1 AND f.asset='Native' AND f.released=0 AND f.amount>=a.fee_limit AND NEW.fee<=a.fee_limit) OR EXISTS(SELECT 1 FROM native_replacement_drafts r JOIN attempts a ON a.txid=r.parent_txid WHERE a.intent_id=(SELECT intent_id FROM attempts WHERE txid=NEW.parent_txid) AND NOT EXISTS(SELECT 1 FROM native_replacement_cancellations x WHERE x.draft_sequence=r.critical_sequence) AND NOT EXISTS(SELECT 1 FROM native_replacement_members m WHERE m.draft_sequence=r.critical_sequence)) BEGIN SELECT RAISE(ABORT,'native_replacement_draft_binding'); END;
-- @statement
CREATE TRIGGER custody_native_replacement_member AFTER INSERT ON native_replacement_members BEGIN UPDATE custody_check SET revision=revision+1; END;
-- @statement
UPDATE deployment SET schema_version=17,paused=1,pause_reason='migration_requires_reconciliation';
