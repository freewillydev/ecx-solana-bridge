#!/usr/bin/env python3
"""Both actual customer directions on the isolated, freshly funded PG ledger.

Dedicated Signet/Devnet funds only. Exact deposit bytes and private capabilities
are journaled before send. A timeout stops the worker and retains all state;
rerun reconciles the same orders/deposits rather than issuing another payment.
"""
import argparse,base64,http.client,json,os,secrets,socket,subprocess,time,urllib.request,urllib.error
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('state');p.add_argument('--binary',help='local paying binary; required unless --installed-vm is used');p.add_argument('--devnet-dir',required=True);p.add_argument('--deposit-helper',required=True);p.add_argument('--report',required=True)
p.add_argument('--installed-vm', help='dedicated Lima VM; use the installed systemd paying service instead of a local process')
a=p.parse_args();state=Path(a.state).resolve();cfg=json.loads((state/'config.json').read_text())
assert cfg['profile']=='L2LSignetDevnet' and cfg['deploymentId']=='fresh-treasury-acceptance' and not cfg['backupRequired']
private=state/'product';private.mkdir(mode=0o700,exist_ok=True);private.chmod(0o700)
env=dict(os.environ,PGDATABASE='ecx_fresh_treasury_acceptance',ECX_WORKER_FENCE_DIR=str(state/'fence'))
assert a.installed_vm or a.binary,'Local binary required'
binary=None if a.installed_vm else str(Path(a.binary).resolve(strict=True));manifest=json.loads((Path(a.devnet_dir)/'setup.json').read_text())
assert manifest['mint']==cfg['mint']=='Hqb82J658UeWXCdr6DA6Au2ChMzrhxoSd3vdXk2hkNqM'

def save(name,value):
    path=private/name;temp=path.with_suffix('.tmp')
    with temp.open('w') as f:
        os.chmod(temp,0o600);json.dump(value,f);f.flush();os.fsync(f.fileno())
    os.replace(temp,path)
    fd=os.open(private,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)
def run(*args):
    r=subprocess.run(args,env=env,capture_output=True,text=True,timeout=45)
    if r.returncode:raise RuntimeError('Acceptance subprocess failed: '+Path(args[0]).name)
    return r.stdout

installed=None
if a.installed_vm:
    from InstalledTestTransport import InstalledTestTransport
    installed=InstalledTestTransport(a.installed_vm,cfg)
    installed.preflight()

def rpc(method,params=(),native=False,wallet=None):
    if installed and native:return installed.rpc(method,params,native,wallet)
    headers={'Content-Type':'application/json'}
    if native:
        assert wallet in (None,cfg['nativeWallet'],'ecx-bridge-tester')
        headers['Authorization']='Basic '+base64.b64encode(Path(cfg['nativeCookie']).read_bytes().strip()).decode()
        url=cfg['nativeRpc']+('/wallet/'+wallet if wallet else '')
    else:url=cfg['solanaRpc']
    req=urllib.request.Request(url,json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers)
    for attempt in range(4):
        try:
            r=json.load(urllib.request.urlopen(req,timeout=25));break
        except urllib.error.HTTPError as e:
            if native:r=json.load(e);break
            # Read-only test RPCs may be retried; signing/sending is never retried here.
            if e.code not in (429,503) or method not in ('getGenesisHash','getLatestBlockhash','getSignatureStatuses','getBlockHeight','getBalance','getTokenAccountBalance') or attempt==3:raise
            time.sleep(2**(attempt+1))
    if r.get('error'):raise RuntimeError('RPC refused '+method)
    return r['result']
class UnixHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.settimeout(55);self.sock.connect(self.target)
def api(route,data=None,token=None,admin=False):
    if installed:return installed.api(route,data,token,admin)
    conn=UnixHTTP('localhost',timeout=55);conn.target=cfg['adminSocket' if admin else 'customerSocket']
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    try:
        conn.request('POST' if data is not None else 'GET',route,None if data is None else json.dumps(data),headers)
        response=conn.getresponse();value=json.loads(response.read())
        if response.status>=400:raise RuntimeError(route+': '+str(value))
        return value
    finally:conn.close()
