#!/usr/bin/env python3
"""Real restic encryption/restore plus isolated PostgreSQL verification.

Defaults to a LOCAL temporary repository; explicit protected credentials select
an existing HTTPS repository. Neither mode acknowledges worker coverage or
proves the repository is physically independent of the bridge host.
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
    parser.add_argument('--repository-file', help='protected file for an existing HTTPS restic repository')
    parser.add_argument('--password-file', help='protected existing repository password file')
    args = parser.parse_args()
    if bool(args.repository_file) != bool(args.password_file):
        parser.error('Repository and password files must be supplied together')
    if not args.restic or not Path(args.restic).is_absolute():
        parser.error('An absolute restic executable is required')
    os.umask(0o077)
    verify = load('verify_snapshot', 'postgres-verify-backup.py')
    uploader = load('encrypted_snapshot', 'postgres-remote-backup.py')
    remote = bool(args.repository_file)
    if remote:
        # Validate before creating any temporary state or reaching the network.
        # Credentials and the repository URL must never enter the report/argv.
        uploader.remote_repository(args.repository_file)
        uploader.private_file(args.password_file)
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
        if remote:
            repository = Path(args.repository_file)
            password = Path(args.password_file)
        else:
            password = stage / 'password'
            password.write_text(secrets.token_urlsafe(48))
            password.chmod(0o600)
            repository = stage / 'repository-file'
            repository.write_text(str(stage / 'encrypted-repository'))
            repository.chmod(0o600)
        common = [args.restic, '--repository-file', str(repository), '--password-file', str(password)]
        if not remote:
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
                  'repositoryLocation': 'configured HTTPS repository' if remote else 'local disposable storage',
                  'httpsRepositoryRoundTripPassed': remote,
                  'offHostDurabilityTested': False, 'workerCoverageAcknowledged': False,
                  'signerKeysCopied': False, 'sourceLedgerModified': False}
        print(json.dumps(report, sort_keys=True))
        if args.report:
            Path(args.report).write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        raise SystemExit('Encrypted backup acceptance failed; no worker coverage was acknowledged') from None
