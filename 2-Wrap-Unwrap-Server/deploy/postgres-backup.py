#!/usr/bin/env python3
"""Exact-snapshot private ledger archive; never acknowledges remote durability."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import time


class Snapshot:
    # This separate read-only transaction pins pg_dump's MVCC snapshot. It does
    # not hold the worker capability, deployment row lock or a signing transaction.
    def __init__(self, username, env=None):
        self.process = subprocess.Popen(
            ['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '--username=' + username],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.buffer = b''

    def query(self, query):
        self.process.stdin.write((query + '\n').encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 90
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while b'\n' not in self.buffer:
                if not selector.select(max(0, deadline-time.monotonic())):
                    raise ValueError('Snapshot query timed out')
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise ValueError('Snapshot query failed')
                self.buffer += data
                if len(self.buffer) > 1024*1024:
                    raise ValueError('Snapshot metadata exceeds limit')
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write(b'ROLLBACK;\n\\q\n')
                self.process.stdin.flush()
                self.process.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()

    def table_digest(self, table):
        # Sorted JSONB rows preserve duplicates and every column without loading
        # a whole table into Python memory. The non-JSON terminator cannot collide
        # with a row. Use the same exported read-only transaction as pg_dump.
        identifier = '"' + table.replace('"', '""') + '"'
        command = ('SELECT to_jsonb(t)::text FROM public.' + identifier +
                   ' t ORDER BY to_jsonb(t)::text COLLATE "C";\n\\echo ECX_TABLE_END\n')
        self.process.stdin.write(command.encode())
        self.process.stdin.flush()
        digest = hashlib.sha256()
        deadline = time.monotonic() + 90
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while True:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    if line == b'ECX_TABLE_END':
                        return digest.hexdigest()
                    if not line.startswith(b'{'):
                        raise ValueError('Invalid table digest stream')
                    digest.update(line + b'\n')
                if not selector.select(max(0, deadline-time.monotonic())):
                    raise ValueError('Table digest timed out')
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise ValueError('Table digest failed')
                self.buffer += data
                if len(self.buffer) > 16*1024*1024:
                    raise ValueError('Ledger row exceeds digest limit')


def table_hashes(session, tables):
    return {table: session.table_digest(table) for table in sorted(tables)}


def inspect_snapshot(session):
    metadata = session.query("""BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
      SET LOCAL timezone='UTC';
      SET LOCAL statement_timeout='60s';
      SET LOCAL idle_in_transaction_session_timeout='6min';
      SELECT json_build_object('snapshot',pg_export_snapshot(),
        'deployment',(SELECT to_jsonb(d) FROM deployment d WHERE singleton=1),
        'tables',(SELECT json_agg(tablename ORDER BY tablename) FROM pg_tables WHERE schemaname='public'));""")
    deployment = metadata.get('deployment')
    if not deployment or deployment.get('schema_version') != 18:
        raise ValueError('Unsupported or uninitialized ledger')
    snapshot = metadata['snapshot']
    if not re.fullmatch(r'[0-9A-Fa-f-]+', snapshot):
        raise ValueError('Invalid exported snapshot')
    counts = {}
    for table in metadata['tables']:
        identifier = '"' + table.replace('"', '""') + '"'
        counts[table] = session.query('SELECT count(*) FROM public.' + identifier + ';')
    return snapshot, deployment, counts


def create_backup(directory, username='ecx_read'):
    directory = Path(directory)
    if not directory.is_absolute() or directory.is_symlink():
        raise ValueError('Unsafe backup directory')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    name = 'ledger-' + str(time.time_ns())
    pending = directory / (name + '.pending')
    finished = directory / (name + '.dump')
    session = Snapshot(username)
    try:
        snapshot, deployment, counts = inspect_snapshot(session)
        hashes = table_hashes(session, counts)
        with pending.open('xb') as output:
            pending.chmod(0o600)
            subprocess.run(['pg_dump', '--username=' + username, '--format=custom',
                '--no-owner', '--no-privileges', '--snapshot=' + snapshot],
                stdout=output, stderr=subprocess.DEVNULL, check=True, timeout=300)
            output.flush()
            os.fsync(output.fileno())
    finally:
        session.close()
    subprocess.run(['pg_restore', '--list', str(pending)], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True, timeout=60)
    with pending.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    pending.rename(finished)
    manifest = {'format': 1, 'archive': finished.name, 'sha256': digest,
                'deployment': deployment, 'tableCounts': counts, 'tableHashes': hashes,
                'remoteDurabilityAcknowledged': False}
    manifest_path = directory / (name + '.json')
    with manifest_path.open('x') as output:
        manifest_path.chmod(0o600)
        json.dump(manifest, output, sort_keys=True)
        output.flush()
        os.fsync(output.fileno())
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    return manifest_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', default='/var/lib/ecx-bridge/private/backups')
    parser.add_argument('--username', default='ecx_read')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        create_backup(args.directory, args.username)
    except (ValueError, OSError, subprocess.SubprocessError):
        raise SystemExit('PostgreSQL backup failed; incomplete material retained privately')
    print('Private exact-snapshot backup created; remote durability is not acknowledged')


if __name__ == '__main__':
    main()
