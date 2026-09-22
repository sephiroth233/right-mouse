#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${RIGHTMOUSE_BUILD_DIR:-$ROOT/.build/native}"
APP="$BUILD/RightMouse.app"
GROUP="${RIGHTMOUSE_APP_GROUP:-group.cn.rightmouse.shared}"
IDENTITY="${RIGHTMOUSE_SIGNING_IDENTITY:--}"
HOST_PROFILE="${RIGHTMOUSE_HOST_PROFILE:-}"
EXTENSION_PROFILE="${RIGHTMOUSE_EXTENSION_PROFILE:-}"
ARCH="${RIGHTMOUSE_ARCH:-$(uname -m)}"
MODE=development
CHECK_ONLY=false
for argument in "$@"; do
    case "$argument" in
        --release) MODE=release ;;
        --check-signing) CHECK_ONLY=true ;;
        *) printf '%s\n' 'Usage: scripts/build-app.sh [--release] [--check-signing]' >&2; exit 2 ;;
    esac
done
mkdir -p "$BUILD"
VALIDATOR="$BUILD/validate-signing-inputs.py"
# This helper is a generated build artifact, not a credential store. Profiles are
# decoded in memory; only authorization metadata and CMS snapshots stay in .build.
cat > "$VALIDATOR" <<'PY'
import datetime, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, sys, tempfile

def fail(message):
    raise ValueError(message)
def run(command, **kwargs):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        fail('Command failed: ' + command[0] + ' ' + command[1] + ' (exit ' + str(result.returncode) + ')')
    return result

def permits(pattern, value):
    if not isinstance(pattern, str): return False
    # Provisioning allowlists support a terminal wildcard, not arbitrary globs.
    return pattern == value or (pattern.endswith('*') and '*' not in pattern[:-1] and value.startswith(pattern[:-1]))

def decode_profile(path, label, bundle, group, expected_team, mode, snapshot):
    source = pathlib.Path(path).expanduser()
    if not source.is_file(): fail(label + ' profile does not exist or is not a regular file.')
    if source.stat().st_size > 4 * 1024 * 1024: fail(label + ' profile exceeds 4 MiB.')
    cms = source.read_bytes()
    result = subprocess.run(['/usr/bin/security', 'cms', '-D'], input=cms, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode: fail(label + ' profile is not a decodable CMS provisioning profile.')
    try: profile = plistlib.loads(result.stdout)
    except Exception: fail(label + ' profile does not contain a valid plist.')
    if not isinstance(profile, dict): fail(label + ' profile root must be a dictionary.')
    now = datetime.datetime.now(datetime.timezone.utc)
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime.datetime): fail(label + ' profile has no valid expiration date.')
    if expires.tzinfo is None: expires = expires.replace(tzinfo=datetime.timezone.utc)
    if expires <= now: fail(label + ' profile has expired.')
    created = profile.get('CreationDate')
    if isinstance(created, datetime.datetime):
        if created.tzinfo is None: created = created.replace(tzinfo=datetime.timezone.utc)
        if created > now + datetime.timedelta(minutes=5): fail(label + ' profile creation date is in the future.')
    if not set(profile.get('Platform', [])) & {'OSX', 'macOS'}: fail(label + ' profile is not for macOS.')
    teams = profile.get('TeamIdentifier')
    if not isinstance(teams, list) or len(teams) != 1 or not re.fullmatch(r'[A-Z0-9]{10}', str(teams[0])):
        fail(label + ' profile must identify one real 10-character developer team.')
    team = teams[0]
    if expected_team and team != expected_team: fail(label + ' profile team does not match the expected signing team.')
    entitlements = profile.get('Entitlements')
    if not isinstance(entitlements, dict): fail(label + ' profile has no entitlement allowlist.')
    if entitlements.get('com.apple.developer.team-identifier') != team:
        fail(label + ' profile team entitlement does not match TeamIdentifier.')
    app_key = 'com.apple.application-identifier' if 'com.apple.application-identifier' in entitlements else 'application-identifier'
    allowed_app = entitlements.get(app_key)
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    if not isinstance(prefixes, list) or not prefixes: fail(label + ' profile has no application identifier prefix.')
    candidates = [str(prefix).rstrip('.') + '.' + bundle for prefix in prefixes]
    resolved_app = next((candidate for candidate in candidates if permits(allowed_app, candidate)), None)
    if not resolved_app: fail(label + ' profile does not authorize the bundle identifier ' + bundle + '.')
    groups = entitlements.get('com.apple.security.application-groups', [])
    if not isinstance(groups, list) or not any(permits(value, group) for value in groups):
        fail(label + ' profile does not authorize the selected App Group.')
    if mode == 'release' and (entitlements.get('get-task-allow') or entitlements.get('com.apple.security.get-task-allow')):
        fail(label + ' profile enables debugger attachment and cannot be used for a release.')
    certificates = profile.get('DeveloperCertificates', [])
    if not isinstance(certificates, list) or not certificates or not all(isinstance(cert, bytes) for cert in certificates):
        fail(label + ' profile has no signing certificate allowlist.')
    snapshot.write_bytes(cms); snapshot.chmod(0o600)
    return {'team': team, 'applicationKey': app_key, 'applicationIdentifier': resolved_app,
            'expires': expires.isoformat(), 'certificateDigests': [hashlib.sha256(cert).hexdigest() for cert in certificates],
            'snapshot': str(snapshot), 'profileDigest': hashlib.sha256(cms).hexdigest()}

