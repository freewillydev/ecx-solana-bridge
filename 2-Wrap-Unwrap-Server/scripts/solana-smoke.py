#!/usr/bin/env python3
"""Manual SDK/adapter acceptance on public Devnet; never a bridge order.

Uses the existing setup manifest and two fixed three-unit transfers. An existing
attempt is reconciled, never replaced or automatically signed a second time.
Private test keys remain in the custody helper. No mainnet endpoint is accepted.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

RPC = "https://api.devnet.solana.com"


def rpc(method, params):
    request = urllib.request.Request(
        RPC,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        raw = response.read(1_048_577)
    if len(raw) > 1_048_576:
        raise RuntimeError("oversized Devnet response")
    result = json.loads(raw)
    if "error" in result:
        raise RuntimeError(f"Devnet {method} error {result['error']['code']}")
    return result["result"]


def save_new(path, value):
    # Refuse overwriting an earlier attempt. Both file and directory are synced
    # before any usable signature can be given to a network service.
    raw = (json.dumps(value, indent=2) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def run_probe(*args):
    result = subprocess.run(args, check=True, capture_output=True, timeout=90)
    if len(result.stdout) > 32768:
        raise RuntimeError("oversized probe result")
    return json.loads(result.stdout)


def main():
    if len(sys.argv) not in (4, 5) or (len(sys.argv) == 5 and sys.argv[4] != "--replace-expired-existing"):
        raise SystemExit("usage: solana-smoke.py CONFIG EXISTING_PRIVATE_DEVNET_DIR COMPILED_SOLANA_PROBE [--replace-expired-existing]")
    config_path, state, probe = map(Path, sys.argv[1:4])
    if not all(p.is_absolute() for p in (config_path, state, probe)):
        raise RuntimeError("absolute paths required")
    config = json.loads(config_path.read_text())
    manifest = json.loads((state / "setup.json").read_text())
    if (config["profile"] != "L2LSignetDevnet" or config["solanaRpc"] != RPC
            or not manifest["completed"] or manifest["network"] != "solana:devnet"
            or config["mint"] != manifest["mint"]
            or config["custodyOwner"] != manifest["custody"]
            or config["custodyAta"] != manifest["custodyAta"]):
        raise RuntimeError("dedicated public-Devnet setup required")
    if rpc("getGenesisHash", []) != "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG":
        raise RuntimeError("wrong genesis")
    if not (0 < int(config["maxSolFee"]) <= 10000 and int(config["maxSolAccountRent"]) <= 2100000):
        raise RuntimeError("probe exceeds fixed test operating budget")
    os.chmod(state, 0o700)
    existing_label = "devnet-three-existing"
    replaces = None
    if len(sys.argv) == 5:
        original = json.loads((state / "devnet-three-existing.attempt.json").read_text())["signed"]
        decision = json.loads((state / "devnet-three-existing.expired-absence.json").read_text())
        replaces = original["signedSolanaReply"]["signature"]
        recent = original["signedSolanaPlan"]["solPlanRecent"]
        if (decision["expiredSignature"] != replaces or decision["transaction"] is not None
                or decision["status"]["value"] != [None] or decision["invalidBlockhash"]["value"] is not False
                or decision["finalizedEpochContext"]["blockHeight"] <= recent["recentLastValidHeight"]):
            raise RuntimeError("conclusive recorded expiry/history decision required")
        for history in (decision["custodyHistoryThroughSetupAnchor"], decision["ownerHistoryThroughSetupAnchor"]):
            ids = [row["signature"] for row in history]
            if manifest["setupSignature"] not in ids or replaces in ids:
                raise RuntimeError("expired attempt history incomplete")
        current = rpc("getSignatureStatuses", [[replaces], {"searchTransactionHistory": True}])
        if current["value"] != [None]:
            raise RuntimeError("old attempt has new evidence; inspect before replacement")
        existing_label += "-retry-1"
    for label, recipient in [(existing_label, manifest["tester"]),
                             ("devnet-three-new", manifest["payer"])]:
        attempt_path = state / f"{label}.attempt.json"
        if attempt_path.exists():
            record = json.loads(attempt_path.read_text())
        else:
            signed = run_probe(str(probe), "prepare", str(config_path), recipient, label)
            reply = signed["signedSolanaReply"]
            plan = signed["signedSolanaPlan"]
            if plan["solPlanRecipient"] != recipient or plan["solPlanAmount"] != "3":
                raise RuntimeError("unexpected probe payout")
            record = {"state": "possibly_broadcast", "label": label, "signed": signed,
                      "replacesExpired": replaces if recipient == manifest["tester"] else None}
            save_new(attempt_path, record)
            height = rpc("getBlockHeight", [{"commitment": "confirmed"}])
            if height + 10 >= plan["solPlanRecent"]["recentLastValidHeight"]:
                raise RuntimeError("saved attempt too near expiry; requires reconciliation")
            actual = rpc("sendTransaction", [reply["transaction"], {
                "encoding": "base64", "skipPreflight": False,
                "preflightCommitment": "confirmed", "maxRetries": 3}])
            if actual != reply["signature"]:
                raise RuntimeError("unexpected RPC signature; reconcile saved attempt")
            print(json.dumps({"submitted": actual, "label": label}), flush=True)

        signed = record["signed"]
        if (record["label"] != label or signed["signedSolanaPlan"]["solPlanRecipient"] != recipient
                or signed["signedSolanaPlan"]["solPlanAmount"] != "3"):
            raise RuntimeError("saved attempt does not match fixed probe")
        signature = signed["signedSolanaReply"]["signature"]
        for _ in range(12):
            status = rpc("getSignatureStatuses", [[signature], {"searchTransactionHistory": True}])["value"][0]
            if status and status["confirmationStatus"] == "finalized":
                break
            if status is None:
                height = rpc("getBlockHeight", [{"commitment": "confirmed"}])
                if height < signed["signedSolanaPlan"]["solPlanRecent"]["recentLastValidHeight"]:
                    actual = rpc("sendTransaction", [signed["signedSolanaReply"]["transaction"], {
                        "encoding": "base64", "skipPreflight": False,
                        "preflightCommitment": "confirmed", "maxRetries": 3}])
                    if actual != signature:
                        raise RuntimeError("rebroadcast signature changed; reconcile saved attempt")
            time.sleep(5)
        else:
            raise RuntimeError("saved attempt still requires reconciliation; no replacement signed")
        proof = rpc("getTransaction", [signature, {
            "commitment": "finalized", "encoding": "json", "maxSupportedTransactionVersion": 0}])
        wire = rpc("getTransaction", [signature, {
            "commitment": "finalized", "encoding": "base64", "maxSupportedTransactionVersion": 0}])
        if not proof or not wire or wire["slot"] != proof["slot"]:
            raise RuntimeError("finalized transaction evidence missing")
        if base64.b64decode(wire["transaction"][0], validate=True) != base64.b64decode(signed["signedSolanaReply"]["transaction"], validate=True):
            raise RuntimeError("finalized wire bytes differ from journal")
        signed_path = state / f"{label}.signed.json"
        proof_path = state / f"{label}.proof.json"
        if not signed_path.exists():
            save_new(signed_path, signed)
        if not proof_path.exists():
            save_new(proof_path, proof)
        outcome = run_probe(str(probe), "verify", str(config_path), str(signed_path), str(proof_path))
        if not outcome["outcomeSucceeded"] or status["err"] is not None:
            raise RuntimeError("finalized probe failed; retain evidence for review")
        report = {"network": "public Solana Devnet", "label": label,
                  "signature": signature, "recipient": recipient, "units": "3",
                  "journalBeforeBroadcast": True, "finalizedBytesMatch": True,
                  "scope": "Standalone adapter probe, not a ledger-driven bridge order",
                  "outcome": outcome, "signed": signed, "transaction": proof}
        evidence_path = state / f"{label}.evidence.json"
        if not evidence_path.exists():
            save_new(evidence_path, report)
        print(json.dumps({"label": label, "signature": signature, "outcome": outcome}), flush=True)


if __name__ == "__main__":
    main()
