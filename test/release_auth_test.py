"""Real OpenSSL signature contracts on file fixtures; no chain/network stand-ins."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/release-auth'


class ReleaseAuthentication(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.key = self.directory / 'key.pem'
        self.public = self.directory / 'public.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(self.key)],
                       check=True, capture_output=True)
        self.key.chmod(0o600)
        subprocess.run(['openssl', 'pkey', '-in', str(self.key), '-pubout', '-out', str(self.public)],
                       check=True, capture_output=True)
        for arch in ('aarch64', 'x86_64'):
            path = self.directory / ('ecx-bridge-ubuntu-24.04-' + arch + '.run')
            path.write_bytes(b'#!/bin/sh\nexit 0\n')
            path.with_suffix('.run.sha256').write_text(
                hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n')
        self.assertEqual(self.call('sign', self.key).returncode, 0)

    def call(self, mode, key, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), mode, str(key),
            str(self.directory), *arguments], capture_output=True, text=True)

    def verify(self, key=None):
        return self.call('verify', key or self.public, 'aarch64')

    def test_original_signed_bytes_verify(self):
        self.assertEqual(self.verify().returncode, 0)

    def test_modified_index_is_rejected(self):
        with (self.directory / 'release-index.json').open('ab') as output:
            output.write(b' ')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_modified_signature_is_rejected(self):
        path = self.directory / 'release-index.sig'
        data = bytearray(path.read_bytes())
        data[0] ^= 1
        path.write_bytes(data)
        self.assertNotEqual(self.verify().returncode, 0)

    def test_modified_installer_is_rejected(self):
        path = self.directory / 'ecx-bridge-ubuntu-24.04-aarch64.run'
        path.write_bytes(b'#!/bin/sh\nexit 9\n')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_different_trust_key_is_rejected(self):
        wrong = self.directory / 'wrong.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(wrong)],
                       check=True, capture_output=True)
        subprocess.run(['openssl', 'pkey', '-in', str(wrong), '-pubout', '-out', str(wrong)+'.pub'],
                       check=True, capture_output=True)
        self.assertNotEqual(self.verify(Path(str(wrong)+'.pub')).returncode, 0)

    def test_signing_key_with_public_access_is_rejected(self):
        (self.directory / 'release-index.json').unlink()
        (self.directory / 'release-index.sig').unlink()
        self.key.chmod(0o644)
        self.assertNotEqual(self.call('sign', self.key).returncode, 0)

    def test_install_arguments_require_install_mode(self):
        self.assertNotEqual(self.call('verify', self.public, 'aarch64', '--', '--test-worker').returncode, 0)


if __name__ == '__main__':
    unittest.main()
