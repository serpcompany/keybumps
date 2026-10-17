#!/bin/zsh
# Reinstall the app that apps/macos/scripts/build-qa-candidate.sh backed up most recently.
# usage: apps/macos/scripts/restore-previous-keybumps.sh [backup.app]
set -euo pipefail

installed_app=/Applications/Keybumps.app
qa_root=${KEYBUMPS_QA_ROOT:-$HOME/Library/Developer/Keybumps-QA}
backup=${1:-$(cat "$qa_root/backups/latest" 2>/dev/null || true)}
[[ -n "$backup" && -d "$backup" ]] || { print -u2 "no backup found; pass a path from $qa_root/backups"; exit 66; }
codesign --verify --deep --strict "$backup"

# Match only the installed copy, never a Debug build or test host running from DerivedData.
installed_running() { pgrep -qf "^$installed_app/Contents/MacOS/Keybumps" }
if installed_running; then
  osascript -e 'tell application id "com.serp.keybumps" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do installed_running || break; sleep 0.25; done
  installed_running && { print -u2 "Keybumps did not quit; close it and rerun"; exit 68; }
fi

# Builds since #490 turn off macOS's ⇧⌘5 (symbolic hotkey 184) for Record Screen; earlier ones
# manage only ⇧⌘3 and ⇧⌘4 (28 and 30), so ⇧⌘5 would stay off with nothing answering it. If
# Keybumps took it over, turn it back on as Keybumps does and drop it from what Keybumps took over;
# a restored build that manages it takes it again when it starts.
give_back_shift_command_5() {
  osascript -l JavaScript - <<'JXA'
ObjC.import('Foundation');
(() => {
  const keybumps = $.NSUserDefaults.alloc.initWithSuiteName('com.serp.keybumps');
  const owned = ObjC.deepUnwrap(keybumps.stringArrayForKey('takenOverSystemShortcuts')) || [];
  if (!owned.includes('184')) return 'not taken';
  const system = $.NSUserDefaults.alloc.initWithSuiteName('com.apple.symbolichotkeys');
  const stored = system.dictionaryForKey('AppleSymbolicHotKeys');
  if (stored.isNil() || stored.objectForKey('184').isNil()) return 'unreadable';
  const hotKeys = stored.mutableCopy;
  const entry = hotKeys.objectForKey('184').mutableCopy;
  entry.setObjectForKey($.NSNumber.numberWithBool(true), 'enabled');
  hotKeys.setObjectForKey(entry, '184');
  system.setObjectForKey(hotKeys, 'AppleSymbolicHotKeys');
  keybumps.setObjectForKey($(owned.filter((id) => id !== '184')), 'takenOverSystemShortcuts');
  return 'on';
})();
JXA
}
case "$(give_back_shift_command_5 2>/dev/null || print failed)" in
  on) /System/Library/PrivateFrameworks/SystemAdministration.framework/Versions/A/Resources/activateSettings -u >/dev/null 2>&1 \
        || print -u2 "turned macOS's ⇧⌘5 back on; it may answer only after you log out and in" ;;
  "not taken") ;;
  *) print -u2 "couldn't turn macOS's ⇧⌘5 back on; turn on Screenshot and recording options in System Settings › Keyboard › Keyboard Shortcuts › Screenshots" ;;
esac

rm -rf "$installed_app"
ditto "$backup" "$installed_app"
open "$installed_app"
print "Restored $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed_app/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_app/Contents/Info.plist")) from $backup"
