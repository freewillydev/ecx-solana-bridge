"""Offline refusal contracts for the encrypted-backup acceptance command."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class BackupCommandRefusals(unittest.TestCase):
    def test_credentials_and_remote_policy_fail_before_staging(self):
        command = Path(__file__).with_name('PostgresEncryptedBackupCheck.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository, password = root / 'repository', root / 'password'
            password.write_text('offline-test-password-do-not-log')
            password.chmod(0o600)
            cases = [
                ('local', '/tmp/offline-repository', 0o600, True),
                ('loopback', 'rest:https://127.0.0.1/offline', 0o600, True),
                ('exposed', 'rest:https://backup.example.invalid/offline', 0o644, True),
                ('incomplete', 'rest:https://backup.example.invalid/offline', 0o600, False),
            ]
            for name, location, mode, paired in cases:
                with self.subTest(name=name):
                    repository.write_text(location)
                    repository.chmod(mode)
                    stage = root / name
                    args = [sys.executable, str(command), str(root / 'absent-manifest'),
                            '--directory', str(stage), '--restic', '/absent-restic',
                            '--repository-file', str(repository)]
                    if paired:
                        args.extend(['--password-file', str(password)])
                    result = subprocess.run(args, capture_output=True, timeout=10,
                                            env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(stage.exists())
                    self.assertNotIn(password.read_bytes(), result.stdout + result.stderr)
                    self.assertNotIn(location.encode(), result.stdout + result.stderr)
                    self.assertNotIn(b'Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
