#!/bin/zsh
# Write latest.json (the latest-release pointer read by the keybumps.app Download buttons and /download/ redirect) from a validated appcast.
# The DMG sits beside the appcast's archive enclosure, so the pointer always matches
# wherever this release's files are published. Publish it with the appcast, last.
#
# usage: write-latest-release-pointer.sh <appcast> <build> <version> <dmg.sha256> <output-json>
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"
(( $# == 5 )) || { print -u2 "usage: $0 <appcast> <build> <version> <dmg.sha256> <output-json>"; exit 64; }
appcast=${1:A}; build=$2; version=$3; checksum_file=${4:A}; output=$5

[[ "$build" == <-> ]] || { print -u2 "build must be an integer"; exit 65; }
[[ -f "$appcast" && -f "$checksum_file" ]] || { print -u2 "missing appcast or DMG checksum"; exit 66; }

archive_url=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$build']]/*[local-name()='enclosure']/@url)" "$appcast")
short_version=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$build']]/*[local-name()='shortVersionString'])" "$appcast")
[[ -n "$archive_url" ]] || { print -u2 "appcast has no enclosure for build $build"; exit 65; }
[[ "$short_version" == "$version" ]] || { print -u2 "appcast version ($short_version) does not match $version"; exit 65; }
if [[ "$archive_url" == https://updates.keybumps.app/* ]]; then
  update_url_is_production_https "$archive_url" || { print -u2 "archive URL is not credential-free HTTPS"; exit 65; }
else
  update_url_is_loopback_fixture "$archive_url" 2>/dev/null || { print -u2 "archive URL must be on updates.keybumps.app"; exit 65; }
fi

dmg_url="${archive_url%/*}/Keybumps-$version.dmg"
sha256=$(/usr/bin/awk '{print $1; exit}' "$checksum_file")
[[ "$sha256" =~ '^[0-9a-f]{64}$' ]] || { print -u2 "DMG checksum is not a SHA-256 digest"; exit 65; }

/usr/bin/python3 - "$output" "$version" "$build" "$dmg_url" "$sha256" <<'PY'
import json, sys
output, version, build, dmg_url, sha256 = sys.argv[1:]
with open(output, "w") as handle:
    json.dump({"version": version, "build": int(build), "dmgURL": dmg_url, "sha256": sha256}, handle, indent=2)
    handle.write("\n")
PY
print "Wrote $output for $version ($build): $dmg_url"
