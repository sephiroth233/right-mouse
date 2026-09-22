#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${RIGHTMOUSE_BUILD_DIR:-$ROOT/.build/native}"
APP="$BUILD/RightMouse.app"
MODE="${1:---development}"
CHECK_ONLY="${2:-}"
if [[ "$MODE" != "--development" && "$MODE" != "--release" ]] || [[ -n "$CHECK_ONLY" && "$CHECK_ONLY" != "--check-signing" ]] || [[ "$#" -gt 2 ]]; then
    printf '%s\n' 'Usage: scripts/package-app.sh [--development|--release] [--check-signing]' >&2; exit 2
fi
if [[ "$MODE" == "--release" ]]; then
    : "${RIGHTMOUSE_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
    : "${RIGHTMOUSE_APP_GROUP:?Set the authorized App Group identifier}"
fi
if [[ "$CHECK_ONLY" == "--check-signing" ]]; then
    if [[ "$MODE" == "--release" ]]; then
        "$ROOT/scripts/build-app.sh" --release --check-signing
    else
        "$ROOT/scripts/build-app.sh" --check-signing
    fi
    exit 0
fi
if [[ "$MODE" == "--release" ]]; then
    # Check identity/profile inputs before requesting the separate notarization credential.
    "$ROOT/scripts/build-app.sh" --release --check-signing
    : "${RIGHTMOUSE_NOTARY_PROFILE:?Set the Keychain notarytool profile name}"
fi
if [[ "$MODE" == "--release" ]]; then
    "$ROOT/scripts/build-app.sh" --release
else
    "$ROOT/scripts/build-app.sh"
fi
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
