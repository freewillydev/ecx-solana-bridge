"""Managed private PostgreSQL installation; no wallet signing or chain sends."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import time

ENV = {"PGHOST": "/run/ecx-postgres", "PGPORT": "29436", "PGDATABASE": "ecx_bridge", "PGUSER": "postgres"}


def run(*args, **kwargs):
    # Do not expose SQL, config contents or copied financial rows on failure.
    result = subprocess.run(args, env=dict(os.environ, **ENV), capture_output=True, **kwargs)
    if result.returncode:
        raise ValueError("PostgreSQL setup failed: " + Path(args[0]).name)
    return result.stdout.decode().strip()


def sql(query, database="ecx_bridge"):
    return run("runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-d", database, input=query.encode())


def install(target, config, mkdir, keep_file, snapshot=None):
    # A stopped legacy deployment must be migrated explicitly, never initialized
    # over. The maintenance importer remains separate from repeat installation.
    legacy = Path("/var/lib/ecx-bridge/private/ledger.sqlite")
    data = Path("/var/lib/ecx-postgres/data")
    if legacy.exists() and not (data / "PG_VERSION").exists() and snapshot is None:
        raise ValueError("Existing SQLite ledger: stop its worker and perform the documented final snapshot/import before PostgreSQL installation")
    if snapshot is not None:
        if subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-worker.service"]).returncode == 0:
            raise ValueError("Stop the old worker before importing its consistent final snapshot")
        snapshot = snapshot.resolve(strict=True)
    mkdir("/var/lib/ecx-postgres", 0o700, "postgres", "postgres")
    mkdir(data, 0o700, "postgres", "postgres")
    for name in ("postgresql.conf", "pg_hba.conf", "pg_ident.conf"):
        keep_file(Path("/etc/ecx-bridge") / name, (target / "deploy" / name).read_bytes(), 0o640, "ecx-worker")
    if not (data / "PG_VERSION").exists():
        run("runuser", "-u", "postgres", "--", "/usr/lib/postgresql/16/bin/initdb", "-D", str(data), "--auth-local=peer", "--auth-host=reject", "--no-instructions")
    elif (data / "PG_VERSION").read_text().strip() != "16":
        raise ValueError("Unsupported PostgreSQL data version; preserve it for a reviewed upgrade")
    keep_file("/etc/systemd/system/ecx-bridge-postgres.service", (target / "deploy/ecx-bridge-postgres.service").read_bytes(), 0o644)
    run("systemctl", "daemon-reload")
    run("systemctl", "enable", "--now", "ecx-bridge-postgres.service")
    for _ in range(30):
        ready = subprocess.run(["runuser", "-u", "postgres", "--", "pg_isready", "-h", ENV["PGHOST"], "-p", ENV["PGPORT"]], capture_output=True)
        if ready.returncode == 0:
            break
        time.sleep(1)
    else:
        raise ValueError("Private PostgreSQL service did not become ready")
    sql("""DO $$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ecx_worker') THEN
        CREATE ROLE ecx_worker LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ecx_read') THEN
        CREATE ROLE ecx_read LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
      END IF;
    END $$;""", "postgres")
    if sql("SELECT count(*) FROM pg_database WHERE datname='ecx_bridge';", "postgres") == "0":
        run("runuser", "-u", "postgres", "--", "createdb", "ecx_bridge")
    if sql("SELECT to_regclass('public.deployment') IS NULL;") == "t":
        run("runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(target / "migrations/postgresql/001.sql"))
    # Fresh schema already includes this correction. Do not rewrite trigger
    # functions during repeat installation while a worker may be paying.
    if sql("SELECT position('IS DISTINCT FROM' in prosrc)>0 FROM pg_proc WHERE proname='trg_immutable_order';") != "t":
        if subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-worker.service"]).returncode == 0:
            raise ValueError("Stop the worker before applying the PostgreSQL trigger correction")
        run("runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(target / "migrations/postgresql/002.sql"))
    sql("""REVOKE ALL ON DATABASE ecx_bridge FROM PUBLIC;
      GRANT CONNECT ON DATABASE ecx_bridge TO ecx_worker,ecx_read;
      REVOKE ALL ON SCHEMA public FROM PUBLIC;
      GRANT USAGE ON SCHEMA public TO ecx_worker,ecx_read;
      GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO ecx_worker;
      GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO ecx_worker;
      GRANT SELECT ON ALL TABLES IN SCHEMA public TO ecx_read;
      GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ecx_read;
      REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
      GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ecx_worker;""")
    if snapshot is not None:
        report = Path("/var/lib/ecx-postgres/import-report.json")
        source_hash = hashlib.sha256(snapshot.read_bytes()).hexdigest()
        digest_file = report.with_suffix(".source-sha256")
        if sql("SELECT count(*) FROM deployment;") == "0":
            with tempfile.TemporaryDirectory(prefix="ecx-pg-import-", dir="/run") as tmp:
                directory = Path(tmp)
                uid = pwd.getpwnam("postgres").pw_uid
                os.chown(directory, uid, -1)
                copy = directory / "snapshot.sqlite"
                shutil.copyfile(snapshot, copy)
                os.chown(copy, uid, -1)
                copy.chmod(0o600)
                run("runuser", "-u", "postgres", "--", "python3", str(target / "scripts/import-legacy-ledger"), str(copy), "--report", str(report))
            digest_file.write_text(source_hash + "\n")
            digest_file.chmod(0o600)
        elif not (report.is_file() and digest_file.is_file() and digest_file.read_text().strip() == source_hash and json.loads(report.read_text()).get("allRecordsMatch")):
            raise ValueError("Nonempty destination does not match this recorded import; do not reimport")
    if config.is_file():
        # Config contains key-file paths, not inline signing material. Give only
        # the maintenance user a short-lived copy for typed initialization.
        with tempfile.TemporaryDirectory(prefix="ecx-pg-init-", dir="/run") as tmp:
            directory = Path(tmp)
            uid = pwd.getpwnam("postgres").pw_uid
            os.chown(directory, uid, -1)
            copy = directory / "worker.json"
            shutil.copyfile(config, copy)
            os.chown(copy, uid, -1)
            copy.chmod(0o600)
            run("runuser", "-u", "postgres", "--", str(target / "bin/ecx-bridge"), "postgres-init", str(copy))
    keep_file("/etc/ecx-bridge/postgres.env", b"PGHOST=/run/ecx-postgres\nPGPORT=29436\nPGDATABASE=ecx_bridge\nPGUSER=ecx_worker\nPGREADUSER=ecx_read\n", 0o640, "ecx-worker")
