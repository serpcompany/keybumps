#!/bin/zsh
# Mounts a release disk image read-only and checks what someone sees on double-click (#437):
# the signed app, the Applications link, and the window layout and background. --notarized also
# requires the app's stapled notarization ticket. Prints nothing about the Mac it runs on.
set -euo pipefail

notarized=0
if [[ "${1:-}" == --notarized ]]; then
  notarized=1
  shift
fi
if (( $# != 1 )); then
  print -u2 "usage: $0 [--notarized] <Keybumps.dmg>"
  exit 64
fi
dmg=${1:A}
mount_point=$(mktemp -d "${TMPDIR:-/tmp}/keybumps-dmg.XXXXXX")
trap 'hdiutil detach -quiet "$mount_point" 2>/dev/null || hdiutil detach -quiet -force "$mount_point" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' EXIT
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg"

fail() { print -u2 "disk image check failed: $1"; exit 70; }
[[ -d "$mount_point/Keybumps.app" ]] || fail "Keybumps.app is missing"
codesign --verify --deep --strict "$mount_point/Keybumps.app" || fail "Keybumps.app's signature doesn't verify"
# dmgbuild copies the app with ditto and ignores its exit status, so check the ticket came along.
(( ! notarized )) || xcrun stapler validate -q "$mount_point/Keybumps.app" || fail "Keybumps.app's notarization ticket is missing"
[[ -L "$mount_point/Applications" && "$(readlink "$mount_point/Applications")" == /Applications ]] || fail "the Applications link is missing or doesn't point to /Applications"
[[ -f "$mount_point/.DS_Store" ]] || fail "the window layout (.DS_Store) is missing"
[[ -f "$mount_point/.background.tiff" ]] || fail "the background image is missing"
[[ -f "$mount_point/.VolumeIcon.icns" ]] || fail "the volume icon is missing"
# Nothing else shows in the window.
visible=(${(f)"$(ls "$mount_point")"})
[[ "${(j: :)${(o)visible}}" == "Applications Keybumps.app" ]] || fail "unexpected items in the window: ${(j:, :)visible}"
print "Disk image layout OK: $dmg"
