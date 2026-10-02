#!/usr/bin/env python3
"""Real-profile CLI fence refusal before any chain call; disposable PostgreSQL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('config')
parser.add_argument('--binary', required=True)
parser.add_argument('--report')
parser.add_argument('--migrations', type=Path, help='reviewed installed PostgreSQL migration directory')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
binary = str(Path(args.binary).resolve(strict=True))
database = 'ecx_fence_runtime_' + uuid.uuid4().hex
environment = dict(os.environ, PGDATABASE=database)


def run(*command, expected_error=None):
    result = subprocess.run(command, env=environment, capture_output=True,
                            text=True, timeout=30)
    if expected_error:
        assert result.returncode != 0
        assert json.loads(result.stdout) == {'error': expected_error}
    elif result.returncode:
        raise RuntimeError('Fence runtime subprocess failed: ' + Path(command[0]).name)
    return result.stdout


run('createdb', '--template=template0', database)
try:
    for number in range(1, 5):
        run('psql', '-Xq', '-v', 'ON_ERROR_STOP=1', '-f',
            str((args.migrations or root / 'migrations/postgresql') / f'{number:03}.sql'))
    with tempfile.TemporaryDirectory(prefix='ecx-fence-runtime-') as folder:
        directory = Path(folder)
        configuration = json.loads(Path(args.config).read_text())
        assert configuration['profile'] in {'L2LSignetDevnet', 'ECXBetanetDevnet'}
        assert not configuration['backupRequired']
        configuration['deploymentId'] = 'ecx-fence-runtime-contract'
        configuration['customerSocket'] = str(directory / 'customer.sock')
        configuration['adminSocket'] = str(directory / 'admin.sock')
        config = directory / 'config.json'
        config.write_text(json.dumps(configuration))
        config.chmod(0o600)
        environment['ECX_WORKER_FENCE_DIR'] = str(directory / 'fence')
        run(binary, 'postgres-init', str(config))
        run(binary, 'postgres-test-worker', str(config),
            expected_error='worker_fence_not_initialized')
        # Database-only rollback fixture. No instruction, signature or chain
        # response is created or approximated by the two sequence updates.
        run('psql', '-Xq', '-v', 'ON_ERROR_STOP=1', '-c',
            'UPDATE deployment SET critical_sequence=1;')
        run(binary, 'postgres-init-worker-fence', str(config))
        watermark = directory / 'fence/sequence.json'
        digest = hashlib.sha256(watermark.read_bytes()).hexdigest()
        run(binary, 'postgres-init-worker-fence', str(config),
            expected_error='worker_fence_already_initialized')
        run('psql', '-Xq', '-v', 'ON_ERROR_STOP=1', '-c',
            'UPDATE deployment SET critical_sequence=0;')
        before = run('psql', '-XqAt', '-c',
                     'SELECT count(*) FROM audit;')
        run(binary, 'postgres-test-worker', str(config),
            expected_error='stale_ledger_below_worker_fence')
        run(binary, 'test-worker', str(config),
            expected_error='stale_ledger_below_worker_fence')
        run(binary, 'scan', str(config), expected_error='postgres_operator_api_required')
        assert before == run('psql', '-XqAt', '-c',
                             'SELECT count(*) FROM audit;')
        assert hashlib.sha256(watermark.read_bytes()).hexdigest() == digest
        configuration['deploymentId'] = 'different-fence-identity'
        config.write_text(json.dumps(configuration))
        run(binary, 'postgres-test-worker', str(config),
            expected_error='worker_fence_identity_mismatch')
        configuration['deploymentId'] = 'ecx-fence-runtime-contract'
        config.write_text(json.dumps(configuration))
        run('psql', '-Xq', '-v', 'ON_ERROR_STOP=1', '-c',
            'UPDATE deployment SET critical_sequence=1;')
        run(binary, 'postgres-retire-worker', str(config))
        retired = hashlib.sha256(watermark.read_bytes()).hexdigest()
        run(binary, 'postgres-test-worker', str(config),
            expected_error='worker_fence_retired')
        run(binary, 'postgres-init-worker-fence', str(config),
            expected_error='worker_fence_already_initialized')
        assert hashlib.sha256(watermark.read_bytes()).hexdigest() == retired
        assert not (directory / 'customer.sock').exists()
        assert not (directory / 'admin.sock').exists()
        report = dict(actualProfile=configuration['profile'],
                      missingFenceRefused=True, firstInitializationPassed=True,
                      repeatedInitializationRefused=True,
                      staleDatabaseRefusedBeforeStartupMutation=True,
                      workerAliasFenced=True, legacyDirectLedgerCommandDisabled=True,
                      differentIdentityRefused=True, watermarkPreserved=True,
                      stoppedWorkerRetirementPassed=True,
                      retiredWorkerRefused=True, retirementCannotBeReinitialized=True,
                      apiNeverOpened=True, chainCalls=0, signedOrSent=False,
                      liveLedgerModified=False, independentHostFencing=False)
        print(json.dumps(report))
        if args.report:
            Path(args.report).write_text(json.dumps(report, indent=2) + '\n')
finally:
    run('dropdb', database)
