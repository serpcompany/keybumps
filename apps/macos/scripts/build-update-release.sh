#!/bin/zsh
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"

if (( $# != 8 )); then
  print -u2 "usage: $0 <version> <build> <previous-build> <feed-url> <public-key> <sparkle-key-account> <sparkle-tools-directory> <output-directory>"
  exit 64
fi

release_version=$1
release_build=$2
previous_build=$3
feed_url=$4
public_key=$5
sparkle_key_account=$6
sparkle_tools_directory=${7:A}
output_directory=${8:A}
# The app folder holds the Xcode project and these scripts. Release notes stay in the
# repository's docs/releases/, which is not inside the app folder once the app moves.
app_root=${0:A:h:h}

[[ "$release_build" == <-> && "$previous_build" == <-> && "$release_build" -gt "$previous_build" ]] || { print -u2 "build must be an integer greater than previous-build"; exit 65; }
update_url_is_production_https "$feed_url" || { print -u2 "release feed must be credential-free, fragment-free public HTTPS with a host"; exit 65; }
update_url_is_keybumps_feed "$feed_url" || { print -u2 "release feed must use updates.keybumps.app"; exit 65; }
[[ -n "$public_key" && -n "$sparkle_key_account" ]] || { print -u2 "signing/notary configuration is incomplete"; exit 65; }
repository_root=$(git -C "$app_root" rev-parse --show-toplevel) || { print -u2 "cannot find the repository root from $app_root: run from a Git checkout, not an export"; exit 66; }
release_notes="$repository_root/docs/releases/v$release_version.md"
[[ -f "$release_notes" ]] || { print -u2 "missing release notes: $release_notes"; exit 66; }
[[ ! -e "$output_directory" ]] || { print -u2 "refusing to overwrite output directory: $output_directory"; exit 73; }
# The disk image's layout tool (scripts/dmg/requirements.txt) needs Python 3.10+; check before the long build.
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null || { print -u2 "packaging the disk image needs python3 3.10 or later on PATH"; exit 69; }

mkdir -p "$output_directory/archive" "$output_directory/export" "$output_directory/feed" "$output_directory/publication/assets" "$output_directory/publication/publish-last"
cd "$app_root"
# CI (KEYBUMPS_MANUAL_SIGNING=1) signs explicitly with the imported Developer ID certificate;
# local builds keep Xcode automatic signing.
typeset -a signing_settings
export_options="$app_root/scripts/ExportOptions-DeveloperID.plist"
if [[ -n "${KEYBUMPS_MANUAL_SIGNING:-}" ]]; then
  signing_settings=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" DEVELOPMENT_TEAM=W3GXL2NQQP PROVISIONING_PROFILE_SPECIFIER=)
  export_options="$app_root/scripts/ExportOptions-DeveloperID-Manual.plist"
fi
xcodegen generate
xcodebuild -project Keybumps.xcodeproj -scheme Keybumps-Release -configuration Release \
  -archivePath "$output_directory/archive/Keybumps.xcarchive" \
  MARKETING_VERSION="$release_version" CURRENT_PROJECT_VERSION="$release_build" \
  KEYBUMPS_UPDATE_FEED_URL="$feed_url" KEYBUMPS_UPDATE_PUBLIC_KEY="$public_key" \
  KEYBUMPS_RELEASE_NOTES="$release_notes" $signing_settings archive
xcodebuild -exportArchive \
  -archivePath "$output_directory/archive/Keybumps.xcarchive" \
  -exportPath "$output_directory/export" \
  -exportOptionsPlist "$export_options"

app_path="$output_directory/export/Keybumps.app"
# What's New shows the notes the app carries (#225): exactly this release's.
cmp -s "$app_path/Contents/Resources/WhatsNew.md" "$release_notes" || { print -u2 "the app doesn't carry this release's notes (Contents/Resources/WhatsNew.md)"; exit 70; }
# KEYBUMPS_SKIP_NOTARIZATION=1 is an owner-authorized interim mode for when notarization is
# unavailable: the app stays Developer ID-signed and strictly verified, but is not notarized, so
# Gatekeeper asks customers to allow it on first open.
typeset -a trust_mode
if [[ "${KEYBUMPS_SKIP_NOTARIZATION:-}" == 1 ]]; then
  print -u2 "warning: KEYBUMPS_SKIP_NOTARIZATION=1; this release is signed but NOT notarized"
  trust_mode=(--signed-not-notarized)
else
  notary_archive="$output_directory/Keybumps-notary.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_archive"
  asc notarization submit --file "$notary_archive" --wait
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
fi

update_archive="$output_directory/feed/Keybumps-$release_version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$update_archive"
cp "$release_notes" "$output_directory/feed/Keybumps-$release_version.md"
# The disk image opens to Keybumps and an Applications link on a lit tray, to drag one onto the other (#437).
python3 -m venv "$output_directory/dmgbuild"
"$output_directory/dmgbuild/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: -r "$app_root/scripts/dmg/requirements.txt"
# Hosted macOS runners sometimes report "Resource busy" on detach. dmgbuild's retries back off
# by 1.5x each time, so 12 waits about 6 minutes in all (its default 5 is about 20 seconds).
"$output_directory/dmgbuild/bin/dmgbuild" --detach-retries 12 -s "$app_root/scripts/dmg/dmg-settings.py" \
  -D app="$app_path" -D background="$app_root/scripts/dmg/background.png" \
  Keybumps "$output_directory/Keybumps-$release_version.dmg"
typeset -a dmg_check_mode
[[ "${KEYBUMPS_SKIP_NOTARIZATION:-}" == 1 ]] || dmg_check_mode=(--notarized)
"$app_root/scripts/check-dmg-layout.sh" $dmg_check_mode "$output_directory/Keybumps-$release_version.dmg"
/usr/bin/shasum -a 256 "$output_directory/Keybumps-$release_version.dmg" > "$output_directory/Keybumps-$release_version.dmg.sha256"

# Production and staging feeds share immutable assets under releases/<build>/ (see docs/releases/cloudflare.md).
release_download_prefix="https://updates.keybumps.app/releases/$release_build/"
"$app_root/scripts/generate-staged-appcast.sh" "$output_directory/feed" "$release_download_prefix" "$sparkle_tools_directory" "$sparkle_key_account"
"$app_root/scripts/validate-update-release.sh" \
  "$app_path" "$update_archive" "$output_directory/feed/appcast.xml" "$output_directory/feed/Keybumps-$release_version.md" \
  "$feed_url" "$feed_url" "$previous_build" "$release_build" "$release_version" "$sparkle_tools_directory" "$sparkle_key_account" \
  $trust_mode

cp "$update_archive" "$update_archive.sha256" "$output_directory/feed/Keybumps-$release_version.md" \
  "$output_directory/Keybumps-$release_version.dmg" "$output_directory/Keybumps-$release_version.dmg.sha256" \
  "$output_directory/publication/assets/"
cp "$output_directory/feed/appcast.xml" "$output_directory/publication/publish-last/appcast.xml"
"$app_root/scripts/write-latest-release-pointer.sh" \
  "$output_directory/feed/appcast.xml" "$release_build" "$release_version" \
  "$output_directory/Keybumps-$release_version.dmg.sha256" "$output_directory/publication/publish-last/latest.json"

print "Release prepared. Preview with apps/macos/scripts/publish-release.sh \"$output_directory\" production; publish (owner-authorized) by adding --publish."
