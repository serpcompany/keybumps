#!/bin/zsh
# Reinstall the app that scripts/build-qa-candidate.sh backed up most recently.
# usage: scripts/restore-previous-keybumps.sh [backup.app]
set -euo pipefail

installed_app=/Applications/Keybumps.app
qa_root=${KEYBUMPS_QA_ROOT:-$HOME/Library/Developer/Keybumps-QA}
backup=${1:-$(cat "$qa_root/backups/latest" 2>/dev/null || true)}
[[ -n "$backup" && -d "$backup" ]] || { print -u2 "no backup found; pass a path from $qa_root/backups"; exit 66; }
codesign --verify --deep --strict "$backup"

if pgrep -xq Keybumps; then
  osascript -e 'tell application id "com.serp.keybumps" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -xq Keybumps || break; sleep 0.25; done
  pgrep -xq Keybumps && { print -u2 "Keybumps did not quit; close it and rerun"; exit 68; }
fi

rm -rf "$installed_app"
ditto "$backup" "$installed_app"
open "$installed_app"
print "Restored $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed_app/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_app/Contents/Info.plist")) from $backup"
