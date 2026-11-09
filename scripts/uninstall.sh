#!/bin/zsh
# Removes Phaedrus completely: 🎤 remap and login item, the app, its Services
# shortcut entry, its settings and its microphone permission.
set -euo pipefail
cd "${0:A:h}/.."
ID=io.github.venzellucas.phaedrus

zsh scripts/mic-key.sh off || true
pkill -x Phaedrus 2>/dev/null || true
rm -rf ~/Applications/Phaedrus.app
# drop the shortcut entry from the Services settings
/usr/bin/osascript -l JavaScript - "$ID - Dictate with Phaedrus - dictate" <<'JS' >/dev/null
function run(argv) {
  ObjC.import('Foundation');
  const d = $.NSUserDefaults.alloc.initWithSuiteName('pbs');
  const all = ObjC.deepUnwrap(d.dictionaryForKey('NSServicesStatus')) || {};
  delete all[argv[0]];
  d.setObjectForKey($(all), 'NSServicesStatus');
  d.synchronize;
}
JS
/System/Library/CoreServices/pbs -update
defaults delete "$ID" 2>/dev/null || true
tccutil reset Microphone "$ID" >/dev/null 2>&1 || true
echo "Phaedrus removed."
