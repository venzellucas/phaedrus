#!/bin/zsh
# Pure transcript alignment checks; no microphone, speech models or app install.
set -euo pipefail
cd "${0:A:h}/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -swift-version 6 Sources/TranscriptMerger.swift Tests/TranscriptMergerTests.swift -o "$test_dir/merge-tests"
"$test_dir/merge-tests"
swiftc -O -swift-version 6 Sources/TranscriptMerger.swift Sources/CleanupPlan.swift Sources/CleanupDeadline.swift Tests/SmartCleanupTests.swift -o "$test_dir/cleanup-tests"
"$test_dir/cleanup-tests"
