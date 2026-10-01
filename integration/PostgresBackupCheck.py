#!/usr/bin/env python3
"""Private real-PostgreSQL snapshot/restore contract; no chain clients or workers."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_backup', root / 'deploy/postgres-verify-backup.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', help='Trusted private ledger backup, never an untrusted archive')
    parser.add_argument('--directory', required=True, help='Private absolute test-output directory')
    args = parser.parse_args()
    os.umask(0o077)
    archive, _ = verify.load_archive(args.manifest)
    original = verify.verify_backup(args.manifest)
    database = 'ecx_snapshot_contract_' + uuid.uuid4().hex
    env = dict(os.environ, PGDATABASE='postgres')
    run = subprocess.run
    run(['createdb', '--template=template0', database], env=env, check=True)
    previous = os.environ.get('PGDATABASE')
    try:
        os.environ['PGDATABASE'] = database
        run(['psql', '-Xq', '-v', 'ON_ERROR_STOP=1', '-c',
             'REVOKE ALL ON DATABASE ' + database + ' FROM PUBLIC'], check=True, stdout=subprocess.DEVNULL)
        run(['pg_restore', '--exit-on-error', '--single-transaction', '--no-owner',
             '--no-privileges', '--dbname=' + database, str(archive)], check=True)
        username = os.environ.get('PGUSER') or os.environ['USER']
        mutated = False

        def concurrent_write(command, **kwargs):
            nonlocal mutated
            if command[0] == 'pg_dump':
                run(['psql', '-Xq', '-v', 'ON_ERROR_STOP=1', '-c',
                     "BEGIN; UPDATE deployment SET critical_sequence=critical_sequence+1; "
                     "INSERT INTO audit(action,detail) VALUES('snapshot_contract','isolated database only'); COMMIT;"],
                    check=True, stdout=subprocess.DEVNULL)
                mutated = True
            return run(command, **kwargs)

        # This writes only to the disposable restored copy, after metadata/counts
        # were read but before pg_dump. Missing --snapshot would fail comparison.
        verify.backup.subprocess.run = concurrent_write
        try:
            manifest_path = verify.backup.create_backup(args.directory, username)
        finally:
            verify.backup.subprocess.run = run
        matched = verify.verify_backup(manifest_path)
        if not mutated:
            raise ValueError('Concurrent write was not exercised')
        original_manifest = json.loads(manifest_path.read_text())
        original_manifest['sha256'] = '0'*64
        damaged = Path(args.directory) / 'damaged-manifest.json'
        damaged.write_text(json.dumps(original_manifest))
        try:
            verify.load_archive(damaged)
        except ValueError:
            rejected = True
        else:
            raise ValueError('Damaged checksum accepted')
        print(json.dumps({'originalRestore': original, 'concurrentWriteSnapshotRestore': matched,
                          'concurrentWriteExcluded': True, 'damagedChecksumRejected': rejected,
                          'sourceLedgerModified': False, 'workerStarted': False}, sort_keys=True))
    finally:
        if previous is None:
            os.environ.pop('PGDATABASE', None)
        else:
            os.environ['PGDATABASE'] = previous
        run(['dropdb', database], env=env, check=True)


if __name__ == '__main__':
    main()
