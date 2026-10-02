#!/usr/bin/env python3
"""Observer DSL authority over the actual Unix API; no wallets/signers invoked.

Provide a real Signet/Devnet or betanet/Devnet config and a compiled binary.
PG* must identify a private maintenance database role with CREATEDB permission.
The source ledger/config stay unchanged; only a disposable database is used.
"""
import os,json,subprocess,tempfile,time,secrets,argparse,uuid
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('config')
parser.add_argument('--binary',required=True)
parser.add_argument('--report')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
binary=Path(args.binary).resolve(strict=True)
env=dict(os.environ,PGDATABASE='ecx_observer_contract_'+uuid.uuid4().hex)
def run(*command,**kw):
    try:return subprocess.run(command,env=env,capture_output=True,text=True,check=True,timeout=30,**kw)
    except (subprocess.SubprocessError,OSError):raise SystemExit('Observer contract subprocess failed: '+Path(command[0]).name)
run('createdb',env['PGDATABASE'])
process=None
try:
    run('psql','-Xq','-v','ON_ERROR_STOP=1','-f',str(root/'migrations/postgresql/001.sql'))
    with tempfile.TemporaryDirectory(prefix='ecx-observer-') as folder:
        directory=Path(folder)
        c=json.loads(Path(args.config).read_text())
        assert c['profile'] in {'L2LSignetDevnet','ECXBetanetDevnet'} and not c['backupRequired']
        c['deploymentId']='ecx-observer-profile-contract';c['customerSocket']=str(directory/'customer.sock');c['adminSocket']=str(directory/'admin.sock')
        cfg=directory/'config.json';cfg.write_text(json.dumps(c));cfg.chmod(0o600)
        run(str(binary),'postgres-init',str(cfg))
        with (directory/'process.log').open('w') as log:
            process=subprocess.Popen([str(binary),'postgres-api',str(cfg)],env=env,stdout=log,stderr=log)
            for _ in range(100):
                if (directory/'admin.sock').exists() and (directory/'customer.sock').exists():break
                if process.poll() is not None:raise RuntimeError('Observer exited')
                time.sleep(.1)
            else:raise RuntimeError('Observer sockets unavailable')
            def api(path,data=None,customer=False):
                sock=c['customerSocket'] if customer else c['adminSocket']
                command=['curl','-sS','--max-time','10','--unix-socket',sock,'http://localhost'+path,'-H','Content-Type: application/json','-H','Authorization: Bearer '+secrets.token_hex(32)]
                if data is not None:command+=['--data',json.dumps(data)]
                elif path=='/resume':command+=['-X','POST']
                return json.loads(run(*command).stdout)
            public=api('/api/v1/config',customer=True)
            assert public['profile']==c['profile'] and not public['intakeEnabled']
            assert public['availability']=={'available':False,'reason':'observation_only'}
            audit=api('/audit')
            assert audit['nativeRecoveryReviews']==[] and not audit['nativeRecoveryBacklog']
            request={'direction':'WrappedToNative','input':'10000','recipient':'unused-observer-destination','refund':'','sourceOwner':None,'idempotencyKey':secrets.token_hex(16)}
            refused={'createOrder':api('/api/v1/orders',request,True),
                     'resume':api('/resume'),
                     'sign':api('/sign-native-replacement',{'draftSequence':1}),
                     'send':api('/send-native-replacement',{'draftSequence':1}),
                     'refund':api('/refund',{'depositId':'no-observer-payment'}),
                     'coveredSource':api('/approve-covered-source',{'coveredObligation':'no-observer-payment','coveredLossSequence':1,'coveredApprovalReason':'observer cannot grant covered payment authority'}),
                     'treasuryAllocation':api('/allocate-treasury',{'treasuryReceipt':'no-observer-capital','treasurySplit':[['operating','10000']],'ownershipAttestation':'observer cannot allocate custody'}),
                     'nativeRebroadcast':api('/rebroadcast-native',{'rebroadcastTransaction':'no-observer-payment','rebroadcastRecoverySequence':1,'rebroadcastReason':'observer cannot rebroadcast settled payments'})}
            assert all(v=={'error':'payment_worker_required'} for v in refused.values()),refused
            result=json.loads(run('psql','-XqAt','-c',"SELECT json_build_object('orders',(SELECT count(*) FROM orders),'attempts',(SELECT count(*) FROM attempts),'criticalSequence',(SELECT critical_sequence FROM deployment));").stdout)
            assert result=={'orders':0,'attempts':0,'criticalSequence':0}
            report={'actualProfile':c['profile'],'canonicalOperationEnabled':False,'observationOnlyAvailabilityPassed':True,'orderCreationRefused':True,'resumeRefused':True,'signatureRefused':True,'broadcastRefused':True,'refundRefused':True,'coveredSourceApprovalRefused':True,'nativeRebroadcastRefused':True,'treasuryAllocationRefused':True,'orders':0,'attempts':0,'criticalSequence':0,'walletsModified':False,'roundTripVerified':False}
            print(json.dumps(report))
            if args.report:Path(args.report).write_text(json.dumps(report,indent=2)+'\n')
finally:
    if process is not None:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()
    run('dropdb',env['PGDATABASE'])
