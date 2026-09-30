#!/bin/zsh
set -euo pipefail

# Scan the whole repository, even when the app folder that holds this script is below its root.
# App files in the allowlist are relative to the app folder: app_prefix is "" at the root.
app_root=${0:A:h:h}
repository_root=$(git -C "$app_root" rev-parse --show-toplevel)
app_prefix=$(git -C "$app_root" rev-parse --show-prefix)
cd "$repository_root"

legacy_pattern='SuperMac|supermac|SUPERMAC|Key Bump|Key Bumps|key bump|key bumps|key-bump|key-bumps|KeyBump|KeyBumps|keyBump|keyBumps|ShortcutCoach|shortcutCoaching'
violations=()

while IFS= read -r tracked_file; do
  case "$tracked_file" in
    AGENTS.md|docs/development-workflow.md|docs/releases/sparkle-update-operations.md)
      continue
      ;;
    "${app_prefix}project.yml"|"${app_prefix}Keybumps.xcodeproj/project.pbxproj"|"${app_prefix}scripts/check-legacy-branding.sh"|"${app_prefix}KeybumpsTests/KeyboardShortcutterTests.swift")
      continue
      ;;
    docs/provenance/*|public/*)
      continue
      ;;
  esac
  if /usr/bin/grep -EIn "$legacy_pattern" "$tracked_file" >/dev/null 2>&1; then
    violations+=("$tracked_file")
  fi
done < <(git ls-files)

if (( ${#violations} > 0 )); then
  print -u2 "Legacy product or feature branding exists outside the approved migration/historical allowlist:"
  for violation in "$violations[@]"; do
    print -u2 "  $violation"
    /usr/bin/grep -EIn "$legacy_pattern" "$violation" >&2 || true
  done
  exit 1
fi

print "Legacy branding allowlist check passed."
