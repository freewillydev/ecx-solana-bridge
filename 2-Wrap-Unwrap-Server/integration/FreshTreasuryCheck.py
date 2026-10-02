#!/usr/bin/env python3
"""Real Signet/Devnet fresh-ledger funding acceptance, with durable test state.

Uses a new dedicated custody key and native wallet, existing Devnet test mint,
existing dedicated test funding keys/wallet. Never copies existing custody keys.
No customer payouts; final worker stays paused and stops. Re-runs reconcile saved
funding bytes instead of creating another funding transaction.
"""
import argparse,base64,http.client,json,os,socket,subprocess,time,urllib.request,urllib.error
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('config');p.add_argument('--binary',required=True)
p.add_argument('--devnet-dir',required=True);p.add_argument('--funding-helper',required=True)
p.add_argument('--state',required=True);p.add_argument('--report',required=True)
a=p.parse_args();root=Path(__file__).resolve().parents[1]
state=Path(a.state).resolve();state.mkdir(mode=0o700,parents=True,exist_ok=True);state.chmod(0o700)
binary=str(Path(a.binary).resolve(strict=True));source=json.loads(Path(a.config).read_text())
assert source['profile']=='L2LSignetDevnet' and not source['backupRequired']
assert source['mint']=='Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM'
env=dict(os.environ,PGDATABASE='ecx_fresh_treasury_acceptance',ECX_WORKER_FENCE_DIR=str(state/'fence'))
wallet='ecx-bridge-fresh-treasury'

def save(name,value):
    path=state/name;temp=path.with_suffix('.tmp')
    with temp.open('w') as f:
        os.chmod(temp,0o600);json.dump(value,f);f.flush();os.fsync(f.fileno())
    os.replace(temp,path)
    fd=os.open(state,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)

def command(*args):
    result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=45)
    if result.returncode:raise RuntimeError('Test subprocess failed: '+Path(args[0]).name)
    return result.stdout

def rpc(method,params=(),native=False,wallet_name=None):
    headers={'Content-Type':'application/json'}
    if native:
        assert wallet_name in (None,wallet,'ecx-bridge-tester')
        headers['Authorization']='Basic '+base64.b64encode(Path(source['nativeCookie']).read_bytes().strip()).decode()
        url=source['nativeRpc']+('/wallet/'+wallet_name if wallet_name else '')
    else:url=source['solanaRpc']
    req=urllib.request.Request(url,json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers)
    try:
        response=json.load(urllib.request.urlopen(req,timeout=25))
    except urllib.error.HTTPError as error:
        if not native:raise
        response=json.load(error)
    if response.get('error'):raise RuntimeError('RPC refused '+method)
    return response['result']

def native(method,params=(),name=None):return rpc(method,params,True,name)

# Identity checks precede setup signing/funding.
assert rpc('getGenesisHash')=='EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG'
info=native('getblockchaininfo')
assert info['chain']=='signet' and info['signet_challenge']=='00148835832e28c816b7acd8fdb19772ab2199603a56' and not info['initialblockdownload']
if not (state/'native-origin.json').exists():
    known=native('listwalletdir')['wallets']
    assert not any(x['name']==wallet for x in known),'Unjournaled existing test wallet: inspect before adoption'
    save('native-origin.json',{'checkpointHeight':info['blocks'],'checkpointHash':info['bestblockhash'],'walletCreationRequested':True})
    native('createwallet',[wallet])
if wallet not in native('listwallets'):native('loadwallet',[wallet])
origin=json.loads((state/'native-origin.json').read_text())
if not (state/'funding.json').exists():
    previous=json.loads((Path(a.devnet_dir)/'setup.json').read_text())
    assert rpc('getBalance',[previous['payer'],{'commitment':'finalized'}])['value']>=60_000_000,'Insufficient real test funding SOL'
    assert int(rpc('getTokenAccountBalance',[previous['testerAta'],{'commitment':'finalized'}])['value']['amount'])>=1_000_000,'Insufficient real test token funding'
    latest=rpc('getLatestBlockhash',[{'commitment':'finalized'}])['value']
    command(a.funding_helper,a.devnet_dir,str(state),latest['blockhash'],str(latest['lastValidBlockHeight']))
funding=json.loads((state/'funding.json').read_text());sig=funding['signature']
status=rpc('getSignatureStatuses',[[sig],{'searchTransactionHistory':True}])['value'][0]
if status is None:
    assert rpc('getBlockHeight',[{'commitment':'finalized'}])<=funding['lastValidBlockHeight'],'Saved funding expired; inspect before replacing'
    assert rpc('sendTransaction',[funding['transaction'],{'encoding':'base64','preflightCommitment':'finalized','maxRetries':0}])==sig
if not (state/'native-funding.json').exists():
    address=native('getnewaddress',['fresh-treasury','bech32'],wallet)
    save('native-funding.json',{'address':address,'phase':'preparing'})
    funded=native('walletcreatefundedpsbt',[[],[{address:'0.00100000'}],0,{'lockUnspents':True,'replaceable':False,'minconf':1,'fee_rate':2},True],'ecx-bridge-tester')
    signed=native('walletprocesspsbt',[funded['psbt'],True,'ALL',True],'ecx-bridge-tester')
    final=native('finalizepsbt',[signed['psbt']]);assert final['complete']
    decoded=native('decoderawtransaction',[final['hex']])
    save('native-funding.json',{'address':address,'transaction':decoded['txid'],'raw':final['hex'],'phase':'possibly_broadcast'})
