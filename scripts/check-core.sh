#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/core-checks"
mkdir -p "$BUILD/modules" "$BUILD/module-cache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CORE=(); while IFS= read -r file; do CORE+=("$file"); done < <(find "$ROOT/Packages/RightMouseCore/Sources/RightMouseCore" -name '*.swift' -type f | sort)
CHECKS=(); while IFS= read -r file; do CHECKS+=("$file"); done < <(find "$ROOT/tools/RightMouseCheck" -name '*.swift' -type f | sort)
COMMON=(-sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$BUILD/module-cache")
xcrun swiftc "${COMMON[@]}" -parse-as-library -enable-testing -emit-library -static -emit-module -module-name RightMouseCore -emit-module-path "$BUILD/modules/RightMouseCore.swiftmodule" "${CORE[@]}" -o "$BUILD/libRightMouseCore.a"
xcrun swiftc "${COMMON[@]}" -I "$BUILD/modules" -L "$BUILD" -lRightMouseCore "${CHECKS[@]}" -o "$BUILD/RightMouseCheck"
if [[ "${1:-}" != "--build-only" ]]; then "$BUILD/RightMouseCheck"; fi
