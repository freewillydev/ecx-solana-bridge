#!/usr/bin/env python3
"""Install a reviewed release and initialize an empty ledger; preserve existing state."""
import argparse
import fcntl
import grp
import hashlib
import hmac
import secrets
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
    """Retain custody bytes while transferring access from the old worker to signer."""
    path = Path(path)
    info = path.lstat()
    owners = {0, pwd.getpwnam("ecx-worker").pw_uid, pwd.getpwnam("ecx-signer").pw_uid}
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in owners or stat.S_IMODE(info.st_mode) not in {0o600, 0o640}:
        raise ValueError("Unsafe managed signer ownership or permissions")
    if stat.S_IMODE(info.st_mode) == 0o640 and (info.st_uid != 0 or info.st_gid != grp.getgrnam("ecx-worker").gr_gid):
        raise ValueError("Unsafe managed signer ownership or permissions")
    path.chmod(0o600)
    os.chown(path, pwd.getpwnam("ecx-signer").pw_uid, grp.getgrnam("ecx-signer").gr_gid)


# Only observation, unsigned construction, input locks and exact-byte broadcast.
# walletprocesspsbt (even its unsigned mode) belongs exclusively to the signer.
NATIVE_WORKER_METHODS = (
    "getblockchaininfo,getblockhash,getconnectioncount,getaddressinfo,decodescript,"
    "getwalletinfo,getnewaddress,getaddressesbylabel,listsinceblock,listunspent,"
    "listlockunspent,getbalances,getmempoolentry,gettransaction,getblockheader,"
    "getrawchangeaddress,gettxout,walletcreatefundedpsbt,decodepsbt,decoderawtransaction,"
    "lockunspent,testmempoolaccept,gettxspendingprevout,sendrawtransaction"
)


def native_worker_policy(credential, salt):
    # Bitcoin Core's rpcauth scheme: HMAC-SHA256 keyed by the hexadecimal salt.
    if len(salt) != 32 or any(c not in "0123456789abcdef" for c in salt):
        raise ValueError("Invalid managed native RPC salt")
    username, password = credential.strip().split(":", 1)
    if username != "ecx_worker" or len(password) != 64 or any(c not in "0123456789abcdef" for c in password):
        raise ValueError("Invalid managed native worker credential")
    digest = hmac.new(salt.encode(), password.encode(), hashlib.sha256).hexdigest()
    return (f"rpcauth={username}:{salt}${digest}\n"
            "rpcwhitelistdefault=0\n"
            f"rpcwhitelist={username}:{NATIVE_WORKER_METHODS}\n").encode()


def install_native_authority(keep):
    credential = Path("/etc/ecx-bridge/native-worker.auth")
    if credential.is_symlink():
        raise ValueError("Native worker credential cannot be a symlink")
    content = credential.read_bytes() if credential.exists() else ("ecx_worker:" + secrets.token_hex(32) + "\n").encode()
    policy = Path("/etc/ecx-native-rpc.conf")
    if policy.is_symlink():
        raise ValueError("Native RPC policy cannot be a symlink")
    # Retain salt and password on repeats; refuse a mismatched existing policy.
    if policy.exists():
        first = policy.read_text().splitlines()[0]
        salt = first.split(":", 1)[1].split("$", 1)[0]
    else:
        salt = secrets.token_hex(16)
    expected = native_worker_policy(content.decode(), salt)
    keep(credential, content, 0o640, "ecx-worker")
    keep(policy, expected, 0o640, "ecx-node")
    credential.chmod(0o640)
    os.chown(credential, 0, grp.getgrnam("ecx-worker").gr_gid)
    policy.chmod(0o640)
    os.chown(policy, 0, grp.getgrnam("ecx-node").gr_gid)


