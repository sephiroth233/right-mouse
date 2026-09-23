#!/usr/bin/env python3
"""Build isolated, harmless XPC ping fixtures; never alters RightMouse bundles."""
import pathlib, plistlib, subprocess, re, json, os
root = pathlib.Path(__file__).resolve().parents[2]
build = root / '.build/xpc-probe'
build.mkdir(parents=True, exist_ok=True)
service = 'cn.rightmouse.xpc-probe.' + str(os.getuid())
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
source = root / 'tools/RightMouseXPCProbe/Probe.swift'
common = ['xcrun', 'swiftc', '-sdk', sdk, '-target', os.uname().machine + '-apple-macosx14.0', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(build/'module-cache')]
entitlements = {'com.apple.security.app-sandbox': True, 'com.apple.security.temporary-exception.mach-lookup.global-name': [service]}
(build / 'client.entitlements').write_bytes(plistlib.dumps(entitlements))
(build / 'no-lookup.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
hashes = {}
paths = {}
for name in ['server', 'client', 'rogue', 'no-lookup']:
    bundle = build / (name + '.app')
    macos = bundle / 'Contents/MacOS'
    macos.mkdir(parents=True, exist_ok=True)
    binary = macos / 'Probe'
    identifier = 'cn.rightmouse.XPCProbe.Server' if name == 'server' else 'cn.rightmouse.XPCProbe.Client'
    info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True}
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(common + (['-D', 'ROGUE'] if name == 'rogue' else []) + [str(source), '-o', str(binary)], check=True)
    signing = ['codesign', '--force', '--sign', '-', '--options', 'runtime']
    if name != 'server': signing += ['--entitlements', str(build / ('no-lookup.entitlements' if name == 'no-lookup' else 'client.entitlements'))]
    subprocess.run(signing + [str(bundle)], check=True)
    result = subprocess.run(['codesign', '-dv', '--verbose=4', str(bundle)], capture_output=True, text=True, check=True)
    hashes[name] = re.search(r'^CDHash=(\w+)', result.stderr, re.M).group(1)
    paths[name] = str(binary)
req = lambda digest: 'cdhash H"' + digest + '"'
plist = {'Label': service, 'ProgramArguments': [paths['server'], 'server', service, '(' + req(hashes['client']) + ') or (' + req(hashes['no-lookup']) + ')'],
         'MachServices': {service: True}, 'StandardOutPath': str(build/'server.log'), 'StandardErrorPath': str(build/'server-error.log')}
(build/'agent.plist').write_bytes(plistlib.dumps(plist))
(build/'metadata.json').write_text(json.dumps({'service':service,'paths':paths,'hashes':hashes},indent=2))
print('Built isolated probe:', build)
print('All signatures ad-hoc; no App Group; client lookup restricted to:', service)
