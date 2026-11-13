#!/bin/zsh
# Native event-loop/settings checks with injected recognizers; no microphone.
set -euo pipefail
cd "${0:A:h}/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
# Keep assertion messages and source locations in UI test failures. The app
# itself is separately compiled with optimization by build.sh.
xcrun --sdk macosx swiftc -g -swift-version 6 "${sources[@]}" Tests/SessionSettingsTests.swift -o "$test_dir/session-settings-tests"
"$test_dir/session-settings-tests" "$PWD/build/hud-previews/paused-settings.png"
