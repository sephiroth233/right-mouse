#!/usr/bin/env python3
"""Run the isolated Finder probe and always remove its temporary registration."""
import pathlib, subprocess, json, os, time
root = pathlib.Path(__file__).resolve().parents[2]
build = root/'.build/xpc-probe'
v = json.loads((build/'finder-metadata.json').read_text())
domain = 'gui/'+str(os.getuid())
job = domain+'/'+v['service']
ext = v['extension']
identifier = 'cn.rightmouse.XPCProbe.Finder'
result = {'runID':v['runID'], 'passed':False}
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
try:
    subprocess.run(['launchctl','bootstrap',domain,str(build/'finder-agent.plist')],check=True)
    subprocess.run([lsregister,'-f',v['bundle']],check=True)
    subprocess.run(['pluginkit','-a',ext],check=True)
    subprocess.run(['pluginkit','-e','use','-i',identifier],check=True)
    print('Finder probe registered. Waiting for Finder to load it; auto-cleanup in 150 seconds.',flush=True)
    deadline = time.monotonic()+150
    while time.monotonic()<deadline:
        predicate = 'subsystem == "cn.rightmouse.XPCProbe" AND eventMessage CONTAINS "'+v['runID']+'"'
        p = subprocess.run(['/usr/bin/log','show','--last','4m','--style','compact','--predicate',predicate],capture_output=True,text=True,timeout=10)
        if 'Finder authenticated ping passed: true' in p.stdout or 'Finder authenticated ping passed: 1' in p.stdout:
            result['passed'] = True
            result['log'] = p.stdout
            print(p.stdout,flush=True)
            # Leave time to inspect the harmless status menu, then clean up.
            time.sleep(25)
            break
        if 'Finder probe rejected:' in p.stdout:
            result['log'] = p.stdout
            print(p.stdout,flush=True)
            break
        time.sleep(3)
finally:
    disabled = subprocess.run(['pluginkit','-e','ignore','-i',identifier],capture_output=True,text=True)
    removed = subprocess.run(['pluginkit','-r',ext],capture_output=True,text=True)
    unregistered = subprocess.run([lsregister,'-u',v['bundle']],capture_output=True,text=True)
    stopped = subprocess.run(['launchctl','bootout',job],capture_output=True,text=True)
    result['cleanup'] = {'disable':disabled.returncode,'unregister':removed.returncode,'bootout':stopped.returncode,'unregisterApp':unregistered.returncode}
    (build/'finder-results.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
    print('Cleanup:',result['cleanup'],flush=True)
if not result['passed']: raise SystemExit('Finder XPC proof not obtained')
