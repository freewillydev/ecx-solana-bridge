#!/usr/bin/env python3
"""Journal one real Devnet redemption and stage its native payout without sending.

Dedicated restored fixture only. Retains private exact deposit bytes and customer
capability. A failed run leaves the worker stopped; never deletes or resets work.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import urllib.request
import urllib.error

from InstalledTestTransport import InstalledTestTransport

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('state', type=Path)
parser.add_argument('--devnet-dir', type=Path, required=True)
parser.add_argument('--deposit-helper', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
os.umask(0o077)
state = args.state.resolve(strict=True)
cfg = json.loads((state / 'config.json').read_text())
assert cfg['deploymentId'] == 'fresh-treasury-acceptance'
assert cfg['profile'] == 'L2LSignetDevnet' and not cfg['backupRequired']
assert cfg['custodyOwner'] == '6vKbKHaYS393gQdjKysZFuyvn6cZ5p4vSwK2kMsQFuZY'
assert cfg['mint'] == 'Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM'
private = state / 'signed-native-recovery'
private.mkdir(mode=0o700, exist_ok=True)
private.chmod(0o700)
transport = InstalledTestTransport('restore', cfg)


def save(name, value):
    path = private / name
    pending = path.with_suffix('.pending')
    with pending.open('w') as output:
        pending.chmod(0o600)
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    pending.replace(path)
    fd = os.open(private, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def guest(*command, input=None):
    result = subprocess.run(['limactl', 'shell', 'restore', *command], input=input,
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('Dedicated guest action refused')
    return result.stdout.strip()


def rpc(method, params):
    request = urllib.request.Request(cfg['solanaRpc'],
        json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
        {'Content-Type': 'application/json'})
    for attempt in range(4):
        try:
            response = json.load(urllib.request.urlopen(request, timeout=25))
            break
        except urllib.error.HTTPError as error:
            if error.code not in [429, 503] or method not in [
                'getGenesisHash', 'getLatestBlockhash', 'getBlockHeight', 'getSignatureStatuses'
            ] or attempt == 3:
                raise
            delay = error.headers.get('Retry-After')
            seconds = 2 ** (attempt + 1) if delay is None else int(delay)
            if seconds < 1 or seconds > 15:
                raise RuntimeError('Unusable read-only RPC retry delay') from None
            time.sleep(seconds)
    if response.get('error'):
        raise RuntimeError('Devnet RPC refused')
    return response['result']


try:
    assert rpc('getGenesisHash', []) == 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG'
    guest('sudo', 'systemctl', 'start', 'ecx-bridge-node')
    if (private / 'order.json').exists():
        if (private / 'deposit.json').exists():
            command = guest('sudo', 'systemctl', 'show', 'ecx-bridge-worker', '--property=ExecStart', '--value')
            assert 'postgres-api' in command and 'test-worker' not in command
        transport.service('start')
        for _ in range(15):
            try:
                transport.api('/health', None, None, True)
                break
            except RuntimeError:
                time.sleep(1)
        else:
            raise RuntimeError('Restored observer API did not start')
    if not (private / 'order.json').exists():
        # Prepare instructions while normal test intake is enabled, before any
        # deposit is signed. An interrupted request reuses its saved idempotency.
        transport.preflight()
        transport.service('start')
        for _ in range(90):
            try:
                if transport.api('/health', None, None, True)['available']:
                    break
                transport.api('/resume', {}, None, True)
            except RuntimeError:
                pass
            time.sleep(2)
        else:
            raise RuntimeError('Dedicated test intake unavailable')
        if not (private / 'request.json').exists():
            address = json.loads((state / 'product/native-recipient.json').read_text())['address']
            save('request.json', dict(capability=secrets.token_hex(32), request=dict(
                direction='WrappedToNative', input='10000', recipient=address,
                refund='', sourceOwner=None, idempotencyKey='signed-native-recovery-1')))
        auth = json.loads((private / 'request.json').read_text())
        order = transport.api('/api/v1/orders', auth['request'], auth['capability'], False)
        assert order['quote'] == dict(gross='10000', fee='100', net='9900')
        save('order.json', order)
    auth = json.loads((private / 'request.json').read_text())
    order = json.loads((private / 'order.json').read_text())
    native = transport.rpc('getblockchaininfo', [], True, None)
    assert native['chain'] == 'signet' and native['signet_challenge'] == '00148835832e28c816b7acd8fdb19772ab2199603a56'
    route = '/api/v1/orders/' + order['orderId']
    if not (private / 'payment.json').exists():
        save('payment.json', transport.api(route + '/transaction', {}, auth['capability'], False))
    # Stop paying mode before the customer's transfer. This temporary test
    # override remains observation-only until the reviewed recovery resumes.
    transport.api('/pause', {'pauseReason': 'signed native recovery acceptance'}, None, True)
    transport.service('stop')
    guest('sudo', 'systemctl', 'stop', 'ecx-bridge-web', 'ecx-bridge-backup.timer', 'ecx-bridge-backup.service')
    override = '[Service]\nExecStart=\nExecStart=/opt/ecx-bridge/current/bin/ecx-bridge postgres-api /etc/ecx-bridge/worker.json\n'
    program = ("from pathlib import Path; "
        "p=Path('/etc/systemd/system/ecx-bridge-worker.service.d/zz-recovery-observer.conf'); "
        "data=" + repr(override) + "; "
        "assert not p.exists() or p.read_text()==data; p.write_text(data); p.chmod(0o644)")
    guest('sudo', 'python3', '-c', program)
    guest('sudo', 'systemctl', 'daemon-reload')
    transport.service('start')
    if not (private / 'deposit.json').exists():
        assert time.time() < order['deadline'], 'Unfunded quote expired; retain it for explicit review'
        payment = json.loads((private / 'payment.json').read_text())
        latest = rpc('getLatestBlockhash', [{'commitment': 'finalized'}])['value']
        manifest = json.loads((args.devnet_dir / 'setup.json').read_text())
        save('prepared.json', dict(chain='solana:devnet', orderId=order['orderId'],
            amount='10000', mint=cfg['mint'], custody=cfg['custodyAta'], owner=manifest['tester'],
            reference=payment['reference'], **latest))
        result = subprocess.run([str(args.deposit_helper.resolve(strict=True)),
            str(args.devnet_dir.resolve(strict=True)), str(private / 'prepared.json'),
            str(private / 'deposit.json'), str(state / 'config.json')],
            capture_output=True, timeout=45)
        assert result.returncode == 0, 'Deposit preparation refused'
    deposit = json.loads((private / 'deposit.json').read_text())
    status = rpc('getSignatureStatuses', [[deposit['signature']], {'searchTransactionHistory': True}])['value'][0]
    if status is None:
        assert time.time() < order['deadline'], 'Saved payment requires explicit expired-order review'
        assert rpc('getBlockHeight', [{'commitment': 'finalized'}]) <= deposit['lastValidBlockHeight']
        signature = rpc('sendTransaction', [deposit['transaction'], {'encoding': 'base64', 'skipPreflight': False, 'maxRetries': 0}])
        assert signature == deposit['signature']
    print(json.dumps(dict(depositJournaled=True, observerOnly=True)), flush=True)
    for _ in range(120):
        view = transport.api(route, None, auth['capability'], False)
        if view['status'] in ['Ready', 'Paying']:
            break
        assert view['status'] in ['AwaitingDeposit', 'Provisioning'], 'Deposit requires explicit review'
        time.sleep(2)
    else:
        raise RuntimeError('Real deposit has not become eligible')
    finalized = rpc('getSignatureStatuses', [[deposit['signature']], {'searchTransactionHistory': True}])['value'][0]
    assert finalized and finalized['err'] is None and finalized['confirmationStatus'] == 'finalized'
    transport.service('stop')
    query = "SELECT json_build_object('attempts',(SELECT count(*) FROM attempts a JOIN obligations o ON o.id=a.intent_id WHERE o.order_id='" + order['orderId'] + "'),'intent',(SELECT id FROM obligations WHERE order_id='" + order['orderId'] + "' AND kind='conversion'));"
    assert len(order['orderId']) == 64 and all(x in '0123456789abcdef' for x in order['orderId'])
    work = transport.financial(query)
    mode = 'stage-signed' if work['attempts'] == 0 else 'verify-signed'
    assert work['attempts'] in [0, 1] and work['intent']
    command = ['sudo', 'runuser', '-u', 'ecx-worker', '--', 'env',
        'PGHOST=/run/ecx-postgres', 'PGPORT=29436', 'PGDATABASE=ecx_bridge', 'PGUSER=ecx_worker',
        'ECX_WORKER_FENCE_DIR=/var/lib/ecx-bridge/fence',
        '/opt/ecx-bridge-acceptance/native-signed-driver', mode, '/etc/ecx-bridge/worker.json', work['intent']]
    result = json.loads(guest(*command))
    save('native-stage.json', result)
    replay = command.copy()
    replay[-3] = 'verify-signed'
    verified = json.loads(guest(*replay))
    save('native-replay.json', verified)
    report = dict(networks=['actual L2L Signet', 'actual Solana Devnet'],
        orderId=order['orderId'], nativePayout=verified['transaction'],
        nativeSignedBytesSha256=verified['savedBytesSha256'], quote=order['quote'],
        customerDepositSignature=deposit['signature'], signedNativeAttemptDurable=True,
        replayWithoutSignerOrRpcPassed=True, observerOnlyOverrideRetained=True,
        nativeBroadcast=False, workerStopped=True, interruptedHostRestoreVerified=False)
    args.report.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report), flush=True)
finally:
    transport.service('stop')
