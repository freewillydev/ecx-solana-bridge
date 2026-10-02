#!/usr/bin/env python3
"""Verify a completed dedicated real-chain recovery without signing or sending.

Uses the private staging journal and actual installed ledger, plus both finalized
Solana providers. Does not start services, resume, approve retries or create work.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
from urllib.parse import urlsplit
from InstalledTestTransport import InstalledTestTransport

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('state', type=Path)
parser.add_argument('--vm', required=True)
parser.add_argument('--run-id', required=True)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
assert re.fullmatch(r'[a-z][a-z0-9-]{0,62}', args.run_id)
state = args.state.resolve(strict=True)
cfg = json.loads((state / 'config.json').read_text())
assert cfg['profile'] == 'L2LSignetDevnet'
assert cfg['deploymentId'] == 'fresh-treasury-acceptance'
private = state / args.run_id
order = json.loads((private / 'order.json').read_text())
auth = json.loads((private / 'request.json').read_text())
original = json.loads((private / 'solana-replay.json').read_text())
transport = InstalledTestTransport(args.vm, cfg)
oid = order['orderId']
assert re.fullmatch('[0-9a-f]{64}', oid)
view = transport.api('/api/v1/orders/' + oid, None, auth['capability'], False)
assert view['status'] == 'Paid' and view['quote'] == {'gross': '10000', 'fee': '100', 'net': '9900'}
tx = view['payoutTx']
assert re.fullmatch('[1-9A-HJ-NP-Za-km-z]{64,100}', tx)
query = "SELECT json_build_object('sequence',(SELECT critical_sequence FROM deployment),'attempts',(SELECT json_agg(json_build_object('txid',txid,'state',state,'generation',preparation_generation,'bytes',signed_bytes)) FROM attempts WHERE intent_id='convert:" + oid + "'),'unbalanced',(SELECT count(*) FROM (SELECT event_id,asset FROM postings GROUP BY event_id,asset HAVING sum(delta)<>0) x),'feeHolds',(SELECT count(*) FROM fee_reservations WHERE intent_id='convert:" + oid + "' AND released=0),'reservations',(SELECT count(*) FROM reservations WHERE order_id='" + oid + "' AND phase<>'released'),'earned',(SELECT coalesce(sum(delta),0) FROM postings WHERE event_id='settlement:" + tx + "' AND asset='Native' AND account='earned'));"
financial = transport.financial(query)
for attempt in financial['attempts']:
    attempt['savedBytesSha256'] = hashlib.sha256(attempt.pop('bytes').encode()).hexdigest()
assert financial['unbalanced'] == financial['feeHolds'] == financial['reservations'] == 0
assert financial['earned'] == 100
assert len(financial['attempts']) == 2
old = next(a for a in financial['attempts'] if a['generation'] == 0)
new = next(a for a in financial['attempts'] if a['generation'] == 1)
assert old['txid'] == original['transaction'] and old['savedBytesSha256'] == original['savedBytesSha256']
assert old['state'] == 'review' and new['state'] == 'settled' and new['txid'] == tx
assert urlsplit(cfg["solanaRpc"]).hostname != urlsplit(cfg["solanaVerifierRpc"]).hostname
assert all(urlsplit(cfg[k]).scheme == "https" for k in ("solanaRpc", "solanaVerifierRpc"))
read_rpc = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/check-token-policy"))["call"]
providers = {}
for label, endpoint in [('primary', cfg['solanaRpc']), ('independent', cfg['solanaVerifierRpc'])]:
    assert read_rpc(endpoint, 'getGenesisHash', []) == 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG'
    receipt = read_rpc(endpoint, 'getTransaction', [tx, {'encoding': 'jsonParsed', 'commitment': 'finalized', 'maxSupportedTransactionVersion': 0}])
    assert receipt and receipt['meta']['err'] is None
    pre = {x['accountIndex']: x for x in receipt['meta']['preTokenBalances']}
    post = {x['accountIndex']: x for x in receipt['meta']['postTokenBalances']}
    deltas = {}
    for index in set(pre) | set(post):
        row = post.get(index, pre.get(index))
        assert row['mint'] == cfg['mint'] and row['uiTokenAmount']['decimals'] == 8
        before = int(pre[index]['uiTokenAmount']['amount']) if index in pre else 0
        after = int(post[index]['uiTokenAmount']['amount']) if index in post else 0
        deltas[row['owner']] = deltas.get(row['owner'], 0) + after - before
    assert deltas[cfg['custodyOwner']] == -9900
    assert deltas[auth['request']['recipient']] == 9900
    providers[label] = dict(finalizedSlot=receipt['slot'], networkFeeLamports=receipt['meta']['fee'], custodyDelta=-9900, customerDelta=9900)
assert providers['primary'] == providers['independent']
# Re-query and hash signed bytes again: read-only acceptance must preserve work.
after = transport.financial(query)
for attempt in after['attempts']:
    attempt['savedBytesSha256'] = hashlib.sha256(attempt.pop('bytes').encode()).hexdigest()
assert after == financial
report = dict(orderId=oid, recoveredPaymentPaid=True, originalSignedBytesPreserved=True,
    oneSettledReplacement=True, feeBaseUnits=100, providers=providers,
    criticalSequence=financial['sequence'], financialStateUnchanged=True, signedOrSent=False)
args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
