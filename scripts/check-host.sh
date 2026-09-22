#!/bin/bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_dir/.build/host-checks"
binary="$build_dir/RightMouseHostCheck"

cd "$repo_dir"
mkdir -p "$build_dir/modules" "$build_dir/module-cache"
sdk=$(xcrun --sdk macosx --show-sdk-path)
core_sources=(); while IFS= read -r file; do core_sources+=("$file"); done < <(find Packages/RightMouseCore/Sources/RightMouseCore -name '*.swift' -type f | sort)
common=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$build_dir/module-cache")
xcrun swiftc "${common[@]}" -parse-as-library -emit-library -static -emit-module -module-name RightMouseCore -emit-module-path "$build_dir/modules/RightMouseCore.swiftmodule" "${core_sources[@]}" -o "$build_dir/libRightMouseCore.a"
xcrun swiftc "${common[@]}" \
  -parse-as-library \
  -I "$build_dir/modules" -L "$build_dir" -lRightMouseCore \
  Apps/RightMouse/AppModel.swift \
  Apps/RightMouse/ApplicationLauncher.swift \
  Apps/RightMouse/HostController.swift \
  Apps/RightMouse/TaskFollowupStore.swift \
  tools/RightMouseHostCheck/main.swift \
  tools/RightMouseHostCheck/FollowupChecks.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework FinderSync \
  -framework ServiceManagement \
  -framework UniformTypeIdentifiers \
  -o "$binary"

"$binary"
