#!/usr/bin/env python3
"""Prepare a private, validated real Signet/Devnet setup. Never funds or pays."""
import argparse
import getpass
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import warnings


def prompt(label, default=None, secret=False):
    suffix = f" [{default}]" if default is not None else ""
    if secret:
        # getpass restores terminal echo even on interruption. Refuse its
        # plaintext fallback rather than accidentally displaying a key or URL.
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            answer = getpass.getpass(label + suffix + ": ")
    else:
        answer = input(label + suffix + ": ")
    return answer.strip() or (str(default) if default is not None else "")


def integer(value, low, high):
    if not value.isascii() or not value.isdecimal() or not low <= int(value) <= high:
        raise ValueError(f"Expected integer from {low} through {high}")
    return int(value)


def check(binary, *args):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        try:
            code = json.loads(result.stdout).get("error", "validation_failed")
        except (ValueError, AttributeError):
            code = "validation_failed"
        raise ValueError("Configuration validation failed: " + code)


def create_setup(binary, template, output, managed_node, ask=prompt):
    output = Path(output)
    if output.is_symlink():
        raise ValueError("Setup directory cannot be a symlink")
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    if stat.S_IMODE(output.stat().st_mode) & 0o077 or any(output.iterdir()):
        raise ValueError("Use an empty owner-only setup directory")
    worker = json.loads(Path(template).read_text())
    worker["deploymentId"] = ask("Deployment name", worker["deploymentId"])
    worker["nativeWallet"] = ask("Native descriptor wallet name", worker["nativeWallet"])
    if not managed_node:
        worker["nativeRpc"] = ask("Existing L2L Signet loopback RPC", worker["nativeRpc"])
        worker["nativeCookie"] = ask("Absolute RPC cookie path")
    worker["solanaRpc"] = ask("Solana Devnet HTTPS RPC (hidden; may contain an API key)", worker["solanaRpc"], True)
    worker["solanaVerifierRpc"] = ask("Independent Devnet HTTPS RPC (hidden; optional)", secret=True) or None
    for field, label in [("mint", "Actual Devnet token mint"), ("custodyOwner", "Actual custody public key"), ("custodyAta", "Actual custody associated token account")]:
        worker[field] = ask(label)
    for field, label in [("solanaHistoryStart", "Verified token history origin signature (optional)"), ("solanaOperatingHistoryStart", "Verified SOL history origin signature (optional)")]:
        worker[field] = ask(label) or None
    policies = [
        ("minInput", "Minimum input, integer base units", 1, 10**15),
        ("maxInput", "Maximum input, integer base units", 1, 10**15),
        ("maxQueued", "Maximum queued orders", 1, 1000),
        ("quoteSeconds", "Quote payment window in seconds", 1, 3600),
        ("confirmationGraceSeconds", "Confirmation grace in seconds", 0, 86400),
        ("nativeConfirmations", "Native confirmations", 1, 2**31-1),
        ("maxNativeFee", "Maximum native payment fee, base units", 1, 2**63-1),
        ("maxSolFee", "Maximum Solana transaction fee, lamports", 1, 2**63-1),
        ("maxSolAccountRent", "Maximum account rent, lamports", 0, 2**63-1),
        ("maxNativeDailyCost", "Daily native operating budget, base units", 1, 2**63-1),
        ("maxSolDailyCost", "Daily Solana operating budget, lamports", 1, 2**63-1),
    ]
    for field, label, low, high in policies:
        value = integer(ask(label, worker[field]), low, high)
        worker[field] = str(value) if isinstance(worker[field], str) else value
    port = integer(ask("Loopback web port", 8080), 1024, 65535)
    interface = {
        "supportUrl": ask("Operator support URL or mailto address (optional)") or None,
        "publicOrigin": ask("Public HTTPS origin, if configured separately (optional)") or None,
        "nativeExplorerBase": ask("Native explorer transaction prefix", "https://explorer.signet.drivechain.info/tx/"),
        "jupiterUrl": None, "orcaUrl": None,
    }
    signer = ask("Custody keypair file; blank for observation, '-' to paste hidden JSON")
    helper = {"deployment_id": worker["deploymentId"], "mint": worker["mint"], "custody_owner": worker["custodyOwner"], "signer_path": "/etc/ecx-bridge/signer.json" if signer else None}

    def write(name, value):
        filename = output / name
        fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())

    write("worker.json", worker)
    write("helper.json", helper)
    write("interface.json", interface)
    if signer:
        if signer == "-":
            key_text = ask("Paste Solana custody keypair JSON (hidden)", secret=True)
        else:
            source = Path(signer).expanduser().resolve(strict=True)
            if stat.S_IMODE(source.stat().st_mode) & 0o077 or source.stat().st_size > 32768:
                raise ValueError("Keypair file must be owner-only and at most 32 KiB")
            key_text = source.read_text()
        try:
            key = json.loads(key_text)
        except ValueError:
            raise ValueError("Invalid keypair JSON") from None
        if not isinstance(key, list) or len(key) != 64 or any(type(n) is not int or not 0 <= n <= 255 for n in key):
            raise ValueError("Expected a 64-byte Solana keypair array")
        write("signer.json", key)
    check(binary, "check-config", output / "worker.json")
    check(binary, "check-interface", output / "worker.json", output / "interface.json")
    if signer:
        check(binary, "check-signer", output / "worker.json", output / "signer.json")
    return port


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary", default="ecx-bridge")
    parser.add_argument("--with-signet", action="store_true")
    args = parser.parse_args()
    if not sys.stdin.isatty():
        parser.error("Interactive terminal required; use --config-dir for noninteractive installation")
    binary = shutil.which(args.binary)
    if not binary:
        parser.error("Supply the built bridge binary")
    port = create_setup(binary, Path(__file__).resolve().parents[1] / "config/l2l-devnet.example.json", args.output, args.with_signet)
    print(f"Validated private setup saved to {args.output}; install with --config-dir and --port {port}.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, getpass.GetPassWarning) as error:
        raise SystemExit(str(error)) from None
