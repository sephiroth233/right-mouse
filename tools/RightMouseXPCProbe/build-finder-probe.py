#!/usr/bin/env python3
import pathlib, json, plistlib, subprocess, re, uuid, os
root = pathlib.Path(__file__).resolve().parents[2]
build = root/'.build/xpc-probe'
v = json.loads((build/'metadata.json').read_text())
app = build/'FinderProbe.app'
ext = app/'Contents/PlugIns/FinderProbe.appex'
for bundle in [app,ext]: (bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
# The containing app is a fixture only. Its executable is never launched.
(app/'Contents/MacOS/Probe').write_bytes(pathlib.Path(v['paths']['server']).read_bytes())
(app/'Contents/MacOS/Probe').chmod(0o755)
info = {'CFBundleIdentifier':'cn.rightmouse.XPCProbe', 'CFBundleExecutable':'Probe','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleName':'RightMouse XPC Probe','LSUIElement':True}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(root/'.build/finder-local-acceptance').mkdir(parents=True,exist_ok=True)
run_id = str(uuid.uuid4())
req = lambda digest: 'cdhash H"' + digest + '"'
info.update({'CFBundleIdentifier':'cn.rightmouse.XPCProbe.Finder','CFBundleExecutable':'FinderProbe','CFBundlePackageType':'XPC!',
 'NSExtension':{'NSExtensionPointIdentifier':'com.apple.FinderSync','NSExtensionPrincipalClass':'RightMouseXPCProbe.FinderProbe'},
 'ProbeDirectory':str(root/'.build/finder-local-acceptance'),'ProbeService':v['service'],'ProbeServerRequirement':req(v['hashes']['server']),'ProbeRunID':run_id})
(ext/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','swiftc','-sdk',sdk,'-target',os.uname().machine+'-apple-macosx14.0','-swift-version','5','-module-cache-path',str(build/'module-cache'),'-parse-as-library','-application-extension','-module-name','RightMouseXPCProbe',str(root/'tools/RightMouseXPCProbe/FinderProbe.swift'),'-framework','FinderSync','-framework','AppKit','-Xlinker','-e','-Xlinker','_NSExtensionMain','-o',str(ext/'Contents/MacOS/FinderProbe')],check=True)
subprocess.run(['codesign','--force','--sign','-','--options','runtime','--entitlements',str(build/'client.entitlements'),str(ext)],check=True)
subprocess.run(['codesign','--force','--sign','-','--options','runtime',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
out = subprocess.run(['codesign','-dv','--verbose=4',str(ext)],capture_output=True,text=True,check=True).stderr
digest = re.search(r'^CDHash=(\w+)',out,re.M).group(1)
agent = plistlib.loads((build/'agent.plist').read_bytes())
agent['ProgramArguments'][3] = '(' + req(digest) + ') or (' + req(v['hashes']['client']) + ')'
(build/'finder-agent.plist').write_bytes(plistlib.dumps(agent))
(build/'finder-metadata.json').write_text(json.dumps({'bundle':str(app),'extension':str(ext),'cdhash':digest,'runID':run_id,'service':v['service']},indent=2))
print('Built sandboxed Finder probe',run_id)
