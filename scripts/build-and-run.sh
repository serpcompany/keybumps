#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate
xcodebuild -project SERPCompanion.xcodeproj -scheme SERPCompanion -configuration Debug -derivedDataPath .derived build
killall SERPCompanion 2>/dev/null || true
open -n '.derived/Build/Products/Debug/SuperMac.app'
