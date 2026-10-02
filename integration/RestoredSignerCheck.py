#!/usr/bin/env python3
"""Reproduce settled saved signatures after a reviewed dedicated test handoff.

No broadcast, new transaction parameters, ledger write or customer intent. Output
contains only comparison results. Run as root with the paying worker stopped.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--settled-solana-fixture', action='store_true')
args = parser.parse_args()
assert os.geteuid() == 0
assert subprocess.run(['systemctl','is-active','--quiet','ecx-bridge-worker']).returncode != 0
cfg = json.loads(Path('/etc/ecx-bridge/worker.json').read_text())
assert cfg['profile'] == 'L2LSignetDevnet' and cfg['deploymentId'] == 'fresh-treasury-acceptance'
assert cfg['custodyOwner'] == '6vKbKHaYS393gQdjKysZFuyvn6cZ5p4vSwK2kMsQFuZY'
env = dict(os.environ, PGHOST='/run/ecx-postgres', PGPORT='29436', PGDATABASE='ecx_bridge')

def sql(query):
    result = subprocess.run(['runuser','-u','postgres','--','psql','-XqAt',
        '-v','ON_ERROR_STOP=1','-c',query],env=env,capture_output=True,text=True,timeout=30)
    assert result.returncode == 0, 'Private signature check query failed'
    return result.stdout.strip()

assert sql('SELECT paused FROM deployment;') == '1'
if args.settled_solana_fixture:
    assert sql('SELECT count(*) FROM orders;') == '6'
    assert sql("SELECT count(*) FROM orders WHERE status='Paid';") == '4'
    assert sql("SELECT count(*) FROM orders WHERE status='ExpiredUnfunded';") == '2'
    assert sql('SELECT critical_sequence FROM deployment;') == '19'
else:
    assert sql("SELECT count(*) FROM orders WHERE status <> 'Paid';") == '0'
rows = sql("SELECT json_build_object('chain',i.chain,'draft',p.draft_json,'bytes',a.signed_bytes,'txid',a.txid)::text FROM preparations p JOIN intents i ON i.id=p.intent_id JOIN attempts a ON a.intent_id=i.id AND a.preparation_generation=p.generation WHERE a.state='settled';").splitlines()
assert len(rows) == (4 if args.settled_solana_fixture else 2)
sequence = sql('SELECT critical_sequence FROM deployment;')
verified = []
for encoded in rows:
    row = json.loads(encoded)
    draft = json.loads(row['draft'])
    if row['chain'] == 'Native':
        headers = {'Content-Type':'application/json','Authorization':'Basic '+base64.b64encode(Path(cfg['nativeCookie']).read_bytes().strip()).decode()}
        def rpc(method, params):
            request = urllib.request.Request(cfg['nativeRpc']+'/wallet/'+cfg['nativeWallet'],
                json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers)
            response = json.load(urllib.request.urlopen(request,timeout=25))
            assert not response.get('error'), 'Restored native signing refused'
            return response['result']
        signed = rpc('walletprocesspsbt',[draft['draftPsbt'],True,'ALL',True])
        final = rpc('finalizepsbt',[signed['psbt']])
        assert final['complete'] and final['hex'] == row['bytes'], 'Restored native signature differs'
    else:
        assert row['chain'] == 'Solana' and draft['verb'] == 'payout'
        result = subprocess.run(['runuser','-u','ecx-worker','--',cfg['helperPath'],
            '--config',cfg['helperConfig']],input=json.dumps(draft),capture_output=True,text=True,timeout=30)
        assert result.returncode == 0, 'Restored isolated helper refused'
        reply = json.loads(result.stdout)
        assert reply['transaction'] == row['bytes'] and reply['signature'] == row['txid'], 'Restored Solana signature differs'
    verified.append(row['chain'])
assert sorted(verified) == (['Native','Native','Solana','Solana'] if args.settled_solana_fixture else ['Native','Solana'])
assert sql('SELECT critical_sequence FROM deployment;') == sequence
report = dict(restoredNativeSignerReproducesOriginalBytes=True,
    restoredSolanaSignerReproducesOriginalBytesAndSignature=True,
    onlySettledSavedDraftsUsed=True, reproducedSavedAttempts=len(verified), newEconomicIntent=False, broadcast=False,
    criticalSequenceUnchanged=True, workerStopped=True)
Path('/home/lukekensik.guest/private-handoff/signer-evidence.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
