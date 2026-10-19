#!/bin/sh
# TEMPORARY (#565 phase 2), removed before review: does a GitHub-hosted runner get the live release
# index, or does the zone's bot protection refuse it (docs/releases/cloudflare.md)? Never fails.
echo "release-index probe: curl"
curl -sS -o /dev/null -w 'release-index probe: curl HTTP %{http_code}\n' \
  https://updates.keybumps.app/releases.json || echo "release-index probe: curl failed"
echo "release-index probe: the build's own read"
RELEASE_INDEX=live RELEASE_INDEX_OUTPUT=/tmp/release-index-probe.json node scripts/release-index.mjs \
  || echo "release-index probe: the build's read failed"
exit 0
