#!/usr/bin/env python3
"""Generate temporary public certificate fixtures; test actual patched validation."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--validator',required=True)
parser.add_argument('--openssl',default='openssl')
args=parser.parse_args()
os.umask(0o077)
with tempfile.TemporaryDirectory(prefix='ecx-cert-constraints-') as stage:
    directory=Path(stage)
    def run(*command):
        subprocess.run(command,cwd=directory,check=True,stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL,timeout=30)
    def key(name):run(args.openssl,'genpkey','-algorithm','EC','-pkeyopt','ec_paramgen_curve:prime256v1','-out',name+'.key')
    def csr(name,subject):run(args.openssl,'req','-new','-key',name+'.key','-out',name+'.csr','-subj','/CN='+subject)
    key('root')
    run(args.openssl,'req','-x509','-new','-key','root.key','-out','root.pem','-days','1',
        '-subj','/CN=Temporary fixture root','-addext','basicConstraints=critical,CA:TRUE',
        '-addext','keyUsage=critical,keyCertSign,cRLSign')
    key('issuer');csr('issuer','Temporary constrained issuer')
    (directory/'issuer.ext').write_text('basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nnameConstraints=critical,permitted;DNS:allowed.example,excluded;DNS:blocked.allowed.example\n')
    run(args.openssl,'x509','-req','-in','issuer.csr','-CA','root.pem','-CAkey','root.key',
        '-CAcreateserial','-out','issuer.pem','-days','1','-extfile','issuer.ext')
    for name in ('good.allowed.example','evil.other.example','blocked.allowed.example'):
        key(name);csr(name,name)
        ext=directory/(name+'.ext')
        ext.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:'+name+'\n')
        run(args.openssl,'x509','-req','-in',name+'.csr','-CA','issuer.pem','-CAkey','issuer.key',
            '-CAcreateserial','-out',name+'.pem','-days','1','-extfile',str(ext))
    subprocess.run([str(Path(args.validator).resolve()),stage],check=True,timeout=30)
