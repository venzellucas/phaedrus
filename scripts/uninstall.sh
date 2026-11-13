#!/bin/zsh
# Removes Phaedrus completely: 🎤 remap and login item, the app, its Services
# shortcut entry, its settings and its microphone permission.
set -euo pipefail
cd "${0:A:h}/.."
ID=io.github.venzellucas.phaedrus

zsh scripts/mic-key.sh off || true
pkill -x Phaedrus 2>/dev/null || true
rm -rf ~/Applications/Phaedrus.app
# drop both shortcut entries from the Services settings
/usr/bin/osascript -l JavaScript - "$ID - Dictate with Phaedrus - dictate" "$ID - Phaedrus Settings - openSettings" <<'JS' >/dev/null
function run(argv) {
  ObjC.import('Foundation');
  const d = $.NSUserDefaults.alloc.initWithSuiteName('pbs');
  const all = ObjC.deepUnwrap(d.dictionaryForKey('NSServicesStatus')) || {};
  for (const key of argv) delete all[key];
  d.setObjectForKey($(all), 'NSServicesStatus');
  d.synchronize;
}
JS
/System/Library/CoreServices/pbs -update
defaults delete "$ID" 2>/dev/null || true
tccutil reset Microphone "$ID" >/dev/null 2>&1 || true
echo "Phaedrus removed."
