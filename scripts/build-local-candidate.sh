#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  print -u2 "usage: $0 <issue-slug> <build-number> <output-directory>"
  exit 64
fi

issue_slug=$1
candidate_build=$2
output_directory=${3:A}
repository_root=${0:A:h:h}

[[ "$issue_slug" == [a-zA-Z0-9-]## ]] || { print -u2 "issue slug must use letters, numbers, and hyphens"; exit 65; }
[[ "$candidate_build" == <-> && "$candidate_build" -gt 0 ]] || { print -u2 "build number must be a positive integer"; exit 65; }
[[ ! -e "$output_directory" ]] || { print -u2 "refusing to overwrite output directory: $output_directory"; exit 73; }

"$repository_root/scripts/verify-build-source.sh" local "$repository_root" >/dev/null
source_commit=$(git -C "$repository_root" rev-parse HEAD)
source_branch=$(git -C "$repository_root" symbolic-ref --quiet --short HEAD || print detached)
short_commit=${source_commit[1,8]}
candidate_version="0.0.2-dev.$issue_slug.$short_commit"

mkdir -p "$output_directory/archive" "$output_directory/export"
cd "$repository_root"
xcodegen generate
"$repository_root/scripts/verify-build-source.sh" local "$repository_root" >/dev/null
xcodebuild archive -project SuperMac.xcodeproj -scheme SuperMac-Release -configuration Release \
  -archivePath "$output_directory/archive/SuperMac.xcarchive" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$candidate_version" CURRENT_PROJECT_VERSION="$candidate_build" \
  SUPERMAC_SOURCE_COMMIT="$source_commit" SUPERMAC_SOURCE_BRANCH="$source_branch" \
  SUPERMAC_BUILD_KIND=local-candidate
xcodebuild -exportArchive \
  -archivePath "$output_directory/archive/SuperMac.xcarchive" \
  -exportPath "$output_directory/export" \
  -exportOptionsPlist "$repository_root/scripts/ExportOptions-DeveloperID.plist"

app_path="$output_directory/export/SuperMac.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SuperMacSourceCommit' "$app_path/Contents/Info.plist")" == "$source_commit" ]] || exit 65
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SuperMacSourceBranch' "$app_path/Contents/Info.plist")" == "$source_branch" ]] || exit 65
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SuperMacBuildKind' "$app_path/Contents/Info.plist")" == local-candidate ]] || exit 65

"$repository_root/scripts/write-build-manifest.sh" \
  "$output_directory/build-manifest.json" "$candidate_version" "$candidate_build" \
  "$source_commit" "$source_branch" local-candidate

print "Local candidate prepared from $source_branch@$short_commit: $app_path"
