#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  print -u2 "usage: $0 <appcast> <public-feed-url> <--dry-run|--verify-live>"
  exit 64
fi

appcast_path=${1:A}
public_feed_url=$2
mode=$3
[[ -f "$appcast_path" ]] || { print -u2 "missing appcast: $appcast_path"; exit 66; }
[[ "$mode" == --dry-run || "$mode" == --verify-live ]] || { print -u2 "mode must be --dry-run or --verify-live"; exit 64; }
[[ "$public_feed_url" == https://* || "$public_feed_url" == http://127.0.0.1:* || "$public_feed_url" == http://localhost:* ]] || {
  print -u2 "feed must be public HTTPS or an explicit localhost fixture"
  exit 65
}
/usr/bin/xmllint --noout "$appcast_path"

asset_urls=(${(f)"$(/usr/bin/xmllint --xpath '//*[local-name()="enclosure"]/@url' "$appcast_path" | grep -Eo 'https?://[^" ]+')"})
notes_urls=(${(f)"$(/usr/bin/xmllint --xpath '//*[local-name()="releaseNotesLink"]/text()' "$appcast_path" 2>/dev/null | grep -Eo 'https?://[^<[:space:]]+' || true)"})
(( ${#asset_urls} > 0 )) || { print -u2 "appcast contains no downloadable update assets"; exit 70; }

print "Phase 1 — publish and verify immutable assets:"
for asset_url in $asset_urls $notes_urls; do
  print "  $asset_url"
  if [[ "$mode" == --verify-live ]]; then
    /usr/bin/curl --fail --silent --show-error --location --head "$asset_url" >/dev/null
  fi
done

print "Phase 2 — publish the pointer last:"
print "  $public_feed_url"
if [[ "$mode" == --verify-live ]]; then
  /usr/bin/curl --fail --silent --show-error --location --head "$public_feed_url" >/dev/null
fi
print "Publication ${mode#--} check passed; the workflow never checks/publishes the appcast before its assets."
