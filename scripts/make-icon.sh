#!/bin/zsh
# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift
set -euo pipefail
cd "${0:A:h}/.."
T=$(mktemp -d); trap 'rm -rf $T' EXIT
swift scripts/make-icon.swift $T/icon.png >/dev/null
mkdir $T/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s $T/icon.png --out $T/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $T/icon.png --out $T/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $T/AppIcon.iconset -o Resources/AppIcon.icns
cp $T/icon.png docs/icon.png 2>/dev/null || { mkdir -p docs && cp $T/icon.png docs/icon.png; }
echo "wrote Resources/AppIcon.icns"
