"""Explicit managed remote-backup configuration; never enables canonical funds."""
import importlib.util
import json
from pathlib import Path
import stat
import subprocess

MANAGED = {
    'python': '/usr/bin/python3',
    'uploader': '/opt/ecx-bridge/current/deploy/postgres-remote-backup.py',
    'stage': '/var/lib/ecx-bridge/private/critical-backups',
    'restic': '/usr/bin/restic',
    'repositoryFile': '/etc/ecx-bridge/backup.repository',
    'passwordFile': '/etc/ecx-bridge/backup.password',
}


def read_private(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 8192:
        raise ValueError('Private regular backup credential file required')
    content = path.read_bytes()
    if not content.strip():
        raise ValueError('Empty backup credential file')
    return content


def incoming_backup(source, target, run):
    if json.loads((source / 'backup.json').read_text()) != MANAGED:
        raise ValueError('Backup configuration must use the documented managed paths')
    run(str(target / 'bin/ecx-bridge'), 'check-backup', str(source / 'backup.json'), stdout=subprocess.DEVNULL)
    incoming = [('backup.json', (source / 'backup.json').read_bytes())]
    for name in ('backup.repository', 'backup.password'):
        incoming.append((name, read_private(source / name)))
    # Validate the actual source URL through the release's own uploader policy,
    # without a database connection, repository connection or secret output.
    spec = importlib.util.spec_from_file_location('remote_backup_policy', target / 'deploy/postgres-remote-backup.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.validate_repository(read_private(source / 'backup.repository').decode().strip())
    return incoming


def validate_managed_backup(target, run):
    directory = Path('/etc/ecx-bridge')
    if json.loads((directory / 'backup.json').read_text()) != MANAGED:
        raise ValueError('Managed remote backup configuration required')
    run(str(target / 'bin/ecx-bridge'), 'check-backup', str(directory / 'backup.json'), stdout=subprocess.DEVNULL)
    for name in ('backup.repository', 'backup.password'):
        read_private(directory / name)
    spec = importlib.util.spec_from_file_location('remote_backup_policy', target / 'deploy/postgres-remote-backup.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.validate_repository(read_private(directory / 'backup.repository').decode().strip())
    if not Path('/usr/bin/restic').is_file():
        raise ValueError('Install the packaged restic runtime dependency')
