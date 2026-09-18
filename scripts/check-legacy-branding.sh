#!/bin/zsh
set -euo pipefail

repository_root=${0:A:h:h}
cd "$repository_root"

legacy_pattern='SuperMac|supermac|SUPERMAC|Key Bump|Key Bumps|key bump|key bumps|key-bump|key-bumps|KeyBump|KeyBumps|keyBump|keyBumps|ShortcutCoach|shortcutCoaching'
violations=()

while IFS= read -r tracked_file; do
  case "$tracked_file" in
    AGENTS.md|project.yml|Keybumps.xcodeproj/project.pbxproj|scripts/check-legacy-branding.sh|docs/development-workflow.md|Keybumps/Delivery/SystemChannelAdapters.swift|KeybumpsTests/KeyboardShortcutterTests.swift|docs/releases/sparkle-update-operations.md|docs/releases/keybumps-update-hosting.md)
      continue
      ;;
    docs/adr/*|docs/provenance/*|docs/evidence/*|docs/app-replica/completion-manifest.json|docs/app-replica/parity-ledger.md|docs/app-replica/scope.md|docs/app-replica/evidence/*|docs/releases/v0.0.*|public/*)
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
