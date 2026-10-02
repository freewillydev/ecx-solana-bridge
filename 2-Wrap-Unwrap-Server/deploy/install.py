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
import stat
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


def secure_signer(path):
    """Tighten only known managed key layouts; never admit a public/link key."""
    path = Path(path)
    info = path.lstat()
    worker = pwd.getpwnam("ecx-worker")
    group = grp.getgrnam("ecx-worker").gr_gid
    mode = stat.S_IMODE(info.st_mode)
    if not stat.S_ISREG(info.st_mode) or not (
        (mode == 0o600 and info.st_uid in {0, worker.pw_uid}) or
        (mode == 0o640 and info.st_uid == 0 and info.st_gid == group)
    ):
        raise ValueError("Unsafe managed signer ownership or permissions")
    path.chmod(0o600)
    os.chown(path, worker.pw_uid, group)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--config-dir", type=Path, help="private directory containing worker.json, helper.json and optional signer.json")
    parser.add_argument("--upgrade", action="store_true", help="stop and privately back up an existing PostgreSQL deployment, then switch verified releases")
    parser.add_argument("--configure", action="store_true", help="interactively collect and validate private Signet/Devnet configuration")
    parser.add_argument("--port", type=int, help="loopback web port (default 8080, or existing configuration)")
    parser.add_argument("--with-signet", action="store_true", help="install/start a dedicated real L2L public Signet node")
    parser.add_argument("--test-worker", action="store_true", help="enable payments only for explicit Signet/Devnet or betanet/Devnet test profiles")
    parser.add_argument("--backed-test-worker", action="store_true", help="enable Devnet payments with mandatory encrypted off-host backup (requires backup.json and protected repository/password files)")
    args = parser.parse_args()
    if args.test_worker and args.backed_test_worker:
        parser.error("Choose either --test-worker or --backed-test-worker")
    if args.configure and args.backed_test_worker:
        parser.error("--backed-test-worker requires prepared private backup configuration; use --config-dir instead of --configure")
    if args.upgrade and (args.configure or args.config_dir or args.test_worker or args.backed_test_worker or args.port is not None):
        parser.error("--upgrade preserves configuration/payment mode; do not combine it with configuration, port or payment-mode changes")
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
    previous = current.resolve() if current.is_symlink() else None
    upgrading = previous is not None and previous != target
    if upgrading and not args.upgrade:
        raise ValueError("A different release is installed; use --upgrade for a stopped-worker private backup and verified switch")
    if args.upgrade and previous is None:
        raise ValueError("--upgrade requires an existing managed release")
    # Subsequent helper imports use the verified root-owned snapshot, rather
    # than the caller's writable extraction directory.
    sys.path.insert(0, str(target / "deploy"))
    upgrade = None
    keeper = keep_file
    if upgrading:
        from upgrade import Upgrade
        upgrade = Upgrade(previous, target, current, verify, run)
        upgrade.prepare()
        keeper = lambda path, content, mode, group="root": upgrade.keep_file(path, content, mode, group, ordinary=keep_file)
        args.with_signet = args.with_signet or upgrade.node_was_active
    try:
        if args.configure:
            from configure import create_setup
            with tempfile.TemporaryDirectory(prefix="ecx-setup-", dir="/run") as directory:
                args.config_dir = Path(directory)
                args.port = create_setup(target / "bin/ecx-bridge", target / "config/l2l-devnet.example.json", args.config_dir, args.with_signet)
                install_runtime(args, target, release_id, current, keeper)
        else:
            install_runtime(args, target, release_id, current, keeper)
    except BaseException:
        if upgrade is not None:
            upgrade.fail()
        raise


