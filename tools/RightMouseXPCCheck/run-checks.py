#!/usr/bin/env python3
"""Integration checks against the running local build. Only creates fixture files.
Build with RIGHTMOUSE_TEST_CLIENTS=1; start that exact app before running.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get('RIGHTMOUSE_BUILD_DIR', root/'.build/local'))
checks = build/'xpc-checks'
fixture = root/'.build/finder-xpc-acceptance'/str(uuid.uuid4())
fixture.mkdir(parents=True)
results = []

def check(name, condition):
    results.append({'name': name, 'passed': bool(condition)})
    print(('PASS ' if condition else 'FAIL ') + name, flush=True)
    if not condition: raise AssertionError(name)

def client(name, mode='ping', payload=None):
    args = [str(checks/(name+'.app')/'Contents/MacOS/XPCCheck'), mode]
    if payload is not None: args.append(payload)
    return subprocess.run(args, capture_output=True, text=True, timeout=12)

def request(mode, name):
    return subprocess.check_output([str(checks/'make-request'), str(fixture), mode, name], text=True).strip()

def wait_for(predicate, seconds=12):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        if predicate(): return True
        time.sleep(.2)
    return False

try:
    for name in ['valid','rogue','wrong-role','no-lookup']:
        result=client(name)
        check(name+' identity/lookup boundary', result.returncode == (0 if name=='valid' else 3))
    before=request('create','before-handshake.txt')
    check('operation before handshake rejected',client('valid','no-handshake',before).returncode==2)
    check('no handshake has no file effect',not (fixture/'before-handshake.txt').exists())
    url=request('create','created.txt')
    check('authenticated create accepted',client('valid','perform',url).returncode==0)
    check('real file created',wait_for(lambda:(fixture/'created.txt').is_file()))
    check('duplicate request accepted by existing ledger',client('valid','perform',url).returncode==0)
    time.sleep(.5)
    check('duplicate has no second file',len(list(fixture.iterdir()))==1)
    expired=request('expired','expired.txt')
    check('expired authenticated request rejected',client('valid','perform',expired).returncode==2)
    check('expired request has no file effect',not (fixture/'expired.txt').exists())
    check('malformed payload rejected',client('valid','perform','invalid').returncode==2)
    subprocess.run(['/bin/launchctl','kickstart','-k','gui/'+str(os.getuid())+'/cn.rightmouse.local-bridge'],check=True)
    check('host republishes endpoint after bridge restart',wait_for(lambda:client('valid').returncode==0))
    after=request('create','after-restart.txt')
    check('operation after restart accepted',client('valid','perform',after).returncode==0)
    check('operation after restart creates real file',wait_for(lambda:(fixture/'after-restart.txt').is_file()))
finally:
    (checks/'results.json').write_text(json.dumps({'fixture':str(fixture),'results':results},indent=2))
