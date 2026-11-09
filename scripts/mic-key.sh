#!/bin/zsh
# mic-key.sh on|off|apply: make the 🎤 (Dictation, F5) key send F18, which triggers Phaedrus.
#
#   on    remap now and install a login item that re-applies it after every restart
#   off   restore the 🎤 key (Apple Dictation) and remove the login item
#   apply remap now only (what the login item runs)
#
# Only the 🎤 entry is added or removed; other hidutil key remaps you have are kept.
set -euo pipefail

LABEL=io.github.venzellucas.phaedrus.mic-key
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SELF="${0:A}"

# Prints the current UserKeyMapping with the 🎤→F18 entry added (add) or removed (remove), as JSON.
merged_mapping() {
  /usr/bin/osascript -l JavaScript - "$1" "$(/usr/bin/hidutil property --get UserKeyMapping)" <<'JS'
function run(argv) {
  ObjC.import('Foundation');
  const SRC = 0xC000000CF;   // consumer usage "Voice Command" = 🎤 key
  const DST = 0x70000006D;   // keyboard usage F18
  const [mode, raw] = argv;
  let list = [];
  if (raw && raw.trim() !== '(null)') {
    const data = $(raw).dataUsingEncoding($.NSUTF8StringEncoding);
    list = ObjC.deepUnwrap($.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 0, null, null)) || [];
  }
  list = list
    .map(m => ({ HIDKeyboardModifierMappingSrc: Number(m.HIDKeyboardModifierMappingSrc),
                 HIDKeyboardModifierMappingDst: Number(m.HIDKeyboardModifierMappingDst) }))
    .filter(m => m.HIDKeyboardModifierMappingSrc !== SRC);
  if (mode === 'add') list.push({ HIDKeyboardModifierMappingSrc: SRC, HIDKeyboardModifierMappingDst: DST });
  return JSON.stringify({ UserKeyMapping: list });
}
JS
}

apply() { /usr/bin/hidutil property --set "$(merged_mapping "$1")" >/dev/null; }

case "${1:-}" in
  apply)
    apply add ;;
  on)
    apply add
    mkdir -p "${AGENT:h}"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/zsh</string><string>$SELF</string><string>apply</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    # bootstrap right after bootout can fail with "Input/output error"; retry briefly
    for attempt in 1 2 3; do
      launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null && break
      [[ $attempt == 3 ]] && { echo "The 🎤 key is remapped, but the login item could not be installed." >&2; exit 1; }
      sleep 1
    done
    echo "🎤 key now triggers Phaedrus (also after restarts)." ;;
  off)
    apply remove
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "🎤 key restored to Apple Dictation." ;;
  *)
    echo "usage: ${0:t} on|off|apply" >&2
    exit 2 ;;
esac
