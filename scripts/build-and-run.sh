#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate
xcodebuild -project SuperMac.xcodeproj -scheme SuperMac -configuration Debug -derivedDataPath .derived build
killall SuperMac 2>/dev/null || true
open -n '.derived/Build/Products/Debug/SuperMac.app'
