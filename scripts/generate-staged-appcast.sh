#!/bin/zsh
set -euo pipefail

if (( $# < 3 || $# > 4 )); then
  print -u2 "usage: $0 <archives-directory> <public-download-url-prefix> <sparkle-tools-directory> [keychain-account]"
  exit 64
fi

archives_directory=${1:A}
download_url_prefix=$2
sparkle_tools_directory=${3:A}
keychain_account=${4:-supermac-staged}
generate_appcast_tool="$sparkle_tools_directory/generate_appcast"

[[ -d "$archives_directory" ]] || { print -u2 "archives directory does not exist: $archives_directory"; exit 66; }
[[ -x "$generate_appcast_tool" ]] || { print -u2 "generate_appcast not found: $generate_appcast_tool"; exit 69; }
[[ "$download_url_prefix" == https://* || "$download_url_prefix" == http://127.0.0.1:* || "$download_url_prefix" == http://localhost:* ]] || {
  print -u2 "download URL must be public HTTPS or an explicit localhost fixture"
  exit 65
}

for update_archive in "$archives_directory"/*.(dmg|zip|tar.gz|tar.xz|aar)(N); do
  /usr/bin/shasum -a 256 "$update_archive" > "$update_archive.sha256"
done

"$generate_appcast_tool" \
  --account "$keychain_account" \
  --download-url-prefix "$download_url_prefix" \
  --embed-release-notes \
  --maximum-versions 3 \
  "$archives_directory"

appcast_path="$archives_directory/appcast.xml"
[[ -f "$appcast_path" ]] || { print -u2 "generate_appcast did not create appcast.xml"; exit 70; }
grep -q 'sparkle:edSignature=' "$appcast_path" || { print -u2 "appcast does not contain an EdDSA-signed enclosure"; exit 70; }
grep -q '<!-- sparkle-signatures:' "$appcast_path" || { print -u2 "appcast feed itself is not signed"; exit 70; }
grep -Eq '<sparkle:minimumSystemVersion>14\.2(\.0)?</sparkle:minimumSystemVersion>' "$appcast_path" || { print -u2 "appcast does not advertise macOS 14.2 minimum"; exit 70; }
grep -q '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>' "$appcast_path" || { print -u2 "appcast does not advertise arm64 hardware"; exit 70; }

print "Generated signed staged feed: $appcast_path"
print "Generated SHA-256 sidecars for update archives."
print "Publish archives and release notes first. Publish appcast.xml last."
