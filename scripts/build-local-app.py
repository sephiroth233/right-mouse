#!/usr/bin/env python3
"""Build a no-account distribution with a disposable code-signing identity.
No root trust or login-keychain changes. Private key never enters the app/DMG.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get('RIGHTMOUSE_BUILD_DIR', ROOT / '.build/local')).resolve()
BUILD.mkdir(parents=True, exist_ok=True)

def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], **kwargs)
    if result.returncode: raise SystemExit(f'{Path(str(args[0])).name} failed (exit {result.returncode}); no signing secret is printed.')
    return result

env = dict(os.environ, RIGHTMOUSE_BUILD_DIR=str(BUILD), RIGHTMOUSE_SIGNING_IDENTITY='-')
env.pop('RIGHTMOUSE_HOST_PROFILE', None); env.pop('RIGHTMOUSE_EXTENSION_PROFILE', None)
run([ROOT/'scripts/build-app.sh'], env=env)
app = BUILD/'RightMouse.app'
ext = app/'Contents/PlugIns/RightMouseFinder.appex'
bridge = app/'Contents/Library/LaunchServices/RightMouseBridge.app'
(bridge/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
arch = os.environ.get('RIGHTMOUSE_ARCH', os.uname().machine)
run(['xcrun','swiftc','-sdk',sdk,'-target',arch+'-apple-macosx14.0','-swift-version','5','-O',
     '-module-cache-path',BUILD/'module-cache','-I',BUILD/'modules','-L',BUILD,'-lRightMouseCore',
     ROOT/'Services/RightMouseBridge/main.swift','-o',bridge/'Contents/MacOS/RightMouseBridge'])
with tempfile.TemporaryDirectory(prefix='local-signing-', dir=BUILD) as temporary:
    temp = Path(temporary); temp.chmod(0o700)
    keychain = temp/'build.keychain-db'; password = secrets.token_hex(32)
    name = 'RightMouse Local Build ' + secrets.token_hex(8)
    config = temp/'certificate.conf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN='+name+'\n[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
    # codesign also consults the search list to resolve the certificate chain,
    # even with --keychain. Restore the original list after this build.
    original_keychains = shlex.split(subprocess.check_output(
        ['/usr/bin/security', 'list-keychains', '-d', 'user'], text=True))
    try:
        run(['/usr/bin/openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-days','3650','-config',config,
             '-keyout',temp/'key.pem','-out',temp/'cert.pem'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(['/usr/bin/openssl','x509','-in',temp/'cert.pem','-outform','der','-out',temp/'cert.der'])
        fingerprint = hashlib.sha1((temp/'cert.der').read_bytes()).hexdigest()
        run(['/usr/bin/openssl','pkcs12','-export','-inkey',temp/'key.pem','-in',temp/'cert.pem',
             '-out',temp/'identity.p12','-passout','pass:'+password])
        run(['/usr/bin/security','create-keychain','-p',password,keychain], stdout=subprocess.DEVNULL)
        run(['/usr/bin/security','unlock-keychain','-p',password,keychain])
        run(['/usr/bin/security','list-keychains','-d','user','-s',keychain,*original_keychains])
        run(['/usr/bin/security','import',temp/'identity.p12','-k',keychain,'-P',password,'-T','/usr/bin/codesign'], stdout=subprocess.DEVNULL)
        run(['/usr/bin/security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',password,keychain], stdout=subprocess.DEVNULL)
        identities = subprocess.check_output(
            ['/usr/bin/security','find-identity','-p','codesigning',keychain], text=True)
        if fingerprint.lower() not in identities.lower():
            raise SystemExit('Temporary keychain has no matching certificate/private-key identity; signing aborted.')
        bridge_info = {'CFBundleIdentifier':'cn.rightmouse.RightMouse.Bridge','CFBundleExecutable':'RightMouseBridge',
            'CFBundlePackageType':'APPL','CFBundleVersion':'1','LSMinimumSystemVersion':'14.0','LSBackgroundOnly':True}
        (bridge/'Contents/Info.plist').write_bytes(plistlib.dumps(bridge_info))
        for bundle in [bridge, ext, app]:
            path = bundle/'Contents/Info.plist'; info = plistlib.loads(path.read_bytes())
            info['RightMouseAuthenticatedXPC'] = True; info['RightMouseLocalCertificate'] = fingerprint
            info['CFBundleShortVersionString'] = '0.2.3'
            path.write_bytes(plistlib.dumps(info))
        entitlement = plistlib.loads((BUILD/'FinderExtension.entitlements').read_bytes())
        entitlement['com.apple.security.temporary-exception.mach-lookup.global-name'] = ['cn.rightmouse.bridge.'+fingerprint[:16]+'.finder']
        (BUILD/'FinderExtension.entitlements').write_bytes(plistlib.dumps(entitlement))
        for bundle, entitlements in [(bridge,None),(ext,BUILD/'FinderExtension.entitlements'),(app,BUILD/'RightMouse.entitlements')]:
            args = ['/usr/bin/codesign','--force','--sign',fingerprint,'--keychain',keychain,'--options','runtime','--timestamp=none']
            if entitlements: args += ['--entitlements',entitlements]
            run(args + [bundle])
        if os.environ.get('RIGHTMOUSE_TEST_CLIENTS') == '1':
            checks = BUILD/'xpc-checks'; checks.mkdir(exist_ok=True)
            run(['xcrun','swiftc','-sdk',sdk,'-target',arch+'-apple-macosx14.0','-swift-version','5',
                 '-module-cache-path',BUILD/'module-cache','-I',BUILD/'modules','-L',BUILD,'-lRightMouseCore',
                 ROOT/'tools/RightMouseXPCCheck/make-request.swift','-o',checks/'make-request'])
            binary = checks/'XPCCheck'
            run(['xcrun','swiftc','-sdk',sdk,'-target',arch+'-apple-macosx14.0','-swift-version','5','-parse-as-library',
                 '-module-cache-path',BUILD/'module-cache','-I',BUILD/'modules','-L',BUILD,'-lRightMouseCore',
                 ROOT/'tools/RightMouseXPCCheck/main.swift','-o',binary])
            for name in ['valid','rogue','wrong-role','no-lookup']:
                bundle = checks/(name+'.app'); (bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
                shutil.copy2(binary,bundle/'Contents/MacOS/XPCCheck')
                info = {'CFBundleIdentifier': 'cn.rightmouse.WrongRole' if name == 'wrong-role' else 'cn.rightmouse.RightMouse.FinderExtension',
                    'CFBundleExecutable':'XPCCheck','CFBundlePackageType':'APPL','RightMouseAuthenticatedXPC':True,'RightMouseLocalCertificate':fingerprint}
                (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                permissions = dict(entitlement)
                if name == 'no-lookup': permissions.pop('com.apple.security.temporary-exception.mach-lookup.global-name')
                permissions_path = checks/(name+'.entitlements'); permissions_path.write_bytes(plistlib.dumps(permissions))
                run(['/usr/bin/codesign','--force','--sign','-' if name == 'rogue' else fingerprint,
                    '--keychain',keychain,'--options','runtime','--timestamp=none','--entitlements',permissions_path,bundle])
        run(['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',app])
        for bundle in [bridge,ext,app]:
            run(['/usr/bin/codesign','--verify','--strict','-R=certificate leaf = H"'+fingerprint+'"',bundle])
        print('Local XPC app:', app)
        print('Build certificate:', fingerprint, '(identity only, not Apple notarization)')
    finally:
        try:
            run(['/usr/bin/security','list-keychains','-d','user','-s',*original_keychains])
        finally:
            subprocess.run(['/usr/bin/security','delete-keychain',str(keychain)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
