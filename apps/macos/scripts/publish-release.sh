#!/bin/zsh
# Publish a release prepared by build-update-release.sh to the updates.keybumps.app R2 bucket.
# Dry run by default; uploads only with --publish, which requires owner authorization. A production
# dry run with --check-index also reads the live release index and checks this release merges into
# it (publish-release-index.sh --check-live), uploading nothing, so a problem shows before approval.
#
# Phase 1 uploads immutable assets to releases/<build>/ (refusing to overwrite different bytes)
# and verifies each uploaded object byte for byte, read back from R2. Phase 2 then publishes the pointers last:
# appcast.xml (production) or staging/appcast.xml (staging), plus latest.json on production.
# On production, phase 3 then adds the release to the release index, releases.json, through
# publish-release-index.sh, so the index lists only releases that are live.
#
# usage: publish-release.sh <release-output-directory> <production|staging> [--check-index|--publish]
# env:   CLOUDFLARE_API_TOKEN  bucket-scoped R2 token (read by wrangler; never stored here): read for
#                              --check-index, read and write for --publish
#        KEYBUMPS_WRANGLER     wrangler command (default: wrangler)
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"
source "${0:A:h}/lib/r2-objects.sh"

(( $# == 2 || $# == 3 )) || { print -u2 "usage: $0 <release-output-directory> <production|staging> [--check-index|--publish]"; exit 64; }
output=${1:A}; channel=$2; mode=${3:-}
[[ "$channel" == production || "$channel" == staging ]] || { print -u2 "channel must be production or staging"; exit 64; }
[[ -z "$mode" || "$mode" == --check-index || "$mode" == --publish ]] || { print -u2 "unknown option: $mode"; exit 64; }
[[ "$mode" != --check-index || "$channel" == production ]] || { print -u2 "--check-index applies to production only: staging has no release index"; exit 64; }

bucket=keybumps-updates
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

typeset -a asset_files pointer_files pointer_keys
asset_files=("$assets_dir"/*(N.))
(( ${#asset_files} > 0 )) || { print -u2 "no release assets"; exit 66; }
for required in "Keybumps-$version.zip" "Keybumps-$version.dmg" "Keybumps-$version.md"; do
  [[ -f "$assets_dir/$required" ]] || { print -u2 "missing asset $required"; exit 66; }
done
for file in $asset_files; do content_type "$file" >/dev/null; done
if [[ "$channel" == production ]]; then
  pointer_files=("$appcast" "$latest"); pointer_keys=(appcast.xml latest.json)
  # The release index entry: this release's DMG and the release date its appcast item carries (ADR 0011).
  released_at=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='releaseDate'])" "$appcast")
  [[ -n "$released_at" ]] || { print -u2 "appcast has no release date (<keybumps:releaseDate>) for the release index"; exit 65; }
  index_entry=$(/usr/bin/mktemp)
  trap '/bin/rm -f "$index_entry"' EXIT
  /usr/bin/python3 "${0:A:h}/lib/release_index.py" entry "$version" "$build" "$released_at" "$index_entry"
else
  pointer_files=("$appcast"); pointer_keys=(staging/appcast.xml)
fi

print "Keybumps $version ($build) → $channel via R2 bucket $bucket"
print "Phase 1 (immutable assets):"
for file in $asset_files; do print "  $release_prefix/${file:t}"; done
print "Phase 2 (pointers, last):"
for key in $pointer_keys; do print "  $key"; done
if [[ "$channel" == production ]]; then
  print "Phase 3 (release index, after the pointers):"
  print "  releases.json adds $version ($build), released $released_at"
fi
if [[ "$mode" != --publish ]]; then
  [[ "$mode" != --check-index ]] || "${0:A:h}/publish-release-index.sh" "$index_entry" --check-live
  print "Dry run only. Re-run with --publish (owner authorization required) to upload."
  exit 0
fi

print "Publishing phase 1…"
for file in $asset_files; do
  key="$release_prefix/${file:t}"
  existing=$(remote_sha "$key")
  if [[ -n "$existing" ]]; then
    [[ "$existing" == "$(sha "$file")" ]] || { print -u2 "refusing to overwrite immutable $key with different bytes"; exit 70; }
    print "  already published $key"
    continue
  fi
  put "$file" "$key" "$R2_IMMUTABLE_CACHE"
  verify "$file" "$key"
done

print "Publishing phase 2…"
for index in {1..${#pointer_files}}; do
  put "${pointer_files[$index]}" "${pointer_keys[$index]}" "$R2_POINTER_CACHE"
done
for index in {1..${#pointer_files}}; do
  verify "${pointer_files[$index]}" "${pointer_keys[$index]}"
done
if [[ "$channel" == production ]]; then
  print "Publishing phase 3…"
  "${0:A:h}/publish-release-index.sh" "$index_entry" --publish
fi
print "Published Keybumps $version ($build) to $channel."
