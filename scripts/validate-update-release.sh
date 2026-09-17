#!/bin/zsh
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"

if (( $# < 11 || $# > 12 )); then
  print -u2 "usage: $0 <app> <archive> <appcast> <release-notes> <embedded-feed-url> <publication-feed-url> <previous-build> <expected-build> <expected-version> <sparkle-tools-directory> <keychain-account> [--skip-apple-trust-for-fixture]"
  exit 64
fi

app_path=${1:A}
archive_path=${2:A}
appcast_path=${3:A}
release_notes_path=${4:A}
embedded_feed_url=$5
publication_feed_url=$6
previous_build=$7
expected_build=$8
expected_version=$9
sparkle_tools_directory=${10:A}
keychain_account=${11}
fixture_mode=${12:-}
info_plist="$app_path/Contents/Info.plist"
checksum_path="$archive_path.sha256"
sign_update_tool="$sparkle_tools_directory/sign_update"
generate_keys_tool="$sparkle_tools_directory/generate_keys"

[[ -z "$fixture_mode" || "$fixture_mode" == --skip-apple-trust-for-fixture ]] || { print -u2 "unknown option: $fixture_mode"; exit 64; }
if [[ "$fixture_mode" == --skip-apple-trust-for-fixture ]]; then
  update_url_is_loopback_fixture "$embedded_feed_url" || { print -u2 "fixture trust bypass accepts loopback feeds only"; exit 65; }
  update_url_is_loopback_fixture "$publication_feed_url" || { print -u2 "fixture trust bypass accepts loopback feeds only"; exit 65; }
else
  update_url_is_production_https "$embedded_feed_url" || { print -u2 "embedded feed URL must be credential-free, fragment-free HTTPS with a host"; exit 65; }
  update_url_is_production_https "$publication_feed_url" || { print -u2 "publication feed URL must be credential-free, fragment-free HTTPS with a host"; exit 65; }
fi
[[ "$previous_build" == <-> && "$expected_build" == <-> && "$expected_build" -gt "$previous_build" ]] || {
  print -u2 "CFBundleVersion must be an integer greater than the previously published build"
  exit 65
}
for required_path in "$app_path" "$archive_path" "$appcast_path" "$release_notes_path" "$info_plist" "$checksum_path"; do
  [[ -e "$required_path" ]] || { print -u2 "missing required artifact: $required_path"; exit 66; }
done
[[ -x "$sign_update_tool" && -x "$generate_keys_tool" ]] || { print -u2 "official Sparkle verification tools are missing"; exit 69; }

actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
actual_feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist")

[[ "$actual_bundle" == com.serp.supermac ]] || { print -u2 "bundle identity changed: $actual_bundle"; exit 70; }
[[ "$actual_build" == "$expected_build" ]] || { print -u2 "unexpected build: $actual_build"; exit 70; }
[[ "$actual_version" == "$expected_version" ]] || { print -u2 "unexpected version: $actual_version"; exit 70; }
[[ "$actual_feed" == "$embedded_feed_url" ]] || { print -u2 "app feed URL does not match expected embedded feed"; exit 70; }
[[ -n "$public_key" ]] || { print -u2 "missing Sparkle public key"; exit 70; }

if [[ "$fixture_mode" != --skip-apple-trust-for-fixture ]]; then
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
  /usr/bin/xcrun stapler validate "$app_path"
fi

keychain_public_key=$("$generate_keys_tool" --account "$keychain_account" -p | grep -Eo '[A-Za-z0-9+/]{43}=' | tail -1)
[[ -n "$keychain_public_key" && "$keychain_public_key" == "$public_key" ]] || {
  print -u2 "Sparkle verification account does not match the public key embedded in the app"
  exit 70
}

/usr/bin/xmllint --noout "$appcast_path"
"$sign_update_tool" --account "$keychain_account" --verify "$appcast_path"

enclosure_url=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$expected_build']]/*[local-name()='enclosure']/@url)" "$appcast_path")
enclosure_signature=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$expected_build']]/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast_path")
enclosure_length=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$expected_build']]/*[local-name()='enclosure']/@length)" "$appcast_path")
release_notes_url=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$expected_build']]/*[local-name()='releaseNotesLink'])" "$appcast_path")
release_notes_signature=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$expected_build']]/*[local-name()='releaseNotesLink']/@*[local-name()='edSignature'])" "$appcast_path")
release_notes_length=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version' and text()='$expected_build']]/*[local-name()='releaseNotesLink']/@*[local-name()='length'])" "$appcast_path")
appcast_version=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='version'])" "$appcast_path")
appcast_short_version=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='shortVersionString'])" "$appcast_path")
minimum_system_version=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='minimumSystemVersion'])" "$appcast_path")
hardware_requirements=$(/usr/bin/xmllint --xpath "string(//*[local-name()='item'][1]/*[local-name()='hardwareRequirements'])" "$appcast_path")
[[ -n "$enclosure_url" && -n "$enclosure_signature" && -n "$enclosure_length" ]] || { print -u2 "appcast enclosure metadata is incomplete"; exit 70; }
[[ -n "$release_notes_url" && -n "$release_notes_signature" && -n "$release_notes_length" ]] || { print -u2 "appcast linked release-note metadata is incomplete"; exit 70; }
[[ "$appcast_version" == "$expected_build" ]] || { print -u2 "appcast build mismatch"; exit 70; }
[[ "$appcast_short_version" == "$expected_version" ]] || { print -u2 "appcast marketing version mismatch"; exit 70; }
[[ "$minimum_system_version" == 14.2 || "$minimum_system_version" == 14.2.0 ]] || { print -u2 "minimum macOS requirement missing"; exit 70; }
[[ "$hardware_requirements" == arm64 ]] || { print -u2 "arm64 requirement missing"; exit 70; }

