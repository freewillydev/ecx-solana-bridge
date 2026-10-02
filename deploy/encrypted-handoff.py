#!/usr/bin/env python3
"""Encrypt a retired test-host handoff with operator-owned restic credentials.

Never retires a host, starts a worker, restores keys into custody or acknowledges
payment backup coverage. Operator escrow is separate from worker ledger uploads.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import shutil
from pathlib import PurePosixPath
import tempfile

spec = importlib.util.spec_from_file_location('remote', Path(__file__).with_name('postgres-remote-backup.py'))
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


def backup_handoff(state, restic, repository, password):
    state = Path(state)
    info = state.lstat()
    if not state.is_absolute() or state.is_symlink() or not state.is_dir() or info.st_mode & 0o077 or info.st_uid not in (0, os.geteuid()) or not Path(restic).is_absolute():
        raise ValueError('Protected handoff directory required')
    names = ('handoff.json', 'manifest.json', 'ledger.dump', 'private-state.tar.gz')
    files = [remote.private_file(state / name) for name in names]
    handoff, manifest = (json.loads(files[i].read_text()) for i in (0, 1))
    fence = handoff['sourceFence']
    fingerprint, sequence = fence['fingerprint'], fence['sequence']
    if handoff['format'] != 1 or not fence['retired'] or not handoff['sourcePayingWorkerRefused'] or not handoff['sourceServicesRetirementCondition'] or not handoff['sourceServicesDisabled']:
        raise ValueError('Reviewed retired source required')
    if not re.fullmatch('[0-9a-f]{64}', fingerprint) or type(sequence) is not int or sequence < 0 or manifest != handoff['archiveManifest'] or manifest['fingerprint'] != fingerprint or manifest['criticalSequence'] != sequence or manifest['schemaVersion'] != 18:
        raise ValueError('Handoff identity mismatch')
    hashes = {}
    for path in files:
        with path.open('rb') as source:
            hashes[path.name] = hashlib.file_digest(source, 'sha256').hexdigest()
    if any(hashes[name] != manifest['files'][name] for name in names[2:]):
        raise ValueError('Handoff archive digest mismatch')
    common = ['--repository-file', str(repository), '--password-file', str(password)]
    tags = ['ecx-bridge-handoff', 'deployment:' + fingerprint, 'sequence:' + str(sequence)]
    command = [*common, 'backup', '--json']
    for tag in tags:
        command.extend(['--tag', tag])
    command.extend(map(str, files))
    summaries = [r for r in map(json.loads, remote.run_json(restic, command).splitlines()) if r.get('message_type') == 'summary']
    if len(summaries) != 1 or not re.fullmatch('[0-9a-f]{64}', summaries[0].get('snapshot_id', '')):
        raise ValueError('Handoff acknowledgment missing')
    snapshot = summaries[0]['snapshot_id']
    metadata = json.loads(remote.run_json(restic, [*common, 'cat', 'snapshot', snapshot]))
    if sorted(metadata['paths']) != sorted(map(str, files)) or not set(tags) <= set(metadata.get('tags', [])):
        raise ValueError('Handoff snapshot association mismatch')
    with tempfile.TemporaryDirectory(prefix='ecx-handoff-restore-') as directory:
        subprocess.run([restic, *common, 'restore', snapshot, '--target', directory], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        for path in files:
            restored = Path(directory) / str(path).lstrip('/')
            with restored.open('rb') as source:
                if hashlib.file_digest(source, 'sha256').hexdigest() != hashes[path.name]:
                    raise ValueError('Encrypted restored handoff differs')
    return dict(format=1, fingerprint=fingerprint, criticalSequence=sequence, snapshotId=snapshot,
                fileHashes=hashes, snapshotAssociationVerified=True, restoredArchiveHashesVerified=True,
                custodyKeysRestoredIntoService=False, workerCoverageAcknowledged=False, offHostDurabilityVerified=False)


def restore_handoff(receipt_file, destination, restic, repository, password):
    receipt = json.loads(remote.private_file(receipt_file).read_text())
    destination = Path(destination)
    if not destination.is_absolute() or destination.exists() or destination.is_symlink() or not Path(restic).is_absolute():
        raise ValueError('Fresh absolute staging destination required')
    snapshot = receipt['snapshotId']
    fingerprint, sequence = receipt['fingerprint'], receipt['criticalSequence']
    names = {'handoff.json', 'manifest.json', 'ledger.dump', 'private-state.tar.gz'}
    hashes = receipt['fileHashes']
    if receipt['format'] != 1 or set(hashes) != names or not re.fullmatch('[0-9a-f]{64}', snapshot) or not re.fullmatch('[0-9a-f]{64}', fingerprint) or type(sequence) is not int or sequence < 0 or any(not re.fullmatch('[0-9a-f]{64}', value) for value in hashes.values()):
        raise ValueError('Invalid trusted handoff receipt')
    common = ['--repository-file', str(repository), '--password-file', str(password)]
    metadata = json.loads(remote.run_json(restic, [*common, 'cat', 'snapshot', snapshot]))
    paths = [PurePosixPath(path) for path in metadata['paths']]
    tags = {'ecx-bridge-handoff', 'deployment:' + fingerprint, 'sequence:' + str(sequence)}
    if len(paths) != 4 or {path.name for path in paths} != names or len({path.parent for path in paths}) != 1 or any(not path.is_absolute() or '..' in path.parts for path in paths) or not tags <= set(metadata.get('tags', [])):
        raise ValueError('Remote handoff association mismatch')
    with tempfile.TemporaryDirectory(prefix='ecx-verified-handoff-', dir=destination.parent) as temporary:
        root = Path(temporary)
        subprocess.run([restic, *common, 'restore', snapshot, '--target', str(root / 'download')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        stage = root / 'verified'
        stage.mkdir(mode=0o700)
        for path in paths:
            source = root / 'download' / str(path).lstrip('/')
            if source.is_symlink() or not source.is_file():
                raise ValueError('Redirected handoff file refused')
            with source.open('rb') as content:
                if hashlib.file_digest(content, 'sha256').hexdigest() != hashes[path.name]:
                    raise ValueError('Restored handoff digest mismatch')
            shutil.copyfile(source, stage / path.name)
            (stage / path.name).chmod(0o600)
        handoff = json.loads((stage / 'handoff.json').read_text())
        manifest = json.loads((stage / 'manifest.json').read_text())
        if handoff['sourceFence']['fingerprint'] != fingerprint or handoff['sourceFence']['sequence'] != sequence or not handoff['sourceFence']['retired'] or handoff['archiveManifest'] != manifest or any(manifest['files'][name] != hashes[name] for name in ('ledger.dump', 'private-state.tar.gz')):
            raise ValueError('Restored handoff identity mismatch')
        # Reserve a new private directory exclusively; an existing archive is
        # never replaced. A failed move leaves an incomplete private bundle
        # which the existing restore verifier refuses, rather than enabling it.
        destination.mkdir(mode=0o700)
        for name in names:
            (stage / name).rename(destination / name)
    return dict(snapshotId=snapshot, criticalSequence=sequence, verifiedFiles=4,
                protectedStagingComplete=True, custodyKeysRestoredIntoService=False,
                workerCoverageAcknowledged=False, offHostDurabilityVerified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('state', type=Path, nargs='?')
    parser.add_argument('--restore-receipt', type=Path)
    parser.add_argument('--restore-to', type=Path)
    parser.add_argument('--restic', default='/usr/bin/restic')
    parser.add_argument('--repository-file', required=True)
    parser.add_argument('--password-file', required=True)
    args = parser.parse_args()
    if bool(args.state) == bool(args.restore_receipt) or bool(args.restore_receipt) != bool(args.restore_to):
        parser.error('Supply a handoff state, or both --restore-receipt and --restore-to')
    os.umask(0o077)
    try:
        remote.remote_repository(args.repository_file)
        remote.private_file(args.password_file)
        result = restore_handoff(args.restore_receipt, args.restore_to, args.restic, args.repository_file, args.password_file) if args.restore_receipt else backup_handoff(args.state, args.restic, args.repository_file, args.password_file)
        print(json.dumps(result))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        raise SystemExit('Encrypted handoff failed; do not acknowledge coverage or resume custody')


if __name__ == '__main__':
    main()
