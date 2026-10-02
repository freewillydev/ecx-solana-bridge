"""Managed private PostgreSQL installation; no wallet signing or chain sends."""
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


def install(target, config, mkdir, keep_file):
    # Historical migration tooling remains at Git revision 6d293a3. Never
    # replace an existing SQLite ledger with an empty PostgreSQL deployment.
    legacy = Path("/var/lib/ecx-bridge/private/ledger.sqlite")
    data = Path("/var/lib/ecx-postgres/data")
    if legacy.exists() and not (data / "PG_VERSION").exists():
        raise ValueError("Existing SQLite ledger: preserve it and migrate separately using the reviewed historical tools before installation")
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
    if sql("SELECT position('attempts prior' in prosrc)>0 FROM pg_proc WHERE proname='trg_native_winner_change_binding';") != "t":
        if subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-worker.service"]).returncode == 0:
            raise ValueError("Stop the worker before applying the PostgreSQL winner-binding correction")
        run("runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(target / "migrations/postgresql/003.sql"))
    if sql("SELECT position('sourceCover' in prosrc)>0 FROM pg_proc WHERE proname='trg_source_approval_binding';") != "t":
        if subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-worker.service"]).returncode == 0:
            raise ValueError("Stop the worker before applying the PostgreSQL covered-source approval migration")
        run("runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(target / "migrations/postgresql/004.sql"))
    if sql("SELECT to_regclass('public.fee_withdrawals') IS NULL;") == "t":
        if subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-worker.service"]).returncode == 0:
            raise ValueError("Stop the worker before applying the PostgreSQL fee-funding migration")
        run("runuser", "-u", "postgres", "--", "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(target / "migrations/postgresql/005.sql"))
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
    # Host-local anti-rollback state is intentionally outside ledger/private
    # backup archives. Upgrades retain it; an old snapshot must never lower it.
    fence = Path("/var/lib/ecx-bridge/fence")
    mkdir(fence, 0o700, "ecx-worker", "ecx-worker")
    keep_file("/etc/ecx-bridge/fence.env", b"ECX_WORKER_FENCE_DIR=/var/lib/ecx-bridge/fence\n", 0o640, "ecx-worker")
    if config.is_file() and not (fence / "sequence.json").exists():
        if subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-worker.service"]).returncode == 0:
            raise ValueError("Stop the worker before first adoption of host-local custody fencing")
        run("runuser", "-u", "ecx-worker", "--", "env", "PGUSER=ecx_worker",
            "ECX_WORKER_FENCE_DIR=" + str(fence), str(target / "bin/ecx-bridge"),
            "postgres-init-worker-fence", str(config))
