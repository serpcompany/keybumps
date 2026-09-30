#!/bin/zsh
# Build a Developer ID-signed local manual-QA candidate from the current commit,
# back up the installed Keybumps, install the candidate, and launch it.
# Never notarizes, publishes, tags, or touches the update feed.
#
# usage: apps/macos/scripts/build-qa-candidate.sh <issue-number> [--no-install]
set -euo pipefail

(( $# >= 1 )) && [[ "$1" == <-> ]] || { print -u2 "usage: $0 <issue-number> [--no-install]"; exit 64; }
issue=$1
install=1
[[ "${2:-}" == "--no-install" ]] && install=0

app_root=${0:A:h:h}
installed_app=/Applications/Keybumps.app
qa_root=${KEYBUMPS_QA_ROOT:-$HOME/Library/Developer/Keybumps-QA}
cd "$app_root"

[[ -z "$(git status --porcelain)" ]] || { print -u2 "refusing to build: working tree has uncommitted changes"; exit 65; }
branch=$(git rev-parse --abbrev-ref HEAD)
commit=$(git rev-parse HEAD)
short_commit=$(git rev-parse --short HEAD)

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true }

# Continuity with the installed baseline: same feed, public key, and designated requirement.
[[ -d "$installed_app" ]] || { print -u2 "no installed baseline at $installed_app"; exit 66; }
baseline_version=$(plist_value "$installed_app" CFBundleShortVersionString)
baseline_build=$(plist_value "$installed_app" CFBundleVersion)
feed_url=${KEYBUMPS_UPDATE_FEED_URL:-$(plist_value "$installed_app" SUFeedURL)}
public_key=${KEYBUMPS_UPDATE_PUBLIC_KEY:-$(plist_value "$installed_app" SUPublicEDKey)}
baseline_requirement=$(codesign -d -r- "$installed_app" 2>&1 | sed -n 's/^designated => //p')
[[ -n "$feed_url" && -n "$public_key" && -n "$baseline_requirement" ]] || { print -u2 "could not read feed, key, or designated requirement from baseline"; exit 66; }
# A previously installed candidate (<release>.<issue>.<n>) still anchors on its release build.
release_build=${baseline_build%%.*}
[[ "$release_build" == <-> ]] || { print -u2 "cannot read a release build from baseline ($baseline_build)"; exit 66; }

# Sparkle orders <baseline>.<issue>.<n> above the baseline and below the next public build,
# so a candidate is never offered a downgrade and still receives the next real release.
candidates_dir="$qa_root/candidates"
mkdir -p "$candidates_dir" "$qa_root/backups"
sequence=1
while [[ -e "$candidates_dir/$release_build.$issue.$sequence" ]]; do (( sequence++ )); done
candidate_build="$release_build.$issue.$sequence"
candidate_version="${baseline_version%%-*}-dev.issue$issue"
output="$candidates_dir/$candidate_build"
mkdir -p "$output"

print "Building $candidate_version ($candidate_build) from $branch @ $short_commit"
xcodegen generate >/dev/null
xcodebuild -quiet -project Keybumps.xcodeproj -scheme Keybumps-Release -configuration Release \
  -archivePath "$output/Keybumps.xcarchive" \
  MARKETING_VERSION="$candidate_version" CURRENT_PROJECT_VERSION="$candidate_build" \
  KEYBUMPS_UPDATE_FEED_URL="$feed_url" KEYBUMPS_UPDATE_PUBLIC_KEY="$public_key" archive
xcodebuild -quiet -exportArchive \
  -archivePath "$output/Keybumps.xcarchive" \
  -exportPath "$output/export" \
  -exportOptionsPlist "$app_root/scripts/ExportOptions-DeveloperID.plist"
candidate_app="$output/export/Keybumps.app"

codesign --verify --deep --strict "$candidate_app"
candidate_requirement=$(codesign -d -r- "$candidate_app" 2>&1 | sed -n 's/^designated => //p')
[[ "$candidate_requirement" == "$baseline_requirement" ]] || { print -u2 "designated requirement differs from the installed baseline; refusing (TCC continuity)"; exit 67; }
[[ "$(plist_value "$candidate_app" CFBundleIdentifier)" == "com.serp.keybumps" ]] || { print -u2 "unexpected bundle identifier"; exit 67; }

cat > "$output/candidate.txt" <<EOF
version=$candidate_version
build=$candidate_build
issue=$issue
branch=$branch
commit=$commit
baseline=$baseline_version ($baseline_build)
feed=$feed_url
EOF

if (( ! install )); then
  print "Candidate ready (not installed): $candidate_app"
  exit 0
fi

# Match only the installed copy, never a Debug build or test host running from DerivedData.
installed_pid() { pgrep -f "^$installed_app/Contents/MacOS/Keybumps" | head -1 }
quit_keybumps() {
  [[ -n "$(installed_pid)" ]] || return 0
  osascript -e 'tell application id "com.serp.keybumps" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do [[ -n "$(installed_pid)" ]] || return 0; sleep 0.25; done
  print -u2 "Keybumps did not quit; close it and rerun"; exit 68
}

backup="$qa_root/backups/Keybumps-$baseline_build-$(date +%Y%m%d-%H%M%S).app"
quit_keybumps
ditto "$installed_app" "$backup"
rm -rf "$installed_app"
ditto "$candidate_app" "$installed_app"
print "$backup" > "$qa_root/backups/latest"
open "$installed_app"

for _ in {1..40}; do [[ -n "$(installed_pid)" ]] && break; sleep 0.25; done
running_path=$(ps -o comm= -p "$(installed_pid)" 2>/dev/null || true)
[[ "$running_path" == "$installed_app/Contents/MacOS/Keybumps" ]] || { print -u2 "the installed candidate is not running from $installed_app${running_path:+ (found $running_path)}; quit any other com.serp.keybumps copy and rerun"; exit 69; }
[[ "$(plist_value "$installed_app" CFBundleVersion)" == "$candidate_build" ]] || { print -u2 "installed build does not match candidate"; exit 69; }

print "Installed and running: $candidate_version ($candidate_build)"
print "Branch $branch @ $commit"
print "Backup of previous app: $backup"
print "Restore with: apps/macos/scripts/restore-previous-keybumps.sh"
