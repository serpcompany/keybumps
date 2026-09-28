#!/bin/zsh
# Publish a release prepared by build-update-release.sh to the updates.keybumps.app R2 bucket.
# Dry run by default; uploads only with --publish, which requires owner authorization.
#
# Phase 1 uploads immutable assets to releases/<build>/ (refusing to overwrite different bytes)
# and verifies each public copy byte for byte. Phase 2 then publishes the pointers last:
# appcast.xml (production) or staging/appcast.xml (staging), plus latest.json on production.
#
# usage: publish-release.sh <release-output-directory> <production|staging> [--publish]
# env:   CLOUDFLARE_API_TOKEN  bucket-scoped R2 write token (read by wrangler; never stored here)
#        KEYBUMPS_WRANGLER     wrangler command (default: wrangler)
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"

(( $# == 2 || $# == 3 )) || { print -u2 "usage: $0 <release-output-directory> <production|staging> [--publish]"; exit 64; }
output=${1:A}; channel=$2; mode=${3:-}
[[ "$channel" == production || "$channel" == staging ]] || { print -u2 "channel must be production or staging"; exit 64; }
[[ -z "$mode" || "$mode" == --publish ]] || { print -u2 "unknown option: $mode"; exit 64; }

bucket=keybumps-updates
origin=https://updates.keybumps.app
# Tests may point at a loopback fixture origin; nothing else may replace production.
if [[ -n "${KEYBUMPS_RELEASE_ORIGIN:-}" ]]; then
  update_url_is_loopback_fixture "$KEYBUMPS_RELEASE_ORIGIN/appcast.xml" 2>/dev/null || { print -u2 "KEYBUMPS_RELEASE_ORIGIN must be loopback"; exit 65; }
  origin=${KEYBUMPS_RELEASE_ORIGIN%/}
fi
wrangler=(${=KEYBUMPS_WRANGLER:-wrangler})

assets_dir=$output/publication/assets
last_dir=$output/publication/publish-last
appcast=$last_dir/appcast.xml
latest=$last_dir/latest.json
[[ -d "$assets_dir" && -f "$appcast" ]] || { print -u2 "not a prepared release: missing publication/assets or publish-last/appcast.xml"; exit 66; }
[[ "$channel" == staging || -f "$latest" ]] || { print -u2 "production publication requires publish-last/latest.json"; exit 66; }

build=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='version'])" "$appcast")
version=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='shortVersionString'])" "$appcast")
enclosure=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='enclosure']/@url)" "$appcast")
[[ "$build" == <-> && -n "$version" ]] || { print -u2 "appcast has no build/version"; exit 65; }
release_prefix="releases/$build"
[[ "$enclosure" == "https://updates.keybumps.app/$release_prefix/Keybumps-$version.zip" ]] || {
  print -u2 "appcast enclosure must be https://updates.keybumps.app/$release_prefix/Keybumps-$version.zip (found $enclosure)"; exit 65; }
if [[ -f "$latest" ]]; then
  /usr/bin/python3 - "$latest" "$build" "$version" <<'PY' || { print -u2 "latest.json does not match the appcast release"; exit 65; }
import json, sys
data = json.load(open(sys.argv[1]))
assert data["build"] == int(sys.argv[2]) and data["version"] == sys.argv[3]
assert data["dmgURL"] == f"https://updates.keybumps.app/releases/{sys.argv[2]}/Keybumps-{sys.argv[3]}.dmg"
PY
fi

content_type() {
  case $1 in
    *.zip) print application/zip ;;
    *.dmg) print application/x-apple-diskimage ;;
    *.md) print "text/markdown; charset=utf-8" ;;
    *.sha256) print "text/plain; charset=utf-8" ;;
    *.xml) print "application/xml; charset=utf-8" ;;
    *.json) print "application/json; charset=utf-8" ;;
    *) print -u2 "unsupported release file: $1"; return 1 ;;
  esac
}
immutable_cache="public, max-age=31536000, immutable"
pointer_cache="public, max-age=60, must-revalidate"

typeset -a asset_files pointer_files pointer_keys
asset_files=("$assets_dir"/*(N.))
(( ${#asset_files} > 0 )) || { print -u2 "no release assets"; exit 66; }
for required in "Keybumps-$version.zip" "Keybumps-$version.dmg" "Keybumps-$version.md"; do
  [[ -f "$assets_dir/$required" ]] || { print -u2 "missing asset $required"; exit 66; }
done
for file in $asset_files; do content_type "$file" >/dev/null; done
if [[ "$channel" == production ]]; then
  pointer_files=("$appcast" "$latest"); pointer_keys=(appcast.xml latest.json)
else
  pointer_files=("$appcast"); pointer_keys=(staging/appcast.xml)
fi

print "Keybumps $version ($build) → $channel via R2 bucket $bucket"
print "Phase 1 (immutable assets):"
for file in $asset_files; do print "  $release_prefix/${file:t}"; done
print "Phase 2 (pointers, last):"
for key in $pointer_keys; do print "  $key"; done
if [[ "$mode" != --publish ]]; then
  print "Dry run only. Re-run with --publish (owner authorization required) to upload."
  exit 0
fi

sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}' }
remote_sha() {
  local target=$1 temporary
  temporary=$(/usr/bin/mktemp)
  if /usr/bin/curl --fail --silent --location --max-time 120 "$origin/$target?verify=$RANDOM$RANDOM" --output "$temporary"; then
    sha "$temporary"
  fi
  /bin/rm -f "$temporary"
}
put() {
  local file=$1 key=$2 cache=$3
  $wrangler r2 object put "$bucket/$key" --file "$file" --content-type "$(content_type "$file")" --cache-control "$cache" --remote >/dev/null
}
verify() {
  local file=$1 key=$2 expected actual
  expected=$(sha "$file")
  for _ in {1..10}; do
    actual=$(remote_sha "$key")
    [[ "$actual" == "$expected" ]] && { print "  verified $key"; return 0; }
    sleep 3
  done
  print -u2 "public $key does not match the local file"; return 1
}

print "Publishing phase 1…"
for file in $asset_files; do
  key="$release_prefix/${file:t}"
  existing=$(remote_sha "$key")
  if [[ -n "$existing" ]]; then
    [[ "$existing" == "$(sha "$file")" ]] || { print -u2 "refusing to overwrite immutable $key with different bytes"; exit 70; }
    print "  already published $key"
    continue
  fi
  put "$file" "$key" "$immutable_cache"
  verify "$file" "$key"
done

print "Publishing phase 2…"
for index in {1..${#pointer_files}}; do
  put "${pointer_files[$index]}" "${pointer_keys[$index]}" "$pointer_cache"
done
for index in {1..${#pointer_files}}; do
  verify "${pointer_files[$index]}" "${pointer_keys[$index]}"
done
print "Published Keybumps $version ($build) to $channel."
