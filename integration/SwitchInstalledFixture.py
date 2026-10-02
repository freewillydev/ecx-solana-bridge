#!/usr/bin/env python3
"""Preserve the dedicated observer fixture before a distinct fresh paying test.

Root-only, fixed fixture guard. No key migration, database import or chain send.
An interrupted switch requires inspection; preservation is never overwritten.
"""
import argparse,json,os,shutil,subprocess,tarfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('setup_archive');p.add_argument('installer');a=p.parse_args()
assert os.geteuid()==0
cfg=Path('/etc/ecx-bridge');old=json.loads((cfg/'worker.json').read_text());assert old['deploymentId']=='ecx-wizard-acceptance' and old['profile']=='L2LSignetDevnet'
assert not (cfg/'signer.json').exists()
env=dict(os.environ,PGHOST='/run/ecx-postgres',PGPORT='29436',PGDATABASE='ecx_bridge')
def run(*args,**kw):
 r=subprocess.run(args,env=env,capture_output=True,timeout=180,**kw)
 assert r.returncode==0,'Fixture switch failed: '+Path(args[0]).name
 return r.stdout

def sql(q,db='ecx_bridge'):
 return run('runuser','-u','postgres','--','psql','-XqAt','-v','ON_ERROR_STOP=1','-d',db,'-c',q).decode().strip()
assert sql('SELECT (SELECT count(*) FROM orders)+(SELECT count(*) FROM attempts)+(SELECT critical_sequence FROM deployment);')=='0'
keep=Path('/var/lib/ecx-bridge/observer-preserved-20261002');assert not keep.exists(),'Preservation exists; inspect before resuming'
keep.mkdir(mode=0o700)
run('systemctl','stop','ecx-bridge-backup.timer','ecx-bridge-web','ecx-bridge-worker')
shutil.copytree(cfg,keep/'configuration');shutil.copytree('/var/lib/ecx-bridge/fence',keep/'fence')
dump=run('runuser','-u','postgres','--','pg_dump','-Fc','ecx_bridge');(keep/'ledger.dump').write_bytes(dump);(keep/'ledger.dump').chmod(0o600)
assert sql("SELECT count(*) FROM pg_database WHERE datname='ecx_observer_preserved';",'postgres')=='0'
sql('ALTER DATABASE ecx_bridge RENAME TO ecx_observer_preserved;','postgres')
shutil.move('/var/lib/ecx-bridge/fence',keep/'original-fence')
for name in ['worker.json','helper.json','interface.json']:
 if (cfg/name).exists():shutil.move(cfg/name,keep/('original-'+name))
setup=keep/'incoming';setup.mkdir(mode=0o700)
with tarfile.open(a.setup_archive) as archive:archive.extractall(setup,filter='data')
new=json.loads((setup/'setup/worker.json').read_text());assert new['deploymentId']=='fresh-treasury-acceptance' and new['custodyOwner']!=old['custodyOwner']
with (keep/'installation.log').open('wb') as log:
 result=subprocess.run(['sh',str(Path(a.installer).resolve()),'--with-signet','--config-dir',str(setup/'setup'),'--test-worker'],stdout=log,stderr=log,timeout=180)
 assert result.returncode==0,'Fresh installer failed; inspect preserved installation log'
assert sql('SELECT count(*) FROM orders;')=='0' and sql('SELECT count(*) FROM attempts;')=='0'
assert sql('SELECT critical_sequence FROM deployment;')=='0'
print(json.dumps({'observerDatabasePreserved':True,'observerConfigAndFencePreserved':True,'freshInstalledLedger':True,'legacyImport':False,'payingTestModeConfigured':True,'customerTransfersRun':False}))
