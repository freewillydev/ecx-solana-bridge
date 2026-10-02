#!/usr/bin/env python3
"""Preview or apply deployment-scoped restic retention outside the payment loop."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess

spec = importlib.util.spec_from_file_location('remote_backup', Path(__file__).with_name('postgres-remote-backup.py'))
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


def retain(restic, repository_file, password_file, fingerprint, apply=False):
    if not Path(restic).is_absolute() or not re.fullmatch('[0-9a-f]{64}', fingerprint):
        raise ValueError('Invalid retention identity')
    common = ['--repository-file', str(repository_file), '--password-file', str(password_file)]
    selector = 'ecx-bridge-critical,deployment:' + fingerprint
    snapshots = json.loads(remote.run_json(restic, [*common, 'snapshots', '--json', '--tag', selector]))
    if not isinstance(snapshots, list) or not snapshots:
        raise ValueError('No recovery snapshots; retention refused')
    sequences = []
    for snapshot in snapshots:
        tags = snapshot.get('tags', [])
        if not {'ecx-bridge-critical', 'deployment:' + fingerprint} <= set(tags):
            raise ValueError('Snapshot identity mismatch')
        values = [tag[9:] for tag in tags if tag.startswith('sequence:')]
        if len(values) != 1 or not re.fullmatch('0|[1-9][0-9]{0,18}', values[0]):
            raise ValueError('Invalid critical sequence')
        if not re.fullmatch('[0-9a-f]{64}', snapshot.get('id', '')):
            raise ValueError('Invalid snapshot identity')
        sequences.append(int(values[0]))
    # Per-backup paths are unique; default path grouping would retain everything.
    # Preserve highest financial sequence independently of wall-clock ordering.
    highest = max(sequences)
    args = [*common, 'forget', '--json', '--tag', selector, '--group-by', '',
            '--keep-last', '2', '--keep-daily', '7', '--keep-weekly', '4',
            '--keep-monthly', '12', '--keep-tag', 'sequence:' + str(highest)]
    args.append('--dry-run')
    result = json.loads(remote.run_json(restic, args))
    if not isinstance(result, list):
        raise ValueError('Invalid retention result')
    known = {snapshot['id']: sequence for snapshot, sequence in zip(snapshots, sequences)}
    remove = [snapshot['id'] for group in result for snapshot in (group.get('remove') or [])]
    if len(remove) != len(set(remove)) or any(sid not in known or known[sid] == highest for sid in remove):
        raise ValueError('Retention plan would remove protected or unknown work')
    if apply and remove:
        # Delete only reviewed IDs, never rerun a policy over newly arriving work.
        remote.run_json(restic, [*common, 'forget', *remove])
    return dict(applied=apply, highestSequenceProtected=highest,
                snapshotsConsidered=len(snapshots),
                snapshotsSelectedForRemoval=sum(len(group.get('remove') or []) for group in result),
                storagePruned=False, workerCoverageAcknowledged=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restic', default='/usr/bin/restic')
    parser.add_argument('--repository-file', required=True)
    parser.add_argument('--password-file', required=True)
    parser.add_argument('--fingerprint', required=True)
    parser.add_argument('--apply', action='store_true', help='Remove selected snapshot metadata; default only previews')
    args = parser.parse_args()
    try:
        remote.remote_repository(args.repository_file)
        remote.private_file(args.password_file)
        print(json.dumps(retain(args.restic, args.repository_file, args.password_file, args.fingerprint, args.apply)))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        raise SystemExit('Retention failed; inspect repository with protected operator access')


if __name__ == '__main__':
    main()
