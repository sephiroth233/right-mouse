#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${RIGHTMOUSE_BUILD_DIR:-$ROOT/.build/local}"
if [[ "${1:-}" != "--no-build" ]]; then python3 "$ROOT/scripts/build-local-app.py"; fi
APP="$BUILD/RightMouse.app"
VERSION="$(python3 - "$APP" <<'PY'
import pathlib, plistlib, re, sys
app=pathlib.Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if info.get('RightMouseAuthenticatedXPC') is not True: raise SystemExit('Expected authenticated local distribution build')
version = info.get('CFBundleShortVersionString', '')
if not re.fullmatch(r'\d+\.\d+\.\d+', version): raise SystemExit('Expected X.Y.Z application version')
print(version)
PY
)"
codesign --verify --deep --strict "$APP"
STAGING="$BUILD/dmg-staging"
mkdir -p "$STAGING" "$ROOT/dist"
# Only replace this script's staging copy, never the running source application.
if [[ -d "$STAGING/RightMouse.app" ]]; then rm -rf "$STAGING/RightMouse.app"; fi
ditto "$APP" "$STAGING/RightMouse.app"
ln -sfn /Applications "$STAGING/Applications"
cp "$ROOT/docs/local-install.md" "$STAGING/安装说明.md"
cp "$ROOT/scripts/uninstall-local-service.command" "$STAGING/卸载连接服务.command"
ARCH="$(lipo -archs "$APP/Contents/MacOS/RightMouse" | tr ' ' '-')"
DMG="$ROOT/dist/RightMouse-$VERSION-$ARCH.dmg"
hdiutil create -volname RightMouse -srcfolder "$STAGING" -ov -format UDZO "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf '\n安装包：%s\n' "$DMG"
