#!/usr/bin/env python3
"""Upload an exact PostgreSQL snapshot to encrypted remote restic storage.

Returns a receipt; only the owning Haskell worker may acknowledge its sequence.
This does not enable payments, copy signer keys, or claim a clean-host restore.
"""
import argparse
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('postgres_snapshot', Path(__file__).with_name('postgres-backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


def private_file(filename):
    path = Path(filename)
    info = path.lstat()
    if not path.is_absolute() or not stat.S_ISREG(info.st_mode) or info.st_uid not in {0, os.geteuid()} or info.st_mode & 0o077:
        raise ValueError('Private regular configuration file required')
    return path


def remote_repository(repository_file):
    repository = private_file(repository_file).read_text().strip()
    return validate_repository(repository)


def validate_repository(repository):
    # One explicit supported remote protocol avoids silently accepting a local
    # path. Credentials stay in the protected file, never in subprocess argv.
    if not repository.startswith('rest:https://'):
        raise ValueError('Remote HTTPS restic REST repository required')
    host = urlsplit(repository[5:]).hostname
    if not host or host.lower().rstrip('.') in {'localhost', 'localhost.localdomain'}:
        raise ValueError('Off-host repository required')
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        pass  # Actual host independence is verified during deployment acceptance.
    else:
        if address.is_loopback or address.is_unspecified:
            raise ValueError('Off-host repository required')
    return repository


def run_json(program, args):
    with tempfile.TemporaryFile() as output:
        subprocess.run([program, *args], stdout=output, stderr=subprocess.DEVNULL,
                       check=True, timeout=300)
        size = output.tell()
        if size > 4*1024*1024:
            raise ValueError('Remote receipt exceeds limit')
        output.seek(0)
        return output.read()


def upload(directory, username, fingerprint, minimum_sequence, restic, repository_file, password_file):
    if not Path(restic).is_absolute() or minimum_sequence < 0 or not re.fullmatch('[0-9a-f]{64}', fingerprint):
        raise ValueError('Invalid backup policy')
    remote_repository(repository_file)
    private_file(password_file)
    manifest_path = backup.create_backup(directory, username)
    manifest = json.loads(manifest_path.read_text())
    deployment = manifest['deployment']
    sequence = deployment['critical_sequence']
    if deployment['fingerprint'] != fingerprint or sequence < minimum_sequence:
        raise ValueError('Snapshot identity or sequence mismatch')
    return upload_snapshot(manifest_path, restic, repository_file, password_file)


def upload_snapshot(manifest_path, restic, repository_file, password_file):
    # The CLI enforces the remote protocol before reaching this storage seam.
    # Integration may exercise real restic encryption with local storage, but
    # that is never a proof of off-host durability or a worker acknowledgement.
    manifest_path = Path(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    deployment = manifest['deployment']
    fingerprint, sequence = deployment['fingerprint'], deployment['critical_sequence']
    name = manifest['archive']
    if not manifest_path.is_absolute() or Path(name).name != name or manifest['format'] != 1 or deployment['schema_version'] != 18:
        raise ValueError('Invalid snapshot manifest')
    archive = manifest_path.parent / name
    with archive.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != manifest['sha256']:
            raise ValueError('Snapshot checksum mismatch')
    tags = ['ecx-bridge-critical', 'deployment:' + fingerprint, 'sequence:' + str(sequence)]
    common = ['--repository-file', str(repository_file), '--password-file', str(password_file)]
    args = [*common, 'backup', '--json']
    for tag in tags:
        args.extend(['--tag', tag])
    args.extend([str(archive), str(manifest_path)])
    lines = run_json(restic, args).splitlines()
    summaries = [line for line in (json.loads(item) for item in lines) if line.get('message_type') == 'summary']
    if len(summaries) != 1 or not re.fullmatch('[0-9a-f]{64}', summaries[0].get('snapshot_id', '')):
        raise ValueError('Remote backup acknowledgment missing')
    snapshot_id = summaries[0]['snapshot_id']
    # Read back authenticated snapshot metadata from the repository. Restic's
    # successful backup is the pack-write barrier; this checks its association.
    remote = json.loads(run_json(restic, [*common, 'cat', 'snapshot', snapshot_id]))
    if sorted(remote.get('paths', [])) != sorted([str(archive), str(manifest_path)]) or not set(tags) <= set(remote.get('tags', [])):
        raise ValueError('Remote snapshot association mismatch')
    receipt = {'format': 1, 'fingerprint': fingerprint, 'criticalSequence': sequence,
               'snapshotId': snapshot_id, 'archiveSha256': manifest['sha256']}
    receipt_path = manifest_path.with_suffix('.receipt.json')
    with receipt_path.open('x') as output:
        receipt_path.chmod(0o600)
        json.dump(receipt, output, sort_keys=True)
        output.flush()
        os.fsync(output.fileno())
    fd = os.open(receipt_path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--username', default='ecx_read')
    parser.add_argument('--fingerprint', required=True)
    parser.add_argument('--minimum-sequence', type=int, required=True)
    parser.add_argument('--restic', default='/usr/bin/restic')
    parser.add_argument('--repository-file', required=True)
    parser.add_argument('--password-file', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        receipt = upload(args.directory, args.username, args.fingerprint, args.minimum_sequence,
                         args.restic, args.repository_file, args.password_file)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        raise SystemExit('Remote PostgreSQL backup failed; coverage must remain unchanged')
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
