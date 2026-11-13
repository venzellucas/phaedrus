#!/bin/zsh
# Native event-loop/settings checks with injected recognizers; no microphone.
set -euo pipefail
cd "${0:A:h}/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
xcrun --sdk macosx swiftc -O -swift-version 6 "${sources[@]}" Tests/SessionSettingsTests.swift -o "$test_dir/session-settings-tests"
"$test_dir/session-settings-tests" "$PWD/build/hud-previews/paused-settings.png"
