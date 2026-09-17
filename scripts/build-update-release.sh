#!/bin/zsh
set -euo pipefail
source "${0:A:h}/lib/update-url-validation.sh"

if (( $# != 9 )); then
  print -u2 "usage: $0 <version> <build> <previous-build> <feed-url> <public-key> <notary-keychain-profile> <sparkle-key-account> <sparkle-tools-directory> <output-directory>"
  exit 64
fi

release_version=$1
release_build=$2
previous_build=$3
feed_url=$4
public_key=$5
notary_profile=$6
sparkle_key_account=$7
sparkle_tools_directory=${8:A}
output_directory=${9:A}
repository_root=${0:A:h:h}
release_notes="$repository_root/docs/releases/v$release_version.md"

[[ "$release_build" == <-> && "$previous_build" == <-> && "$release_build" -gt "$previous_build" ]] || { print -u2 "build must be an integer greater than previous-build"; exit 65; }
update_url_is_production_https "$feed_url" || { print -u2 "release feed must be credential-free, fragment-free public HTTPS with a host"; exit 65; }
[[ -n "$public_key" && -n "$notary_profile" && -n "$sparkle_key_account" ]] || { print -u2 "signing/notary configuration is incomplete"; exit 65; }
[[ -f "$release_notes" ]] || { print -u2 "missing release notes: $release_notes"; exit 66; }
[[ ! -e "$output_directory" ]] || { print -u2 "refusing to overwrite output directory: $output_directory"; exit 73; }

mkdir -p "$output_directory/archive" "$output_directory/export" "$output_directory/feed" "$output_directory/dmg-root" "$output_directory/publication/assets" "$output_directory/publication/publish-last"
cd "$repository_root"
xcodegen generate
xcodebuild -project SuperMac.xcodeproj -scheme SuperMac-Release -configuration Release \
  -archivePath "$output_directory/archive/SuperMac.xcarchive" \
  MARKETING_VERSION="$release_version" CURRENT_PROJECT_VERSION="$release_build" \
  SUPERMAC_UPDATE_FEED_URL="$feed_url" SUPERMAC_UPDATE_PUBLIC_KEY="$public_key" archive
xcodebuild -exportArchive \
  -archivePath "$output_directory/archive/SuperMac.xcarchive" \
  -exportPath "$output_directory/export" \
  -exportOptionsPlist "$repository_root/scripts/ExportOptions-DeveloperID.plist"

app_path="$output_directory/export/SuperMac.app"
notary_archive="$output_directory/SuperMac-notary.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_archive"
xcrun notarytool submit "$notary_archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

update_archive="$output_directory/feed/SuperMac-$release_version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$update_archive"
cp "$release_notes" "$output_directory/feed/SuperMac-$release_version.md"
cp -R "$app_path" "$output_directory/dmg-root/SuperMac.app"
hdiutil create -volname SuperMac -srcfolder "$output_directory/dmg-root" -format ULFO "$output_directory/SuperMac-$release_version.dmg"

feed_parent_prefix=$(update_url_parent_prefix "$feed_url")
"$repository_root/scripts/generate-staged-appcast.sh" "$output_directory/feed" "$feed_parent_prefix" "$sparkle_tools_directory" "$sparkle_key_account"
"$repository_root/scripts/validate-update-release.sh" \
  "$app_path" "$update_archive" "$output_directory/feed/appcast.xml" "$output_directory/feed/SuperMac-$release_version.md" \
  "$feed_url" "$feed_url" "$previous_build" "$release_build" "$release_version" "$sparkle_tools_directory" "$sparkle_key_account"

cp "$update_archive" "$update_archive.sha256" "$output_directory/feed/SuperMac-$release_version.md" "$output_directory/SuperMac-$release_version.dmg" "$output_directory/publication/assets/"
cp "$output_directory/feed/appcast.xml" "$output_directory/publication/publish-last/appcast.xml"

print "Release prepared. Publish publication/assets first and publication/publish-last/appcast.xml last."
