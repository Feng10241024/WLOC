#!/usr/bin/env bash
set -euo pipefail
task_repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_repo_dir"
mkdir -p DerivedData/Logs
task_device_id="${1:-}"
task_owns_device=false
task_cleanup() {
    if $task_owns_device; then
        xcrun simctl shutdown "$task_device_id" >/dev/null 2>&1 || true
        xcrun simctl delete "$task_device_id" >/dev/null 2>&1 || true
    fi
}
trap task_cleanup EXIT

if [[ -z "$task_device_id" ]]; then
    task_runtime_and_type="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r.get("platform") == "iOS"]
if not runtimes:
    sys.exit("No iOS Simulator runtime installed. Run: xcodebuild -downloadPlatform iOS -architectureVariant arm64")
runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
phones = [d for d in runtime["supportedDeviceTypes"] if d.get("productFamily") == "iPhone"]
device = next((d for d in phones if d["identifier"].endswith(".iPhone-17")), phones[0])
print(runtime["identifier"], device["identifier"])
')"
    read -r task_runtime_id task_device_type <<< "$task_runtime_and_type"
    task_device_id="$(xcrun simctl create 'WLOC UI Tests' "$task_device_type" "$task_runtime_id")"
    task_owns_device=true
fi

task_stamp="$(date +%Y%m%d-%H%M%S)"
task_log="DerivedData/Logs/ui-tests-$task_stamp.log"
task_result="DerivedData/UITests-$task_stamp.xcresult"
echo "Running favorites UI tests on Simulator $task_device_id..."
if ! xcodebuild -project WLOC.xcodeproj -scheme WLOC -configuration Debug \
    -sdk iphonesimulator -destination "platform=iOS Simulator,id=$task_device_id" \
    -derivedDataPath DerivedData/Simulator -resultBundlePath "$task_result" \
    -only-testing:WLOCUITests -parallel-testing-enabled NO -collect-test-diagnostics never \
    CODE_SIGNING_ALLOWED=NO test \
    > "$task_log" 2>&1; then
    tail -n 80 "$task_log"
    exit 1
fi
tail -n 12 "$task_log"
echo "Test result: $task_repo_dir/$task_result"
echo "Log: $task_repo_dir/$task_log"
