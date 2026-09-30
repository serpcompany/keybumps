#!/bin/zsh
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"

if (( $# != 5 )); then
  print -u2 "usage: $0 <local-appcast> <local-archive> <local-release-notes> <public-feed-url> <--dry-run|--verify-live>"
  exit 64
fi

appcast_path=${1:A}
archive_path=${2:A}
release_notes_path=${3:A}
public_feed_url=$4
mode=$5
for local_artifact in "$appcast_path" "$archive_path" "$release_notes_path"; do
  [[ -f "$local_artifact" ]] || { print -u2 "missing local artifact: $local_artifact"; exit 66; }
done
[[ "$mode" == --dry-run || "$mode" == --verify-live ]] || { print -u2 "mode must be --dry-run or --verify-live"; exit 64; }
update_url_is_production_https "$public_feed_url" 2>/dev/null || update_url_is_loopback_fixture "$public_feed_url" 2>/dev/null || {
  print -u2 "feed must be public HTTPS or an explicit localhost fixture"
  exit 65
}
/usr/bin/xmllint --noout "$appcast_path"

archive_url=$(/usr/bin/xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="enclosure"]/@url)' "$appcast_path")
notes_url=$(/usr/bin/xmllint --xpath 'string(//*[local-name()="item"][1]/*[local-name()="releaseNotesLink"])' "$appcast_path")
[[ -n "$archive_url" && -n "$notes_url" ]] || { print -u2 "appcast must contain archive and release-note URLs"; exit 70; }

print "Phase 1 — publish and verify immutable assets:"
print "  $archive_url"
print "  $notes_url"
print "Phase 2 — publish the pointer last:"
print "  $public_feed_url"

if [[ "$mode" == --verify-live ]]; then
  verification_directory=$(mktemp -d /tmp/keybumps-publication-verify.XXXXXX)
  trap 'rm -rf -- "$verification_directory"' EXIT
  /usr/bin/curl --fail --silent --show-error --location "$archive_url" --output "$verification_directory/archive"
  /usr/bin/curl --fail --silent --show-error --location "$notes_url" --output "$verification_directory/notes"
  cmp -s "$archive_path" "$verification_directory/archive" || { print -u2 "deployed archive bytes differ from the validated archive"; exit 70; }
  cmp -s "$release_notes_path" "$verification_directory/notes" || { print -u2 "deployed release-note bytes differ from the validated notes"; exit 70; }
  [[ "$(/usr/bin/shasum -a 256 "$archive_path" | awk '{print $1}')" == "$(/usr/bin/shasum -a 256 "$verification_directory/archive" | awk '{print $1}')" ]] || { print -u2 "deployed archive checksum differs"; exit 70; }
  /usr/bin/curl --fail --silent --show-error --location "$public_feed_url" --output "$verification_directory/appcast.xml"
  cmp -s "$appcast_path" "$verification_directory/appcast.xml" || { print -u2 "deployed appcast bytes and embedded signatures differ from the validated appcast"; exit 70; }
  /usr/bin/xmllint --noout "$verification_directory/appcast.xml"
fi

print "Publication ${mode#--} check passed; archive and notes are verified before the appcast pointer."
