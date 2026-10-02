#!/usr/bin/env python3
"""Paused dedicated Signet/Devnet installation preservation check; run as root.

Capture while stopped, reinstall the same release, then compare while stopped.
Print only hashes/counts; never configuration, keys or financial rows.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('--capture', action='store_true')
    args = parser.parse_args()
    assert os.geteuid() == 0
    cfg = json.loads(Path('/etc/ecx-bridge/worker.json').read_text())
    assert cfg['profile'] == 'L2LSignetDevnet'
    assert cfg['deploymentId'] == 'fresh-treasury-acceptance'
    assert subprocess.run(['systemctl', 'is-active', '--quiet', 'ecx-bridge-worker']).returncode != 0
    env = dict(os.environ, PGHOST='/run/ecx-postgres', PGPORT='29436', PGDATABASE='ecx_bridge')

    def sql(query):
        result = subprocess.run(['runuser', '-u', 'postgres', '--', 'psql', '-XqAt',
            '-v', 'ON_ERROR_STOP=1', '-c', query], env=env, capture_output=True,
            text=True, timeout=30)
        assert result.returncode == 0, 'Private database query failed'
        return result.stdout.strip()

    assert sql('SELECT paused FROM deployment;') == '1'
    assert sql("SELECT count(*) FROM orders WHERE status <> 'Paid';") == '0'
    assert sql('SELECT count(*) FROM orders;') == '2'
    assert sql('SHOW listen_addresses;') == ''
    assert sql("SELECT bool_and(NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole) FROM pg_roles WHERE rolname IN ('ecx_worker','ecx_read');") == 't'
    owner = pwd.getpwnam('ecx-worker').pw_uid
    for p in (Path('/etc/ecx-bridge/signer.json'), Path('/var/lib/ecx-bridge/fence'),
              Path('/var/lib/ecx-bridge/fence/sequence.json')):
        assert not p.is_symlink() and p.stat().st_uid == owner and p.stat().st_mode & 0o077 == 0
    fence = json.loads(Path('/var/lib/ecx-bridge/fence/sequence.json').read_text())
    assert fence['fingerprint'] == sql('SELECT fingerprint FROM deployment;')
    assert fence['sequence'] == int(sql('SELECT critical_sequence FROM deployment;'))
    assert not fence.get('retired', False)
    mutable = {'audit', 'checkpoints', 'custody_check', 'scan_health', 'operating_clock',
               'chain_events', 'observation_evidence'}
    hashes = {}
    for table in sql("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;").splitlines():
        if table in mutable:
            continue
        identifier = '"' + table.replace('"', '""') + '"'
        projection = "to_jsonb(t)-'pause_reason'" if table == 'deployment' else 'to_jsonb(t)'
        rows = sql('SELECT (' + projection + ')::text FROM public.' + identifier + ' t ORDER BY (' + projection + ')::text;')
        hashes[table] = hashlib.sha256(rows.encode()).hexdigest()
    configs = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
               for p in sorted(Path('/etc/ecx-bridge').iterdir()) if p.is_file()}
    state = dict(releaseId=Path('/opt/ecx-bridge/current').resolve().name,
                 criticalSequence=fence['sequence'], configurationHashes=configs,
                 durableTableHashes=hashes, fence=fence)
    if args.capture:
        with args.baseline.open('x') as output:
            os.chmod(args.baseline, 0o600)
            json.dump(state, output)
    else:
        assert json.loads(args.baseline.read_text()) == state, 'Installation changed durable state'
    print(json.dumps(dict(releaseId=state['releaseId'], durableTables=len(hashes),
        configurationFiles=len(configs), criticalSequence=fence['sequence'],
        baselineMatched=not args.capture, signerPrivate=True, fenceVerified=True,
        publicRelease=False)))


if __name__ == '__main__':
    main()
