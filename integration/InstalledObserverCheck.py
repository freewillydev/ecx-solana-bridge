#!/usr/bin/env python3
"""Ubuntu observation-only installation/reinstall/reboot acceptance. Run as root.

No signer, chain send, financial mutation or production activation. The baseline
contains hashes, never configuration contents or ledger rows.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('--capture', action='store_true')
    args = parser.parse_args()
    assert os.geteuid() == 0, 'root required for protected configuration hashes'
    env = dict(os.environ, PGHOST='/run/ecx-postgres', PGPORT='29436',
               PGUSER='postgres', PGDATABASE='ecx_bridge')

    def sql(query):
        result = subprocess.run(['runuser', '-u', 'postgres', '--', 'psql',
            '-XqAt', '-v', 'ON_ERROR_STOP=1', '-c', query], env=env,
            capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, 'installed PostgreSQL query failed'
        return result.stdout.strip()

    def status(path):
        try:
            with urllib.request.urlopen('http://127.0.0.1:8080/' + path, timeout=10) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    for service in ('postgres', 'worker', 'web', 'node'):
        subprocess.run(['systemctl', 'is-active', '--quiet',
            'ecx-bridge-' + service], check=True, timeout=10)
    assert status('healthz') == 200 and status('readyz') == 503
    assert not Path('/etc/ecx-bridge/signer.json').exists()
    helper = json.loads(Path('/etc/ecx-bridge/helper.json').read_text())
    assert helper.get('signer_path') is None
    assert sql('SHOW listen_addresses;') == '', 'PostgreSQL must not listen on TCP'
    assert sql("SELECT bool_and(NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole) FROM pg_roles WHERE rolname IN ('ecx_worker','ecx_read');") == 't'
    assert sql("SELECT has_table_privilege('ecx_read','deployment','SELECT') AND NOT has_table_privilege('ecx_read','deployment','UPDATE');") == 't'
    assert sql('SELECT schema_version FROM deployment;') == '18'
    assert sql('SELECT paused FROM deployment;') == '1'
    assert sql('SELECT count(*) FROM scan_origins;') == '3', 'wait for initial history scans'
    assert sql('SELECT count(*) FROM scan_health WHERE last_success IS NOT NULL AND last_error IS NULL;') == '3', 'wait for healthy scans'
    mutable = {'audit', 'checkpoints', 'custody_check', 'scan_health', 'operating_clock',
               'chain_events', 'observation_evidence'}
    tables = sql("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;").splitlines()
    hashes = {}
    for table in tables:
        if table not in mutable:
            identifier = '"' + table.replace('"', '""') + '"'
            projection = "to_jsonb(t)-'pause_reason'" if table == 'deployment' else 'to_jsonb(t)'
            rows = sql('SELECT (' + projection + ')::text FROM public.' + identifier + ' t ORDER BY (' + projection + ')::text;')
            hashes[table] = hashlib.sha256(rows.encode()).hexdigest()
    configs = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
               for p in sorted(Path('/etc/ecx-bridge').iterdir()) if p.is_file()}
    state = {'releaseId': Path('/opt/ecx-bridge/current').resolve().name,
             'criticalSequence': sql('SELECT critical_sequence FROM deployment;'),
             'configurationHashes': configs, 'durableTableHashes': hashes}
    if args.capture:
        with args.baseline.open('x') as output:
            os.chmod(args.baseline, 0o600)
            json.dump(state, output, indent=2)
    else:
        assert json.loads(args.baseline.read_text()) == state, 'durable installation state changed'
    print(json.dumps({'releaseId': state['releaseId'], 'healthStatus': 200,
        'readyStatus': 503, 'observationOnly': True, 'signerAbsent': True,
        'privatePostgres': True, 'restrictedRoles': True,
        'configurationFiles': len(configs), 'durableTables': len(hashes),
        'criticalSequence': int(state['criticalSequence']),
        'baselineMatched': not args.capture}))


if __name__ == '__main__':
    main()
