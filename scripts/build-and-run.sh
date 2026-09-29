#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate
xcodebuild -project Keybumps.xcodeproj -scheme Keybumps -configuration Debug -derivedDataPath .derived build
# The Debug build (com.serp.keybumps.debug) shares the installed app's local data folders, so only one
# may run: quit both before launching it.
for identifier in com.serp.keybumps com.serp.keybumps.debug; do
  osascript -e "tell application id \"$identifier\" to quit" >/dev/null 2>&1 || true
done
installed_running() { pgrep -qf '^/Applications/Keybumps.app/Contents/MacOS/Keybumps' }
for _ in {1..40}; do installed_running || break; sleep 0.25; done
installed_running && { print -u2 "The installed Keybumps did not quit; quit it and rerun."; exit 68; }
open -n '.derived/Build/Products/Debug/Keybumps.app'
