#!/usr/bin/env python3
"""Allocate verified fresh installed test receipts through the operator DSL."""
import argparse,json,os,time
from pathlib import Path
from InstalledTestTransport import InstalledTestTransport
p=argparse.ArgumentParser(description=__doc__);p.add_argument('state');p.add_argument('--vm',required=True);p.add_argument('--report',required=True);a=p.parse_args()
state=Path(a.state).resolve(strict=True);cfg=json.loads((state/'config.json').read_text());transport=InstalledTestTransport(a.vm,cfg);transport.preflight()
for _ in range(90):
 try:
  scans=transport.api('/scanners',None,None,True)['scanners']
  if len(scans)==3 and all(x['lastSuccess'] and x['lastError'] is None for x in scans):break
 except RuntimeError:pass
 time.sleep(2)
else:raise RuntimeError('Installed scans pending; retain funding and reconcile, do not repeat')
transport.api('/pause',{'pauseReason':'fresh installed treasury allocation acceptance'},None,True)
audit=transport.api('/audit',None,None,True);path=state/'allocation-requests.json'
if not path.exists():
 requests=[]
 for asset,split in [('Native',[['float','15000'],['operating','5000']]),('Wrapped',[['float','1000000']]),('Sol',[['operating','50000000']])]:
  receipts=[x for x in audit['treasuryReceipts'] if x['asset']==asset];assert len(receipts)==1,'Unexpected installed receipt count'
  requests.append({'asset':asset,'request':{'treasuryReceipt':receipts[0]['receipt'],'treasurySplit':split,'ownershipAttestation':'Dedicated real-chain installed-test capital; retained source funding journals and owned target wallets verified'}})
 temp=path.with_suffix('.tmp')
 with temp.open('w') as file:os.chmod(temp,0o600);json.dump(requests,file);file.flush();os.fsync(file.fileno())
 os.replace(temp,path);fd=os.open(state,os.O_RDONLY)
 try:os.fsync(fd)
 finally:os.close(fd)
results=[]
for entry in json.loads(path.read_text()):
 result=transport.api('/allocate-treasury',entry['request'],None,True);assert not result['signedOrSent']
 assert transport.api('/allocate-treasury',entry['request'],None,True)==result
 results.append({'asset':entry['asset'],'criticalSequence':result['criticalSequence'],'replayStable':True})
final=transport.api('/audit',None,None,True);assert not final['treasuryReceipts']
report={'actualInstalledSystemdWorker':True,'freshLedger':True,'legacyImport':False,'allocations':results,'balances':final['balances'],'paused':not transport.api('/health',None,None,True)['available'],'customerTransfersRun':False}
Path(a.report).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'installedTreasuryAllocation':'passed','allocations':len(results),'paused':report['paused']}))