def preflight(root, build, group, identity, mode, host_profile, extension_profile):
    if not re.fullmatch(r'(?:group|[A-Z0-9]{10})\.[A-Za-z0-9][A-Za-z0-9.-]*', group) or '..' in group or group.endswith('.'):
        fail('App Group must use group.<name> or a real 10-character Team ID prefix.')
    expected_team = os.environ.get('RIGHTMOUSE_TEAM_ID', '')
    if expected_team and not re.fullmatch(r'[A-Z0-9]{10}', expected_team): fail('RIGHTMOUSE_TEAM_ID must contain 10 uppercase letters/digits.')
    if not group.startswith('group.'):
        prefix = group.split('.')[0]
        if expected_team and expected_team != prefix: fail('App Group prefix does not match RIGHTMOUSE_TEAM_ID.')
        expected_team = prefix
    if mode == 'release' and identity == '-': fail('A release requires a Developer ID Application identity, not ad-hoc signing.')
    if identity == '-' and (host_profile or extension_profile): fail('Provisioning profiles cannot authorize an ad-hoc signature. Set a real signing identity.')
    if identity != '-' and group.startswith('group.') and (not host_profile or not extension_profile):
        fail('A signed group. build requires both RIGHTMOUSE_HOST_PROFILE and RIGHTMOUSE_EXTENSION_PROFILE.')
    inputs = build / 'signing-inputs'
    inputs.mkdir(mode=0o700, exist_ok=True); inputs.chmod(0o700)
    profiles = {}
    for label, path, bundle in [('host', host_profile, 'cn.rightmouse.RightMouse'), ('extension', extension_profile, 'cn.rightmouse.RightMouse.FinderExtension')]:
        snapshot = inputs / (label + '.provisionprofile')
        if path:
            profiles[label] = decode_profile(path, label, bundle, group, expected_team, mode, snapshot)
            if expected_team and profiles[label]['team'] != expected_team: fail('Host and extension profiles have different teams.')
            expected_team = profiles[label]['team']
        elif snapshot.exists(): snapshot.unlink()
    if identity != '-':
        identities = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']).stdout.decode(errors='replace')
        matches = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"', identities, re.M)
        if not any(identity.upper() == digest.upper() or identity == name for digest, name in matches):
            fail('The requested signing identity is not an exact valid Keychain identity name or SHA-1.')
    metadata = {'group': group, 'identity': identity, 'mode': mode, 'expectedTeam': expected_team, 'profiles': profiles}
    (inputs/'metadata.json').write_text(json.dumps(metadata)); (inputs/'metadata.json').chmod(0o600)
    for name, label in [('RightMouse.entitlements', 'host'), ('FinderExtension.entitlements', 'extension')]:
        raw = (root/'Config'/name).read_text().replace('$(RIGHTMOUSE_APP_GROUP)', group)
        entitlement = plistlib.loads(raw.encode())
        if label in profiles:
            profile = profiles[label]
            entitlement[profile['applicationKey']] = profile['applicationIdentifier']
            entitlement['com.apple.developer.team-identifier'] = profile['team']
        (build/name).write_bytes(plistlib.dumps(entitlement))
    print('Signing input checks passed (' + mode + '). Actual certificate/profile agreement is checked after signing.')

