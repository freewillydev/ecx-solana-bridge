#!/usr/bin/env python3
"""Prepare new, empty native wallets on the dedicated installed Signet fixture.

Run as root in that guest. No keys leave the node, no funding is sent, and no
bridge configuration/ledger is changed. Retain the journal before proceeding.
"""
import base64
import json
import os
from pathlib import Path
import urllib.error
import urllib.request

assert os.geteuid() == 0
cfg = json.loads(Path('/etc/ecx-bridge/worker.json').read_text())
assert cfg['profile'] == 'L2LSignetDevnet' and cfg['deploymentId'] == 'ecx-wizard-acceptance'
state = Path('/var/lib/ecx-bridge/private/installed-paying-stage')
state.mkdir(mode=0o700, exist_ok=True)
assert state.stat().st_mode & 0o077 == 0 and not state.is_symlink()


def save(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as file:
        os.chmod(temporary, 0o600)
        json.dump(value, file)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)
    descriptor = os.open(state, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def rpc(method, params=(), wallet=None):
    authorization = 'Basic ' + base64.b64encode(Path(cfg['nativeCookie']).read_bytes().strip()).decode()
    url = cfg['nativeRpc'] + ('/wallet/' + wallet if wallet else '')
    request = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1,
        'method': method, 'params': params}).encode(),
        {'Content-Type': 'application/json', 'Authorization': authorization})
    try:
        result = json.load(urllib.request.urlopen(request, timeout=25))
    except urllib.error.HTTPError as error:
        result = json.load(error)
    assert not result.get('error'), 'Dedicated native setup RPC refused: ' + method
    return result['result']


info = rpc('getblockchaininfo')
assert info['chain'] == 'signet' and not info['initialblockdownload']
assert info['signet_challenge'] == '00148835832e28c816b7acd8fdb19772ab2199603a56'
for wallet in ['ecx-bridge-fresh-treasury', 'ecx-bridge-tester']:
    journal = state / (wallet + '.json')
    known = {entry['name'] for entry in rpc('listwalletdir')['wallets']}
    if not journal.exists():
        assert wallet not in known, 'Unjournaled wallet exists; inspect before adoption'
        save(journal, {'wallet': wallet, 'creationRequested': True,
            'checkpointHeight': info['blocks'], 'checkpointHash': info['bestblockhash']})
    value = json.loads(journal.read_text())
    assert value['wallet'] == wallet and value['creationRequested']
    if wallet not in known:
        rpc('createwallet', [wallet, False, False, '', False, True, True])
    elif wallet not in rpc('listwallets'):
        rpc('loadwallet', [wallet, True])
    if 'address' not in value:
        value['address'] = rpc('getnewaddress', ['installed-product-funding', 'bech32'], wallet)
        save(journal, value)
    assert value['address'].startswith('tb1')
print(json.dumps({'actualL2LSignet': True, 'newWalletJournals': 2,
    'fundingSent': False, 'keysExported': False, 'bridgeLedgerChanged': False}))
