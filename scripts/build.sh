#!/bin/zsh
# Build Phaedrus.app and install it to ~/Applications (no admin needed).
set -euo pipefail
cd "${0:A:h}/.."
APP=build/Phaedrus.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 6 Sources/*.swift -o "$APP/Contents/MacOS/Phaedrus"
cp Resources/Info.plist $APP/Contents/Info.plist
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Contents/Resources/
cp scripts/mic-key.sh $APP/Contents/Resources/
codesign -s - -f -i io.github.venzellucas.phaedrus "$APP"
[[ "${1:-}" == "--no-install" ]] && { echo "Built $APP"; exit 0; }
pkill -x Phaedrus 2>/dev/null || true
rm -rf ~/Applications/Phaedrus.app
mkdir -p ~/Applications && cp -R $APP ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Phaedrus.app
/System/Library/CoreServices/pbs -update
echo "Installed ~/Applications/Phaedrus.app"
