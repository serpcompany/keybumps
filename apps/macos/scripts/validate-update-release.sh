#!/bin/zsh
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"

if (( $# < 11 || $# > 12 )); then
  print -u2 "usage: $0 <app> <archive> <appcast> <release-notes> <embedded-feed-url> <publication-feed-url> <previous-build> <expected-build> <expected-version> <sparkle-tools-directory> <keychain-account> [--skip-apple-trust-for-fixture|--signed-not-notarized]"
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

[[ -z "$fixture_mode" || "$fixture_mode" == --skip-apple-trust-for-fixture || "$fixture_mode" == --signed-not-notarized ]] || { print -u2 "unknown option: $fixture_mode"; exit 64; }
if [[ "$fixture_mode" == --skip-apple-trust-for-fixture ]]; then
  update_url_is_loopback_fixture "$embedded_feed_url" || { print -u2 "fixture trust bypass accepts loopback feeds only"; exit 65; }
  update_url_is_loopback_fixture "$publication_feed_url" || { print -u2 "fixture trust bypass accepts loopback feeds only"; exit 65; }
else
  update_url_is_production_https "$embedded_feed_url" || { print -u2 "embedded feed URL must be credential-free, fragment-free HTTPS with a host"; exit 65; }
  update_url_is_production_https "$publication_feed_url" || { print -u2 "publication feed URL must be credential-free, fragment-free HTTPS with a host"; exit 65; }
  update_url_is_keybumps_feed "$embedded_feed_url" || { print -u2 "embedded feed must use updates.keybumps.app"; exit 65; }
  update_url_is_keybumps_feed "$publication_feed_url" || { print -u2 "publication feed must use updates.keybumps.app"; exit 65; }
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
requires_signed_feed=$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$info_plist")
verifies_before_extraction=$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$info_plist")

[[ "$actual_bundle" == com.serp.keybumps ]] || { print -u2 "bundle identity changed: $actual_bundle"; exit 70; }
# What's New shows the notes the app carries (#225).
[[ -s "$app_path/Contents/Resources/WhatsNew.md" ]] || { print -u2 "the app doesn't carry its release notes (WhatsNew.md)"; exit 70; }
[[ "$actual_build" == "$expected_build" ]] || { print -u2 "unexpected build: $actual_build"; exit 70; }
[[ "$actual_version" == "$expected_version" ]] || { print -u2 "unexpected version: $actual_version"; exit 70; }
[[ "$actual_feed" == "$embedded_feed_url" ]] || { print -u2 "app feed URL does not match expected embedded feed"; exit 70; }
[[ -n "$public_key" ]] || { print -u2 "missing Sparkle public key"; exit 70; }
[[ "$requires_signed_feed" == true && "$verifies_before_extraction" == true ]] || {
  print -u2 "Sparkle signed-feed and verify-before-extraction requirements must be enabled"
  exit 70
}

if [[ "$fixture_mode" == --signed-not-notarized ]]; then
  # Interim releases without notarization still require a valid, strict Developer ID signature.
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
  # Capture first: with pipefail, grep -q exiting early can fail the pipeline on a valid app.
  signature=$(/usr/bin/codesign -dv --verbose=2 "$app_path" 2>&1)
  [[ "$signature" == *$'\nAuthority=Developer ID Application:'* && "$signature" == *$'\nTeamIdentifier=W3GXL2NQQP'* ]] || {
    print -u2 "app is not signed with the Keybumps Developer ID Application certificate"
    exit 70
  }
elif [[ "$fixture_mode" != --skip-apple-trust-for-fixture ]]; then
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
  /usr/bin/xcrun stapler validate "$app_path"
fi

# CI verifies with the key file (see generate-staged-appcast.sh); local runs use the keychain.
# The file must hold the same key as the keychain account checked below; CI's setup step imports
# the file into that account, so never export KEYBUMPS_SPARKLE_KEY_FILE by hand.
typeset -a verify_key
if [[ -n "${KEYBUMPS_SPARKLE_KEY_FILE:-}" ]]; then
  verify_key=(--ed-key-file "$KEYBUMPS_SPARKLE_KEY_FILE")
else
  verify_key=(--account "$keychain_account")
fi
keychain_public_key=$("$generate_keys_tool" --account "$keychain_account" -p | grep -Eo '[A-Za-z0-9+/]{43}=' | tail -1)
[[ -n "$keychain_public_key" && "$keychain_public_key" == "$public_key" ]] || {
  print -u2 "Sparkle verification account does not match the public key embedded in the app"
  exit 70
}

/usr/bin/xmllint --noout "$appcast_path"
"$sign_update_tool" $verify_key --verify "$appcast_path"

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
"$sign_update_tool" $verify_key --verify "$archive_path" "$enclosure_signature"
actual_notes_size=$(/usr/bin/stat -f '%z' "$release_notes_path")
[[ "$release_notes_length" == "$actual_notes_size" ]] || { print -u2 "appcast release-note length does not match local notes"; exit 70; }
"$sign_update_tool" $verify_key --verify "$release_notes_path" "$release_notes_signature"

expected_checksum=$(awk 'NR == 1 { print $1 }' "$checksum_path")
actual_checksum=$(/usr/bin/shasum -a 256 "$archive_path" | awk '{ print $1 }')
[[ "$expected_checksum" == "$actual_checksum" ]] || { print -u2 "SHA-256 checksum does not match the archive"; exit 70; }

archive_name=${archive_path:t}
release_notes_name=${release_notes_path:t}
[[ "$enclosure_url" == *"$archive_name" ]] || { print -u2 "appcast does not reference $archive_name"; exit 70; }
[[ "$release_notes_url" == *"$release_notes_name" ]] || { print -u2 "appcast does not reference $release_notes_name"; exit 70; }
publication_parent=$(update_url_parent_prefix "$publication_feed_url")
# Keybumps feeds (production and staging) share immutable assets under releases/<build>/;
# loopback fixture feeds keep assets beside the feed.
if [[ "$publication_parent" == https://updates.keybumps.app/* ]]; then
  asset_prefix="https://updates.keybumps.app/releases/$expected_build/"
else
  asset_prefix=$publication_parent
fi
[[ "$enclosure_url" == "$asset_prefix"* ]] || { print -u2 "appcast archive URL is outside $asset_prefix"; exit 70; }
[[ "$release_notes_url" == "$asset_prefix"* ]] || { print -u2 "appcast release-note URL is outside $asset_prefix"; exit 70; }
grep -q 'sparkle:edSignature=' "$appcast_path" || { print -u2 "missing update signature"; exit 70; }
grep -q '<!-- sparkle-signatures:' "$appcast_path" || { print -u2 "appcast feed itself is not signed"; exit 70; }

architectures=$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/Keybumps")
[[ "$architectures" == arm64 ]] || { print -u2 "release must contain only arm64; found: $architectures"; exit 70; }

print "Release validation passed for Keybumps $expected_version ($expected_build)."
print "Upload archive and notes first, verify their public URLs, and publish appcast.xml last."