nf=json.loads((state/'native-funding.json').read_text());assert 'raw' in nf,'Interrupted preparation requires inspection'
try:native('gettransaction',[nf['transaction']],'ecx-bridge-tester')
except RuntimeError:assert native('sendrawtransaction',[nf['raw']])==nf['transaction']
# Finality wait is bounded. Saved real transfers survive timeout and must be reconciled.
for _ in range(90):
    sol=rpc('getSignatureStatuses',[[sig],{'searchTransactionHistory':True}])['value'][0]
    nat=native('gettransaction',[nf['transaction']],wallet)
    if sol and sol['err'] is None and sol['confirmationStatus']=='finalized' and nat['confirmations']>=1:break
    time.sleep(2)
else:raise RuntimeError('Real funding awaiting finality; saved transfers must be reconciled, not repeated')
helper={'deployment_id':'fresh-treasury-acceptance','mint':source['mint'],'custody_owner':funding['custodyOwner'],'signer_path':str(state/'custody.keypair.json')}
save('helper.json',helper)
sockets=Path('/tmp/ecx-fresh-treasury');sockets.mkdir(mode=0o700,exist_ok=True);sockets.chmod(0o700)
config=dict(source,deploymentId=helper['deployment_id'],nativeWallet=wallet,nativeCheckpointHeight=origin['checkpointHeight'],nativeCheckpointHash=origin['checkpointHash'],custodyOwner=funding['custodyOwner'],custodyAta=funding['custodyAta'],solanaHistoryStart=sig,solanaOperatingHistoryStart=sig,helperConfig=str(state/'helper.json'),dbPath=str(state/'unused.sqlite'),customerSocket=str(sockets/'customer.sock'),adminSocket=str(sockets/'admin.sock'))
save('config.json',config)
existing=command('psql','-XqAt','-d','postgres','-c',"SELECT 1 FROM pg_database WHERE datname='ecx_fresh_treasury_acceptance'").strip()
if not existing:
    command('createdb','-T','template0',env['PGDATABASE'])
    for f in sorted((root/'migrations/postgresql').glob('*.sql')):command('psql','-Xq','-v','ON_ERROR_STOP=1','-f',str(f))
command(binary,'postgres-init',str(state/'config.json'))
if not (state/'fence/sequence.json').exists():command(binary,'postgres-init-worker-fence',str(state/'config.json'))
class UnixHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.settimeout(55);self.sock.connect(config['adminSocket'])
def api(route,data=None):
    conn=UnixHTTP('localhost',timeout=55)
    try:
        conn.request('POST' if data is not None else 'GET',route,None if data is None else json.dumps(data),{'Content-Type':'application/json'})
        response=conn.getresponse();value=json.loads(response.read())
        if response.status>=400:raise RuntimeError(route+': '+str(value))
        return value
    finally:conn.close()
worker=None
try:
    with (state/'worker.log').open('a') as log:
        os.chmod(state/'worker.log',0o600)
        worker=subprocess.Popen([binary,'postgres-test-worker',str(state/'config.json')],env=env,stdout=log,stderr=log)
        for _ in range(90):
            assert worker.poll() is None,'Fresh worker exited'
            if Path(config['adminSocket']).exists():
                try:
                    scans=api('/scanners')['scanners']
                    if len(scans)==3 and all(x['lastSuccess'] and x['lastError'] is None for x in scans):break
                except (OSError,RuntimeError):pass
            time.sleep(2)
        else:raise RuntimeError('Fresh real-chain scans did not complete')
        api('/pause',{'pauseReason':'fresh treasury acceptance; no customer transfers'})
        audit=api('/audit');receipts=audit['treasuryReceipts']
        allocations=[]
        if not (state/'allocation-requests.json').exists():
            requests=[]
            for asset,split in [('Native',[['float','90000'],['operating','10000']]),('Wrapped',[['float','1000000']]),('Sol',[['operating','50000000']])]:
                matches=[x for x in receipts if x['asset']==asset]
                assert len(matches)==1,(asset,len(matches))
                requests.append({'asset':asset,'request':{'treasuryReceipt':matches[0]['receipt'],'treasurySplit':split,'ownershipAttestation':'Dedicated real-chain test treasury capital; source funding journal verified'}})
            save('allocation-requests.json',requests)
        for entry in json.loads((state/'allocation-requests.json').read_text()):
            request=entry['request']
            response=api('/allocate-treasury',request);assert not response['signedOrSent']
            replay=api('/allocate-treasury',request);assert replay==response
            allocations.append({'asset':entry['asset'],'receipt':request['treasuryReceipt'],'criticalSequence':response['criticalSequence'],'replayStable':True})
        final=api('/audit');assert not final['treasuryReceipts'];assert not api('/health')['available']
        counts=json.loads(command('psql','-XqAt','-c',"SELECT json_build_object('orders',(SELECT count(*) FROM orders),'attempts',(SELECT count(*) FROM attempts),'allocations',(SELECT count(*) FROM treasury_allocations),'paused',(SELECT paused FROM deployment));"))
        assert counts=={'orders':0,'attempts':0,'allocations':3,'paused':1}
        report={'network':'actual L2L Signet / Solana Devnet','mint':source['mint'],'nativeFunding':nf['transaction'],'solanaFunding':sig,'newCustody':funding['custodyOwner'],'freshPostgresLedger':True,'legacyLedgerImported':False,'allocations':allocations,'balances':final['balances'],'counts':counts,'customerRoundTripVerified':False,'guiWalletVerified':False,'workerStopped':True}
        Path(a.report).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'freshTreasuryAcceptance':'passed','allocations':3,'workerStopped':True}))
finally:
    if worker is not None:
        worker.terminate()
        try:worker.wait(timeout=15)
        except subprocess.TimeoutExpired:worker.kill();worker.wait()
