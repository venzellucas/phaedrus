#!/bin/zsh
# Check the real Foundation Models path with synthetic text and no microphone.
set -euo pipefail
cd "${0:A:h}/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun --sdk macosx swiftc -O -swift-version 6 Sources/TranscriptMerger.swift Sources/CleanupPlan.swift Sources/CleanupDeadline.swift Sources/SmartCleanup.swift Tests/NativeCleanupSmoke.swift -o "$test_dir/native-cleanup"
"$test_dir/native-cleanup"
