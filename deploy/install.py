#!/usr/bin/env python3
"""Install a reviewed release and initialize an empty ledger; preserve existing state."""
import argparse
import fcntl
import grp
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

# Verify exactly the packaged inventory. Importing the sibling PostgreSQL helper
# must not add root-owned bytecode to the unprivileged extraction directory.
sys.dont_write_bytecode = True


def run(*args, **kw):
    return subprocess.run(args, check=True, **kw)


def verify(bundle):
    manifest = json.loads((bundle / "manifest.json").read_text())
    if manifest.get("format") != 1 or manifest.get("os") != "ubuntu-24.04" or manifest.get("arch") != platform.machine():
        raise ValueError("Wrong release platform or format")
    expected = manifest["files"]
    actual = set()
    for p in bundle.rglob("*"):
        if p.is_symlink() or not (p.is_file() or p.is_dir()):
            raise ValueError("Release contains a link or special file")
        if p.is_file() and p != bundle / "manifest.json":
            name = str(p.relative_to(bundle))
            actual.add(name)
            if hashlib.sha256(p.read_bytes()).hexdigest() != expected.get(name):
                raise ValueError("Release checksum mismatch: " + name)
    if actual != set(expected):
        raise ValueError("Release file inventory mismatch")
    return hashlib.sha256((bundle / "manifest.json").read_bytes()).hexdigest()[:24]


def mkdir(path, mode, user="root", group="root"):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Refusing symlink: " + str(path))
    path.mkdir(parents=True, exist_ok=True)
    os.chown(path, pwd.getpwnam(user).pw_uid, grp.getgrnam(group).gr_gid)
    path.chmod(mode)


