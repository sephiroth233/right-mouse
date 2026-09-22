#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${RIGHTMOUSE_BUILD_DIR:-$ROOT/.build/native}"
APP="$BUILD/RightMouse.app"
GROUP="${RIGHTMOUSE_APP_GROUP:-group.cn.rightmouse.shared}"
IDENTITY="${RIGHTMOUSE_SIGNING_IDENTITY:--}"
ARCH="${RIGHTMOUSE_ARCH:-$(uname -m)}"
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
python3 - "$ROOT" "$APP" "$GROUP" "$BUILD" <<'PY'
import pathlib, plistlib, sys
root, app, group, build = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
for name, output, bundle in [
    ('RightMouse-Info.plist', app/'Contents/Info.plist', 'cn.rightmouse.RightMouse'),
    ('FinderExtension-Info.plist', app/'Contents/PlugIns/RightMouseFinder.appex/Contents/Info.plist', 'cn.rightmouse.RightMouse.FinderExtension'),
    ('RightMouse.entitlements', build/'RightMouse.entitlements', ''),
    ('FinderExtension.entitlements', build/'FinderExtension.entitlements', '')]:
    raw = (root/'Config'/name).read_text().replace('$(PRODUCT_BUNDLE_IDENTIFIER)', bundle).replace('$(RIGHTMOUSE_APP_GROUP)', group)
    output.write_bytes(plistlib.dumps(plistlib.loads(raw.encode())))
PY
if [[ -d "$ROOT/Resources/Templates" ]]; then
    ditto "$ROOT/Resources/Templates" "$APP/Contents/Resources/Templates"
fi
SIGN_OPTIONS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_OPTIONS+=(--options runtime --timestamp); fi
codesign "${SIGN_OPTIONS[@]}" --entitlements "$BUILD/FinderExtension.entitlements" "$EXT"
codesign "${SIGN_OPTIONS[@]}" --entitlements "$BUILD/RightMouse.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
printf '\nBuilt: %s\n' "$APP"
if [[ "$IDENTITY" == "-" ]]; then
    printf '%s\n' 'Development build with ad-hoc signatures. App Group access and Finder activation must be verified separately; this is not a notarized release.'
fi
