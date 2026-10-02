#!/usr/bin/env python3
"""Exercise retention with real restic in disposable local storage, never off-host."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--restic', required=True)
parser.add_argument('--report', type=Path)
args = parser.parse_args()
assert Path(args.restic).is_absolute()
os.umask(0o077)
spec = importlib.util.spec_from_file_location('retention', Path(__file__).resolve().parents[1] / 'deploy/postgres-retention.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='ecx-retention-') as temporary:
    root = Path(temporary)
    repository, password, payload = (root / name for name in ('repository', 'password', 'payload'))
    repository.write_text(str(root / 'restic'))
    password.write_text('disposable-local-retention-acceptance')
    payload.write_text('disposable test content')
    common = [args.restic, '--repository-file', str(repository), '--password-file', str(password)]
    def run(*command):
        return subprocess.run([*common, *command], check=True, capture_output=True, text=True).stdout
    run('init')
    fingerprint = 'a' * 64
    for sequence in [99, 1, 2, 3, 4]:
        year, hour = ('2020', 1) if sequence == 99 else ('2026', sequence)
        run('backup', '--time', f'{year}-10-01 {hour:02}:00:00', '--tag', 'ecx-bridge-critical',
            '--tag', 'deployment:' + fingerprint, '--tag', 'sequence:' + str(sequence), str(payload))
    run('backup', '--tag', 'ecx-bridge-critical', '--tag', 'deployment:' + 'b' * 64, '--tag', 'sequence:1', str(payload))
    before = json.loads(run('snapshots', '--json'))
    preview = module.retain(args.restic, repository, password, fingerprint)
    assert json.loads(run('snapshots', '--json')) == before
    applied = module.retain(args.restic, repository, password, fingerprint, True)
    after = json.loads(run('snapshots', '--json'))
    assert any('sequence:99' in item.get('tags', []) and 'deployment:' + fingerprint in item['tags'] for item in after)
    assert any('deployment:' + 'b' * 64 in item.get('tags', []) for item in after)
    assert len(after) < len(before) and preview['snapshotsSelectedForRemoval'] > 0
    run('check')
    report = dict(realRestic=True, localDisposableRepository=True, previewDidNotDelete=True,
                  highestSequenceOlderTimestampRetained=True, otherDeploymentPreserved=True,
                  repositoryCheckPassed=True, preview=preview, applied=applied, offHostAcceptance=False)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
