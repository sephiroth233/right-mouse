#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${RIGHTMOUSE_BUILD_DIR:-$ROOT/.build/native}"
APP="$BUILD/RightMouse.app"
MODE="${1:---development}"
if [[ "$MODE" != "--development" && "$MODE" != "--release" ]]; then
    printf '%s\n' 'Usage: scripts/package-app.sh [--development|--release]' >&2; exit 2
fi
if [[ "$MODE" == "--release" ]]; then
    : "${RIGHTMOUSE_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
    : "${RIGHTMOUSE_APP_GROUP:?Set the registered App Group identifier}"
    : "${RIGHTMOUSE_NOTARY_PROFILE:?Set the Keychain notarytool profile name}"
    if [[ "$RIGHTMOUSE_SIGNING_IDENTITY" == "-" ]]; then printf '%s\n' 'A release cannot use an ad-hoc signature.' >&2; exit 2; fi
fi
"$ROOT/scripts/build-app.sh"
mkdir -p "$ROOT/dist"
if [[ "$MODE" == "--release" ]]; then
    ARCHIVE="$ROOT/dist/RightMouse-notarization.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$RIGHTMOUSE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    ARCHIVE="$ROOT/dist/RightMouse-0.1.0.zip"
else
    ARCHIVE="$ROOT/dist/RightMouse-0.1.0-development.zip"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
printf '\nPackage: %s\n' "$ARCHIVE"
