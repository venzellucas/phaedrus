#!/bin/zsh
# Build Phaedrus.app and install it to ~/Applications (no admin needed).
#   scripts/build.sh               build and install
#   scripts/build.sh --no-install  build into ./build only (used by CI)
set -euo pipefail
cd "${0:A:h}/.."
APP="$PWD/build/Phaedrus.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 6 Sources/*.swift -o "$APP/Contents/MacOS/Phaedrus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns scripts/mic-key.sh "$APP/Contents/Resources/"
codesign -s - -f -i io.github.venzellucas.phaedrus "$APP"
[[ "${1:-}" == "--no-install" ]] && { echo "Built $APP"; exit 0; }

pkill -x Phaedrus 2>/dev/null || true
rm -rf ~/Applications/Phaedrus.app
mkdir -p ~/Applications && cp -R "$APP" ~/Applications/
# Only the installed copy may provide the Service: drop the build copy macOS may have registered.
"$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf build
"$LSREGISTER" -f ~/Applications/Phaedrus.app
/System/Library/CoreServices/pbs -update
echo "Installed ~/Applications/Phaedrus.app"
