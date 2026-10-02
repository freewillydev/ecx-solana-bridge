#!/usr/bin/env python3
"""Real restic encryption/restore plus isolated PostgreSQL verification.

Uses a LOCAL temporary repository: never off-host acceptance or worker coverage.
Only a trusted archive produced by our own PostgreSQL backup tool is accepted.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, root / 'deploy' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest')
    parser.add_argument('--directory', required=True)
    parser.add_argument('--restic', default=shutil.which('restic'))
    parser.add_argument('--report')
    args = parser.parse_args()
    os.umask(0o077)
    verify = load('verify_snapshot', 'postgres-verify-backup.py')
    uploader = load('encrypted_snapshot', 'postgres-remote-backup.py')
    archive, _ = verify.load_archive(args.manifest)
    directory = Path(args.directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='local-encrypted-contract-', dir=directory) as temporary:
        stage = Path(temporary)
        inputs = stage / 'inputs'
        inputs.mkdir(mode=0o700)
        manifest = inputs / Path(args.manifest).name
        shutil.copyfile(args.manifest, manifest)
        shutil.copyfile(archive, inputs / archive.name)
        password = stage / 'password'
        password.write_text(secrets.token_urlsafe(48))
        password.chmod(0o600)
        repository = stage / 'repository-file'
        repository.write_text(str(stage / 'encrypted-repository'))
        repository.chmod(0o600)
        common = [args.restic, '--repository-file', str(repository), '--password-file', str(password)]
        subprocess.run([*common, 'init'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        receipt = uploader.upload_snapshot(manifest, args.restic, repository, password)
        restore = stage / 'restored'
        subprocess.run([*common, 'restore', receipt['snapshotId'], '--target', str(restore)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        restored_manifest = restore / str(manifest).lstrip('/')
        result = verify.verify_backup(restored_manifest)
        # The original signed/financial archive remains immutable; this only
        # restores into a random isolated database, then drops that database.
        if not result['deploymentMatches'] or not result['tableCountsMatch']:
            raise ValueError('Encrypted restore mismatched source snapshot')
        report = {'encryptedRepositoryRoundTripPassed': True,
                  'authenticatedSnapshotMetadataPassed': True,
                  'postgresRestore': result, 'snapshotId': receipt['snapshotId'],
                  'repositoryLocation': 'local disposable storage',
                  'offHostDurabilityTested': False, 'workerCoverageAcknowledged': False,
                  'signerKeysCopied': False, 'sourceLedgerModified': False}
        print(json.dumps(report, sort_keys=True))
        if args.report:
            Path(args.report).write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
