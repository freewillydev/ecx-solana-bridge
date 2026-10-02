#!/usr/bin/env python3
"""Restore the retired dedicated test fixture on a clean installed Ubuntu guest.

Requires an explicitly reviewed private handoff journal. Restores no source fence
or service overrides. Starts observation mode only; no paying resume or chain send.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import subprocess
import sys
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('state', type=Path)
parser.add_argument('installer', type=Path)
args = parser.parse_args()
assert os.geteuid() == 0
sys.dont_write_bytecode = True
state = args.state.resolve(strict=True)
assert not state.is_symlink() and state.stat().st_mode & 0o077 == 0
handoff = json.loads((state / 'handoff.json').read_text())
assert handoff['format'] == 1 and handoff['sourceFence']['retired']
assert handoff['sourcePayingWorkerRefused'] and handoff['sourceServicesRetirementCondition']
manifest = json.loads((state / 'manifest.json').read_text())
assert manifest == handoff['archiveManifest']
for name in ('ledger.dump', 'private-state.tar.gz'):
    path = state / name
    assert path.is_file() and not path.is_symlink()
    assert hashlib.sha256(path.read_bytes()).hexdigest() == manifest['files'][name]
current = Path('/opt/ecx-bridge/current').resolve(strict=True)
sys.path.insert(0, str(current / 'deploy'))
import install
import postgres
assert install.verify(current) == handoff['sourceRelease']
assert not Path('/etc/ecx-bridge/worker.json').exists()
assert not Path('/etc/ecx-bridge/signer.json').exists()
assert not Path('/var/lib/ecx-bridge/fence/sequence.json').exists()
assert not Path('/var/lib/ecx-node/signet').exists()
for unit in ('ecx-bridge-worker', 'ecx-bridge-web', 'ecx-bridge-node'):
    assert subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode != 0
setup = state / 'setup'
setup.mkdir(mode=0o700)
node = pwd.getpwnam('ecx-node')
wallet_files = 0
with tarfile.open(state / 'private-state.tar.gz') as archive:
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        assert not path.is_absolute() and '..' not in path.parts
        if member.name in ['etc/ecx-bridge/'+name for name in ('worker.json','helper.json','signer.json','interface.json')]:
            assert member.isfile() and member.size <= 32768
            target = setup / path.name
            with target.open('xb') as output:
                os.chmod(target, 0o600)
                output.write(archive.extractfile(member).read())
        elif member.name.startswith('var/lib/ecx-node/signet/wallets/'):
            assert member.isdir() or member.isfile(), 'Redirected wallet storage refused'
            target = Path('/') / member.name
            # Clean-node ancestry is asserted above; never extract archive links.
            parents = [target] if member.isdir() else [target.parent]
            for parent in parents:
                parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if member.isfile():
                assert member.size <= 16*1024*1024
                with target.open('xb') as output:
                    os.chmod(target, 0o600)
                    output.write(archive.extractfile(member).read())
                wallet_files += member.name.endswith('/wallet.dat')
assert wallet_files == 3
for path in (Path('/var/lib/ecx-node/signet'), *Path('/var/lib/ecx-node/signet').rglob('*')):
    os.chown(path, node.pw_uid, node.pw_gid)
    path.chmod(0o700 if path.is_dir() else 0o600)
cfg = json.loads((setup / 'worker.json').read_text())
assert cfg['profile'] == 'L2LSignetDevnet' and cfg['deploymentId'] == 'fresh-treasury-acceptance'
assert cfg['custodyOwner'] == '6vKbKHaYS393gQdjKysZFuyvn6cZ5p4vSwK2kMsQFuZY'
assert not cfg['backupRequired']
env = dict(os.environ, PGHOST='/run/ecx-postgres', PGPORT='29436', PGDATABASE='ecx_bridge')

def run(*command, **kwargs):
    result = subprocess.run(command, env=env, capture_output=True, timeout=180, **kwargs)
    assert result.returncode == 0, 'Restore failed: ' + Path(command[0]).name
    return result.stdout.decode().strip()


def sql(query):
    return run('runuser', '-u', 'postgres', '--', 'psql', '-XqAt', '-v', 'ON_ERROR_STOP=1', '-c', query)

# Initialize the clean cluster and restricted roles without supplying a config;
# this cannot initialize a paying host fence or start a chain worker.
postgres.install(current, Path('/etc/ecx-bridge/worker.json'), install.mkdir, install.keep_file)
assert sql('SELECT count(*) FROM deployment;') == '0'
assert sql('SELECT count(*) FROM orders;') == '0'
run('runuser', '-u', 'postgres', '--', 'dropdb', 'ecx_bridge')
run('runuser', '-u', 'postgres', '--', 'createdb', '--template=template0', 'ecx_bridge')
with (state / 'ledger.dump').open('rb') as source:
    run('runuser', '-u', 'postgres', '--', 'pg_restore', '--exit-on-error',
        '--single-transaction', '--dbname=ecx_bridge', stdin=source)
for table, digest in handoff['tableHashes'].items():
    assert table.isidentifier()
    rows = sql('SELECT to_jsonb(t)::text FROM public."'+table+'" t ORDER BY to_jsonb(t)::text;')
    assert hashlib.sha256(rows.encode()).hexdigest() == digest, 'Restored ledger rows differ'
assert sql('SELECT fingerprint FROM deployment;') == handoff['sourceFence']['fingerprint']
assert int(sql('SELECT critical_sequence FROM deployment;')) == handoff['sourceFence']['sequence']
assert sql('SELECT paused FROM deployment;') == '1'
# Reinstallation validates the restored signer, initializes a fresh destination
# fence at the reviewed restored sequence, loads the restored real native wallet,
# and enables the observer. Source overrides and source fence are never copied.
with (state / 'installation.log').open('xb') as log:
    result = subprocess.run(['sh', str(args.installer.resolve(strict=True)), '--with-signet',
        '--config-dir', str(setup), '--port', '8090'], stdout=log, stderr=log, timeout=180)
    assert result.returncode == 0, 'Observer installation failed; inspect private log'
# The customer acceptance client has a separately owned tester wallet. Its
# database was restored above; load it explicitly, never create a replacement.
run('runuser', '-u', 'ecx-node', '--', str(current / 'bin/bitcoin-cli'),
    '-datadir=/var/lib/ecx-node', '-conf=/etc/ecx-node.conf',
    'loadwallet', 'ecx-bridge-tester', 'true')
fence = json.loads(Path('/var/lib/ecx-bridge/fence/sequence.json').read_text())
assert not fence['retired'] and fence['sequence'] == handoff['sourceFence']['sequence']
assert fence['fingerprint'] == handoff['sourceFence']['fingerprint']
command = subprocess.check_output(['systemctl', 'show', 'ecx-bridge-worker', '--property=ExecStart', '--value'], text=True)
assert 'postgres-api' in command and 'test-worker' not in command
report = dict(freshUbuntuGuest=True, verifiedRetiredSource=True, sourceFenceNotRestored=True,
    sourceOverridesNotRestored=True, archiveDigestsVerified=True, allLedgerRowsMatchBeforeStartup=True,
    ledgerTablesCompared=len(handoff['tableHashes']), nativeWalletDatabasesRestored=wallet_files,
    configuredCustodySignerValidated=True, newDestinationFenceAtReviewedSequence=True,
    criticalSequence=fence['sequence'], observationOnly=True, payingResumeVerified=False,
    chainFinalityAndReconciliationVerified=False, offHostDurabilityVerified=False)
(state / 'restore-evidence.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report))
