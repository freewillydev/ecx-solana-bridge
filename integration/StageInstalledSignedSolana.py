#!/usr/bin/env python3
"""Journal one real Signet wrap and stage its Solana payout without sending.

Dedicated installed Signet/Devnet fixture only. Retains private exact deposit bytes and customer
capability. A failed run leaves the worker stopped; never deletes or resets work.
"""
import argparse
import json
import os
import re
from pathlib import Path
import secrets
import subprocess
import time

from InstalledTestTransport import InstalledTestTransport

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('state', type=Path)
parser.add_argument('--vm', required=True, help='Active dedicated test guest; retired sources are refused')
parser.add_argument('--run-id', required=True, help='Distinct durable journal and order identity')
parser.add_argument('--devnet-dir', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
assert re.fullmatch(r'[a-z][a-z0-9-]{0,62}', args.vm)
assert args.vm not in ('inflight', 'restore', 'pg-install'), 'Retired source guest refused'
assert re.fullmatch(r'[a-z][a-z0-9-]{0,62}', args.run_id)
os.umask(0o077)
state = args.state.resolve(strict=True)
cfg = json.loads((state / 'config.json').read_text())
assert cfg['deploymentId'] == 'fresh-treasury-acceptance'
assert cfg['profile'] == 'L2LSignetDevnet' and not cfg['backupRequired']
assert cfg['custodyOwner'] == '6vKbKHaYS393gQdjKysZFuyvn6cZ5p4vSwK2kMsQFuZY'
assert cfg['mint'] == 'Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM'
assert cfg['solanaVerifierRpc'] == 'https://solana-devnet.api.onfinality.io/public'
private = state / args.run_id
private.mkdir(mode=0o700, exist_ok=True)
private.chmod(0o700)
transport = InstalledTestTransport(args.vm, cfg)


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
    result = subprocess.run(['limactl', 'shell', args.vm, *command], input=input,
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        codes = re.findall(r'BridgeError "([a-z0-9_-]{1,100})"', result.stderr)
        raise RuntimeError('Dedicated guest action refused' + (': ' + codes[-1] if codes else ''))
    return result.stdout.strip()



try:
    # Qualify the actual guest's egress before any order or wallet mutation.
    # Host-only preflight does not prove this installed server can reach RPC.
    connectivity = guest('sudo', 'python3', '-c', r"""
import json,urllib.request
from pathlib import Path
cfg=json.loads(Path('/etc/ecx-bridge/worker.json').read_text())
assert cfg['profile']=='L2LSignetDevnet'
assert cfg['solanaVerifierRpc']=='https://solana-devnet.api.onfinality.io/public'
checks = {}
for label, endpoint in [('primary',cfg['solanaRpc']),('verifier',cfg['solanaVerifierRpc'])]:
    try:
        req=urllib.request.Request(endpoint,json.dumps({'jsonrpc':'2.0','id':1,'method':'getGenesisHash','params':[]}).encode(),{'Content-Type':'application/json'})
        result=json.load(urllib.request.urlopen(req,timeout=25))
        checks[label] = 'ready' if result.get('id')==1 and result.get('result')=='EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG' else 'identity_mismatch'
    except (OSError,ValueError):
        checks[label] = 'unavailable'
print(json.dumps(checks))
""")
    checks = json.loads(connectivity)
    assert set(checks) == {'primary', 'verifier'}
    if any(value != 'ready' for value in checks.values()):
        raise RuntimeError('Real Solana provider preflight refused: ' + ', '.join(key + '=' + value for key, value in checks.items()))
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
            manifest = json.loads((args.devnet_dir / 'setup.json').read_text())
            assert manifest['tester'] == 'HcctYHWCfLGrE5WigGKHg5hR6Q1P1Gntb5PYQWSQFHXg'
            address = json.loads((state / 'product/native-recipient.json').read_text())['address']
            save('request.json', dict(capability=secrets.token_hex(32), request=dict(
                direction='NativeToWrapped', input='10000', recipient=manifest['tester'],
                refund=address, sourceOwner=None, idempotencyKey=args.run_id)))
        auth = json.loads((private / 'request.json').read_text())
        order = transport.api('/api/v1/orders', auth['request'], auth['capability'], False)
        assert order['quote'] == dict(gross='10000', fee='100', net='9900')
        save('order.json', order)
    auth = json.loads((private / 'request.json').read_text())
    order = json.loads((private / 'order.json').read_text())
    native = transport.rpc('getblockchaininfo', [], True, None)
    assert native['chain'] == 'signet' and native['signet_challenge'] == '00148835832e28c816b7acd8fdb19772ab2199603a56'
    route = '/api/v1/orders/' + order['orderId']
    # Stop paying mode before the customer's transfer. This temporary test
    # override remains observation-only until the reviewed recovery resumes.
    transport.api('/pause', {'pauseReason': 'signed Solana recovery acceptance'}, None, True)
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
        assert time.time() < order['deadline'], 'Unfunded quote expired; retain it for review'
        destination = order['depositInstruction']
        assert isinstance(destination, str) and destination.startswith('tb1')
        save('deposit.json', dict(phase='preparing', address=destination))
        funded = transport.rpc('walletcreatefundedpsbt', [[], [{destination: '0.00010000'}], 0,
            {'lockUnspents': True, 'replaceable': False, 'minconf': 1, 'fee_rate': 2}, True], True, 'ecx-bridge-tester')
        signed = transport.rpc('walletprocesspsbt', [funded['psbt'], True, 'ALL', True], True, 'ecx-bridge-tester')
        final = transport.rpc('finalizepsbt', [signed['psbt']], True, None)
        assert final['complete']
        decoded = transport.rpc('decoderawtransaction', [final['hex']], True, None)
        save('deposit.json', dict(phase='possibly_broadcast', transaction=decoded['txid'], raw=final['hex']))
    deposit = json.loads((private / 'deposit.json').read_text())
    assert 'raw' in deposit, 'Interrupted native preparation requires inspection'
    try:
        transport.rpc('gettransaction', [deposit['transaction']], True, 'ecx-bridge-tester')
    except RuntimeError:
        assert time.time() < order['deadline'], 'Expired order requires review before broadcast'
        assert transport.rpc('sendrawtransaction', [deposit['raw']], True, None) == deposit['transaction']
    print(json.dumps(dict(depositJournaled=True, observerOnly=True)), flush=True)
    for _ in range(900):
        view = transport.api(route, None, auth['capability'], False)
        if view['status'] in ['Ready', 'Paying']:
            break
        assert view['status'] in ['AwaitingDeposit', 'Provisioning'], 'Deposit requires explicit review'
        time.sleep(2)
    else:
        raise RuntimeError('Real deposit has not become eligible')
    confirmed = transport.rpc('gettransaction', [deposit['transaction']], True, 'ecx-bridge-tester')
    assert confirmed['confirmations'] >= cfg['nativeConfirmations']
    transport.service('stop')
    query = "SELECT json_build_object('attempts',(SELECT count(*) FROM attempts a JOIN obligations o ON o.id=a.intent_id WHERE o.order_id='" + order['orderId'] + "'),'intent',(SELECT id FROM obligations WHERE order_id='" + order['orderId'] + "' AND kind='conversion'));"
    assert len(order['orderId']) == 64 and all(x in '0123456789abcdef' for x in order['orderId'])
    work = transport.financial(query)
    mode = 'stage-solana-signed' if work['attempts'] == 0 else 'verify-solana-signed'
    assert work['attempts'] in [0, 1] and work['intent']
    command = ['sudo', 'runuser', '-u', 'ecx-worker', '--', 'env',
        'PGHOST=/run/ecx-postgres', 'PGPORT=29436', 'PGDATABASE=ecx_bridge', 'PGUSER=ecx_worker',
        'ECX_WORKER_FENCE_DIR=/var/lib/ecx-bridge/fence',
        '/opt/ecx-bridge-acceptance/solana-signed-driver', mode, '/etc/ecx-bridge/worker.json', work['intent']]
    result = json.loads(guest(*command))
    save('solana-stage.json', result)
    replay = command.copy()
    replay[-3] = 'verify-solana-signed'
    verified = json.loads(guest(*replay))
    save('solana-replay.json', verified)
    report = dict(networks=['actual L2L Signet', 'actual Solana Devnet'],
        orderId=order['orderId'], solanaPayout=verified['transaction'],
        solanaSignedBytesSha256=verified['savedBytesSha256'], quote=order['quote'],
        customerDepositTransaction=deposit['transaction'], signedSolanaAttemptDurable=True,
        replayWithoutSignerOrRpcPassed=True, observerOnlyOverrideRetained=True,
        solanaBroadcast=False, workerStopped=True, interruptedHostRestoreVerified=False)
    args.report.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report), flush=True)
finally:
    transport.service('stop')
