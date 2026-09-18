#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source_commit=$(git rev-parse HEAD)
source_branch=$(git symbolic-ref --quiet --short HEAD || print detached)
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  source_commit="$source_commit-dirty"
fi
xcodegen generate
xcodebuild -project SuperMac.xcodeproj -scheme SuperMac -configuration Debug -derivedDataPath .derived \
  SUPERMAC_SOURCE_COMMIT="$source_commit" SUPERMAC_SOURCE_BRANCH="$source_branch" \
  SUPERMAC_BUILD_KIND=debug-preview build
killall SuperMac 2>/dev/null || true
open -n '.derived/Build/Products/Debug/SuperMac.app'
