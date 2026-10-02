#!/usr/bin/env python3
"""Restore a trusted private backup into an isolated disposable database. No worker."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import pwd
import shutil
import tempfile
import subprocess
import sys
import uuid

# Installed package inventory must remain immutable, including no bytecode files.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('ledger_backup', Path(__file__).with_name('postgres-backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


def load_archive(manifest_path):
    manifest_path = Path(manifest_path).resolve(strict=True)
    if manifest_path.stat().st_size > 1024*1024:
        raise ValueError('Manifest exceeds limit')
    manifest = json.loads(manifest_path.read_text())
    name = manifest.get('archive', '')
    if manifest.get('format') != 1 or not re.fullmatch(r'ledger-[0-9]+\.dump', name):
        raise ValueError('Unsupported manifest')
    archive = manifest_path.parent / name
    if archive.is_symlink() or not archive.is_file():
        raise ValueError('Unsafe archive')
    with archive.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != manifest.get('sha256'):
            raise ValueError('Archive checksum mismatch')
    return archive, manifest


def verify_backup(manifest_path):
    archive, manifest = load_archive(manifest_path)
    database = 'ecx_restore_' + uuid.uuid4().hex
    maintenance = dict(os.environ, PGDATABASE='postgres')
    restored = dict(os.environ, PGDATABASE=database)
    # No source database is altered, and runtime roles receive no CONNECT grant.
    created = False
    session = None
    try:
        subprocess.run(['createdb', '--template=template0', database], env=maintenance,
                       stderr=subprocess.DEVNULL, check=True, timeout=60)
        created = True
        subprocess.run(['psql', '-Xq', '-v', 'ON_ERROR_STOP=1', '-c',
                        'REVOKE ALL ON DATABASE ' + database + ' FROM PUBLIC'],
                       env=restored, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True, timeout=60)
        subprocess.run(['pg_restore', '--exit-on-error', '--single-transaction',
                        '--no-owner', '--no-privileges', '--dbname=' + database, str(archive)],
                       env=restored, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True, timeout=300)
        username = restored.get('PGUSER') or os.environ.get('USER')
        if not username:
            raise ValueError('Explicit restore user required')
        session = backup.Snapshot(username, restored)
        _, deployment, counts = backup.inspect_snapshot(session)
        if deployment != manifest.get('deployment') or counts != manifest.get('tableCounts'):
            raise ValueError('Restored ledger does not match snapshot manifest')
        hashes = manifest.get('tableHashes')
        if hashes is not None:
            if (not isinstance(hashes, dict) or set(hashes) != set(counts) or
                any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                    for value in hashes.values())):
                raise ValueError('Invalid table-content manifest')
            if backup.table_hashes(session, counts) != hashes:
                raise ValueError('Restored ledger row contents do not match snapshot manifest')
        return {'archiveChecksumVerified': True, 'deploymentMatches': True,
                'tableCountsMatch': True, 'tables': len(counts),
                'tableContentsMatch': True if hashes is not None else None,
                'remoteDurabilityAcknowledged': False, 'workerStarted': False}
    finally:
        if session is not None:
            session.close()
        if created:
            # Deliberately avoid --force: unexpected concurrent use needs review.
            subprocess.run(['dropdb', database], env=maintenance, stderr=subprocess.DEVNULL,
                           check=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest')
    args = parser.parse_args()
    try:
        if os.geteuid() == 0:
            # PostgreSQL's peer-authenticated owner cannot read the worker's
            # private directory. Copy only this verified ledger archive/manifest
            # into a temporary owner-only directory; never copy signer material.
            archive, _ = load_archive(args.manifest)
            account = pwd.getpwnam('postgres')
            with tempfile.TemporaryDirectory(prefix='ecx-restore-', dir='/run') as stage:
                directory = Path(stage)
                directory.chmod(0o700)
                os.chown(directory, account.pw_uid, account.pw_gid)
                for source in (archive, Path(args.manifest).resolve(strict=True)):
                    target = directory / source.name
                    shutil.copyfile(source, target)
                    target.chmod(0o600)
                    os.chown(target, account.pw_uid, account.pw_gid)
                env = dict(os.environ, PGHOST='/run/ecx-postgres', PGPORT='29436',
                           PGUSER='postgres', PGDATABASE='postgres')
                subprocess.run(['runuser', '-u', 'postgres', '--', 'python3',
                                str(Path(__file__).resolve()), str(directory / Path(args.manifest).name)],
                               env=env, check=True, timeout=420)
            return
        result = verify_backup(args.manifest)
    except (ValueError, OSError, subprocess.SubprocessError):
        raise SystemExit('Private backup verification failed; no worker was started')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
