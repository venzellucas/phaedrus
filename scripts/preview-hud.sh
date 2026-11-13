#!/bin/zsh
# Capture the actual AppKit UI using synthetic input, without a microphone.
set -euo pipefail
cd "${0:A:h}/.."
preview_dir=$(mktemp -d)
trap 'rm -rf "$preview_dir"' EXIT
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
xcrun --sdk macosx swiftc -O -swift-version 6 "${sources[@]}" Tests/HUDPreview.swift -o "$preview_dir/hud-preview"
"$preview_dir/hud-preview" "$PWD/build/hud-previews"
