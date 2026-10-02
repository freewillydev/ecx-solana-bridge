"""Offline PostgreSQL release upgrades; preserve keys/state and stop on failure."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time

SERVICES = ("ecx-bridge-backup.timer", "ecx-bridge-backup.service",
            "ecx-bridge-web.service", "ecx-bridge-worker.service", "ecx-bridge-node.service")
PG_ENV = {"PGHOST": "/run/ecx-postgres", "PGPORT": "29436", "PGUSER": "postgres", "PGDATABASE": "ecx_bridge"}


def atomic_link(current, target):
    temporary = current.with_name(".current-new")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    temporary.replace(current)
    descriptor = os.open(current.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def managed_files(release):
    result = {Path("/etc/systemd/system") / p.name: p for p in (release / "deploy").glob("ecx-bridge*.service")}
    result.update({Path("/etc/systemd/system") / p.name: p for p in (release / "deploy").glob("ecx-bridge*.timer")})
    result[Path("/etc/apparmor.d/ecx-bridge-bwrap")] = release / "deploy/ecx-bridge-bwrap.apparmor"
    result[Path("/etc/ecx-node.conf")] = release / "deploy/signet.conf"
    return result


class Upgrade:
    def __init__(self, previous, target, current, verify, run):
        self.previous, self.target, self.current = previous, target, current
        self.run = run
        if previous.parent != current.parent / "releases" or verify(previous) != previous.name:
            raise ValueError("Previous release is not an intact managed package")
        # Refuse legacy/version changes rather than guessing a custody migration.
        version = Path("/var/lib/ecx-postgres/data/PG_VERSION")
        if not version.is_file() or version.read_text().strip() != "16":
            raise ValueError("--upgrade requires the existing PostgreSQL 16 deployment; migrate a legacy ledger separately")
        self.old_files = managed_files(previous)
        for destination, source in self.old_files.items():
            if destination.is_symlink() or (destination.exists() and destination.read_bytes() != source.read_bytes()):
                raise ValueError("Managed service/profile changed locally; reconcile it before upgrading: " + str(destination))
        self.backup = None
        self.node_was_active = False

    def metadata(self):
        query = "SELECT json_build_object('schemaVersion',schema_version,'criticalSequence',critical_sequence,'fingerprint',fingerprint)::text FROM deployment;"
        result = subprocess.run(["runuser", "-u", "postgres", "--", "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", query], env=dict(os.environ, **PG_ENV), capture_output=True, check=True)
        rows = result.stdout.decode().splitlines()
        if len(rows) != 1:
            raise ValueError("Upgrade requires one initialized deployment")
        data = json.loads(rows[0])
        if data["schemaVersion"] != 18:
            raise ValueError("Unsupported ledger schema; upgrade requires an explicit migration")
        return data

    def prepare(self):
        self.node_was_active = subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-node.service"]).returncode == 0
        self.run("systemctl", "stop", *SERVICES)
        for unit in SERVICES:
            if subprocess.run(["systemctl", "is-active", "--quiet", unit]).returncode == 0:
                raise ValueError("Service still active; upgrade stopped: " + unit)
        before = self.metadata()
        parent = Path("/var/lib/ecx-bridge/upgrades")
        if parent.is_symlink():
            raise ValueError("Upgrade backup directory cannot be a symlink")
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        parent.chmod(0o700)
        self.backup = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%dT%H%M%SZ-", time.gmtime()), dir=parent))
        archive = self.backup / "ledger.dump"
        with archive.open("xb") as output:
            archive.chmod(0o600)
            subprocess.run(["runuser", "-u", "postgres", "--", "pg_dump", "--format=custom"], env=dict(os.environ, **PG_ENV), stdout=output, stderr=subprocess.PIPE, check=True)
            output.flush()
            os.fsync(output.fileno())
        subprocess.run(["pg_restore", "--list", str(archive)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        if self.metadata() != before:
            raise ValueError("Ledger changed during stopped-worker backup")
        # Node stopped before copying wallet databases. Preserve signing material
        # privately; archives never enter a release or the Git repository.
        with tarfile.open(self.backup / "private-state.tar.gz", "w:gz") as saved:
            for path in (Path("/etc/ecx-bridge"), Path("/etc/ecx-node.conf"), Path("/var/lib/ecx-node/wallets")):
                if path.exists():
                    saved.add(path, arcname=str(path).lstrip("/"))
            for destination in self.old_files:
                if destination.exists():
                    saved.add(destination, arcname=str(destination).lstrip("/"))
            override = Path("/etc/systemd/system/ecx-bridge-worker.service.d")
            if override.exists():
                saved.add(override, arcname=str(override).lstrip("/"))
        state = self.backup / "private-state.tar.gz"
        state.chmod(0o600)
        with state.open("rb") as saved:
            os.fsync(saved.fileno())
        report = dict(before, previousRelease=self.previous.name, targetRelease=self.target.name,
                      files={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (archive, state)})
        journal = self.backup / "manifest.json"
        with journal.open("x") as output:
            journal.chmod(0o600)
            json.dump(report, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        descriptor = os.open(self.backup, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        print("Private upgrade backup:", self.backup)

    def keep_file(self, path, content, mode, group="root", ordinary=None):
        path = Path(path)
        source = self.old_files.get(path)
        if source is None or not path.exists() or path.read_bytes() == content:
            return ordinary(path, content, mode, group)
        if path.is_symlink() or path.read_bytes() != source.read_bytes():
            raise ValueError("Managed file changed during upgrade: " + str(path))
        descriptor, name = tempfile.mkstemp(prefix=".ecx-upgrade-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                os.fchmod(output.fileno(), mode)
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            Path(name).replace(path)
        finally:
            Path(name).unlink(missing_ok=True)

    def fail(self):
        # Database migrations may already have committed. Do not auto-resume old
        # binaries or restore older financial state over possibly newer decisions.
        self.run("systemctl", "stop", *SERVICES)
        atomic_link(self.current, self.previous)
        print("Upgrade failed; services remain stopped. Previous release selected; inspect backup:", self.backup)