def embed(root, build, app):
    metadata = json.loads((build/'signing-inputs/metadata.json').read_text())
    locations = [('host', app, 'RightMouse-Info.plist', 'cn.rightmouse.RightMouse'),
                 ('extension', app/'Contents/PlugIns/RightMouseFinder.appex', 'FinderExtension-Info.plist', 'cn.rightmouse.RightMouse.FinderExtension')]
    for label, bundle, name, bundle_id in locations:
        contents = bundle/'Contents'
        raw = (root/'Config'/name).read_text().replace('$(PRODUCT_BUNDLE_IDENTIFIER)', bundle_id).replace('$(RIGHTMOUSE_APP_GROUP)', metadata['group'])
        (contents/'Info.plist').write_bytes(plistlib.dumps(plistlib.loads(raw.encode())))
        target = contents/'embedded.provisionprofile'
        # Always remove an older embedded profile before the current build is signed.
        if target.exists() or target.is_symlink(): target.unlink()
        profile = metadata['profiles'].get(label)
        if profile:
            data = pathlib.Path(profile['snapshot']).read_bytes()
            if hashlib.sha256(data).hexdigest() != profile['profileDigest']: fail('Profile snapshot changed after validation.')
            target.write_bytes(data)

def verify(build, app):
    metadata = json.loads((build/'signing-inputs/metadata.json').read_text())
    teams = []
    for label, bundle, name in [('host', app, 'RightMouse.entitlements'), ('extension', app/'Contents/PlugIns/RightMouseFinder.appex', 'FinderExtension.entitlements')]:
        actual_data = run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(bundle)]).stdout
        try: actual = plistlib.loads(actual_data)
        except Exception: fail(label + ' signed entitlements could not be decoded.')
        expected = plistlib.loads((build/name).read_bytes())
        if actual != expected: fail(label + ' signed entitlements do not match the checked build entitlements.')
        profile = metadata['profiles'].get(label)
        embedded = bundle/'Contents/embedded.provisionprofile'
        if not profile and (embedded.exists() or embedded.is_symlink()): fail(label + ' has an unexpected stale provisioning profile.')
        if metadata['identity'] == '-': continue
        description = run(['/usr/bin/codesign', '-d', '--verbose=4', str(bundle)]).stderr.decode(errors='replace')
        found = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', description, re.M)
        if not found: fail(label + ' signature has no real TeamIdentifier.')
        team = found.group(1); teams.append(team)
        if metadata['expectedTeam'] and team != metadata['expectedTeam']: fail(label + ' signature team does not match the profile/App Group team.')
        if not metadata['group'].startswith('group.') and not metadata['group'].startswith(team + '.'):
            fail(label + ' unprovisioned App Group prefix does not match its actual signature team.')
        # Require an Apple-issued certificate chain. A self-signed label is not identity proof.
        requirement = 'anchor apple generic'
        if metadata['mode'] == 'release': requirement += ' and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        run(['/usr/bin/codesign', '--verify', '--strict', '-R=' + requirement, str(bundle)])
        if profile:
            if not embedded.is_file() or hashlib.sha256(embedded.read_bytes()).hexdigest() != profile['profileDigest']:
                fail(label + ' embedded profile differs from the validated input.')
            with tempfile.TemporaryDirectory(prefix='cert-check-', dir=str(build)) as temporary:
                prefix = str(pathlib.Path(temporary)/'cert-')
                run(['/usr/bin/codesign', '-d', '--extract-certificates', prefix, str(bundle)])
                leaf = pathlib.Path(prefix + '0')
                if not leaf.is_file() or hashlib.sha256(leaf.read_bytes()).hexdigest() not in profile['certificateDigests']:
                    fail(label + ' signing certificate is not authorized by its provisioning profile.')
            expiry = datetime.datetime.fromisoformat(profile['expires'])
            if expiry <= datetime.datetime.now(datetime.timezone.utc): fail(label + ' profile expired while building.')
    if len(set(teams)) > 1: fail('Host and extension were signed by different teams.')
    if metadata['identity'] == '-':
        print('Ad-hoc entitlements match; no stale embedded profiles. App Group authorization remains unverified.')
    else:
        print('Signed entitlements, team, embedded profiles and certificate allowlists verified.')

