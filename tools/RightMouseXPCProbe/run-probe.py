#!/usr/bin/env python3
"""Temporarily bootstrap only our ping service, test, and always boot it out."""
import pathlib, subprocess, json, os, time
root = pathlib.Path(__file__).resolve().parents[2]
build = root / '.build/xpc-probe'
v = json.loads((build/'metadata.json').read_text())
domain = 'gui/' + str(os.getuid())
job = domain + '/' + v['service']
req = lambda digest: 'cdhash H"' + digest + '"'
results = []
def client(name, requirement, expected):
    p = subprocess.run([v['paths'][name], 'client', v['service'], requirement], capture_output=True, text=True, timeout=12)
    passed = p.returncode == expected
    print(name, 'PASS' if passed else 'FAIL', 'exit', p.returncode, p.stdout.strip(), p.stderr.strip(), flush=True)
    results.append({'client': name, 'expected':expected, 'exit':p.returncode, 'stdout':p.stdout, 'stderr':p.stderr, 'pass':passed})
    if not passed: raise RuntimeError('Probe failed: ' + name)
try:
    subprocess.run(['launchctl','bootstrap',domain,str(build/'agent.plist')],check=True)
    client('client',req(v['hashes']['server']),0)
    client('rogue',req(v['hashes']['server']),2)
    client('no-lookup',req(v['hashes']['server']),2)
    client('client',req('0'*40),2)
    subprocess.run(['launchctl','kickstart','-k',job],check=True)
    # kickstart -k completes the process replacement before making a new connection.
    client('client',req(v['hashes']['server']),0)
finally:
    result = subprocess.run(['launchctl','bootout',job],capture_output=True,text=True)
    print('Cleanup bootout:', result.returncode, result.stderr.strip(), flush=True)
    (build/'results.json').write_text(json.dumps({'results':results,'cleanup':result.returncode},indent=2))
