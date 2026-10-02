#!/usr/bin/env python3
"""Replay one historical test snapshot against the actual public chains.

Only an isolated copy is opened by the application. Its reconcile command reads
both chains and cannot sign, broadcast or allocate a receipt. This is a scoped
acceptance check, not a backup selection, key restoration or resume tool.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess


ORDER = "478c5de1dfce591148344e21ff60ececb60267585a5ad647a8a8b155286e7aae"
SOURCE = "3dArKVRqpyuXLNfcUXzsfyfA29ZoPKqoZXmkoBXETez8WYnCec8tB4bfGMgn5wHKG1V6vF8neYVCM33KY7vf2rik"
PAYOUT = "235bf2ba1cfe20852a8d19c234759f4e6ef0c493fdc17824521be7864939a0ad"
FINGERPRINT = "027929d80f528c8da4766560c2597c3971960bd47b4fc7c9f7648c0eba5996f8"
TABLES = (
    "orders", "events", "deposits", "obligations", "postings", "intents", "attempts",
    "reservations", "fee_reservations", "preparations", "preparation_cancellations",
    "solana_expiries", "solana_retry_approvals", "treasury_allocations", "treasury_spends",
    "order_cost_limits", "operating_reservations", "operating_costs", "native_allocations",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read_database(path):
    return sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)


def financial(path):
    with read_database(path) as db:
        result = {}
        for table in TABLES:
            columns = [row[1] for row in db.execute("PRAGMA table_info(" + table + ")")
                       if table != "deposits" or row[1] not in ("anchor", "confirmations", "eligible")]
            result[table] = db.execute("SELECT rowid," + ",".join(columns)
                                       + " FROM " + table + " ORDER BY rowid").fetchall()
        return result


def write_private(path, value):
    with path.open("x") as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, indent=2)
        stream.write("\n")


def fingerprint_file(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("config", "snapshot", "binary", "work-dir", "evidence"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    live = Path(config["dbPath"])
    require(config["profile"] == "L2LSignetDevnet" and not config["backupRequired"], "public test only")
    require(args.snapshot.is_file() and not os.path.samefile(args.snapshot, live), "use the historical snapshot")
    require(not args.work_dir.exists() and not args.evidence.exists(), "output already exists; inspect it instead")
    initial_live = financial(live)
    with read_database(live) as db:
        require(db.execute("SELECT schema_version,critical_sequence,fingerprint FROM deployment").fetchall()
                == [(10, 31, FINGERPRINT)], "unexpected live deployment")
        require(db.execute("SELECT status FROM orders WHERE id=?", (ORDER,)).fetchall() == [("Paid",)], "payout not complete")
        require(db.execute("SELECT state FROM attempts WHERE txid=?", (PAYOUT,)).fetchall() == [("settled",)], "payout not settled")
        require(db.execute("SELECT COUNT(*) FROM intents WHERE resolved=0").fetchone() == (0,), "live payments pending")
    with read_database(args.snapshot) as db:
        require(db.execute("SELECT schema_version,critical_sequence,fingerprint FROM deployment").fetchall()
                == [(10, 27, FINGERPRINT)], "unexpected historical snapshot")
        require(db.execute("SELECT COUNT(*) FROM orders").fetchone() == (7,), "unexpected old order count")
        require(db.execute("SELECT COUNT(*) FROM orders WHERE id=?", (ORDER,)).fetchone() == (0,), "snapshot already knows this order")
        require(db.execute("SELECT COUNT(*) FROM deposits WHERE id=?", ("solana:" + SOURCE,)).fetchone() == (0,), "snapshot already knows this receipt")
        require(db.execute("SELECT COUNT(*) FROM attempts WHERE txid=?", (PAYOUT,)).fetchone() == (0,), "snapshot already knows this payout")
        require(db.execute("SELECT COUNT(*) FROM intents WHERE resolved=0").fetchone() == (0,), "old snapshot has pending payments")
    original_hash = fingerprint_file(args.snapshot)
    args.work_dir.mkdir(mode=0o700, parents=False)
    clone = args.work_dir / "ledger.sqlite"
    with read_database(args.snapshot) as source, sqlite3.connect(clone) as destination:
        source.backup(destination)
    os.chmod(clone, 0o600)
    copied = financial(clone)
    require(copied == financial(args.snapshot), "snapshot copy differs")
    # The one-shot reconcile mode never opens either server socket. Preserve
    # every chain/key/transport setting and change only the isolated ledger.
    isolated_config = dict(config, dbPath=str(clone.resolve()))
    configuration = args.work_dir / "config.json"
    write_private(configuration, isolated_config)
    reports = []
    first_financial = None
    for label in ("initial-replay", "reopened-replay"):
        print(json.dumps({"stage": label}), flush=True)
        # This mode only observes and checks custody; it does not reconstruct
        # locks, settle attempts, start a worker, sign or send on either chain.
        process = subprocess.run([str(args.binary), "reconcile", str(configuration)],
                                 capture_output=True, text=True, timeout=240)
        write_private(args.work_dir / (label + ".json"),
                      {"exitCode": process.returncode, "stdout": process.stdout, "stderr": process.stderr})
        require(process.returncode == 0, "reconcile failed; inspect the private diagnostic")
        custody = json.loads(process.stdout)
        require(custody["lastError"] == "chain_observations_require_review"
                and custody["checkedRevision"] is None and custody["report"] is None, "stale snapshot was not quarantined")
        with read_database(clone) as db:
            health = db.execute("SELECT chain,last_error FROM scan_health ORDER BY chain").fetchall()
            require(health == [("Native", None), ("Solana", None), ("SolanaOperating", None)], "real scan failed")
            reviews = db.execute("SELECT chain,event_id,kind FROM chain_events WHERE needs_review=1 ORDER BY chain,event_id").fetchall()
            require(reviews == [("Native", PAYOUT, "outgoing")], "unknown payout not retained for review")
            receipt = db.execute("SELECT order_id,asset,amount,allocated FROM deposits WHERE id=?", ("solana:" + SOURCE,)).fetchall()
            require(receipt == [(None, "Wrapped", 10000, 0)], "lost order binding was invented or receipt spent")
            require(db.execute("SELECT COUNT(*) FROM obligations WHERE deposit_id=?", ("solana:" + SOURCE,)).fetchone() == (0,), "unknown receipt acquired an obligation")
            require(db.execute("SELECT SUM(delta) FROM postings WHERE asset='Wrapped' AND account='unallocated'").fetchone() == (10000,), "unmatched funds not retained")
            require(db.execute("SELECT paused,critical_sequence FROM deployment").fetchall() == [(1, 27)], "recovery changed authorization")
            require(db.execute("SELECT COUNT(*) FROM attempts").fetchone() == (6,), "recovery created an attempt")
        after = financial(clone)
        for table in TABLES:
            require(after[table][:len(copied[table])] == copied[table], "prior financial/binding row changed: " + table)
            expected = {"events": 1, "deposits": 1, "postings": 2}.get(table, 0)
            require(len(after[table]) - len(copied[table]) == expected, "unexpected financial mutation: " + table)
        if first_financial is not None:
            require(after == first_financial, "replay duplicated or changed financial rows")
        first_financial = after
        reports.append({"pass": label, "custody": custody, "review": reviews,
                        "unmatchedReceipt": {"transaction": SOURCE, "units": "10000", "asset": "Wrapped",
                                             "order": None, "allocated": False, "obligationCreated": False},
                        "paused": True, "criticalSequence": 27, "savedAttempts": 6,
                        "priorFinancialAndBindingRowsPreserved": True})
    require(financial(live) == initial_live, "live financial records changed")
    require(fingerprint_file(args.snapshot) == original_hash, "original snapshot changed")
    evidence = {"network": "public L2L Signet / Solana Devnet", "scope": "isolated stale snapshot replay with real chain reads",
                "schema": 10, "snapshotSequence": 27, "currentSequence": 31,
                "missingOrder": ORDER, "missingPayout": PAYOUT,
                "snapshotSha256": original_hash, "applicationSha256": fingerprint_file(args.binary),
                "passes": reports, "liveFinancialRowsUnchanged": True, "originalSnapshotUnchanged": True,
                "reopenedFinancialReplayUnchanged": True, "signedOrSent": False,
                "finishedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "limitations": "One old snapshot missing a subsequently completed redemption. No keys or remote backups were restored; no signer fencing, operator resume, destination reorg or release installation was accepted."}
    with args.evidence.open("x") as stream:
        json.dump(evidence, stream, indent=2)
        stream.write("\n")
    print(json.dumps({"complete": True, "oldSnapshotQuarantined": True, "replayUnchanged": True,
                      "liveFinancialRowsUnchanged": True, "signedOrSent": False}), flush=True)


if __name__ == "__main__":
    main()
