#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate
xcodebuild -project Keybumps.xcodeproj -scheme Keybumps -configuration Debug -derivedDataPath .derived build
killall Keybumps 2>/dev/null || true
open -n '.derived/Build/Products/Debug/Keybumps.app'