try:
    command = sys.argv[1]
    if command == 'preflight':
        root, build = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
        preflight(root, build, *sys.argv[4:])
    elif command == 'embed': embed(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4]))
    elif command == 'verify': verify(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
    else: fail('Unknown signing validation phase.')
except (ValueError, OSError, KeyError, TypeError, plistlib.InvalidFileException) as error:
    print('Signing validation failed: ' + str(error), file=sys.stderr)
    sys.exit(2)
PY
python3 "$VALIDATOR" preflight "$ROOT" "$BUILD" "$GROUP" "$IDENTITY" "$MODE" "$HOST_PROFILE" "$EXTENSION_PROFILE"
if [[ "$CHECK_ONLY" == true ]]; then exit 0; fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD/modules" "$BUILD/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns/RightMouseFinder.appex/Contents/MacOS"
EXT="$APP/Contents/PlugIns/RightMouseFinder.appex"
CORE_SOURCES=(); while IFS= read -r file; do CORE_SOURCES+=("$file"); done < <(find "$ROOT/Packages/RightMouseCore/Sources/RightMouseCore" -name '*.swift' -type f | sort)
APP_SOURCES=(); while IFS= read -r file; do APP_SOURCES+=("$file"); done < <(find "$ROOT/Apps/RightMouse" -name '*.swift' -type f | sort)
EXT_SOURCES=(); while IFS= read -r file; do EXT_SOURCES+=("$file"); done < <(find "$ROOT/Extensions/RightMouseFinder" -name '*.swift' -type f | sort)
COMMON=(-sdk "$SDK" -target "$ARCH-apple-macosx14.0" -swift-version 5 -module-cache-path "$BUILD/module-cache" -O)
printf '%s\n' 'Building RightMouseCore…'
xcrun swiftc "${COMMON[@]}" -parse-as-library -emit-library -static -emit-module -module-name RightMouseCore -emit-module-path "$BUILD/modules/RightMouseCore.swiftmodule" "${CORE_SOURCES[@]}" -o "$BUILD/libRightMouseCore.a"
printf '%s\n' 'Building RightMouse.app…'
xcrun swiftc "${COMMON[@]}" -parse-as-library -I "$BUILD/modules" -L "$BUILD" -lRightMouseCore -module-name RightMouse "${APP_SOURCES[@]}" -o "$APP/Contents/MacOS/RightMouse"
printf '%s\n' 'Building Finder extension…'
xcrun swiftc "${COMMON[@]}" -parse-as-library -application-extension -I "$BUILD/modules" -L "$BUILD" -lRightMouseCore -module-name RightMouseFinder "${EXT_SOURCES[@]}" -framework FinderSync -framework AppKit -Xlinker -e -Xlinker _NSExtensionMain -o "$EXT/Contents/MacOS/RightMouseFinder"
python3 "$VALIDATOR" embed "$ROOT" "$BUILD" "$APP"
if [[ -d "$ROOT/Resources/Templates" ]]; then ditto "$ROOT/Resources/Templates" "$APP/Contents/Resources/Templates"; fi
SIGN_OPTIONS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_OPTIONS+=(--options runtime --timestamp); fi
codesign "${SIGN_OPTIONS[@]}" --entitlements "$BUILD/FinderExtension.entitlements" "$EXT"
codesign "${SIGN_OPTIONS[@]}" --entitlements "$BUILD/RightMouse.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
python3 "$VALIDATOR" verify "$BUILD" "$APP"
printf '\nBuilt: %s\n' "$APP"
if [[ "$IDENTITY" == "-" ]]; then
    printf '%s\n' 'Development build with ad-hoc signatures. App Group access and Finder activation must be verified separately; this is not a notarized release.'
fi