worker=None;log=None
def stop():
    global worker,log
    if installed:installed.service('stop')
    if worker:
        worker.terminate()
        try:worker.wait(timeout=15)
        except subprocess.TimeoutExpired:worker.kill();worker.wait()
        worker=None
    if log:log.close();log=None
def start():
    global worker,log
    launched=int(time.time());log=(private/'worker.log').open('a');os.chmod(private/'worker.log',0o600)
    if installed:
        installed.service('stop')
        installed.service('start')
    else:worker=subprocess.Popen([binary,'postgres-test-worker',str(state/'config.json')],env=env,stdout=log,stderr=log)
    for _ in range(90):
        assert (installed.alive() if installed else worker.poll() is None),'Product worker exited'
        try:
            scans=api('/scanners',admin=True)['scanners']
            if len(scans)==3 and all(x['lastSuccess'] and x['lastSuccess']>=launched and x['lastError'] is None for x in scans):
                if api('/health',admin=True)['available']:return
                # Explicit reviewed-test resume also covers a transient startup scan failure.
                # The production resume handler retains all evidence/recovery gates.
                try:
                    if api('/resume',{},admin=True)['available']:return
                except RuntimeError:pass
        except (OSError,RuntimeError):pass
        time.sleep(2)
    raise RuntimeError('Fresh product did not become ready; inspect retained ledger and worker log')
def view(which):
    order=json.loads((private/(which+'-order.json')).read_text());auth=json.loads((private/(which+'-request.json')).read_text())
    return api('/api/v1/orders/'+order['orderId'],token=auth['capability'])
def financial():
    tables=['orders','obligations','attempts','postings','reservations','fee_reservations','order_cost_limits','treasury_allocations','preparations','intents']
    q="SELECT json_build_object('sequence',(SELECT critical_sequence FROM deployment),'tables',json_build_object("+','.join("'"+t+"',(SELECT md5(coalesce(string_agg(to_jsonb(x)::text,'' ORDER BY to_jsonb(x)::text),'')) FROM "+t+" x)" for t in tables)+"));"
    return installed.financial(q) if installed else json.loads(run('psql','-XqAt','-v','ON_ERROR_STOP=1','-c',q))
