#!/bin/zsh
# Add releases to releases.json, the release index on the production release origin
# (https://updates.keybumps.app/releases.json, format in docs/releases/cloudflare.md). The website
# reads it when it builds, to link each release's DMG on /changelog/ (#565).
# Dry run by default: checks the additions and prints them, reading nothing. --check-live also
# reads the live index from R2 and merges the additions into it, uploading nothing, so a live list
# that is unreadable, invalid, or disagrees with the additions shows up before a release is
# approved. With --publish, which requires owner authorization, it reads the live index from R2,
# adds the releases (a missing index starts a new list; an unreadable or invalid one stops before
# any upload), uploads the result, and verifies it byte for byte, read back from R2.
#
# publish-release.sh calls this after each production release, with that release's entry. The
# one-time backfill of earlier releases is the same call with the committed list:
#   publish-release-index.sh apps/macos/scripts/release-index-backfill.json [--check-live|--publish]
#
# usage: publish-release-index.sh <additions.json> [--check-live|--publish]
# env:   CLOUDFLARE_API_TOKEN  bucket-scoped R2 token (read by wrangler; never stored here): read for
#                              --check-live, read and write for --publish
#        KEYBUMPS_WRANGLER     wrangler command (default: wrangler)
set -euo pipefail
source "${0:A:h}/lib/r2-objects.sh"
release_index=("/usr/bin/python3" "${0:A:h}/lib/release_index.py")

(( $# == 1 || $# == 2 )) || { print -u2 "usage: $0 <additions.json> [--check-live|--publish]"; exit 64; }
additions=${1:A}; mode=${2:-}
[[ -z "$mode" || "$mode" == --check-live || "$mode" == --publish ]] || { print -u2 "unknown option: $mode"; exit 64; }
[[ -f "$additions" ]] || { print -u2 "no such file: $additions"; exit 66; }

bucket=keybumps-updates
wrangler=(${=KEYBUMPS_WRANGLER:-wrangler})
key=releases.json

work=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$work"' EXIT
if [[ -z "$mode" ]]; then
  # Merging into an empty list checks the additions without reading R2.
  print "Release index $key in R2 bucket $bucket would add:"
  $release_index merge "$additions" "$work/additions.json"
  print "Dry run only. Re-run with --publish (owner authorization required) to add these to the live index."
  exit 0
fi

# Reads the live index and merges the additions into $work/$key; stops when it can't.
merge_into_live() {
  local result=0
  remote_get "$key" "$work/live.json" || result=$?
  case $result in
    0) $release_index merge "$additions" "$work/$key" "$work/live.json" ;;
    2) print "  no live $key yet: starting a new list"
       $release_index merge "$additions" "$work/$key" ;;
    *) exit 1 ;;
  esac
}

if [[ "$mode" == --check-live ]]; then
  print "Release index $key in R2 bucket $bucket, checked against the live list, would become:"
  merge_into_live
  print "Checked only: nothing was uploaded."
  exit 0
fi

print "Publishing the release index $key…"
merge_into_live
put "$work/$key" "$key" "$R2_POINTER_CACHE"
verify "$work/$key" "$key"
print "Published $key."
