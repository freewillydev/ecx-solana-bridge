"""Installer integrity and repeat-install contracts; no wallets or services touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "deploy/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ReleaseIntegrity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        (self.path / "app").write_bytes(b"real package bytes")
        self.manifest = {"format": 1, "os": "ubuntu-24.04", "arch": platform.machine(), "files": {"app": hashlib.sha256(b"real package bytes").hexdigest()}}
        self.save()

    def save(self):
        (self.path / "manifest.json").write_text(json.dumps(self.manifest))

    def test_verified_package_has_stable_identity(self):
        self.assertEqual(installer.verify(self.path), installer.verify(self.path))

    def test_modified_executable_refused(self):
        (self.path / "app").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            installer.verify(self.path)

    def test_missing_file_refused(self):
        (self.path / "app").unlink()
        with self.assertRaises(ValueError):
            installer.verify(self.path)

    def test_unlisted_file_refused(self):
        (self.path / "extra").write_text("not in manifest")
        with self.assertRaises(ValueError):
            installer.verify(self.path)

    def test_symlink_refused(self):
        (self.path / "link").symlink_to("app")
        with self.assertRaises(ValueError):
            installer.verify(self.path)

    def test_nested_manifest_cannot_hide_unlisted_content(self):
        (self.path / "nested").mkdir()
        (self.path / "nested/manifest.json").write_text("unlisted")
        with self.assertRaises(ValueError):
            installer.verify(self.path)

    def test_wrong_architecture_refused(self):
        self.manifest["arch"] = "unsupported"
        self.save()
        with self.assertRaises(ValueError):
            installer.verify(self.path)

    def test_existing_config_preserved_and_difference_refused(self):
        config = self.path / "config"
        config.write_bytes(b"original private configuration")
        installer.keep_file(config, config.read_bytes(), 0o640)
        with self.assertRaises(ValueError):
            installer.keep_file(config, b"replacement", 0o640)
        self.assertEqual(config.read_bytes(), b"original private configuration")


if __name__ == "__main__":
    unittest.main()
