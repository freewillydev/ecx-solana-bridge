#!/usr/bin/env python3
"""Consistent private PostgreSQL dump. No remote durability acknowledgement."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

os.umask(0o077)
directory = Path('/var/lib/ecx-bridge/private/backups')
if directory.is_symlink():
    raise SystemExit('Unsafe backup directory')
directory.mkdir(mode=0o700, parents=True, exist_ok=True)
name = 'ledger-' + str(time.time_ns())
pending = directory / (name + '.pending')
finished = directory / (name + '.dump')
with pending.open('xb') as output:
    result = subprocess.run(['pg_dump', '--username=ecx_read', '--format=custom', '--no-owner', '--no-privileges'], stdout=output, stderr=subprocess.DEVNULL)
    output.flush()
    os.fsync(output.fileno())
if result.returncode:
    raise SystemExit('PostgreSQL backup failed; incomplete file retained privately')
if subprocess.run(['pg_restore', '--list', str(pending)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
    raise SystemExit('PostgreSQL backup archive validation failed')
with pending.open('rb') as source:
    digest = hashlib.file_digest(source, 'sha256').hexdigest()
pending.rename(finished)
with (directory / (name + '.json')).open('x') as output:
    json.dump({'archive': finished.name, 'sha256': digest, 'remoteDurabilityAcknowledged': False}, output)
    output.flush()
    os.fsync(output.fileno())
fd = os.open(directory, os.O_RDONLY)
os.fsync(fd)
os.close(fd)
print('Private PostgreSQL backup created; remote durability is not acknowledged')