actual_size=$(/usr/bin/stat -f '%z' "$archive_path")
[[ "$enclosure_length" == "$actual_size" ]] || { print -u2 "appcast archive length does not match the local archive"; exit 70; }
"$sign_update_tool" --account "$keychain_account" --verify "$archive_path" "$enclosure_signature"
actual_notes_size=$(/usr/bin/stat -f '%z' "$release_notes_path")
[[ "$release_notes_length" == "$actual_notes_size" ]] || { print -u2 "appcast release-note length does not match local notes"; exit 70; }
"$sign_update_tool" --account "$keychain_account" --verify "$release_notes_path" "$release_notes_signature"

expected_checksum=$(awk 'NR == 1 { print $1 }' "$checksum_path")
actual_checksum=$(/usr/bin/shasum -a 256 "$archive_path" | awk '{ print $1 }')
[[ "$expected_checksum" == "$actual_checksum" ]] || { print -u2 "SHA-256 checksum does not match the archive"; exit 70; }

archive_name=${archive_path:t}
release_notes_name=${release_notes_path:t}
[[ "$enclosure_url" == *"$archive_name" ]] || { print -u2 "appcast does not reference $archive_name"; exit 70; }
[[ "$release_notes_url" == *"$release_notes_name" ]] || { print -u2 "appcast does not reference $release_notes_name"; exit 70; }
publication_parent=$(update_url_parent_prefix "$publication_feed_url")
[[ "$enclosure_url" == "$publication_parent"* ]] || { print -u2 "appcast archive URL is outside the publication feed directory"; exit 70; }
[[ "$release_notes_url" == "$publication_parent"* ]] || { print -u2 "appcast release-note URL is outside the publication feed directory"; exit 70; }
grep -q 'sparkle:edSignature=' "$appcast_path" || { print -u2 "missing update signature"; exit 70; }
grep -q '<!-- sparkle-signatures:' "$appcast_path" || { print -u2 "appcast feed itself is not signed"; exit 70; }

architectures=$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/SuperMac")
[[ "$architectures" == arm64 ]] || { print -u2 "release must contain only arm64; found: $architectures"; exit 70; }

print "Release validation passed for SuperMac $expected_version ($expected_build)."
print "Upload archive and notes first, verify their public URLs, and publish appcast.xml last."
