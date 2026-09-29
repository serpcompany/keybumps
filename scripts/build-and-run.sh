#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate
xcodebuild -project Keybumps.xcodeproj -scheme Keybumps -configuration Debug -derivedDataPath .derived build
# The Debug build is com.serp.keybumps.debug, so it runs beside the installed app; restart only it.
osascript -e 'tell application id "com.serp.keybumps.debug" to quit' >/dev/null 2>&1 || true
open -n '.derived/Build/Products/Debug/Keybumps.app'
