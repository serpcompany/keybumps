#!/bin/zsh
set -euo pipefail

if (( $# != 8 )); then
  print -u2 "usage: $0 <app> <archive> <appcast> <release-notes> <feed-url> <previous-build> <expected-build> <expected-version>"
  exit 64
fi

app_path=${1:A}
archive_path=${2:A}
appcast_path=${3:A}
release_notes_path=${4:A}
feed_url=$5
previous_build=$6
expected_build=$7
expected_version=$8
info_plist="$app_path/Contents/Info.plist"

for required_path in "$app_path" "$archive_path" "$appcast_path" "$release_notes_path" "$info_plist"; do
  [[ -e "$required_path" ]] || { print -u2 "missing required artifact: $required_path"; exit 66; }
done
[[ "$feed_url" == https://* ]] || { print -u2 "production feed URL must use HTTPS"; exit 65; }
[[ "$previous_build" == <-> && "$expected_build" == <-> && "$expected_build" -gt "$previous_build" ]] || {
  print -u2 "CFBundleVersion must be an integer greater than the previously published build"
  exit 65
}

actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
actual_feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist")

[[ "$actual_bundle" == com.serp.supermac ]] || { print -u2 "bundle identity changed: $actual_bundle"; exit 70; }
[[ "$actual_build" == "$expected_build" ]] || { print -u2 "unexpected build: $actual_build"; exit 70; }
[[ "$actual_version" == "$expected_version" ]] || { print -u2 "unexpected version: $actual_version"; exit 70; }
[[ "$actual_feed" == "$feed_url" ]] || { print -u2 "app feed URL does not match publication feed"; exit 70; }
[[ -n "$public_key" ]] || { print -u2 "missing Sparkle public key"; exit 70; }

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
/usr/bin/xcrun stapler validate "$app_path"

archive_name=${archive_path:t}
grep -Fq "$archive_name" "$appcast_path" || { print -u2 "appcast does not reference $archive_name"; exit 70; }
grep -q "sparkle:version=\"$expected_build\"" "$appcast_path" || { print -u2 "appcast build mismatch"; exit 70; }
grep -q "sparkle:shortVersionString=\"$expected_version\"" "$appcast_path" || { print -u2 "appcast marketing version mismatch"; exit 70; }
grep -q 'sparkle:edSignature=' "$appcast_path" || { print -u2 "missing update signature"; exit 70; }
grep -q '<!-- sparkle-signatures:' "$appcast_path" || { print -u2 "appcast feed itself is not signed"; exit 70; }
grep -Eq '<sparkle:minimumSystemVersion>14\.2(\.0)?</sparkle:minimumSystemVersion>' "$appcast_path" || { print -u2 "minimum macOS requirement missing"; exit 70; }
grep -q '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>' "$appcast_path" || { print -u2 "arm64 requirement missing"; exit 70; }

architectures=$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/SuperMac")
[[ "$architectures" == arm64 ]] || { print -u2 "release must contain only arm64; found: $architectures"; exit 70; }

print "Release validation passed for SuperMac $expected_version ($expected_build)."
print "Upload archive and notes first, verify their public URLs, and publish appcast.xml last."