def install_runtime(args, target, release_id, current, keep=keep_file):
    import postgres
    for name in ("ecx-api", "ecx-worker", "ecx-node"):
        try:
            grp.getgrnam(name)
        except KeyError:
            run("groupadd", "--system", name)
    for name, group in (("ecx-worker", "ecx-api"), ("ecx-node", "ecx-node")):
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
    keep("/etc/apparmor.d/ecx-bridge-bwrap", (target / "deploy/ecx-bridge-bwrap.apparmor").read_bytes(), 0o644)
    run("apparmor_parser", "-r", "/etc/apparmor.d/ecx-bridge-bwrap")
    mkdir("/var/lib/ecx-bridge", 0o755)
    mkdir("/var/lib/ecx-bridge/private", 0o700, "ecx-worker", "ecx-worker")
    mkdir("/var/lib/ecx-node", 0o750, "ecx-node", "ecx-node")
    config = Path("/etc/ecx-bridge/worker.json")
    if args.config_dir:
        source = args.config_dir.resolve(strict=True)
        worker = json.loads((source / "worker.json").read_text())
        helper = json.loads((source / "helper.json").read_text())
        required = {"dbPath": "/var/lib/ecx-bridge/private/ledger.sqlite", "customerSocket": "/run/ecx-bridge/customer/api.sock", "adminSocket": "/run/ecx-bridge/admin/api.sock", "signerSocket": "/run/ecx-bridge/signer/api.sock", "solanaSdkLibrary": "/opt/ecx-bridge/current/lib/libecx_solana_sdk.so"}
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
        if args.backed_test_worker:
            from backed import incoming_backup
            incoming.extend(incoming_backup(source, target, run))
        if signer:
            incoming.append(("signer.json", (source / "signer.json").read_bytes()))
        for name, content in incoming:
            dest = Path("/etc/ecx-bridge") / name
            if dest.is_symlink() or (dest.exists() and dest.read_bytes() != content):
                raise ValueError(f"Refusing to replace existing {name}")
        for name, content in incoming:
            dest = Path("/etc/ecx-bridge") / name
            credential = name in {"backup.repository", "backup.password"}
            keep(dest, content, 0o600 if credential or name == "signer.json" else 0o640, "ecx-worker")
            if credential:
                os.chown(dest, pwd.getpwnam("ecx-worker").pw_uid, grp.getgrnam("ecx-worker").gr_gid)
                dest.chmod(0o600)
    managed_signer = Path("/etc/ecx-bridge/signer.json")
    if managed_signer.exists() or managed_signer.is_symlink():
        secure_signer(managed_signer)
        run(str(target / "bin/ecx-bridge"), "check-signer", str(config), str(managed_signer), stdout=subprocess.DEVNULL)
    if Path("/etc/ecx-bridge/interface.json").is_file():
        keep("/etc/ecx-bridge/interface.env", b"ECX_INTERFACE_CONFIG=/etc/ecx-bridge/interface.json\n", 0o640, "ecx-worker")
    port = 8080
    web_environment = Path("/etc/ecx-bridge/web.env")
    if args.port is not None:
        keep(web_environment, f"ECX_PORT={args.port}\n".encode(), 0o640, "ecx-worker")
    if web_environment.is_file():
        line = web_environment.read_text().strip()
        if not line.startswith("ECX_PORT=") or not line[9:].isdecimal() or not 1024 <= int(line[9:]) <= 65535:
            raise ValueError("Invalid managed web port")
        port = int(line[9:])
    if args.test_worker or args.backed_test_worker:
        if not config.exists():
            raise ValueError("--test-worker requires configured real chains and wallets")
        worker = json.loads(config.read_text())
        if worker.get("profile") not in {"L2LSignetDevnet", "ECXBetanetDevnet"} or worker.get("backupRequired") is not args.backed_test_worker:
            raise ValueError("Devnet payment mode and backupRequired policy must match")
        if args.backed_test_worker:
            from backed import validate_managed_backup
            validate_managed_backup(target, run)
            mkdir("/var/lib/ecx-bridge/private/critical-backups", 0o700, "ecx-worker", "ecx-worker")
        if not Path("/etc/ecx-bridge/signer.json").is_file():
            raise ValueError("Payment mode requires the custody signer")
    if args.with_signet and config.exists():
        worker = json.loads(config.read_text())
        if worker["profile"] != "L2LSignetDevnet" or worker["nativeRpc"] != "http://127.0.0.1:29432" or worker["nativeCookie"] != "/run/ecx-node/rpc.cookie":
            raise ValueError("Managed Signet requires the matching profile, loopback port 29432 and /run/ecx-node/rpc.cookie")
    if args.with_signet:
        keep("/etc/ecx-node.conf", (target / "deploy/signet.conf").read_bytes(), 0o644)
    for name in ("ecx-bridge-worker.service", "ecx-bridge-node.service"):
        dest = Path("/etc/systemd/system") / name
        keep(dest, (target / "deploy" / name).read_bytes(), 0o644)
    postgres.install(target, config, mkdir, keep)
    for name in ("ecx-bridge-backup.service", "ecx-bridge-backup.timer"):
        keep(Path("/etc/systemd/system") / name, (target / "deploy" / name).read_bytes(), 0o644)
    payment_mode_added = False
    if args.test_worker or args.backed_test_worker:
        mkdir("/etc/systemd/system/ecx-bridge-worker.service.d", 0o755)
        command = "postgres-backed-test-worker /etc/ecx-bridge/worker.json /etc/ecx-bridge/backup.json" if args.backed_test_worker else "postgres-test-worker /etc/ecx-bridge/worker.json"
        payment_mode_added = not Path("/etc/systemd/system/ecx-bridge-worker.service.d/test.conf").exists()
        keep("/etc/systemd/system/ecx-bridge-worker.service.d/test.conf", ("[Service]\nExecStart=\nExecStart=/opt/ecx-bridge/current/bin/ecx-bridge " + command + "\n").encode(), 0o644)
    # Switch only after configuration, schema and unit setup have succeeded.
    from upgrade import atomic_link
    atomic_link(current, target)
    # Retire the previous public proxy before the API binds its loopback port.
    obsolete = Path("/etc/systemd/system/ecx-bridge-web.service")
    if obsolete.exists():
        run("systemctl", "disable", "--now", obsolete.name)
        obsolete.unlink()
    run("systemctl", "daemon-reload")
    run("runuser", "-u", "ecx-worker", "--", "/opt/ecx-bridge/libexec/bwrap", "--unshare-all", "--ro-bind", "/", "/", "--", "/usr/bin/true")
    run("systemd-analyze", "verify", "/etc/systemd/system/ecx-bridge-worker.service", "/etc/systemd/system/ecx-bridge-node.service")
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
        run("systemctl", "enable", "--now", "ecx-bridge-worker.service")
        if payment_mode_added:
            # daemon-reload changes future starts, not an active observer process.
            # Existing paying repeat installs retain their running process.
            run("systemctl", "restart", "ecx-bridge-worker.service")
        for _ in range(30):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=2) as response:
                    if response.status == 200:
                        break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(1)
        else:
            raise ValueError("Installed services failed their liveness check; inspect journalctl -u ecx-bridge-worker")
        print(f"Installed. Interface: http://127.0.0.1:{port}; check /readyz before use.")
    else:
        print("Installed; awaiting real wallet configuration. See docs/INSTALL.md. Services have not been started.")
    print("Release:", release_id)


if __name__ == "__main__":
    main()