def install_signing_authority(keep, native_cookie):
    # Never rotate an existing key or regenerate an incomplete TLS identity.
    mkdir("/etc/ecx-bridge/signing", 0o750, group="ecx-signer")
    private = Path("/etc/ecx-bridge/signing/private.json")
    content = (json.dumps({"nativeSigningCookie": native_cookie,
                          "solanaSigningKey": "/etc/ecx-bridge/signer.json"}, sort_keys=True) + "\n").encode()
    keep(private, content, 0o600)
    os.chown(private, pwd.getpwnam("ecx-signer").pw_uid, grp.getgrnam("ecx-signer").gr_gid)
    token = Path("/etc/ecx-bridge/signing.auth")
    if not token.exists():
        keep(token, (secrets.token_hex(32) + "\n").encode(), 0o640, "ecx-worker")
    cert, key = Path(str(token) + ".pem"), Path(str(token) + ".key")
    if cert.is_symlink() or key.is_symlink() or token.is_symlink():
        raise ValueError("Signer credential cannot be a symlink")
    if cert.exists() != key.exists():
        raise ValueError("Incomplete signer TLS identity; recover it before continuing")
    if not cert.exists():
        with tempfile.TemporaryDirectory(prefix="ecx-signer-tls-", dir="/run") as directory:
            staged = Path(directory)
            run("openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes", "-days", "365",
                "-subj", "/CN=ecx-local-signer", "-addext", "subjectAltName=IP:127.0.0.1",
                "-keyout", str(staged / "key"), "-out", str(staged / "cert"),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            keep(key, (staged / "key").read_bytes(), 0o600)
            keep(cert, (staged / "cert").read_bytes(), 0o644)
    os.chown(key, pwd.getpwnam("ecx-signer").pw_uid, grp.getgrnam("ecx-signer").gr_gid)
    key.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--config-dir", type=Path, help="private directory containing worker.json and optional signer.json")
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
    config = Path("/etc/ecx-bridge/worker.json")
    # Group changes do not revoke credentials from an already running process.
    # Upgrade.prepare stops both authorities and snapshots state before we get here.
    if not Path("/etc/ecx-bridge/signing/private.json").exists():
        if subprocess.run(["systemctl", "is-active", "--quiet", "ecx-bridge-worker.service"]).returncode == 0:
            raise ValueError("Stop the existing worker through --upgrade before separating signing authority")
    args.with_signet = args.with_signet or Path("/etc/ecx-native-rpc.conf").is_file()
    if args.upgrade and args.with_signet and config.is_file():
        worker = json.loads(config.read_text())
        if worker.get("nativeCookie") == "/run/ecx-node/rpc.cookie":
            # Only the credential location changes; it is outside fingerprint.
            worker["nativeCookie"] = "/etc/ecx-bridge/native-worker.auth"
            with tempfile.NamedTemporaryFile(mode="w", dir=config.parent, delete=False) as output:
                temporary = Path(output.name)
                try:
                    json.dump(worker, output, indent=2)
                    output.write("\n"); output.flush(); os.fsync(output.fileno())
                    run(str(target / "bin/ecx-bridge"), "check-config", str(temporary), stdout=subprocess.DEVNULL)
                    os.chown(temporary, 0, grp.getgrnam("ecx-worker").gr_gid)
                    temporary.chmod(0o640)
                    temporary.replace(config)
                finally:
                    temporary.unlink(missing_ok=True)
    for name in ("ecx-api", "ecx-worker", "ecx-node", "ecx-signer"):
        try:
            grp.getgrnam(name)
        except KeyError:
            run("groupadd", "--system", name)
    for name, group in (("ecx-worker", "ecx-api"), ("ecx-node", "ecx-node"), ("ecx-signer", "ecx-signer")):
        try:
            pwd.getpwnam(name)
        except KeyError:
            run("useradd", "--system", "--gid", group, "--no-create-home", "--home-dir", "/nonexistent", "--shell", "/usr/sbin/nologin", name)
    # Exact supplementary groups remove the old worker's native-cookie access.
    run("usermod", "--groups", "ecx-worker", "ecx-worker")
    run("usermod", "--groups", "ecx-worker,ecx-node", "ecx-signer")
    mkdir("/etc/ecx-bridge", 0o750, group="ecx-worker")
    mkdir("/var/lib/ecx-bridge", 0o755)
    mkdir("/var/lib/ecx-bridge/private", 0o700, "ecx-worker", "ecx-worker")
    mkdir("/var/lib/ecx-node", 0o750, "ecx-node", "ecx-node")
    config = Path("/etc/ecx-bridge/worker.json")
    if args.config_dir:
        source = args.config_dir.resolve(strict=True)
        worker = json.loads((source / "worker.json").read_text())

        required = {"customerSocket": "/run/ecx-bridge/customer/api.sock", "adminSocket": "/run/ecx-bridge/admin/api.sock", "signerPort": 8081, "signerAuthFile": "/etc/ecx-bridge/signing.auth", "solanaSdkLibrary": "/opt/ecx-bridge/current/lib/libecx_solana_sdk.so"}
        if any(worker.get(k) != v for k, v in required.items()):
            raise ValueError("Configuration must use the documented managed paths")
        signer = (source / "signer.json").is_file()
        run(str(target / "bin/ecx-bridge"), "check-config", str(source / "worker.json"), stdout=subprocess.DEVNULL)
        if signer:
            run(str(target / "bin/ecx-bridge"), "check-signer", str(source / "worker.json"), str(source / "signer.json"), stdout=subprocess.DEVNULL)
        # Check all collisions before writing any config files.
        incoming = [("worker.json", (source / "worker.json").read_bytes())]
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
        if worker["profile"] != "L2LSignetDevnet" or worker["nativeRpc"] != "http://127.0.0.1:29432" or worker["nativeCookie"] != "/etc/ecx-bridge/native-worker.auth":
            raise ValueError("Managed Signet requires the matching profile, loopback port 29432 and /etc/ecx-bridge/native-worker.auth")
    if args.with_signet:
        install_native_authority(keep)
        keep("/etc/ecx-node.conf", (target / "deploy/signet.conf").read_bytes(), 0o644)
    for name in ("ecx-bridge-worker.service", "ecx-bridge-node.service", "ecx-bridge-signer.service"):
        dest = Path("/etc/systemd/system") / name
        keep(dest, (target / "deploy" / name).read_bytes(), 0o644)
    if managed_signer.is_file():
        if not args.with_signet:
            raise ValueError("Automatic signer provisioning currently requires --with-signet; external nodes need reviewed restricted RPC configuration")
        install_signing_authority(keep, "/run/ecx-node/rpc.cookie")
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
    run("systemd-analyze", "verify", "/etc/systemd/system/ecx-bridge-worker.service", "/etc/systemd/system/ecx-bridge-node.service", "/etc/systemd/system/ecx-bridge-signer.service")
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
        if managed_signer.is_file():
            run("systemctl", "enable", "--now", "ecx-bridge-signer.service")
        run("systemctl", "enable", "--now", "ecx-bridge-backup.timer")
        run("systemctl", "enable", "--now", "ecx-bridge-worker.service")
        if payment_mode_added:
            # daemon-reload changes future starts, not an active observer process.
            # Existing paying repeat installs retain their running process.
            run("systemctl", "restart", "ecx-bridge-worker.service")
        for _ in range(30):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/config", timeout=2) as response:
                    if response.status == 200:
                        break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(1)
        else:
            raise ValueError("Installed services failed their liveness check; inspect journalctl -u ecx-bridge-worker")
        print(f"Installed. Interface: http://127.0.0.1:{port}; inspect /api/v1/config availability before use.")
    else:
        print("Installed; awaiting real wallet configuration. See docs/INSTALL.md. Services have not been started.")
    print("Release:", release_id)


if __name__ == "__main__":
    main()