def keep_file(path, content, mode, group="root"):
    """Configuration is immutable on repeat install; mismatches need explicit editing."""
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Refusing configuration symlink")
    if path.exists():
        if path.read_bytes() != content:
            raise ValueError(f"Existing {path} differs; refusing to overwrite")
        return
    with path.open("xb") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.chown(path, 0, grp.getgrnam(group).gr_gid)
    path.chmod(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--config-dir", type=Path, help="private directory containing worker.json, helper.json and optional signer.json")
    parser.add_argument("--configure", action="store_true", help="interactively collect and validate private Signet/Devnet configuration")
    parser.add_argument("--port", type=int, help="loopback web port (default 8080, or existing configuration)")
    parser.add_argument("--legacy-snapshot", type=Path, help="consistent final SQLite snapshot; old worker must be stopped")
    parser.add_argument("--with-signet", action="store_true", help="install/start a dedicated real L2L public Signet node")
    parser.add_argument("--test-worker", action="store_true", help="enable payments only for the public Signet/Devnet profile")
    args = parser.parse_args()
    if args.configure and (args.config_dir or not sys.stdin.isatty()):
        parser.error("--configure requires a terminal and cannot be combined with --config-dir")
    if args.port is not None and not 1024 <= args.port <= 65535:
        parser.error("--port must be from 1024 through 65535")
    if os.geteuid() != 0:
        parser.error("Run with sudo")
    if 'ID=ubuntu\n' not in Path('/etc/os-release').read_text() or 'VERSION_ID="24.04"' not in Path('/etc/os-release').read_text():
        parser.error("Ubuntu 24.04 required")
    with open("/run/ecx-bridge-install.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        install(args)


def install(args):
    # Snapshot unprivileged build output, then verify the root-owned copy before using it.
    mkdir("/opt/ecx-bridge/releases", 0o755)
    with tempfile.TemporaryDirectory(prefix=".stage-", dir="/opt/ecx-bridge/releases") as tmp:
        stage = Path(tmp) / "release"
        shutil.copytree(args.bundle, stage, symlinks=True)
        release_id = verify(stage)
        target = Path("/opt/ecx-bridge/releases") / release_id
        if target.exists():
            if verify(target) != release_id:
                raise ValueError("Installed release changed")
        else:
            for p in stage.rglob("*"):
                p.chmod(0o755 if p.is_dir() or p.parent.name == "bin" or p.suffix == ".sh" else 0o644)
            stage.chmod(0o755)
            stage.rename(target)
    current = Path("/opt/ecx-bridge/current")
    if current.exists() and not current.is_symlink():
        raise ValueError("current must be a release symlink")
    if current.is_symlink() and current.resolve() != target:
        raise ValueError("A different release is installed; stop and back up before a reviewed upgrade")
    # Subsequent helper imports use the verified root-owned snapshot, rather
    # than the caller's writable extraction directory.
    sys.path.insert(0, str(target / "deploy"))
    if args.configure:
        from configure import create_setup
        with tempfile.TemporaryDirectory(prefix="ecx-setup-", dir="/run") as directory:
            args.config_dir = Path(directory)
            args.port = create_setup(target / "bin/ecx-bridge", target / "config/l2l-devnet.example.json", args.config_dir, args.with_signet)
            install_runtime(args, target, release_id, current)
    else:
        install_runtime(args, target, release_id, current)


def install_runtime(args, target, release_id, current):
    import postgres
    for name in ("ecx-api", "ecx-worker", "ecx-node"):
        try:
            grp.getgrnam(name)
        except KeyError:
            run("groupadd", "--system", name)
    for name, group in (("ecx-worker", "ecx-api"), ("ecx-web", "ecx-api"), ("ecx-node", "ecx-node")):
        try:
            pwd.getpwnam(name)
        except KeyError:
            run("useradd", "--system", "--gid", group, "--no-create-home", "--home-dir", "/nonexistent", "--shell", "/usr/sbin/nologin", name)
    run("usermod", "--append", "--groups", "ecx-worker,ecx-node", "ecx-worker")
    mkdir("/etc/ecx-bridge", 0o750, group="ecx-worker")
    mkdir("/opt/ecx-bridge/libexec", 0o750, group="ecx-worker")
    shutil.copy2("/usr/bin/bwrap", "/opt/ecx-bridge/libexec/bwrap")
    os.chown("/opt/ecx-bridge/libexec/bwrap", 0, grp.getgrnam("ecx-worker").gr_gid)
    os.chmod("/opt/ecx-bridge/libexec/bwrap", 0o750)
    keep_file("/etc/apparmor.d/ecx-bridge-bwrap", (target / "deploy/ecx-bridge-bwrap.apparmor").read_bytes(), 0o644)
    run("apparmor_parser", "-r", "/etc/apparmor.d/ecx-bridge-bwrap")
    mkdir("/var/lib/ecx-bridge", 0o755)
    mkdir("/var/lib/ecx-bridge/private", 0o700, "ecx-worker", "ecx-worker")
    mkdir("/var/lib/ecx-node", 0o750, "ecx-node", "ecx-node")
    config = Path("/etc/ecx-bridge/worker.json")
    if args.config_dir:
        source = args.config_dir.resolve(strict=True)
        worker = json.loads((source / "worker.json").read_text())
        helper = json.loads((source / "helper.json").read_text())
        required = {"dbPath": "/var/lib/ecx-bridge/private/ledger.sqlite", "customerSocket": "/run/ecx-bridge/customer/api.sock", "adminSocket": "/run/ecx-bridge/admin/api.sock", "helperPath": "/opt/ecx-bridge/current/deploy/helper-sandbox.sh", "helperConfig": "/etc/ecx-bridge/helper.json"}
        if any(worker.get(k) != v for k, v in required.items()):
            raise ValueError("Configuration must use the documented managed paths")
        if any(helper.get(k) != worker.get(v) for k, v in (("deployment_id", "deploymentId"), ("mint", "mint"), ("custody_owner", "custodyOwner"))):
            raise ValueError("Helper/worker identity mismatch")
        signer = helper.get("signer_path")
        if signer not in (None, "/etc/ecx-bridge/signer.json"):
            raise ValueError("Signer must use the managed path")
        run(str(target / "bin/ecx-bridge"), "check-config", str(source / "worker.json"), stdout=subprocess.DEVNULL)
        if signer:
            run(str(target / "bin/ecx-bridge"), "check-signer", str(source / "worker.json"), str(source / "signer.json"), stdout=subprocess.DEVNULL)
        # Check all collisions before writing any config files.
        incoming = [("worker.json", (source / "worker.json").read_bytes()), ("helper.json", (source / "helper.json").read_bytes())]
        if (source / "interface.json").is_file():
            run(str(target / "bin/ecx-bridge"), "check-interface", str(source / "worker.json"), str(source / "interface.json"), stdout=subprocess.DEVNULL)
            incoming.append(("interface.json", (source / "interface.json").read_bytes()))
        if signer:
            incoming.append(("signer.json", (source / "signer.json").read_bytes()))
        for name, content in incoming:
            dest = Path("/etc/ecx-bridge") / name
            if dest.is_symlink() or (dest.exists() and dest.read_bytes() != content):
                raise ValueError(f"Refusing to replace existing {name}")
        for name, content in incoming:
            keep_file(Path("/etc/ecx-bridge") / name, content, 0o640, "ecx-worker")
    if Path("/etc/ecx-bridge/interface.json").is_file():
        keep_file("/etc/ecx-bridge/interface.env", b"ECX_INTERFACE_CONFIG=/etc/ecx-bridge/interface.json\n", 0o640, "ecx-worker")
    port = 8080
    web_environment = Path("/etc/ecx-bridge/web.env")
    if args.port is not None:
        keep_file(web_environment, f"ECX_PORT={args.port}\n".encode(), 0o640, "ecx-worker")
    if web_environment.is_file():
        line = web_environment.read_text().strip()
        if not line.startswith("ECX_PORT=") or not line[9:].isdecimal() or not 1024 <= int(line[9:]) <= 65535:
            raise ValueError("Invalid managed web port")
        port = int(line[9:])
    if args.test_worker:
        if not config.exists():
            raise ValueError("--test-worker requires configured real chains and wallets")
        worker = json.loads(config.read_text())
        if worker.get("profile") != "L2LSignetDevnet" or worker.get("backupRequired"):
            raise ValueError("Payments allowed only for the explicit public test profile")
        if not Path("/etc/ecx-bridge/signer.json").is_file():
            raise ValueError("Payment mode requires the custody signer")
    if args.with_signet and config.exists():
        worker = json.loads(config.read_text())
        if worker["profile"] != "L2LSignetDevnet" or worker["nativeRpc"] != "http://127.0.0.1:29432" or worker["nativeCookie"] != "/run/ecx-node/rpc.cookie":
            raise ValueError("Managed Signet requires the matching profile, loopback port 29432 and /run/ecx-node/rpc.cookie")
    if args.with_signet:
        keep_file("/etc/ecx-node.conf", (target / "deploy/signet.conf").read_bytes(), 0o644)
    if not current.is_symlink():
        temp_link = current.with_name(".current-new")
        temp_link.unlink(missing_ok=True)
        temp_link.symlink_to(target)
        temp_link.replace(current)
    for name in ("ecx-bridge-worker.service", "ecx-bridge-web.service", "ecx-bridge-node.service"):
        dest = Path("/etc/systemd/system") / name
        keep_file(dest, (target / "deploy" / name).read_bytes(), 0o644)
    postgres.install(target, config, mkdir, keep_file, args.legacy_snapshot)
    for name in ("ecx-bridge-backup.service", "ecx-bridge-backup.timer"):
        keep_file(Path("/etc/systemd/system") / name, (target / "deploy" / name).read_bytes(), 0o644)
    if args.test_worker:
        mkdir("/etc/systemd/system/ecx-bridge-worker.service.d", 0o755)
        keep_file("/etc/systemd/system/ecx-bridge-worker.service.d/test.conf", b"[Service]\nExecStart=\nExecStart=/opt/ecx-bridge/current/bin/ecx-bridge postgres-test-worker /etc/ecx-bridge/worker.json\n", 0o644)
    run("systemctl", "daemon-reload")
    run("runuser", "-u", "ecx-worker", "--", "/opt/ecx-bridge/libexec/bwrap", "--unshare-all", "--ro-bind", "/", "/", "--", "/usr/bin/true")
    run("systemd-analyze", "verify", "/etc/systemd/system/ecx-bridge-worker.service", "/etc/systemd/system/ecx-bridge-web.service", "/etc/systemd/system/ecx-bridge-node.service")
    if args.with_signet:
        run("systemctl", "enable", "--now", "ecx-bridge-node.service")
        if config.exists():
            cli = ["runuser", "-u", "ecx-node", "--", str(current / "bin/bitcoin-cli"), "-datadir=/var/lib/ecx-node", "-conf=/etc/ecx-node.conf"]
            for _ in range(60):
                result = subprocess.run(cli + ["listwallets"], capture_output=True, text=True)
                if result.returncode == 0:
                    break
                time.sleep(1)
            if result.returncode:
                raise ValueError("Node did not start; inspect journalctl -u ecx-bridge-node")
            wallet = json.loads(config.read_text())["nativeWallet"]
            if wallet not in json.loads(result.stdout):
                existing = json.loads(subprocess.check_output(cli + ["listwalletdir"]))["wallets"]
                if any(w["name"] == wallet for w in existing):
                    run(*cli, "loadwallet", wallet, "true", stdout=subprocess.DEVNULL)
                else:
                    run(*cli, "-named", "createwallet", "wallet_name=" + wallet, "descriptors=true", "load_on_startup=true", stdout=subprocess.DEVNULL)
    if config.exists():
        run("systemctl", "enable", "--now", "ecx-bridge-backup.timer")
        run("systemctl", "enable", "--now", "ecx-bridge-worker.service", "ecx-bridge-web.service")
        for _ in range(30):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=2) as response:
                    if response.status == 200:
                        break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(1)
        else:
            raise ValueError("Installed services failed their liveness check; inspect journalctl -u ecx-bridge-worker -u ecx-bridge-web")
        print(f"Installed. Interface: http://127.0.0.1:{port}; check /readyz before use.")
    else:
        print("Installed; awaiting real wallet configuration. See docs/INSTALL.md. Services have not been started.")
    print("Release:", release_id)


if __name__ == "__main__":
    main()
