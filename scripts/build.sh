#!/bin/zsh
# Build Phaedrus.app and install it to ~/Applications (no admin needed).
#   scripts/build.sh               build and install
#   scripts/build.sh --no-install  build into ./build only (used by CI)
set -euo pipefail
cd "${0:A:h}/.."

case "${1:-}" in
  ""|--no-install) ;;
  *) echo "usage: scripts/build.sh [--no-install]" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { echo "usage: scripts/build.sh [--no-install]" >&2; exit 2; }

[[ "$(uname -s)" == Darwin ]] || { echo "Phaedrus requires macOS 26 or later." >&2; exit 1; }
OS_VERSION=$(sw_vers -productVersion)
(( ${OS_VERSION%%.*} >= 26 )) || { echo "Phaedrus requires macOS 26 or later (found $OS_VERSION)." >&2; exit 1; }
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null) || {
  echo "Install Xcode Command Line Tools with xcode-select --install, then try again." >&2
  exit 1
}
(( ${SDK_VERSION%%.*} >= 26 )) || {
  echo "Phaedrus requires the macOS 26 SDK or later (found $SDK_VERSION). Update your Xcode Command Line Tools." >&2
  exit 1
}
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
# Keep builds made with newer SDKs compatible with the minimum in Info.plist.
export MACOSX_DEPLOYMENT_TARGET=26.0

APP="$PWD/build/Phaedrus.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun --sdk macosx swiftc -sdk "$SDK_PATH" -O -swift-version 6 Sources/*.swift -o "$APP/Contents/MacOS/Phaedrus"
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
