#!/usr/bin/env python3
"""One idempotent public-L2L-Signet PSBT probe; never a production bridge.

Uses two dedicated test wallets and a persisted possibly-sent transaction.
It refuses other network identities or wallet names. No secrets are printed.
"""
import base64
import decimal
import json
import os
from pathlib import Path
import sys
import urllib.request

if len(sys.argv) != 3:
    raise SystemExit('usage: native-smoke.py PRIVATE_SIGNET_DATADIR PRIVATE_EVIDENCE_PATH')
datadir, output = map(Path, sys.argv[1:])
if not datadir.is_absolute() or not output.is_absolute():
    raise SystemExit('absolute paths required')
secret = (datadir / 'signet/.cookie').read_bytes().strip()
headers = {'Content-Type': 'application/json', 'Authorization': 'Basic '+base64.b64encode(secret).decode()}

def rpc(method, params=(), wallet=None):
    assert wallet in (None, 'ecx-bridge-test', 'ecx-bridge-tester')
    url='http://127.0.0.1:29432'+('/wallet/'+wallet if wallet else '')
    req=urllib.request.Request(url, json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), headers)
    with urllib.request.urlopen(req, timeout=15) as response:
        result=json.loads(response.read(1048576), parse_float=decimal.Decimal)
    if result.get('error'): raise RuntimeError('RPC error: '+method)
    return result['result']

def save(record):
    output.parent.mkdir(parents=True, exist_ok=True)
    temp=output.with_suffix('.tmp')
    with open(temp,'w') as f:
        os.chmod(temp,0o600)
        json.dump(record,f,indent=2,default=str);f.flush();os.fsync(f.fileno())
    os.replace(temp,output)
    fd=os.open(output.parent,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)

info=rpc('getblockchaininfo')
assert info['chain']=='signet' and info['signet_challenge']=='00148835832e28c816b7acd8fdb19772ab2199603a56'
assert not info['initialblockdownload']
assert rpc('getblockhash',[16000])=='00000047dcc9d64b767687d6a5e610c411dd85db5460e824c0f7284f5514bc47'
if output.exists():
    record=json.loads(output.read_text())
    if 'raw' not in record:raise SystemExit('Preparation was interrupted: inspect wallet locks before retrying')
else:
    recipient=rpc('getnewaddress',['psbt-smoke','bech32'],'ecx-bridge-tester')
    save({'phase':'preparing','recipient':recipient})
    funded=rpc('walletcreatefundedpsbt',[[],[{recipient:'0.00100000'}],0,{'lockUnspents':True,'replaceable':False,'minconf':1,'fee_rate':2},True],'ecx-bridge-test')
    fee=decimal.Decimal(str(funded['fee']))*100000000
    assert fee==fee.to_integral_value() and 0<fee<=1000
    signed=rpc('walletprocesspsbt',[funded['psbt'],True,'ALL',True],'ecx-bridge-test')
    assert signed['complete']
    final=rpc('finalizepsbt',[signed['psbt']])
    assert final['complete']
    decoded=rpc('decoderawtransaction',[final['hex']])
    assert decoded['locktime']!=499999999
    total_recipient=0
    for item in decoded['vout']:
        address=item['scriptPubKey']['address']
        value=decimal.Decimal(str(item['value']))*100000000
        assert value==value.to_integral_value()
        if address==recipient:total_recipient+=int(value)
        else:assert rpc('getaddressinfo',[address],'ecx-bridge-test')['ismine']
    assert total_recipient==100000 and len(decoded['vout'])<=2
    assert all(v['sequence']==4294967294 for v in decoded['vin'])
    record={'network':'public-l2l-signet','checkpointHeight':16000,'checkpointHash':rpc('getblockhash',[16000]),'recipient':recipient,'amountUnits':'100000','feeUnits':str(int(fee)),'txid':decoded['txid'],'raw':final['hex'],'inputs':decoded['vin'],'phase':'possibly_broadcast'}
    save(record)
# An interrupted send never creates another transaction: only these exact bytes.
try:
    known=rpc('gettransaction',[record['txid']],'ecx-bridge-test')
except Exception:
    sent=rpc('sendrawtransaction',[record['raw']])
    assert sent==record['txid']
    known=rpc('gettransaction',[record['txid']],'ecx-bridge-test')
record['confirmations']=known['confirmations'];record['phase']='confirmed' if known['confirmations']>=1 else 'submitted'
save(record)
print(json.dumps({k:v for k,v in record.items() if k not in ('raw','inputs')},indent=2))
