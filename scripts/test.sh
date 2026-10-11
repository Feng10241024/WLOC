#!/usr/bin/env bash
set -euo pipefail

task_repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_repo_dir"
python3 -m unittest discover -s scripts/tests -v

# Some Command Line Tools releases bundle TestingMacros in a nested folder
# that SwiftPM's default build engine does not discover automatically.
task_swift_bin="$(dirname "$(xcrun --find swiftc)")"
task_testing_plugins="$task_swift_bin/../lib/swift/host/plugins/testing"
if [[ -f "$task_testing_plugins/libTestingMacros.dylib" ]]; then
    swift test -Xswiftc -plugin-path -Xswiftc "$task_testing_plugins" "$@"
else
    swift test "$@"
fi
