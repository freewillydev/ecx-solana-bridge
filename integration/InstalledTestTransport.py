"""Private transport for the dedicated Signet/Devnet installed product test.

Requests travel over SSH stdin, never command arguments or public RPC ports.
The guest reads its own cookie. This is test orchestration, not a server API.
"""
import json
import re
import subprocess


GUEST = r'''
import base64,http.client,json,os,re,socket,subprocess,sys,urllib.request,urllib.error
from pathlib import Path
request=json.load(sys.stdin)
cfg=json.loads(Path('/etc/ecx-bridge/worker.json').read_text())
assert cfg['profile']=='L2LSignetDevnet' and not cfg['backupRequired']
assert cfg['deploymentId']=='fresh-treasury-acceptance'
for field,value in request['identity'].items():assert cfg[field]==value,'Installed identity mismatch'
action=request['action']
if action=='preflight':
    helper=json.loads(Path('/etc/ecx-bridge/helper.json').read_text())
    assert helper['signer_path']=='/etc/ecx-bridge/signer.json'
    assert helper['custody_owner']==cfg['custodyOwner'] and helper['mint']==cfg['mint']
    assert Path(helper['signer_path']).is_file()
    for arguments in [['check-config','/etc/ecx-bridge/worker.json'],['check-signer','/etc/ecx-bridge/worker.json',helper['signer_path']]]:
        checked=subprocess.run(['/opt/ecx-bridge/current/bin/ecx-bridge',*arguments],capture_output=True)
        assert checked.returncode==0,'Installed signing configuration rejected'
    command=subprocess.check_output(['systemctl','show','ecx-bridge-worker','--property=ExecStart','--value'],text=True)
    assert 'postgres-test-worker' in command,'Installed public-test payment mode required'
    value={'installedPayingPreflight':True}
elif action=='service':
    verb=request['verb'];assert verb in ['start','stop','is-active']
    result=subprocess.run(['systemctl',verb,'--quiet','ecx-bridge-worker'],capture_output=True)
    if verb!='is-active':assert result.returncode==0,'Installed service action failed'
    value=result.returncode==0
elif action=='rpc':
    headers={'Content-Type':'application/json'}
    if request['native']:
        wallet=request['wallet'];assert wallet in [None,cfg['nativeWallet'],'ecx-bridge-tester']
        headers['Authorization']='Basic '+base64.b64encode(Path(cfg['nativeCookie']).read_bytes().strip()).decode()
        url=cfg['nativeRpc']+('/wallet/'+wallet if wallet else '')
    else:url=cfg['solanaRpc']
    req=urllib.request.Request(url,json.dumps({'jsonrpc':'2.0','id':1,'method':request['method'],'params':request['params']}).encode(),headers)
    try:response=json.load(urllib.request.urlopen(req,timeout=25))
    except urllib.error.HTTPError as error:
        if not request['native']:raise
        response=json.load(error)
    assert not response.get('error'),'Installed RPC refused request'
    value=response['result']
elif action=='api':
    class UnixHTTP(http.client.HTTPConnection):
        def connect(self):
            self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            self.sock.settimeout(55)
            self.sock.connect(cfg['adminSocket' if request['admin'] else 'customerSocket'])
    conn=UnixHTTP('localhost',timeout=55)
    headers={'Content-Type':'application/json'}
    if request['token']:headers['Authorization']='Bearer '+request['token']
    try:
        data=request['data']
        conn.request('POST' if data is not None else 'GET',request['route'],None if data is None else json.dumps(data),headers)
        response=conn.getresponse();value=json.loads(response.read())
        if response.status>=400:
            code=value.get('error') if isinstance(value,dict) else None
            code=code if isinstance(code,str) and re.fullmatch('[a-z0-9_-]{1,100}',code) else 'redacted'
            value={'__installed_test_error':{'status':response.status,'code':code}}
    finally:conn.close()
elif action=='financial':
    query=request['query'];assert query.startswith('SELECT json_build_object(') and query.count(';')==1
    env=dict(os.environ,PGHOST='/run/ecx-postgres',PGPORT='29436',PGDATABASE='ecx_bridge')
    result=subprocess.run(['runuser','-u','postgres','--','psql','-XqAt','-v','ON_ERROR_STOP=1','-c',query],env=env,capture_output=True,text=True,timeout=30)
    assert result.returncode==0,'Installed financial comparison failed'
    value=json.loads(result.stdout)
else:raise ValueError('Unknown installed test action')
json.dump(value,sys.stdout)
'''


class InstalledTestTransport:
    def __init__(self, vm, config):
        assert re.fullmatch(r'[a-z][a-z0-9-]{0,62}', vm), 'Invalid dedicated VM name'
        self.vm = vm
        self.identity = {key: config[key] for key in (
            'profile', 'deploymentId', 'nativeRpc', 'nativeCookie', 'solanaRpc', 'nativeWallet', 'nativeCheckpointHeight',
            'nativeCheckpointHash', 'mint', 'custodyOwner', 'custodyAta',
            'solanaHistoryStart', 'solanaOperatingHistoryStart')}

    def call(self, action, **values):
        result = subprocess.run(
            ['limactl', 'shell', self.vm, 'sudo', 'python3', '-c', GUEST],
            input=json.dumps(dict(action=action, identity=self.identity, **values)),
            capture_output=True, text=True, timeout=75)
        if result.returncode:
            # Never print private capabilities, signed bytes, cookies or config.
            raise RuntimeError('Installed test action failed: ' + action)
        value = json.loads(result.stdout)
        if isinstance(value, dict) and '__installed_test_error' in value:
            error = value['__installed_test_error']
            raise RuntimeError('Installed API refused: ' + str(error['status']) + ' ' + error['code'])
        return value

    def preflight(self):
        return self.call('preflight')

    def service(self, verb):
        return self.call('service', verb=verb)

    def alive(self):
        return self.service('is-active')

    def rpc(self, method, params, native, wallet):
        return self.call('rpc', method=method, params=params, native=native, wallet=wallet)

    def api(self, route, data, token, admin):
        return self.call('api', route=route, data=data, token=token, admin=admin)

    def financial(self, query):
        return self.call('financial', query=query)