try:
    assert rpc('getGenesisHash')=='EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG'
    native=rpc('getblockchaininfo',native=True)
    assert native['chain']=='signet' and native['signet_challenge']=='00148835832e28c816b7acd8fdb19772ab2199603a56'
    start()
    if not (private/'native-recipient.json').exists():
        address=rpc('getnewaddress',['fresh-product-tester','bech32'],True,'ecx-bridge-tester');save('native-recipient.json',{'address':address})
    address=json.loads((private/'native-recipient.json').read_text())['address']
    for which,direction,recipient,refund in [('wrap','NativeToWrapped',manifest['tester'],address),('redeem','WrappedToNative',address,'')]:
        if not (private/(which+'-request.json')).exists():
            save(which+'-request.json',{'capability':secrets.token_hex(32),'request':{'direction':direction,'input':'10000','recipient':recipient,'refund':refund,'sourceOwner':None,'idempotencyKey':'fresh-product-'+which}})
        auth=json.loads((private/(which+'-request.json')).read_text())
        order=api('/api/v1/orders',auth['request'],auth['capability']);assert order['quote']=={'gross':'10000','fee':'100','net':'9900'}
        save(which+'-order.json',order)
    wrap=json.loads((private/'wrap-order.json').read_text())
    if not (private/'native-deposit.json').exists():
        destination=wrap['depositInstruction'];assert isinstance(destination,str) and destination.startswith('tb1')
        save('native-deposit.json',{'phase':'preparing','address':destination})
        funded=rpc('walletcreatefundedpsbt',[[],[{destination:'0.00010000'}],0,{'lockUnspents':True,'replaceable':False,'minconf':1,'fee_rate':2},True],True,'ecx-bridge-tester')
        signed=rpc('walletprocesspsbt',[funded['psbt'],True,'ALL',True],True,'ecx-bridge-tester')
        final=rpc('finalizepsbt',[signed['psbt']],True);assert final['complete']
        decoded=rpc('decoderawtransaction',[final['hex']],True)
        save('native-deposit.json',{'phase':'possibly_broadcast','transaction':decoded['txid'],'raw':final['hex']})
    nd=json.loads((private/'native-deposit.json').read_text());assert 'raw' in nd,'Interrupted native preparation requires inspection'
    try:rpc('gettransaction',[nd['transaction']],True,'ecx-bridge-tester')
    except RuntimeError:assert rpc('sendrawtransaction',[nd['raw']],True)==nd['transaction']
    redeem=json.loads((private/'redeem-order.json').read_text());auth=json.loads((private/'redeem-request.json').read_text())
    if not (private/'solana-deposit.json').exists():
        pay=api('/api/v1/orders/'+redeem['orderId']+'/transaction',{},auth['capability'])
        latest=rpc('getLatestBlockhash',[{'commitment':'finalized'}])['value']
        prepared={'chain':'solana:devnet','orderId':redeem['orderId'],'amount':'10000','mint':cfg['mint'],'custody':cfg['custodyAta'],'owner':manifest['tester'],'reference':pay['reference'],**latest}
        save('prepared.json',prepared)
        run(a.deposit_helper,a.devnet_dir,str(private/'prepared.json'),str(private/'solana-deposit.json'),str(state/'config.json'))
    sd=json.loads((private/'solana-deposit.json').read_text())
    status=rpc('getSignatureStatuses',[[sd['signature']],{'searchTransactionHistory':True}])['value'][0]
    if status is None:
        assert rpc('getBlockHeight',[{'commitment':'finalized'}])<=sd['lastValidBlockHeight'],'Saved deposit expired; explicit recovery required'
        assert rpc('sendTransaction',[sd['transaction'],{'encoding':'base64','preflightCommitment':'finalized','maxRetries':0}])==sd['signature']
    api('/api/v1/orders/'+redeem['orderId']+'/observations',{'signature':sd['signature']},auth['capability'])
    for _ in range(360):
        assert (installed.alive() if installed else worker.poll() is None),'Worker exited with saved customer work'
        results={which:view(which) for which in ['wrap','redeem']}
        if all(x['status']=='Paid' for x in results.values()):
            sol=rpc('getSignatureStatuses',[[results['wrap']['payoutTx']],{'searchTransactionHistory':True}])['value'][0]
            nat=rpc('gettransaction',[results['redeem']['payoutTx']],True,cfg['nativeWallet'])
            if sol and sol['err'] is None and sol['confirmationStatus']=='finalized' and nat['confirmations']>=1:break
        time.sleep(2)
    else:raise RuntimeError('Real customer work remains pending; saved orders and deposits require reconciliation')
    api('/pause',{'pauseReason':'fresh product restart acceptance'},admin=True)
    before=financial();terminal=results;stop();start()
    assert {which:view(which) for which in ['wrap','redeem']}==terminal,'Saved-order reload changed terminal result'
    after=financial();assert before==after,'Restart changed financial rows or critical sequence'
    api('/pause',{'pauseReason':'fresh product acceptance complete; stopped for review'},admin=True)
    report={'networks':['actual L2L Signet','actual Solana Devnet'],'freshPostgresLedger':True,'legacyImport':False,'feesBpsBothDirections':100,'orders':[{'direction':x['request']['direction'],'orderId':x['orderId'],'status':x['status'],'payout':x['payoutTx'],'quote':x['quote']} for x in terminal.values()],'nativeDeposit':nd['transaction'],'solanaDeposit':sd['signature'],'nativePayoutConfirmed':True,'solanaPayoutFinalized':True,'financialTablesCompared':len(before['tables']),'financialRowsAndSequenceUnchangedAfterRestart':True,'savedOrderReloadStable':True,'hostFenceEnabled':True,'guiWalletVerified':False,'workerStopped':True,'finalPaused':True,'installedSystemdWorker':bool(installed)}
    Path(a.report).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'freshProductAcceptance':'passed','directions':2,'restartStable':True}))
finally:stop()
