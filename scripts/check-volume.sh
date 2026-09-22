#!/bin/bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/rightmouse-volume.XXXXXX")
image="$work_dir/test-volume.dmg"
mount_point="$work_dir/mount"
host_fixture="$work_dir/host"
device=""
cleanup() {
  if [[ -n "$device" ]]; then
    if ! hdiutil detach "$device" >/dev/null 2>&1; then
      echo "Refusing to remove test work directory: non-force detach failed for $device; retained at $work_dir" >&2
      return
    fi
    device=""
  fi
  local mount_table
  if ! mount_table=$(mount); then
    echo "Refusing to remove test work directory: unable to read mount table; retained at $work_dir" >&2
    return
  fi
  if [[ "$mount_table" == *" on $mount_point "* ]]; then
    echo "Refusing to remove test work directory: $mount_point is still mounted; retained at $work_dir" >&2
    return
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

mkdir -p "$mount_point" "$host_fixture"
chmod 700 "$work_dir" "$mount_point" "$host_fixture"
hdiutil create -size 96m -fs APFS -volname "RightMouseCheck-$$" -type UDIF "$image" >/dev/null
attach_output=$(hdiutil attach -nobrowse -noautoopen -mountpoint "$mount_point" "$image")
device=$(printf '%s\n' "$attach_output" | awk '/^\/dev\// { print $1; exit }')
if [[ -z "$device" ]]; then echo "Unable to identify test image device" >&2; exit 1; fi

build_dir="$work_dir/build"
mkdir -p "$build_dir/modules" "$build_dir/module-cache"
sdk=$(xcrun --sdk macosx --show-sdk-path)
core_sources=(); while IFS= read -r file; do core_sources+=("$file"); done < <(find "$repo_dir/Packages/RightMouseCore/Sources/RightMouseCore" -name '*.swift' -type f | sort)
common=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$build_dir/module-cache")
xcrun swiftc "${common[@]}" -parse-as-library -emit-library -static -emit-module -module-name RightMouseCore -emit-module-path "$build_dir/modules/RightMouseCore.swiftmodule" "${core_sources[@]}" -o "$build_dir/libRightMouseCore.a"
xcrun swiftc "${common[@]}" -parse-as-library -I "$build_dir/modules" -L "$build_dir" -lRightMouseCore "$repo_dir/tools/RightMouseVolumeCheck/main.swift" -framework AppKit -o "$build_dir/RightMouseVolumeCheck"
"$build_dir/RightMouseVolumeCheck" "$host_fixture" "$mount_point"
hdiutil detach "$device" >/dev/null
device=""
