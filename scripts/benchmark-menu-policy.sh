#!/bin/bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_dir/.build/menu-benchmark"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir="${1:-$build_dir/results/$stamp}"
mkdir -p "$build_dir/modules" "$build_dir/module-cache" "$output_dir"
cd "$repo_dir"
sdk=$(xcrun --sdk macosx --show-sdk-path)
snapshot_dir="$build_dir/snapshots/$stamp"
python3 - "$repo_dir" "$snapshot_dir" <<'PY'
import hashlib, json, pathlib, sys
repo, snapshot = map(pathlib.Path, sys.argv[1:])
files = sorted((repo / "Packages/RightMouseCore/Sources/RightMouseCore").rglob("*.swift"))
files += [repo / "tools/MenuPolicyBenchmark/main.swift", repo / "scripts/benchmark-menu-policy.sh"]
hashes = {}
for path in files:
    relative = path.relative_to(repo)
    data = path.read_bytes()
    target = snapshot / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    hashes[str(relative)] = hashlib.sha256(data).hexdigest()
(snapshot / "source-hashes.json").write_text(json.dumps(hashes, indent=2) + "\n")
PY
core_sources=(); while IFS= read -r file; do core_sources+=("$file"); done < <(find "$snapshot_dir/Packages/RightMouseCore/Sources/RightMouseCore" -name '*.swift' -type f | sort)
common=(-sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path "$build_dir/module-cache" -O)
xcrun swiftc "${common[@]}" -parse-as-library -emit-library -static -emit-module -module-name RightMouseCore -emit-module-path "$build_dir/modules/RightMouseCore.swiftmodule" "${core_sources[@]}" -o "$build_dir/libRightMouseCore.a"
xcrun swiftc "${common[@]}" -parse-as-library -I "$build_dir/modules" -L "$build_dir" -lRightMouseCore "$snapshot_dir/tools/MenuPolicyBenchmark/main.swift" -o "$build_dir/MenuPolicyBenchmark"

python3 - "$repo_dir" "$build_dir/MenuPolicyBenchmark" "$output_dir" "$snapshot_dir" <<'PY'
import datetime, hashlib, json, pathlib, platform, subprocess, sys
repo, binary, output, snapshot = map(pathlib.Path, sys.argv[1:])
def command(*arguments):
    result = subprocess.run(arguments, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else "unavailable: " + result.stderr.strip()
metadata = {
    "recordedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "machine": platform.machine(),
    "hardwareModel": command("sysctl", "-n", "hw.model"),
    "processor": command("sysctl", "-n", "machdep.cpu.brand_string"),
    "memoryBytes": command("sysctl", "-n", "hw.memsize"),
    "logicalCPUs": command("sysctl", "-n", "hw.logicalcpu"),
    "macOSVersion": command("sw_vers", "-productVersion"),
    "macOSBuild": command("sw_vers", "-buildVersion"),
    "compiler": command("xcrun", "swiftc", "--version"),
    "developerDirectory": command("xcode-select", "-p"),
    "xcodeVersion": command("xcodebuild", "-version"),
    "sdkVersion": command("xcrun", "--sdk", "macosx", "--show-sdk-version"),
    "optimization": "-O for both RightMouseCore and benchmark; Swift language mode 5; deployment macOS 14.0",
    "gitCommit": command("git", "-C", str(repo), "rev-parse", "HEAD"),
    "sourceSHA256": json.loads((snapshot / "source-hashes.json").read_text()),
    "buildInputSnapshot": str(snapshot.relative_to(repo)),
    "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "scope": "Pure MenuPolicy rule generation only. This evidence does not satisfy AC-027 Finder menu construction acceptance.",
    "coldDefinition": "First timed MenuPolicy call in a new executable process after fixture setup. No warmup; OS/framework caches are not flushed.",
    "timing": "DispatchTime monotonic nanoseconds; fixture setup, validation, recursive output verification, destruction, and JSON encoding outside the measured call interval.",
    "samplePolicy": "100 sequential calls per scenario, all raw samples retained, no outlier removal; each scenario uses a separate new process.",
    "limitations": ["No Finder invocation or NSMenu materialization", "No disk configuration loading, bookmarks, or IPC", "No machine exclusivity or CPU affinity; other work can affect results", "Synthetic maximal stored configuration; normal UI starts with eight action categories", "First process call is not a cold OS boot measurement"]
}
(output / "environment.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
for scenario in ("100-actions-one-selection", "100-actions-1024-selection", "8-actions-one-selection"):
    result = subprocess.run([str(binary), scenario], text=True, capture_output=True, check=True)
    if result.stderr:
        (output / (scenario + ".stderr.txt")).write_text(result.stderr)
    measured = json.loads(result.stdout)
    assert measured["sampleCount"] == len(measured["rawMilliseconds"]) == 100
    assert measured["allSamplesRetained"]
    assert measured["p95Milliseconds"] == sorted(measured["rawMilliseconds"])[94]
    (output / (scenario + ".json")).write_text(result.stdout)
    print(f'{scenario}: first={measured["firstSampleMilliseconds"]:.3f} ms, P95={measured["p95Milliseconds"]:.3f} ms, max={measured["maximumMilliseconds"]:.3f} ms, nodes={measured["totalTreeEntries"]}, samples=100')
print("Pure rule benchmark evidence:", output)
PY
