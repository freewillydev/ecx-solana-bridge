"""Installer integrity and repeat-install contracts; no wallets or services touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

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

    def test_compiled_installer_payload_matches_embedded_checksum(self):
        spec = importlib.util.spec_from_file_location("package_release", Path(__file__).resolve().parents[1] / "deploy/package_release.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as output:
            release = module.package_release(self.path, Path(output), platform.machine())
            data = release.read_bytes()
            line = int(re.search(rb'tail -n \+([0-9]+) "\$0"', data[:4096]).group(1))
            header, payload = data.split(b"\n", line-1)[:-1], data.split(b"\n", line-1)[-1]
            expected = re.search(rb"[0-9a-f]{64}", b"\n".join(header)).group().decode()
            self.assertEqual(hashlib.sha256(payload).hexdigest(), expected)
            self.assertTrue(payload.startswith(b"\x1f\x8b"))

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

    def test_helper_import_preserves_verified_inventory(self):
        deploy = self.path / "deploy"
        deploy.mkdir()
        source = Path(__file__).resolve().parents[1] / "deploy"
        for name in ("install.py", "postgres.py", "configure.py", "upgrade.py"):
            shutil.copyfile(source / name, deploy / name)
            self.manifest["files"]["deploy/" + name] = hashlib.sha256((deploy / name).read_bytes()).hexdigest()
        self.save()
        subprocess.run([sys.executable, "-c", "import runpy,sys; from pathlib import Path; p=Path(sys.argv[1]); sys.path.insert(0,str(p/'deploy')); m=runpy.run_path(str(p/'deploy/install.py')); import postgres,configure,upgrade; m['verify'](p)", str(self.path)], check=True)
        self.assertFalse((deploy / "__pycache__").exists())

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


class ConfigurationOrigins(unittest.TestCase):
    def test_wizard_refuses_missing_origins_before_writing_configuration(self):
        root = Path(__file__).resolve().parents[1]
        spec = importlib.util.spec_from_file_location("configure", root / "deploy/configure.py")
        configure = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(configure)
        for missing in ("token", "SOL"):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "setup"
                def ask(label, default=None, secret=False):
                    if "history origin signature" in label:
                        return "" if label.startswith("Verified " + missing) else "explicit operator origin"
                    return str(default) if default is not None else "test-only input"
                with self.assertRaisesRegex(ValueError, "Verified history origin required"):
                    configure.create_setup("unused-validator", root / "config/l2l-devnet.example.json", output, True, ask)
                self.assertEqual(list(output.iterdir()), [])


class UpgradeFiles(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("upgrade", Path(__file__).resolve().parents[1] / "deploy/upgrade.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.previous = self.root / "previous"
        self.target = self.root / "target"
        self.previous.mkdir()
        self.target.mkdir()
        self.current = self.root / "current"
        self.current.symlink_to(self.previous)
        self.upgrade = self.module.Upgrade.__new__(self.module.Upgrade)
        self.upgrade.previous, self.upgrade.target, self.upgrade.current = self.previous, self.target, self.current
        self.upgrade.old_files = {}

    def test_atomic_release_switch_retains_previous_package(self):
        self.module.atomic_link(self.current, self.target)
        self.assertEqual(self.current.resolve(), self.target)
        self.assertTrue(self.previous.is_dir())

    def test_only_verified_managed_definition_can_change(self):
        source = self.previous / "service"
        source.write_bytes(b"old managed service")
        destination = self.root / "service"
        destination.write_bytes(source.read_bytes())
        self.upgrade.old_files[destination] = source
        ordinary = Mock()
        self.upgrade.keep_file(destination, b"new managed service", 0o644, ordinary=ordinary)
        self.assertEqual(destination.read_bytes(), b"new managed service")
        ordinary.assert_not_called()

    def test_locally_modified_definition_is_preserved(self):
        source = self.previous / "service"
        source.write_bytes(b"old managed service")
        destination = self.root / "service"
        destination.write_bytes(b"local modification")
        self.upgrade.old_files[destination] = source
        with self.assertRaises(ValueError):
            self.upgrade.keep_file(destination, b"new managed service", 0o644, ordinary=Mock())
        self.assertEqual(destination.read_bytes(), b"local modification")

    def test_private_configuration_still_uses_immutable_contract(self):
        config = self.root / "signer.json"
        config.write_bytes(b"private signer")
        with self.assertRaises(ValueError):
            self.upgrade.keep_file(config, b"different signer", 0o600, ordinary=installer.keep_file)
        self.assertEqual(config.read_bytes(), b"private signer")

    def test_failure_stops_services_and_selects_old_release_without_start(self):
        self.module.atomic_link(self.current, self.target)
        self.upgrade.run = Mock()
        self.upgrade.backup = self.root / "private-backup"
        self.upgrade.fail()
        self.assertEqual(self.current.resolve(), self.previous)
        self.upgrade.run.assert_called_once_with("systemctl", "stop", *self.module.SERVICES)

    def test_definition_symlink_is_refused(self):
        source = self.previous / "service"
        source.write_bytes(b"old managed service")
        destination = self.root / "service"
        destination.symlink_to(source)
        self.upgrade.old_files[destination] = source
        with self.assertRaises(ValueError):
            self.upgrade.keep_file(destination, b"new managed service", 0o644, ordinary=installer.keep_file)



if __name__ == "__main__":
    unittest.main()
