#!/usr/bin/env python3
"""Fund dedicated installed Signet/Devnet test custody; retain exact bytes.

Uses only the existing dedicated tester funding sources. Native target journals
must have been verified inside the guest; no native private keys are exported.
"""
import argparse,base64,json,os,subprocess,urllib.request,urllib.error
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('state');p.add_argument('--source-config',required=True);p.add_argument('--devnet-dir',required=True);p.add_argument('--funding-helper',required=True)
a=p.parse_args();state=Path(a.state).resolve(strict=True);assert state.stat().st_mode&0o077==0
source=json.loads(Path(a.source_config).read_text());targets=json.loads((state/'native-targets.json').read_text());manifest=json.loads((Path(a.devnet_dir)/'setup.json').read_text())
assert source['profile']=='L2LSignetDevnet' and targets['chain']=='L2LSignet'
assert manifest['mint']==source['mint']=='Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM'
assert [x['wallet'] for x in targets['wallets']]==['ecx-bridge-fresh-treasury','ecx-bridge-tester']
assert all(x['creationRequested'] and x['address'].startswith('tb1') for x in targets['wallets'])
def save(name,value):
 path=state/name;temp=path.with_suffix('.tmp')
 with temp.open('w') as file:
  os.chmod(temp,0o600);json.dump(value,file);file.flush();os.fsync(file.fileno())
 os.replace(temp,path);fd=os.open(state,os.O_RDONLY)
 try:os.fsync(fd)
 finally:os.close(fd)
def rpc(method,params=(),native=False,wallet=None):
 headers={'Content-Type':'application/json'}
 if native:
  assert wallet in (None,'ecx-bridge-tester')
  headers['Authorization']='Basic '+base64.b64encode(Path(source['nativeCookie']).read_bytes().strip()).decode()
  url=source['nativeRpc']+('/wallet/'+wallet if wallet else '')
 else:url=source['solanaRpc']
 req=urllib.request.Request(url,json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers)
 try:value=json.load(urllib.request.urlopen(req,timeout=25))
 except urllib.error.HTTPError as error:
  if not native:raise
  value=json.load(error)
 if value.get('error'):raise RuntimeError('Funding RPC refused '+method)
 return value['result']
assert rpc('getGenesisHash')=='EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG'
info=rpc('getblockchaininfo',native=True)
assert info['chain']=='signet' and not info['initialblockdownload'] and info['signet_challenge']==targets['signetChallenge']=='00148835832e28c816b7acd8fdb19772ab2199603a56'
if not (state/'funding.json').exists():
 assert rpc('getBalance',[manifest['payer'],{'commitment':'finalized'}])['value']>=60_000_000
 assert int(rpc('getTokenAccountBalance',[manifest['testerAta'],{'commitment':'finalized'}])['value']['amount'])>=1_000_000
 latest=rpc('getLatestBlockhash',[{'commitment':'finalized'}])['value']
 result=subprocess.run([a.funding_helper,a.devnet_dir,str(state),latest['blockhash'],str(latest['lastValidBlockHeight'])],capture_output=True,timeout=45)
 assert result.returncode==0,'Dedicated Devnet funding preparation failed'
funding=json.loads((state/'funding.json').read_text());sig=funding['signature']
status=rpc('getSignatureStatuses',[[sig],{'searchTransactionHistory':True}])['value'][0]
if status is None:
 assert rpc('getBlockHeight',[{'commitment':'finalized'}])<=funding['lastValidBlockHeight'],'Saved funding expired; inspect before replacement'
 assert rpc('sendTransaction',[funding['transaction'],{'encoding':'base64','preflightCommitment':'finalized','maxRetries':0}])==sig
else:assert status['err'] is None,'Saved funding failed; inspect before replacement'
transactions=[]
for target,amount in zip(targets['wallets'],['0.00020000','0.00012000']):
 name=target['wallet']+'-funding.json';path=state/name
 if not path.exists():
  save(name,{'address':target['address'],'amount':amount,'phase':'preparing'})
  funded=rpc('walletcreatefundedpsbt',[[],[{target['address']:amount}],0,{'lockUnspents':True,'replaceable':False,'minconf':1,'fee_rate':2},True],True,'ecx-bridge-tester')
  signed=rpc('walletprocesspsbt',[funded['psbt'],True,'ALL',True],True,'ecx-bridge-tester')
  final=rpc('finalizepsbt',[signed['psbt']],True);assert final['complete']
  decoded=rpc('decoderawtransaction',[final['hex']],True)
  save(name,{'address':target['address'],'amount':amount,'raw':final['hex'],'transaction':decoded['txid'],'phase':'possibly_broadcast'})
 saved=json.loads(path.read_text());assert saved['address']==target['address'] and saved['amount']==amount and 'raw' in saved,'Interrupted preparation: inspect locks before continuing'
 try:rpc('gettransaction',[saved['transaction']],True,'ecx-bridge-tester')
 except RuntimeError:assert rpc('sendrawtransaction',[saved['raw']],True)==saved['transaction']
 transactions.append(saved['transaction'])
print(json.dumps({'fundingSubmitted':True,'nativeTransactions':transactions,'solanaTransaction':sig,'newCustody':funding['custodyOwner'],'finalityVerified':False,'installedPayingAcceptance':False}))
