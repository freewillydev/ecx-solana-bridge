#!/usr/bin/env python3
"""Retire and archive the dedicated reviewed Signet/Devnet fixture.

Root-only test handoff. Retains original data; disables source services. No chain
send or key deletion. A retired host cannot be reactivated by fence initialization.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--signed-native-fixture', action='store_true',
                    help='Retire the exact reviewed five-order signed-native checkpoint')
args = parser.parse_args()
assert os.geteuid() == 0
sys.dont_write_bytecode = True
current = Path('/opt/ecx-bridge/current').resolve(strict=True)
sys.path.insert(0, str(current / 'deploy'))
from install import verify
from upgrade import Upgrade
assert verify(current) == current.name
cfg = json.loads(Path('/etc/ecx-bridge/worker.json').read_text())
assert cfg['deploymentId'] == 'fresh-treasury-acceptance'
assert cfg['profile'] == 'L2LSignetDevnet' and not cfg['backupRequired']
assert cfg['custodyOwner'] == '6vKbKHaYS393gQdjKysZFuyvn6cZ5p4vSwK2kMsQFuZY'
output = Path('/var/lib/ecx-bridge/private/installed-handoff.json')
assert not output.exists(), 'Existing handoff: inspect retained journal, do not repeat blindly'
env = dict(os.environ, PGHOST='/run/ecx-postgres', PGPORT='29436', PGDATABASE='ecx_bridge')

def run(*args):
    result = subprocess.run(args, env=env, capture_output=True, timeout=180)
    assert result.returncode == 0, 'Handoff failed: ' + Path(args[0]).name
    return result.stdout.decode().strip()


def sql(query):
    return run('runuser', '-u', 'postgres', '--', 'psql', '-XqAt', '-v',
               'ON_ERROR_STOP=1', '-c', query)

if args.signed_native_fixture:
    order = '6632ca65986747e3cd135735ca23d1d0e6420f6b7fed43161a851543e188c49a'
    txid = 'f4aa18204d8c5d4dad583f0638887a5e7d0b3c84169226dccd4148539d6c8013'
    assert sql("SELECT count(*) FROM orders;") == '5'
    assert sql("SELECT count(*) FROM orders WHERE status='Paid';") == '2'
    assert sql("SELECT count(*) FROM orders WHERE status='ExpiredUnfunded';") == '2'
    assert sql("SELECT count(*) FROM orders WHERE id='" + order + "' AND status='Paying';") == '1'
    assert sql("SELECT count(*) FROM attempts;") == '3'
    assert sql("SELECT count(*) FROM attempts WHERE state='settled';") == '2'
    assert sql("SELECT count(*) FROM attempts WHERE txid='" + txid + "' AND intent_id='convert:" + order + "' AND state='signed' AND critical_sequence IS NULL;") == '1'
    # Hash locally without emitting custody transaction bytes.
    saved = sql("SELECT signed_bytes FROM attempts WHERE txid='" + txid + "';")
    assert hashlib.sha256(saved.encode()).hexdigest() == '51ac16fd2efb5eb5ccbfbee548c8e62f19af6bff2b9e7a17691da8f1c4eb71d1'
    del saved
    assert sql("SELECT count(*) FROM fee_reservations WHERE intent_id='convert:" + order + "' AND released=0;") == '1'
    assert sql("SELECT count(*) FROM reservations WHERE order_id='" + order + "' AND phase='payment';") == '1'
    assert sql('SELECT critical_sequence FROM deployment;') == '12'
else:
    assert sql('SELECT count(*) FROM orders;') == '2'
    assert sql("SELECT count(*) FROM orders WHERE status <> 'Paid';") == '0'
    assert sql("SELECT count(*) FROM attempts WHERE state <> 'settled';") == '0'
units = ['ecx-bridge-worker.service', 'ecx-bridge-web.service',
         'ecx-bridge-backup.timer', 'ecx-bridge-node.service']
run('systemctl', 'disable', '--now', *units)
run('systemctl', 'stop', 'ecx-bridge-backup.service')
# Preserve managed definitions and add a persistent source-only start barrier.
# Destination restoration must never copy these source retirement drop-ins.
marker = Path('/var/lib/ecx-bridge/source-retired')
with marker.open('x') as saved:
    os.chmod(marker, 0o600)
    saved.write('Dedicated public-test custody handed off; source services retired\n')
    saved.flush()
    os.fsync(saved.fileno())
for unit in units:
    directory = Path('/etc/systemd/system') / (unit + '.d')
    directory.mkdir(mode=0o755, exist_ok=True)
    dropin = directory / 'handoff.conf'
    with dropin.open('x') as saved:
        saved.write('[Unit]\nConditionPathExists=!/var/lib/ecx-bridge/source-retired\n')
run('systemctl', 'daemon-reload')
run('runuser', '-u', 'ecx-worker', '--', 'env', 'PGUSER=ecx_worker',
    'ECX_WORKER_FENCE_DIR=/var/lib/ecx-bridge/fence', str(current / 'bin/ecx-bridge'),
    'postgres-retire-worker', '/etc/ecx-bridge/worker.json')
fence = json.loads(Path('/var/lib/ecx-bridge/fence/sequence.json').read_text())
assert fence['retired'] and fence['sequence'] == int(sql('SELECT critical_sequence FROM deployment;'))
refused = subprocess.run(['runuser', '-u', 'ecx-worker', '--', 'env',
    'PGUSER=ecx_worker', 'ECX_WORKER_FENCE_DIR=/var/lib/ecx-bridge/fence',
    str(current / 'bin/ecx-bridge'), 'postgres-test-worker', '/etc/ecx-bridge/worker.json'],
    env=env, capture_output=True, text=True, timeout=30)
assert refused.returncode != 0 and json.loads(refused.stdout) == {'error': 'worker_fence_retired'}
upgrade = Upgrade(current, current, Path('/opt/ecx-bridge/current'), verify, run)
upgrade.prepare()
tables = sql("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;").splitlines()
hashes = {}
for table in tables:
    identifier = '"' + table.replace('"', '""') + '"'
    rows = sql('SELECT to_jsonb(t)::text FROM public.' + identifier + ' t ORDER BY to_jsonb(t)::text;')
    hashes[table] = hashlib.sha256(rows.encode()).hexdigest()
manifest = json.loads((upgrade.backup / 'manifest.json').read_text())
report = dict(format=1, backupDirectory=str(upgrade.backup), sourceRelease=current.name,
    sourceFence=fence, archiveManifest=manifest, tableHashes=hashes,
    sourcePayingWorkerRefused=True, sourceServicesDisabled=True,
    sourceServicesRetirementCondition=True, publicRelease=False)
with output.open('x') as saved:
    os.chmod(output, 0o600)
    json.dump(report, saved, indent=2)
    saved.flush()
    os.fsync(saved.fileno())
print(json.dumps({'sourceRetired': True, 'directPayingStartRefused': True,
    'sourceServicesDisabled': True, 'ledgerTables': len(hashes),
    'criticalSequence': fence['sequence'], 'privateHandoffJournal': str(output)}))
